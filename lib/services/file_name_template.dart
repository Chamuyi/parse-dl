import '../models/bili_meta.dart';
import '../models/media.dart';
import '../models/media_variant.dart';
import '../l10n/l10n.dart';

/// 文件名 / 文件夹模板引擎。
///
/// 移植自原版 X-Spider：
///   - 前代模块（变量表 REPLACER_MAP）
///   - 前代模块（解析 resolveVariables）
///   - 前代模块（unicodeSubstring / unicodeFilenamify）
///
/// 语法：`%VAR%` 只净化变量值，字面字符原样保留：
///
///   %POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%
///   → 2024-01-20 21-15-36 userscreenname 1145141919810-1.jpg
///
/// 带参数的变量写作 `%VAR,a=1,b=2%`，例如 `%CONTENT,t=32%` 表示截断 32 个字符。

/// 一个模板参数（如 `%CONTENT,t=32%` 里的 `t`）。
class TemplateParam {
  final String name;
  final String desc;
  final String defaultValue;

  const TemplateParam(this.name, this.desc, this.defaultValue);
}

/// 一个可用变量。
class TemplateVar {
  final String name;
  final String desc;
  final List<TemplateParam> params;

  /// 该变量的值是**序号类整数**（分P号、季号、集号…）。
  ///
  /// 只影响可选段 `<...>` 的判空口径：数值型变量里的 `0` 表示"没有这一项"
  /// （单 P 视频没有 P 号），所以按空处理；非数值型变量哪怕内容就是字符 `0`
  /// 也不算空 —— 标题真叫「0」的作品是存在的。
  final bool numeric;

  /// 给定媒体数据 + 解析后的参数，返回替换文本。
  final String Function(Media media, Map<String, String> params) replacer;

  const TemplateVar({
    required this.name,
    required this.desc,
    required this.replacer,
    this.params = const [],
    this.numeric = false,
  });

  /// 带参数时给 UI 展示的提示文本，无参数返回 null。
  String? get paramsTooltip {
    if (params.isEmpty) return null;
    return params
        .map((p) => tf('{name}：{desc}（默认：{def}）', {
              'name': p.name,
              'desc': t(p.desc),
              'def': p.defaultValue,
            }))
        .join('\n');
  }
}

