using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ParseDl.Services.X;

/// <summary>一条媒体（图片或视频）。</summary>
public sealed record XMedia
{
    public string Id { get; init; } = "";
    public string Type { get; init; } = "image";
    /// <summary>已归一化为原图/原视频的直链。</summary>
    public string Url { get; init; } = "";
    /// <summary>缩略图直链（网格预览用）。图片取小尺寸，视频/GIF 取封面帧。</summary>
    public string PreviewUrl { get; init; } = "";
    public int? Width { get; init; }
    public int? Height { get; init; }
}

/// <summary>一条推文。</summary>
public sealed record XPost
{
    public string Id { get; init; } = "";
    public DateTime? CreatedAt { get; init; }
    public string Text { get; init; } = "";
    public string? UserId { get; init; }
    public string? UserName { get; init; }
    public string? UserScreenName { get; init; }
    public IReadOnlyList<XMedia> Media { get; init; } = Array.Empty<XMedia>();
}

/// <summary>一页时间线结果。</summary>
public sealed record XTimelinePage
{
    public IReadOnlyList<XPost> Posts { get; init; } = Array.Empty<XPost>();
    public string? NextCursor { get; init; }
}

/// <summary>
/// X（Twitter）媒体工具 —— 从 Flutter 版 x_api.dart / twitter_time.dart 移植的纯逻辑部分。
///
/// 边界：真实抓取需要登录态（cookie + bearer + csrf），要配 WebView2 登录才能做。
/// 本文件只负责三件事，都是纯函数、可离线自测、也是抓取链路里最容易错的地方：
///   1. URL 归一化（缩略图 → 原图）
///   2. Twitter 时间格式解析
///   3. 从 GraphQL 响应 JSON 里抽推文与媒体
/// </summary>
public static class XApi
{
    /// <summary>把 X 的图片 URL 归一化为原图（name=small/medium/large → name=orig）。</summary>
    public static string NormalizeImageUrl(string url)
    {
        if (string.IsNullOrWhiteSpace(url)) return url;
        var u = url.Replace("http://", "https://");
        if (!u.Contains("pbs.twimg.com")) return u;

        if (Regex.IsMatch(u, "[?&]name=[^&]+"))
            return Regex.Replace(u, "([?&])name=[^&]+", "$1name=orig");
        return u + (u.Contains((char)63) ? "&" : "?") + "name=orig";
    }

    /// <summary>
    /// 解析 Twitter 经典时间格式：Sat Jan 20 21:15:36 +0000 2024。
    /// 解析失败返回 null —— 不返回 DateTime.MinValue，那会被当成有效日期写进文件名。
    /// </summary>
    public static DateTime? ParseTwitterTime(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var s = raw.Trim();

        var m = Regex.Match(s,
            "^[A-Za-z]{3} ([A-Za-z]{3}) (\\d{1,2}) (\\d{2}):(\\d{2}):(\\d{2}) ([+-]\\d{4}) (\\d{4})$");
        if (m.Success)
        {
            var monthNames = new[] { "Jan","Feb","Mar","Apr","May","Jun",
                                     "Jul","Aug","Sep","Oct","Nov","Dec" };
            var mon = Array.IndexOf(monthNames, m.Groups[1].Value);
            if (mon >= 0)
            {
                try
                {
                    var dt = new DateTime(
                        int.Parse(m.Groups[7].Value), mon + 1, int.Parse(m.Groups[2].Value),
                        int.Parse(m.Groups[3].Value), int.Parse(m.Groups[4].Value),
                        int.Parse(m.Groups[5].Value), DateTimeKind.Utc);
                    var off = m.Groups[6].Value;
                    var sign = off[0] == (char)45 ? -1 : 1;
                    var oh = int.Parse(off.Substring(1, 2));
                    var om = int.Parse(off.Substring(3, 2));
                    return dt.AddMinutes(-sign * (oh * 60 + om));
                }
                catch { return null; }
            }
        }

        if (DateTime.TryParse(s, null,
            System.Globalization.DateTimeStyles.AdjustToUniversal |
            System.Globalization.DateTimeStyles.AssumeUniversal, out var iso))
            return iso;

        return null;
    }

