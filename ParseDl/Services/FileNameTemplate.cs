using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace ParseDl.Services;

/// <summary>模板替换用的数据上下文（对应 Flutter 版 Media 的字段）。</summary>
public sealed class TemplateContext
{
    public string? PostId { get; init; }
    public DateTime? PostTime { get; init; }
    public string? UserId { get; init; }
    public string? UserName { get; init; }
    public string? UserScreenName { get; init; }
    public string MediaId { get; init; } = "";
    public int? MediaWidth { get; init; }
    public int? MediaHeight { get; init; }
    public string? MediaType { get; init; }
    public string? Extension { get; init; }
    public int MediaIndex { get; init; } = 1;
    public int MediaCount { get; init; } = 1;
    public string? Content { get; init; }
    public string? PlayCount { get; init; }
    public string? LikeCount { get; init; }
    public string? BiliTitle { get; init; }
    public int? BiliPageIndex { get; init; }
    public string? BiliQuality { get; init; }
}

/// <summary>
/// 文件名 / 文件夹模板引擎 —— 从 Flutter 版 lib/services/file_name_template.dart 移植。
///
/// 语法：百分号包住变量名，只净化变量值，字面字符原样保留。
/// 带参数写作 变量名逗号参数，如 CONTENT,t=32 表示截断 32 个字符。
/// 可选段用尖括号：段内任一变量为空时，整个段（含字面字符）丢弃。
///
/// 为什么规则原样照搬：文件名是对照 Flutter 版验证过的，改规则会让两版产出对不上。
/// </summary>
public static class FileNameTemplate
{
    private const char Pct = (char)0x25;
    private const string SegmentMark = "\u0001";

    /// <summary>展开模板。perVar 可覆盖单个变量值的清洗方式，默认为 X 侧规则。</summary>
    public static string Resolve(string template, TemplateContext ctx, Func<string, string>? perVar = null)
    {
        if (string.IsNullOrEmpty(template)) return "";
        var clean = perVar ?? UnicodeFilenamify;

        string Expand(string tpl, bool strict)
        {
            var sb = new StringBuilder();
            var i = 0;
            while (i < tpl.Length)
            {
                var open = tpl.IndexOf(Pct, i);
                if (open < 0) { sb.Append(tpl, i, tpl.Length - i); break; }
                sb.Append(tpl, i, open - i);

                var close = tpl.IndexOf(Pct, open + 1);
                if (close < 0) { sb.Append(tpl, open, tpl.Length - open); break; }

                var body = tpl.Substring(open + 1, close - open - 1);
                var name = body;
                string? rawParams = null;
                var comma = body.IndexOf((char)44);
                if (comma >= 0)
                {
                    name = body[..comma];
                    rawParams = body[comma..];
                }

                var raw = Lookup(name, ctx, ParseParams(rawParams));
                if (raw is null)
                {
                    // 未知变量原样保留 —— 不静默吃掉，否则用户拼错也看不出来
                    sb.Append(tpl, open, close - open + 1);
                }
                else
                {
                    if (strict && IsEmptyForOptionalSegment(name, raw))
                        throw new OptionalSegmentEmptyException();
                    sb.Append(clean(raw));
                }
                i = close + 1;
            }
            return sb.ToString();
        }

        // 先摘出成对的可选段，用占位符顶替。顺序很关键：只扫模板，不扫注入结果 ——
        // 变量值里出现尖括号时，若先展开再找，那段注入文本会被当成可选段吞掉。
        var segments = new List<string>();
        var text = Regex.Replace(template, "<([^<>]*)>", m =>
        {
            string segBody;
            try { segBody = Expand(m.Groups[1].Value, strict: true); }
            catch (OptionalSegmentEmptyException) { segBody = ""; }
            segments.Add(segBody);
            return SegmentMark + (segments.Count - 1) + SegmentMark;
        });

        text = Expand(text, strict: false);

        if (segments.Count > 0)
        {
            text = Regex.Replace(text, SegmentMark + "(\\d+)" + SegmentMark,
                m => segments[int.Parse(m.Groups[1].Value)]);
        }
        return text;
    }

    /// <summary>抖音侧完整文件名：模板展开后整串清洗（规则与 X 侧不同）。</summary>
    public static string ResolveDouyin(string template, TemplateContext ctx)
        => DouyinFilenamify(Resolve(template, ctx, perVar: s => s).Trim(), ctx.MediaId);

    /// <summary>把文件夹模板拆成路径段（丢弃 .. 防止跳出保存目录）。</summary>
    public static List<string> ParseDirSegments(string dirName)
    {
        var outList = new List<string>();
        foreach (var s in Regex.Split(dirName ?? "", "[\\\\/]+"))
        {
            var t = s.Trim();
            if (t.Length > 0 && t != "." && t != "..") outList.Add(t);
        }
        return outList;
    }