/// **全部**模板变量（X + 抖音 + B 站），**顺序即替换顺序**（与原版 REPLACER_MAP 的
/// 插入顺序一致）。
///
/// 解析模板时用这一份全集：用户可能在任一模块里存了带另一个平台变量的旧模板，
/// 用全集解析才不会出现「变量原样留在文件名里」。**界面上不直接展示它** ——
/// 三个模块各自只显示属于自己语义的那一份（见下方 [kXTemplateVars] /
/// [kDouyinTemplateVars] / [kBiliTemplateVars]），免得 X 设置里冒出抖音变量、或反过来。
final List<TemplateVar> kAllTemplateVars = [
  TemplateVar(
    name: 'POST_ID',
    desc: '推文 ID',
    replacer: (m, _) => m.tweetId ?? '',
  ),
  TemplateVar(
    name: 'POST_TIME',
    desc: '推文发布日期',
    params: const [TemplateParam('d', '仅日期（0 或 1）', '0')],
    replacer: (m, p) {
      final t = m.createdAt;
      if (t == null) return '未知日期';
      // 注意：时分秒之间用 `-` 而不是 `:` —— 冒号是 Windows 文件名非法字符。
      final date =
          '${t.year.toString().padLeft(4, '0')}-'
          '${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')}';
      if (p['d'] == '1') return date;
      return '$date ${t.hour.toString().padLeft(2, '0')}-'
          '${t.minute.toString().padLeft(2, '0')}-'
          '${t.second.toString().padLeft(2, '0')}';
    },
  ),
  TemplateVar(
    name: 'USER_ID',
    desc: '用户 ID',
    replacer: (m, _) => m.userId ?? '',
  ),
  TemplateVar(
    name: 'USER_NAME',
    desc: '用户昵称',
    replacer: (m, _) => m.userName ?? '',
  ),
  TemplateVar(
    name: 'USER_SCREEN_NAME',
    desc: '用户名',
    replacer: (m, _) => m.userScreenName ?? '',
  ),
  TemplateVar(name: 'MEDIA_ID', desc: '资源 ID', replacer: (m, _) => m.id),
  TemplateVar(
    name: 'MEDIA_WIDTH',
    desc: '资源宽度',
    replacer: (m, _) => m.width?.toString() ?? '',
  ),
  TemplateVar(
    name: 'MEDIA_HEIGHT',
    desc: '资源高度',
    replacer: (m, _) => m.height?.toString() ?? '',
  ),
  TemplateVar(
    name: 'MEDIA_INDEX',
    desc: '资源索引',
    replacer: (m, _) => m.mediaIndex.toString(),
  ),
  TemplateVar(
    name: 'CONTENT',
    desc: '推文内容',
    params: const [TemplateParam('t', '截断长度', '32')],
    replacer: (m, p) {
      final text = m.tweetText;
      if (text == null || text.isEmpty) return '';
      final parsed = int.tryParse(p['t'] ?? '');
      final trim = (parsed == null || parsed < 0) ? 32 : parsed;
      return unicodeSubstring(text, 0, trim);
    },
  ),
  TemplateVar(name: 'MEDIA_TYPE', desc: '媒体类型', replacer: (m, _) => m.type.id),
  TemplateVar(
    name: 'EXT',
    desc: '扩展名',
    replacer: (m, _) {
      // 原版同样是从「下载链接」里取扩展名（图片链接带 ?name=orig 也要能剥掉）。
      final url = m.downloadUrl;
      if (url.isNotEmpty) {
        // 先剥 query 再取最后一个 `.` 之后的部分 —— 顺序颠倒会被
        // `?a=1.jpg` 这类查询串骗到。
        final tail = url.split('?').first.split('.').last;
        // 合法扩展名是 1~5 位字母数字。抖音的视频直链形如
        // `/aweme/v1/play/?video_id=v0300...`，压根没有扩展名，
        // 这时按媒体类型退回（视频 mp4 / GIF gif / 图片看链接后缀）。
        if (RegExp(r'^[A-Za-z0-9]{1,5}$').hasMatch(tail)) return '.$tail';
      }
      return '.${m.extension}';
    },
  ),
  TemplateVar(name: 'TAGS', desc: '推文标签', replacer: (m, _) => m.tags.join(',')),
  TemplateVar(
    name: 'SOURCE',
    desc: '来源平台（x / douyin / bili）',
    replacer: (m, _) => m.source,
  ),

  // ── 抖音专有变量 ─────────────────────────────────────────────
  //
  // 下面这组抖音专有变量的**顺序固定**（16 个，另加本项目自有的 IMAGE_INDEX）：
  // AUTHOR → AUTHOR_ID → AUTHOR_UNIQUE_ID →
  // CREATE_TIME → DESCRIPTION → AWEME_ID → CUSTOM_TEXT → RESOLUTION → BITRATE →
  // FPS → DURATION → FILE_SIZE → LIKE_COUNT → COMMENT_COUNT → COLLECT_COUNT →
  // SHARE_COUNT。
  //
  // **一处刻意的等价转换**：本项目是用户手写模板（`%A%_%B%`），分隔符由用户
  // 显式写出来，所以这里的格式化函数**只输出值本身**，不带装饰性的前导下划线
  // —— 那是「组件列表自动用 `_` 拼接」的实现才需要的东西；其余格式化规则
  // 保持不变。
  TemplateVar(
    name: 'AUTHOR',
    desc: '作者（@昵称）',
    replacer: (m, _) {
      final name = m.userName;
      return '@${(name == null || name.isEmpty) ? 'unknown_author' : name}';
    },
  ),
  TemplateVar(
    name: 'AUTHOR_ID',
    desc: '作者 ID',
    replacer: (m, _) => m.userId ?? '',
  ),
  TemplateVar(
    name: 'AUTHOR_UNIQUE_ID',
    desc: '抖音号',
    replacer: (m, _) => m.userScreenName ?? '',
  ),
  TemplateVar(
    name: 'CREATE_TIME',
    desc: '创建时间（YYYYMMDDHHmmss）',
    params: const [TemplateParam('d', '仅日期（0 或 1）', '0')],
    replacer: (m, p) =>
        formatCreateTime(m.createdAt, dateOnly: p['d'] == '1'),
  ),
  TemplateVar(
    name: 'DESCRIPTION',
    desc: '作品描述',
    params: const [TemplateParam('t', '最大长度（1~120）', '25')],
    replacer: (m, p) {
      final text = m.tweetText;
      // 描述为空时拿**作品 id** 兜底，不留空 ——
      // 留空会拼出 `@作者_20260824_.jpg` 这种尾巴挂个下划线的名字。
      if (text == null || text.isEmpty) return m.tweetId ?? '';
      // 长度参数缺省 25，取值夹在 1~120；超长截断后加 `...`
      final parsed = int.tryParse(p['t'] ?? '');
      final limit = parsed == null
          ? 25
          : (parsed < 1 ? 1 : (parsed > 120 ? 120 : parsed));
      if (text.length <= limit) return text;
      // 按 **UTF-16 码元**截，不是按「用户感知字符」—— `String.length` 与
      // `substring` 数的都是码元，emoji 占 2 个码元，所以含 emoji 的描述会
      // 比按字符截**少一个汉字**。这是与外部实现行为对齐的既定口径
      // （见仓库根目录 `NOTICE.md`），改数法会让同一作品前后落出两个名字。
      // 截在 emoji 中间留下的半个代理对，下一步整串清洗会换成 `_`。
      return '${text.substring(0, limit)}...';
    },
  ),
  TemplateVar(
    name: 'IMAGE_INDEX',
    desc: '图集序号（0 起，作品主视频不带）',
    replacer: (m, _) => _isMainVideo(m) ? '' : '_${m.mediaIndex - 1}',
  ),
  TemplateVar(
    name: 'AWEME_ID',
    desc: '作品 ID',
    replacer: (m, _) => m.tweetId ?? '',
  ),
  TemplateVar(
    name: 'CUSTOM_TEXT',
    desc: '自定义文本',
    replacer: (m, _) => m.customText ?? '',
  ),
  TemplateVar(
    name: 'RESOLUTION',
    desc: '分辨率（WxH）',
    replacer: (m, _) => resolutionText(m),
  ),
  TemplateVar(
    name: 'BITRATE',
    desc: '比特率',
    replacer: (m, _) {
      final bps = m.chosen?.bitrate ?? 0;
      return bps > 0 ? '${(bps / 1000).round()}Kbps' : '';
    },
  ),
  TemplateVar(
    name: 'FPS',
    desc: '帧率',
    replacer: (m, _) {
      final fps = m.chosen?.fps ?? 0;
      return fps > 0 ? '${fps}fps' : '';
    },
  ),
  TemplateVar(
    name: 'DURATION',
    desc: '时长',
    replacer: (m, _) => formatDurationSeconds((m.durationMs ?? 0) ~/ 1000),
  ),
  TemplateVar(
    name: 'FILE_SIZE',
    desc: '文件大小',
    replacer: (m, _) {
      final size = m.chosen?.dataSize ?? 0;
      return size > 0 ? formatFileSize(size) : '';
    },
  ),
  TemplateVar(
    name: 'LIKE_COUNT',
    desc: '点赞数',
    replacer: (m, _) => '${formatStatCount(m.likeCount)}点赞',
  ),
  TemplateVar(
    name: 'COMMENT_COUNT',
    desc: '评论数',
    replacer: (m, _) => '${formatStatCount(m.commentCount)}评论',
  ),
  TemplateVar(
    name: 'COLLECT_COUNT',
    desc: '收藏数',
    replacer: (m, _) => '${formatStatCount(m.collectCount)}收藏',
  ),
  TemplateVar(
    name: 'SHARE_COUNT',
    desc: '分享数',
    replacer: (m, _) => '${formatStatCount(m.shareCount)}分享',
  ),

  // ── B 站专有变量 ─────────────────────────────────────────────
  //
  // 取值全部来自 `Media.bili`（见 `models/bili_meta.dart`）；非 B 站媒体上
  // 这个块是 null，一律回空串 —— 用户把 B 站变量手打进 X 模板里也不会崩，
  // 只会得到空值，而空值正好让可选段 `<...>` 整段消失。
  //
  // `numeric: true` 的两个（P / PART_TOTAL）：`0` 表示「没有这一项」，
  // 可选段按空处理。单 P 视频的 `%P%` 就是 0 —— 参照实现把它渲染成 `P00`
  // 的那个坑，靠这个标记堵住。
  TemplateVar(
    name: 'WORK_TITLE',
    desc: '作品标题',
    replacer: (m, _) => m.bili?.workTitle ?? '',
  ),
  TemplateVar(
    name: 'PART_TITLE',
    desc: '分P标题',
    replacer: (m, _) => m.bili?.partTitle ?? '',
  ),
  TemplateVar(
    name: 'P',
    desc: '分P序号',
    numeric: true,
    params: const [TemplateParam('w', '补零位数（0=按分P总数自动）', '0')],
    replacer: (m, p) {
      // **没有 bili 块 ≠ 单 P**：X / 抖音的媒体上这两个序号类变量出空串，
      // 与其余 B 站变量口径一致；单 P 稿件才是 `'0'`（配合 numeric 让可选段消失）。
      final b = m.bili;
      if (b == null) return '';
      if (b.isSinglePart) return '0';
      final wParam = int.tryParse(p['w'] ?? '');
      final width = (wParam != null && wParam > 0)
          ? wParam
          : b.partTotal.toString().length;
      return m.mediaIndex.toString().padLeft(width < 1 ? 1 : width, '0');
    },
  ),
  TemplateVar(
    name: 'PART_TOTAL',
    desc: '分P总数',
    numeric: true,
    replacer: (m, _) => m.bili == null ? '' : '${m.bili!.partTotal}',
  ),
  TemplateVar(
    name: 'BVID',
    desc: 'BV号',
    replacer: (m, _) => m.bili?.bvid ?? '',
  ),
  TemplateVar(
    name: 'AVID',
    desc: 'av号',
    replacer: (m, _) => m.bili?.aid ?? '',
  ),
  TemplateVar(
    name: 'CID',
    desc: '内容ID',
    replacer: (m, _) => m.bili?.cid ?? '',
  ),
  TemplateVar(
    name: 'UP_NAME',
    desc: 'UP主昵称',
    replacer: (m, _) => m.userName ?? '',
  ),
  TemplateVar(
    name: 'UP_MID',
    desc: 'UP主ID',
    replacer: (m, _) => m.userId ?? '',
  ),
  TemplateVar(
    name: 'QUALITY',
    desc: '画质',
    replacer: (m, _) => m.bili?.qualityLabel ?? '',
  ),
  TemplateVar(
    name: 'CODEC',
    desc: '编码格式',
    replacer: (m, _) => m.bili?.codecLabel ?? '',
  ),
];

