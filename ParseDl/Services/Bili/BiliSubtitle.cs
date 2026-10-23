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
        var path = $"/x/player/wbi/v2?bvid={Uri.EscapeDataString(bvid)}&cid={cid}";
        var data = await api.GetDataPublicAsync(path, ct);

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
}
