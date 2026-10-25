using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;

namespace ParseDl.Services.Douyin;

/// <summary>自动滚动为什么停。</summary>
public enum DouyinAutoScrollStop { Stopped, ReachedMaxRounds, NoGrowth, Error }

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

    private int _rounds;
    private int _stalls;
    private double _lastHeight;
    private bool _running;
    private DouyinAutoScrollStop? _stopReason;

    public DouyinAutoScroller(int maxRounds = 20, int stallLimit = 6, TimeSpan? interval = null)
    {
        MaxRounds = maxRounds < 1 ? 1 : maxRounds;
        StallLimit = stallLimit < 1 ? 1 : stallLimit;
        Interval = interval ?? TimeSpan.FromMilliseconds(700);
    }

    public bool Running => _running;
    public int Rounds => _rounds;
    public int Stalls => _stalls;
    public double LastHeight => _lastHeight;
    public DouyinAutoScrollStop? StopReason => _stopReason;

    /// <summary>开始（已在跑就什么都不做，防手抖连点把进度重置）。</summary>
    public void Start()
    {
        if (_running) return;
        _running = true;
        _stopReason = null;
        _rounds = 0;
        _stalls = 0;
        _lastHeight = 0;
    }

    public void Stop(DouyinAutoScrollStop reason = DouyinAutoScrollStop.Stopped)
    {
        if (!_running) return;
        _running = false;
        _stopReason = reason;
    }

    /// <summary>
    /// 每滚完一轮，把页面当前的 scrollHeight 交回来；返回「是否继续」。
    /// 停止条件：高度不再增长（连续 StallLimit 轮）或到达 MaxRounds。
    /// </summary>
    public bool OnRoundResult(double scrollHeight)
    {
        if (!_running) return false;
        _rounds++;

        // 1px 以内的抖动不算「长高了」
        if (scrollHeight > _lastHeight + 1)
        {
            _lastHeight = scrollHeight;
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
        _ => "出错停止",
    };
}

/// <summary>自动加载每轮的页面回报。</summary>
public sealed class DouyinAutoScrollReport
{
    public double ScrollHeight { get; init; }
    public int Moved { get; init; }
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
                Moved = (int)Num(root, "moved"),
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
    moved: Math.round(after - before)
  });
})()
""".Replace("STEP_PX", px.ToString(CultureInfo.InvariantCulture));
}
