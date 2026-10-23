using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ParseDl.Services.Douyin;

/// <summary>抖音的一条作品。</summary>
public sealed record DouyinAweme
{
    public string Id { get; init; } = "";
    public string Desc { get; init; } = "";
    public DateTime? CreatedAt { get; init; }
    public string? AuthorId { get; init; }
    public string? AuthorName { get; init; }
    public string? AuthorUniqueId { get; init; }
    public IReadOnlyList<DouyinMedia> Media { get; init; } = Array.Empty<DouyinMedia>();
    public int DiggCount { get; init; }
    public int CommentCount { get; init; }
    public int ShareCount { get; init; }
}

/// <summary>抖音的一条媒体（视频或图片）。</summary>
public sealed record DouyinMedia
{
    public string Url { get; init; } = "";
    public string Type { get; init; } = "video";
    public int Index { get; init; }
}

/// <summary>
/// 抖音解析 —— 从 Flutter 版 douyin_parser.dart（303 行）、douyin_source.dart（253 行）移植。
///
/// 边界：抖音的页面抓取依赖 WebView2 注入（独立模块）。本文件只做「给一段 HTML 或 JSON，
/// 解析出作品与媒体地址」 —— 这是整条链路里最容易出错的环节，且能离线用真实样本验证。
/// </summary>
public sealed class DouyinParser
{
    /// <summary>抖音页面里可能装数据的容器名。结构会变，认多个更稳。</summary>
    private static readonly string[] DataContainerNames =
        { "_ROUTER_DATA", "RENDER_DATA", "__INITIAL_STATE__", "_SSR_HYDRATED_DATA" };

    /// <summary>从页面 HTML 里抽内嵌 JSON。找不到返回 null。</summary>
    public static string? ExtractEmbeddedJson(string html)
    {
        if (string.IsNullOrEmpty(html)) return null;

        foreach (var name in DataContainerNames)
        {
            // <script id="NAME" type="application/json">...</script>
            var pat1 = @"<script[^>]*id=(['""])" + Regex.Escape(name) + @"\1[^>]*>([\s\S]*?)</script>";
            var byId = Regex.Match(html, pat1, RegexOptions.IgnoreCase);
            if (byId.Success)
            {
                var inner = byId.Groups[2].Value.Trim();
                if (inner.Length > 0 && (inner[0] == (char)123 || inner[0] == (char)91)) return inner;
                try { return Uri.UnescapeDataString(inner); } catch { }
            }

            // window.NAME = {...};
            var pat2 = @"window\.?" + Regex.Escape(name) + @"\s*=\s*(\{[\s\S]*?\})\s*;";
            var byAssign = Regex.Match(html, pat2, RegexOptions.IgnoreCase);
            if (byAssign.Success) return byAssign.Groups[1].Value;
        }
        return null;
    }

