/// 抓取结果的**作品粒度**视图模型。
///
/// 参照实现的抓取列表是**一行一个作品**：图文作品的 9 张图不会平铺成 9 行，
/// 实况图的配对视频也不会单独占一行（2026-09-19 用户明确要求对齐这个做法）。
/// 我们内部一直是「一条媒体一项」（图集按张展开、实况多出配对视频），
/// 所以下载、台账、文件名模板都不受影响 —— 这里只是**展示时折回去**。
library;

import '../models/media.dart';

/// 一个作品（aweme）在界面上的勾选状态 —— **三态**。
///
/// 为什么不能只有"选中/没选中"：「勾选全部图文」勾的是每组里的图文媒体，
/// 而一条图文作品在 `includeBgm` 开着时还带一条视频媒体。按"整组全选才算选中"
/// 判定的话，这些组永远是未选 —— 用户点了「勾选全部图文」、计数已经到 145，
/// 右侧格子却一个勾都没有（2026-09-24 就是这么报的）。
enum DouyinSelection { none, some, all }

/// 一个作品（aweme）在抓取结果里的一行。
class DouyinAwemeGroup {
  DouyinAwemeGroup({required this.awemeId, required this.items});

  /// 作品 id（= `Media.tweetId`）
  final String awemeId;

  /// 该作品的全部可下载条目，**保持页面顺序**
  final List<Media> items;

  int get count => items.length;

  /// 封面用第一条：图集是第 1 张图，纯视频是它的 cover
  Media get lead => items.first;

  String get title {
    final t = lead.tweetText;
    return (t == null || t.isEmpty) ? awemeId : t;
  }

  String? get coverUrl => lead.previewUrl;

  List<String> get tags => lead.tags;

  int get likeCount => lead.likeCount ?? 0;
  int get commentCount => lead.commentCount ?? 0;
  int get collectCount => lead.collectCount ?? 0;
  int get shareCount => lead.shareCount ?? 0;
  DateTime? get createdAt => lead.createdAt;

  int get imageCount => items.where((m) => m.type == MediaType.image).length;

  /// 实况图张数 —— 该序号的静态图旁边还挂着一条配对视频。
  /// 判据只能这样算：`Media` 上没有"我是实况图"这个标记，
  /// 配对关系是靠**同一个 `mediaIndex`** 表达的（见 `douyin_parser.dart`）。
  int get imageLiveCount {
    final liveIndexes = {
      for (final m in items)
        if (m.type == MediaType.video && m.id != awemeId) m.mediaIndex,
    };
    if (liveIndexes.isEmpty) return 0;
    return items
        .where(
          (m) => m.type == MediaType.image && liveIndexes.contains(m.mediaIndex),
        )
        .length;
  }

  /// **主视频**：id 就等于作品 id 的那条。
  /// 实况图的配对视频 id 带 `v` 后缀（见 `douyin_parser.dart`），不算主视频。
  Media? get mainVideo {
    for (final m in items) {
      if (m.type == MediaType.video && m.id == awemeId) return m;
    }
    return null;
  }

  bool get hasMainVideo => mainVideo != null;

  /// 实况图（静态图 + 配对视频）—— 有"不是主视频"的视频条目就是它
  bool get hasLiveVideo =>
      items.any((m) => m.type == MediaType.video && m.id != awemeId);

  int? get durationMs => mainVideo?.durationMs;

  /// 行上的类型标签，对齐参照实现列表里的「图文 / 视频」前缀。
  String get typeLabel {
    final imgs = imageCount;
    if (imgs > 0 && hasMainVideo) return '视频 + $imgs 图';
    if (imgs > 0) {
      if (imageLiveCount > 0) return '实况图文 $imageLiveCount 图';
      return imgs > 1 ? '图文 $imgs 图' : '图文';
    }
    return '视频';
  }
}

/// 把媒体粒度列表折成作品粒度，**按各作品首条出现的先后**排序
/// （= 页面上从上到下）。
List<DouyinAwemeGroup> groupByAweme(List<Media> items) {
  final order = <String>[];
  final buckets = <String, List<Media>>{};
  for (final m in items) {
    final key = m.tweetId ?? m.id;
    if (!buckets.containsKey(key)) {
      buckets[key] = <Media>[];
      order.add(key);
    }
    buckets[key]!.add(m);
  }
  return [
    for (final id in order)
      DouyinAwemeGroup(awemeId: id, items: buckets[id]!),
  ];
}
