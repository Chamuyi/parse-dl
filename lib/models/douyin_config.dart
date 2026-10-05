/// 抖音下载配置 —— 「下载设置」这一组选项。
library;

/// 下载源 —— 6 个选项，覆盖平台实际下发的几路地址。
enum DouyinSource {
  /// 默认播放地址（`video.play_addr`）
  defaultAddr('default', '视频（默认）'),

  /// 指定 H.264
  h264('h264', '下载地址 (H.264)'),

  /// 指定 H.265
  h265('h265', '下载地址 (H.265)'),

  /// 兼容性+质量优先（排除 ByteVC1）
  qualityFirst('quality_first', '下载地址 (兼容性+质量优先) (H.265/H.264)'),

  /// 最高质量优先（含 ByteVC1）
  qualityFirstBytevc1(
    'quality_first_bytevc1',
    '下载地址 (最高质量优先) (ByteVC1/H.265/H.264)',
  ),

  /// 仅音频 —— **取该作品的 BGM**，不是从视频里抽音轨
  audioOnly('audio_only', '下载地址（仅音频）');

  const DouyinSource(this.id, this.label);

  /// 持久化标识 —— 这个字符串进了 `settings.json`，改它等于让老用户的设置失效。
  final String id;

  /// 下拉里显示的文案。
  final String label;

  /// 是否是「质量优先」两个档位 —— 只有这两档才显示「质量优先策略」下拉。
  bool get needsQualityMode =>
      this == DouyinSource.qualityFirst ||
      this == DouyinSource.qualityFirstBytevc1;

  static DouyinSource fromId(String? id) => DouyinSource.values.firstWhere(
    (e) => e.id == id,
    orElse: () => DouyinSource.defaultAddr,
  );
}

/// 「质量优先策略」四档。权重模式是**主项 0.7 / 次项 0.2 / 末项 0.1**，
/// 换档只是换主项：主项权重 0.7，其余两项 0.2 / 0.1。
enum DouyinQualityMode {
  /// 综合分辨率、比特率、帧率，自动选择最佳质量（`0.4 / 0.4 / 0.2`）
  auto('auto', '自动（推荐）'),

  resolution('resolution', '分辨率优先'),
  bitrate('bitrate', '比特率优先'),
  fps('fps', '帧率优先');

  const DouyinQualityMode(this.id, this.label);

  final String id;
  final String label;

  static DouyinQualityMode fromId(String? id) => DouyinQualityMode.values
      .firstWhere((e) => e.id == id, orElse: () => DouyinQualityMode.auto);
}

/// 图文作品的图片格式偏好。
enum DouyinImageFormat {
  /// 默认，保持抖音下发的镜像顺序（通常是 webp）
  keep('webp', '默认（webp）'),

  /// 其它格式优先 —— 把非 `.webp` 的镜像排到前面
  jpgFirst('jpg', '其它格式优先（jpg）');

  const DouyinImageFormat(this.id, this.label);

  final String id;
  final String label;

  static DouyinImageFormat fromId(String? id) => DouyinImageFormat.values
      .firstWhere((e) => e.id == id, orElse: () => DouyinImageFormat.keep);
}

/// 抖音页的下载配置。
class DouyinConfig {
  /// 下载源
  DouyinSource source;

  /// 质量优先策略（仅 [DouyinSource.needsQualityMode] 为真时生效）
  DouyinQualityMode qualityMode;

  /// 图片格式偏好
  DouyinImageFormat imageFormat;

  /// 候选过滤：滤掉档位名含 `low` 的低画质变体
  bool filterLowQuality;

  /// 候选过滤：排除 ByteVC1 编码（兼容性差）
  bool filterByteVc1;

  /// 图文作品附带下载**实况图的配对视频**
  bool includeLivePhoto;

  /// 附带下载 **BGM**（按 `mid` 在本批内去重）
  bool includeBgm;

  /// 「跳过已下载」—— 按**作品粒度**台账（`aweme_id`）跳过，对齐参照实现
  bool skipDownloaded;

  /// 「按作品」把同一作品的多个媒体排在连续位置（默认开）
  bool groupByAweme;

  /// 时长筛选是否启用（**只影响视频本身的时长**，不是发布时段）
  bool timeRangeEnabled;

  /// 时长下限（秒）
  int timeStartSec;

  /// 时长上限（秒）
  int timeEndSec;

  /// aria2 并发数（对应参照实现的 `limit`，默认 4）
  int concurrency;

