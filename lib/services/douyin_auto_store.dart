import 'package:flutter/foundation.dart';

import '../models/douyin_auto_task.dart';
import '../models/media.dart';
import 'douyin_store.dart';

/// 单次目标收集用的媒体收集器。
///
/// **为什么不复用 [DouyinStore]**：那个 store 是「当前浏览页面」的结果仓库，
/// 自动下载跑批时每个目标都要一份干净的收集结果，混进用户的浏览结果里
/// 只会互相打扰（而且它按 URL 分桶、带勾选状态，跑批完全不需要）。
///
/// 去重按媒体 id：抖音一个页面会反复下发同一批作品，不去重列表会瞬间爆掉。
class DouyinAutoCollector {
  final List<Media> _items = [];
  final Set<String> _ids = {};

  /// 原始 aweme 条数（图集只算一条，与参照实现口径一致）
  int _aweme = 0;

  int get awemeCount => _aweme;

  int get count => _items.length;

  List<Media> get items => List.unmodifiable(_items);

  void noteAweme(int n) {
    if (n > 0) _aweme += n;
  }

  /// 并入一批媒体，返回真正新增的条数。
  int ingest(List<Media> incoming) {
    var added = 0;
    for (final m in incoming) {
      if (_ids.add(m.id)) {
        _items.add(m);
        added++;
      }
    }
    return added;
  }
}

/// [parseDouyinTargets] 的结果。
class DouyinTargetParse {
  const DouyinTargetParse(this.tasks, this.rejected, this.truncated);

  /// 认出来的目标（已按地址去重）
  final List<DouyinAutoTask> tasks;

  /// 认不出来的原始行 —— 回显给用户，免得他以为自己写的东西生效了
  final List<String> rejected;

  /// 因为超出上限被丢掉的目标数
  final int truncated;
}

/// 从一段文本里解析出待处理的目标。**一行一个**。
///
/// 支持的写法：
///   - `https://www.douyin.com/user/MS4wLjABAAAA...`（作者主页）
///   - `https://www.douyin.com/video/7412345678901234567`（作品）
///   - `v.douyin.com/xxxx/`（短链，WebView 自己跟 302）
///   - `7412345678901234567`（纯作品 ID）
///   - 分享口令：`7.32 复制打开抖音，看看【xxx】 https://v.douyin.com/xxxx/`
///     —— 整段粘进来也能认，会自己把链接抠出来
///
/// 空行忽略；同一个地址只保留第一次出现的那个。
DouyinTargetParse parseDouyinTargets(String text, {int maxTargets = 200}) {
  final tasks = <DouyinAutoTask>[];
  final rejected = <String>[];
  final seen = <String>{};
  var truncated = 0;

  for (final line in text.split(RegExp(r'\r?\n'))) {
    final raw = line.trim();
    if (raw.isEmpty) continue;

    final url = normalizeDouyinUrl(raw);
    if (url == null) {
      rejected.add(raw);
      continue;
    }
    if (!seen.add(url)) continue;
    if (tasks.length >= maxTargets) {
      truncated++;
      continue;
    }
    tasks.add(DouyinAutoTask(input: raw, url: url));
  }

  return DouyinTargetParse(tasks, rejected, truncated);
}

/// 「自动下载」的状态。
///
/// **职责边界**：这里只存「有哪些目标 / 每个跑到哪一步 / 选项是什么」，
/// 不碰 WebView、不碰 aria2 —— 真正的执行循环在 `DouyinAutoPage` 里，
/// 因为它需要页面持有的 `WebviewController`。这样 store 是纯数据，
/// 切页面不丢进度（与 X 模块 `AutoTaskStore` 的取舍一致）。
class DouyinAutoStore extends ChangeNotifier {
  /// 目标数上限。太多了跑一晚上也跑不完，列表也会卡。
  static const int kMaxTargets = 200;

