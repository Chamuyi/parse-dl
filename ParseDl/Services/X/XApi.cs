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
                if (!ins.TryGetProperty("entries", out var entries)) continue;
                foreach (var entry in entries.EnumerateArray())
                {
                    if (entry.TryGetProperty("content", out var ec) &&
                        ec.TryGetProperty("entryType", out var et) &&
                        et.GetString() == "TimelineTimelineCursor" &&
                        ec.TryGetProperty("cursorType", out var ct) &&
                        ct.GetString() == "Bottom")
                    {
                        if (ec.TryGetProperty("value", out var cv)) nextCursor = cv.GetString();
                        continue;
                    }

                    if (!TryDig(entry, out var tweet, "content", "itemContent", "tweet_results", "result"))
                        continue;

                    var post = ParseTweet(tweet);
                    if (post is not null) posts.Add(post);
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

                    media.Add(new XMedia { Id = mid, Type = type, Url = url, Width = w, Height = h });
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