    /// <summary>
    /// 从 GraphQL 时间线响应里抽推文。
    /// 路径：data.user.result.timeline_v2.timeline.instructions[].entries[]
    /// 结构会变，所以整条链「找不到就跳过」而不是抛异常。
    /// </summary>
    public static XTimelinePage ParseTimeline(JsonElement root)
    {
        var posts = new List<XPost>();
        string? nextCursor = null;

        try
        {
            if (!TryDig(root, out var instructions,
                    "data", "user", "result", "timeline_v2", "timeline", "instructions"))
                return new XTimelinePage();

            foreach (var ins in instructions.EnumerateArray())
            {
                // 翻页时媒体会被追加到已有 module（TimelineAddToModule）
                if (ins.TryGetProperty("moduleItems", out var moduleItems) &&
                    moduleItems.ValueKind == JsonValueKind.Array)
                {
                    foreach (var it in moduleItems.EnumerateArray()) TakeTweet(it, posts);
                    continue;
                }

                if (!ins.TryGetProperty("entries", out var entries) ||
                    entries.ValueKind != JsonValueKind.Array) continue;

                foreach (var entry in entries.EnumerateArray())
                {
                    if (!entry.TryGetProperty("content", out var ec) ||
                        ec.ValueKind != JsonValueKind.Object) continue;

                    if (ec.TryGetProperty("entryType", out var et) &&
                        et.GetString() == "TimelineTimelineCursor" &&
                        ec.TryGetProperty("cursorType", out var ct) &&
                        ct.GetString() == "Bottom")
                    {
                        if (ec.TryGetProperty("value", out var cv)) nextCursor = cv.GetString();
                        continue;
                    }

                    // **UserMedia 的媒体推文通常包在 TimelineTimelineModule 里**
                    // （原版就是先找 module 再取 content.items）—— 漏掉它会一条媒体都解析不出来。
                    if (ec.TryGetProperty("items", out var items) &&
                        items.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var it in items.EnumerateArray()) TakeTweet(it, posts);
                        continue;
                    }

                    TakeTweet(ec, posts);
                }
            }
        }
        catch
        {
            // 结构变化时返回已解析到的部分，不整批丢弃
        }

