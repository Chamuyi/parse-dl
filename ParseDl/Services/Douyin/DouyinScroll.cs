using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;

namespace ParseDl.Services.Douyin;

/// <summary>自动滚动为什么停。</summary>
public enum DouyinAutoScrollStop { Stopped, ReachedMaxRounds, NoGrowth, Error, CaughtUp }

/// <summary>
/// 自动滚动的状态机（纯逻辑，可单测）—— 对齐 Flutter 版 douyin_scroll.dart 的
/// DouyinAutoScroller。风险不在滚动本身，而在**什么时候停**：停不下来会一直发请求
/// （限流、弹验证码），停太早又抓不满。所以停止条件用测试钉死。
/// </summary>
public sealed class DouyinAutoScroller
{
    public int MaxRounds { get; }
    /// <summary>连续多少轮「高度没变」就判定到底。6 轮 ≈ 4 秒 —— 原来是 3 轮（2.1 秒），
    /// 抖音作者主页翻下一页要发游标请求，网稍慢就超 2 秒，会被误判成「到底了」提前收工。</summary>
    public int StallLimit { get; }
    public TimeSpan Interval { get; }

    /// <summary>是否启用「追平即停」（2026-11-18）。false 时整条逻辑不参与，行为退回旧版。</summary>
    public bool CatchUpStop { get; }
    /// <summary>连续多少个作品已在台账里就判定「已追平」。</summary>
    public int CatchUpStreak { get; }

    private int _rounds;
    private int _stalls;
    private double _lastHeight;
    private double _lastTop;
    private bool _running;
    private DouyinAutoScrollStop? _stopReason;

    /// <summary>当前「连续已在台账里」的计数（跨批累计，遇到新作品清零）。</summary>
    private int _catchUpRun;
    /// <summary>已追平时撞上的连续条数（写日志用）。</summary>
    private int _catchUpAt;

    public DouyinAutoScroller(
        int maxRounds = 20,
        int stallLimit = 6,
        TimeSpan? interval = null,
        bool catchUpStop = false,
        int catchUpStreak = 20)
    {
        MaxRounds = maxRounds < 1 ? 1 : maxRounds;
        StallLimit = stallLimit < 1 ? 1 : stallLimit;
        Interval = interval ?? TimeSpan.FromMilliseconds(700);
        CatchUpStop = catchUpStop;
        CatchUpStreak = catchUpStreak < 1 ? 1 : catchUpStreak;
    }

    public bool Running => _running;
    public int Rounds => _rounds;
    public int Stalls => _stalls;
    public double LastHeight => _lastHeight;
    public DouyinAutoScrollStop? StopReason => _stopReason;
    /// <summary>追平时撞到的连续「已下过」条数；未追平为 0。</summary>
    public int CatchUpAt => _catchUpAt;

    /// <summary>开始（已在跑就什么都不做，防手抖连点把进度重置）。</summary>
    public void Start()
    {
        if (_running) return;
        _running = true;
        _stopReason = null;
        _rounds = 0;
        _stalls = 0;
        _lastHeight = 0;
        _lastTop = 0;
        _catchUpRun = 0;
        _catchUpAt = 0;
    }

    public void Stop(DouyinAutoScrollStop reason = DouyinAutoScrollStop.Stopped)
    {
        if (!_running) return;
        _running = false;
        _stopReason = reason;
    }

    /// <summary>
    /// 把「本批作品里哪些是台账里已有的」喂进来；返回是否应当继续滚动。
    ///
    /// **按列表顺序逐条判**，而不是只看这批的统计 —— 抖音按发布时间倒序排列，
    /// 所以「连续 <see cref="CatchUpStreak"/> 条都下过」才是「已经追平上次位置」的可靠信号；
    /// 而「这批 80% 都下过」在中间夹着新作品时也会成立，那个判据会漏抓。
    ///
    /// 遇到任何**未下载**的作品就清零重来：说明还没追到交界处，得继续往下滚。
    /// </summary>
    /// <param name="alreadyDownloaded">按页面出现顺序排列的「是否已在台账里」。</param>
    public bool OnBatchSeen(IReadOnlyList<bool> alreadyDownloaded)
    {
        if (!_running || !CatchUpStop) return _running;

        for (var i = 0; i < alreadyDownloaded.Count; i++)
        {
            if (alreadyDownloaded[i])
            {
                _catchUpRun++;
                if (_catchUpRun >= CatchUpStreak)
                {
                    _catchUpAt = _catchUpRun;
                    Stop(DouyinAutoScrollStop.CaughtUp);
                    return false;
                }
            }
            else
            {
                // 撞到新作品 —— 交界处还在下面，计数清零。
                _catchUpRun = 0;
            }
        }
        return true;
    }

