/// B 站弹幕的**取数 + 三种格式渲染 + 落盘登记**。
///
/// 分层：
///   - 取数：[biliFetchDanmaku] 只认一个注入进来的 `fetchSegment`，本文件**不 import
///     http、不碰 cookie、不碰登录态**（实测匿名可取，接口那边由接线方塞进来）；
///   - 渲染：[biliDanmakuToXml] / [biliDanmakuToJson] / [biliDanmakuToAss] 三个纯函数，
///     输入是已解码的 [BiliDanmaku] 列表，不发网络也不碰磁盘，测试直接喂真夹具解出的条目；
///   - 落盘：[buildBiliDanmakuSideFile] 走共用契约（`bili_additional.dart`），
///     ass 时按前提登记一条待内封轨，前提缺了就把原因短语放进 `missing`，**不静默**。
///
/// 分段口径（实测）：一条分 P 的弹幕按**视频时间每 6 分钟一段**，
/// 段数 = `ceil(总时长秒 / 360)`。一条 3 小时的稿件就是 31 段 = 31 个请求，
/// 所以这里限并发并回报进度，而不是一把全打出去。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../models/bili_config.dart';
import 'bili_additional.dart';
import 'bili_dm_proto.dart';

// ── 接口口径 ──────────────────────────────────────────────────

/// 每段的时长（秒）。B 站按视频时间切段，与弹幕发出时间无关。
const int kBiliDanmakuSegmentSeconds = 360;

/// 分段请求的并发上限。
///
/// 刻意与 [BiliConfig.concurrency]（aria2 的下载并发）**分开**：那一个是 4 路大文件
/// 带宽占用，这里是几十 KB 的小请求，复用同一个数会让用户在下载管理里改并发时
/// 不知不觉改动弹幕请求的突发量。
const int kBiliDanmakuDefaultConcurrency = 3;

/// 滚动弹幕的横向速度（px/s，按 [kBiliDanmakuPlayResX] 的坐标系算）。
///
/// 250 px/s 在 1920 宽下让一条普通长度的弹幕约 8~9 秒走完，与 B 站播放器同量级。
/// 这个值同时决定防重叠的间距：速度越慢，同一行上相邻两条离得越开。
const double kBiliDanmakuScrollPxPerSecond = 250;

/// 顶部/底部固定弹幕的停留时长（毫秒）
const int kBiliDanmakuFixedHoldMs = 5000;

/// ass 的剧本分辨率。libass 按实际视频尺寸等比缩放，所以这里定的是**坐标系**而不是
/// 像素：字号与 MarginV 都以这个坐标系为准。
const int kBiliDanmakuPlayResX = 1920;
const int kBiliDanmakuPlayResY = 1080;

/// 行高 = 字号 × 这个系数。1.3 覆盖「字高 + 行间余量」，两行之间不留视觉重叠余地。
const double kBiliDanmakuRowHeightFactor = 1.3;

/// 顶部/底部各自最多占几行（超出就走「延后出场」，而不是继续往中间堆）。
const int kBiliDanmakuTopRows = 3;
const int kBiliDanmakuBottomRows = 3;

/// ass 里的样式名。ASCII：它是脚本内的标识符而不是界面文案，换成中文还会让
/// 「只认 ASCII 样式名的老 libass」多一个变量。
const String kBiliDanmakuAssStyleName = 'Danmaku';

// ── 过滤默认值 ────────────────────────────────────────────────

/// 默认的 mode 黑名单：特效（7）与代码弹幕（8）。
///
/// 这两档的 `text` 装的是渲染指令而不是给人看的字。渲染层对 `mode >= 7` 也有一道
/// 跳过（[BiliDanmaku.isSpecial]），两处不是重复：**黑名单管「要不要进产物」，
/// 渲染层管「进了产物也不画」**——用户清空黑名单时后者仍然拦得住。
const Set<int> kBiliDanmakuDefaultBlockedModes = {7, 8};

/// 默认屏蔽的弹幕池。2 = 登录屏蔽区。
///
/// 注意 protobuf 的 `DanmakuElem` 里**没有 pool 字段**（只有旧 XML 接口回过），
/// 解出来一律是 0，所以这条规则在本期的真数据上是空转的；它保留是因为过滤逻辑
/// 要能在两种来源下同一套代码，并且可被测试驱动（见 `bili_danmaku_test.dart`
/// 里手工构造 pool=2 的那条）。
const Set<int> kBiliDanmakuDefaultBlockedPools = {2};