// ── 按平台划分的变量视图（设置页的「可用变量」表用这三份）──────────
//
// 为什么要分：三个模块的业务术语完全不同。X 侧说「推文 / 用户名 / 推文内容」，
// 抖音侧说「作品 / 作者 / 作品描述」，B 站侧说「作品 / 分P / UP 主」。把 42 个
// 变量混在一张表里，用户会在 X 设置里看到 %AWEME_ID%，在 B 站设置里看到「推文
// 内容」——都是噪音。
//
// 只是**视图**：底层定义仍是 [kAllTemplateVars] 一份，解析行为不受影响。

/// 三个平台共有的、只跟「文件」有关的变量。
const Set<String> kCommonVarNames = {'MEDIA_INDEX', 'MEDIA_TYPE', 'EXT'};

/// X 下载设置里显示的变量名。**不含任何抖音术语**。
///
/// 注意 `SOURCE` 不在其中：它的取值就是平台标识（X 侧永远是 x），
/// 对用户没有意义，列出来反而会让 X 设置里出现其它平台字样。
const Set<String> kXVarNames = {
  'POST_ID',
  'POST_TIME',
  'USER_ID',
  'USER_NAME',
  'USER_SCREEN_NAME',
  'MEDIA_ID',
  'MEDIA_WIDTH',
  'MEDIA_HEIGHT',
  'CONTENT',
  'TAGS',
  ...kCommonVarNames,
};

