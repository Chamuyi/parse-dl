/// B 站批量页的状态仓库：有哪些目标、每个跑到哪一步、选项是什么。
///
/// **职责边界与 `DouyinAutoStore` 一致**：这里只存数据，不碰 WebView、不碰
/// aria2 —— 真正的执行循环在 `bili_batch_page.dart`，因为它要持有页面那个
/// `WebviewController`（页内 fetch 是列表接口唯一的登录态出口）。
/// 这样切页面不丢进度，而且这一层可以不打网络就单测。
///
/// 与抖音那份的两处实质差别，都在「B 站的列表接口能直接翻页」这件事上：
///  * 没有「滚几轮」这种档 —— 抖音要滚是因为它的签名接口不能公开翻页，
///    B 站这边一次 `allArcs` 就翻到尽了；
///  * 一个目标底下可能摊开成**几百条稿件**，所以多了一层「最多下几条」的闸门，
///    以及「多 P 稿件只取第 1P」这个默认 —— 后者不开的话，一个 20P 的合集
///    点一次批量就是几百条队列，而用户想说的通常只是「这些都下」。
library;

import 'package:flutter/foundation.dart';

import 'bili_batch_runner.dart';
import 'bili_list_api.dart';
import 'bili_link.dart';

/// 一个目标在批量里的进度阶段。
enum BiliBatchStatus {
  /// 还没轮到
  waiting,

  /// 短链展开中（只有链接本身是短链时才会经过这一格）
  expanding,

  /// 列表翻页 / 稿件展开中
  listing,

  /// 取流入队中
  downloading,

  /// 跑完了（**不等于全部成功**，成功几条看 [BiliBatchTarget.run]）
  done,

  /// 这一整个目标没跑成：链接判不出身份、列表拿不到、稿件一条都没展开出来
  failed,
}

/// 批量里的一行 = 一个目标（一条主页 / 一个合集 / 一个收藏夹 / 一条稿件）。
class BiliBatchTarget {
  BiliBatchTarget({required this.input, required this.ref});

  /// 用户原文那一行 —— 出错时要能指回他写的到底是哪一条。
  final String input;

  /// 解析结果。短链展开之后会被换成展开出来的那份。
  BiliRef ref;

  /// 列表身份（`unknown` 已经过 [BiliListApi.resolveTarget] 判定）。
  /// 单条稿件那一行没有它。
  BiliListTarget? target;

  /// 界面那一行显示的名字：列表名，或稿件标题。
  String title = '';

  BiliBatchStatus status = BiliBatchStatus.waiting;

  /// 从列表里认出来的稿件条数（不含被上限截掉的）。
  int collected = 0;

  /// 列表里**本期不支持**因而丢掉的条数（收藏夹会混进音频 / 番剧 / 直播间）。
  /// 界面要把它如实说出来，静默吞掉的话用户会以为「漏了」。
  int skippedUnsupported = 0;

  /// 被「最多下几条」截掉的条数（也是要说人话的数）。
  int truncated = 0;

  /// 列表翻到尽拿回来的稿件，界面展开明细时用。
  List<BiliArchive> archives = const [];

  /// 下载阶段的计数（还没跑到就是 null）。
  BiliRunTally? run;

  /// 失败原因（`status == failed` 时给）。
  String? error;

  bool get isSettled =>
      status == BiliBatchStatus.done || status == BiliBatchStatus.failed;

  void reset() {
    status = BiliBatchStatus.waiting;
    collected = 0;
    skippedUnsupported = 0;
    truncated = 0;
    archives = const [];
    run = null;
    error = null;
  }

  /// 这一行是什么类型的列表（界面那一列的文案按它取）。
  BiliListKind? get kind => ref.list?.kind;
}

/// [parseBiliTargets] 的结果。
class BiliTargetParse {
  const BiliTargetParse(this.targets, this.rejected, this.truncated);

  /// 认出来的目标（已按身份去重）
  final List<BiliBatchTarget> targets;

  /// 认不出来的原始行 —— 回显给用户，免得他以为自己写的东西生效了
  final List<String> rejected;

  /// 因为超出上限被丢掉的行数
  final int truncated;
}

