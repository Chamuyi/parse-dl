/// B 站下载配置 —— 「B 站解析下载」这一组选项。
///
/// 形状对齐 [DouyinConfig]：同样是「取流偏好 + 附属开关 + 保存与命名」三段，
/// 用户在三个模块之间不用换脑子。
///
/// **刻意没有 cookie 字段**：B 站登录态只活在运行时（内嵌 WebView2 的会话里），
/// 不进 `settings.json`。大会员内容的取流凭据一旦落盘，就等于把账号写进了
/// 一个会被同步、被备份、被截图的普通文本文件。
library;

import 'douyin_config.dart' show DouyinConfig;

/// 画质上限 —— 与 B 站 `qn` 取值对齐，实际能拿到哪档由账号权限决定。
///
/// 这里存的是**上限**而不是档位：B 站会在 `playurl` 的 `support_formats` 里
/// 按账号裁掉无权的高阶档，所以「选 1080P60 却只拿到 1080P」是正常结果，
/// 不是 bug。参照实现也是这么处理的（取 `dash.video` 实际最高档再裁）。
enum BiliQuality {
  highest('highest', 127, '最高可用'),
  q8k('8k', 127, '8K'),
  q4k('4k', 120, '4K'),
  q1080p60('1080p60', 116, '1080P 60帧'),
  q1080('1080p', 80, '1080P'),
  q720('720p', 64, '720P'),
  q480('480p', 32, '480P'),
  q360('360p', 16, '360P');

  const BiliQuality(this.id, this.qn, this.label);

  /// 持久化标识 —— 进了 `settings.json` 就不能改。
  final String id;

  /// 请求 `playurl` 时传的 `qn`。
  final int qn;

  final String label;

  static BiliQuality fromId(String? id) => BiliQuality.values.firstWhere(
    (e) => e.id == id,
    orElse: () => BiliQuality.highest,
  );
}

/// 编码偏好。B 站同画质常同时给 AVC / HEVC / AV1 三条流，
/// 选哪条影响**能不能合并**与**播放兼容性**，不影响清晰度。
enum BiliCodec {
  auto('auto', '自动（兼容性优先）'),
  avc('avc', 'H.264 / AVC'),
  hevc('hevc', 'H.265 / HEVC'),
  av1('av1', 'AV1');

  const BiliCodec(this.id, this.label);

  final String id;
  final String label;

  static BiliCodec fromId(String? id) => BiliCodec.values.firstWhere(
    (e) => e.id == id,
    orElse: () => BiliCodec.auto,
  );
}

/// 合并产物用的容器。
///
/// **只有开了合并才有意义**：DASH 的两条裸流各自落成 `.video.m4s` /
/// `.audio.m4s`，容器名是 ffmpeg 那一步才用上的（见 [BiliConfig.mergeAfterDownload]）。
/// MKV 相对 MP4 的唯一硬优势是装得下 ASS 字幕轨，画质与兼容性都不占便宜，
/// 所以默认仍是 MP4。
enum BiliContainer {
  mp4('mp4', 'MP4（兼容性最好）'),
  mkv('mkv', 'MKV（可内封字幕轨）');

  const BiliContainer(this.id, this.label);

  /// 持久化标识，同时就是产物扩展名 —— 进了 `settings.json` 就不能改。
  final String id;

  final String label;

  static BiliContainer fromId(String? id) => BiliContainer.values.firstWhere(
    (e) => e.id == id,
    orElse: () => BiliContainer.mp4,
  );
}

/// 弹幕落盘格式。
///
/// 只有 [ass] 能作为字幕轨内封进 MKV，xml 与 json 永远是侧文件
/// —— 这不是实现没做到，是容器只认 text_ass/vobsub 这类字幕轨。
enum BiliDanmakuFormat {
  ass('ass', 'ASS（可内封）'),
  xml('xml', 'XML（弹姬格式）'),
  json('json', 'JSON');

  const BiliDanmakuFormat(this.id, this.label);

  final String id;

  final String label;

  static BiliDanmakuFormat fromId(String? id) =>
      BiliDanmakuFormat.values.firstWhere(
        (e) => e.id == id,
        orElse: () => BiliDanmakuFormat.ass,
      );
}

/// 字幕落盘格式。同样只有 [ass] 谈得上内封。
enum BiliSubtitleFormat {
  srt('srt', 'SRT'),
  ass('ass', 'ASS（可内封）'),
  txt('txt', 'TXT（纯文本）');