    /// <summary>
    /// 每滚完一轮，把页面当前的滚动状态交回来；返回「是否继续」。
    ///
    /// ### 2026-10-31 重写「到底」判定（用户报「没滚到底就切下一个人主页」）
    ///
    /// 老实现只看 `scrollHeight` 是否增长。**抖音是虚拟滚动**：列表容器高度
    /// 往往在首屏就定死（或只长一点点），后续内容靠回收 DOM + 追加数据，
    /// 于是 scrollHeight 一半天都不变 —— 连续 StallLimit 轮就被误判成「到底」。
    /// 更糟的是调用侧原先还有一条「识别到 >0 个作品就立刻停」，两刀砍下来
    /// 一个主页通常只抓到首屏那十几个就切下一个人了。
    ///
    /// 现在改成**三条都为真才算到底**：
    ///   ① 本轮 `scrollTop` 没有前进（已经把 scrollHeight 走完了）；
    ///   ② `scrollHeight` 也没增长（没有新内容灌进来）；
    ///   ③ 连续满足 StallLimit 轮（给慢网/慢游标请求留缓冲）。
    /// 任一条不满足就继续滚。这样虚拟滚动「容器不涨但内容在换」也能一直滚下去。
    /// </summary>
    /// <param name="scrollHeight">容器当前 scrollHeight。</param>
    /// <param name="scrollTop">容器当前 scrollTop（滚动位置）。</param>
    /// <param name="moved">本轮实际移动了多少像素（0 = 已经到底、滚不动了）。</param>
    public bool OnRoundResult(double scrollHeight, double scrollTop = -1, double moved = -1)
    {
        if (!_running) return false;
        _rounds++;

        // 判断「这一轮有没有实质进展」：高度长高了 或 滚动位置前进了 都算。
        var heightGrew = scrollHeight > _lastHeight + 1;
        var positionAdvanced = scrollTop >= 0 && scrollTop > _lastTop + 1;
        // moved 明确为 0 且高度没长 —— 才是真的「滚不动了」
        var stuckInPlace = moved >= 0 && moved < 1;

        if (heightGrew) _lastHeight = scrollHeight;
        if (positionAdvanced) _lastTop = scrollTop;

        if (heightGrew || positionAdvanced || !stuckInPlace)
        {
            // 还有进展（或无法判断有没有停）→ 不算卡住
            _stalls = 0;
        }
        else
        {
            _stalls++;
            if (_stalls >= StallLimit)
            {
                Stop(DouyinAutoScrollStop.NoGrowth);
                return false;
            }
        }

        if (_rounds >= MaxRounds)
        {
            Stop(DouyinAutoScrollStop.ReachedMaxRounds);
            return false;
        }
        return true;
    }

    public string Describe => "已滚 " + _rounds + " 次";

    public static string LabelOf(DouyinAutoScrollStop r) => r switch
    {
        DouyinAutoScrollStop.Stopped => "已手动停止",
        DouyinAutoScrollStop.ReachedMaxRounds => "已达本次滚动上限",
        DouyinAutoScrollStop.NoGrowth => "已到底（没有更多内容）",
        DouyinAutoScrollStop.CaughtUp => "已追平上次抓到的位置",
        _ => "出错停止",
    };
}

/// <summary>自动加载每轮的页面回报。</summary>
public sealed class DouyinAutoScrollReport
{
    public double ScrollHeight { get; init; }
    /// <summary>容器当前 scrollTop（-1 = 脚本没回报）。判定「滚不动了」要用它。</summary>
    public double ScrollTop { get; init; } = -1;
    public int Moved { get; init; }
    /// <summary>可滚容器的高度（视口高度，px）；0 = 脚本没回报。用于判断「一屏内就到头」。</summary>
    public double Viewport { get; init; }
    public string Hit { get; init; } = "";
    public string? Error { get; init; }