/// 抖音解析下载设置里显示的变量名。**不含任何 X 术语**。
///
/// 其中 16 个抖音专有变量的**输出形状**按平台返回字段整理（语法见 README），
/// IMAGE_INDEX 是本项目自有的；另外 3 个是跟文件本身有关的中性变量
/// （序号 / 媒体类型 / 扩展名）。
const Set<String> kDouyinVarNames = {
  // ── 作品与作者 ──
  'AUTHOR',
  'AUTHOR_ID',
  'AUTHOR_UNIQUE_ID',
  'CREATE_TIME',
  'DESCRIPTION',
  'AWEME_ID',
  // ── 下载配置 ──
  'CUSTOM_TEXT',
  // ── 文件属性 ──
  'IMAGE_INDEX',
  'RESOLUTION',
  'BITRATE',
  'FPS',
  'DURATION',
  'FILE_SIZE',
  // ── 作品数据 ──
  'LIKE_COUNT',
  'COMMENT_COUNT',
  'COLLECT_COUNT',
  'SHARE_COUNT',
  // ── 通用 ──
  ...kCommonVarNames,
};


/// B 站解析下载设置里显示的变量名。**不含 X 与抖音的术语**
/// （`test/platform_terms_test.dart` 会盯这条边界）。
///
/// 其中 11 个是 B 站专有；`RESOLUTION`/`DURATION`/`FILE_SIZE`/`CUSTOM_TEXT`
/// 是跟文件本身有关的中性变量，三个模块共用同一份定义。
const Set<String> kBiliVarNames = {
  // ── 作品与分P ──
  'WORK_TITLE',
  'PART_TITLE',
  'P',
  'PART_TOTAL',
  'BVID',
  'AVID',
  'CID',
  // ── UP 主 ──
  'UP_NAME',
  'UP_MID',
  // ── 下载配置 ──
  'QUALITY',
  'CODEC',
  'CUSTOM_TEXT',
  // ── 文件属性 ──
  'RESOLUTION',
  'DURATION',
  'FILE_SIZE',
  // ── 通用 ──
  ...kCommonVarNames,
};

