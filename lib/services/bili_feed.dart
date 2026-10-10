import 'dart:math';

import '../models/bili_meta.dart';
import '../models/media.dart';

/// 主页推荐流的一行。
///
/// **为什么不复用 [Media]**：推荐项只给「够显示」的那几个字段（标题 / UP 主 /
/// 时长 / 封面），没有分 P 列表也没有取流地址。真要塞进 `Media`，就得造一堆
/// 假字段（`tweetText` 当标题、`mediaIndex` 硬填 1），后面谁都得先猜这些
/// 假字段是不是真的。等用户真的选中某条，再由页面拿它的 `bvid` 走 `view`
/// 展开成分 P 列表，那才是 `Media`。
class BiliFeedItem {
  const BiliFeedItem({
    required this.bvid,
    required this.aid,
    required this.cid,
    required this.title,
    required this.upperName,
    required this.upperMid,
    required this.cover,
    required this.durationMs,
    required this.publishTime,
    required this.viewCount,
  });

  final String bvid;
  final int aid;
  final int cid;
  final String title;
  final String upperName;
  final int upperMid;
  final String cover;
  final int durationMs;
  final DateTime? publishTime;
  final int viewCount;

  /// 选中之后要拿去 `view` 展开的那个号。
  Media toSeedMedia() => Media(
    id: bvid,
    type: MediaType.video,
    url: '',
    previewUrl: cover,
    tweetId: bvid,
    tweetText: title,
    createdAt: publishTime,
    userId: upperMid.toString(),
    userName: upperName,
    source: 'bili',
    durationMs: durationMs,
    bili: BiliMeta(
      workTitle: title,
      partTitle: title,
      bvid: bvid,
      aid: aid.toString(),
      cid: cid.toString(),
      partTotal: 1,
    ),
  );

  @override
  String toString() => 'BiliFeedItem($bvid, ${title.length}字, ${durationMs}ms)';
}

/// 推荐流响应 → 可下载稿件的列表。
///
/// 只留 `goto == 'av'` 的条目：直播间、专栏、番剧入口、广告位在这个接口里
/// 混在同一份 `item` 数组里，字段形状不同（`room_info` / `ogv_info` 那种）。
/// **认不出来的一律跳过而不是硬解** —— 硬解的结果是把一条直播间当成稿件去
/// `view`，然后在几十条里报一个看不懂的错。
List<BiliFeedItem> biliFeedItems(Map<String, dynamic> data) {
  final raw = data['item'];
  if (raw is! List) return const [];
  final out = <BiliFeedItem>[];
  for (final e in raw.whereType<Map>()) {
    final j = e.cast<String, dynamic>();
    final bvid = (j['bvid'] as String? ?? '').trim();
    if (bvid.isEmpty) continue;
    if (j['goto'] != 'av') continue;
    out.add(BiliFeedItem(
      bvid: bvid,
      aid: _i(j['id']),
      cid: _i(j['cid']),
      title: (j['title'] as String? ?? '').trim(),
      upperName: _ownerName(j['owner']),
      upperMid: _i(j['owner']?['mid']),
      cover: _https((j['pic'] as String? ?? '').trim()),
      // 推荐流里的 `duration` 是**秒**，项目内部一律用毫秒
      durationMs: _i(j['duration']) * 1000,
      publishTime: _secondsToDate(j['pubdate']),
      viewCount: _i((j['stat'] as Map?)?['view']),
    ));
  }
  return out;
}

/// 从一批里随机取 [count] 条，**不重复**。
///
/// 验收要的就是这个：「从我主页推荐随机选三个视频」。抽干之后不补，
/// 所以 `count > items.length` 时返回全部（而不是抛或重复抽）。
List<T> sampleDistinct<T>(List<T> items, int count, Random rng) {
  if (items.isEmpty || count <= 0) return const [];
  final pool = items.toList();
  final picked = <T>[];
  while (picked.length < count && pool.isNotEmpty) {
    picked.add(pool.removeAt(rng.nextInt(pool.length)));
  }
  return picked;
}

int _i(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

String _ownerName(Object? owner) {
  if (owner is Map && owner['name'] is String) {
    return (owner['name'] as String).trim();
  }
  return '';
}

/// B 站的封面常给 `http://` 甚至 `//` 开头的协议相对地址。存成 `Media.previewUrl`
/// 之前补成 https —— 界面里 `<img>` 走 http 会被当作混合内容拦掉。
String _https(String url) {
  if (url.startsWith('//')) return 'https:$url';
  if (url.startsWith('http://')) return url.replaceFirst('http://', 'https://');
  return url;
}

DateTime? _secondsToDate(Object? v) {
  final s = _i(v);
  if (s <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(s * 1000);
}