    public static DouyinAutoScrollReport Decode(string? raw)
    {
        var text = (raw ?? "").Trim();
        if (text.Length == 0)
            return new DouyinAutoScrollReport { Error = "页面没有返回任何内容" };
        try
        {
            // ExecuteScriptAsync 的返回值是 JSON 编码过的字符串（外层带引号）
            text = UnquoteJsonString(text);
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return new DouyinAutoScrollReport { Error = "返回值格式不是对象：" + text };
            return new DouyinAutoScrollReport
            {
                ScrollHeight = Num(root, "scrollHeight"),
                ScrollTop = root.TryGetProperty("scrollTop", out _) ? Num(root, "scrollTop") : -1,
                Moved = (int)Num(root, "moved"),
                Viewport = Num(root, "viewport"),
                Hit = Str(root, "hit"),
            };
        }
        catch (Exception ex)
        {
            return new DouyinAutoScrollReport { Error = "返回值无法解析：" + ex.Message };
        }
    }

    internal static double Num(JsonElement el, string name)
    {
        if (!el.TryGetProperty(name, out var v)) return 0;
        if (v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d)) return d;
        if (v.ValueKind == JsonValueKind.String
            && double.TryParse(v.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var p)) return p;
        return 0;
    }

    internal static string Str(JsonElement el, string name)
        => el.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";

    /// <summary>ExecuteScriptAsync 返回的是 JSON 编码过的字符串（带外层引号与转义）。</summary>
    internal static string UnquoteJsonString(string raw)
    {
        var t = raw.Trim();
        if (t.Length < 2 || t[0] != '"') return t;
        try { return JsonSerializer.Deserialize<string>(t) ?? t; }
        catch { return t; }
    }
}

/// <summary>抖音页用到的两段页面脚本。</summary>
public static class DouyinScripts
{
    /// <summary>
    /// 自动加载：把页面里**面积最大的可滚容器**滚到底，然后回报 scrollHeight
    /// 供状态机判断有没有新内容。之所以要自己找容器：抖音精选页能滚的是
    /// 一个深埋的 div，滚 document 一格都不动。
    /// </summary>
    public const string AutoScroll = """
(function () {
  function scrollable(el) {
    if (!el || el.nodeType !== 1) return false;
    var st = window.getComputedStyle(el);
    var oy = st.overflowY;
    if (oy !== 'auto' && oy !== 'scroll' && oy !== 'overlay') return false;
    return el.scrollHeight > el.clientHeight + 1;
  }
  var best = null, bestArea = 0;
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
  // 直接跳到底（保持原行为）。**不要改成「每次滚一屏」**：抖音是虚拟滚动，
  // 列表到底后才会加载下一页，所以限制轮数的从来不是滚动距离，而是内容加载速度。
  // 跳到底 + 等新内容灌进来，每轮正好前进「已加载的一页」；改成小步滚反而让
  // 同样一段内容要花好几轮才走完，直接顶到 MaxRounds 上限、把抓取量砍掉。
  target.scrollTop = target.scrollHeight;
  var after = target.scrollTop;
  var cls = '';
  if (target && typeof target.className === 'string') cls = target.className.split(' ')[0];
  var name = target ? (target.tagName + (cls ? '.' + cls : '')) : 'window';
  return JSON.stringify({
    ok: true,
    hit: name,
    scrollHeight: target ? target.scrollHeight : 0,
    scrollTop: target ? target.scrollTop : 0,
    moved: Math.round(after - before),
    viewport: target ? target.clientHeight : 0
  });
})()
""";

    /// <summary>按配置的步长往下滚（小步慢滚，更接近真人）。</summary>
    public static string StepScroll(int px) => """
(function () {
  var step = STEP_PX;
  function scrollable(el) {
    if (!el || el.nodeType !== 1) return false;
    var st = window.getComputedStyle(el);
    var oy = st.overflowY;
    if (oy !== 'auto' && oy !== 'scroll' && oy !== 'overlay') return false;
    return el.scrollHeight > el.clientHeight + 1;
  }
  var best = null, bestArea = 0;
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
  target.scrollTop = before + step;
  var after = target.scrollTop;
  return JSON.stringify({
    ok: true,
    scrollHeight: target ? target.scrollHeight : 0,
    scrollTop: target ? target.scrollTop : 0,
    moved: Math.round(after - before)
  });
})()
""".Replace("STEP_PX", px.ToString(CultureInfo.InvariantCulture));
}