/// B 站解析下载设置页的「可用变量」表。
final List<TemplateVar> kBiliTemplateVars = kAllTemplateVars
    .where((v) => kBiliVarNames.contains(v.name))
    .toList(growable: false);

/// X 下载设置页的「可用变量」表。
final List<TemplateVar> kXTemplateVars = kAllTemplateVars
    .where((v) => kXVarNames.contains(v.name))
    .toList(growable: false);

/// 抖音解析下载设置页的「可用变量」表。
final List<TemplateVar> kDouyinTemplateVars = kAllTemplateVars
    .where((v) => kDouyinVarNames.contains(v.name))
    .toList(growable: false);

// ── 抖音模板变量的格式化函数（公开以便单测） ──

/// `%RESOLUTION%`：优先用视频自身的宽高，
/// 没有就取**最高码率**那条变体的宽高。X 的媒体没有变体，退回 `Media.width/height`。
String resolutionText(Media m) {
  final chosen = m.chosen;
  if (chosen != null && chosen.width > 0 && chosen.height > 0) {
    return '${chosen.width}x${chosen.height}';
  }
  final w = m.width ?? 0;
  final h = m.height ?? 0;
  return (w > 0 && h > 0) ? '${w}x$h' : '';
}

/// `%DURATION%`：
/// `0s` / `45s` / `1m30s` / `1h2m3s`，中间为 0 的位省略（`2m0s` → `2m`）。
String formatDurationSeconds(int seconds) {
  if (seconds <= 0) return '0s';
  if (seconds >= 3600) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h}h${m > 0 ? '${m}m' : ''}${s > 0 ? '${s}s' : ''}';
  }
  if (seconds >= 60) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m}m${s > 0 ? '${s}s' : ''}';
  }
  return '${seconds}s';
}

/// `%FILE_SIZE%`：**不带**前导下划线（下划线由用户在模板里显式写）——
/// `bytes / 1048576`，大于 1 MB 取整、否则保留一位小数。
String formatFileSize(int bytes) {
  if (bytes <= 0) return '';
  final mb = bytes / 1048576.0;
  if (mb <= 0) return '';
  return mb > 1 ? '${mb.round()}MB' : '${mb.toStringAsFixed(1)}MB';
}

/// 抖音统计数字：0（含 null）→ `0`，超过 9999999 → `9999999+`。
String formatStatCount(int? n) {
  if (n == null || n == 0) return '0';
  return n > 9999999 ? '9999999+' : '$n';
}

/// `%CREATE_TIME%`：本地时区、无分隔符的 `YYYYMMDDHHmmss`。
/// 时间缺失时返回空串（原版是 `''`，不像 `%POST_TIME%`
/// 会写「未知日期」—— 那个是本项目 X 侧的历史行为）。
///
/// [dateOnly] 对应 `%CREATE_TIME,d=1%`：只留 `YYYYMMDD`，给「按日期分文件夹」
/// 这类预设用 —— 抖音侧要日期只能走这个参数，`%POST_TIME%` 是 X 的变量。
String formatCreateTime(DateTime? t, {bool dateOnly = false}) {
  if (t == null) return '';
  String p2(int v) => v.toString().padLeft(2, '0');
  final date =
      '${t.year.toString().padLeft(4, '0')}${p2(t.month)}${p2(t.day)}';
  if (dateOnly) return date;
  return '$date${p2(t.hour)}${p2(t.minute)}${p2(t.second)}';
}

/// 可选段 `<...>` 内部出现了"空值"的信号（仅供 [resolveVariables] 内部使用）。
class _OptionalSegmentEmpty {
  const _OptionalSegmentEmpty();
}

/// 成对的 `<...>`，段内不再嵌套尖括号（本期只支持一层，B 站的模板用不到嵌套）。
final _optionalSegmentRe = RegExp(r'<([^<>]*)>');

/// 可选段的占位符边界字符。控制字符在两条清洗路径里都会被换成 `_`/`!`，
/// 所以用户手打的模板里不可能出现它，回填时不会误伤。
const String _segmentMark = '\u0001';

/// 可选段里"这一项算不算没有"。
///
/// 判据必须看**变量的原始值**，不能看渲染后的文本：单 P 视频的 P 号原始值是 `0`，
/// 但渲染出来是 `"00"`，按文本判空就漏掉了 —— 参照实现正是栽在这里，
/// 结果所有单 P 作品都多出一个 `P00`。
bool _isEmptyForOptionalSegment(TemplateVar v, String raw) {
  if (raw.isEmpty) return true;
  if (!v.numeric) return false;
  final n = int.tryParse(raw.trim());
  return n == 0;
}

