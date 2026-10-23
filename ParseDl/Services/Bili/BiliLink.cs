using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace ParseDl.Services.Bili;

/// <summary>链接解析结果。三种情况：单个稿件（bvid/aid）、列表（合集/系列/收藏夹）、UP 主空间。</summary>
public sealed record BiliRef
{
    public string? Bvid { get; init; }
    public long? Aid { get; init; }
    /// <summary>分 P 号（从链接里的 p 参数来，没给则为 null）。</summary>
    public int? PartIndex { get; init; }
    public long? Mid { get; init; }
    public long? SeasonId { get; init; }
    public long? SeriesId { get; init; }
    public long? FavId { get; init; }

    public bool IsVideo => Bvid is not null || Aid is not null;
    public bool IsList => SeasonId is not null || SeriesId is not null || FavId is not null;
}

/// <summary>列表类型。</summary>
public enum BiliListKind { Season, Series, Fav, Space }

/// <summary>
/// B 站链接解析 —— 从 Flutter 版 lib/services/bili_link.dart 移植。
///
/// 支持：裸 BV 号、av 号、整条带 query 的长链、b23.tv 短链（需网络）、
/// 番剧链接、合集(season)/系列(series)/收藏夹(fav)/UP 主空间(space)。
///
/// 为什么单独一层：接口层只该管「给我一个 bvid / 给我一个列表 id」，
/// 把「用户粘了什么东西」这件事挡在外面，两边都好测。
/// </summary>
public static class BiliLink
{
    /// <summary>BV 号：BV + 10 位 base58（不含 0/O/I/l）。</summary>
    private static readonly Regex BvidRe = new("BV[1-9A-HJ-NP-Za-km-z]{10}", RegexOptions.Compiled);
    /// <summary>av 号：av + 数字（大小写都收）。</summary>
    private static readonly Regex AvRe = new("^av(\\d+)$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    /// <summary>用户常把小写 bv 前缀粘进来，B 站号区分大小写但前缀不区分。</summary>
    private static readonly Regex LowerBvRe = new("^bv([1-9A-HJ-NP-Za-km-z]{10})$", RegexOptions.Compiled);
    private static readonly Regex DigitsRe = new("^\\d+$", RegexOptions.Compiled);

    public const string ShortHost = "b23.tv";

    /// <summary>解析一段用户输入。返回 null 表示认不出来。</summary>
    public static BiliRef? Parse(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var text = raw.Trim();

        // ① 裸号
        var avm = AvRe.Match(text);
        if (avm.Success) return new BiliRef { Aid = long.Parse(avm.Groups[1].Value) };
        var lbv = LowerBvRe.Match(text);
        if (lbv.Success) return new BiliRef { Bvid = "BV" + lbv.Groups[1].Value };
        if (Regex.IsMatch(text, "^BV[1-9A-HJ-NP-Za-km-z]{10}$")) return new BiliRef { Bvid = text };

        // ② 链接
        if (!text.Contains("://")) text = "https://" + text;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri)) return null;

        var query = ParseQuery(uri.Query);
        int? Part() => query.TryGetValue("p", out var p) && int.TryParse(p, out var pv) ? pv : null;

        // 番剧 / 影视：/bangumi/play/ep123 或 /bangumi/play/ss123 —— 交给 playurl 用 epid 处理
        var path = uri.AbsolutePath;

        // 收藏夹 /medialist/detail/ml123 或 /medialist/play/ml123
        var mlm = Regex.Match(path, "/ml(\\d+)");
        if (mlm.Success) return new BiliRef { FavId = long.Parse(mlm.Groups[1].Value) };

        // 收藏夹新版 /list/ml123?fid=123
        if (query.TryGetValue("fid", out var fidStr) && long.TryParse(fidStr, out var fid))
            return new BiliRef { FavId = fid };

        // 合集 / 系列：/space/xxx 或 /list/ 下带 season_id / series_id
        if (query.TryGetValue("season_id", out var sidStr) && long.TryParse(sidStr, out var sid))
            return new BiliRef { SeasonId = sid };
        if (query.TryGetValue("series_id", out var serStr) && long.TryParse(serStr, out var ser))
            return new BiliRef { SeriesId = ser };

