/// 抓取结果的筛选 —— 五个筛选条件串联。
///
/// 五个谓词串联：`byKeyword && byDateRange &&
/// byAuthors && byTags && byDuration)`），全部通过才入选：
///
/// | 谓词 | 匹配范围 |
/// |---|---|
/// | 关键词 | `desc` + `author.nickname` + `video_tag` 拼接后的子串匹配 |
/// | 日期 | `create_time` 落在所选**日期的整天区间**内 |
/// | 作者 | `uid` ‖ `author_user_id` ‖ `sec_uid` ‖ `nickname` 任一命中 |
/// | 标签 | 「任一」命中，或「全部」命中 |
/// | 时长 | `video.duration`（毫秒）落在 `[最短, 最长]` 内 |
///
/// **两个容易搞混的点（源码确认过）：**
///   1. 日期筛选是**发布时间**，时长筛选是**视频本身的时长**（不是发布时段）。
///   2. 日期把用户选的「日」展开成**整天的毫秒区间**
///      （`setHours(0,0,0,0)` ~ `setHours(23,59,59,999)`），
///      这样「选了 9 月 14 日」才能查到当天下午发的作品。
library;

import '../models/media.dart';

/// 标签匹配模式。
enum TagMode {
  /// 任一命中即可（默认）
  any('any', '任一'),

  /// 全部命中
  all('all', '全部');

  const TagMode(this.id, this.label);

  final String id;
  final String label;
}

/// 日期快捷范围（下拉里那几项）。
enum DateQuickRange {
  none('', '不限'),
  last7('7', '最近7天'),
  last30('30', '最近30天'),
  last90('90', '最近90天'),
  lastHalfYear('180', '最近半年'),
  lastYear('365', '最近一年');

  const DateQuickRange(this.id, this.label);

  final String id;
  final String label;

  /// 该范围对应的起止时刻；[none] 返回 null。
  ///
  /// **含今天**：`最近7天` = 今天与之前 6 天（共 7 天）。
  /// 截止时刻取今天 23:59:59.999，避免「今天下午发的查不到」。
  (DateTime, DateTime)? resolve(DateTime now) {
    if (this == DateQuickRange.none) return null;
    final days = int.tryParse(id) ?? 0;
    if (days <= 0) return null;
    final start = startOfDay(now.subtract(Duration(days: days - 1)));
    return (start, endOfDay(now));
  }
}

/// 当天的 00:00:00.000
DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

/// 当天的 23:59:59.999
DateTime endOfDay(DateTime d) =>
    DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

/// 筛选条件。全部为空表示「未设置筛选条件」。
class DouyinFilter {
  /// 关键词（大小写不敏感的子串匹配）
  String keyword;

  /// 发布日期起点（含，整天区间的最小值）
  DateTime? dateStart;

  /// 发布日期终点（含，整天区间的最大值）
  DateTime? dateEnd;

  /// 最近 N 天快捷键（与手动日期互斥：选了快捷键就覆盖 dateStart/dateEnd）
  DateQuickRange quickRange;

  /// 作者：匹配 userId / userScreenName / userName 任一
  Set<String> authorIds;

  /// 标签
  Set<String> tags;
  TagMode tagMode;

  /// 时长区间（**秒**，作用于视频本身时长）
  int? minDurationSec;
  int? maxDurationSec;

  /// 「按作品」—— 同一作品的多条媒体连续排列
  bool groupByAweme;

  DouyinFilter({
    this.keyword = '',
    this.dateStart,
    this.dateEnd,
    this.quickRange = DateQuickRange.none,
    Set<String>? authorIds,
    Set<String>? tags,
    this.tagMode = TagMode.any,
    this.minDurationSec,
    this.maxDurationSec,
    this.groupByAweme = true,
  })  : authorIds = authorIds ?? <String>{},
        tags = tags ?? <String>{};

  /// 是否「未设置筛选条件」——用于决定要不要显示筛选提示。
  bool get isEmpty =>
      keyword.trim().isEmpty &&
      dateStart == null &&
      dateEnd == null &&
      quickRange == DateQuickRange.none &&
      authorIds.isEmpty &&
      tags.isEmpty &&
      minDurationSec == null &&
      maxDurationSec == null;

  /// 命中该筛选条件的数量（界面上「筛选结果: N」用它）。
  int countIn(Iterable<Media> items) =>
      items.where((m) => matches(m, this)).length;

