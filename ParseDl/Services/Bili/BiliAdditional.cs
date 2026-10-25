using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.Bili;

/// <summary>
/// 一条已经落盘、等着塞进成品的内封字幕轨 —— 从 Flutter 版
/// lib/services/bili_additional.dart 的 BiliEmbeddedTrack 移植。
/// </summary>
public sealed record BiliEmbeddedTrack(string FileName, string Title, string Iso639, bool FromDanmaku);

/// <summary>
/// 附加文件（弹幕 / 字幕 / 封面 / 章节 / 元数据）这一层的**共用契约**。
///
/// 一条纪律写在类型上而不是写在注释里：附加文件**不走 aria2**。它们都是几十 KB 的
/// 小文件，走 aria2 要新增一类 gid 配对，而带凭据的那几种还会撞上
/// 「per-task header 被 --save-session 明文写盘」那条红线。
/// </summary>
public static class BiliAdditional
{
    /// <summary>中文轨的语言码（ISO 639-2 与 BCP-47 两种写法都认）。</summary>
    public static readonly HashSet<string> ChineseLangs = new(StringComparer.OrdinalIgnoreCase)
    {
        "chi", "zh", "zh-cn", "zh-hans", "zh-hant", "zh-hk", "zh-tw", "zho",
    };

    /// <summary>
    /// 附加文件的落盘名。形如 冬天-1080P.弹幕.中文.ass / 冬天-1080P.字幕.eng.srt。
    /// qualifier 是「弹幕 / 字幕 / 元数据 / 封面」这一族的名字，lang 可省。
    /// </summary>
    public static string AdditionalName(string baseName, string qualifier, string? lang, string ext)
    {
        var parts = new List<string> { baseName, qualifier };
        if (!string.IsNullOrEmpty(lang)) parts.Add(lang!);
        return string.Join('.', parts) + "." + ext.TrimStart('.');
    }

    /// <summary>
    /// 按优先级排轨序：排在列表最前的那条占成品里的第一条字幕轨。
    /// 同一族内部按文件名稳定排序，不然同一批两次跑出来的轨序会随哈希顺序漂。
    /// </summary>
    public static List<BiliEmbeddedTrack> OrderTracks(
        IEnumerable<BiliEmbeddedTrack> tracks, BiliTrackPriority priority)
    {
        int GroupOf(BiliEmbeddedTrack t) => priority switch
        {
            BiliTrackPriority.DanmakuFirst => t.FromDanmaku ? 0 : 1,
            _ => t.FromDanmaku ? 1 : 0,
        };
        return tracks.OrderBy(GroupOf)
                     .ThenBy(t => t.FileName, StringComparer.Ordinal)
                     .ToList();
    }

    /// <summary>
    /// 哪一条字幕轨该是播放器的**默认轨**。
    ///
    /// 为什么不能靠「谁排第一谁默认」：ffmpeg 会把 default 标给**第一条**字幕流，
    /// 而第一条是按文件名排序撞出来的（2026-10-12 真机：阿拉伯语 AI 轨恰好排第一，
    /// 用户打开成品看到一屏看不懂的字）。判据只有一条：**中文优先，弹幕垫底**。
    /// 返回 -1 表示没有可作默认的轨（空列表）。
    /// </summary>
    public static int DefaultTrackIndex(IReadOnlyList<BiliEmbeddedTrack> tracks)
    {
        if (tracks.Count == 0) return -1;
        int Rank(BiliEmbeddedTrack t) => t.FromDanmaku
            ? 2
            : (ChineseLangs.Contains(t.Iso639) ? 0 : 1);
        var best = 0;
        var bestRank = Rank(tracks[0]);
        for (var i = 1; i < tracks.Count; i++)
        {
            var r = Rank(tracks[i]);
            if (r < bestRank) { bestRank = r; best = i; }
        }
        return best;
    }

    // ── 章节 ────────────────────────────────────────────────

    /// <summary>章节中间文件名（它是中间文件，不是交付物，所以以点开头）。</summary>
    public static string ChapterScratchName(string outBase) => "." + outBase + ".chapters.ffmeta";