  const BiliSubtitleFormat(this.id, this.label);

  final String id;

  final String label;

  static BiliSubtitleFormat fromId(String? id) =>
      BiliSubtitleFormat.values.firstWhere(
        (e) => e.id == id,
        orElse: () => BiliSubtitleFormat.srt,
      );
}

/// 封面格式。B 站图床按 `@.{后缀}` 的缩放语法出图，四种都能直接要到。
enum BiliCoverFormat {
  jpg('jpg', 'JPG'),
  png('png', 'PNG'),
  webp('webp', 'WebP'),
  avif('avif', 'AVIF');

  const BiliCoverFormat(this.id, this.label);

  final String id;

  final String label;

  static BiliCoverFormat fromId(String? id) =>
      BiliCoverFormat.values.firstWhere(
        (e) => e.id == id,
        orElse: () => BiliCoverFormat.jpg,
      );
}

/// 元数据格式。nfo 给媒体库软件读，json 是我们自己那份解析结果的完整转储。
enum BiliMetadataFormat {
  nfo('nfo', 'NFO（媒体库）'),
  json('json', 'JSON');

  const BiliMetadataFormat(this.id, this.label);

  final String id;

  final String label;

  static BiliMetadataFormat fromId(String? id) =>
      BiliMetadataFormat.values.firstWhere(
        (e) => e.id == id,
        orElse: () => BiliMetadataFormat.nfo,
      );
}

/// 弹幕与字幕同名时的先后。
///
/// 两族都是 ASS 时会在同一个目录里撞名（同一语言标签），谁在前谁占 0 号字幕轨，
/// 文件名限定词也按这个顺序排。
enum BiliTrackPriority {
  subtitleFirst('subtitle', '字幕优先'),
  danmakuFirst('danmaku', '弹幕优先');

  const BiliTrackPriority(this.id, this.label);

  final String id;

  final String label;

  static BiliTrackPriority fromId(String? id) =>
      BiliTrackPriority.values.firstWhere(
        (e) => e.id == id,
        orElse: () => BiliTrackPriority.subtitleFirst,
      );
}

/// B 站页的下载配置。
class BiliConfig {
  /// 画质上限
  BiliQuality quality;

  /// 编码偏好
  BiliCodec codec;

  /// 下载完用 ffmpeg 把视频流 + 音频流合并成单个 mp4。
  ///
  /// 关掉就是留 `xxx.m4s` 两个裸文件：DASH 的两条流各自都不是可独立播放的
  /// 完整文件，所以默认必须合并。留这个开关是因为合并依赖随包的 ffmpeg ——
  /// 它被安全软件拦下时，用户至少能拿到原始流自己处理。
  bool mergeAfterDownload;

  /// 「跳过已下载」—— 按 `bvid + cid` 台账跳过。
  bool skipDownloaded;

  /// 把同一稿件的多个分 P 排在连续位置（默认开）
  bool groupByWork;

  /// aria2 并发数
  int concurrency;

  /// `%CUSTOM_TEXT%` 的输出内容
  String customText;

  // ── 保存与命名 ──────────────────────────────────────────────

  /// 保存根目录。**空 = 沿用另一处已设过的根目录**（同 [DouyinConfig.saveDirBase]）。
  String saveDirBase;

  /// **启用保存文件夹**：开 = 按 [dirTemplate] 建子目录；关 = 平铺。
  bool enableSaveFolder;

  /// 文件夹模板 —— 界面可用变量是 B 站那 18 个（`kBiliTemplateVars`）。
  String dirTemplate;

  /// 文件模板。
  String fileNameTemplate;

  // ── 外部依赖 ────────────────────────────────────────────────

  /// **外挂 ffmpeg 所在目录**（用户自己指定）。**空 = 用随包那份**。
  ///
  /// 为什么要有这个：随包那份是 10 MB 白名单构建（只有 mp4/mkv 直拷所需的那点
  /// 能力，没有 h264/hevc 编码器、没有 ffprobe、网络被禁）。用户想用完整版
  /// ffmpeg（217 MB）时不该被迫重打安装包 —— 指一个目录就能接管。
  ///
  /// 取值是**目录**而不是 exe 全路径：完整构建的压缩包里层级固定
  /// （`…/bin/ffmpeg.exe`），让用户去指到 exe 容易指错一层。目录里有
  /// `ffmpeg.exe` 或 `bin/ffmpeg.exe` 都认（见 [BiliMerger.resolvePath]）。
  String ffmpegDir;

