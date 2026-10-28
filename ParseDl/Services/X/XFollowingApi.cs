using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.X;

/// <summary>关注列表里的一个人。</summary>
public sealed class XFollowingUser
{
    public string Id { get; init; } = "";
    public string ScreenName { get; init; } = "";
    public string Name { get; init; } = "";
    public string? Avatar { get; init; }
    /// <summary>他有多少媒体作品（有就拿来判断值不值得跑）。</summary>
    public int MediaCount { get; init; }
    public bool IsFollowingMe { get; init; }
}

/// <summary>一页关注列表。</summary>
public sealed class XFollowingPage
{
    public List<XFollowingUser> Users { get; init; } = new();
    public string? NextCursor { get; init; }
    public bool HasMore => !string.IsNullOrEmpty(NextCursor);
}

/// <summary>
/// 拉取「当前登录账号的关注列表」。
///
/// ### 为什么单独一个文件（2026-10-28 用户需求）
/// 用户要在 X 自动下载里加「按关注列表下载」。X 的关注列表是 GraphQL 的
/// <c>Following</c> 操作，与已有的 <see cref="XHomeApi"/>（按 user_id 取媒体）
/// 是两条不同的接口，放在一起会让那个文件继续膨胀。
///
/// ### 复用点
/// - queryId 解析、Cookie、错误映射全部复用 <see cref="XHomeApi"/> 的现有机制：
///   这里不重复实现 HTTP，只调它暴露的 <see cref="XHomeApi.GraphqlRawAsync"/>。
/// - 关注列表操作名固定为 <c>Following</c>；queryId 由 bundle 自动解析，
///   所以 X 轮换 doc_id 时不用改代码（XHomeApi 那套兜底逻辑会生效）。
/// </summary>
public sealed class XFollowingApi
{
    private readonly XHomeApi _api;

    public XFollowingApi(XHomeApi api) => _api = api;

    public bool HasLogin => _api.HasLogin;

    /// <summary>
    /// 拉一页关注列表。<paramref name="cursor"/> 传 null 即第一页。
    /// </summary>
    /// <param name="userId">当前登录账号的 user_id（不能为空）。</param>
    /// <param name="count">每页条数，X 一般上限 50~200，这里默认 100。</param>
    public async Task<XFollowingPage> GetFollowingAsync(
        string userId, string? cursor, int count = 100, CancellationToken ct = default)
    {
        if (!HasLogin)
            throw new XHomeException("未登录：请先在 X 下载设置里填入登录 Cookie（需含 ct0）");
        if (string.IsNullOrWhiteSpace(userId))
            throw new XHomeException("缺少当前账号的 user_id，无法读取关注列表");

        var pars = new Dictionary<string, string>
        {
            ["variables"] = JsonSerializer.Serialize(new Dictionary<string, object?>
            {
                ["userId"] = userId,
                ["count"] = count,
                ["includePromotedContent"] = false,
                ["withClientEventToken"] = false,
                ["withBirdwatchNotes"] = false,
                ["withVoice"] = true,
            }),
            ["features"] = JsonSerializer.Serialize(FollowingFeatures),
        };
        if (!string.IsNullOrEmpty(cursor)) pars["variables"] =
            JsonSerializer.Serialize(new Dictionary<string, object?>
            {
                ["userId"] = userId,
                ["count"] = count,
                ["cursor"] = cursor,
                ["includePromotedContent"] = false,
                ["withClientEventToken"] = false,
                ["withBirdwatchNotes"] = false,
                ["withVoice"] = true,
            });

        using var doc = await _api.GraphqlRawAsync("Following", pars, ct);
        return ParseFollowing(doc.RootElement);
    }

    /// <summary>
    /// 一口气拉到没有下一页为止（或到 <paramref name="maxPages"/> 上限）。
    /// 关注几百人时会有很多页，所以给个上限防止无限翻。
    /// </summary>
    public async Task<List<XFollowingUser>> GetAllFollowingAsync(
        string userId, int maxPages = 20, int pageSize = 100,
        Action<int, int>? onProgress = null, CancellationToken ct = default)
    {
        var all = new List<XFollowingUser>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        string? cursor = null;

        for (var page = 0; page < maxPages; page++)
        {
            var p = await GetFollowingAsync(userId, cursor, pageSize, ct);
            foreach (var u in p.Users)
                if (!string.IsNullOrEmpty(u.Id) && seen.Add(u.Id)) all.Add(u);

            onProgress?.Invoke(page + 1, all.Count);
            if (!p.HasMore) break;
            cursor = p.NextCursor;
        }
        return all;
    }

