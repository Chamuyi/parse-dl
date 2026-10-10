import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_api.dart';
import 'package:parse_dl/services/bili_batch_store.dart';
import 'package:parse_dl/services/bili_link.dart';
import 'package:parse_dl/services/bili_list_api.dart';

/// C 提交（收藏夹批量）的判据。
///
/// **不发真实请求**：全部用假传输 + 夹具。已有的 `bili_list_api_test.dart`
/// 钉的是「分页终止判据读哪个字段」，这里补的是那一支**新加的行为**：
///  1. 三种链接写法（`?fid=` / 短链 `ml…` / 直接贴 id）都落到同一个接口与同一个 id；
///  2. 收藏夹里混着的非稿件条目被丢掉时**要数出来**（静默吞掉的话，用户看到
///     「我 120 条的收藏夹怎么只下到 90 条」会以为是漏了）；
///  3. 未登录那一支的形状是「抛」而不是「空列表」，界面据此说降级话。
void main() {
  Map<String, dynamic> medias(int n, {int from = 1}) => {
        'info': {'media_count': n, 'title': '我的英语片单'},
        'has_more': false,
        'page': null,
        'medias': [
          for (var i = from; i < from + n; i++)
            {
              'id': i,
              'bvid': _bv(i),
              'title': '稿件 $i',
              'upper': {'mid': 224900, 'name': '某UP'},
              'cnt_info': {'play': i, 'collect': 1},
            },
        ],
      };

  group('三种写法都认得，且落进同一个接口', () {
    // (写法, 那一行的样子, 期望的 media_id)
    for (final (label, line, id) in [
      ('?fid= 那种长链接', 'https://space.bilibili.com/224900/favlist?fid=1155866758', 1155866758),
      ('medialist 短链 ml…', 'https://www.bilibili.com/medialist/detail/ml1155866758', 1155866758),
      // 直接贴那串 id（D8 的「贴链接直抓」也接受这种写法）
      ('纯数字 media_id', '1155866758', 1155866758),
    ]) {
      test(label, () {
        final ref = biliTargetRef(line);
        expect(ref, isNotNull, reason: '这一行应该被认成目标');
        expect(ref!.list?.kind, BiliListKind.fav);
        expect(ref.list?.favId, id);
      });
    }

    test('正控制：把 fid 换成字母就必须认不出来（不是「什么都认」）', () {
      expect(biliTargetRef('https://space.bilibili.com/224900/favlist?fid=abc'),
          isNull);
    });

    test('fid=view_later 这种「稍后再看」不在本期，落进 rejected', () {
      expect(biliTargetRef('https://space.bilibili.com/1/favlist?fid=view_later'),
          isNull);
    });

    test('取列表时 favId 进 media_id，而不是被当成 mid', () async {
      final fake = _Fake()
        ..on('/x/v3/fav/resource/list', (p) => medias(2));
      await _api(fake).allArcs(
        BiliListTarget(kind: BiliListKind.fav, favId: 1155866758),
      );
      expect(fake.lastParams('/x/v3/fav/resource/list')?['media_id'],
          1155866758);
    });
  });

  group('非稿件条目：丢掉，但要数着', () {
    test('混进音频与番剧那两条被丢掉，skippedUnsupported=2', () async {
      final fake = _Fake()
        ..on('/x/v3/fav/resource/list', (p) => {
              'info': {'media_count': 5, 'title': '混合单'},
              'medias': [
                ...medias(3)['medias']!,
                // 收藏夹里的音频条目：没有 bvid，只有 aid 与 `type`
                {'id': 901, 'aid': 901, 'title': '一段音频', 'type': 11},
                {'id': 902, 'aid': 902, 'title': '一部番', 'type': 1},
              ],
            });
      final page = await _api(fake).favResources(mediaId: 7);
      expect(page.items, hasLength(3));
      expect(page.skippedUnsupported, 2,
          reason: '丢掉两条没有 BV 号的行是**结果**，多少条才是用户要的话');
    });

    test('跨页累计：两页各丢一条 → 汇总里是 2', () async {
      final fake = _Fake()
        ..on('/x/v3/fav/resource/list', (p) {
          final pn = p['pn'] as int;
          return {
            'info': {'media_count': 4, 'title': '混合单'},
            'medias': [
              ...medias(2, from: pn == 1 ? 1 : 3)['medias']!,
              {'id': 500 + pn, 'title': '非稿件条目', 'type': 11},
            ],
          };
        });
      final s = await _api(fake).allArcsSummary(
        BiliListTarget(kind: BiliListKind.fav, favId: 7),
      );
      expect(s.items, hasLength(4));
      expect(s.skipped, 2);
      expect(s.listTitle, '混合单', reason: '列表名要给界面那一行用');
      expect(fake.countOf('/x/v3/fav/resource/list'), 2);
    });

    test('正控制：一条非稿件都没有时 skipped 必须是 0 而不是 null 混过去', () async {
      final fake = _Fake()..on('/x/v3/fav/resource/list', (p) => medias(2));
      final s = await _api(fake).allArcsSummary(
        BiliListTarget(kind: BiliListKind.fav, favId: 7),
      );
      expect(s.skipped, 0);
    });
  });

  group('未登录时的降级形状', () {
    test('匿名回 code=0 而 data=null → 抛，界面才有「拿不到列表」可说', () async {
      final fake = _Fake()
        ..onRaw('/x/v3/fav/folder/created/list-all', (p) => {
              'code': 0,
              'message': 'OK',
              'data': null,
            });
      await expectLater(
        _api(fake).createdFolders(upMid: 224900),
        throwsA(isA<BiliApiException>()),
        reason: '把「没登录」报成空列表，界面就只能显示一个空下拉',
      );
    });

    test('store 侧：note 非空 + 列表为空，是界面说降级话的那对值', () {
      final store = BiliBatchStore();
      store.setFavFolders(const [], note: '还没登录');
      expect(store.favFolders, isEmpty);
      expect(store.favFoldersNote, '还没登录');
      // 正控制：清空 note 之后界面不该再显示那句
      store.setFavFolders(const []);
      expect(store.favFoldersNote, isEmpty);
    });

    test('从下拉里选一条收藏夹 = 把那串 id 加进目标文本；重复选不再加', () {
      final store = BiliBatchStore();
      final folder = BiliFavFolder(
        mediaId: 1155866758,
        title: '我的英语片单',
        mediaCount: 3,
      );
      expect(store.addFavFolderTarget(folder), isTrue);
      expect(store.rawText, '1155866758');
      expect(store.targets.single.ref.list?.kind, BiliListKind.fav);
      expect(store.addFavFolderTarget(folder), isFalse,
          reason: '第二次点不该在文本里多出一样的一行');
      expect(store.rawText, '1155866758');
    });
  });
}

