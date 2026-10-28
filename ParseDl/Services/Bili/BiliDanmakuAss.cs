using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace ParseDl.Services.Bili;

/// <summary>一次 ASS 生成的结果。</summary>
public sealed record BiliDanmakuAssResult
{
    public string Ass { get; init; } = "";
    /// <summary>写进去的弹幕条数。</summary>
    public int Written { get; init; }
    /// <summary>跳过的特殊弹幕（mode 7/8：特效与代码弹幕，ASS 表示不了）。</summary>
    public int SpecialSkipped { get; init; }
}

/// <summary>
/// 弹幕 → ASS 字幕（移植自原项目 bili_danmaku.dart 的 `biliDanmakuToAss`）。
///
/// ### 为什么需要
/// WinUI3 版原来只有 XML 导出，而用户真正要看弹幕得靠播放器挂 ASS。
/// 原项目有完整的排版逻辑（滚动/顶部/底部三种弹幕各自的轨道分配与防重叠），
/// 这里逐条搬过来。
///
/// ### 一个必须记住的坑（原项目注释里记着）
/// ASS 的 `\move` **是一对括号四个参数**：`\move(x1,y1,x2,y2)`。
/// 写成两对括号 `\move(x1,y1)(x2,y2)` 看着更自然，但**不是合法 ASS**，
/// 播放器认不出来会整个标签失效 —— 表现为所有滚动弹幕全挤在左上角不动。
/// </summary>
public static class BiliDanmakuAss
{
    // ── 排版常量（与原项目逐一对齐）──────────────────────────
    /// <summary>ASS 剧本分辨率：定的是**坐标系**而不是像素，libass 会按实际视频尺寸等比缩放。</summary>
    public const int PlayResX = 1920;
    public const int PlayResY = 1080;
    /// <summary>行高 = 字号 × 这个系数。1.3 覆盖「字高 + 行间余量」。</summary>
    public const double RowHeightFactor = 1.3;
    /// <summary>顶部/底部各自最多占几行。</summary>
    public const int TopRows = 3;
    public const int BottomRows = 3;
    /// <summary>滚动速度（px/s）。250 在 1920 宽下让普通弹幕约 8~9 秒走完。</summary>
    public const double ScrollPxPerSecond = 250;
    /// <summary>顶部/底部固定弹幕的停留时长（ms）。</summary>
    public const int FixedHoldMs = 5000;
    /// <summary>ASS 样式名。ASCII：它是脚本内的标识符，换中文会让只认 ASCII 的老 libass 出问题。</summary>
    public const string StyleName = "Danmaku";

    /// <summary>毫秒 → ASS 时间戳 `h:mm:ss.cc`。</summary>
    public static string AssTime(int ms)
    {
        if (ms < 0) ms = 0;
        var centis = ms / 10;
        var h = centis / 360000;
        var m = (centis / 6000) % 60;
        var s = (centis / 100) % 60;
        return h + ":" + m.ToString("00") + ":" + s.ToString("00") + "." + (centis % 100).ToString("00");
    }

    /// <summary>弹幕文本进 ASS 前：`{` `}` 是覆盖块定界符必须转义，换行压成空格。</summary>
    public static string EscapeAssText(string text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        return text.Replace("\r\n", " ").Replace("\n", " ").Replace("\r", " ")
                   .Replace("{", "\\{").Replace("}", "\\}");
    }

    /// <summary>弹幕颜色（B站是 RGB 整数）→ ASS 的 `&amp;HBBGGRR&amp;`（**注意是 BGR 序**）。</summary>
    public static string AssColor(long rgb, double opacity)
    {
        var r = (int)((rgb >> 16) & 0xFF);
        var g = (int)((rgb >> 8) & 0xFF);
        var b = (int)(rgb & 0xFF);
        // ASS 的 alpha 是「透明度」，0 = 不透明，255 = 全透明
        var a = (int)Math.Round((1.0 - Math.Clamp(opacity, 0.0, 1.0)) * 255.0);
        return "&H" + a.ToString("X2") + b.ToString("X2") + g.ToString("X2") + r.ToString("X2");
    }

    /// <summary>估算文本宽度（px）。全角按 1 em，ASCII 按 0.55 em，其它 0.8 em。</summary>
    public static int WidthOf(string text, int fontSize)
    {
        var em = 0.0;
        foreach (var ch in text ?? "")
        {
            var cp = (int)ch;
            if (IsWide(cp)) em += 1.0;
            else if (cp >= 0x20 && cp <= 0x7E) em += 0.55;
            else em += 0.8;
        }
        return (int)Math.Ceiling(em * fontSize);
    }

