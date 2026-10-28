using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.X;

/// <summary>X 用户（主页搜索加载出来的用户信息）。</summary>
public sealed record XHomeUser
{
    public string? Id { get; init; }
    public string? Name { get; init; }
    public string? ScreenName { get; init; }
    public string? Description { get; init; }
    public string? Avatar { get; init; }
    public int? MediaCount { get; init; }
    public int? FollowersCount { get; init; }
    public int? FriendsCount { get; init; }

    /// <summary>展示名：昵称优先，回落 @screenName。</summary>
    public string DisplayName => !string.IsNullOrWhiteSpace(Name)
        ? Name!
        : (!string.IsNullOrWhiteSpace(ScreenName) ? "@" + ScreenName : "未知用户");
}

/// <summary>X 接口错误（带 HTTP 状态码 —— 401/403/404/429 给用户的提示各不相同）。</summary>
public sealed class XHomeException : Exception
{
    public int? StatusCode { get; }

    public XHomeException(string message, int? statusCode = null) : base(message)
        => StatusCode = statusCode;
}

/// <summary>解析出来的目标类型：screen_name 还是 user_id。</summary>
public enum XHomeTargetKind { ScreenName, UserId }

/// <summary>
/// 把用户在主页输入框里敲的东西归一化成 X 的 screen_name 或 user_id。
///
/// 接受的写法：nasa / @nasa / https://x.com/nasa / https://twitter.com/nasa/ /
/// x.com/nasa。纯数字按 user_id 处理（REST v1.1 的 users/show.json 支持，
/// GraphQL 的 UserByScreenName 只认 screen_name）。认不出返回 null，
/// 由调用方给出「认不出这个输入」的提示 —— 不要在这里静默兜底成别的用户。
///
/// 抽成纯函数是为了能离线自测：这是整页第一个会出错的地方。
/// </summary>
public static class XHomeInput
{
    private static readonly string[] Reserved = new[]
    {
        "i", "home", "explore", "search", "settings", "notifications",
        "messages", "compose", "login", "logout", "signup", "tos", "privacy",
        "share", "intent", "hashtag", "about", "download",
    };

    public static (XHomeTargetKind Kind, string Value)? Parse(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var s = raw.Trim();

        // 主页链接：取路径第一段（status / i / home 这类段随后被 Reserved 挡掉）
        var m = Regex.Match(s,
            @"(?:^|//)(?:www\.|mobile\.)?(?:x|twitter)\.com/(?:#!\/)?([^/?#\s]+)",
            RegexOptions.IgnoreCase);
        if (m.Success) s = m.Groups[1].Value;

        s = s.TrimStart((char)64).Trim().TrimEnd((char)47);
        if (s.Length == 0) return null;
        if (Array.IndexOf(Reserved, s.ToLowerInvariant()) >= 0) return null;

        // 纯数字 = 用户 ID（X 的 rest_id 就是纯数字）
        if (Regex.IsMatch(s, @"^\d{1,25}$")) return (XHomeTargetKind.UserId, s);

        // screen_name：字母数字下划线，最长 15
        if (Regex.IsMatch(s, @"^[A-Za-z0-9_]{1,15}$")) return (XHomeTargetKind.ScreenName, s);

        return null;
    }
}

/// <summary>
/// X 真实抓取客户端 —— 从 Flutter 版 lib/services/x_api.dart 的抓取链路移植。
///
/// **为什么必须有它**：X 没有「给个 id 就返回 JSON」的公开接口，但它的 Web 客户端
/// 走的是公开的 GraphQL 端点（带 Cookie + Bearer + csrf）。Flutter 版就是这么抓的，
/// 所以这里不再需要 WebView2：一次 HTTP 请求就能拿到用户信息与媒体列表。
///
/// 三个必须同时具备的头（少一个就 401/403）：
///   1. Authorization: Bearer &lt;公开常量&gt;
///   2. Cookie: &lt;用户从浏览器复制的整串 cookie，其中必须含 ct0&gt;
///   3. X-Csrf-Token: &lt;cookie 里的 ct0&gt;
///
/// queryId（GraphQL 的 doc_id）X 每 2~4 周轮换一次，过期就是 404「Query not found」。
/// 所以：内置兜底值 → 404 时抓 x.com 的 JS bundle 重新解析 → 再试一次。
/// </summary>
public sealed class XHomeApi
{
    private const string Bearer =
        "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";