/// 假的 `bvid`（`BV` + 10 位 base58 的形状），与真响应同形。
String _bv(int i) => 'BV${i.toString().padLeft(10, '0')}';

BiliListApi _api(_Fake fake) =>
    BiliListApi(signed: fake.transport, plain: fake.transport);

class _Fake {
  final Map<String, Map<String, dynamic> Function(Map<String, dynamic>)>
      _handlers = {};
  final List<(String, Map<String, dynamic>)> calls = [];

  _Fake on(String path, Map<String, dynamic> Function(Map<String, dynamic>) fn) {
    _handlers[path] = fn;
    return this;
  }

  _Fake onRaw(String path, Map<String, dynamic> Function(Map<String, dynamic>) fn) =>
      on(path, fn);

  List<String> get paths => calls.map((c) => c.$1).toList();

  int countOf(String path) => paths.where((p) => p == path).length;

  Map<String, dynamic>? lastParams(String path) {
    for (var i = calls.length - 1; i >= 0; i--) {
      if (calls[i].$1 == path) return calls[i].$2;
    }
    return null;
  }

  BiliListTransport get transport => (path, params) async {
        final snapshot = Map<String, dynamic>.from(params);
        calls.add((path, snapshot));
        final fn = _handlers[path];
        if (fn == null) throw BiliApiException('no fixture handler for $path');
        return fn(snapshot);
      };
}