    /// <summary>东亚宽字符判定（CJK / 假名 / 谚文 / 全角标点）。</summary>
    private static bool IsWide(int cp) =>
        (cp >= 0x1100 && cp <= 0x115F) ||   // 谚文字母
        (cp >= 0x2E80 && cp <= 0xA4CF) ||   // CJK 部首 ~ 彝文
        (cp >= 0xAC00 && cp <= 0xD7A3) ||   // 谚文音节
        (cp >= 0xF900 && cp <= 0xFAFF) ||   // CJK 兼容
        (cp >= 0xFE30 && cp <= 0xFE4F) ||   // CJK 兼容标点
        (cp >= 0xFF00 && cp <= 0xFF60) ||   // 全角
        (cp >= 0xFFE0 && cp <= 0xFFE6);

    /// <summary>一行 Dialogue。</summary>
    private static string Dialogue(int startMs, int endMs, string over, string text)
        => "Dialogue: 0," + AssTime(startMs) + "," + AssTime(endMs) + "," + StyleName + ",,0,0,0,," + "{" + over + "}" + text;

    /// <summary>
    /// 轨道分配器：把「某时刻开始、持续 durMs」的弹幕放进一条不冲突的行。
    /// 行被占用到 `start + dur` 为止；都占满时顺延到最早空出的那一行。
    /// </summary>
    private sealed class RowAllocator
    {
        private readonly int _rows;
        private readonly double _rowHeight;
        private readonly double _firstY;
        private readonly bool _downwards;
        private readonly List<long> _freeAt;

        public RowAllocator(int rows, double rowHeight, double firstY, bool downwards)
        {
            _rows = Math.Max(1, rows);
            _rowHeight = rowHeight;
            _firstY = firstY;
            _downwards = downwards;
            _freeAt = Enumerable.Repeat(long.MinValue, _rows).ToList();
        }

        public (int Row, long StartMs) Claim(long startMs, long durMs)
        {
            var best = 0;
            var earliest = long.MaxValue;
            for (var i = 0; i < _rows; i++)
            {
                if (_freeAt[i] <= startMs) { best = i; earliest = startMs; break; }
                if (_freeAt[i] < earliest) { earliest = _freeAt[i]; best = i; }
            }
            // 都占满 → 顺延到最早空出的那一刻
            var realStart = earliest > startMs ? earliest : startMs;
            _freeAt[best] = realStart + durMs;
            return (best, realStart);
        }

        public double YOf(int row)
            => _downwards ? _firstY + row * _rowHeight : _firstY - row * _rowHeight;
    }

    /// <summary>
    /// 渲染完整 ASS（[Script Info] + [V4+ Styles] + [Events]）。
    /// </summary>
    /// <param name="items">弹幕列表。</param>
    /// <param name="fontSize">字号（以 1080 坐标系为准）。</param>
    /// <param name="marginV">上下边距。</param>
    /// <param name="opacity">不透明度 0~1。</param>
    /// <param name="title">标题（写进 Script Info 的 Title）。</param>
    public static BiliDanmakuAssResult Build(
        IReadOnlyList<BiliDanmaku> items, int fontSize = 36, int marginV = 8,
        double opacity = 1.0, string title = "")
    {
        // 字号/边距被写成 0 或负数时夹到最小 1px —— 行高为 0 会让下面的除法直接抛，
        // 整份已取回的弹幕就全废了。夹一下只是排版退化成「全挤第一行」，不是错误。
        var fs = Math.Max(1, fontSize);
        var mv = Math.Max(0, marginV);
        var rowHeight = (fs * RowHeightFactor);

        var scrollRows = Math.Max(1, (int)((PlayResY - mv) / rowHeight));
        var scroll = new RowAllocator(scrollRows, rowHeight, 0, true);
        var topBand = new RowAllocator(TopRows, rowHeight, mv, true);
        var bottomBand = new RowAllocator(BottomRows, rowHeight, PlayResY - mv, false);

        var ordered = (items ?? Array.Empty<BiliDanmaku>())
            .OrderBy(d => d.TimeSec)
            .ToList();

        var events = new StringBuilder();
        var written = 0;
        var special = 0;
        var centerX = PlayResX / 2;

        foreach (var d in ordered)
        {
            // mode 7 = 特效弹幕，8 = 代码弹幕：ASS 表示不了，跳过（计入报告）
            if (d.Mode == 7 || d.Mode == 8) { special++; continue; }

            var startMs = (long)Math.Round(d.TimeSec * 1000);
            if (startMs < 0) startMs = 0;
            var color = AssColor(d.Color, opacity);
            var text = EscapeAssText(d.Text);
            if (text.Length == 0) continue;

            if (d.Mode == 5 || d.Mode == 4)          // 顶部(5) / 底部(4)
            {
                var isTop = d.Mode == 5;
                var band = isTop ? topBand : bottomBand;
                var (row, st) = band.Claim(startMs, FixedHoldMs);
                // an8 / an2 决定 pos 那个点是文字的顶边中点还是底边中点，
                // 所以 x 一律给画面中心，y 给该行边界
                var align = isTop ? "\\an8" : "\\an2";
                events.Append(Dialogue((int)st, (int)(st + FixedHoldMs),
                    align + "\\pos(" + centerX + "," + (int)band.YOf(row) + ")\\c" + color + "&",
                    text)).Append('\n');
                written++;
            }
            else                                     // 滚动
            {
                var width = WidthOf(d.Text, fs);
                var durMs = (long)Math.Ceiling((PlayResX + width) / ScrollPxPerSecond * 1000);
                var backwards = d.Mode == 6;         // mode 6 = 逆向滚动
                var (row, st) = scroll.Claim(startMs, durMs);
                var y = (int)scroll.YOf(row);
                var from = backwards ? -width : PlayResX;
                var to = backwards ? PlayResX : -width;

                // ⚠️ \move 是**一对括号四个参数**。写成两对括号不是合法 ASS，
                // 播放器认不出来整个标签失效 → 所有滚动弹幕挤在左上角不动。
                events.Append(Dialogue((int)st, (int)(st + durMs),
                    "\\an7\\move(" + from + "," + y + "," + to + "," + y + ")\\c" + color + "&",
                    text)).Append('\n');
                written++;
            }
        }

        var sb = new StringBuilder();
        sb.Append("[Script Info]\n");
        sb.Append("Title: ").Append(string.IsNullOrWhiteSpace(title) ? "Bilibili Danmaku" : title).Append('\n');
        sb.Append("ScriptType: v4.00+\n");
        sb.Append("WrapStyle: 2\n");
        sb.Append("PlayResX: ").Append(PlayResX).Append('\n');
        sb.Append("PlayResY: ").Append(PlayResY).Append('\n');
        sb.Append("ScaledMarginV: 1\n\n");

        sb.Append("[V4+ Styles]\n");
        sb.Append("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n");
        sb.Append("Style: ").Append(StyleName)
          .Append(",Microsoft YaHei,").Append(fs)
          .Append(",&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000")
          .Append(",0,0,0,0,100,100,0,0,1,1.5,0,7,")
          .Append(mv).Append(',').Append(mv).Append(',').Append(mv).Append(",1\n\n");

        sb.Append("[Events]\n");
        sb.Append("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n");
        sb.Append(events);

        return new BiliDanmakuAssResult { Ass = sb.ToString(), Written = written, SpecialSkipped = special };
    }

