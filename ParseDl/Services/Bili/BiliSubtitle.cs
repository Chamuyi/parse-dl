using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.Bili;

/// <summary>一条字幕 cue。</summary>
public sealed record BiliSubtitleCue(double FromSec, double ToSec, string Text);

/// <summary>一份字幕（语言 + 内容）。</summary>
public sealed record BiliSubtitle(string Lang, string LangLabel, IReadOnlyList<BiliSubtitleCue> Cues);

/// <summary>
/// B 站字幕下载 —— 从 Flutter 版 bili_subtitle.dart（280 行）移植。
///
/// 数据源：/x/player/wbi/v2 的 data.subtitle.subtitles[]，每条再 GET 一次
/// subtitle_url（那是个 JSON，body[] 里是 content + start_time/end_time）。
///
/// **必须登录**：未登录时 subtitles 数组是空的 —— 字幕是登录用户才有的权益。
/// </summary>
public static class BiliSubtitleService
{
    /// <summary>取该稿件所有可用字幕的语言列表。</summary>
    public static async Task<List<(string Lang, string Label, string Url)>> ListAsync(
        BiliApi api, string bvid, long cid, CancellationToken ct = default)
    {
        var result = new List<(string, string, string)>();
        // **走 wbi 签名**：/x/player/wbi/v2 不签名会被风控。
        var data = await api.GetSignedDataAsync("/x/player/wbi/v2", new Dictionary<string, string?>
        {
            ["bvid"] = bvid,
            ["cid"] = cid.ToString(),
        }, ct);

        if (!data.TryGetProperty("subtitle", out var sub) ||
            !sub.TryGetProperty("subtitles", out var arr) ||
            arr.ValueKind != JsonValueKind.Array)
        {
            return result;
        }

        foreach (var s in arr.EnumerateArray())
        {
            var lan = s.TryGetProperty("lan", out var l) ? l.GetString() ?? "" : "";
            var label = s.TryGetProperty("lan_doc", out var ld) ? ld.GetString() ?? lan : lan;
            var url = s.TryGetProperty("subtitle_url", out var u) ? u.GetString() ?? "" : "";
            if (string.IsNullOrEmpty(url)) continue;
            // B 站给的是 //aisubtitle.hdslb.com/... 这种协议相对地址
            if (url.StartsWith("//")) url = "https:" + url;
            result.Add((lan, label, url));
        }
        return result;
    }

    /// <summary>下载并解析一份字幕。</summary>
    public static async Task<BiliSubtitle> FetchAsync(
        string url, string lang, string label, CancellationToken ct = default)
    {
        using var http = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        var json = await http.GetStringAsync(url, ct);
        var cues = ParseBody(json);
        return new BiliSubtitle(lang, label, cues);
    }

    /// <summary>
    /// 解析 subtitle_url 那份 JSON。字段缺失/形状不对时返回空列表而不是抛 ——
    /// 字幕是附加功能，不该因为它坏掉就中断整个下载。
    /// </summary>
    public static List<BiliSubtitleCue> ParseBody(string json)
    {
        var cues = new List<BiliSubtitleCue>();
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("body", out var body) ||
                body.ValueKind != JsonValueKind.Array) return cues;