/// 从一段文本里解析出批量目标。**一行一个**。
///
/// 认得这几种（其余一律进 [BiliTargetParse.rejected]，不猜）：
///   * `https://space.bilibili.com/224900`（UP 主主页投稿）
///   * `https://space.bilibili.com/224900/lists/3202069?type=series`（系列）
///   * `https://www.bilibili.com/list/224900?sid=3202069`（合集或系列，身份待定）
///   * `https://www.bilibili.com/video/BV1xx…`、`BV1xx`、`av1234`（单条稿件）
///   * `…/favlist?fid=123456`、短链里的 `ml123456`、直接贴的纯数字收藏夹 id
///   * `b23.tv/xxxx`（短链要发请求才认得，这里只标成「待展开」）
///
/// 空行忽略；同一个身份只保留第一次出现的那一行。
BiliTargetParse parseBiliTargets(String text, {int maxTargets = 200}) {
  final targets = <BiliBatchTarget>[];
  final rejected = <String>[];
  final seen = <String>{};
  var truncated = 0;

  for (final line in text.split(RegExp(r'\r?\n'))) {
    final raw = line.trim();
    if (raw.isEmpty) continue;

    final ref = biliTargetRef(raw);
    if (ref == null) {
      rejected.add(raw);
      continue;
    }
    final key = biliTargetKey(ref);
    if (!seen.add(key)) continue;
    if (targets.length >= maxTargets) {
      truncated++;
      continue;
    }
    targets.add(BiliBatchTarget(input: raw, ref: ref));
  }
  return BiliTargetParse(targets, rejected, truncated);
}

/// 一行文本 → 一个可执行的目标；认不出来回 null。
///
/// 「本期不支持」（番剧 / 专栏那几行）也算认不出来 —— 它们进 [BiliTargetParse.rejected]
/// 比进队列好：批量跑到一半才发现整条链路不支持，用户看到的是一堆没头没尾的失败行。
BiliRef? biliTargetRef(String raw) {
  final ref = parseBiliRef(raw);
  if (ref == null || ref.isUnsupported) return null;
  return ref.isList || ref.bvid != null || ref.aid != null || ref.needsExpand
      ? ref
      : null;
}

/// 目标身份。同一个主页写两次、或一条稿件既写链接又写 BV 号，都只留一行。
String biliTargetKey(BiliRef ref) {
  final list = ref.list;
  if (list != null) {
    // unknown 那一支的 sid 既可能是合集也可能是系列，身份还没判出来，
    // 但去重仍然按它 —— 同一个 sid 写两行只会多请求一次探针，没有第二个后果。
    return 'list:${list.kind.name}:${list.mid ?? ''}:${list.sid ?? ''}'
        ':${list.seasonId ?? ''}:${list.seriesId ?? ''}:${list.favId ?? ''}';
  }
  if (ref.bvid != null && ref.bvid!.isNotEmpty) return 'work:${ref.bvid}';
  if (ref.aid != null) return 'work:av${ref.aid}';
  if (ref.shortLink != null && ref.shortLink!.isNotEmpty) {
    // 短链没展开之前不知道它指向哪，只能按地址本身去重
    return 'short:${ref.shortLink}';
  }
  return 'unknown';
}

/// 批量页的状态。
class BiliBatchStore extends ChangeNotifier {
  /// 目标数上限。太多了列表先卡住，而且一晚上也跑不完。
  static const int kMaxTargets = 200;

  /// 「每个列表最多下几条稿件」的档位。0 = 不限。
  ///
  /// 给档位而不是自由输入：用户要的其实是「先来一小批看看对不对」，
  /// 几个能看懂的数比一个空输入框有用。
  static const List<int> kMaxWorksChoices = [0, 5, 10, 30, 50, 100];

  String _rawText = '';
  BiliTargetParse _parsed = const BiliTargetParse([], [], 0);

  bool _running = false;
  int _currentIndex = -1;
  int _maxWorks = 0;
  bool _allParts = false;

  // 收藏夹下拉（D8 的后半：贴链接直抓 + 列出我自己建的那些）
  List<BiliFavFolder> _favFolders = const [];
  String _favFoldersNote = '';

  // ── 只读 ──────────────────────────────────────────────────

  String get rawText => _rawText;

  List<BiliBatchTarget> get targets => List.unmodifiable(_parsed.targets);

  List<String> get rejected => List.unmodifiable(_parsed.rejected);

  int get truncated => _parsed.truncated;

  int get total => _parsed.targets.length;

  bool get hasTargets => _parsed.targets.isNotEmpty;

  bool get running => _running;

  /// 正在跑第几个（-1 = 还没开始）
  int get currentIndex => _currentIndex;

  BiliBatchTarget? get current =>
      (_currentIndex >= 0 && _currentIndex < _parsed.targets.length)
      ? _parsed.targets[_currentIndex]
      : null;

  int get maxWorks => _maxWorks;

  bool get allParts => _allParts;

  int get settledCount => _parsed.targets.where((t) => t.isSettled).length;