/// 默认的文本长度上限（按 rune 计，不是 UTF-16 单元）。<=0 = 不限。
///
/// 100 就是 B 站自身单条弹幕的上限，取它等于「不因长度丢任何合法弹幕」，
/// 只挡掉特效弹幕里那种整段指令串。
const int kBiliDanmakuDefaultMaxTextLength = 100;

// ── 待接 l10n 的短语文案 ──────────────────────────────────────
//
// 下面几条会进 `BiliAdditionalOutcome.missing`（界面原样列出）。接线时集中替换这
// 一小块即可，渲染与取数逻辑都不依赖它们的具体措辞。

/// 落盘名限定词与播放器菜单里的轨道名（契约要求，见 `biliAdditionalName`）
const String kBiliDanmakuQualifier = '弹幕';

/// 接口一条都没回
const String kBiliDanmakuMissingEmptyApi = '弹幕：接口未返回内容（0 条）';

/// 过滤规则把全部弹幕挡掉了
const String kBiliDanmakuMissingAllFiltered = '弹幕：取回的条目被过滤规则全部挡掉';

/// 勾了内封但配置前提不满足（后面拼的是 [BiliConfig.embedBlockReason] 给的原文）
const String kBiliDanmakuMissingEmbedBlocked = '弹幕：未登记内封轨 —— ';

/// 落盘本身失败（磁盘满 / 只读目录 / 被占用）
const String kBiliDanmakuMissingWriteFailed = '弹幕：写入失败';

/// 某个分段取回或解码失败（后面拼段号）
const String kBiliDanmakuMissingSegmentFailed = '弹幕分段取回失败：第 ';

/// 特效类未渲染的条数提示（后面拼数字）
const String kBiliDanmakuNoteSpecialSkipped = '弹幕：特效类未渲染 ';

// ── 分段数 ────────────────────────────────────────────────────

/// 段数 = `ceil(总时长秒 / 360)`。
///
/// 时长未知（0 或负）时返回 **1** 而不是 0：B 站对任何 cid 都至少回一段，
/// 拿不到时长是元数据层的缺失，不该让弹幕整体变成「不请求」。
int biliDanmakuSegmentCount(int durationSeconds) {
  if (durationSeconds <= 0) return 1;
  return (durationSeconds + kBiliDanmakuSegmentSeconds - 1) ~/
      kBiliDanmakuSegmentSeconds;
}

// ── 取数 ──────────────────────────────────────────────────────

/// 取一个分段，返回 protobuf 原始字节。
///
/// 由接线方注入：`cid` 是分 P 的 cid，`segmentIndex` 从 **1** 开始（B 站的
/// `segment_index` 不是 0 基）。抛异常即视为该段失败，上层记下段号后继续跑别的段。
typedef BiliDanmakuSegmentFetcher =
    Future<List<int>> Function(int cid, int segmentIndex);

/// 一次分段取回的结果
class BiliDanmakuFetchResult {
  const BiliDanmakuFetchResult({
    required this.items,
    required this.failedSegments,
    required this.segmentCount,
  });

  /// 全部段的弹幕，**已按 (stime, id) 定序**（分段完成顺序是乱的，渲染要时间序）
  final List<BiliDanmaku> items;

  /// 取回或解码失败的分段号（1 基），已升序。空 = 全段成功。
  final List<int> failedSegments;

  /// 计划请求的段数（用来区分「失败」和「压根没请求」）
  final int segmentCount;

  bool get isComplete => failedSegments.isEmpty;
}

