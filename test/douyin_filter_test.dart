import 'package:flutter_test/flutter_test.dart' hide matches;
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/douyin_filter.dart';

/// 参照实现「筛选」的五个谓词测试。
///
/// 源码是 `list.filter(e => byKeyword && byDateRange && byAuthors && byTags &&
/// byDuration)`，五个全通过才入选。两个容易被实现搞混、这里专门钉住的点：
///   1. 日期筛的是**发布时间**，时长筛的是**视频本身的时长**；
///   2. 启用了日期/时长筛选时，**缺这个字段的条目要被排除**（否则用户
///      会以为筛选没生效 —— 混进来一堆图片）。
void main() {
  Media mk({
    String id = 'm1',
    String tweetId = 'w1',
    MediaType type = MediaType.video,
    String? text = '一条视频',
    String? userName = '张三',
    String? userScreenName = 'zhangsan',
    String? userId = '111',
    List<String> tags = const ['测试'],
    DateTime? createdAt,
    int? durationMs = 12000,
  }) =>
      Media(
        id: id,
        type: type,
        url: 'https://x/$id.mp4',
        source: 'douyin',
        tweetId: tweetId,
        tweetText: text,
        userName: userName,
        userScreenName: userScreenName,
        userId: userId,
        tags: tags,
        createdAt: createdAt,
        durationMs: durationMs,
      );

  group('关键词', () {
    test('命中描述 / 作者名 / 抖音号 / 标签', () {
      final m = mk(text: '小猫日常', userName: '张三', userScreenName: 'zhangsan', tags: ['猫']);
      expect(matches(m, DouyinFilter(keyword: '小猫')), isTrue);
      expect(matches(m, DouyinFilter(keyword: '张三')), isTrue);
      expect(matches(m, DouyinFilter(keyword: 'zhangsan')), isTrue);
      expect(matches(m, DouyinFilter(keyword: '猫')), isTrue);
      expect(matches(m, DouyinFilter(keyword: '狗')), isFalse);
    });

    test('大小写不敏感，首尾空格被忽略', () {
      final m = mk(userScreenName: 'ZhangSan');
      expect(matches(m, DouyinFilter(keyword: 'zhangsan')), isTrue);
      expect(matches(m, DouyinFilter(keyword: '  ZhangSan  ')), isTrue);
    });

    test('空关键词等于不筛', () {
      expect(matches(mk(), DouyinFilter(keyword: '   ')), isTrue);
    });
  });

  group('发布日期', () {
    test('整天区间：选了当天就能查到当天下午发的作品', () {
      final f = DouyinFilter(
        dateStart: DateTime(2024, 1, 20),
        dateEnd: DateTime(2024, 1, 20),
      );
      expect(matches(mk(createdAt: DateTime(2024, 1, 20, 15, 30)), f), isTrue);
      expect(matches(mk(createdAt: DateTime(2024, 1, 20, 0, 0)), f), isTrue);
      expect(matches(mk(createdAt: DateTime(2024, 1, 20, 23, 59)), f), isTrue);
      expect(matches(mk(createdAt: DateTime(2024, 1, 21, 0, 1)), f), isFalse);
      expect(matches(mk(createdAt: DateTime(2024, 1, 19, 23, 59)), f), isFalse);
    });

    test('只有起点时按「之后」筛', () {
      final f = DouyinFilter(dateStart: DateTime(2024, 1, 20));
      expect(matches(mk(createdAt: DateTime(2024, 6, 1)), f), isTrue);
      expect(matches(mk(createdAt: DateTime(2024, 1, 1)), f), isFalse);
    });

    test('没有发布时间的条目在启用日期筛选时被排除', () {
      final f = DouyinFilter(dateStart: DateTime(2024, 1, 1));
      expect(matches(mk(createdAt: null), f), isFalse);
      // 不启用日期筛选时照常通过
      expect(matches(mk(createdAt: null), DouyinFilter()), isTrue);
    });

    test('快捷范围与手动日期互斥：快捷范围覆盖手动值', () {
      final f = DouyinFilter(
        dateStart: DateTime(2000, 1, 1),
        dateEnd: DateTime(2000, 1, 2),
        quickRange: DateQuickRange.last7,
      );
      // 快捷范围是「最近 7 天」，所以 2000 年的边界被丢掉、今天的条目能过
      expect(matches(mk(createdAt: DateTime.now()), f), isTrue);
    });
  });

  group('DateQuickRange', () {
    test('不限返回 null', () {
      expect(DateQuickRange.none.resolve(DateTime(2024, 1, 10)), isNull);
    });

    test('最近 7 天含今天（共 7 天）', () {
      final r = DateQuickRange.last7.resolve(DateTime(2024, 1, 10, 12))!;
      expect(r.$1, DateTime(2024, 1, 4));
      expect(r.$2, DateTime(2024, 1, 10, 23, 59, 59, 999));
    });

    test('截止时刻是今天 23:59:59.999（避免今天下午的查不到）', () {
      final r = DateQuickRange.last30.resolve(DateTime(2024, 3, 15, 0, 5))!;
      expect(r.$2, DateTime(2024, 3, 15, 23, 59, 59, 999));
      expect(r.$1, DateTime(2024, 2, 15));
    });

    test('半年 / 一年档', () {
      final half = DateQuickRange.lastHalfYear.resolve(DateTime(2024, 7, 1))!;
      final year = DateQuickRange.lastYear.resolve(DateTime(2024, 7, 1))!;
      expect(half.$1, DateTime(2024, 1, 4), reason: '含今天共 180 天');
      expect(year.$1, DateTime(2023, 7, 3), reason: '含今天共 365 天，跨了 2024 闰年');
    });
  });

  group('作者', () {
    test('uid / 抖音号 / 昵称任一命中', () {
      final m = mk(userId: '111', userScreenName: 'zhangsan', userName: '张三');
      expect(matches(m, DouyinFilter(authorIds: {'111'})), isTrue);
      expect(matches(m, DouyinFilter(authorIds: {'zhangsan'})), isTrue);
      expect(matches(m, DouyinFilter(authorIds: {'张三'})), isTrue);
      expect(matches(m, DouyinFilter(authorIds: {'lisi'})), isFalse);
    });

    test('多选作者是「任一」', () {
      final m = mk(userId: '111');
      expect(matches(m, DouyinFilter(authorIds: {'999', '111'})), isTrue);
    });

    test('空集合等于不筛', () {
      expect(matches(mk(), DouyinFilter()), isTrue);
    });
  });

  group('标签', () {
    final m = mk(tags: ['猫', '狗']);

    test('任一模式：命中一个即可', () {
      expect(matches(m, DouyinFilter(tags: {'猫'})), isTrue);
      expect(matches(m, DouyinFilter(tags: {'猫', '鸟'})), isTrue);
      expect(matches(m, DouyinFilter(tags: {'鸟'})), isFalse);
    });

    test('全部模式：一个不落', () {
      expect(
        matches(m, DouyinFilter(tags: {'猫', '狗'}, tagMode: TagMode.all)),
        isTrue,
      );
      expect(
        matches(m, DouyinFilter(tags: {'猫', '鸟'}, tagMode: TagMode.all)),
        isFalse,
      );
    });

    test('没有标签的条目在启用标签筛选时被排除', () {
      expect(matches(mk(tags: const []), DouyinFilter(tags: {'猫'})), isFalse);
    });
  });

  group('视频时长', () {
    test('落在区间内', () {
      final m = mk(durationMs: 12000);
      expect(matches(m, DouyinFilter(minDurationSec: 5, maxDurationSec: 20)), isTrue);
      expect(matches(m, DouyinFilter(minDurationSec: 15)), isFalse);
      expect(matches(m, DouyinFilter(maxDurationSec: 10)), isFalse);
    });

    test('边界含等号', () {
      final m = mk(durationMs: 10000);
      expect(matches(m, DouyinFilter(minDurationSec: 10, maxDurationSec: 10)), isTrue);
    });

    test('图片（没有时长）在启用时长筛选时被排除 —— 与参照实现一致', () {
      final img = mk(type: MediaType.image, durationMs: null);
      expect(matches(img, DouyinFilter(minDurationSec: 1)), isFalse);
      expect(matches(img, DouyinFilter()), isTrue);
    });

    test('时长 0 也算「没有时长」', () {
      expect(matches(mk(durationMs: 0), DouyinFilter(minDurationSec: 1)), isFalse);
    });
  });

  group('DouyinFilter 自身', () {
    test('isEmpty 对每个维度都敏感', () {
      expect(DouyinFilter().isEmpty, isTrue);
      expect(DouyinFilter(keyword: ' ').isEmpty, isTrue, reason: '纯空格不算条件');
      expect(DouyinFilter(keyword: 'a').isEmpty, isFalse);
      expect(DouyinFilter(dateStart: DateTime(2024)).isEmpty, isFalse);
      expect(DouyinFilter(quickRange: DateQuickRange.last7).isEmpty, isFalse);
      expect(DouyinFilter(authorIds: {'a'}).isEmpty, isFalse);
      expect(DouyinFilter(tags: {'a'}).isEmpty, isFalse);
      expect(DouyinFilter(minDurationSec: 1).isEmpty, isFalse);
    });

    test('countIn 数命中条数', () {
      final items = [
        mk(id: 'a', text: '猫'),
        mk(id: 'b', text: '狗'),
        mk(id: 'c', text: '猫狗'),
      ];
      expect(DouyinFilter(keyword: '猫').countIn(items), 2);
      expect(DouyinFilter().countIn(items), 3);
    });

    test('clearDates / clearDuration 能把条件清掉', () {
      final f = DouyinFilter(
        dateStart: DateTime(2024),
        dateEnd: DateTime(2024),
        minDurationSec: 1,
        maxDurationSec: 2,
      );
      final cleared = f.copyWith(clearDates: true, clearDuration: true);
      expect(cleared.dateStart, isNull);
      expect(cleared.dateEnd, isNull);
      expect(cleared.minDurationSec, isNull);
      expect(cleared.maxDurationSec, isNull);
      expect(cleared.isEmpty, isTrue);
    });
  });

  group('applyFilter', () {
    test('五个谓词串联（有一个不过就被筛掉）', () {
      final items = [
        mk(id: 'a', text: '猫', createdAt: DateTime(2024, 1, 20), durationMs: 12000),
        mk(id: 'b', text: '猫', createdAt: DateTime(2024, 1, 21), durationMs: 12000),
      ];
      final kept = applyFilter(
        items,
        DouyinFilter(
          keyword: '猫',
          dateStart: DateTime(2024, 1, 20),
          dateEnd: DateTime(2024, 1, 20),
        ),
      );
      expect(kept.map((m) => m.id).toList(), ['a']);
    });

    test('按作品归组：同一作品的条目连续，作品间相对顺序不变', () {
      final items = [
        mk(id: 'a1', tweetId: 'wa'),
        mk(id: 'b1', tweetId: 'wb'),
        mk(id: 'a2', tweetId: 'wa'),
        mk(id: 'b2', tweetId: 'wb'),
      ];
      final grouped = applyFilter(items, DouyinFilter());
      expect(grouped.map((m) => m.id).toList(), ['a1', 'a2', 'b1', 'b2']);
    });

    test('group: false 或 groupByAweme=false 时保持原顺序', () {
      final items = [
        mk(id: 'a1', tweetId: 'wa'),
        mk(id: 'b1', tweetId: 'wb'),
        mk(id: 'a2', tweetId: 'wa'),
      ];
      expect(
        applyFilter(items, DouyinFilter(), group: false).map((m) => m.id),
        ['a1', 'b1', 'a2'],
      );
      expect(
        applyFilter(items, DouyinFilter(groupByAweme: false)).map((m) => m.id),
        ['a1', 'b1', 'a2'],
      );
    });

    test('作品顺序按首次出现决定（不按 id 排序）', () {
      final items = [
        mk(id: 'x1', tweetId: 'zz'),
        mk(id: 'y1', tweetId: 'aa'),
        mk(id: 'x2', tweetId: 'zz'),
        mk(id: 'y2', tweetId: 'aa'),
      ];
      expect(
        applyFilter(items, DouyinFilter()).map((m) => m.tweetId).toList(),
        ['zz', 'zz', 'aa', 'aa'],
      );
    });
  });

  group('filterFacets', () {
    test('作者候选去重后按字典序，包含昵称 / 抖音号 / uid', () {
      final r = filterFacets([
        mk(userName: '张三', userScreenName: 'zhangsan', userId: '111'),
        mk(userName: '李四', userScreenName: 'lisi', userId: '222', tags: ['猫']),
      ]);
      expect(r.authors, ['111', '222', 'lisi', 'zhangsan', '张三', '李四']);
    });

    test('标签候选去重后按字典序', () {
      final r = filterFacets([
        mk(tags: ['猫', '狗']),
        mk(tags: ['猫']),
      ]);
      expect(r.tags, ['狗', '猫']);
    });

    test('空字段不进候选', () {
      final r = filterFacets([
        Media(id: 'x', type: MediaType.image, url: 'https://x/1.jpeg'),
      ]);
      expect(r.authors, isEmpty);
      expect(r.tags, isEmpty);
    });
  });
}