    /// <summary>
    /// view_points[] → ffmetadata 文本。没有可用章节时返回 null（= 不该多带一个输入）。
    ///
    /// 两条必须守住的边界：
    ///  * view_points 空是**常态**（绝大多数稿件没有分段章节），这时一个参数都不许多带，
    ///    更不能因为「没章节」把合并判成失败；
    ///  * 末段的 to 实测可能是 0：用总时长兜底；总时长也没有就跳过那一段
    ///    （写出一条 END=0 的章节等于在成品里塞一条 0 秒章节）。
    /// </summary>
    public static string? ChaptersToFfmetadata(IEnumerable<JsonElement>? viewPoints, int durationSeconds)
    {
        if (viewPoints is null) return null;
        var points = viewPoints.Where(p => p.ValueKind == JsonValueKind.Object).ToList();
        if (points.Count == 0) return null;

        var capMs = durationSeconds > 0 ? (long?)durationSeconds * 1000 : null;
        var sb = new StringBuilder();
        sb.AppendLine(";FFMETADATA1");
        var wrote = 0;
        for (var i = 0; i < points.Count; i++)
        {
            // 接口这两个字段的单位是**秒**，而 TIMEBASE 是 1/1000 ——
            // 少乘一次就是一份缩到千分之一、全长四秒的章节。
            var startSec = IntOf(points[i], "from");
            var endSec = IntOf(points[i], "to");
            if (endSec <= startSec)
            {
                endSec = i + 1 < points.Count ? IntOf(points[i + 1], "from") : durationSeconds;
            }
            var startMs = (long)startSec * 1000;
            var endMs = (long)endSec * 1000;
            if (capMs is long cap)
            {
                if (endMs > cap) endMs = cap;
                // 贴着片尾的那一格往前挪 1ms：与总时长相等的 END 会让 muxer 告警。
                if (endMs >= cap) endMs = cap - 1;
            }
            if (endMs <= startMs) continue;
            var title = TitleOf(points[i]);
            sb.AppendLine();
            sb.AppendLine("[CHAPTER]");
            sb.AppendLine("TIMEBASE=1/1000");
            sb.AppendLine("START=" + startMs);
            sb.AppendLine("END=" + endMs);
            sb.AppendLine("title=" + FfmetaValue(title.Length == 0 ? ("章节 " + (wrote + 1)) : title));
            wrote++;
        }
        return wrote == 0 ? null : sb.ToString();
    }

    private static int IntOf(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : 0;

    private static string TitleOf(JsonElement e) =>
        e.TryGetProperty("content", out var c) && c.ValueKind == JsonValueKind.String
            ? (c.GetString() ?? "").Trim() : "";

    /// <summary>ffmetadata 的值里 = ; # \ 与换行都要转义。</summary>
    private static string FfmetaValue(string v)
    {
        var sb = new StringBuilder();
        foreach (var ch in v)
        {
            if ("=;#\\".IndexOf(ch) >= 0) sb.Append('\\').Append(ch);
            else if (ch == (char)10) sb.Append("\\N");
            else sb.Append(ch);
        }
        return sb.ToString();
    }

    // ── 封面 ────────────────────────────────────────────────

    /// <summary>B 站图床的后缀缩放语法：https://i0.hdslb.com/x.jpg + jpg → ...x.jpg@.jpg。</summary>
    public static string CoverUrl(string pic, string suffix) =>
        string.IsNullOrEmpty(pic) ? pic : pic + "@." + suffix;

    public static string CoverExt(BiliCoverFormat f) => f switch
    {
        BiliCoverFormat.Png => "png",
        BiliCoverFormat.Webp => "webp",
        BiliCoverFormat.Avif => "avif",
        _ => "jpg",
    };

    /// <summary>取一张封面落盘，返回文件名；一次都没成则返回 null（调用方记进 missing）。</summary>
    public static async Task<string?> WriteCoverAsync(
        string saveDir, string outBase, string pic, BiliCoverFormat format,
        int attempts = 3, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(pic)) return null;
        var ext = CoverExt(format);
        var url = CoverUrl(pic, ext);
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        http.DefaultRequestHeaders.TryAddWithoutValidation("Referer", BiliApi.Referer);
        http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", BiliApi.UserAgent);
        for (var i = 0; i < attempts; i++)
        {
            try
            {
                var bytes = await http.GetByteArrayAsync(url, ct);
                if (bytes.Length > 0)
                {
                    var name = AdditionalName(outBase, "封面", null, ext);
                    var path = Path.Combine(saveDir, name);
                    await File.WriteAllBytesAsync(path, bytes, ct);
                    return name;
                }
            }
            catch
            {
                // 最后一次以外都当作「再试一次」
            }
        }
        return null;
    }