  /// `%CUSTOM_TEXT%` 的输出内容（对齐参照实现的「自定义文本」组件）
  String customText;

  // ── 保存与命名（对齐 X 下载的设置，用户要求抖音侧也要有）──────────

  /// 保存根目录。**空 = 沿用另一处已设过的根目录**（见 `resolveSaveBase`）：
  /// 这个字段引入之前抖音没有这个字段，一直复用 X 下载那条，留空是为了不让老用户
  /// 更新完发现下载位置突然变了。
  String saveDirBase;

  /// **启用保存文件夹**：开 = 按 [dirTemplate] 建子目录再存；
  /// 关 = 忽略文件夹模板，文件全部平铺在保存根目录里。
  bool enableSaveFolder;

  /// 文件夹模板 —— 只在 [enableSaveFolder] 为真时生效。
  /// 界面上的可用变量是抖音那 19 个（`kDouyinTemplateVars`）。
  String dirTemplate;

  /// 文件模板 —— 空则退回「媒体ID_时间戳.扩展名」。
  String fileNameTemplate;

  DouyinConfig({
    this.source = DouyinSource.defaultAddr,
    this.qualityMode = DouyinQualityMode.auto,
    this.imageFormat = DouyinImageFormat.keep,
    this.filterLowQuality = false,
    this.filterByteVc1 = false,
    this.includeLivePhoto = true,
    this.includeBgm = false,
    // 默认开启：配合下载历史，「下过的不再重下」才是有意义的行为
    this.skipDownloaded = true,
    this.groupByAweme = true,
    this.timeRangeEnabled = false,
    this.timeStartSec = 0,
    this.timeEndSec = 300,
    this.concurrency = 4,
    this.customText = '',
    this.saveDirBase = '',
    this.enableSaveFolder = true,
    this.dirTemplate = '%AUTHOR%',
    this.fileNameTemplate = kDouyinDefaultFileNameTemplate,
  });

  factory DouyinConfig.fromJson(Map<String, dynamic> j) => DouyinConfig(
    source: DouyinSource.fromId(j['source'] as String?),
    qualityMode: DouyinQualityMode.fromId(j['qualityMode'] as String?),
    imageFormat: DouyinImageFormat.fromId(j['imageFormat'] as String?),
    filterLowQuality: j['filterLowQuality'] as bool? ?? false,
    filterByteVc1: j['filterByteVc1'] as bool? ?? false,
    includeLivePhoto: j['includeLivePhoto'] as bool? ?? true,
    includeBgm: j['includeBgm'] as bool? ?? false,
    skipDownloaded: j['skipDownloaded'] as bool? ?? true,
    groupByAweme: j['groupByAweme'] as bool? ?? true,
    timeRangeEnabled: j['timeRangeEnabled'] as bool? ?? false,
    timeStartSec: (j['timeStartSec'] as num?)?.toInt() ?? 0,
    timeEndSec: (j['timeEndSec'] as num?)?.toInt() ?? 300,
    concurrency: (j['concurrency'] as num?)?.toInt() ?? 4,
    customText: j['customText'] as String? ?? '',
    saveDirBase: j['saveDirBase'] as String? ?? '',
    enableSaveFolder: j['enableSaveFolder'] as bool? ?? true,
    dirTemplate: j['dirTemplate'] as String? ?? '%AUTHOR%',
    fileNameTemplate: _migrateFileNameTemplate(j['fileNameTemplate'] as String?),
  );

  Map<String, dynamic> toJson() => {
    'source': source.id,
    'qualityMode': qualityMode.id,
    'imageFormat': imageFormat.id,
    'filterLowQuality': filterLowQuality,
    'filterByteVc1': filterByteVc1,
    'includeLivePhoto': includeLivePhoto,
    'includeBgm': includeBgm,
    'skipDownloaded': skipDownloaded,
    'groupByAweme': groupByAweme,
    'timeRangeEnabled': timeRangeEnabled,
    'timeStartSec': timeStartSec,
    'timeEndSec': timeEndSec,
    'concurrency': concurrency,
    'customText': customText,
    'saveDirBase': saveDirBase,
    'enableSaveFolder': enableSaveFolder,
    'dirTemplate': dirTemplate,
    'fileNameTemplate': fileNameTemplate,
  };