    /// <summary>
    /// 解析 GraphQL Following 响应。
    ///
    /// 结构（2026-10 实测形状）：
    /// <code>
    /// data.user.result.timeline.timeline.instructions[]
    ///   → { type: "TimelineAddEntries", entries[] }
    ///       entry.entryId 以 "user-" 开头 → content.itemContent.user_results.result
    ///       entry.entryId 以 "cursor-bottom" 开头 → content.value 即下一页 cursor
    /// </code>
    /// 注意：**游标 entry 与用户 entry 混在同一个数组里**，不能只认 user-，
    /// 否则永远拿不到下一页（第一版就踩过这个）。
    /// </summary>
    public static XFollowingPage ParseFollowing(JsonElement root)
    {
        var users = new List<XFollowingUser>();
        string? nextCursor = null;

        try
        {
            if (!root.TryGetProperty("data", out var data)) return new XFollowingPage();
            if (!data.TryGetProperty("user", out var user)) return new XFollowingPage();
            if (!user.TryGetProperty("result", out var result)) return new XFollowingPage();
            if (!result.TryGetProperty("timeline", out var timeline)) return new XFollowingPage();
            if (!timeline.TryGetProperty("timeline", out var tl)) return new XFollowingPage();
            if (!tl.TryGetProperty("instructions", out var ins) || ins.ValueKind != JsonValueKind.Array)
                return new XFollowingPage();

            foreach (var inst in ins.EnumerateArray())
            {
                if (!inst.TryGetProperty("entries", out var entries)
                    || entries.ValueKind != JsonValueKind.Array) continue;

                foreach (var e in entries.EnumerateArray())
                {
                    var entryId = Str(e, "entryId") ?? "";

                    // 游标
                    if (entryId.StartsWith("cursor-bottom", StringComparison.Ordinal))
                    {
                        if (e.TryGetProperty("content", out var c))
                            nextCursor = Str(c, "value");
                        continue;
                    }

                    // 用户条目
                    if (!e.TryGetProperty("content", out var content)) continue;
                    if (!content.TryGetProperty("itemContent", out var item)) continue;
                    if (!item.TryGetProperty("user_results", out var ur)) continue;
                    if (!ur.TryGetProperty("result", out var r)) continue;

                    var u = ParseUser(r);
                    if (u is not null) users.Add(u);
                }
            }
        }
        catch { /* 形状不对 → 返回已解析到的部分 */ }

        return new XFollowingPage { Users = users, NextCursor = nextCursor };
    }

    private static XFollowingUser? ParseUser(JsonElement r)
    {
        try
        {
            var id = Str(r, "rest_id");
            if (string.IsNullOrEmpty(id)) return null;

            var legacy = r.TryGetProperty("legacy", out var l) ? l : r;
            var sn = Str(legacy, "screen_name") ?? "";
            if (string.IsNullOrEmpty(sn)) return null;

            var followingMe = false;
            if (legacy.TryGetProperty("following", out var f))
                followingMe = f.ValueKind == JsonValueKind.True;

            return new XFollowingUser
            {
                Id = id,
                ScreenName = sn,
                Name = Str(legacy, "name") ?? sn,
                Avatar = (Str(legacy, "profile_image_url_https") ?? "").Replace("_normal", "_400x400"),
                MediaCount = Int(legacy, "media_count"),
                IsFollowingMe = followingMe,
            };
        }
        catch { return null; }
    }

