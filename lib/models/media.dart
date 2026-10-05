/// X / 抖音媒体（图片 / 视频 / 音频）模型。
///
///  里的 `Media`。字段分三类：
///
/// **展示用**
///   - id           媒体唯一 id（用于去重与下载命名）
///   - type         'image' | 'video' | 'animated_gif' | 'audio'
///   - url          直链（图片原图 / 视频 mp4 / 音频 mp3）
///   - previewUrl   缩略图（用于网格预览）
///   - width/height 用于布局
///   - tweetId      所属推文 / 作品的 id
///   - tweetText    文本（hover 显示）
///   - createdAt    发布时间
///
/// **文件名模板用**（原版 `FileNameTemplateData` 的 media + post 两部分，
/// 这里拍平进 Media，省掉一层包装）
///   - userId / userName / userScreenName  发布者
///   - tags                                话题标签
///   - mediaIndex                          本条媒体在作品内的序号（从 1 起）
///   - source                              来源平台（`x` / `douyin`），`%SOURCE%` 用它
///   - durationMs / likeCount / commentCount / collectCount / shareCount
///                                         抖音统计字段，供文件名组件使用
///
/// **下载源选择用**
///   - variants    全部可选下载源（抖音多码率 / 多镜像）；X 为空
///   - chosen      下载时按用户设置挑中的那一个（决定分辨率/码率/帧率/大小）
library;

import 'media_variant.dart';

class Media {
  final String id;
  final MediaType type;
  final String url;
  final String? previewUrl;
  final int? width;
  final int? height;
  final String? tweetId;
  final String? tweetText;
  final DateTime? createdAt;
  final String? userId;
  final String? userName;
  final String? userScreenName;
  final List<String> tags;
  final int mediaIndex;

  /// 来源平台标识：`x`（默认，保持旧行为）或 `douyin`。
  final String source;

  /// 备用下载地址（同一条媒体在其它 CDN 节点 / 其它码率上的直链）。
  ///
  /// **为什么需要：** 抖音一条视频会同时下发多个 `play_addr`（不同 CDN 节点、
  /// 不同码率），而这些地址**并非都可用** —— 实测同一作品在
  /// `v26-web.douyinvod.com` 上无 Referer 返回 403、在 `v11-weba` 上却正常，
  /// 且链接带过期签名。这里的做法是「逐个尝试下载地址，全部失败才报错」，
  /// 这里用同一策略：首选 [url] 失败后依次换到备用源。
  ///
  /// X 的媒体没有这个需要，保持默认空列表。
  final List<String> altUrls;

  /// 全部可选下载源（抖音）。解析器填充，下载时由 `douyin_source.dart` 挑选。
  final List<MediaVariant> variants;

  /// 挑中的变体 —— 只在「下载时解析」这一步设置。
  ///
  /// `%RESOLUTION%` / `%BITRATE%` / `%FPS%` / `%FILE_SIZE%` 四个模板变量
  /// 读它；为空（X 的媒体）时退回 [width] / [height]。
  final MediaVariant? chosen;

  /// 视频时长，毫秒（抖音 `video.duration`）。X 没有。
  final int? durationMs;

  /// 抖音统计字段（`statistics`），供 `%LIKE_COUNT%` 等组件使用。
  final int? likeCount;
  final int? commentCount;
  final int? collectCount;
  final int? shareCount;

  /// 合集集数（`_collectionEpisode`）。抖音合集 / 短剧才有，0 表示不是合集。
  final int collectionEpisode;

  /// `%CUSTOM_TEXT%` 的输出内容 —— 下载时从设置里带进来。
  ///
  /// 与 [chosen] 同理：它是「下载时按当前设置解析」的结果，不是媒体自带属性。
  /// 对齐参照实现的「自定义文本」文件名组件。
  final String? customText;

  const Media({
    required this.id,
    required this.type,
    required this.url,
    this.previewUrl,
    this.width,
    this.height,
    this.tweetId,
    this.tweetText,
    this.createdAt,
    this.userId,
    this.userName,
    this.userScreenName,
    this.tags = const [],
    this.mediaIndex = 1,
    this.source = 'x',
    this.altUrls = const [],
    this.variants = const [],
    this.chosen,
    this.durationMs,
    this.likeCount,
    this.commentCount,
    this.collectCount,
    this.shareCount,
    this.collectionEpisode = 0,
    this.customText,
  });

