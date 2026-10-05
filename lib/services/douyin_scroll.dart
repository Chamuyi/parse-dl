import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 滚轮合并时间窗：约一帧。一次滑动会来好几格，合并成一次脚本调用，
/// 免得每个刻度都走一次 Flutter → JS 的往返（那会明显发涩）。
const Duration kScrollFlushInterval = Duration(milliseconds: 16);

/// 一次待消费的滚动量（CSS 像素）
@immutable
class ScrollDelta {
  const ScrollDelta(this.dx, this.dy);

  final double dx;
  final double dy;

  bool get isZero => dx == 0 && dy == 0;

  @override
  String toString() => 'ScrollDelta($dx, $dy)';
}

/// 把连续多个滚轮刻度累加起来，等时间窗到了再一次性取走。
class ScrollAccumulator {
  double _dx = 0;
  double _dy = 0;

  bool get hasPending => _dx != 0 || _dy != 0;

  double get pendingDx => _dx;
  double get pendingDy => _dy;

  void add(double dx, double dy) {
    if (dx == 0 && dy == 0) return; // 空事件不产生「待处理」，免得空转
    _dx += dx;
    _dy += dy;
  }

  /// 取走并清零
  ScrollDelta take() {
    final d = ScrollDelta(_dx, _dy);
    _dx = 0;
    _dy = 0;
    return d;
  }

  void clear() {
    _dx = 0;
    _dy = 0;
  }
}

/// 数字规整：整数不带小数点，小数最多两位。
/// 一是让脚本短，二是**不出现 53.333333333333336 这种浮点尾巴**。
String formatScrollNumber(double v) {
  if (v.isNaN || v.isInfinite) return '0';
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(2);
}

/// 生成「按真实鼠标坐标找可滚容器并滚动」的脚本。
///
/// 为什么必须自己做（实测结论见 `evidence/wheel-rootcause.log`）：
/// `webview_windows` 0.4.0 的 `Webview::SendScroll`（windows/webview.cc:587）把
/// 注入点写死成客户区左上角 `POINT{0,0}`，于是滚轮永远落在 (0,0) 那个元素上。
/// 抖音精选页真正能滚的容器是 `DIV._bpJj4nI`（left=72 top=108），根本不在
/// 那个点上 —— 事件冒泡到不可滚的 document，页面**一格都不动**。
/// 实测：真实滚轮 5 格 → 页面收到 10 个 wheel 事件，全部 `cx=0, cy=0`，
/// 且没有任何容器 scrollTop 变化；而用 CDP 在真实坐标派发同样的滚轮，
/// 容器立刻滚了 600px。
///
/// 另外插件的 `delta * 6` 换算也是错的（实测一个刻度被 WebView2 拆成 2 个
/// `deltaY=500` 的事件），所以这里**不做任何倍数换算**：Flutter 给的
/// `scrollDelta` 本身就是逻辑像素，直接当 CSS 像素用，手感与浏览器原生一致。
///
/// 找容器的顺序：
///   1. `elementFromPoint(鼠标位置)` 起，一路向父级找第一个「该方向真能滚」的
///      元素 —— **不设层数上限**（抖音的滚动容器埋得很深，实测 8 层探针够不到）；
///   2. 找不到就退而求其次：页面上**面积最大**的可滚容器（抖音精选正是这种）；
///   3. 再退到 `document.scrollingElement`（普通网页）。
String buildScrollScript({
  required double dx,
  required double dy,
  required double x,
  required double y,
}) {
  final sx = formatScrollNumber(x);
  final sy = formatScrollNumber(y);
  final sdx = formatScrollNumber(dx);
  final sdy = formatScrollNumber(dy);

  return '''
(function () {
  var x = $sx, y = $sy, dx = $sdx, dy = $sdy;

  // 这个元素在该方向上还能不能滚
  function canScroll(el) {
    if (!el || el.nodeType !== 1) return false;
    var st = window.getComputedStyle(el);
    if (dy !== 0) {
      var oy = st.overflowY;
      if (oy !== 'auto' && oy !== 'scroll' && oy !== 'overlay') return false;
      if (el.scrollHeight <= el.clientHeight + 1) return false;
      if (dy > 0 && el.scrollTop + el.clientHeight >= el.scrollHeight - 1) return false;
      if (dy < 0 && el.scrollTop <= 0) return false;
      return true;
    }
    var ox = st.overflowX;
    if (ox !== 'auto' && ox !== 'scroll' && ox !== 'overlay') return false;
    if (el.scrollWidth <= el.clientWidth + 1) return false;
    if (dx > 0 && el.scrollLeft + el.clientWidth >= el.scrollWidth - 1) return false;
    if (dx < 0 && el.scrollLeft <= 0) return false;
    return true;
  }

  // ① 从鼠标真正指着的元素向上找（不设层数上限）
  var hit = null;
  var node = document.elementFromPoint(x, y);
  while (node) {
    if (canScroll(node)) { hit = node; break; }
    node = node.parentElement;
  }

  // ② 兜底：页面上面积最大的可滚容器（抖音精选的滚动区就属于这种）
  if (!hit) {
    var best = null;
    var bestArea = 0;
    var all = document.querySelectorAll('div,main,section,article,ul,ol');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (!canScroll(el)) continue;
      var r = el.getBoundingClientRect();
      var area = r.width * r.height;
      if (area > bestArea) { bestArea = area; best = el; }
    }
    hit = best;
  }

  // ③ 再兜底：文档本身
  if (!hit) {
    var se = document.scrollingElement || document.documentElement;
    if (se && canScroll(se)) hit = se;
  }

  var before = hit ? hit.scrollTop : (window.pageYOffset || 0);
  if (hit) {
    if (dx) hit.scrollLeft += dx;
    if (dy) hit.scrollTop += dy;
  } else {
    window.scrollBy(dx, dy);
  }
  var after = hit ? hit.scrollTop : (window.pageYOffset || 0);

  var cls = '';
  if (hit && typeof hit.className === 'string') cls = hit.className.split(' ')[0];
  var name = hit ? (hit.tagName + (cls ? '.' + cls : '')) : 'window';

  return JSON.stringify({
    ok: true,
    hit: name,
    before: before,
    after: after,
    moved: Math.round(after - before)
  });
})()
''';
}