  /// 「每个目标最多滚几轮」的可选项。
  ///
  /// 给档位而不是自由输入：这个值的含义对用户是模糊的（一轮≈700ms），
  /// 给几个档位配文字说明比让他填数字有用。
  /// 一轮 = 把页面**直接跳到底**一次，抖音作者主页每页约 17~20 条，
  /// 所以轮数≈翻页数：100 轮约 1800 条作品。
  ///
  /// 上限给到 100 是为了作品上千的大号；正常情况下会先被
  /// 「连续 6 轮高度没变」判定到底而提前结束，不会白跑满。
  static const List<int> kRoundChoices = [5, 10, 15, 25, 40, 60, 100];

  String _rawText = '';
  DouyinTargetParse _parsed = const DouyinTargetParse([], [], 0);

  bool _running = false;
  int _currentIndex = -1;
  int _maxRounds = 15;
  bool _autoDownload = true;

  // ── 只读 ──────────────────────────────────────────────────

  String get rawText => _rawText;

  List<DouyinAutoTask> get tasks => List.unmodifiable(_parsed.tasks);

  List<String> get rejected => List.unmodifiable(_parsed.rejected);

  int get truncated => _parsed.truncated;

  int get total => _parsed.tasks.length;

  bool get hasTargets => _parsed.tasks.isNotEmpty;

  bool get running => _running;

  /// 正在跑第几个（-1 = 还没开始）
  int get currentIndex => _currentIndex;

  DouyinAutoTask? get current =>
      (_currentIndex >= 0 && _currentIndex < _parsed.tasks.length)
      ? _parsed.tasks[_currentIndex]
      : null;

  int get maxRounds => _maxRounds;

  bool get autoDownload => _autoDownload;

  /// 已经跑完的条数
  int get settledCount => _parsed.tasks.where((t) => t.status.isSettled).length;

  int get failedCount =>
      _parsed.tasks.where((t) => t.status == DouyinAutoStatus.failed).length;

  /// 累计收集到的作品数
  int get totalAweme => _parsed.tasks.fold(0, (sum, t) => sum + t.awemeCount);

  /// 累计提交下载的条数
  int get totalQueued => _parsed.tasks.fold(0, (sum, t) => sum + t.queued);

  /// 累计跳过（已下载）的作品数
  int get totalSkipped =>
      _parsed.tasks.fold(0, (sum, t) => sum + t.skippedDownloaded);

  /// 全部跑完了吗（用于工具栏文案）
  bool get allSettled => hasTargets && settledCount == total;

  // ── 写入 ──────────────────────────────────────────────────

  /// 更新目标文本并重新解析。运行中不接受修改 —— 换掉列表会让下标错位。
  void setRawText(String v) {
    if (_running || _rawText == v) return;
    _rawText = v;
    _parsed = parseDouyinTargets(v, maxTargets: kMaxTargets);
    // 列表换了，之前的下标/状态全部作废
    _currentIndex = -1;
    notifyListeners();
  }

  void clearText() => setRawText('');

  void setMaxRounds(int v) {
    if (_maxRounds == v) return;
    _maxRounds = v;
    notifyListeners();
  }

  void setAutoDownload(bool v) {
    if (_autoDownload == v) return;
    _autoDownload = v;
    notifyListeners();
  }

  /// 开始跑批。列表为空时什么都不做（界面侧应已禁用按钮）。
  void start() {
    if (_running || _parsed.tasks.isEmpty) return;
    for (final t in _parsed.tasks) {
      t.reset();
    }
    _currentIndex = 0;
    _running = true;
    notifyListeners();
  }

  /// 请求停止。当前这一轮会跑完（下载循环里会看到 `running == false` 提前退出）。
  void stop() {
    if (!_running) return;
    _running = false;
    notifyListeners();
  }

  /// 把当前目标推到下一个。
  void advance() {
    _currentIndex++;
    notifyListeners();
  }

  /// 界面需要重画时调（跑批过程中每滚一轮都会调）。
  void refresh() => notifyListeners();
}