    private static string? Str(JsonElement e, string key)
        => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v)
           && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static int Int(JsonElement e, string key)
        => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v)
           && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n) ? n : 0;

    /// <summary>Following 要的 features 开关（缺了会返回空列表，不是报错 —— 容易误判成"没关注"）。</summary>
    private static readonly Dictionary<string, bool> FollowingFeatures = new()
    {
        ["rweb_video_screen_enabled"] = false,
        ["payments_enabled"] = false,
        ["profile_label_improvements_pcf_label_in_post_enabled"] = true,
        ["rweb_tipjar_consumption_enabled"] = true,
        ["verified_phone_label_enabled"] = false,
        ["creator_subscriptions_tweet_preview_api_enabled"] = true,
        ["responsive_web_graphql_timeline_navigation_enabled"] = true,
        ["responsive_web_graphql_skip_user_profile_image_extensions_enabled"] = false,
        ["premium_content_api_read_enabled"] = false,
        ["communities_web_enable_tweet_community_results_fetch"] = true,
        ["c9s_tweet_anatomy_moderator_badge_enabled"] = true,
        ["responsive_web_grok_analyze_button_fetch_trends_enabled"] = false,
        ["responsive_web_grok_analyze_post_followups_enabled"] = true,
        ["responsive_web_jetfuel_frame"] = false,
        ["responsive_web_grok_share_attachment_enabled"] = true,
        ["articles_preview_enabled"] = true,
        ["responsive_web_edit_tweet_api_enabled"] = true,
        ["graphql_is_translatable_rweb_tweet_is_translatable_enabled"] = true,
        ["view_counts_everywhere_api_enabled"] = true,
        ["longform_notetweets_consumption_enabled"] = true,
        ["responsive_web_twitter_article_tweet_consumption_enabled"] = true,
        ["tweet_awards_web_tipping_enabled"] = false,
        ["responsive_web_grok_show_grok_translated_post"] = false,
        ["responsive_web_grok_analysis_button_from_backend"] = false,
        ["creator_subscriptions_quote_tweet_preview_enabled"] = false,
        ["freedom_of_speech_not_reach_fetch_enabled"] = true,
        ["standardized_nudges_misinfo"] = true,
        ["tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled"] = true,
        ["longform_notetweets_rich_text_read_enabled"] = true,
        ["longform_notetweets_inline_media_enabled"] = true,
        ["responsive_web_grok_image_annotation_enabled"] = true,
        ["responsive_web_grok_community_note_auto_translation_is_enabled"] = false,
        ["responsive_web_enhance_cards_enabled"] = false,
    };

    /// <summary>
    /// 离线自测：关注列表响应解析。
    /// 造一段与 X 真实结构一致的 JSON，检查用户条目与**游标**都能取到 ——
    /// 游标容易漏（它和用户条目混在同一个 entries 数组里），漏了就无法翻页。
    /// </summary>
    public static string SelfTest()
    {
        var sb = new System.Text.StringBuilder();

        var json = @"{
          ""data"": { ""user"": { ""result"": { ""timeline"": { ""timeline"": {
            ""instructions"": [ { ""type"": ""TimelineAddEntries"", ""entries"": [
              { ""entryId"": ""user-111"", ""content"": { ""itemContent"": { ""user_results"": { ""result"": {
                  ""rest_id"": ""111"", ""legacy"": { ""screen_name"": ""alice"", ""name"": ""Alice"", ""media_count"": 42, ""following"": true } } } } } },
              { ""entryId"": ""user-222"", ""content"": { ""itemContent"": { ""user_results"": { ""result"": {
                  ""rest_id"": ""222"", ""legacy"": { ""screen_name"": ""bob"", ""name"": ""Bob"", ""media_count"": 7 } } } } } },
              { ""entryId"": ""cursor-bottom-999"", ""content"": { ""value"": ""CURSOR_NEXT"" } }
            ] } ]
          } } } } }
        }";

        using var doc = JsonDocument.Parse(json);
        var page = ParseFollowing(doc.RootElement);

        sb.AppendLine("[解析] 用户数 " + page.Users.Count + "（应为 2）：" +
            (page.Users.Count == 2 ? "OK" : "FAIL"));
        sb.AppendLine("[解析] 下一页游标 " + (page.NextCursor ?? "null") + "：" +
            (page.NextCursor == "CURSOR_NEXT" ? "OK" : "FAIL"));
        sb.AppendLine("[解析] HasMore = " + page.HasMore + "：" + (page.HasMore ? "OK" : "FAIL"));

        if (page.Users.Count == 2)
        {
            var a = page.Users[0];
            var b = page.Users[1];
            sb.AppendLine("[解析] 第 1 个 @" + a.ScreenName + " 作品数 " + a.MediaCount +
                " 互关 " + a.IsFollowingMe + "：" +
                (a.ScreenName == "alice" && a.MediaCount == 42 && a.IsFollowingMe ? "OK" : "FAIL"));
            sb.AppendLine("[解析] 第 2 个 @" + b.ScreenName + " 作品数 " + b.MediaCount + "：" +
                (b.ScreenName == "bob" && b.MediaCount == 7 && !b.IsFollowingMe ? "OK" : "FAIL"));
        }

        // 负例：空响应不该崩
        using var empty = JsonDocument.Parse("{}");
        var p2 = ParseFollowing(empty.RootElement);
        sb.AppendLine("[负例] 空响应不崩且 0 用户：" +
            (p2.Users.Count == 0 && !p2.HasMore ? "OK" : "FAIL"));

        return sb.ToString();
    }
}