  // ── 容器与限速 ──────────────────────────────────────────────

  /// 合并产物容器。关合并时这个字段不参与落名。
  BiliContainer container;

  /// 每条任务的下载限速，单位 KB/s。**0 = 不限**。
  ///
  /// 走 aria2 的 per-task option `max-download-limit`，不是全局启动参数 ——
  /// 全局那条会牵连 X 与抖音两个队列。
  int speedLimitKbps;

  // ── 附加文件 ────────────────────────────────────────────────

  /// 弹幕总开关。关掉时下面几个弹幕字段一律不参与任何请求。
  bool saveDanmaku;

  BiliDanmakuFormat danmakuFormat;

  /// 弹幕渲染样式。**只在 [danmakuFormat] == [BiliDanmakuFormat.ass] 时生效**，
  /// xml 与 json 是把接口给的原样信息落盘，没有排版这一步。
  String danmakuFontFace;
  int danmakuFontSize;

  /// 不透明度，0~100 的整数百分比（与界面滑条同一口径，避免两处各存一套小数）。
  int danmakuOpacity;

  /// 底部边距（像素，ASS 的 MarginV）。
  int danmakuMarginV;

  /// 字幕总开关。
  bool saveSubtitle;

  BiliSubtitleFormat subtitleFormat;

  /// 只要这几种语言；**空列表 = 不做筛选，有几条取几条**。
  List<String> subtitleLangs;

  /// 「仅人工字幕」：AI 生成的那条语言码带 `ai-` 前缀，关掉它就不取。
  ///
  /// 需要登录 —— 未登录时 B 站根本不返回 AI 字幕，所以这个开关在匿名态下
  /// 没有可观测效果，不要为了它去提示用户登录。
  bool subtitleManualOnly;

  /// 封面总开关。
  bool saveCover;

  BiliCoverFormat coverFormat;

  /// 章节总开关：把稿件的分段信息写进成品的章节表。
  bool saveChapter;

  /// 元数据总开关。
  bool saveMetadata;

  BiliMetadataFormat metadataFormat;

  /// 把 ass 字幕作为内封轨塞进成品，而不是只留侧文件。
  ///
  /// 生效前提有三个：容器是 MKV、开了合并、格式是 ass。缺任何一条这个开关都
  /// 是无效项 —— 界面上要**写明缺的是哪一条**，不许像参照实现那样静默跳过。
  bool embedSubtitleTrack;

  /// 弹幕与字幕撞名时的先后。
  BiliTrackPriority trackPriority;

  BiliConfig({
    this.quality = BiliQuality.highest,
    this.codec = BiliCodec.auto,
    this.mergeAfterDownload = true,
    this.skipDownloaded = true,
    this.groupByWork = true,
    this.concurrency = 4,
    this.customText = '',
    this.saveDirBase = '',
    this.enableSaveFolder = true,
    this.dirTemplate = kBiliDefaultDirTemplate,
    this.fileNameTemplate = kBiliDefaultFileNameTemplate,
    this.ffmpegDir = '',
    this.container = BiliContainer.mp4,
    this.speedLimitKbps = 0,
    this.saveDanmaku = false,
    this.danmakuFormat = BiliDanmakuFormat.ass,
    this.danmakuFontFace = kBiliDefaultDanmakuFontFace,
    this.danmakuFontSize = kBiliDefaultDanmakuFontSize,
    this.danmakuOpacity = kBiliDefaultDanmakuOpacity,
    this.danmakuMarginV = kBiliDefaultDanmakuMarginV,
    this.saveSubtitle = false,
    this.subtitleFormat = BiliSubtitleFormat.srt,
    this.subtitleLangs = const [],
    this.subtitleManualOnly = false,
    this.saveCover = false,
    this.coverFormat = BiliCoverFormat.jpg,
    this.saveChapter = false,
    this.saveMetadata = false,
    this.metadataFormat = BiliMetadataFormat.nfo,
    this.embedSubtitleTrack = false,
    this.trackPriority = BiliTrackPriority.subtitleFirst,
  });

