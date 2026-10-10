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
    enableSaveFolder: j['enableSaveFolder'] as bool? ?? true,
    dirTemplate: j['dirTemplate'] as String? ?? kBiliDefaultDirTemplate,
    fileNameTemplate: j['fileNameTemplate'] as String? ??
        kBiliDefaultFileNameTemplate,
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
  };

  /// 与默认值不同的项数 —— 设置区折叠时点「已修改」小圆点用。
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
      fileNameTemplate == kBiliDefaultFileNameTemplate;
}

/// 默认文件夹模板：一个稿件一个目录。
const String kBiliDefaultDirTemplate = '%WORK_TITLE%';

/// 默认文件名模板：`P03-第3P 冬天-1080P60-AV1.mp4`，单 P 时 `P%P%-` 整段消失。
///
/// `<...>` 里的 `%P%` 是数值变量，单 P 稿件取到 `0` → 按空处理 → 连字面量
/// `P` 和 `-` 一起丢弃。这正是参照实现踩过的那个坑（单 P 落出 `P00` 文件名），
/// 在这里由可选段规则堵住。
const String kBiliDefaultFileNameTemplate =
    '<P%P%->%PART_TITLE%-%QUALITY%-%CODEC%%EXT%';

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