  int get failedCount =>
      _parsed.targets.where((t) => t.status == BiliBatchStatus.failed).length;

  /// 各目标累计认出来的稿件数
  int get totalCollected =>
      _parsed.targets.fold(0, (sum, t) => sum + t.collected);

  /// 各目标累计**提交下载**的分 P 数
  int get totalQueued =>
      _parsed.targets.fold(0, (sum, t) => sum + (t.run?.queued ?? 0));

  /// 累计「本期不支持、已跳过」的条目数（收藏夹里混的那些）
  int get totalUnsupported =>
      _parsed.targets.fold(0, (sum, t) => sum + t.skippedUnsupported);

  /// 累计台账里已处理过而跳过的分 P 数
  int get totalLedgerSkipped =>
      _parsed.targets.fold(0, (sum, t) => sum + (t.run?.skippedLedger ?? 0));

  bool get allSettled => hasTargets && settledCount == total;

  /// 自建收藏夹列表。空 = 还没拿到（未登录或接口没回东西）。
  List<BiliFavFolder> get favFolders => _favFolders;

  /// 拿不到列表时的那句话（界面据此提示「请直接贴收藏夹链接」）。
  String get favFoldersNote => _favFoldersNote;

  // ── 写入 ──────────────────────────────────────────────────

  /// 更新目标文本并重新解析。运行中不接受修改 —— 换掉列表会让下标错位。
  void setRawText(String v) {
    if (_running || _rawText == v) return;
    _rawText = v;
    _parsed = parseBiliTargets(v, maxTargets: kMaxTargets);
    _currentIndex = -1;
    notifyListeners();
  }

  void clearText() => setRawText('');

  void setMaxWorks(int v) {
    if (_maxWorks == v) return;
    _maxWorks = v;
    notifyListeners();
  }

  void setAllParts(bool v) {
    if (_allParts == v) return;
    _allParts = v;
    notifyListeners();
  }

  /// 收藏夹列表落地。[note] 非空表示「没拿到」，界面要说降级话而不是显示空下拉。
  void setFavFolders(List<BiliFavFolder> folders, {String note = ''}) {
    _favFolders = folders;
    _favFoldersNote = note;
    notifyListeners();
  }

  /// 把一条收藏夹直接加进目标文本 —— 下拉里选中之后不用用户自己拼链接。
  ///
  /// 已经在文本里就不加（重复行会被 [biliTargetKey] 去掉，但那等于让用户
  /// 看见「点了没反应」，不如在这里就明确不加）。
  bool addFavFolderTarget(BiliFavFolder folder) {
    // 写回去的**只能**是那串 id：`fid=` 与 `ml…` 两种链接写法会因写法不同产生
    // 两行同样的目标，而 id 既最短又一定指回同一个收藏夹。
    // 尾部不能跟标题 —— 一行里混了别的字符就不再是「纯数字」，会掉进 rejected。
    final probe = biliTargetRef('${folder.mediaId}');
    if (probe == null ||
        _parsed.targets.any(
          (t) => biliTargetKey(t.ref) == biliTargetKey(probe),
        )) {
      return false;
    }
    final line = '${folder.mediaId}';
    setRawText(_rawText.isEmpty ? line : '$_rawText\n$line');
    return true;
  }

  /// 开始跑批。列表为空时什么都不做（界面侧应已禁用按钮）。
  void start() {
    if (_running || _parsed.targets.isEmpty) return;
    for (final t in _parsed.targets) {
      t.reset();
    }
    _currentIndex = 0;
    _running = true;
    notifyListeners();
  }

  /// 请求停止。正在跑的那一条会跑完当前这一步（循环里看 `running == false`）。
  void stop() {
    if (!_running) return;
    _running = false;
    notifyListeners();
  }

  /// 一轮跑完（正常结束或被停止之后由页面调），把「运行中」放下来。
  ///
  /// 与 [stop] 的分工：`stop` 是「用户按了停止」，之后循环还得看见
  /// `running == false` 才走得掉；`finish` 是循环自己收的尾。
  void finish() {
    if (!_running) return;
    _running = false;
    notifyListeners();
  }

  /// 把当前目标推到下一个。
  void advance() {
    _currentIndex++;
    notifyListeners();
  }

  /// 标状态 + 刷新（页面每一步都调这里，而不是自己 setState）。
  void mark(BiliBatchTarget t, BiliBatchStatus s, {String? error}) {
    t.status = s;
    if (error != null) t.error = error;
    notifyListeners();
  }

  /// 界面需要重画时调（跑批过程中每翻一页都会调）。
  void refresh() => notifyListeners();
}