/// 把模板里的 `%VAR%` 全部替换成实际值，并处理可选段 `<...>`。
///
/// **只对「变量替换出来的值」做文件名净化**，模板里的字面字符原样保留 ——
/// 这样文件夹模板里的 `/` 才能当作路径分隔符用（原版就是这个行为）。
///
/// 可选段：段内**任一**变量按 [_isEmptyForOptionalSegment] 判为空，整段连同
/// 其中的字面字符一起丢弃（`<P%P%>-%TITLE%` 在单 P 时得到 `标题` 而不是 `-标题`）。
/// 不成对的 `<` / `>` 原样保留，交给后续的整串清洗处理。
///
/// [perVar] 是**逐个变量值**的净化函数，默认 X 侧那套 [unicodeFilenamify]
/// （非法字符换 `!`）。抖音侧要传 `(s) => s` 跳过它 —— 抖音那套清洗是整串拼好之后
/// 才做一次，其中「连续下划线压成一个」「去首尾下划线」两步只有在整串上才做得成；
/// 逐变量做，「逗号紧跟 emoji」的地方会留下两个下划线，名字对不上。
String resolveVariables(
  String template,
  Media media, {
  String Function(String)? perVar,
}) {
  final clean = perVar ?? unicodeFilenamify;

  /// [strict] 为真时任一空值变量都抛 [_OptionalSegmentEmpty]（用于可选段判空）。
  String expand(String text, {bool strict = false}) {
    var out = text;
    for (final v in kAllTemplateVars) {
      final re = RegExp(
        '%${v.name}((?:,[a-z]+=[^%]+?)+)?%',
        caseSensitive: false,
      );
      if (!re.hasMatch(out)) continue;
      out = out.replaceAllMapped(re, (match) {
        final params = _parseParams(match.group(1));
        final raw = v.replacer(media, params);
        if (strict && _isEmptyForOptionalSegment(v, raw)) {
          throw const _OptionalSegmentEmpty();
        }
        return clean(raw);
      });
    }
    return out;
  }

  // ① 先把成对的可选段摘出来，用占位符顶替。
  //    顺序很关键：**只扫模板，不扫注入结果** —— 变量值里出现 `<x>` 时
  //    （`test/file_name_template_test.dart:118` 就有 `a<b>c:d"e/f\g|h?i*j` 这种输入），
  //    若先展开再找尖括号，那段注入文本会被当成可选段吞掉。
  final segments = <String>[];
  var text = template.replaceAllMapped(_optionalSegmentRe, (m) {
    String body;
    try {
      body = expand(m.group(1)!, strict: true);
    } on _OptionalSegmentEmpty {
      body = ''; // 段内有空值 → 整段（含字面字符）丢弃
    }
    segments.add(body);
    return '$_segmentMark${segments.length - 1}$_segmentMark';
  });

  // ② 主展开（与改动前完全同一条循环、同一套顺序）
  text = expand(text);

  // ③ 回填摘出来的段。占位符里的控制字符会被清洗掉，所以不会被别的路径碰到。
  if (segments.isNotEmpty) {
    text = text.replaceAllMapped(
      RegExp('$_segmentMark(\\d+)$_segmentMark'),
      (m) => segments[int.parse(m.group(1)!)],
    );
  }
  return text;
}

// ── 抖音侧的整串清洗（本项目自行实现） ──────────────────────────────
//
// 与 X 侧的 `unicodeFilenamify` **不是一套规则**：那套把非法字符换成 `!`、
// 且只逐变量作用；抖音这套换成 `_`，并且对整串做一次归并。混用会让两边的
// 文件名都对不上各自的参照物，所以两套必须分开。
//
// 判据是**正向保留**：任意语言的字母与数字一律留下，另外保住文件名里确实
// 有用的几个标点，其余（标点、符号、emoji、控制字符）换成 `_`。
//
// ⚠️ 不用 `\w`：Dart 与 JS 的 `\w` 都只认 ASCII，用它做保留集会把纯日文假名、
//   纯韩文、纯全角数字的标题**整条洗成空串**（`テスト` → `___` → 折叠 → 去首尾 → 空）。

/// 除「字母 / 数字」之外还保留的标点。全角冒号 `：` 在中文标题里常见，
/// 而半角 `:` 是 Windows 保留字符，必须换掉。
const String kDouyinKeptPunct = '-.@：_';

/// 文件名整串上限。**保持原样**（200 个 UTF-16 码元，不是 200 个字）。
const int kDouyinFileNameMax = 200;

final _dyLetterOrDigit = RegExp(r'^[\p{L}\p{N}]$', unicode: true);
final _dyRunsOfUnderscore = RegExp(r'_{2,}');
final _dyEdgeUnderscore = RegExp(r'^_+|_+$');
// Windows 不允许名字以点或空格结尾（资源管理器会静默裁掉，aria2 那边则可能报错）
final _dyTrailingDots = RegExp(r'[ .]+$');