  factory BiliConfig.fromJson(Map<String, dynamic> j) => BiliConfig(
    quality: BiliQuality.fromId(j['quality'] as String?),
    codec: BiliCodec.fromId(j['codec'] as String?),
    mergeAfterDownload: j['mergeAfterDownload'] as bool? ?? true,
    skipDownloaded: j['skipDownloaded'] as bool? ?? true,
    groupByWork: j['groupByWork'] as bool? ?? true,
    concurrency: (j['concurrency'] as num?)?.toInt() ?? 4,
    customText: j['customText'] as String? ?? '',
    saveDirBase: j['saveDirBase'] as String? ?? '',
    ffmpegDir: j['ffmpegDir'] as String? ?? '',
    enableSaveFolder: j['enableSaveFolder'] as bool? ?? true,
    dirTemplate: j['dirTemplate'] as String? ?? kBiliDefaultDirTemplate,
    // 一次性迁移：盘上存的**恰好是旧默认串**时升到新默认（见 migrateBiliTemplate）。
    // 挂在这里而不是别处，是因为「读设置」是唯一能同时看到旧值与新默认的地方；
    // 用户自己改过的模板不会被碰（判据收窄到全串相等）。
    fileNameTemplate: migrateBiliTemplate(
      fileNameTemplate: j['fileNameTemplate'] as String? ??
          kBiliDefaultFileNameTemplate,
      dirTemplate: j['dirTemplate'] as String? ?? kBiliDefaultDirTemplate,
    ),
    container: BiliContainer.fromId(j['container'] as String?),
    speedLimitKbps: (j['speedLimitKbps'] as num?)?.toInt() ?? 0,
    saveDanmaku: j['saveDanmaku'] as bool? ?? false,
    danmakuFormat: BiliDanmakuFormat.fromId(j['danmakuFormat'] as String?),
    danmakuFontFace: j['danmakuFontFace'] as String? ??
        kBiliDefaultDanmakuFontFace,
    danmakuFontSize: (j['danmakuFontSize'] as num?)?.toInt() ??
        kBiliDefaultDanmakuFontSize,
    danmakuOpacity: (j['danmakuOpacity'] as num?)?.toInt() ??
        kBiliDefaultDanmakuOpacity,
    danmakuMarginV: (j['danmakuMarginV'] as num?)?.toInt() ??
        kBiliDefaultDanmakuMarginV,
    saveSubtitle: j['saveSubtitle'] as bool? ?? false,
    subtitleFormat: BiliSubtitleFormat.fromId(j['subtitleFormat'] as String?),
    subtitleLangs: (j['subtitleLangs'] as List?)?.whereType<String>().toList() ??
        const [],
    subtitleManualOnly: j['subtitleManualOnly'] as bool? ?? false,
    saveCover: j['saveCover'] as bool? ?? false,
    coverFormat: BiliCoverFormat.fromId(j['coverFormat'] as String?),
    saveChapter: j['saveChapter'] as bool? ?? false,
    saveMetadata: j['saveMetadata'] as bool? ?? false,
    metadataFormat:
        BiliMetadataFormat.fromId(j['metadataFormat'] as String?),
    embedSubtitleTrack: j['embedSubtitleTrack'] as bool? ?? false,
    trackPriority: BiliTrackPriority.fromId(j['trackPriority'] as String?),
  );

  Map<String, dynamic> toJson() => {
    'quality': quality.id,
    'codec': codec.id,
    'mergeAfterDownload': mergeAfterDownload,
    'skipDownloaded': skipDownloaded,
    'groupByWork': groupByWork,
    'concurrency': concurrency,
    'customText': customText,
    'saveDirBase': saveDirBase,
    'enableSaveFolder': enableSaveFolder,
    'dirTemplate': dirTemplate,
    'fileNameTemplate': fileNameTemplate,
    'ffmpegDir': ffmpegDir,
    'container': container.id,
    'speedLimitKbps': speedLimitKbps,
    'saveDanmaku': saveDanmaku,
    'danmakuFormat': danmakuFormat.id,
    'danmakuFontFace': danmakuFontFace,
    'danmakuFontSize': danmakuFontSize,
    'danmakuOpacity': danmakuOpacity,
    'danmakuMarginV': danmakuMarginV,
    'saveSubtitle': saveSubtitle,
    'subtitleFormat': subtitleFormat.id,
    'subtitleLangs': subtitleLangs,
    'subtitleManualOnly': subtitleManualOnly,
    'saveCover': saveCover,
    'coverFormat': coverFormat.id,
    'saveChapter': saveChapter,
    'saveMetadata': saveMetadata,
    'metadataFormat': metadataFormat.id,
    'embedSubtitleTrack': embedSubtitleTrack,
    'trackPriority': trackPriority.id,
  };