  DouyinFilter copyWith({
    String? keyword,
    DateTime? dateStart,
    DateTime? dateEnd,
    DateQuickRange? quickRange,
    Set<String>? authorIds,
    Set<String>? tags,
    TagMode? tagMode,
    int? minDurationSec,
    int? maxDurationSec,
    bool? groupByAweme,
    bool clearDates = false,
    bool clearDuration = false,
  }) =>
      DouyinFilter(
        keyword: keyword ?? this.keyword,
        dateStart: clearDates ? null : (dateStart ?? this.dateStart),
        dateEnd: clearDates ? null : (dateEnd ?? this.dateEnd),
        quickRange: clearDates
            ? DateQuickRange.none
            : (quickRange ?? this.quickRange),
        authorIds: authorIds ?? this.authorIds,
        tags: tags ?? this.tags,
        tagMode: tagMode ?? this.tagMode,
        minDurationSec:
            clearDuration ? null : (minDurationSec ?? this.minDurationSec),
        maxDurationSec:
            clearDuration ? null : (maxDurationSec ?? this.maxDurationSec),
        groupByAweme: groupByAweme ?? this.groupByAweme,
      );
}

/// 谓词合集 —— 单个条件是否命中（每个都是纯函数，便于单测）。
bool matches(Media m, DouyinFilter f) =>
    _byKeyword(m, f.keyword) &&
    _byDateRange(m, f) &&
    _byAuthors(m, f.authorIds) &&
    _byTags(m, f.tags, f.tagMode) &&
    _byDuration(m, f.minDurationSec, f.maxDurationSec);

/// 关键词：作品文本 + 作者名 + 标签 拼接后做子串匹配。
bool _byKeyword(Media m, String keyword) {
  final k = keyword.trim().toLowerCase();
  if (k.isEmpty) return true;
  return m.searchText.toLowerCase().contains(k);
}

/// 日期：发布时间落在整天区间内。
///
/// **没有发布时间的条目在启用日期筛选时被排除** —— 否则「筛选了日期」
/// 却混进来一堆未知时间的条目，用户会以为筛选没生效。
bool _byDateRange(Media m, DouyinFilter f) {
  DateTime? lo = f.dateStart;
  DateTime? hi = f.dateEnd;
  final quick = f.quickRange.resolve(DateTime.now());
  if (quick != null) {
    lo = quick.$1;
    hi = quick.$2;
  }
  if (lo == null && hi == null) return true;
  final t = m.createdAt;
  if (t == null) return false;
  if (lo != null && t.isBefore(startOfDay(lo))) return false;
  if (hi != null && t.isAfter(endOfDay(hi))) return false;
  return true;
}

/// 作者：四选一任一命中。
bool _byAuthors(Media m, Set<String> authors) {
  if (authors.isEmpty) return true;
  for (final a in authors) {
    if (a == m.userId || a == m.userScreenName || a == m.userName) return true;
  }
  return false;
}

/// 标签：任一 / 全部。
bool _byTags(Media m, Set<String> tags, TagMode mode) {
  if (tags.isEmpty) return true;
  final owned = m.tags.toSet();
  if (mode == TagMode.all) {
    return tags.every(owned.contains);
  }
  return tags.any(owned.contains);
}

/// 时长：视频本身时长（秒）落在区间内。
///
/// **没有时长的条目（图片）在启用时长筛选时被排除** —— 与参照实现一致
/// （它读的是 `video.duration`，图片拿不到）。
bool _byDuration(Media m, int? minSec, int? maxSec) {
  if (minSec == null && maxSec == null) return true;
  final ms = m.durationMs;
  if (ms == null || ms <= 0) return false;
  final sec = ms / 1000.0;
  if (minSec != null && sec < minSec) return false;
  if (maxSec != null && sec > maxSec) return false;
  return true;
}

/// 应用筛选并（可选）按作品聚合排序。
///
/// 「按作品」的语义是把同一 `tweetId` 的媒体排在一起，
/// **不改动作品之间的相对顺序**（保持时间倒序）。
List<Media> applyFilter(
  Iterable<Media> items,
  DouyinFilter f, {
  bool group = true,
}) {
  final kept = items.where((m) => matches(m, f)).toList(growable: false);
  if (!group || !f.groupByAweme) return kept;

  // 用「首次出现顺序」建立作品次序，再按该次序稳定归组
  final order = <String, int>{};
  for (final m in kept) {
    final key = m.tweetId ?? m.id;
    order.putIfAbsent(key, () => order.length);
  }
  final indexed = <(int, int, Media)>[];
  for (var i = 0; i < kept.length; i++) {
    final key = kept[i].tweetId ?? kept[i].id;
    indexed.add((order[key]!, i, kept[i]));
  }
  indexed.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    return a.$2.compareTo(b.$2);
  });
  return indexed.map((e) => e.$3).toList(growable: false);
}

/// 可选的作者 / 标签候选列表 —— 供筛选面板做多选。
({List<String> authors, List<String> tags}) filterFacets(
    Iterable<Media> items) {
  final authors = <String>{};
  final tags = <String>{};
  for (final m in items) {
    for (final a in [m.userName, m.userScreenName, m.userId]) {
      if (a != null && a.isNotEmpty) authors.add(a);
    }
    tags.addAll(m.tags);
  }
  final a = authors.toList()..sort();
  final t = tags.toList()..sort();
  return (authors: a, tags: t);
}