/// 整串清洗。[fallback] 是"洗完什么都不剩"时的兜底名 —— 空文件名会一路
/// 传到 aria2 的 `out:` 参数，那里没有第二次机会补救。
String douyinFilenamify(String s, {String fallback = ''}) {
  final kept = StringBuffer();
  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    kept.write(
      _dyLetterOrDigit.hasMatch(ch) || kDouyinKeptPunct.contains(ch)
          ? ch
          : '_',
    );
  }
  var out = kept
      .toString()
      .replaceAll(_dyRunsOfUnderscore, '_')
      .replaceAll(_dyEdgeUnderscore, '')
      .replaceAll(_dyTrailingDots, '');
  if (out.length > kDouyinFileNameMax) out = out.substring(0, kDouyinFileNameMax);
  return out.isEmpty ? fallback : out;
}

/// 抖音侧的完整文件名：模板展开 → **整串**清洗。
String resolveDouyinFileName(String template, Media media) => douyinFilenamify(
  resolveVariables(template, media, perVar: (s) => s).trim(),
  fallback: media.id,
);

/// 「作品自带的那个视频」—— 区别于实况图的配对视频。
///
/// 解析器给主视频用的 id 就是作品 id，实况配对视频是 `<作品id>_<序号>v`
/// （见 `douyin_parser.dart`）。参照实现只给图集静态图和它的实况视频加
/// `_序号` 后缀，主视频不加。
bool _isMainVideo(Media m) =>
    m.type == MediaType.video && m.tweetId != null && m.id == m.tweetId;

/// `,t=32,d=1` → `{t: 32, d: 1}`
Map<String, String> _parseParams(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  final out = <String, String>{};
  for (final part in raw.substring(1).split(',')) {
    final i = part.indexOf('=');
    if (i <= 0) continue;
    out[part.substring(0, i)] = part.substring(i + 1);
  }
  return out;
}

/// 把「文件夹模板的解析结果」拆成路径段。
///
/// `/` 与 `\` 都当分隔符，空段与 `.` / `..` 丢弃 ——
/// 模板是用户输入，不该允许借 `..` 跳到保存目录之外。
List<String> parseDirSegments(String dirName) => dirName
    .split(RegExp(r'[\\/]+'))
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty && s != '.' && s != '..')
    .toList(growable: false);

/// ── 以下两个是 unicode 感知的字符串工具，与原版 `utils/unicode.ts` 一一对应 ──

int _charCodeAt(String s, int i) => s.codeUnitAt(i);

/// 取第 index 个「用户感知字符」（会把代理对当一个字符）。
String _unicodeCharAt(String s, int index) {
  final first = _charCodeAt(s, index);
  if (first >= 0xd800 && first <= 0xdbff && s.length > index + 1) {
    final second = _charCodeAt(s, index + 1);
    if (second >= 0xdc00 && second <= 0xdfff) {
      return s.substring(index, index + 2);
    }
  }
  return s[index];
}

/// 按「用户感知字符」截取 `[start, end)`，避免把 emoji 切一半。
String unicodeSubstring(String string, int start, int end) {
  if (end == start) return '';
  final lo = end > start ? start : end;
  final hi = end > start ? end : start;

  final buffer = StringBuffer();
  var stringIndex = 0;
  var unicodeIndex = 0;
  while (stringIndex < string.length) {
    final ch = _unicodeCharAt(string, stringIndex);
    if (unicodeIndex >= lo && unicodeIndex < hi) buffer.write(ch);
    stringIndex += ch.length;
    unicodeIndex += 1;
  }
  return buffer.toString();
}

/// Windows 文件名里非法的字符 → `!`；整个名字是保留名（CON/PRN/…）时尾部补 `!`。
final RegExp _filenameReserved = RegExp(r'[<>:"/\\|?*\u0000-\u001F]');
final RegExp _windowsReservedName = RegExp(
  r'^(con|prn|aux|nul|com\d|lpt\d)$',
  caseSensitive: false,
);

String unicodeFilenamify(String str) {
  if (str.isEmpty) return str;
  if (_windowsReservedName.hasMatch(str)) return '$str!';
  final out = StringBuffer();
  var i = 0;
  while (i < str.length) {
    final ch = _unicodeCharAt(str, i);
    out.write(_filenameReserved.hasMatch(ch) ? '!' : ch);
    i += ch.length;
  }
  return out.toString();
}