    // ── 元数据 ──────────────────────────────────────────────

    /// <summary>x/web-interface/view/detail/tag 的 data[] → 标签名列表。形状不对时回空列表，不抛。</summary>
    public static List<string> TagsFromData(JsonElement data)
    {
        var list = new List<string>();
        if (data.ValueKind != JsonValueKind.Array) return list;
        foreach (var e in data.EnumerateArray())
        {
            if (!e.TryGetProperty("tag_name", out var t)) continue;
            var s = (t.GetString() ?? "").Trim();
            if (s.Length > 0) list.Add(s);
        }
        return list;
    }

    /// <summary>渲染 nfo（媒体库读）。</summary>
    public static string MetadataToNfo(
        JsonElement view, IReadOnlyList<string> tags, string partTitle, int partIndex)
    {
        string Str(string name) =>
            view.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";
        string OwnerName()
        {
            if (view.TryGetProperty("owner", out var o) && o.TryGetProperty("name", out var n) &&
                n.ValueKind == JsonValueKind.String) return n.GetString() ?? "";
            return "";
        }
        var title = Str("title").Length == 0 ? partTitle : Str("title");
        var lines = new List<string>
        {
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
            "<movie>",
            "  <title>" + X(title) + "</title>",
        };
        if (partIndex > 1) lines.Add("  <originaltitle>" + X(partTitle) + "</originaltitle>");
        lines.Add("  <plot>" + X(Str("desc")) + "</plot>");
        if (Str("tname").Length > 0) lines.Add("  <genre>" + X(Str("tname")) + "</genre>");
        if (OwnerName().Length > 0) lines.Add("  <studio>" + X(OwnerName()) + "</studio>");
        foreach (var t in tags) lines.Add("  <tag>" + X(t) + "</tag>");
        if (Str("bvid").Length > 0)
            lines.Add("  <uniqueid type=\"bilibili\">" + X(Str("bvid")) + "</uniqueid>");
        lines.Add("  <premiered>" + IsoDate(Str("pubdate")) + "</premiered>");
        lines.Add("</movie>");
        return string.Join(Environment.NewLine, lines);
    }

    private static string IsoDate(string s)
    {
        if (!long.TryParse(s, out var epoch) || epoch <= 0) return "";
        var d = DateTimeOffset.FromUnixTimeSeconds(epoch).LocalDateTime;
        return d.Year.ToString("D4") + "-" + d.Month.ToString("D2") + "-" + d.Day.ToString("D2");
    }

    private static string X(string v) => v.Replace("&", "&amp;").Replace("<", "&lt;")
                                          .Replace(">", "&gt;").Replace("\"", "&quot;");

    // ── 弹幕 / 字幕落盘 ─────────────────────────────────────