  /// 复制并覆盖部分字段 —— 解析器先建对象、后补用户信息时用，
  /// 下载前的「按设置解析下载源」也用它。
  Media copyWith({
    MediaType? type,
    String? url,
    String? previewUrl,
    int? width,
    int? height,
    String? userId,
    String? userName,
    String? userScreenName,
    List<String>? tags,
    int? mediaIndex,
    String? source,
    List<String>? altUrls,
    List<MediaVariant>? variants,
    MediaVariant? chosen,
    int? durationMs,
    int? likeCount,
    int? commentCount,
    int? collectCount,
    int? shareCount,
    int? collectionEpisode,
    String? customText,
  }) =>
      Media(
        id: id,
        type: type ?? this.type,
        url: url ?? this.url,
        previewUrl: previewUrl ?? this.previewUrl,
        width: width ?? this.width,
        height: height ?? this.height,
        tweetId: tweetId,
        tweetText: tweetText,
        createdAt: createdAt,
        userId: userId ?? this.userId,
        userName: userName ?? this.userName,
        userScreenName: userScreenName ?? this.userScreenName,
        tags: tags ?? this.tags,
        mediaIndex: mediaIndex ?? this.mediaIndex,
        source: source ?? this.source,
        altUrls: altUrls ?? this.altUrls,
        variants: variants ?? this.variants,
        chosen: chosen ?? this.chosen,
        durationMs: durationMs ?? this.durationMs,
        likeCount: likeCount ?? this.likeCount,
        commentCount: commentCount ?? this.commentCount,
        collectCount: collectCount ?? this.collectCount,
        shareCount: shareCount ?? this.shareCount,
        collectionEpisode: collectionEpisode ?? this.collectionEpisode,
        customText: customText ?? this.customText,
      );

