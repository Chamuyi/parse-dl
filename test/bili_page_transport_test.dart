import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_api.dart';

/// 钉住「取流走页内 fetch」这条通路的几件事：
///
///  1. **装上就不该再走 dart:io**。负控制：装了口却仍然直连，真机上表现为
///     「登录了也还是 480P」，而单测里什么都看不出来 —— 正是 2026-10-11
///     那一轮的实际症状（`_cookieForApi` 恒为 null，取流永远匿名）。
///  2. **口的契约定死为「返回整份 body」**（带 `code` 信封），不是 `data`。
///     这条契约 2026-10-11 收窄过一次：原来返回 `data` 那版会让
///     `view/detail/tag`（`data` 是**数组**）被挡死 —— 表现在真机上就是
///     「标签这一支恒缺」。判 code、取 data 现在由 [BiliApi] 自己按各口需要做。
///  3. **附加文件那条路也要能用上这个口**（`BiliPageTransportRegistry`）。
///     漏了它，真机症状是「登录了也报：字幕：接口没返回任何一条」——
///     因为附加文件那份 `BiliApi` 在 main.dart 启动时装配、拿不到 WebView。
///     这条是同一轮真机撞出来的第二个 bug。
///
/// 为什么不真起 WebView：`webview_windows` 的控制器要原生视图，单测里没有。
/// 所以这里钉的是**口这一层的契约**；`BiliInPage.get` 的真实行为由
/// `bili_web_test.dart` 覆盖，端到端由真机验收执行器覆盖。
///
/// 注：`getSignedData` 会先算 WBI 签名（要打 nav 取密钥），所以凡是要走到
/// 「调用口」的用例都必须先给一对 key；`setWbiKeysForTest` 是为此加的
/// `@visibleForTesting` 入口，形状照 `aria2_coordinator.dart` 那几个。
void main() {
  const imgKey = '7d070483c80752b30d309a11c0c9a9ad';
  const subKey = 'b888d6f1d8b042d3973b4cf6b0b5bd99';

  setUp(BiliPageTransportRegistry.resetForTest);
  tearDown(BiliPageTransportRegistry.resetForTest);

  /// 假的水管：**返回整份 body（带 code 信封）**，与真实现契约一致。
  BiliApi apiWithProbe(
    List<Uri> seen, {
    Map<String, dynamic> Function(Uri uri)? data,
  }) {
    final api = BiliApi();
    api.setWbiKeysForTest(imgKey: imgKey, subKey: subKey);
    api.setPageTransport((uri, what) async {
      seen.add(uri);
      return {
        'code': 0,
        'data': (data ?? (_) => {'ok': 1})(uri),
      };
    });
    return api;
  }

  group('页内取流口', () {
    test('默认没装：usesPageTransport 为假（匿名 dart:io 那条路不变）', () {
      expect(BiliApi().usesPageTransport, isFalse);
    });

    test('装上之后为真，且签名 URL 真的传进口里', () async {
      final seen = <Uri>[];
      final api = apiWithProbe(seen, data: (_) => {'dash': <String, dynamic>{}});
      expect(api.usesPageTransport, isTrue);

      final data = await api.getSignedData(
        '/x/player/wbi/playurl',
        {'cid': 1, 'qn': 80},
        what: '取流地址',
      );

      expect(seen, hasLength(1), reason: '页内口没被调用 —— 又走回 dart:io 了');
      final u = seen.single;
      expect(u.host, isNotEmpty);
      expect(u.query, contains('w_rid='), reason: '签名没算就发出去，真机会被拒');
      expect(u.query, contains('wts='));
      expect(data['dash'], isA<Map>());
    });

    test('卸掉口之后回到 dart:io（WebView 销毁 / 退出登录那条路）', () {
      final api = BiliApi();
      api.setPageTransport((uri, what) async => const {'code': 0});
      expect(api.usesPageTransport, isTrue);
      api.setPageTransport(null);
      expect(api.usesPageTransport, isFalse);
    });
  });

  group('页内回包的契约（负控制）', () {
    test('业务码非 0 → 由 BiliApi 抛出并带码（-403 重取密钥的分支靠它认）',
        () async {
      final api = BiliApi();
      api.setWbiKeysForTest(imgKey: imgKey, subKey: subKey);
      // 口只负责把整份 body 拿回来，非 0 的判定在 BiliApi 里
      api.setPageTransport(
          (uri, what) async => {'code': -412, 'message': '请求被拦截'});

      await expectLater(
        api.getSignedData('/x/player/wbi/playurl', {'cid': 1}, what: '取流地址'),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -412)),
      );
    });

    test('签名被拒（-403）会清密钥重取一次再试，不是直接放弃', () async {
      var calls = 0;
      final api = BiliApi();
      api.setWbiKeysForTest(imgKey: imgKey, subKey: subKey);
      api.setPageTransport((uri, what) async {
        calls++;
        if (calls == 1) return {'code': -403, 'message': '签名被拒'};
        return {
          'code': 0,
          'data': {'ok': 1},
        };
      });

      final data = await api.getSignedData('/x/player/wbi/playurl', {'cid': 1},
          what: '取流地址');
      expect(calls, 2, reason: '-403 必须重试一次，密钥按天轮换，用户不该为此重启');
      expect(data['ok'], 1);
    });

    test('data 不是对象时 getSignedData 要抛（别让上层拿到空形状）', () async {
      final api = BiliApi();
      api.setWbiKeysForTest(imgKey: imgKey, subKey: subKey);
      // view/detail/tag 那类接口的 data 是数组；getSignedData 这条口只认对象
      api.setPageTransport((uri, what) async => {
            'code': 0,
            'data': [1, 2, 3],
          });

      await expectLater(
        api.getSignedData('/x/player/wbi/playurl', {'cid': 1}, what: '取流地址'),
        throwsA(isA<BiliApiException>()),
      );
    });
  });

  group('附加文件那条通路的登记处', () {
    test('未登记时 current 为空（附加文件退回匿名，好过打向死控制器）', () {
      expect(BiliPageTransportRegistry.current, isNull);
    });

    test('页面登记后，用 useSharedPageTransport 的那份立刻用上同一个口', () async {
      final seen = <Uri>[];
      // 模拟 main.dart 里那份「附加文件专用」的 BiliApi：装配时还没有 WebView
      final forFiles = BiliApi()
        ..setWbiKeysForTest(imgKey: imgKey, subKey: subKey)
        ..useSharedPageTransport();

      // 登记之前：它没有口（会走 dart:io 匿名）——这正是修复前的真机症状
      expect(forFiles.usesPageTransport, isFalse,
          reason: '登记前就不该有口，否则说明跟随逻辑没生效');

      // 页面 WebView 就绪 → 登记
      BiliPageTransportRegistry.set((uri, what) async {
        seen.add(uri);
        return {
          'code': 0,
          'data': {'subtitle': <String, dynamic>{}},
        };
      });

      // 现在它应该用上同一个口了
      expect(forFiles.usesPageTransport, isTrue,
          reason: '登记之后附加文件那份必须跟上，否则登录态传不到字幕那条接口');
      final data = await forFiles.getSignedData(
        '/x/player/wbi/v2',
        {'cid': 1, 'bvid': 'BV1'},
        what: '字幕列表',
      );
      expect(seen, hasLength(1), reason: '走的还是 dart:io —— 登记处没被读');
      expect(data['subtitle'], isA<Map>());
    });

    test('页面销毁注销之后，跟随者退回匿名', () {
      final forFiles = BiliApi()..useSharedPageTransport();
      BiliPageTransportRegistry
          .set((uri, what) async => const {'code': 0});
      expect(forFiles.usesPageTransport, isTrue);
      BiliPageTransportRegistry.set(null);
      expect(forFiles.usesPageTransport, isFalse,
          reason: '页面没了还留着口 = 请求打向已销毁的 WebView');
    });

    test('自己装了口的优先于登记处（页面那份不该被别人顶掉）', () {
      final own = BiliApi()..setPageTransport((uri, what) async => const {});
      BiliPageTransportRegistry.set((uri, what) async => const {});
      expect(own.usesPageTransport, isTrue);
      // 自有口不为 null，所以跟随与否都不影响它
      expect(identical(BiliPageTransportRegistry.current, null), isFalse);
    });
  });
}