  /// 覆盖副本 —— 下载选项弹窗返回的就是这个：只改点到的格子，其余原样带走。
  ///
  /// 传 null 表示「这一格没动」，所以字段值本身不能以 null 为合法取值。
  /// [subtitleLangs] 给空列表是合法的「清空筛选」，靠 `??` 区分不了没动和清空，
  /// 所以它不带 null 语义：要么传新列表，要么整个不写。
  BiliConfig copyWith({
    BiliQuality? quality,
    BiliCodec? codec,
    bool? mergeAfterDownload,
    bool? skipDownloaded,
    bool? groupByWork,
    int? concurrency,
    String? customText,
    String? saveDirBase,
    String? ffmpegDir,
    bool? enableSaveFolder,
    String? dirTemplate,
    String? fileNameTemplate,
    BiliContainer? container,
    int? speedLimitKbps,
    bool? saveDanmaku,
    BiliDanmakuFormat? danmakuFormat,
    String? danmakuFontFace,
    int? danmakuFontSize,
    int? danmakuOpacity,
    int? danmakuMarginV,
    bool? saveSubtitle,
    BiliSubtitleFormat? subtitleFormat,
    List<String>? subtitleLangs,
    bool? subtitleManualOnly,
    bool? saveCover,
    BiliCoverFormat? coverFormat,
    bool? saveChapter,
    bool? saveMetadata,
    BiliMetadataFormat? metadataFormat,
    bool? embedSubtitleTrack,
    BiliTrackPriority? trackPriority,
  }) => BiliConfig(
    quality: quality ?? this.quality,
    codec: codec ?? this.codec,
    mergeAfterDownload: mergeAfterDownload ?? this.mergeAfterDownload,
    skipDownloaded: skipDownloaded ?? this.skipDownloaded,
    groupByWork: groupByWork ?? this.groupByWork,
    concurrency: concurrency ?? this.concurrency,
    customText: customText ?? this.customText,
    saveDirBase: saveDirBase ?? this.saveDirBase,
    enableSaveFolder: enableSaveFolder ?? this.enableSaveFolder,
    dirTemplate: dirTemplate ?? this.dirTemplate,
    fileNameTemplate: fileNameTemplate ?? this.fileNameTemplate,
    ffmpegDir: ffmpegDir ?? this.ffmpegDir,
    container: container ?? this.container,
    speedLimitKbps: speedLimitKbps ?? this.speedLimitKbps,
    saveDanmaku: saveDanmaku ?? this.saveDanmaku,
    danmakuFormat: danmakuFormat ?? this.danmakuFormat,
    danmakuFontFace: danmakuFontFace ?? this.danmakuFontFace,
    danmakuFontSize: danmakuFontSize ?? this.danmakuFontSize,
    danmakuOpacity: danmakuOpacity ?? this.danmakuOpacity,
    danmakuMarginV: danmakuMarginV ?? this.danmakuMarginV,
    saveSubtitle: saveSubtitle ?? this.saveSubtitle,
    subtitleFormat: subtitleFormat ?? this.subtitleFormat,
    subtitleLangs: subtitleLangs ?? this.subtitleLangs,
    subtitleManualOnly: subtitleManualOnly ?? this.subtitleManualOnly,
    saveCover: saveCover ?? this.saveCover,
    coverFormat: coverFormat ?? this.coverFormat,
    saveChapter: saveChapter ?? this.saveChapter,
    saveMetadata: saveMetadata ?? this.saveMetadata,
    metadataFormat: metadataFormat ?? this.metadataFormat,
    embedSubtitleTrack: embedSubtitleTrack ?? this.embedSubtitleTrack,
    trackPriority: trackPriority ?? this.trackPriority,
  );