/// 按段取回弹幕，**限并发**并回报进度。
///
/// 三条纪律：
///   1. 一段失败不拖垮整批 —— 31 段里第 17 段超时是常态，用户要的是其余 30 段；
///      但段号必须带回去，不能只写日志（它会进 `missing`）。
///   2. 解码失败与取回失败**合并成同一个段号列表**：对用户而言都是「这一段没拿到」。
///   3. 进度按「已结束的段」计，成功与失败都推进度，否则失败时进度会卡住不动。
///
/// 并发实现是 [maxConcurrent] 个自取段号的 worker（不用 `Future.wait` 一把开
/// segmentCount 个）：段号计数器在单线程事件循环里递增，天然不会重发或漏发。
Future<BiliDanmakuFetchResult> biliFetchDanmaku({
  required int cid,
  required int segmentCount,
  required BiliDanmakuSegmentFetcher fetchSegment,
  int maxConcurrent = kBiliDanmakuDefaultConcurrency,
  void Function(int done, int total)? onProgress,
}) async {
  if (segmentCount <= 0) {
    return const BiliDanmakuFetchResult(
      items: [],
      failedSegments: [],
      segmentCount: 0,
    );
  }
  final workers = math.min(math.max(1, maxConcurrent), segmentCount);
  final items = <BiliDanmaku>[];
  final failed = <int>[];
  var nextSegment = 1;
  var done = 0;

  Future<void> worker() async {
    while (true) {
      final segment = nextSegment++;
      if (segment > segmentCount) return;
      try {
        final bytes = await fetchSegment(cid, segment);
        // 解码也圈在 try 里：一段脏字节不该整批失败，但它确实属于「没拿到」
        items.addAll(biliDecodeDmSegReply(bytes));
      } on Exception {
        failed.add(segment);
      }
      done++;
      onProgress?.call(done, segmentCount);
    }
  }

  await Future.wait([for (var i = 0; i < workers; i++) worker()]);

  items.sort((a, b) {
    final byTime = a.stime.compareTo(b.stime);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });
  failed.sort();
  return BiliDanmakuFetchResult(
    items: items,
    failedSegments: failed,
    segmentCount: segmentCount,
  );
}

// ── 过滤与账目 ────────────────────────────────────────────────

/// 弹幕过滤规则。三个条件的默认值见上面的 `kBiliDanmakuDefault*`。
class BiliDanmakuFilter {
  const BiliDanmakuFilter({
    this.blockedModes = kBiliDanmakuDefaultBlockedModes,
    this.maxTextLength = kBiliDanmakuDefaultMaxTextLength,
    this.blockedPools = kBiliDanmakuDefaultBlockedPools,
  });

  /// mode 黑名单
  final Set<int> blockedModes;

  /// 文本长度上限（rune 数），<=0 表示不限
  final int maxTextLength;

  /// 屏蔽的弹幕池
  final Set<int> blockedPools;

  /// 留下这一条吗。空白文本一律不留：三种格式落出去都是无意义的一行。
  bool accepts(BiliDanmaku d) =>
      !blockedModes.contains(d.mode) &&
      !blockedPools.contains(d.pool) &&
      d.text.trim().isNotEmpty &&
      (maxTextLength <= 0 || d.text.runes.length <= maxTextLength);

  List<BiliDanmaku> apply(List<BiliDanmaku> items) =>
      items.where(accepts).toList();
}

/// 一次弹幕处理的账目。**每个数字都对应一个用户能看见的去向**，
/// 所以宁可多列一项，也不要「其余不计」。
class BiliDanmakuStats {
  const BiliDanmakuStats({
    this.total = 0,
    this.kept = 0,
    this.dropped = 0,
    this.scroll = 0,
    this.reverse = 0,
    this.top = 0,
    this.bottom = 0,
    this.special = 0,
    this.assSpecialSkipped = 0,
    this.failedSegments = 0,
    this.segmentCount = 0,
  });

  /// 接口回到的总条数（过滤前）
  final int total;

  /// 过滤后留下的条数
  final int kept;

  /// 被过滤规则挡掉的条数（= total - kept）
  final int dropped;

  final int scroll;
  final int reverse;
  final int top;
  final int bottom;

  /// 特效/代码类（mode >= 7）条数，**按过滤前的全量计**。
  ///
  /// 口径写成全量是因为默认黑名单就把 7/8 挡掉了：若按 kept 计，这个数字恒为 0，
  /// 「特效类未渲染」就变成了一条永远不会出现的假报账。
  final int special;

  /// ass 渲染层实际跳过的特效条数（黑名单被清空时才会 > 0）
  final int assSpecialSkipped;

  final int failedSegments;
  final int segmentCount;

  /// 渲染进 ass 的条数
  int get rendered => scroll + reverse + top + bottom;
}

/// 过滤 + 分类型计数
class BiliDanmakuSelection {
  const BiliDanmakuSelection({required this.kept, required this.stats});
  final List<BiliDanmaku> kept;
  final BiliDanmakuStats stats;
}