/// 页面脚本的回报，用于写日志（「到底滚了没有、滚的是谁」）。
@immutable
class ScrollOutcome {
  const ScrollOutcome({
    required this.hit,
    required this.moved,
    required this.before,
    required this.after,
    this.error,
  });

  /// 命中的容器（`DIV._bpJj4nI` 这种），或 `window`
  final String hit;

  /// 实际滚动的像素（0 = 没动，正是修复前的症状）
  final int moved;

  final double before;
  final double after;

  /// 出错信息（脚本抛错 / 返回值无法解析）
  final String? error;

  bool get effective => error == null && moved != 0;

  String get describe {
    if (error != null) return '滚动失败：$error';
    return '滚了 $hit $moved px（$before → $after）';
  }

  static ScrollOutcome decode(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) {
      return const ScrollOutcome(
        hit: '',
        moved: 0,
        before: 0,
        after: 0,
        error: '页面没有返回任何内容',
      );
    }

    try {
      var parsed = jsonDecode(text);
      // `executeScript` 有的实现会把结果再包一层引号，这里兼容一下
      if (parsed is String) parsed = jsonDecode(parsed);
      if (parsed is! Map) {
        return ScrollOutcome(
          hit: '',
          moved: 0,
          before: 0,
          after: 0,
          error: '返回值格式不是对象：$text',
        );
      }
      if (parsed['ok'] == false) {
        return ScrollOutcome(
          hit: '',
          moved: 0,
          before: 0,
          after: 0,
          error: parsed['error']?.toString() ?? '页面脚本执行失败',
        );
      }
      return ScrollOutcome(
        hit: parsed['hit']?.toString() ?? '',
        moved: _asInt(parsed['moved']),
        before: _asDouble(parsed['before']),
        after: _asDouble(parsed['after']),
      );
    } catch (e) {
      return ScrollOutcome(
        hit: '',
        moved: 0,
        before: 0,
        after: 0,
        error: '返回值无法解析：$e',
      );
    }
  }

  static int _asInt(Object? v) {
    if (v is num) return v.round();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static double _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0;
  }
}

// ── 自动滚动加载更多 ─────────────────────────────────────────────
//
// 对齐参照实现的「自动加载」：一直往下滚，让抖音把下一页内容也吐出来。
// **风险不在滚动本身，而在什么时候停** —— 停不下来会一直发请求
// （限流、弹验证码），停太早又抓不满。所以决策逻辑做成纯状态机，
// 用测试把停止条件钉死。

/// 自动滚动为什么停
enum AutoScrollStopReason {
  /// 用户手动停
  stopped,

  /// 到了轮次上限
  reachedMaxRounds,

  /// 连续若干轮页面高度没变化 → 到底了
  noGrowth,

  /// 出错（脚本异常 / WebView 没了）
  error;

  String get label => switch (this) {
        AutoScrollStopReason.stopped => '已手动停止',
        AutoScrollStopReason.reachedMaxRounds => '已达本次滚动上限',
        AutoScrollStopReason.noGrowth => '已到底（没有更多内容）',
        AutoScrollStopReason.error => '出错停止',
      };
}

/// 自动滚动的状态机（纯逻辑，可单测）
class DouyinAutoScroller {
  DouyinAutoScroller({
    this.maxRounds = 20,
    this.stallLimit = 6,
    this.interval = const Duration(milliseconds: 700),
  });

  /// 最多滚多少轮
  final int maxRounds;