    private const string UserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";

    private const string Api = "https://x.com";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(25) };

    /// <summary>硬编码兜底 queryId（取自原版 X-Spider 2.2.2，过期后由 bundle 解析覆盖）。</summary>
    private static readonly Dictionary<string, string> QueryIdFallback = new()
    {
        ["UserByScreenName"] = "NimuplG1OB7Fd2btCLdBOw",
        ["UserMedia"] = "cEjpJXA15Ok78yO4TUQPeQ",
    };

    /// <summary>进程内 queryId 缓存（抓到新值就记住，不必每次重抓 bundle）。</summary>
    private static readonly Dictionary<string, string> QueryIdCache = new();

    private static readonly Dictionary<string, object> UserFeatures = new()
    {
        ["hidden_profile_likes_enabled"] = true,
        ["hidden_profile_subscriptions_enabled"] = true,
        ["responsive_web_graphql_exclude_directive_enabled"] = true,
        ["verified_phone_label_enabled"] = false,
        ["subscriptions_verification_info_is_identity_verified_enabled"] = true,
        ["subscriptions_verification_info_verified_since_enabled"] = true,
        ["highlights_tweets_tab_ui_enabled"] = true,
        ["responsive_web_twitter_article_notes_tab_enabled"] = false,
        ["creator_subscriptions_tweet_preview_api_enabled"] = true,
        ["responsive_web_graphql_skip_user_profile_image_extensions_enabled"] = false,
        ["responsive_web_graphql_timeline_navigation_enabled"] = true,
    };

    private static readonly Dictionary<string, object> MediaFeatures = new()
    {
        ["responsive_web_graphql_exclude_directive_enabled"] = true,
        ["verified_phone_label_enabled"] = false,
        ["creator_subscriptions_tweet_preview_api_enabled"] = true,
        ["responsive_web_graphql_timeline_navigation_enabled"] = true,
        ["responsive_web_graphql_skip_user_profile_image_extensions_enabled"] = false,
        ["c9s_tweet_anatomy_moderator_badge_enabled"] = true,
        ["tweetypie_unmention_optimization_enabled"] = true,
        ["responsive_web_edit_tweet_api_enabled"] = true,
        ["graphql_is_translatable_rweb_tweet_is_translatable_enabled"] = true,
        ["view_counts_everywhere_api_enabled"] = true,
        ["longform_notetweets_consumption_enabled"] = true,
        ["responsive_web_twitter_article_tweet_consumption_enabled"] = true,
        ["tweet_awards_web_tipping_enabled"] = false,
        ["freedom_of_speech_not_reach_fetch_enabled"] = true,
        ["standardized_nudges_misinfo"] = true,
        ["tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled"] = true,
        ["rweb_video_timestamps_enabled"] = true,
        ["longform_notetweets_rich_text_read_enabled"] = true,
        ["longform_notetweets_inline_media_enabled"] = true,
        ["responsive_web_media_download_video_enabled"] = false,
        ["responsive_web_enhance_cards_enabled"] = false,
    };

    private readonly string _cookie;
    private readonly string _csrf;

    public XHomeApi(string? cookie)
    {
        _cookie = (cookie ?? "").Trim();
        _csrf = ExtractCsrf(_cookie) ?? "";
    }

    /// <summary>cookie 与 ct0 都在才算「已登录」—— 缺 ct0 时 GraphQL 一律 403。</summary>
    public bool HasLogin => _cookie.Length > 0 && _csrf.Length > 0;

    /// <summary>从整串 cookie 里抽 ct0（GraphQL 的 X-Csrf-Token 就是它）。</summary>
    public static string? ExtractCsrf(string? cookie)
    {
        if (string.IsNullOrWhiteSpace(cookie)) return null;
        foreach (var part in cookie.Split((char)59))
        {
            var kv = part.Trim();
            var eq = kv.IndexOf((char)61);
            if (eq <= 0) continue;
            if (kv[..eq].Trim() == "ct0") return kv[(eq + 1)..].Trim();
        }
        return null;
    }

    // ── 对外能力 ──────────────────────────────────────────────

    /// <summary>
    /// 加载用户信息。输入可以是用户名 / @用户名 / user_id / 主页链接。
    ///
    /// 路径与 Flutter 版一致：GraphQL UserByScreenName 优先，非 401/403 的失败
    /// （queryId 过期、端点变更）降级到 REST v1.1 users/show.json。
    /// </summary>
    public async Task<XHomeUser> GetUserAsync(string input, CancellationToken ct = default)
    {
        if (!HasLogin)
            throw new XHomeException("未登录：请先在下方填入 X 登录 Cookie（需含 ct0）");

        var target = XHomeInput.Parse(input)
            ?? throw new XHomeException("认不出这个输入：请输入 X 用户名（如 nasa）、@nasa 或主页链接");

        if (target.Kind == XHomeTargetKind.UserId)
            return await GetUserRestAsync("user_id", target.Value, ct);

        try
        {
            var pars = new Dictionary<string, string>
            {
                ["variables"] = JsonSerializer.Serialize(new Dictionary<string, object?>
                {
                    ["screen_name"] = target.Value,
                    ["withSafetyModeUserFields"] = true,
                }),
                ["features"] = JsonSerializer.Serialize(UserFeatures),
                ["fieldToggles"] = "{\"withAuxiliaryUserLabels\":false}",
            };
            using var doc = await GraphqlAsync("UserByScreenName", pars, ct);
            var user = ParseUserGraphql(doc.RootElement);
            if (user is not null) return user;

            // **200 但没有用户数据 = X 明确告知这个账号不可用**（2026-10-28 实测）。
            // 响应形如 data.user.result = { __typename:"UserUnavailable",
            //   message:"User is suspended", reason:"Suspended" }。
            //
            // 以前这里抛 404，然后被下面的 catch(Exception) 降级到 REST v1.1 ——
            // 但 **v1.1 用户端点已被 X 下线**，那条路必然返回 403，
            // 最终用户看到「被 X 拒绝访问（403）：登录可能已失效」，完全指错方向。
            // 现在把 X 给的原因直接翻译出来，并且**不再降级**。
            var why = DescribeUserUnavailable(doc.RootElement);
            throw new XHomeException(why ?? ("找不到该用户：" + target.Value), 0);
        }
        catch (XHomeException)
        {
            // 业务性失败（账号被封/不存在、限流等）原样抛，**不再降级到 v1.1**：
            // v1.1 用户端点已被下线，降级只会把真实原因盖成 403。
            throw;
        }
    }

    /// <summary>
    /// 加载某个 user_id 的媒体列表（分页）。
    /// cursor 传 null 即第一页。翻页失败**不降级** —— REST 只能取第一页，
    /// 降级会把首页数据重复塞进列表。
    /// </summary>
    public async Task<XTimelinePage> GetMediasAsync(
        string userId, string? cursor, int count = 20, CancellationToken ct = default)
    {
        if (!HasLogin)
            throw new XHomeException("未登录：请先在下方填入 X 登录 Cookie（需含 ct0）");
        if (string.IsNullOrWhiteSpace(userId))
            throw new XHomeException("缺少用户 ID，无法加载作品列表");

        try
        {
            var vars = new Dictionary<string, object?>
            {
                ["userId"] = userId,
                ["count"] = count,
                ["includePromotedContent"] = false,
                ["withClientEventToken"] = false,
                ["withBirdwatchNotes"] = false,
                ["withVoice"] = true,
                ["withV2Timeline"] = true,
            };
            if (!string.IsNullOrEmpty(cursor)) vars["cursor"] = cursor;

            var pars = new Dictionary<string, string>
            {
                ["variables"] = JsonSerializer.Serialize(vars),
                ["features"] = JsonSerializer.Serialize(MediaFeatures),
            };
            using var doc = await GraphqlAsync("UserMedia", pars, ct);
            return XApi.ParseTimeline(doc.RootElement);
        }
        catch (XHomeException e) when (e.StatusCode is 401 or 403)
        {
            throw;
        }
        catch (Exception e)
        {
            if (!string.IsNullOrEmpty(cursor)) throw;
            var path = "/i/api/1.1/statuses/user_timeline.json?user_id="
                + Uri.EscapeDataString(userId)
                + "&count=200&tweet_mode=extended&include_entities=true"
                + "&exclude_replies=true&exclude_retweets=true";
            try
            {
                using var doc = await GetJsonAsync(Api + path, true, ct);
                return XApi.ParseTimelineV11(doc.RootElement);
            }
            catch
            {
                // 降级也失败：把 GraphQL 的原始错误抛出去更有诊断价值
                throw e is XHomeException ? e : new XHomeException("加载媒体失败：" + e.Message);
            }
        }
    }

    /// <summary>
    /// 验证 cookie 是否还有效，返回当前登录账号的 screen_name。
    ///
    /// 只请求首页 HTML（**只带 Cookie，不带 Authorization** —— 带 Bearer 请求
    /// 首页会 401，这是 Flutter 版实测过的）。
    /// </summary>
    public async Task<string?> VerifyLoginAsync(CancellationToken ct = default)
    {
        if (!HasLogin) throw new XHomeException("未登录：请先填入 X 登录 Cookie（需含 ct0）");
        using var req = new HttpRequestMessage(HttpMethod.Get, Api + "/");
        ApplyHeaders(req, auth: false);
        using var resp = await Http.SendAsync(req, ct);
        if ((int)resp.StatusCode >= 400)
            throw new XHomeException("HTTP " + (int)resp.StatusCode + "：cookie 可能已失效", (int)resp.StatusCode);
        var html = await resp.Content.ReadAsStringAsync(ct);
        var m = Regex.Match(html, "\"screen_name\":\"([A-Za-z0-9_]{1,15})\"");
        return m.Success ? m.Groups[1].Value : null;
    }

    // ── 响应解析（纯函数，离线可测）────────────────────────────

    /// <summary>解析 GraphQL UserByScreenName：data.user.result.{rest_id,legacy}。</summary>
    public static XHomeUser? ParseUserGraphql(JsonElement root)
    {
        try
        {
            if (!Dig(root, out var result, "data", "user", "result")) return null;
            if (!result.TryGetProperty("legacy", out var legacy) ||
                legacy.ValueKind != JsonValueKind.Object) return null;

            var id = result.TryGetProperty("rest_id", out var rid) ? rid.GetString() : null;
            return new XHomeUser
            {
                Id = id,
                Name = Str(legacy, "name"),
                ScreenName = Str(legacy, "screen_name"),
                Description = Str(legacy, "description"),
                Avatar = BigAvatar(Str(legacy, "profile_image_url_https")),
                MediaCount = Int(legacy, "media_count"),
                FollowersCount = Int(legacy, "followers_count"),
                FriendsCount = Int(legacy, "friends_count"),
            };
        }
        catch { return null; }
    }

    /// <summary>解析 REST v1.1 users/show.json（根节点就是 user 对象）。</summary>
    public static XHomeUser? ParseUserV11(JsonElement root)
    {
        try
        {
            if (root.ValueKind != JsonValueKind.Object) return null;
            var id = Str(root, "id_str") ?? (root.TryGetProperty("id", out var i) ? i.ToString() : null);
            var sn = Str(root, "screen_name");
            if (string.IsNullOrEmpty(id) && string.IsNullOrEmpty(sn)) return null;
            return new XHomeUser
            {
                Id = id,
                Name = Str(root, "name"),
                ScreenName = sn,
                Description = Str(root, "description"),
                Avatar = BigAvatar(Str(root, "profile_image_url_https")),
                MediaCount = Int(root, "media_count"),
                FollowersCount = Int(root, "followers_count"),
                FriendsCount = Int(root, "friends_count"),
            };
        }
        catch { return null; }
    }

    /// <summary>头像统一换 400x400（X 默认给 _normal 的小图）。</summary>
    private static string? BigAvatar(string? url)
        => string.IsNullOrWhiteSpace(url) ? url : url.Replace("_normal", "_400x400");

    // ── HTTP 细节 ─────────────────────────────────────────────

    private async Task<XHomeUser> GetUserRestAsync(string key, string value, CancellationToken ct)
    {
        var path = "/i/api/1.1/users/show.json?" + key + "=" + Uri.EscapeDataString(value)
                   + "&include_entities=false&skip_status=true";
        using var doc = await GetJsonAsync(Api + path, true, ct);
        var user = ParseUserV11(doc.RootElement);
        if (user is null) throw new XHomeException("找不到该用户：" + value, 404);
        return user;
    }

    private async Task<JsonDocument> GraphqlAsync(
        string operation, Dictionary<string, string> pars, CancellationToken ct)
    {
        var queryId = await ResolveQueryIdAsync(operation, ct);
        if (string.IsNullOrEmpty(queryId))
            throw new XHomeException("无法解析 " + operation + " 的 queryId（X 前端已改版？）");

        var url = Api + "/i/api/graphql/" + queryId + "/" + operation + "?" + BuildQuery(pars);
        try
        {
            return await GetJsonAsync(url, true, ct);
        }
        catch (XHomeException e) when (e.StatusCode is 404 or 400)
        {
            // queryId 轮换了：抓 bundle 拿新值再试一次，拿不到就如实抛
            var fresh = await RefreshQueryIdAsync(operation, ct);
            if (string.IsNullOrEmpty(fresh) || fresh == queryId) throw;
            var retry = Api + "/i/api/graphql/" + fresh + "/" + operation + "?" + BuildQuery(pars);
            return await GetJsonAsync(retry, true, ct);
        }
    }

    /// <summary>
    /// 对外的通用 GraphQL 入口（给 XFollowingApi 这类「另一个文件里的新操作」用）。
    /// 复用同一套 queryId 解析 + 轮换重试 + Cookie，不重复实现 HTTP。
    /// </summary>
    public Task<JsonDocument> GraphqlRawAsync(
        string operation, Dictionary<string, string> pars, CancellationToken ct = default)
        => GraphqlAsync(operation, pars, ct);
    private static async Task<string> ResolveQueryIdAsync(string operation, CancellationToken ct)
    {
        if (QueryIdCache.TryGetValue(operation, out var hit) && !string.IsNullOrEmpty(hit)) return hit;
        if (QueryIdFallback.TryGetValue(operation, out var fb) && !string.IsNullOrEmpty(fb))
        {
            QueryIdCache[operation] = fb;
            return fb;
        }
        return await RefreshQueryIdAsync(operation, ct);
    }

    /// <summary>抓 x.com 首页 HTML → 找 JS bundle → 从 bundle 里解析 queryId。</summary>
    private static async Task<string> RefreshQueryIdAsync(string operation, CancellationToken ct)
    {
        foreach (var page in new[] { "/home", "/" })
        {
            try
            {
                var html = await GetTextAsync(Api + page, ct);
                foreach (Match m in Regex.Matches(html,
                    "https://abs\\.twimg\\.com/(?:responsive-web/client-web|x-web)[^\"'\\s\\\\]+\\.js"))
                {
                    try
                    {
                        var js = await GetTextAsync(m.Value, ct);
                        var id = PickQueryId(js, operation);
                        if (!string.IsNullOrEmpty(id))
                        {
                            QueryIdCache[operation] = id;
                            return id;
                        }
                    }
                    catch { }
                }
            }
            catch { }
        }
        return QueryIdFallback.TryGetValue(operation, out var fb) ? fb : "";
    }

    private static string? PickQueryId(string js, string operation)
    {
        var patterns = new[]
        {
            "queryId:\"([^\"]{10,64})\",operationName:\"" + operation + "\"",
            "operationName:\"" + operation + "\",queryId:\"([^\"]{10,64})\"",
        };
        foreach (var p in patterns)
        {
            var m = Regex.Match(js, p);
            if (m.Success) return m.Groups[1].Value;
        }
        return null;
    }

    private static string BuildQuery(Dictionary<string, string> pars)
    {
        var sb = new StringBuilder();
        foreach (var kv in pars)
        {
            if (sb.Length > 0) sb.Append((char)38);
            sb.Append(Uri.EscapeDataString(kv.Key)).Append((char)61).Append(Uri.EscapeDataString(kv.Value));
        }
        return sb.ToString();
    }

    private void ApplyHeaders(HttpRequestMessage req, bool auth)
    {
        req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        req.Headers.TryAddWithoutValidation("Referer", Api + "/");
        req.Headers.TryAddWithoutValidation("Accept", "*/*");
        if (_cookie.Length > 0) req.Headers.TryAddWithoutValidation("Cookie", _cookie);
        if (auth && _csrf.Length > 0)
        {
            req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + Bearer);
            req.Headers.TryAddWithoutValidation("X-Csrf-Token", _csrf);
            req.Headers.TryAddWithoutValidation("x-twitter-active-user", "yes");
            req.Headers.TryAddWithoutValidation("x-twitter-client-language", "en");
        }
    }

    private async Task<JsonDocument> GetJsonAsync(string url, bool auth, CancellationToken ct)
    {
        Exception? last = null;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                ApplyHeaders(req, auth);
                using var resp = await Http.SendAsync(req, ct);
                var body = await resp.Content.ReadAsStringAsync(ct);

                if (resp.StatusCode == HttpStatusCode.TooManyRequests)
                {
                    last = new XHomeException("被 X 限流（429），稍后再试", 429);
                    await Task.Delay(900 * (attempt + 1), ct);
                    continue;
                }
                if ((int)resp.StatusCode >= 400)
                    throw new XHomeException(
                        "HTTP " + (int)resp.StatusCode + "：" + Truncate(body, 180), (int)resp.StatusCode);

                return JsonDocument.Parse(body);
            }
            catch (XHomeException) { throw; }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new XHomeException("连接 X 超时，请检查网络或代理设置");
            }
            catch (HttpRequestException e)
            {
                last = e;
                await Task.Delay(350 * (attempt + 1), ct);
            }
        }

        throw new XHomeException(FriendlyNetworkError(last) ?? ("网络错误：" + (last?.Message ?? "未知")));
    }

    private static async Task<string> GetTextAsync(string url, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        using var resp = await Http.SendAsync(req, ct);
        if ((int)resp.StatusCode >= 400)
            throw new XHomeException("HTTP " + (int)resp.StatusCode, (int)resp.StatusCode);
        return await resp.Content.ReadAsStringAsync(ct);
    }

    // ── 错误提示 ──────────────────────────────────────────────

    /// <summary>
    /// 把底层网络异常翻译成**可操作**的中文提示；非网络类返回 null。
    /// 国内直连 x.com 的典型表现是 TLS 握手被中断 —— 用户能做只有配代理。
    /// </summary>
    public static string? FriendlyNetworkError(Exception? e)
    {
        if (e is null) return null;
        var s = e.ToString();
        if (s.Contains("Authentication") || s.Contains("SSL") || s.Contains("TLS"))
            return "无法连接 X：TLS 握手失败（网络被阻断）→ 请配置系统代理后重试";
        if (s.Contains("Name or service not known") || s.Contains("No such host") ||
            s.Contains("actively refused") || s.Contains("unreachable"))
            return "无法连接 X：网络不可达 → 请配置系统代理后重试";
        if (s.Contains("timed out") || s.Contains("timeout", StringComparison.OrdinalIgnoreCase))
            return "连接 X 超时 → 请检查网络或代理";
        return null;
    }

    /// <summary>把状态码映射成给用户看的一句话。</summary>
    public static string MapError(Exception e)
    {
        if (e is XHomeException xe)
        {
            var friendly = FriendlyNetworkError(xe);
            if (friendly is not null) return friendly;
            return xe.StatusCode switch
            {
                401 => "登录已失效（401）：请重新复制 X 的 Cookie",
                403 => "被 X 拒绝访问（403）：登录可能已失效，或请求过于频繁",
                404 => xe.Message,
                429 => "请求过于频繁（429），请稍后再试",
                _ => xe.Message,
            };
        }
        return FriendlyNetworkError(e) ?? ("加载失败：" + e.Message);
    }

    // ── 小工具 ────────────────────────────────────────────────

    private static bool Dig(JsonElement el, out JsonElement result, params string[] path)
    {
        result = el;
        foreach (var key in path)
        {
            if (result.ValueKind != JsonValueKind.Object ||
                !result.TryGetProperty(key, out var next)) return false;
            result = next;
        }
        return true;
    }

    private static string? Str(JsonElement el, string name)
        => el.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static int? Int(JsonElement el, string name)
    {
        if (!el.TryGetProperty(name, out var v)) return null;
        if (v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n)) return n;
        if (v.ValueKind == JsonValueKind.String && int.TryParse(v.GetString(), out var p)) return p;
        return null;
    }

    private static string Truncate(string s, int n)
        => string.IsNullOrEmpty(s) ? "" : (s.Length <= n ? s : s[..n]);

    /// <summary>
    /// 把 GraphQL 的 <c>UserUnavailable</c> 翻译成给人看的中文。
    /// 不是这类响应就返回 null（交给调用方按「找不到用户」处理）。
    ///
    /// X 的原始返回（2026-10-28 实测）：
    /// <code>{"data":{"user":{"result":{"__typename":"UserUnavailable",
    ///        "message":"User is suspended","reason":"Suspended"}}}}</code>
    /// </summary>
    private static string? DescribeUserUnavailable(JsonElement root)
    {
        try
        {
            if (!root.TryGetProperty("data", out var d)) return null;
            if (!d.TryGetProperty("user", out var u)) return null;
            if (!u.TryGetProperty("result", out var r)) return null;
            var type = r.TryGetProperty("__typename", out var tn) ? tn.GetString() : null;
            if (type != "UserUnavailable") return null;

            var reason = r.TryGetProperty("reason", out var rs) ? rs.GetString() : null;
            var message = r.TryGetProperty("message", out var ms) ? ms.GetString() : null;

            return reason switch
            {
                "Suspended" => "该账号已被 X 封禁（suspended），无法获取作品",
                "NotAuthorized" => "无权查看该账号（可能是私密账号或已被限制）",
                "Unsafe" => "该账号被 X 标记为不安全内容，接口不返回数据",
                _ => "该账号当前不可用" + (string.IsNullOrWhiteSpace(message) ? "" : "：" + message),
            };
        }
        catch { return null; }
    }
}