/// ── 示例数据：设置页「输出示例」用它预览模板效果 ──
//
// **三个平台各一份，不共用。** 原因不只是术语：抖音的变量语义（作者 / 作品
// 描述 / 抖音号 / 作品数据）、B 站的（作品 / 分P / UP 主 / BV 号）跟 X（推文 /
// 用户名 / 转推标签）是三套，拿 X 的样例去预览它们的模板，输出示例会是一堆空值，
// 看不出模板对不对。

/// X 下载设置里预览模板用的示例媒体（一条推文里的图片）。
///
/// 数据取自原版 `constants/file-name-template.ts`，这样旧文档里的示例输出
/// 在新版里能对得上。
Media xExampleMedia() => Media(
  id: '1234567890123456789',
  type: MediaType.image,
  url: 'https://pbs.twimg.com/media/EXAMPLEid01.jpg',
  previewUrl: 'https://pbs.twimg.com/media/EXAMPLEid01.jpg',
  width: 1323,
  height: 1136,
  tweetId: '1145141919810',
  tweetText:
      '这里是推文内容,这里是推文内容，这里是推文内容，这里是推文内容，'
      '这里是推文内容，这里是推文内容。',
  createdAt: DateTime.fromMillisecondsSinceEpoch(1705756536000),
  userId: '1145141919',
  userName: '这是用户昵称',
  userScreenName: 'userscreenname',
  tags: const ['标签1', '标签2'],
  mediaIndex: 1,
);

/// 抖音解析下载设置里预览模板用的示例媒体（一条竖屏视频作品）。
///
/// 故意用**竖屏 1080x1920 + 视频**，这样 `%RESOLUTION%`、`%DURATION%`
/// 这些抖音特有的变量的输出示例才有参考价值。作品 ID 用 19 位真实位数，
/// 让 `%AWEME_ID%` 的示例长度与实际一致。
Media douyinExampleMedia() => Media(
  id: '7412345678901234567',
  type: MediaType.video,
  url: 'https://v3-web.douyinvod.com/example/media.mp4',
  previewUrl: 'https://p3-sign.douyinpic.com/example/cover.jpeg',
  width: 1080,
  height: 1920,
  tweetId: '7412345678901234567',
  tweetText: '傍晚的海边，风把云吹成一条线。#旅行 #vlog',
  createdAt: DateTime.fromMillisecondsSinceEpoch(1705756536000),
  userId: '1234567890123456',
  userName: '海边的猫',
  userScreenName: 'haibiandema',
  tags: const ['旅行', 'vlog'],
  mediaIndex: 1,
  source: 'douyin',
  durationMs: 45000,
  likeCount: 12345,
  commentCount: 678,
  collectCount: 2345,
  shareCount: 89,
  chosen: const MediaVariant(
    urls: ['https://v3-web.douyinvod.com/example/media.mp4'],
    kind: VariantKind.bitRate,
    width: 1080,
    height: 1920,
    fps: 30,
    bitrate: 2400000,
    dataSize: 12582912,
  ),
);

/// B 站解析下载设置里预览模板用的示例媒体（一条 12 分 P 稿件的第 3 P）。
///
/// 刻意选**多 P**：`%P%` 在单 P 时按空处理，用单 P 样例预览会让 `<P%P%>` 这段
/// 直接消失，用户在设置页里就看不出补零到底生效没有。
Media biliExampleMedia() => Media(
  id: 'BV1ofPY3Thnr-3',
  type: MediaType.video,
  url: 'https://upos-sz-mirrorhw.bilivideo.com/example/video.m4s',
  previewUrl: 'https://i0.hdslb.com/bfs/archive/example_cover.jpg',
  width: 1920,
  height: 1080,
  tweetId: 'BV1ofPY3Thnr',
  tweetText: '【4K】把一年的海边拍成十二段，第 3 段是冬天。',
  createdAt: DateTime.fromMillisecondsSinceEpoch(1705756536000),
  userId: '349326425505',
  userName: '海边的猫',
  tags: const ['旅行', 'vlog'],
  mediaIndex: 3,
  source: 'bili',
  durationMs: 632000,
  likeCount: 12345,
  commentCount: 678,
  shareCount: 89,
  bili: const BiliMeta(
    workTitle: '把一年的海边拍成十二段',
    partTitle: '第3P 冬天',
    bvid: 'BV1ofPY3Thnr',
    aid: '114514000',
    cid: '765432109',
    partTotal: 12,
    qualityLabel: '1080P60',
    codecLabel: 'AV1',
  ),
  chosen: const MediaVariant(
    urls: ['https://upos-sz-mirrorhw.bilivideo.com/example/video.m4s'],
    kind: VariantKind.bitRate,
    width: 1920,
    height: 1080,
    fps: 60,
    bitrate: 4800000,
    dataSize: 377487360,
  ),
);