  /// 把 [src] 的每一项搬进自己。**同步为默认**走的就是这一条。
  ///
  /// 刻意逐字段赋值而不是换对象：`SettingsStore.setBili` 给的是
  /// 「拿到那一份活的配置改它」的写法，别处（下载管理、设置页）正 watch 着同一个
  /// 对象，换成新对象会让它们看的是旧的。
  void applyFrom(BiliConfig src) {
    quality = src.quality;
    codec = src.codec;
    mergeAfterDownload = src.mergeAfterDownload;
    skipDownloaded = src.skipDownloaded;
    groupByWork = src.groupByWork;
    concurrency = src.concurrency;
    customText = src.customText;
    saveDirBase = src.saveDirBase;
    enableSaveFolder = src.enableSaveFolder;
    dirTemplate = src.dirTemplate;
    fileNameTemplate = src.fileNameTemplate;
    ffmpegDir = src.ffmpegDir;
    container = src.container;
    speedLimitKbps = src.speedLimitKbps;
    saveDanmaku = src.saveDanmaku;
    danmakuFormat = src.danmakuFormat;
    danmakuFontFace = src.danmakuFontFace;
    danmakuFontSize = src.danmakuFontSize;
    danmakuOpacity = src.danmakuOpacity;
    danmakuMarginV = src.danmakuMarginV;
    saveSubtitle = src.saveSubtitle;
    subtitleFormat = src.subtitleFormat;
    subtitleLangs = List.of(src.subtitleLangs);
    subtitleManualOnly = src.subtitleManualOnly;
    saveCover = src.saveCover;
    coverFormat = src.coverFormat;
    saveChapter = src.saveChapter;
    saveMetadata = src.saveMetadata;
    metadataFormat = src.metadataFormat;
    embedSubtitleTrack = src.embedSubtitleTrack;
    trackPriority = src.trackPriority;
  }

  /// 内封字幕轨的前提缺了哪一条。
  ///
  /// 返回 null = 可以内封；否则给出还差什么，**由界面原样显示**。
  /// 参照实现在这里的做法是「条件不满足就静默跳过」，用户勾了内封却在成品里
  /// 找不到轨，也没有任何地方告诉他为什么 —— 我们不跟这一条。
  ///
  /// 三个前提都是硬的：MP4 容器装不下 ASS 字幕轨；不合并就没有成品容器可塞；
  /// 非 ass 格式（srt / xml / json）ffmpeg 塞不进 matroska 的文本字幕轨。
  List<String>? embedBlockReason({required bool forDanmaku}) {
    final missing = <String>[];
    if (container != BiliContainer.mkv) missing.add('容器要选 MKV');
    if (!mergeAfterDownload) missing.add('要开「合并音视频流」');
    if (forDanmaku) {
      if (danmakuFormat != BiliDanmakuFormat.ass) missing.add('弹幕格式要选 ASS');
    } else {
      if (subtitleFormat != BiliSubtitleFormat.ass) missing.add('字幕格式要选 ASS');
    }
    return missing.isEmpty ? null : missing;
  }

  /// 是否全部保持默认值。
  ///
  /// `CollapsibleGroup` 那边有个 `modified` 小圆点的渲染分支，但**目前全仓没有
  /// 任何调用点传它**，所以这个 getter 现在只被测试用作「改过任何一项就要翻
  /// false」的判据，不要对外宣称界面上有圆点。
  bool get isDefault =>
      quality == BiliQuality.highest &&
      codec == BiliCodec.auto &&
      mergeAfterDownload &&
      skipDownloaded &&
      groupByWork &&
      concurrency == 4 &&
      customText.isEmpty &&
      saveDirBase.isEmpty &&
      enableSaveFolder &&
      dirTemplate == kBiliDefaultDirTemplate &&
      fileNameTemplate == kBiliDefaultFileNameTemplate &&
      ffmpegDir.isEmpty &&
      container == BiliContainer.mp4 &&
      speedLimitKbps == 0 &&
      !saveDanmaku &&
      danmakuFormat == BiliDanmakuFormat.ass &&
      danmakuFontFace == kBiliDefaultDanmakuFontFace &&
      danmakuFontSize == kBiliDefaultDanmakuFontSize &&
      danmakuOpacity == kBiliDefaultDanmakuOpacity &&
      danmakuMarginV == kBiliDefaultDanmakuMarginV &&
      !saveSubtitle &&
      subtitleFormat == BiliSubtitleFormat.srt &&
      subtitleLangs.isEmpty &&
      !subtitleManualOnly &&
      !saveCover &&
      coverFormat == BiliCoverFormat.jpg &&
      !saveChapter &&
      !saveMetadata &&
      metadataFormat == BiliMetadataFormat.nfo &&
      !embedSubtitleTrack &&
      trackPriority == BiliTrackPriority.subtitleFirst;
}

/// 弹幕 ass 默认字体。libass 按系统字体名找，中文环境下这个比字体族名更靠得住。
const String kBiliDefaultDanmakuFontFace = 'Microsoft YaHei';

