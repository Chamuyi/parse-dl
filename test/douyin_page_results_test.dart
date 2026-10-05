import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/douyin_config.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/douyin_store.dart';

/// 「抓取结果跟着当前页面走」的测试。
///
/// 诉求原话：「在抖音切换网页时，获取结果要刷新，保证抓取结果要是当前网页内容」。
/// 抖音是单页应用，切页不会新建 WebView，只是把内容换掉；结果如果只存一份，
/// 切页后看到的就是「上一页 + 这一页」的混合物。所以按页面 key 分桶。
void main() {
  Media post(String id, {String? tweetId}) => Media(
        id: id,
        type: MediaType.video,
        url: 'https://x/$id.mp4',
        source: 'douyin',
        tweetId: tweetId ?? id,
      );

  group('douyinPageKey：URL → 分组 key（纯函数）', () {
    test('空与首页都归 home', () {
      expect(douyinPageKey(''), 'home');
      expect(douyinPageKey('https://www.douyin.com/'), 'home');
      expect(douyinPageKey('https://www.douyin.com/?recommend=1'), 'home');
    });

    test('一级路径各成一组', () {
      expect(douyinPageKey('https://www.douyin.com/jingxuan'), 'jingxuan');
      expect(douyinPageKey('https://www.douyin.com/discover'), 'discover');
    });

    test('作品页归到 video:<id>，追踪参数不影响', () {
      expect(douyinPageKey('https://www.douyin.com/video/7123456789'),
          'video:7123456789');
      expect(
          douyinPageKey('https://www.douyin.com/video/7123456789?from=web&x=1'),
          'video:7123456789');
    });

    test('图文作品页（/note/）与视频页归到同一类 key', () {
      expect(douyinPageKey('https://www.douyin.com/note/7123456789'),
          'video:7123456789');
    });

    test('作者页归到 user:<id>', () {
      expect(douyinPageKey('https://www.douyin.com/user/MS4wLjABAAAA'),
          'user:MS4wLjABAAAA');
    });

    test('结尾多一个斜杠也归一', () {
      expect(douyinPageKey('https://www.douyin.com/jingxuan/'), 'jingxuan');
    });

    test('不是合法 URL 也不崩，且归一结果稳定', () {
      expect(douyinPageKey('about:blank'), isNotEmpty);
      expect(douyinPageKey('乱码'), isNotEmpty);
      expect(douyinPageKey('   '), 'home');
    });
  });

  group('结果按页面分组', () {
    test('初始是首页那一组', () {
      final s = DouyinStore();
      expect(s.currentPageKey, 'home');
      expect(s.pageCount, 1);
    });

    test('新抓到的只进当前页那一组', () {
      final s = DouyinStore();
      s.setCurrentUrl('https://www.douyin.com/jingxuan');
      s.ingest([post('j1')]);

      expect(s.items.map((m) => m.id), ['j1']);
      expect(s.currentPageKey, 'jingxuan');
    });

    test('切页后列表换成新页面的结果（旧页不再混进来）', () {
      final s = DouyinStore();
      s.ingest([post('h1')]);

      s.setCurrentUrl('https://www.douyin.com/video/999');
      expect(s.items, isEmpty, reason: '新页面还没抓到东西，列表就该是空的');

      s.ingest([post('v1')]);
      expect(s.items.map((m) => m.id), ['v1']);
    });

    test('切回旧页面，旧结果还在（没被清掉）', () {
      final s = DouyinStore();
      s.ingest([post('h1')]);

      s.setCurrentUrl('https://www.douyin.com/video/999');
      s.ingest([post('v1')]);

      s.setCurrentUrl('https://www.douyin.com/');
      expect(s.items.map((m) => m.id), ['h1']);
    });

    test('已抓过的页面可以通过 pages 列表切回去', () {
      final s = DouyinStore();
      s.ingest([post('h1')]);
      s.setCurrentUrl('https://www.douyin.com/jingxuan');
      s.ingest([post('j1')]);

      expect(s.pages.map((b) => b.key).toSet(), {'home', 'jingxuan'});
      s.selectPage('home');
      expect(s.items.map((m) => m.id), ['h1']);
    });

    test('勾选按页面隔离（切页不会把上一页的勾选带过来）', () {
      final s = DouyinStore();
      s.ingest([post('h1')]);
      s.toggle('h1');
      expect(s.selectedCount, 1);

      s.setCurrentUrl('https://www.douyin.com/video/999');
      s.ingest([post('v1')]);
      expect(s.selectedCount, 0);

      s.setCurrentUrl('https://www.douyin.com/');
      expect(s.selectedCount, 1, reason: '切回来勾选应该还在');
    });

    test('clear 只清当前页，不动别的页', () {
      final s = DouyinStore();
      s.ingest([post('h1')]);
      s.setCurrentUrl('https://www.douyin.com/jingxuan');
      s.ingest([post('j1')]);

      s.clear();
      expect(s.items, isEmpty);

      s.selectPage('home');
      expect(s.items.map((m) => m.id), ['h1']);
    });

    test('pages 按最近使用排序（当前页在最前）', () async {
      final s = DouyinStore();
      s.ingest([post('h1')]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      s.setCurrentUrl('https://www.douyin.com/jingxuan');
      s.ingest([post('j1')]);

      expect(s.pages.first.key, 'jingxuan');
    });

    test('页面数超上限时淘汰最久没用的，但保留当前页', () {
      final s = DouyinStore();
      // 造 20 个**互不相同**的页面（正好到上限）。
      // 注意不能用 `?p=i` 区分 —— 归一化会去掉 query，那样只会有一个桶。
      for (var i = 0; i < DouyinStore.kMaxPages; i++) {
        s.setCurrentUrl('https://www.douyin.com/user/u$i');
        s.ingest([post('u$i')]);
      }
      final firstKey = s.pages.last.key;

      // 再来一个新的 → 最久没用的那个被挤掉
      s.setCurrentUrl('https://www.douyin.com/video/1');
      s.ingest([post('v1')]);

      expect(s.pageCount, lessThanOrEqualTo(DouyinStore.kMaxPages));
      expect(s.pages.any((b) => b.key == firstKey), isFalse);
      expect(s.currentPageKey, 'video:1');
      expect(s.pages.any((b) => b.key == 'video:1'), isTrue);
    });

    // 作者作品页才是 kMaxItems 那一档（feed 页有 12 条滑窗，见下面的组）
    test('每页各自的上限互不挤占', () {
      final s = DouyinStore();
      s.setCurrentUrl('https://www.douyin.com/user/MS4wLjABAAAAtest');
      s.ingest([for (var i = 0; i <= DouyinStore.kMaxItems; i++) post('h$i')]);
      expect(s.count, DouyinStore.kMaxItems);

      s.setCurrentUrl('https://www.douyin.com/jingxuan');
      s.ingest([post('j1')]);
      expect(s.count, 1);

      s.selectPage('user:MS4wLjABAAAAtest');
      expect(s.count, DouyinStore.kMaxItems, reason: '新页面不该挤掉作者页的结果');
    });

    test('切换 URL 不会丢失「上次访问」的记忆', () {
      final s = DouyinStore();
      s.setCurrentUrl('https://www.douyin.com/jingxuan');
      expect(s.lastUrl, 'https://www.douyin.com/jingxuan');
    });

    test('同一页面重复 setCurrentUrl 不会多建组', () {
      final s = DouyinStore();
      s.setCurrentUrl('https://www.douyin.com/jingxuan');
      s.setCurrentUrl('https://www.douyin.com/jingxuan?from=a');
      s.setCurrentUrl('https://www.douyin.com/jingxuan?from=b');

      // 首页那一桶一开始就在，所以总数是 2；关键是 jingxuan 只算一组
      expect(s.pageCount, 2);
      expect(s.pages.where((b) => b.key == 'jingxuan').length, 1);
    });
  });

  group('下载组装只作用于当前页', () {
    test('buildDownloadList 只取当前页的结果', () {
      final s = DouyinStore();
      s.ingest([post('h1')]);

      s.setCurrentUrl('https://www.douyin.com/video/999');
      s.ingest([post('v1')]);

      final r = s.buildDownloadList(DouyinConfig());
      expect(r.items.map((m) => m.id), ['v1']);

      s.selectPage('home');
      final r2 = s.buildDownloadList(DouyinConfig());
      expect(r2.items.map((m) => m.id), ['h1']);
    });

    test('跳过已下载也只在当前页生效', () async {
      final s = DouyinStore();
      s.ingest([post('h1')]);
      await s.ledger.markAll(['h1']);

      final skipped = s.buildDownloadList(DouyinConfig(skipDownloaded: true));
      expect(skipped.items, isEmpty);
      expect(skipped.skippedDownloaded, 1);
    });
  });

  // ── 数量上限：识别由脚本按页面 DOM 把关，这里只剩一道硬上限 ────────
  group('结果条数上限', () {
    DouyinStore filled(String url, int n) {
      final s = DouyinStore();
      s.setCurrentUrl(url);
      s.ingest([for (var i = 0; i < n; i++) post('p$i')]);
      return s;
    }

    test('喂进来多少留多少 —— 不再有 feed 12 / 详情 5 的窗口', () {
      // 能走到这里的每一条，拦截脚本都已经在页面上找到过对应卡片
      expect(filled('https://www.douyin.com/jingxuan', 30).count, 30);
      expect(
        filled('https://www.douyin.com/video/7300000000000000001', 9).count,
        9,
      );
      expect(
        filled('https://www.douyin.com/user/MS4wLjABAAAA', 30).count,
        30,
      );
    });

    test('只有超过硬上限才丢，且要算进「已丢弃」', () {
      final s = DouyinStore();
      s.setCurrentUrl('https://www.douyin.com/jingxuan');
      const n = DouyinStore.kMaxItems;
      s.ingest([for (var i = 0; i < n + 5; i++) post('p$i')]);
      expect(s.count, n);
      expect(s.dropped, 5);
      expect(s.overflowed, isTrue);
      expect(s.items.first.id, 'p5', reason: '列表按页面从上到下，挤掉的是最上面那批');
    });

    test('被挤掉的 id 会重新算新增（去重集合同步移除）', () {
      final s = DouyinStore();
      s.setCurrentUrl('https://www.douyin.com/jingxuan');
      const n = DouyinStore.kMaxItems;
      s.ingest([for (var i = 0; i < n; i++) post('p$i')]);
      expect(s.ingest([post('p0')]), 0, reason: '还在列表里，算重复');
      s.ingest([post('x1'), post('x2')]);
      expect(s.items.any((m) => m.id == 'p0'), isFalse, reason: '从头挤掉两条');
      expect(
        s.ingest([post('p0')]),
        1,
        reason: '已被挤掉，重新抓到应算新增',
      );
      expect(s.ingest([post('x1')]), 0, reason: '没被挤掉的仍算重复');
    });

    test('清空后重新计数', () {
      final s = filled('https://www.douyin.com/jingxuan', 20);
      s.clear();
      expect(s.count, 0);
      expect(s.dropped, 0);
      expect(s.ingest([post('p0')]), 1, reason: '清空后再抓到算新增');
    });
  });
}