/// 分账目。类型计数按「kept 里实际会渲染的那几条」算，特效类按全量算（见
/// [BiliDanmakuStats.special] 的口径说明）。
BiliDanmakuSelection biliSelectDanmaku(
  List<BiliDanmaku> items,
  BiliDanmakuFilter filter, {
  int segmentCount = 0,
  int failedSegments = 0,
}) {
  final kept = filter.apply(items);
  var special = 0;
  for (final d in items) {
    if (d.isSpecial) special++;
  }
  var scroll = 0, reverse = 0, top = 0, bottom = 0;
  for (final d in kept) {
    if (d.isSpecial) {
      // 黑名单被清空的场合：留给渲染层跳过，这里不重复计数（special 已按全量计）
      continue;
    } else if (d.isTop) {
      top++;
    } else if (d.isBottom) {
      bottom++;
    } else if (d.mode == kBiliDmModeReverse) {
      reverse++;
    } else {
      scroll++;
    }
  }
  return BiliDanmakuSelection(
    kept: kept,
    stats: BiliDanmakuStats(
      total: items.length,
      kept: kept.length,
      dropped: items.length - kept.length,
      scroll: scroll,
      reverse: reverse,
      top: top,
      bottom: bottom,
      special: special,
      failedSegments: failedSegments,
      segmentCount: segmentCount,
    ),
  );
}

// ── xml ───────────────────────────────────────────────────────