    /// <summary>弹幕 ASS（唯一能内封进容器的弹幕格式）。</summary>
    public static string DanmakuToAss(IReadOnlyList<BiliDanmaku> list, string title)
    {
        var sb = new StringBuilder();
        sb.AppendLine("[Script Info]");
        sb.AppendLine("ScriptType: v4.00+");
        sb.AppendLine("Title: " + title);
        sb.AppendLine("PlayResX: 1920");
        sb.AppendLine("PlayResY: 1080");
        sb.AppendLine("WrapStyle: 2");
        sb.AppendLine();
        sb.AppendLine("[V4+ Styles]");
        sb.AppendLine("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, " +
                      "BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, " +
                      "BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding");
        sb.AppendLine("Style: Danmaku,Microsoft YaHei,48,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000," +
                      "0,0,0,0,100,100,0,0,1,2,1,8,20,20,20,1");
        sb.AppendLine();
        sb.AppendLine("[Events]");
        sb.AppendLine("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text");
        foreach (var d in list)
        {
            var text = (d.Text ?? "").Replace("\r", "").Replace("\n", "\\N");
            sb.AppendLine("Dialogue: 0," + AssTime(d.TimeSec) + "," + AssTime(d.TimeSec + 6) +
                          ",Danmaku,,0,0,0,,{\\an8}" + text);
        }
        return sb.ToString();
    }

    /// <summary>字幕 ASS。</summary>
    public static string SubtitleToAss(IReadOnlyList<BiliSubtitleCue> cues, string title)
    {
        var sb = new StringBuilder();
        sb.AppendLine("[Script Info]");
        sb.AppendLine("ScriptType: v4.00+");
        sb.AppendLine("Title: " + title);
        sb.AppendLine("PlayResX: 1920");
        sb.AppendLine("PlayResY: 1080");
        sb.AppendLine();
        sb.AppendLine("[V4+ Styles]");
        sb.AppendLine("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, " +
                      "BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, " +
                      "BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding");
        sb.AppendLine("Style: Default,Microsoft YaHei,54,&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000," +
                      "0,0,0,0,100,100,0,0,1,3,1,2,20,20,40,1");
        sb.AppendLine();
        sb.AppendLine("[Events]");
        sb.AppendLine("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text");
        foreach (var c in cues)
        {
            var text = (c.Text ?? "").Replace("\r", "").Replace("\n", "\\N");
            sb.AppendLine("Dialogue: 0," + AssTime(c.FromSec) + "," + AssTime(c.ToSec) +
                          ",Default,,0,0,0,," + text);
        }
        return sb.ToString();
    }

    /// <summary>ASS 时间：H:MM:SS.cc（**厘秒**，只有两位小数）。</summary>
    public static string AssTime(double sec)
    {
        if (sec < 0) sec = 0;
        var ts = TimeSpan.FromSeconds(sec);
        var cs = (int)Math.Round(ts.Milliseconds / 10.0);
        if (cs >= 100) cs = 99;
        return (int)ts.TotalHours + ":" + ts.Minutes.ToString("D2") + ":" + ts.Seconds.ToString("D2") +
               "." + cs.ToString("D2");
    }

    /// <summary>B 站的 lan 码 → MKV 的 Language 元素要的 ISO 639-2 三字母码。空串 = 不写这个标签。</summary>
    public static string Iso639FromLan(string lan)
    {
        var l = (lan ?? "").Trim().ToLowerInvariant();
        if (l.StartsWith("ai-")) l = l.Substring(3);
        switch (l)
        {
            case "zh" or "zh-cn" or "zh-hans" or "zh-hant" or "chi" or "zho": return "chi";
            case "en" or "eng": return "eng";
            case "ja" or "jpn": return "jpn";
            case "ko" or "kor": return "kor";
            case "ru" or "rus": return "rus";
            case "es" or "spa": return "spa";
            case "fr" or "fra": return "fra";
            case "de" or "deu": return "deu";
            case "ar" or "ara": return "ara";
            case "pt" or "por": return "por";
            case "it" or "ita": return "ita";
            case "th" or "tha": return "tha";
            case "vi" or "vie": return "vie";
            default: return l.Length == 3 ? l : "";
        }
    }
}

