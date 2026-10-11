import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_api.dart';

/// 钉住「取流走页内 fetch」这条通路的两件事：
///
///  1. **装上就不该再走 dart:io**。这条是负控制：装了口却仍然直连，在真机上
///     表现为「登录了也还是 480P」，而单测里什么都看不出来 —— 正是 2026-10-11
///     那一轮的实际症状（`_cookieForApi` 恒为 null，取流永远匿名）。
///  2. **契约**与 `getSignedData` 一致：非 0 就抛（并带上业务码，-403 那条
///     重取密钥的分支靠它认）。页内 fetch 拿回的是**整份 JSON**，判 code 再取
///     data 是那一段的责任 —— 少了它，一条被风控的回包会被当成正常流信息吃下去，
///     症状是「选流莫名其妙说不支持」。
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

  BiliApi apiWithProbe(
    List<Uri> seen, {
    Map<String, dynamic> Function(Uri uri)? reply,
  }) {
    final api = BiliApi();
    api.setWbiKeysForTest(imgKey: imgKey, subKey: subKey);
    api.setPageTransport((uri, what) async {
      seen.add(uri);
      return (reply ?? (_) => {'ok': 1})(uri);
    });
    return api;
  }

  group('页内取流口', () {
    test('默认没装：usesPageTransport 为假（匿名 dart:io 那条路不变）', () {
      expect(BiliApi().usesPageTransport, isFalse);
    });

    test('装上之后为真，且签名 URL 真的传进口里', () async {
      final seen = <Uri>[];
      final api = apiWithProbe(seen, reply: (_) => {'dash': <String, dynamic>{}});
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
      api.setPageTransport((uri, what) async => const {});
      expect(api.usesPageTransport, isTrue);
      api.setPageTransport(null);
      expect(api.usesPageTransport, isFalse);
    });
  });

  group('页内回包的契约（负控制）', () {
    test('业务码非 0 → 异常带码透出来（-403 重取密钥的分支靠它认）', () async {
      final api = BiliApi();
      api.setWbiKeysForTest(imgKey: imgKey, subKey: subKey);
      // 模拟页面层那段的判定：非 0 自己抛
      api.setPageTransport((uri, what) async {
        throw const BiliApiException('取流地址失败：请求被拦截', code: -412);
      });

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
        if (calls == 1) {
          throw const BiliApiException('签名被拒', code: -403);
        }
        return {'ok': 1};
      });

      final data =
          await api.getSignedData('/x/player/wbi/playurl', {'cid': 1}, what: '取流地址');
      expect(calls, 2, reason: '-403 必须重试一次，密钥按天轮换，用户不该为此重启');
      expect(data['ok'], 1);
    });
  });
}