    /// <summary>解析单个作品 JSON（aweme_detail 形状），也接受外层包了 aweme_detail 的对象。</summary>
    public static DouyinAweme? ParseAweme(JsonElement el)
    {
        try
        {
            if (el.TryGetProperty("aweme_detail", out var detail)) el = detail;

            var id = Str(el, "aweme_id") ?? "";
            if (string.IsNullOrEmpty(id)) return null;

            DateTime? created = null;
            if (el.TryGetProperty("create_time", out var ct) && ct.ValueKind == JsonValueKind.Number)
            {
                try { created = DateTimeOffset.FromUnixTimeSeconds(ct.GetInt64()).UtcDateTime; }
                catch { }
            }

            string? authorId = null, authorName = null, uniqueId = null;
            if (el.TryGetProperty("author", out var author))
            {
                authorId = Str(author, "uid");
                authorName = Str(author, "nickname");
                uniqueId = Str(author, "unique_id");
            }

            var media = new List<DouyinMedia>();
            var idx = 0;

            // 图集：images 数组
            if (el.TryGetProperty("images", out var images) && images.ValueKind == JsonValueKind.Array)
            {
                foreach (var img in images.EnumerateArray())
                {
                    idx++;
                    var url = PickUrlList(img, "url_list");
                    if (!string.IsNullOrEmpty(url))
                        media.Add(new DouyinMedia { Url = url, Type = "image", Index = idx });
                }
            }

            // 视频：优先 720p，退回 play_addr，再退回最高码率
            if (el.TryGetProperty("video", out var video))
            {
                var url = "";
                if (video.TryGetProperty("play_addr_720p", out var p720)) url = PickUrlList(p720, "url_list");
                if (string.IsNullOrEmpty(url) && video.TryGetProperty("play_addr", out var pa))
                    url = PickUrlList(pa, "url_list");
                if (string.IsNullOrEmpty(url) && video.TryGetProperty("bit_rate", out var brs) &&
                    brs.ValueKind == JsonValueKind.Array)
                {
                    foreach (var b in brs.EnumerateArray()
                        .OrderByDescending(b => b.TryGetProperty("bit_rate", out var bv) ? bv.GetInt64() : 0))
                    {
                        if (b.TryGetProperty("play_addr", out var bpa))
                        {
                            url = PickUrlList(bpa, "url_list");
                            if (!string.IsNullOrEmpty(url)) break;
                        }
                    }
                }

                if (!string.IsNullOrEmpty(url))
                {
                    idx++;
                    media.Add(new DouyinMedia { Url = url, Type = "video", Index = idx });
                }
            }

            return new DouyinAweme
            {
                Id = id, Desc = Str(el, "desc") ?? "", CreatedAt = created,
                AuthorId = authorId, AuthorName = authorName, AuthorUniqueId = uniqueId,
                Media = media,
                DiggCount = Int(el, "digg_count"),
                CommentCount = Int(el, "comment_count"),
                ShareCount = Int(el, "share_count"),
            };
        }
        catch { return null; }
    }

    /// <summary>
    /// 从页面 JSON 里批量抽作品。递归找所有含 aweme_id 的对象 ——
    /// 抖音各页面里列表的嵌套深度不同，写死路径会漏。
    /// </summary>
    public static List<DouyinAweme> ParseAllAwemes(JsonElement root)
    {
        var found = new List<DouyinAweme>();
        var seen = new HashSet<string>();
        Walk(root, found, seen, 0);
        return found;
    }

    private static void Walk(JsonElement el, List<DouyinAweme> found, HashSet<string> seen, int depth)
    {
        if (depth > 30) return;   // 防畸形 JSON 打爆栈

        switch (el.ValueKind)
        {
            case JsonValueKind.Object:
                if (el.TryGetProperty("aweme_id", out _))
                {
                    var a = ParseAweme(el);
                    if (a is not null && seen.Add(a.Id)) found.Add(a);
                    return;   // 已是作品，不再往里钻（否则评论里的 id 也会被当作品）
                }
                foreach (var prop in el.EnumerateObject())
                    Walk(prop.Value, found, seen, depth + 1);
                break;

            case JsonValueKind.Array:
                foreach (var item in el.EnumerateArray())
                    Walk(item, found, seen, depth + 1);
                break;
        }
    }

    /// <summary>取 url_list 里最后一个可用地址（抖音常给多个 CDN，最后一个通常最稳）。</summary>
    private static string PickUrlList(JsonElement parent, string prop)
    {
        if (!parent.TryGetProperty(prop, out var list) || list.ValueKind != JsonValueKind.Array)
            return "";
        var last = "";
        foreach (var u in list.EnumerateArray())
        {
            var s = u.GetString();
            if (!string.IsNullOrEmpty(s)) last = s!;
        }
        return last.Replace("http://", "https://");
    }

    private static string? Str(JsonElement el, string name)
        => el.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static int Int(JsonElement el, string name)
        => el.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : 0;

    /// <summary>
    /// 从分享文本里抽 URL。用户粘的常是「7.92 复制打开抖音… https://v.douyin.com/xxx/」
    /// 这种带前后缀的整段话。
    /// </summary>
    public static string? ExtractShareUrl(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var m = Regex.Match(text, "https?://[\\w.-]+(?:/[\\w./?=&%-]*)?");
        return m.Success ? m.Value : null;
    }

    /// <summary>从作品页 URL 里抽作品 id（/video/7xxxxxxxxxxxxxxxxxx）。</summary>
    public static string? ExtractAwemeIdFromUrl(string? url)
    {
        if (string.IsNullOrEmpty(url)) return null;
        var m = Regex.Match(url, "/(?:video|note|share/video)/(\\d{15,25})");
        return m.Success ? m.Groups[1].Value : null;
    }
}