        return new XTimelinePage { Posts = posts, NextCursor = nextCursor };
    }

    /// <summary>解析单条推文。</summary>
    public static XPost? ParseTweet(JsonElement tweet)
    {
        try
        {
            // 转推：真正的推文在 legacy.retweeted_status_result.result 里
            if (tweet.TryGetProperty("legacy", out var legacy0) &&
                legacy0.TryGetProperty("retweeted_status_result", out var rt) &&
                rt.TryGetProperty("result", out var rtResult))
                tweet = rtResult;

            var id = tweet.TryGetProperty("rest_id", out var rid) ? rid.GetString() ?? "" : "";
            if (string.IsNullOrEmpty(id)) return null;

            if (!tweet.TryGetProperty("legacy", out var legacy)) return null;

            var text = legacy.TryGetProperty("full_text", out var ft) ? ft.GetString() ?? "" : "";
            var createdAt = legacy.TryGetProperty("created_at", out var ca)
                ? ParseTwitterTime(ca.GetString()) : null;

            string? userId = null, userName = null, screenName = null;
            if (TryDig(tweet, out var userLegacy, "core", "user_results", "result", "legacy"))
            {
                userId = userLegacy.TryGetProperty("id_str", out var uid) ? uid.GetString() : null;
                userName = userLegacy.TryGetProperty("name", out var un) ? un.GetString() : null;
                screenName = userLegacy.TryGetProperty("screen_name", out var sn) ? sn.GetString() : null;
            }

            var media = new List<XMedia>();
            if (legacy.TryGetProperty("extended_entities", out var ee) &&
                ee.TryGetProperty("media", out var mediaArr) &&
                mediaArr.ValueKind == JsonValueKind.Array)
            {
                foreach (var m in mediaArr.EnumerateArray())
                {
                    var mid = m.TryGetProperty("id_str", out var mId) ? mId.GetString() ?? "" : "";
                    var type = m.TryGetProperty("type", out var mt) ? mt.GetString() ?? "photo" : "photo";

                    // 缩略图：视频/GIF 用封面帧（media_url_https 就是封面），图片取 small 尺寸
                    var thumbRaw = m.TryGetProperty("media_url_https", out var muth)
                        ? muth.GetString() ?? "" : "";

                    var url = "";
                    if (type == "video" || type == "animated_gif")
                    {
                        if (m.TryGetProperty("video_info", out var vi) &&
                            vi.TryGetProperty("variants", out var variants) &&
                            variants.ValueKind == JsonValueKind.Array)
                        {
                            var best = variants.EnumerateArray()
                                .Where(v => v.TryGetProperty("content_type", out var ctv) &&
                                            (ctv.GetString() ?? "").Contains("mp4"))
                                .OrderByDescending(v => v.TryGetProperty("bitrate", out var br) ? br.GetInt32() : 0)
                                .FirstOrDefault();
                            if (best.ValueKind == JsonValueKind.Object && best.TryGetProperty("url", out var bu))
                                url = bu.GetString() ?? "";
                        }
                        type = type == "animated_gif" ? "gif" : "video";
                    }
                    else
                    {
                        url = m.TryGetProperty("media_url_https", out var mu) ? mu.GetString() ?? "" : "";
                        url = NormalizeImageUrl(url);
                    }

                    if (string.IsNullOrEmpty(url)) continue;

                    int? w = null, h = null;
                    if (m.TryGetProperty("original_info", out var oi))
                    {
                        if (oi.TryGetProperty("width", out var ow)) w = ow.GetInt32();
                        if (oi.TryGetProperty("height", out var oh)) h = oh.GetInt32();
                    }

                    media.Add(new XMedia
                    {
                        Id = mid, Type = type, Url = url,
                        PreviewUrl = ThumbnailUrl(thumbRaw),
                        Width = w, Height = h,
                    });
                }
            }

            return new XPost
            {
                Id = id, CreatedAt = createdAt, Text = text,
                UserId = userId, UserName = userName, UserScreenName = screenName,
                Media = media,
            };
        }
        catch { return null; }
    }

    /// <summary>
    /// 从「一个可能装着推文的节点」里取推文并加进结果。
    ///
    /// 兼容三种形态（Flutter 版同样都要认，否则一条媒体都解析不出来）：
    ///   ① entry.content.itemContent.tweet_results.result（单条 entry）
    ///   ② module.items[].item.itemContent.tweet_results.result（媒体推文默认包在 module 里）
    ///   ③ 节点本身就是 itemContent / tweet_results
    /// 另外 TweetWithVisibilityResults 是 X 给「可见性受限推文」加的包装层，要剥掉。
    /// </summary>
    private static void TakeTweet(JsonElement node, List<XPost> posts)
    {
        if (node.ValueKind != JsonValueKind.Object) return;

        if (!TryDig(node, out var tweet, "itemContent", "tweet_results", "result") &&
            !TryDig(node, out tweet, "tweet_results", "result"))
        {
            // ②：module item 的形式是 { item: { itemContent: … } }
            if (!TryDig(node, out var item, "item") ||
                !TryDig(item, out tweet, "itemContent", "tweet_results", "result"))
                return;
        }
        if (tweet.ValueKind != JsonValueKind.Object) return;

        if (tweet.TryGetProperty("__typename", out var tn) &&
            tn.GetString() == "TweetWithVisibilityResults" &&
            tweet.TryGetProperty("tweet", out var inner) &&
            inner.ValueKind == JsonValueKind.Object)
        {
            tweet = inner;
        }

        var post = ParseTweet(tweet);
        if (post is not null) posts.Add(post);
    }

    /// <summary>
    /// 缩略图 URL：X 的图片直链靠 name 参数取尺寸（small / medium / large / orig）。
    /// 非 pbs.twimg.com 的地址原样返回（视频封面也是 pbs 上的图，规则相同）。
    /// </summary>
    public static string ThumbnailUrl(string? url, string size = "small")
    {
        if (string.IsNullOrWhiteSpace(url)) return "";
        var u = url.Replace("http://", "https://");
        if (!u.Contains("pbs.twimg.com")) return u;
        if (Regex.IsMatch(u, "[?&]name=[^&]+"))
            return Regex.Replace(u, "([?&])name=[^&]+", "$1name=" + size);
        return u + (u.Contains((char)63) ? "&" : "?") + "name=" + size;
    }

    /// <summary>
    /// REST v1.1 `statuses/user_timeline.json` 的解析（GraphQL 不可用时的降级路径）。
    ///
    /// v1.1 的结构与 GraphQL 完全不同：数组根、媒体在 extended_entities.media[]、
    /// 视频地址在 video_info.variants。**不要**拿它去喂 ParseTimeline。
    /// </summary>
    public static XTimelinePage ParseTimelineV11(JsonElement root)
    {
        var posts = new List<XPost>();
        if (root.ValueKind != JsonValueKind.Array) return new XTimelinePage();

        foreach (var t in root.EnumerateArray())
        {
            try
            {
                if (t.ValueKind != JsonValueKind.Object) continue;
                var id = t.TryGetProperty("id_str", out var rid) ? rid.GetString() ?? "" : "";
                if (string.IsNullOrEmpty(id)) continue;

                var text = "";
                if (t.TryGetProperty("full_text", out var ft)) text = ft.GetString() ?? "";
                else if (t.TryGetProperty("text", out var tx)) text = tx.GetString() ?? "";
                var createdAt = t.TryGetProperty("created_at", out var ca)
                    ? ParseTwitterTime(ca.GetString()) : null;

                var userId = ""; var userName = ""; var screenName = "";
                if (TryDig(t, out var user, "user"))
                {
                    userId = user.TryGetProperty("id_str", out var uid) ? uid.GetString() ?? "" : "";
                    userName = user.TryGetProperty("name", out var un) ? un.GetString() ?? "" : "";
                    screenName = user.TryGetProperty("screen_name", out var sn) ? sn.GetString() ?? "" : "";
                }

                var media = new List<XMedia>();
                var hasMedia = TryDig(t, out var arr, "extended_entities", "media") ||
                               TryDig(t, out arr, "entities", "media");
                if (hasMedia && arr.ValueKind == JsonValueKind.Array)
                {
                    foreach (var m in arr.EnumerateArray())
                    {
                        if (m.ValueKind != JsonValueKind.Object) continue;
                        var mid = m.TryGetProperty("id_str", out var mId) ? mId.GetString() ?? "" : "";
                        var type = m.TryGetProperty("type", out var mt) ? mt.GetString() ?? "photo" : "photo";
                        var thumb = m.TryGetProperty("media_url_https", out var mu) ? mu.GetString() ?? "" : "";

                        string url;
                        if (type is "video" or "animated_gif")
                        {
                            var best = default(JsonElement);
                            if (TryDig(m, out var variants, "video_info", "variants") &&
                                variants.ValueKind == JsonValueKind.Array)
                            {
                                best = variants.EnumerateArray()
                                    .Where(v => v.TryGetProperty("content_type", out var ctv) &&
                                                (ctv.GetString() ?? "").Contains("mp4"))
                                    .OrderByDescending(v => v.TryGetProperty("bitrate", out var br) ? br.GetInt32() : 0)
                                    .FirstOrDefault();
                            }
                            url = best.ValueKind == JsonValueKind.Object &&
                                  best.TryGetProperty("url", out var bu) ? bu.GetString() ?? "" : "";
                            type = type == "animated_gif" ? "gif" : "video";
                        }
                        else
                        {
                            url = NormalizeImageUrl(thumb);
                        }
                        if (string.IsNullOrEmpty(url)) continue;

                        int? w = null; int? h = null;
                        if (TryDig(m, out var size, "sizes", "large"))
                        {
                            if (size.TryGetProperty("w", out var ww)) w = ww.GetInt32();
                            if (size.TryGetProperty("h", out var hh)) h = hh.GetInt32();
                        }

                        media.Add(new XMedia
                        {
                            Id = mid, Type = type, Url = url,
                            PreviewUrl = ThumbnailUrl(thumb),
                            Width = w, Height = h,
                        });
                    }
                }

                posts.Add(new XPost
                {
                    Id = id, CreatedAt = createdAt, Text = text,
                    UserId = userId, UserName = userName, UserScreenName = screenName,
                    Media = media,
                });
            }
            catch
            {
                // 单条坏数据不拖垮整页
            }
        }

        return new XTimelinePage { Posts = posts, NextCursor = null };
    }

    /// <summary>逐层下钻取子节点，任一层缺失返回 false（不抛）。</summary>
    private static bool TryDig(JsonElement el, out JsonElement result, params string[] path)
    {
        result = el;
        foreach (var key in path)
        {
            if (result.ValueKind != JsonValueKind.Object || !result.TryGetProperty(key, out var next))
                return false;
            result = next;
        }
        return true;
    }
}