            foreach (var item in body.EnumerateArray())
            {
                var from = item.TryGetProperty("from", out var f) && f.ValueKind == JsonValueKind.Number
                    ? f.GetDouble() : 0;
                var to = item.TryGetProperty("to", out var t) && t.ValueKind == JsonValueKind.Number
                    ? t.GetDouble() : 0;
                var text = item.TryGetProperty("content", out var c) ? c.GetString() ?? "" : "";
                if (text.Length == 0) continue;
                cues.Add(new BiliSubtitleCue(from, to, text));
            }
        }
        catch
        {
            // 结构不符就返回已解析到的部分
        }
        return cues;
    }

    /// <summary>导出成 SRT（最通用的字幕格式，播放器都认）。</summary>
    public static string ToSrt(IReadOnlyList<BiliSubtitleCue> cues)
    {
        var sb = new StringBuilder();
        for (var i = 0; i < cues.Count; i++)
        {
            var c = cues[i];
            sb.AppendLine((i + 1).ToString());
            sb.AppendLine(SrtTime(c.FromSec) + " --> " + SrtTime(c.ToSec));
            sb.AppendLine(c.Text);
            sb.AppendLine();
        }
        return sb.ToString();
    }

    private static string SrtTime(double sec)
    {
        if (sec < 0) sec = 0;
        var ts = TimeSpan.FromSeconds(sec);
        return $"{ts.Hours:D2}:{ts.Minutes:D2}:{ts.Seconds:D2},{ts.Milliseconds:D3}";
    }

    /// <summary>导出成纯文本（每行一句，方便复制）。</summary>
    public static string ToPlainText(IReadOnlyList<BiliSubtitleCue> cues)
        => string.Join(Environment.NewLine, cues.Select(c => c.Text));

    // ── ASS 字幕（移植自原项目 bili_subtitle.dart 的 biliSubtitleToAss）──

    /// <summary>字幕正文的默认字号（1080p 坐标系）。</summary>
    public const int DefaultSubtitleFontSize = 48;
    /// <summary>字幕默认底部边距。弹幕默认 10 对字幕太贴底（会被播放器进度条压住）。</summary>
    public const int DefaultSubtitleMarginV = 48;
    /// <summary>描边宽度。</summary>
    public const int SubtitleOutline = 3;

    /// <summary>
    /// 字幕字号。**不直接复用弹幕字号**：弹幕默认 25 是给「一行挤很多条」用的，
    /// 字幕是「一行一句」的正文，25 太小 —— 实测字形高只占 1080p 屏高的 1.76%，
    /// 而 B站播放器与 Netflix 规范都在 42 上下，常见压制组正文在 48。
    ///
    /// 规则：用户调过弹幕字号（≠ 默认 25）就尊重他的选择；仍是默认值就给字幕更大的默认。
    /// </summary>
    public static int SubtitleFontSize(BiliConfig cfg)
        => cfg.DanmakuFontSize == 25 ? DefaultSubtitleFontSize : cfg.DanmakuFontSize;

    /// <summary>字幕底部边距（同上：没调过就给字幕更宽松的默认）。</summary>
    public static int SubtitleMarginV(BiliConfig cfg)
        => cfg.DanmakuMarginV == 10 ? DefaultSubtitleMarginV : cfg.DanmakuMarginV;

    /// <summary>字幕文本进 ASS 前的转义：反斜杠与花括号会改语义，换行要变成 \N。</summary>
    public static string EscapeSubtitleAssText(string text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        return text.Replace("\\", "\\\\")
                   .Replace("{", "(").Replace("}", ")")
                   .Replace("\r\n", "\\N").Replace("\n", "\\N");
    }

    /// <summary>
    /// 渲染字幕 ASS（[Script Info] + [V4+ Styles] + [Events]）。
    ///
    /// 与弹幕 ASS 的区别：字幕是「一行一句」，用 Alignment=2（底部居中）、
    /// BorderStyle=1（描边阴影）、字号更大；弹幕是满屏滚动。
    /// </summary>
    public static string ToAss(BiliSubtitle sub, BiliConfig cfg, string title = "")
    {
        const string nl = "\n";
        var opacity = Math.Clamp(cfg.DanmakuOpacity, 0, 100) / 100.0;
        var primary = BiliDanmakuAss.AssColor(0xFFFFFF, opacity);
        var outline = BiliDanmakuAss.AssColor(0x000000, 1.0);
        var fs = SubtitleFontSize(cfg);
        var mv = SubtitleMarginV(cfg);

        var sb = new StringBuilder();
        sb.Append("[Script Info]").Append(nl);
        sb.Append("Title: ").Append(string.IsNullOrWhiteSpace(title) ? "Bilibili Subtitle" : title).Append(nl);
        sb.Append("ScriptType: v4.00+").Append(nl);
        sb.Append("PlayResX: 1920").Append(nl);
        sb.Append("PlayResY: 1080").Append(nl);
        sb.Append("WrapStyle: 0").Append(nl);
        sb.Append("ScaledBorderAndShadow: yes").Append(nl).Append(nl);

        sb.Append("[V4+ Styles]").Append(nl);
        sb.Append("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding").Append(nl);
        sb.Append("Style: Default,").Append(cfg.DanmakuFontFace).Append(',').Append(fs).Append(',')
          .Append(primary)
          .Append(",&H00FFFFFF,").Append(outline).Append(",&H00000000")
          .Append(primary).Append(",&H00FFFFFF,").Append(outline).Append(",&H00000000")
          .Append(",0,0,0,0,100,100,0,0,1,").Append(SubtitleOutline)
          .Append(",0,2,20,20,").Append(mv).Append(",134").Append(nl).Append(nl);

        sb.Append("[Events]").Append(nl);
        sb.Append("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text").Append(nl);

        foreach (var cue in sub.Cues)
        {
            var start = (int)Math.Round(cue.FromSec * 1000);
            var end = (int)Math.Round(cue.ToSec * 1000);
            if (end <= start) end = start + 500;
            sb.Append("Dialogue: 0,").Append(BiliDanmakuAss.AssTime(start)).Append(',')
              .Append(BiliDanmakuAss.AssTime(end)).Append(",Default,,0,0,0,,")
              .Append(EscapeSubtitleAssText(cue.Text)).Append(nl);
        }
        return sb.ToString();
    }

    /// <summary>离线自测：验证字幕 ASS 的关键格式，不联网。</summary>
    public static string SelfTest()
    {
        var sb = new StringBuilder();
        sb.AppendLine("[字幕ASS]");
        try
        {
            var cues = new List<BiliSubtitleCue>
            {
                new(1.0, 3.5, "第一句 {含花括号} 与 \\ 反斜杠"),
                new(4.0, 6.0, "第二句\n带换行"),
            };
            var sub = new BiliSubtitle("zh-CN", "中文（中国）", cues);
            var cfg = new BiliConfig();
            var ass = ToAss(sub, cfg, "自测");

            sb.AppendLine("  含 Script Info = " + ass.Contains("[Script Info]"));
            sb.AppendLine("  含 V4+ Styles = " + ass.Contains("[V4+ Styles]"));
            sb.AppendLine("  含 Events = " + ass.Contains("[Events]"));
            sb.AppendLine("  PlayResX 1920 = " + ass.Contains("PlayResX: 1920"));
            sb.AppendLine("  ScaledBorderAndShadow = " + ass.Contains("ScaledBorderAndShadow: yes"));
            // 字号应为字幕默认 48（不是弹幕的 25）
            sb.AppendLine("  字幕字号=48 = " + ass.Contains(",48,"));
            // Alignment=2 底部居中
            sb.AppendLine("  Alignment=2 = " + System.Text.RegularExpressions.Regex.IsMatch(ass, @",1,3,0,2,20,20,"));
            sb.AppendLine("  Dialogue 条数=2 = " + (ass.Split("Dialogue:").Length - 1 == 2));
            // 花括号被替换成圆括号，反斜杠转义
            sb.AppendLine("  花括号转圆括号 = " + (ass.Contains("(含花括号)") && !ass.Contains("{含花括号}")));
            sb.AppendLine("  换行转 \\N = " + ass.Contains("\\N"));
            sb.AppendLine("  时间戳格式 = " + System.Text.RegularExpressions.Regex.IsMatch(ass, @"Dialogue: 0,\d+:\d{2}:\d{2}\.\d{2},"));

            var pass = ass.Contains("[Script Info]") && ass.Contains("[Events]")
                       && ass.Contains(",48,") && (ass.Split("Dialogue:").Length - 1 == 2);
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
