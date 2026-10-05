import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/x_api.dart';

/// 翻页终止条件。
///
/// 2026-09-18 的线上问题：X 时间线翻到末尾后，返回的页里**一条媒体都没有**
/// （entries 只剩 Top/Bottom 两个游标），但 Bottom 游标照样原样重复下发。
/// 循环只按 `nextCursor == null` 收尾，于是同一个游标连翻 39 页、每页 0 条，
/// 任务永远停在「创建中」，下载管理页表现为角标有数字而列表是空的。
///
/// 这里只能测纯函数：`CreationTaskStore` / `HomepageStore` 的循环直接调
/// `AppState.api`（真实 XApi，不可注入），要端到端复现得有登录态与网络。
void main() {
  MediaPage page({int n = 0, String? cursor, bool? hasMore}) => MediaPage(
    tweets: List.generate(
      n,
      (i) => Media(id: 'm$i', type: MediaType.image, url: 'https://e/$i'),
    ),
    nextCursor: cursor,
    hasMore: hasMore ?? (cursor != null),
  );

  group('mediaPageHasMore', () {
    test('游标前进了 → 继续翻', () {
      expect(
        mediaPageHasMore(requestedCursor: 'c1', page: page(cursor: 'c2')),
        isTrue,
      );
    });

    test('第一页（没请求过游标）带回游标 → 继续翻', () {
      expect(
        mediaPageHasMore(requestedCursor: null, page: page(cursor: 'c1')),
        isTrue,
      );
    });

    test('**游标原样重复 → 停**（这就是那个无限翻页的洞）', () {
      expect(
        mediaPageHasMore(requestedCursor: 'c1', page: page(cursor: 'c1')),
        isFalse,
      );
      // 哪怕这一页一条媒体都没有、接口还标着 hasMore，也一样停
      expect(
        mediaPageHasMore(
          requestedCursor: 'c1',
          page: page(cursor: 'c1', hasMore: true),
        ),
        isFalse,
      );
    });

    test('没有游标了 → 停', () {
      expect(
        mediaPageHasMore(requestedCursor: 'c1', page: page(cursor: null)),
        isFalse,
      );
      expect(
        mediaPageHasMore(requestedCursor: 'c1', page: page(cursor: '')),
        isFalse,
      );
    });

    test('hasMore 为假时不看游标', () {
      expect(
        mediaPageHasMore(
          requestedCursor: 'c1',
          page: page(cursor: 'c2', hasMore: false),
        ),
        isFalse,
      );
    });

    test('有媒体的正常页不受影响（别把还在走的翻页掐了）', () {
      expect(
        mediaPageHasMore(requestedCursor: 'c1', page: page(n: 20, cursor: 'c2')),
        isTrue,
      );
    });

    // ↓↓↓ 2026-09-18 补：3.0 只判了「游标未前进」，线上根本没拦住 ——
    // X 末尾每页回的游标**一直在变**，但一条媒体都没有。光靠上面那条不够。
    test('单页空 → 还继续（给 X 偶发的可见性过滤留余量）', () {
      expect(
        mediaPageHasMore(
          requestedCursor: 'c1',
          page: page(cursor: 'c2'),
          emptyPagesBefore: 0,
        ),
        isTrue,
      );
    });

    test('连续第 2 页空 → 停', () {
      expect(
        mediaPageHasMore(
          requestedCursor: 'c2',
          page: page(cursor: 'c3'),
          emptyPagesBefore: 1,
        ),
        isFalse,
      );
    });

    test('空页计数只在"有媒体"时归零（这一页有媒体就不算空）', () {
      expect(
        mediaPageHasMore(
          requestedCursor: 'c9',
          page: page(n: 5, cursor: 'c10'),
          emptyPagesBefore: 99, // 之前空过多少页都不该影响有内容的页
        ),
        isTrue,
      );
    });

    test('空页上限常量本身是 2', () {
      expect(kEmptyPageStopAfter, 2);
    });
  });

  group('模拟末尾翻页', () {
    test('到底后每页 0 条、游标一直在变 —— 循环必须有限步内结束', () {
      // 复刻线上形态：前 3 页有货，之后每页 0 条但游标都是新的
      final pages = <MediaPage>[
        for (var i = 0; i < 3; i++)
          page(n: 10, cursor: 'c$i'),
        for (var i = 0; i < 200; i++)
          page(cursor: 'tail$i'),
      ];
      String? cursor;
      var empty = 0;
      var requested = 0;
      while (requested < pages.length) {
        final p = pages[requested];
        if (!mediaPageHasMore(
          requestedCursor: cursor,
          page: p,
          emptyPagesBefore: empty,
        )) {
          break;
        }
        empty = p.tweets.isEmpty ? empty + 1 : 0;
        cursor = p.nextCursor;
        requested++;
      }
      expect(requested, 4, reason: '3 页有货 + 1 页空（余量）后就该收工，不该刷完 200 页');
    });
  });
}