/// 转义 XML 的五个保留字符。**`&` 必须最先处理**，否则前面转义出来的 `&lt;`
/// 会被后面几步二次转义成 `&amp;lt;`。
String biliEscapeXmlText(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 弹姬格式 xml。
///
/// `p` 属性八个槽位按 B 站自己的顺序：
/// `stime秒.小数,mode,字号,颜色,发出时间戳,pool,mid,行id`。
/// **mid 那一槽留空**：protobuf 里只有 midhash（发送者 mid 的 md5 前 8 位），
/// 本层没把它带进 [BiliDanmaku]（本期用不到），拿它冒充 mid 会让下游工具误判成 mid。
String biliDanmakuToXml(List<BiliDanmaku> items) {
  final sb = StringBuffer();
  sb.write('<?xml version="1.0" encoding="UTF-8"?>\n<i>\n');
  for (final d in items) {
    final time = d.stimeSeconds.toStringAsFixed(3);
    sb.write(
      '  <d p="$time,${d.mode},${d.size},${d.color},${d.date},${d.pool},'
      ',${d.id}">${biliEscapeXmlText(d.text)}</d>\n',
    );
  }
  sb.write('</i>\n');
  return sb.toString();
}

// ── json ──────────────────────────────────────────────────────

/// 弹幕的 json 转储：解码后的字段原样落盘，缩进 2。
///
/// 刻意**不过滤、不排序、不改字段名**：这一档的用途是「接口给了什么」的取证件，
/// 一加工就和 xml 那档重复了。`pool` 不写：它不在 wire 上，写出去是个恒为 0 的假字段。
String biliDanmakuToJson(List<BiliDanmaku> items) {
  final list = items
      .map(
        (d) => <String, Object>{
          'id': d.id,
          'stime': d.stime,
          'mode': d.mode,
          'size': d.size,
          'color': d.color,
          'text': d.text,
          'date': d.date,
        },
      )
      .toList();
  return const JsonEncoder.withIndent('  ').convert(list);
}

// ── ass ───────────────────────────────────────────────────────

/// 估算一条弹幕的渲染宽度（px，按 [kBiliDanmakuPlayResX] 坐标系）。
///
/// 没有字体度量就别装：这里用「CJK 1.0 em / ASCII 0.55 em / 其余 0.8 em」粗估。
/// 它只影响 `\move` 的终点与防重叠的间距，而两个方向的后果不对称：估**大**了弹幕
/// 晚点出屏、相邻两条离得更开（只是浪费），估小了才会尾部叠尾部真重叠 —— 所以向上取整。
int biliDanmakuWidthOf(String text, int fontSize) {
  var em = 0.0;
  for (final r in text.runes) {
    if (_isWideRune(r)) {
      em += 1.0;
    } else if (r >= 0x20 && r <= 0x7E) {
      em += 0.55;
    } else {
      em += 0.8;
    }
  }
  return (em * fontSize).ceil();
}

bool _isWideRune(int r) =>
    (r >= 0x1100 && r <= 0x115F) ||
    (r >= 0x2E80 && r <= 0x303E) ||
    (r >= 0x3041 && r <= 0x33FF) ||
    (r >= 0x3400 && r <= 0x4DBF) ||
    (r >= 0x4E00 && r <= 0x9FFF) ||
    (r >= 0xA000 && r <= 0xA4CF) ||
    (r >= 0xAC00 && r <= 0xD7A3) ||
    (r >= 0xF900 && r <= 0xFAFF) ||
    (r >= 0xFE30 && r <= 0xFE6F) ||
    (r >= 0xFF00 && r <= 0xFF60) ||
    (r >= 0xFFE0 && r <= 0xFFE6);

/// ass 渲染结果
class BiliDanmakuAssResult {
  const BiliDanmakuAssResult({
    required this.content,
    required this.specialSkipped,
    required this.events,
  });

  /// 完整 ass 文本（不含 BOM，BOM 在写盘那一步加）
  final String content;

  /// 渲染层跳过的特效条数
  final int specialSkipped;

  /// 实际写出的 Dialogue 行数
  final int events;
}

/// 一次槽位分配的结果
class _BiliDanmakuSlot {
  const _BiliDanmakuSlot({required this.row, required this.startMs});
  final int row;
  final int startMs;
}

/// 一行槽位分配器 —— **防重叠的全部逻辑就在这个类里**。
///
/// 每行记一个「最早可用时刻」（毫秒）。新弹幕优先落在已空出来的**最小序号行**；
/// 所有行都还占着时，落到最快腾出来的那一行并把出场时刻**顺延**到那个时刻。
/// 于是「同一时刻多条叠在同一行」在这套规则下不可能发生（同刻必然不同行），
/// 而一行上相邻两条也必然时间不交叠；代价是弹幕可能比原发出时间晚几百毫秒出现，
/// 这比叠成一坨好。
class _BiliDanmakuRowAllocator {
  _BiliDanmakuRowAllocator({
    required this.rowCount,
    required this.rowHeight,
    required this.firstY,
    required this.downwards,
  }) : _freeAt = List<int>.filled(math.max(1, rowCount), 0);

  final int rowCount;

  /// 行高（px）
  final int rowHeight;

  /// 第 0 行的 y
  final int firstY;

  /// true = 从 firstY 往画面下方排（滚动、顶部）；false = 往上排（底部）
  final bool downwards;

  /// 每行最早可用时刻（毫秒）
  final List<int> _freeAt;

  /// 第 [row] 行的 y 坐标
  int yOf(int row) => downwards ? firstY + row * rowHeight : firstY - row * rowHeight;

  /// 占用一行，返回落点行号与实际出场时刻。
  _BiliDanmakuSlot claim(int desired, int durationMs) {
    var row = -1;
    var start = desired;
    for (var r = 0; r < rowCount; r++) {
      if (_freeAt[r] <= desired) {
        row = r;
        break;
      }
    }
    if (row < 0) {
      // 全忙：挑最快空出来的行。从 0 号行起比，并列时自然取最小行号 ——
      // 两次跑出同一个结果，这是「产物可复现」的前提。
      row = 0;
      for (var r = 1; r < rowCount; r++) {
        if (_freeAt[r] < _freeAt[row]) row = r;
      }
      start = _freeAt[row];
    }
    _freeAt[row] = start + durationMs;
    return _BiliDanmakuSlot(row: row, startMs: start);
  }
}

/// 毫秒 → ass 时间串 `H:MM:SS.cc`（厘秒两位，libass 只认到这一位）。
String biliAssTime(int milliseconds) {
  final centis = milliseconds ~/ 10;
  String two(int v) => v.toString().padLeft(2, '0');
  final h = centis ~/ 360000;
  final m = (centis ~/ 6000) % 60;
  final s = (centis ~/ 100) % 60;
  return '$h:${two(m)}:${two(s)}.${two(centis % 100)}';
}

/// 渲染完整 ass（`[Script Info]` + `[V4+ Styles]` + `[Events]`）。
///
/// 样式全部取配置：字体 [BiliConfig.danmakuFontFace]、字号 [BiliConfig.danmakuFontSize]
/// （**覆盖弹幕自带的 size**，与 B 站播放器一致 —— 否则用户调字号滑条没反应）、
/// 不透明度 [BiliConfig.danmakuOpacity]、底部边距 [BiliConfig.danmakuMarginV]。
///
/// 三类弹幕：
///   - 滚动（mode 1/2/3 与其它未列举档位）：`\an7` + `\move(右进)(左出)`；
///   - 逆向（mode 6）：同一套行槽位，方向反过来 `\move(左进)(右出)`；
///   - 顶部 `\an8` / 底部 `\an2`：用 `\pos` 定行，停留 [kBiliDanmakuFixedHoldMs]。
///
/// 颜色逐条走 `\c&HAABBGGRR&`（alpha 由配置的不透明度算，见 [biliAssColor]），
/// 样式里的 PrimaryColour 同样带 alpha —— 两处都带是防一手「只认 RGB 的实现」。
///
/// `mode >= 7` 的特效弹幕不渲染，条数如实带回
/// （[BiliDanmakuAssResult.specialSkipped]）。
BiliDanmakuAssResult biliDanmakuToAss(
  List<BiliDanmaku> items,
  BiliConfig cfg, {
  String title = '',
}) {
  // 字号/边距来自 settings.json，用户手改或旧版本残留都可能写进 0 或负数：
  // 行高为 0 会让下面的 `~/` 直接抛异常，整条弹幕（连同一份已经取回的字节）就废了。
  // 夹成最小 1px 只是把排版退化成「全挤在第一行」，不是错误。
  final fontSize = math.max(1, cfg.danmakuFontSize);
  final marginV = math.max(0, cfg.danmakuMarginV);
  final rowHeight = (fontSize * kBiliDanmakuRowHeightFactor).ceil();
  // 滚动区占满整个画面（顶部/底部的固定弹幕叠在它上面，B 站自己也是这么画的）
  final scrollRows = math.max(1, (kBiliDanmakuPlayResY - marginV) ~/ rowHeight);
  final scroll = _BiliDanmakuRowAllocator(
    rowCount: scrollRows,
    rowHeight: rowHeight,
    firstY: 0,
    downwards: true,
  );
  final topBand = _BiliDanmakuRowAllocator(
    rowCount: kBiliDanmakuTopRows,
    rowHeight: rowHeight,
    firstY: marginV,
    downwards: true,
  );
  final bottomBand = _BiliDanmakuRowAllocator(
    rowCount: kBiliDanmakuBottomRows,
    rowHeight: rowHeight,
    firstY: kBiliDanmakuPlayResY - marginV,
    downwards: false,
  );

  final stylePrimary = biliAssColor(kBiliDmDefaultColor, opacity: cfg.danmakuOpacity);
  final ordered = [...items]..sort((a, b) {
    final byTime = a.stime.compareTo(b.stime);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });

  final events = <String>[];
  var specialSkipped = 0;
  final centerX = kBiliDanmakuPlayResX ~/ 2;

  for (final d in ordered) {
    if (d.isSpecial) {
      specialSkipped++;
      continue;
    }
    final color = biliAssColor(d.color, opacity: cfg.danmakuOpacity);
    final text = biliEscapeAssText(d.text);
    if (d.isTop || d.isBottom) {
      final band = d.isTop ? topBand : bottomBand;
      final slot = band.claim(d.stime, kBiliDanmakuFixedHoldMs);
      // \an8 / \an2 决定 \pos 那个点是文字的顶边中点还是底边中点，
      // 所以 x 一律给画面中心，y 给该行的边界 —— 两个方向共用一套行槽位。
      final align = d.isTop ? r'\an8' : r'\an2';
      events.add(
        _assDialogue(
          slot.startMs,
          slot.startMs + kBiliDanmakuFixedHoldMs,
          '$align\\pos($centerX,${band.yOf(slot.row)})\\c$color&',
          text,
        ),
      );
    } else {
      final width = biliDanmakuWidthOf(d.text, fontSize);
      final durationMs = ((kBiliDanmakuPlayResX + width) /
              kBiliDanmakuScrollPxPerSecond *
              1000)
          .ceil();
      final backwards = d.mode == kBiliDmModeReverse;
      final slot = scroll.claim(d.stime, durationMs);
      final y = scroll.yOf(slot.row);
      final from = backwards ? -width : kBiliDanmakuPlayResX;
      final to = backwards ? kBiliDanmakuPlayResX : -width;
      events.add(
        _assDialogue(
          slot.startMs,
          slot.startMs + durationMs,
          r'\an7'
          '\\move($from,$y)($to,$y)'
          '\\c$color&',
          text,
        ),
      );
    }
  }

  final sb = StringBuffer();
  sb.write('[Script Info]\n');
  sb.write('Title: ${title.isEmpty ? 'bilibili danmaku' : title}\n');
  sb.write('ScriptType: v4.00+\n');
  sb.write('WrapStyle: 0\n');
  sb.write('PlayResX: $kBiliDanmakuPlayResX\n');
  sb.write('PlayResY: $kBiliDanmakuPlayResY\n');
  sb.write('ScaledBorderAndShadow: yes\n');
  sb.write('\n');
  // 这一行注释是给「打开 ass 直接看」的人写的：字号来源不写清就会被当成 bug
  sb.write('; fontsize = config value; the per-danmaku size from the api is not used\n');
  sb.write('[V4+ Styles]\n');
  sb.write(
    'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
    'OutlineColour, BackColour, Bold, Italic, Underline, StrikeThrough, '
    'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
    'Alignment, MarginL, MarginR, MarginV, Encoding\n',
  );
  sb.write(
    'Style: $kBiliDanmakuAssStyleName,${cfg.danmakuFontFace},$fontSize,'
    '$stylePrimary,&H000000FF,&H00000000,&H00000000,'
    '0,0,0,0,100,100,0,0,1,1,0,5,10,10,$marginV,1\n',
  );
  sb.write('\n');
  sb.write('[Events]\n');
  sb.write(
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
    'Effect, Text\n',
  );
  for (final e in events) {
    sb.write('$e\n');
  }
  return BiliDanmakuAssResult(
    content: sb.toString(),
    specialSkipped: specialSkipped,
    events: events.length,
  );
}

/// 一条 Dialogue。行内三个 Margin 给 0 = 「按样式走」，Effect 留空。
///
/// 大括号由这里包，两个分支只贡献块内的标签：漏了它 `\an7` 会变成**看得见的字**
/// 打在弹幕前面，而 ass 语法照样合法、一个字都不报 —— 只能靠断言盯住。
/// 覆盖块与文本之间**不留空格**：ass 的文本是原样渲染的，那个空格会变成可见的
/// 缩进（滚动弹幕整体右移一个空格，行槽位的宽度估算也跟着偏）。
String _assDialogue(int startMs, int endMs, String override, String text) =>
    'Dialogue: 0,${biliAssTime(startMs)},${biliAssTime(endMs)},'
    '$kBiliDanmakuAssStyleName,,0,0,0,,'
    '{$override}$text';

/// 弹幕文本进 ass 前的处理：`{` `}` 是覆盖块定界符必须转义，换行压成空格
/// （弹幕本体不该有换行，留着会把一行 Dialogue 劈成两行）。
String biliEscapeAssText(String text) => text
    .replaceAll('\r\n', ' ')
    .replaceAll('\n', ' ')
    .replaceAll('\r', ' ')
    .replaceAll('{', r'\{')
    .replaceAll('}', r'\}');

// ── 落盘 + 契约登记 ───────────────────────────────────────────

/// 一次弹幕落盘的结果：契约那份 `outcome` 加上账目与落盘名。
class BiliDanmakuRunResult {
  const BiliDanmakuRunResult({
    required this.outcome,
    required this.fileName,
    required this.stats,
  });

  final BiliAdditionalOutcome outcome;

  /// 落盘名；null = 没落盘（0 条 / 全被滤掉 / 写入失败）
  final String? fileName;

  final BiliDanmakuStats stats;
}

/// 取回一条分 P 的弹幕，渲染成 [BiliConfig.danmakuFormat] 选的格式落盘，
/// 并按契约把 ass 登记成一条待内封轨。
///
/// **内封不由这里做**：ass 时产出的只是一条 [BiliEmbeddedTrack]，
/// 合并命令照 `outcome.tracks` 的顺序拼 `-map`（那一步在 `bili_merger.dart`）。
///
/// 三个落点要分清，否则界面会出现「用户没要求的事也在报警」：
///   - 没勾 [BiliConfig.saveDanmaku] → 什么都不做，返回 [BiliAdditionalOutcome.none]；
///   - 格式 ass 且内封前提齐 → 落盘 + 登记一条待内封轨；
///   - 格式 ass 但没登记成轨（没勾内封 / 前提缺）→ 落盘照旧，`missing` 里给原因短语。
Future<BiliDanmakuRunResult> buildBiliDanmakuSideFile({
  required String saveDir,
  required String base,
  required int cid,
  required int durationSeconds,
  required BiliConfig cfg,
  required BiliDanmakuSegmentFetcher fetchSegment,
  BiliDanmakuFilter filter = const BiliDanmakuFilter(),
  int maxConcurrent = kBiliDanmakuDefaultConcurrency,
  void Function(int done, int total)? onProgress,
}) async {
  if (!cfg.saveDanmaku) {
    return const BiliDanmakuRunResult(
      outcome: BiliAdditionalOutcome.none,
      fileName: null,
      stats: BiliDanmakuStats(),
    );
  }

  final segmentCount = biliDanmakuSegmentCount(durationSeconds);
  final fetched = await biliFetchDanmaku(
    cid: cid,
    segmentCount: segmentCount,
    fetchSegment: fetchSegment,
    maxConcurrent: maxConcurrent,
    onProgress: onProgress,
  );
  final selection = biliSelectDanmaku(
    fetched.items,
    filter,
    segmentCount: segmentCount,
    failedSegments: fetched.failedSegments.length,
  );

  final missing = <String>[
    for (final s in fetched.failedSegments)
      '$kBiliDanmakuMissingSegmentFailed$s／共 $segmentCount 段',
  ];

  final format = cfg.danmakuFormat;
  final fileName = biliAdditionalName(
    base: base,
    qualifier: kBiliDanmakuQualifier,
    ext: format.id,
  );

  if (selection.kept.isEmpty) {
    missing.add(
      fetched.items.isEmpty
          ? kBiliDanmakuMissingEmptyApi
          : kBiliDanmakuMissingAllFiltered,
    );
    return BiliDanmakuRunResult(
      outcome: BiliAdditionalOutcome(
        tracks: const [],
        written: const [],
        missing: missing,
      ),
      fileName: null,
      stats: selection.stats,
    );
  }

  // ass 才需要「跳过特效」这一步，先算出来好把条数带回账目
  final ass = format == BiliDanmakuFormat.ass
      ? biliDanmakuToAss(selection.kept, cfg, title: base)
      : null;
  final content = switch (format) {
    BiliDanmakuFormat.xml => biliDanmakuToXml(selection.kept),
    BiliDanmakuFormat.json => biliDanmakuToJson(selection.kept),
    BiliDanmakuFormat.ass => ass!.content,
  };
  final stats = BiliDanmakuStats(
    total: selection.stats.total,
    kept: selection.stats.kept,
    dropped: selection.stats.dropped,
    scroll: selection.stats.scroll,
    reverse: selection.stats.reverse,
    top: selection.stats.top,
    bottom: selection.stats.bottom,
    special: selection.stats.special,
    assSpecialSkipped: ass?.specialSkipped ?? 0,
    failedSegments: selection.stats.failedSegments,
    segmentCount: selection.stats.segmentCount,
  );
  // 特效类未渲染：以全量口径报，避免默认黑名单把它算成 0 条（见 stats.special）
  if (format == BiliDanmakuFormat.ass && stats.special > 0) {
    missing.add('$kBiliDanmakuNoteSpecialSkipped${stats.special} 条');
  }

  String? written;
  try {
    // ass 加 BOM：libmpv / ffmpeg 都不挑，但 Windows 上那批按 GBK 猜编码的播放器
    // 会挑 —— BOM 是它们唯一认得的「这是 UTF-8」标记。xml/json 不加，
    // 因为下游 xml 解析器与 json 解析器对 BOM 的容忍度更低。
    final payload = format == BiliDanmakuFormat.ass ? '\uFEFF$content' : content;
    final file = File(p.join(saveDir, fileName));
    await file.create(recursive: true);
    await file.writeAsString(payload, flush: true);
    written = fileName;
  } on FileSystemException catch (e) {
    missing.add('$kBiliDanmakuMissingWriteFailed：${e.osError?.message ?? e.message}');
  }

  final tracks = <BiliEmbeddedTrack>[];
  if (written != null) {
    final blocked = cfg.embedBlockReason(forDanmaku: true);
    if (format == BiliDanmakuFormat.ass &&
        cfg.embedSubtitleTrack &&
        blocked == null) {
      tracks.add(
        BiliEmbeddedTrack(
          fileName: fileName,
          title: kBiliDanmakuQualifier,
          // 弹幕没有「语言」这个概念：留空串 = 合并层不写 MKV 的 Language 元素。
          // 填 chi 会把它谎称成一条「中文字幕轨」，而它和字幕轨是两回事。
          iso639: '',
          fromDanmaku: true,
        ),
      );
    } else if (cfg.embedSubtitleTrack) {
      missing.add('$kBiliDanmakuMissingEmbedBlocked${(blocked ?? const []).join('、')}');
    }
  }

  return BiliDanmakuRunResult(
    outcome: BiliAdditionalOutcome(
      // 契约要求交出去就已经排好序
      tracks: orderTracks(tracks, cfg.trackPriority),
      written: written == null ? const [] : [written],
      missing: missing,
    ),
    fileName: written,
    stats: stats,
  );
}