    // ── 自测（--selftest 时跑）────────────────────────────────

    /// <summary>离线自测：验证 ASS 输出的关键格式，不联网。</summary>
    public static string SelfTest()
    {
        var sb = new StringBuilder();
        sb.AppendLine("[弹幕ASS]");
        try
        {
            var items = new List<BiliDanmaku>
            {
                new(1.5, 1, 25, 0xFFFFFF, "滚动 {特殊}"),
                new(2.0, 5, 25, 0xFF0000, "顶部"),
                new(3.0, 4, 25, 0x00FF00, "底部"),
                new(4.0, 6, 25, 0x0000FF, "逆向"),
                new(5.0, 7, 25, 0xFFFFFF, "特效应跳过"),
            };
            var r = Build(items, 36, 8, 1.0, "自测");

            sb.AppendLine("  Written = " + r.Written + "（应为 4）");
            sb.AppendLine("  SpecialSkipped = " + r.SpecialSkipped + "（应为 1）");
            sb.AppendLine("  含 Script Info = " + r.Ass.Contains("[Script Info]"));
            sb.AppendLine("  含 V4+ Styles = " + r.Ass.Contains("[V4+ Styles]"));
            sb.AppendLine("  含 Events = " + r.Ass.Contains("[Events]"));
            sb.AppendLine("  PlayResX 1920 = " + r.Ass.Contains("PlayResX: 1920"));
            // \move 必须是四参一对括号
            var moveOk = System.Text.RegularExpressions.Regex.IsMatch(r.Ass, @"\\move\(-?\d+,-?\d+,-?\d+,-?\d+\)");
            sb.AppendLine("  \\move 四参格式 = " + moveOk);
            sb.AppendLine("  含 \\an8(顶部) = " + r.Ass.Contains("\\an8"));
            sb.AppendLine("  含 \\an2(底部) = " + r.Ass.Contains("\\an2"));
            sb.AppendLine("  含 \\an7(滚动) = " + r.Ass.Contains("\\an7"));
            // 花括号必须转义成 \{ \}
            var escaped = r.Ass.Contains("\\{") && r.Ass.Contains("\\}");
            sb.AppendLine("  花括号已转义 = " + escaped);
            sb.AppendLine("  时间戳格式 = " + System.Text.RegularExpressions.Regex.IsMatch(r.Ass, @"Dialogue: 0,\d+:\d{2}:\d{2}\.\d{2},"));

            var pass = r.Written == 4 && r.SpecialSkipped == 1 && moveOk && escaped
                       && r.Ass.Contains("[Script Info]") && r.Ass.Contains("[Events]");
            sb.AppendLine("  结论: " + (pass ? "通过" : "失败"));
        }
        catch (Exception ex)
        {
            sb.AppendLine("  异常: " + ex.Message);
            sb.AppendLine("  结论: 失败");
        }
        return sb.ToString();
    }
}
