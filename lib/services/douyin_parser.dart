/// 抖音拦截载荷 → [Media]。
///
/// 输入是 [kDouyinInterceptorJs] 从页面里抄回来、已经压扁过的对象
/// （字段名见 `douyin_interceptor_js.dart` 的 `normalize()`）。
///
/// **为什么在这里才转成 `Media`：** 抖音的东西最终要和 X 的一起走
/// `Aria2Coordinator.enqueueMedia()` / 文件名模板 / 下载管理页，
/// 统一成同一个模型就只维护一条下载管线，不需要给抖音再写一套。
///
/// **这里只做「结构转换」，不做「下载源选择」。** 一条视频的全部
/// `bit_rate` 变体、图集的全部镜像、BGM 地址都会被保留下来
/// （`Media.variants`），等用户点下载时再由 `douyin_source.dart`
/// 按当时的清晰度设置挑 —— 否则改设置对已抓到的条目无效。
///
/// 字段映射。Media 沿用 X 的字段名（`tweetId` 等）是历史包袱，但界面上的
/// 变量表按平台拆过：抖音设置里只出现下面第三列这些抖音语义的变量。
/// 旧的 X 名变量（`%POST_ID%` / `%CONTENT%` / `%POST_TIME%`…）仍然能解析，
/// 只是为了让用户早年手写的模板不会在文件名里留下 `%XXX%` 残字。
///
/// | 抖音 | Media（借用 X 命名） | 抖音侧模板变量 |
/// | --- | --- | --- |
/// | `id` | `tweetId` | `%AWEME_ID%` |
/// | `desc` | `tweetText` | `%DESCRIPTION%` |
/// | `createTime` | `createdAt` | `%CREATE_TIME%` |
/// | `authorUid` | `userId` | `%AUTHOR_ID%` |
/// | `authorName` | `userName` | `%AUTHOR%` |
/// | `authorId` | `userScreenName` | `%AUTHOR_UNIQUE_ID%` |
/// | `tags` | `tags` | ——（不在抖音变量表里） |
/// | `digg` / `comment` / `collect` / `share` | 统计字段 | `%LIKE_COUNT%` 等 |
/// | `durationMs` | `durationMs` | `%DURATION%` |
/// | `episode` | `collectionEpisode` | ——（不在抖音变量表里） |
///
/// `source` 固定为 `douyin`（`%SOURCE%`）。
library;

import '../models/media.dart';
import '../models/media_variant.dart';

/// 一条拦截载荷解析出来的结果。
class DouyinParseResult {
  /// 转换后的媒体列表（图集已按张展开，实况图会多出配对视频）。
  final List<Media> media;

  /// 载荷里原始 aweme 条数（不含图集展开）。
  final int awemeCount;

  const DouyinParseResult(this.media, this.awemeCount);

  static const empty = DouyinParseResult(<Media>[], 0);
}

/// 把 Dart 侧收到的 `webMessage` 载荷解析成媒体。
///
/// 兼容三种形态：
///   - `{__pd: 'douyin', items: [...]}` —— 拦截脚本的正常输出
///   - `[...]`                          —— 直接是一个数组
///   - `{...}`                          —— 单条对象
DouyinParseResult parseDouyinPayload(dynamic payload) {
  final items = <dynamic>[];
  if (payload is Map) {
    final tagged = payload['__pd'];
    if (tagged != null) {
      final raw = payload['items'];
      if (raw is List) items.addAll(raw);
    } else if (payload['id'] != null) {
      items.add(payload);
    }
  } else if (payload is List) {
    items.addAll(payload);
  }

  final out = <Media>[];
  final ids = <String>{};
  var awemeCount = 0;

  for (final raw in items) {
    if (raw is! Map) continue;
    final map = raw.cast<String, dynamic>();
    final parsed = mediaFromAweme(map);
    if (parsed.isEmpty) continue;
    awemeCount++;
    for (final m in parsed) {
      // 同一次载荷内部也要去重：图集 + 视频混合时可能出现重复直链
      if (ids.add(m.id)) out.add(m);
    }
  }
  return DouyinParseResult(out, awemeCount);
}