    private static string? Lookup(string name, TemplateContext c, Dictionary<string, string> p)
    {
        bool Flag(string key) => p.TryGetValue(key, out var v) && v == "1";

        switch (name.ToUpperInvariant())
        {
            case "POST_ID": return c.PostId ?? "";
            case "POST_TIME":
                if (c.PostTime is null) return "未知日期";
                var t = c.PostTime.Value;
                // 时分秒用连字符而不是冒号（冒号是 Windows 文件名非法字符）
                var date = $"{t.Year:D4}-{t.Month:D2}-{t.Day:D2}";
                return Flag("d") ? date : $"{date} {t.Hour:D2}-{t.Minute:D2}-{t.Second:D2}";
            case "USER_ID": return c.UserId ?? "";
            case "USER_NAME": return c.UserName ?? "";
            case "USER_SCREEN_NAME": return c.UserScreenName ?? "";
            case "MEDIA_ID": return c.MediaId;
            case "MEDIA_WIDTH": return c.MediaWidth?.ToString() ?? "";
            case "MEDIA_HEIGHT": return c.MediaHeight?.ToString() ?? "";
            case "MEDIA_TYPE": return c.MediaType ?? "";
            case "MEDIA_INDEX": return c.MediaIndex.ToString();
            case "MEDIA_COUNT": return c.MediaCount.ToString();
            case "MEDIA_NUMBER": return c.MediaIndex.ToString().PadLeft(2, (char)48);
            case "EXT":
                var e = (c.Extension ?? "").Trim();
                if (e.Length == 0) return "";
                return e.StartsWith((char)46) ? e : "." + e;
            case "CONTENT":
                var text = c.Content ?? "";
                if (p.TryGetValue("t", out var ts) && int.TryParse(ts, out var trim) && trim > 0)
                    return UnicodeSubstring(text, 0, trim);
                return text;
            case "PLAY_COUNT": return c.PlayCount ?? "";
            case "LIKE_COUNT": return c.LikeCount ?? "";
            case "BILI_TITLE": return c.BiliTitle ?? "";
            case "BILI_PAGE": return c.BiliPageIndex?.ToString() ?? "";
            case "BILI_QUALITY": return c.BiliQuality ?? "";
            default: return null;
        }
    }

    /// <summary>
    /// 可选段判空口径：数值型变量里的 0 表示「没有这一项」（单 P 视频没有 P 号），
    /// 而非数值型变量哪怕内容就是字符 0 也不算空 —— 标题真叫 0 的作品存在。
    /// </summary>
    private static bool IsEmptyForOptionalSegment(string name, string raw)
    {
        var upper = name.ToUpperInvariant();
        var numeric = upper is "MEDIA_INDEX" or "MEDIA_COUNT" or "MEDIA_NUMBER" or "BILI_PAGE";
        if (numeric && (raw == "0" || raw.Length == 0)) return true;
        return string.IsNullOrEmpty(raw);
    }

    private static Dictionary<string, string> ParseParams(string? raw)
    {
        var d = new Dictionary<string, string>();
        if (string.IsNullOrEmpty(raw)) return d;
        foreach (var part in raw.TrimStart((char)44).Split((char)44))
        {
            var i = part.IndexOf((char)61);
            if (i <= 0) continue;
            d[part[..i]] = part[(i + 1)..];
        }
        return d;
    }

    private sealed class OptionalSegmentEmptyException : Exception { }

    private static readonly Regex FilenameReserved = BuildReserved();
    private static readonly Regex WindowsReservedName = new("^(con|prn|aux|nul|com\\d|lpt\\d)$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static Regex BuildReserved()
    {
        // 用字符类拼，避免在字符串里写反斜杠转义
        var chars = new[] { (char)60, (char)62, (char)58, (char)34, (char)47, (char)92,
                            (char)124, (char)63, (char)42 };
        var sb = new StringBuilder("[");
        foreach (var c in chars) sb.Append(Regex.Escape(c.ToString()));
        sb.Append("\\x00-\\x1F]");
        return new Regex(sb.ToString(), RegexOptions.Compiled);
    }

    /// <summary>X 侧清洗：非法字符换成叹号；整个名字是保留名（CON/PRN 等）时尾部补叹号。</summary>
    public static string UnicodeFilenamify(string str)
    {
        if (string.IsNullOrEmpty(str)) return str;
        var outStr = FilenameReserved.Replace(str, "!");
        if (WindowsReservedName.IsMatch(outStr)) outStr += "!";
        return outStr;
    }

    private const string DouyinKeptPunct = "-.@：_";
    private const int DouyinFileNameMax = 200;
    private static readonly Regex DyRunsOfUnderscore = new("_{2,}", RegexOptions.Compiled);
    private static readonly Regex DyEdgeUnderscore = new("^_+|_+$", RegexOptions.Compiled);
    private static readonly Regex DyTrailingDots = new("[ .]+$", RegexOptions.Compiled);

    /// <summary>
    /// 抖音侧整串清洗：正向保留「任意语言的字母与数字」+ 少量标点，其余换下划线。
    /// 不用 反斜杠w 正则：它只认 ASCII，会把纯日文假名/纯韩文标题整条洗成空串。
    /// </summary>
    public static string DouyinFilenamify(string s, string fallback = "")
    {
        if (string.IsNullOrEmpty(s)) return fallback;
        var sb = new StringBuilder();
        foreach (var rune in s.EnumerateRunes())
        {
            var ch = rune.ToString();
            var keep = Rune.IsLetterOrDigit(rune) || (ch.Length == 1 && DouyinKeptPunct.Contains(ch));
            sb.Append(keep ? ch : "_");
        }
        var outStr = DyRunsOfUnderscore.Replace(sb.ToString(), "_");
        outStr = DyEdgeUnderscore.Replace(outStr, "");
        outStr = DyTrailingDots.Replace(outStr, "");
        if (outStr.Length > DouyinFileNameMax) outStr = outStr[..DouyinFileNameMax];
        return outStr.Length == 0 ? fallback : outStr;
    }

    /// <summary>按用户感知字符截取，避免把 emoji 切一半。</summary>
    public static string UnicodeSubstring(string s, int start, int end)
    {
        if (string.IsNullOrEmpty(s) || end == start) return "";
        var lo = end > start ? start : end;
        var hi = end > start ? end : start;
        var sb = new StringBuilder();
        var idx = 0;
        foreach (var rune in s.EnumerateRunes())
        {
            if (idx >= lo && idx < hi) sb.Append(rune.ToString());
            idx++;
            if (idx >= hi) break;
        }
        return sb.ToString();
    }
}