import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/download_filter.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/twitter_time.dart';

/// 原版 `runCreationTask` 的翻页条件是
/// `while (nextCursor !== null && now.isAfter(since))` ——
/// `since` 是日期范围下界、`now` 是本页最旧一条推文的时间。
///
/// 这条判据同时被「自动执行」和「主页默认下载」使用，所以单独守护它。
/// 它也是「日期解析坏了 → 下载逻辑一起坏」的根源：`createdAt` 全为 null 时
/// 永远返回 false，翻页会一路拉到底。
void main() {
  group('DownloadFilter.reachedDateFloor', () {
    final floor = DateTime(2024, 1, 1);

    test('没设日期下界 → 永远不停止翻页', () {
      const f = DownloadFilter();
      expect(f.reachedDateFloor(DateTime(2010, 1, 1)), isFalse);
      expect(f.reachedDateFloor(null), isFalse);
    });

    test('本页最旧一条早于下界 → 应该停', () {
      final f = DownloadFilter(dateFrom: floor);
      expect(f.reachedDateFloor(DateTime(2023, 12, 31, 23, 59)), isTrue);
    });

    test('刚好等于下界也算到达（原版是 !isAfter）', () {
      final f = DownloadFilter(dateFrom: floor);
      expect(f.reachedDateFloor(floor), isTrue);
    });

    test('本页最旧一条仍晚于下界 → 继续翻', () {
      final f = DownloadFilter(dateFrom: floor);
      expect(f.reachedDateFloor(DateTime(2024, 1, 1, 0, 0, 1)), isFalse);
      expect(f.reachedDateFloor(DateTime(2025, 6, 1)), isFalse);
    });

    test('整页都没有时间（oldestSeen 为 null）→ 保守继续翻', () {
      final f = DownloadFilter(dateFrom: floor);
      expect(f.reachedDateFloor(null), isFalse);
    });
  });

  group('端到端：日期解析决定翻页何时停', () {
    test('真实 X 时间能解析 → 翻到下界就停', () {
      final pages = [
        'Sat Jan 20 21:15:36 +0000 2024',
        'Fri Dec 15 08:00:00 +0000 2023',
        'Mon Nov 06 08:00:00 +0000 2023',
      ].map(parseTwitterCreatedAt).toList();

      expect(pages.every((p) => p != null), isTrue);

      final filter = DownloadFilter(dateFrom: DateTime(2024, 1, 1));
      // 第 1 页最旧一条（2024-01-20）仍晚于下界 → 继续翻
      expect(filter.reachedDateFloor(pages[0]), isFalse);
      // 第 2 页最旧一条（2023-12-15）已早于下界 → 停
      expect(filter.reachedDateFloor(pages[1]), isTrue);
    });

    test('回归：解析失败让 createdAt 变 null 时，翻页判据永远为 false（旧 bug 现象）',
        () {
      final filter = DownloadFilter(dateFrom: DateTime(2024, 1, 1));
      // 解析不出来 → null → reachedDateFloor 永远 false → 一路拉到底
      expect(filter.reachedDateFloor(parseTwitterCreatedAt('garbage')), isFalse);
      // 而真实 X 的时间串必须能解析出来（否则就是这个 bug）
      expect(
        parseTwitterCreatedAt('Wed Oct 10 20:19:24 +0000 2018'),
        isNotNull,
      );
    });
  });

  group('DownloadFilter.accepts', () {
    Media media(MediaType type, DateTime? createdAt) => Media(
          id: '1',
          type: type,
          url: 'https://pbs.twimg.com/media/x.jpg',
          tweetId: '1',
          createdAt: createdAt,
        );

    test('日期下界：早于下界的拒掉，等于下界的放行', () {
      final f = DownloadFilter(dateFrom: DateTime(2024, 1, 1));
      expect(f.accepts(media(MediaType.image, DateTime(2023, 12, 31))), isFalse);
      expect(f.accepts(media(MediaType.image, DateTime(2024, 1, 1))), isTrue);
      expect(f.accepts(media(MediaType.image, DateTime(2024, 6, 1))), isTrue);
      // createdAt 缺失时不做日期判断（放行），与原版 `if (!post.createdAt) return true` 一致
      expect(f.accepts(media(MediaType.image, null)), isTrue);
    });

    test('日期上界：晚于上界的拒掉', () {
      final f = DownloadFilter(dateTo: DateTime(2024, 1, 1));
      expect(f.accepts(media(MediaType.image, DateTime(2024, 6, 1))), isFalse);
      expect(f.accepts(media(MediaType.image, DateTime(2023, 1, 1))), isTrue);
    });

    test('媒体类型：勾了哪些就只下哪些', () {
      const f = DownloadFilter(mediaTypes: {MediaType.video});
      expect(f.accepts(media(MediaType.video, DateTime(2025, 1, 1))), isTrue);
      expect(f.accepts(media(MediaType.image, DateTime(2025, 1, 1))), isFalse);
      // 空集合 = 不限
      const all = DownloadFilter();
      expect(all.accepts(media(MediaType.animatedGif, null)), isTrue);
    });
  });

  group('翻页终止：本页最旧一条的取法', () {
    test('一页里时间乱序时，取最小值才能保证不漏停', () {
      final page = [
        DateTime(2024, 6, 1),
        DateTime(2023, 1, 1), // 最旧
        DateTime(2024, 9, 1),
      ];
      var oldest = DateTime.now();
      for (final c in page) {
        if (c.isBefore(oldest)) oldest = c;
      }
      expect(oldest, DateTime(2023, 1, 1));
      expect(DownloadFilter(dateFrom: DateTime(2024, 1, 1)).reachedDateFloor(oldest),
          isTrue);
    });
  });
}