  /// 连续多少轮「高度没变」就判定到底。
  ///
  /// 6 轮 ≈ 4 秒。原来是 3 轮（2.1 秒），但抖音作者主页翻下一页要发一次
  /// 游标请求，网稍慢就超过 2 秒 —— 那时会被误判成"到底了"提前收工，
  /// 表现就是作品多的号只抓到前几十条。误判到底比多等几轮代价大得多。
  final int stallLimit;

  /// 两轮之间的间隔（给页面留出加载时间）
  final Duration interval;

  int _rounds = 0;
  int _stalls = 0;
  double _lastHeight = 0;
  bool _running = false;
  AutoScrollStopReason? _stopReason;

  bool get running => _running;
  int get rounds => _rounds;
  int get stalls => _stalls;
  double get lastHeight => _lastHeight;
  AutoScrollStopReason? get stopReason => _stopReason;

  /// 开始（已在跑就什么都不做，防手抖连点把进度重置）
  void start() {
    if (_running) return;
    _running = true;
    _stopReason = null;
    _rounds = 0;
    _stalls = 0;
    _lastHeight = 0;
  }

  void stop([AutoScrollStopReason reason = AutoScrollStopReason.stopped]) {
    if (!_running) return;
    _running = false;
    _stopReason = reason;
  }

  /// 每滚完一轮，把页面当前的 `scrollHeight` 交回来。
  ///
  /// 返回「是否继续」。停止条件：高度不再增长（连续 [stallLimit] 轮）
  /// 或到达 [maxRounds]。
  bool onRoundResult(double scrollHeight) {
    if (!_running) return false;

    _rounds++;

    // 1px 以内的抖动不算「长高了」
    if (scrollHeight > _lastHeight + 1) {
      _lastHeight = scrollHeight;
      _stalls = 0;
    } else {
      _stalls++;
      if (_stalls >= stallLimit) {
        stop(AutoScrollStopReason.noGrowth);
        return false;
      }
    }

    if (_rounds >= maxRounds) {
      stop(AutoScrollStopReason.reachedMaxRounds);
      return false;
    }
    return true;
  }

  /// 界面上的进度摘要
  String get describe => '已滚 $_rounds 次';
}

/// 自动加载用的脚本：把页面里**面积最大的可滚容器**滚到底，
/// 然后回报 `scrollHeight` 供状态机判断有没有新内容。
String buildAutoScrollScript() => '''
(function () {
  function scrollable(el) {
    if (!el || el.nodeType !== 1) return false;
    var st = window.getComputedStyle(el);
    var oy = st.overflowY;
    if (oy !== 'auto' && oy !== 'scroll' && oy !== 'overlay') return false;
    return el.scrollHeight > el.clientHeight + 1;
  }

  var best = null;
  var bestArea = 0;
  var all = document.querySelectorAll('div,main,section,article,ul,ol');
  for (var i = 0; i < all.length; i++) {
    var el = all[i];
    if (!scrollable(el)) continue;
    var r = el.getBoundingClientRect();
    var area = r.width * r.height;
    if (area > bestArea) { bestArea = area; best = el; }
  }

  var target = best || document.scrollingElement || document.documentElement;
  var before = target.scrollTop;
  target.scrollTop = target.scrollHeight;
  var after = target.scrollTop;

  var cls = '';
  if (target && typeof target.className === 'string') cls = target.className.split(' ')[0];
  var name = target ? (target.tagName + (cls ? '.' + cls : '')) : 'window';

  return JSON.stringify({
    ok: true,
    hit: name,
    scrollHeight: target ? target.scrollHeight : 0,
    moved: Math.round(after - before)
  });
})()
''';

/// 自动加载每轮的页面回报
@immutable
class AutoScrollReport {
  const AutoScrollReport({
    required this.scrollHeight,
    required this.moved,
    this.hit = '',
    this.error,
  });

  final double scrollHeight;
  final int moved;
  final String hit;
  final String? error;

  static AutoScrollReport decode(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) {
      return const AutoScrollReport(
        scrollHeight: 0,
        moved: 0,
        error: '页面没有返回任何内容',
      );
    }
    try {
      var parsed = jsonDecode(text);
      if (parsed is String) parsed = jsonDecode(parsed);
      if (parsed is! Map) {
        return AutoScrollReport(
          scrollHeight: 0,
          moved: 0,
          error: '返回值格式不是对象：$text',
        );
      }
      if (parsed['ok'] == false) {
        return AutoScrollReport(
          scrollHeight: 0,
          moved: 0,
          error: parsed['error']?.toString() ?? '页面脚本执行失败',
        );
      }
      return AutoScrollReport(
        scrollHeight: ScrollOutcome._asDouble(parsed['scrollHeight']),
        moved: ScrollOutcome._asInt(parsed['moved']),
        hit: parsed['hit']?.toString() ?? '',
      );
    } catch (e) {
      return AutoScrollReport(
        scrollHeight: 0,
        moved: 0,
        error: '返回值无法解析：$e',
      );
    }
  }
}