  /// 与默认值不同的项数 —— 设置区折叠时用来点「已修改」小圆点。
  bool get isDefault =>
      source == DouyinSource.defaultAddr &&
      qualityMode == DouyinQualityMode.auto &&
      imageFormat == DouyinImageFormat.keep &&
      !filterLowQuality &&
      !filterByteVc1 &&
      includeLivePhoto &&
      !includeBgm &&
      skipDownloaded &&
      groupByAweme &&
      !timeRangeEnabled &&
      concurrency == 4 &&
      customText.isEmpty &&
      saveDirBase.isEmpty &&
      enableSaveFolder &&
      dirTemplate == '%AUTHOR%' &&
      fileNameTemplate == kDouyinDefaultFileNameTemplate;
}

/// 「启用模版」预设 —— 一键把文件夹模板 + 文件模板填成一套现成组合。
///
/// 用户要的「提供启用模版」就是这个：不必从零拼变量，选一个预设即可，
/// 选完仍可手动微调（微调后下拉会显示「自定义」）。
///
/// 默认值（[DouyinConfig.dirTemplate] / [DouyinConfig.fileNameTemplate]）
/// 与第一个预设 'author' 完全一致，所以初始状态下拉就停在「按作者分文件夹」。
///
/// 组合顺序对齐参照实现的默认组件（AUTHOR → CREATE_TIME → DESCRIPTION），
/// 只是它用 `_` 自动拼接、这里由模板显式写出。
class DouyinTemplatePreset {
  const DouyinTemplatePreset({
    required this.id,
    required this.label,
    required this.dirTemplate,
    required this.fileNameTemplate,
  });

  /// 下拉项标识（不进设置，仅 UI 用）
  final String id;

  /// 下拉里显示的文案
  final String label;

  final String dirTemplate;
  final String fileNameTemplate;
}

/// 抖音默认的文件名模板。
///
/// 展开后经 `douyinFilenamify` 整串清洗，产出的名字形状（示例数据为虚构）：
///   `@demo作者甲_20260824_这是第一段示例文字_这是第二段的文字_这是第三段..._0.jpg`
///
/// 三段分别来自：`%AUTHOR%`（自带 `@` 前缀与 unknown_author 兜底）、
/// `%CREATE_TIME,d=1%`（只到日，输出 `YYYYMMDD`）、
/// `%DESCRIPTION%`（截断 25 字、超长补 `...`，空描述用作品 id 兜底）。
/// `%IMAGE_INDEX%` 给图集静态图补 `_0` 起的序号，作品主视频则输出空串。
const String kDouyinDefaultFileNameTemplate =
    '%AUTHOR%_%CREATE_TIME,d=1%_%DESCRIPTION%%IMAGE_INDEX%%EXT%';

/// 3.6 之前的默认文件名模板。留着只为了识别「用户从没改过模板」这一种情况。
const String kLegacyDouyinFileNameTemplate = '%CREATE_TIME%_%DESCRIPTION%%EXT%';

/// 把旧默认模板升级成当前这一套。
///
/// 只认「存的值恰好等于旧默认串」—— 那说明用户根本没动过模板，只是默认值
/// 被写进了设置文件；光改代码里的默认值对这类老配置不生效。
/// 手动改过的（哪怕改成了别的格式）一律不动。
String _migrateFileNameTemplate(String? stored) =>
    stored == null || stored == kLegacyDouyinFileNameTemplate
    ? kDouyinDefaultFileNameTemplate
    : stored;

/// 「自定义」在下拉里的标识 —— 模板被手动改过、不匹配任何预设时用它。
const String kDouyinCustomPresetId = 'custom';

const List<DouyinTemplatePreset> kDouyinTemplatePresets = [
  DouyinTemplatePreset(
    id: 'author',
    label: '按作者分文件夹（推荐）',
    dirTemplate: '%AUTHOR%',
    fileNameTemplate: kDouyinDefaultFileNameTemplate,
  ),
  DouyinTemplatePreset(
    id: 'author_date',
    label: '按「作者 / 日期」两级文件夹',
    dirTemplate: '%AUTHOR%/%CREATE_TIME,d=1%',
    fileNameTemplate: '%DESCRIPTION%%EXT%',
  ),
  DouyinTemplatePreset(
    id: 'flat',
    label: '全部平铺（不建子文件夹）',
    dirTemplate: '',
    fileNameTemplate: '%CREATE_TIME%_%AUTHOR%_%DESCRIPTION%%EXT%',
  ),
  DouyinTemplatePreset(
    id: 'aweme',
    label: '按作品 ID 分文件夹',
    dirTemplate: '%AWEME_ID%',
    fileNameTemplate: '%DESCRIPTION%%EXT%',
  ),
];