        // 视频页 /video/BVxxx 或 /video/av123
        var bv = BvidRe.Match(path + "?" + uri.Query);
        if (bv.Success) return new BiliRef { Bvid = bv.Value, PartIndex = Part() };
        var avInPath = Regex.Match(path, "/av(\\d+)", RegexOptions.IgnoreCase);
        if (avInPath.Success) return new BiliRef { Aid = long.Parse(avInPath.Groups[1].Value), PartIndex = Part() };

        // UP 主空间。两种写法都要认：
        //   ① space.bilibili.com/546195  —— **host 是 space，路径只有 /546195**（实测踩过）
        //   ② www.bilibili.com/space/546195 —— 路径带 /space 前缀
        if (uri.Host.StartsWith("space.bilibili.com", StringComparison.OrdinalIgnoreCase))
        {
            var onlyId = Regex.Match(path, "^/(\\d+)");
            if (onlyId.Success) return new BiliRef { Mid = long.Parse(onlyId.Groups[1].Value) };
        }
        var spaceM = Regex.Match(path, "^/space/(\\d+)");
        if (spaceM.Success) return new BiliRef { Mid = long.Parse(spaceM.Groups[1].Value) };
        if (query.TryGetValue("mid", out var midStr) && long.TryParse(midStr, out var mid2))
            return new BiliRef { Mid = mid2 };

        return null;
    }

    /// <summary>是不是 b23.tv 短链（需要跟随重定向才能知道真实目标）。</summary>
    public static bool IsShortLink(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return false;
        var t = raw.Trim();
        if (!t.Contains("://")) t = "https://" + t;
        return Uri.TryCreate(t, UriKind.Absolute, out var u)
            && u.Host.EndsWith(ShortHost, StringComparison.OrdinalIgnoreCase);
    }

    private static Dictionary<string, string> ParseQuery(string q)
    {
        var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrEmpty(q)) return d;
        foreach (var part in q.TrimStart((char)63).Split((char)38))
        {
            var i = part.IndexOf((char)61);
            if (i <= 0 || i == part.Length - 1) continue;
            d[part[..i]] = Uri.UnescapeDataString(part[(i + 1)..]);
        }
        return d;
    }
}

/// <summary>B 站链接解析自测 —— 全部离线，不联网。</summary>
public static class BiliLinkSelfTest
{
    public static string Run()
    {
        var sb = new System.Text.StringBuilder();
        var pass = 0; var fail = 0;
        void Check(string name, bool ok, string detail = "")
        {
            if (ok) { pass++; sb.AppendLine("  PASS  " + name); }
            else { fail++; sb.AppendLine("  FAIL  " + name + (detail.Length > 0 ? "  " + detail : "")); }
        }

        Check("裸 BV 号", BiliLink.Parse("BV1xx411c7mD")?.Bvid == "BV1xx411c7mD");
        Check("裸 av 号", BiliLink.Parse("av170001")?.Aid == 170001);
        Check("小写 bv 前缀", BiliLink.Parse("bv1xx411c7mD")?.Bvid == "BV1xx411c7mD");
        Check("完整视频链接", BiliLink.Parse("https://www.bilibili.com/video/BV1xx411c7mD")?.Bvid == "BV1xx411c7mD");
        Check("链接带分P参数",
            BiliLink.Parse("https://www.bilibili.com/video/BV1xx411c7mD?p=3")?.PartIndex == 3);
        Check("av 链接", BiliLink.Parse("https://www.bilibili.com/video/av170001")?.Aid == 170001);
        Check("合集 season_id", BiliLink.Parse("https://www.bilibili.com/list/BV1xx?season_id=1729")?.SeasonId == 1729);
        Check("系列 series_id", BiliLink.Parse("https://www.bilibili.com/list/BV1xx?series_id=88")?.SeriesId == 88);
        Check("收藏夹 ml", BiliLink.Parse("https://www.bilibili.com/medialist/detail/ml152431")?.FavId == 152431);
        Check("UP 主空间（space 子域）", BiliLink.Parse("https://space.bilibili.com/546195")?.Mid == 546195);
        Check("UP 主空间（/space 路径）", BiliLink.Parse("https://www.bilibili.com/space/546195")?.Mid == 546195);
        Check("b23 短链识别", BiliLink.IsShortLink("https://b23.tv/abc123"));
        Check("非 B 站链接返回 null", BiliLink.Parse("https://example.com/x") is null);
        Check("空输入返回 null", BiliLink.Parse("") is null);

        sb.AppendLine();
        sb.AppendLine("BiliLink 合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}