/// <summary>附加文件契约自测 —— 纯离线。</summary>
public static class BiliAdditionalSelfTest
{
    public static string Run()
    {
        var sb = new StringBuilder();
        var pass = 0; var fail = 0;
        void Check(string name, bool ok, string detail = "")
        {
            if (ok) { pass++; sb.AppendLine("  PASS  " + name); }
            else { fail++; sb.AppendLine("  FAIL  " + name + (detail.Length > 0 ? "  " + detail : "")); }
        }

        Check("落名（带语言）",
            BiliAdditional.AdditionalName("冬天-1080P", "弹幕", "中文", "ass") == "冬天-1080P.弹幕.中文.ass");
        Check("落名（不带语言）",
            BiliAdditional.AdditionalName("冬天-1080P", "封面", null, "jpg") == "冬天-1080P.封面.jpg");

        var tracks = new List<BiliEmbeddedTrack>
        {
            new("c.ass", "阿拉伯语", "ara", false),
            new("b.ass", "中文（AI）", "chi", false),
            new("a.ass", "弹幕", "", true),
        };
        var ordered = BiliAdditional.OrderTracks(tracks, BiliTrackPriority.SubtitleFirst);
        Check("轨序：字幕族在前", ordered[0].FileName != "a.ass" && ordered[2].FileName == "a.ass");
        // 判据是「默认轨那条必须是中文」，不是「索引等于某个固定数字」——
        // 写死索引会让「排序规则一改就假绿」。
        var defIdx = BiliAdditional.DefaultTrackIndex(ordered);
        Check("默认轨是中文那条（不是阿拉伯语、也不是弹幕）",
            defIdx >= 0 && ordered[defIdx].Iso639 == "chi",
            "idx=" + defIdx + " iso=" + (defIdx >= 0 ? ordered[defIdx].Iso639 : "-"));
        Check("只有弹幕时默认轨是它", BiliAdditional.DefaultTrackIndex(new List<BiliEmbeddedTrack>
        {
            new("a.ass", "弹幕", "", true),
        }) == 0);
        Check("空轨表返回 -1", BiliAdditional.DefaultTrackIndex(new List<BiliEmbeddedTrack>()) == -1);

        Check("封面 URL 后缀语法",
            BiliAdditional.CoverUrl("https://i0.hdslb.com/x.jpg", "png") == "https://i0.hdslb.com/x.jpg@.png");
        Check("封面扩展名 webp", BiliAdditional.CoverExt(BiliCoverFormat.Webp) == "webp");

        Check("ASS 时间格式 0 秒", BiliAdditional.AssTime(0) == "0:00:00.00");
        Check("ASS 时间格式 1 小时零 5 秒 120 毫秒",
            BiliAdditional.AssTime(3605.12) == "1:00:05.12", BiliAdditional.AssTime(3605.12));

        Check("ISO639 zh-cn → chi", BiliAdditional.Iso639FromLan("zh-cn") == "chi");
        Check("ISO639 ai-es → spa", BiliAdditional.Iso639FromLan("ai-es") == "spa");
        Check("ISO639 eng 保留", BiliAdditional.Iso639FromLan("eng") == "eng");
        Check("ISO639 认不出回空串", BiliAdditional.Iso639FromLan("xx") == "");

        // 章节：无 view_points → null（一个参数都不许多带）
        Check("无章节返回 null", BiliAdditional.ChaptersToFfmetadata(null, 100) is null);
        var vp = new List<JsonElement>
        {
            JsonDocument.Parse("{\"from\":0,\"to\":10,\"content\":\"开场\"}").RootElement.Clone(),
            JsonDocument.Parse("{\"from\":10,\"to\":0,\"content\":\"正片\"}").RootElement.Clone(),
        };
        var meta = BiliAdditional.ChaptersToFfmetadata(vp, 100);
        // 末段 to=0 → 用总时长兜底，但**贴着片尾那一格要往前挪 1ms**
        // （与总时长相等的 END 会让 mp4 muxer 告警），所以是 99999 而不是 100000。
        Check("末段 to=0 用总时长兜底（且夹住越界 1ms）",
            meta is not null && meta.Contains("END=99999"), meta ?? "null");
        Check("章节带 TIMEBASE 1/1000", meta is not null && meta.Contains("TIMEBASE=1/1000"));
        Check("章节标题转义（无特殊字符时原样）", meta is not null && meta.Contains("title=开场"));

        sb.AppendLine();
        sb.AppendLine("BiliAdditional 合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}