  /// 落盘用的 JSON（下载任务表持久化用）。
  ///
  /// **刻意不写 `variants` / `chosen` / `customText`**：这三样只在「按设置选源」
  /// 那一刻有意义，而下载任务里的 [url] 与文件名早已是选好之后的结果。
  /// 抖音一条视频的 variants 有十几项，写进去会让任务表膨胀好几倍。
  /// 换源重试只依赖 [downloadCandidates]（= `url` + `altUrls`），不受影响。
  ///
  /// 枚举写 `name`（`image` / `video` / `animatedGif` / `audio`），
  /// 不写 [MediaType.id]（`photo` / …）—— 后者是模板变量用的对外字面量，
  /// 拿来做持久化标识会在两套名字之间来回翻译。
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'url': url,
        if (previewUrl != null) 'previewUrl': previewUrl,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (tweetId != null) 'tweetId': tweetId,
        if (tweetText != null) 'tweetText': tweetText,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
        if (userId != null) 'userId': userId,
        if (userName != null) 'userName': userName,
        if (userScreenName != null) 'userScreenName': userScreenName,
        if (tags.isNotEmpty) 'tags': tags,
        'mediaIndex': mediaIndex,
        'source': source,
        if (altUrls.isNotEmpty) 'altUrls': altUrls,
        if (durationMs != null) 'durationMs': durationMs,
        if (likeCount != null) 'likeCount': likeCount,
        if (commentCount != null) 'commentCount': commentCount,
        if (collectCount != null) 'collectCount': collectCount,
        if (shareCount != null) 'shareCount': shareCount,
        if (collectionEpisode != 0) 'collectionEpisode': collectionEpisode,
      };

  /// [toJson] 的逆运算。缺字段一律回退默认值 —— 调用方（`DownloadStore`）
  /// 负责判断这一行是否「可用」（[id] 与 [url] 为空就丢弃）。
  factory Media.fromJson(Map<String, dynamic> j) => Media(
        id: j['id'] as String? ?? '',
        type: MediaType.values.firstWhere(
          (t) => t.name == (j['type'] as String?),
          orElse: () => MediaType.image,
        ),
        url: j['url'] as String? ?? '',
        previewUrl: j['previewUrl'] as String?,
        width: (j['width'] as num?)?.toInt(),
        height: (j['height'] as num?)?.toInt(),
        tweetId: j['tweetId'] as String?,
        tweetText: j['tweetText'] as String?,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
        userId: j['userId'] as String?,
        userName: j['userName'] as String?,
        userScreenName: j['userScreenName'] as String?,
        tags: (j['tags'] as List?)?.cast<String>() ?? const [],
        mediaIndex: (j['mediaIndex'] as num?)?.toInt() ?? 1,
        source: j['source'] as String? ?? 'x',
        altUrls: (j['altUrls'] as List?)?.cast<String>() ?? const [],
        durationMs: (j['durationMs'] as num?)?.toInt(),
        likeCount: (j['likeCount'] as num?)?.toInt(),
        commentCount: (j['commentCount'] as num?)?.toInt(),
        collectCount: (j['collectCount'] as num?)?.toInt(),
        shareCount: (j['shareCount'] as num?)?.toInt(),
        collectionEpisode: (j['collectionEpisode'] as num?)?.toInt() ?? 0,
      );

  String get extension {
    switch (type) {
      case MediaType.video:
        // 有变体时用变体自己的容器格式（通常是 mp4）
        return chosen?.extension ?? 'mp4';
      case MediaType.audio:
        return chosen?.extension ?? 'mp3';
      case MediaType.animatedGif:
        return 'gif';
      case MediaType.image:
        // 抖音的图集直链常常没有后缀（走参数决定格式），退回 jpeg
        final ext = _extOf(url);
        if (ext.isNotEmpty) return ext;
        return source == 'douyin' ? 'jpeg' : 'jpg';
    }
  }

  static String _extOf(String u) {
    if (u.isEmpty) return '';
    final path = u.split('?').first;
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '';
    final tail = path.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(tail) ? tail : '';
  }

  /// 真正的下载直链。
  ///
  /// **X 的图片必须补上 `?name=orig`**：X 的 CDN 在缺省 `name` 参数时返回的是
  /// 压缩过的预览图（原版 `getDownloadUrl()` 就是这么做并且用 `orig`）。
  ///
  /// 注意**只对 X 生效** —— 抖音的图集直链自带 `?from=...&name=...` 之类参数，
  /// 强行塞 `name=orig` 会改变 CDN 的取图逻辑。视频 / 音频 / GIF 用的已经是
  /// 挑好的直链，原样返回。
  String get downloadUrl {
    if (source != 'x' || type != MediaType.image || url.isEmpty) return url;
    final u = Uri.tryParse(url);
    if (u == null) return url;
    return u.replace(queryParameters: {
      ...u.queryParameters,
      'name': 'orig',
    }).toString();
  }

  /// 依次尝试的下载地址：首选 [downloadUrl] 在前，[altUrls] 在后。
  ///
  /// 下载失败时由 `Aria2Coordinator` 按这个顺序换源（对齐参照实现
  /// 「正在尝试同源其它下载地址」的行为）。
  List<String> get downloadCandidates {
    final primary = downloadUrl;
    final out = <String>[primary];
    for (final u in altUrls) {
      if (u.isNotEmpty && !out.contains(u)) out.add(u);
    }
    return out;
  }

  /// 安全的下载文件名（避免 Windows 路径非法字符）。
  ///
  /// **只作兜底**：正常路径是 `file_name_template.resolveVariables()` 按用户
  /// 设置的模板生成文件名；模板为空时才退回到这个 `id_时间戳.ext` 形式。
  String get safeFileName {
    final ts = createdAt != null
        ? '_${createdAt!.toIso8601String().substring(0, 19).replaceAll(RegExp(r'[^0-9]'), '')}'
        : '';
    return '$id$ts.$extension';
  }

  /// 用于筛选 / 搜索的合并文本（作品描述 + 作者 + 标签）。
  ///
  /// 关键词匹配的口径：不区分大小写，命中描述即算匹配。
  String get searchText =>
      [tweetText ?? '', userName ?? '', userScreenName ?? '', ...tags].join(' ');
}

enum MediaType {
  image,
  video,
  animatedGif,

  /// 音频（抖音 BGM / 「仅音频」模式）。X 没有。
  audio;

  /// 与原版 `MediaType` 枚举值一致的字面量（`%MEDIA_TYPE%` 用它）。
  String get id => switch (this) {
        MediaType.image => 'photo',
        MediaType.video => 'video',
        MediaType.animatedGif => 'animated_gif',
        MediaType.audio => 'audio',
      };

  bool get isVideo => this == video || this == animatedGif;
  bool get isImage => this == image;
  bool get isAudio => this == audio;
}