const int kBiliDefaultDanmakuFontSize = 25;

const int kBiliDefaultDanmakuOpacity = 100;

const int kBiliDefaultDanmakuMarginV = 10;

/// 默认文件夹模板：一个稿件一个目录。
const String kBiliDefaultDirTemplate = '%WORK_TITLE%';

/// 默认文件名模板：`冬天-1080P60.mp4`。
///
/// **刻意不带 `%CODEC%`**：B 站同一个稿件的编码族（AVC / HEVC / AV1）对用户
/// 来说通常没有意义，而标题里本来就常带 `4K`、`3840x2160` 这类字样 ——
/// 再拼一个编码后缀，文件名会长到一眼看不懂、也更容易撞 Windows 的 260 字符。
/// 想标编码的人可以在设置里用「启用模版」预设切到别的组合。
///
/// **也没有 `<P%P%->` 前缀**：默认目录模板已经是「一个稿件一个目录」，
/// 目录名就是作品标题，文件名再加一遍分 P 号是冗余。多 P 稿件想区分分 P 时
/// 换「按 BV 号分文件夹」那份预设即可（它保留了 `P%P%`）。
const String kBiliDefaultFileNameTemplate = '%PART_TITLE%-%QUALITY%%EXT%';

/// 上一版的默认文件名模板。**只为一次性迁移而存在**（见 [migrateBiliTemplate]）。
///
/// 用户在盘上存过这个串、且从未自己改过时，才把它升级成新默认 ——
/// 判据收窄成「恰好等于旧默认串」，他自己改过的值一律不动。
/// 这是 `project-downloader-settings-defaults-trap` 那条教训的落地：
/// 光改默认值对老配置**不产生任何效果**，而且测试抓不到。
const String kBiliLegacyFileNameTemplate =
    '<P%P%->%PART_TITLE%-%QUALITY%-%CODEC%%EXT%';

/// 旧文件名模板 → 新默认。**只在值恰好等于旧默认串时才换**，否则原样返回。
///
/// 纯函数，可单测：迁移判断最容易写错的地方是「顺手把用户自己的也改了」，
/// 而那在本机上是不可逆的（他手改过的模板会被悄悄覆盖）。
String migrateBiliTemplate({
  required String fileNameTemplate,
  required String dirTemplate,
}) {
  final legacyName = fileNameTemplate == kBiliLegacyFileNameTemplate;
  final legacyDir = dirTemplate == kBiliDefaultDirTemplate;
  // 两条都还是出厂值 → 整份升到新默认（目录模板这一版没变，保留原样）
  if (legacyName && legacyDir) return kBiliDefaultFileNameTemplate;
  // 只文件名是出厂值 → 单换文件名
  if (legacyName) return kBiliDefaultFileNameTemplate;
  return fileNameTemplate;
}

/// 「启用模版」预设 —— 与抖音那份同构，选完仍可手动微调。
class BiliTemplatePreset {
  const BiliTemplatePreset({
    required this.id,
    required this.label,
    required this.dirTemplate,
    required this.fileNameTemplate,
  });

  final String id;
  final String label;
  final String dirTemplate;
  final String fileNameTemplate;
}

/// 「自定义」在下拉里的标识 —— 模板被手动改过、不匹配任何预设时用它。
const String kBiliCustomPresetId = 'custom';

const List<BiliTemplatePreset> kBiliTemplatePresets = [
  BiliTemplatePreset(
    id: 'work',
    label: '按作品分文件夹（推荐）',
    dirTemplate: kBiliDefaultDirTemplate,
    fileNameTemplate: kBiliDefaultFileNameTemplate,
  ),
  BiliTemplatePreset(
    id: 'up',
    label: '按「UP 主 / 作品」两级文件夹',
    dirTemplate: '%UP_NAME%/%WORK_TITLE%',
    fileNameTemplate: '<P%P%->%PART_TITLE%%EXT%',
  ),
  BiliTemplatePreset(
    id: 'flat',
    label: '全部平铺（不建子文件夹）',
    dirTemplate: '',
    fileNameTemplate: '%WORK_TITLE%<-%PART_TITLE%>-%QUALITY%%EXT%',
  ),
  BiliTemplatePreset(
    id: 'bvid',
    label: '按 BV 号分文件夹',
    dirTemplate: '%BVID%',
    fileNameTemplate: '<P%P%->%PART_TITLE%-%QUALITY%-%CODEC%%EXT%',
  ),
];