/// 单条 aweme → 若干 [Media]。
///
/// 展开规则（对齐参照实现）：
///   - 视频 → 1 条视频媒体（候选含全部码率变体 + 指定编码字段 + BGM 变体）
///   - 图集 → 每张图 1 条图片媒体；**实况图**额外产出 1 条配对视频媒体，
///     两者 `mediaIndex` 相同 → 落盘后 `前缀_1.jpg` + `前缀_1.mp4` 天然配对
///   - 混合（既下图又下视频的图文）→ 两者都产出
///
/// **BGM 不作为独立条目产出** —— 参照实现是在「批量下载」组装阶段按
/// `mid` 去重后追加的，所以这里只把 BGM 地址挂成 `audio` 变体，
/// 由下载组装阶段决定要不要真的下一个音频文件。
List<Media> mediaFromAweme(Map<String, dynamic> j) {
  final id = _str(j['id']);
  if (id.isEmpty) return const [];

  final kind = _str(j['kind']);
  final desc = _str(j['desc']);
  final createdAt = _createdAt(j['createTime']);
  final cover = _str(j['cover']);
  final durationMs = _int(j['durationMs']) ?? 0;
  final episode = _int(j['episode']) ?? 0;

  final videoVariants = _variants(j['videos']);
  final imageEntries = _imageEntries(j['images']);
  final tags = _strList(j['tags']);

  final userId = _str(j['authorUid']);
  final userName = _str(j['authorName']);
  final authorId = _str(j['authorId']);

  // BGM：挂成 audio 变体。「仅音频」下载源与「附带 BGM」都用它。
  final musicUrls = _strList(j['musicUrls']);
  final audioVariant = musicUrls.isEmpty
      ? null
      : MediaVariant(urls: musicUrls, kind: VariantKind.audio);

  final digg = _int(j['digg']);
  final comment = _int(j['comment']);
  final collect = _int(j['collect']);
  final share = _int(j['share']);

  Media build({
    required String mediaId,
    required MediaType type,
    required String url,
    required int index,
    List<String> altUrls = const [],
    List<MediaVariant> variants = const [],
    int? width,
    int? height,
    int? dur,
  }) =>
      Media(
        id: mediaId,
        type: type,
        url: url,
        previewUrl: type == MediaType.image ? url : cover,
        width: width,
        height: height,
        tweetId: id,
        tweetText: desc,
        createdAt: createdAt,
        userId: userId.isEmpty ? null : userId,
        userName: userName.isEmpty ? null : userName,
        userScreenName: authorId.isEmpty ? null : authorId,
        tags: tags,
        mediaIndex: index,
        source: 'douyin',
        altUrls: altUrls,
        variants: variants,
        durationMs: dur,
        likeCount: digg,
        commentCount: comment,
        collectCount: collect,
        shareCount: share,
        collectionEpisode: episode,
      );

  final out = <Media>[];

  // ── 图集（含实况图的配对视频）─────────────────────────────
  for (var i = 0; i < imageEntries.length; i++) {
    final e = imageEntries[i];
    if (e.urls.isEmpty) continue;

    out.add(build(
      mediaId: '${id}_${i + 1}',
      type: MediaType.image,
      url: e.urls.first,
      index: i + 1,
      altUrls: e.urls.length > 1 ? e.urls.sublist(1) : const [],
      variants: [
        MediaVariant(urls: e.urls, kind: VariantKind.image),
        ?audioVariant,
      ],
    ));

    // 实况图：静态图 + 配对视频共用同一个 `mediaIndex`，
    // 所以 `%MEDIA_INDEX%%EXT%` 能拼出 `_1.jpg` / `_1.mp4` 这样的配对。
    if (e.live.isNotEmpty) {
      final liveUrls = _flatten(e.live);
      out.add(build(
        mediaId: '${id}_${i + 1}v',
        type: MediaType.video,
        url: liveUrls.first,
        index: i + 1,
        altUrls: liveUrls.length > 1 ? liveUrls.sublist(1) : const [],
        variants: [
          ...e.live,
          ?audioVariant,
        ],
        width: e.live.first.width,
        height: e.live.first.height,
      ));
    }
  }

  // ── 视频 ─────────────────────────────────────────────────
  final videoKinds = videoVariants
      .where((v) =>
          v.kind == VariantKind.bitRate || v.kind == VariantKind.defaultAddr)
      .toList(growable: false);

  if (videoKinds.isNotEmpty && kind != 'images') {
    final allUrls = _flatten(videoVariants);
    if (allUrls.isNotEmpty) {
      final first = videoKinds.first;
      out.add(build(
        mediaId: id,
        type: MediaType.video,
        url: allUrls.first,
        index: imageEntries.isEmpty ? 1 : imageEntries.length + 1,
        altUrls: allUrls.length > 1 ? allUrls.sublist(1) : const [],
        variants: [
          ...videoVariants,
          ?audioVariant,
        ],
        width: first.width,
        height: first.height,
        dur: durationMs,
      ));
    }
  }

  return out;
}

/// 图集条目：镜像列表 + 实况图的配对视频变体。
class _ImageEntry {
  final List<String> urls;
  final List<MediaVariant> live;

  const _ImageEntry(this.urls, this.live);
}

List<_ImageEntry> _imageEntries(dynamic raw) {
  if (raw is! List) return const [];
  final out = <_ImageEntry>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final map = e.cast<String, dynamic>();
    final urls = _strList(map['urls']);
    final live = _variants(map['live']);
    if (urls.isEmpty && live.isEmpty) continue;
    out.add(_ImageEntry(urls, live));
  }
  return out;
}

List<MediaVariant> _variants(dynamic raw) {
  if (raw is! List) return const [];
  final out = <MediaVariant>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final v = MediaVariant.fromJson(e.cast<String, dynamic>());
    if (v.usable) out.add(v);
  }
  return out;
}

/// 把变体列表压平成一串去重地址（首个即首选）。
List<String> _flatten(List<MediaVariant> variants) {
  final out = <String>[];
  for (final v in variants) {
    for (final u in v.urls) {
      if (u.isNotEmpty && !out.contains(u)) out.add(u);
    }
  }
  return out;
}

DateTime? _createdAt(dynamic raw) {
  final sec = _int(raw);
  if (sec == null || sec <= 0) return null;
  // 抖音的 create_time 是 Unix 秒（UTC），转成本地时区再喂给 `%CREATE_TIME%`
  return DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true).toLocal();
}

String _str(dynamic v) => v is String ? v : (v == null ? '' : v.toString());

int? _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

List<String> _strList(dynamic v) {
  if (v is! List) return const [];
  return v
      .map(_str)
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}
