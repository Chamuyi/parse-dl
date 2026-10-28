using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.Bili;

/// <summary>列表里的一条稿件（区别于完整的 BiliVideoInfo：列表接口只给概要）。</summary>
public sealed record BiliListItem
{
    public string Bvid { get; init; } = "";
    public long Aid { get; init; }
    public string Title { get; init; } = "";
    public string Cover { get; init; } = "";
    public int DurationSec { get; init; }
    public long PubDateUnix { get; init; }
}

/// <summary>一页列表结果。</summary>
public sealed record BiliListPage
{
    public IReadOnlyList<BiliListItem> Items { get; init; } = Array.Empty<BiliListItem>();
    /// <summary>是否还有下一页（用来决定「继续加载」按钮是否可点）。</summary>
    public bool HasMore { get; init; }
    public int Total { get; init; }
}

/// <summary>
/// B 站列表接口 —— 从 Flutter 版 lib/services/bili_list_api.dart（1200 行）移植。
///
/// 覆盖四类列表：
///   * 合集 season  —— /x/polymer/web-space/seasons_archives_list
///   * 系列 series  —— /x/series/archives + /x/series/series
///   * 收藏夹 fav   —— /x/v3/fav/resource/list
///   * UP 主投稿    —— /x/space/wbi/arc/search
///
/// 全部为公开接口，不需要登录；但收藏夹需要它是「公开收藏夹」，私密的要 cookie。
/// </summary>
/// <summary>按名称搜到的 UP 主。</summary>
public sealed record BiliUserHit
{
    public long Mid { get; init; }
    public string Name { get; init; } = "";
    public string Avatar { get; init; } = "";
    public long Fans { get; init; }
    public int Videos { get; init; }
    public string Sign { get; init; } = "";

    /// <summary>主页链接（用户可点）。</summary>
    public string SpaceUrl => "https://space.bilibili.com/" + Mid;
}

public sealed class BiliListApi
{
    private readonly BiliApi _api;

    public BiliListApi(BiliApi? api = null) => _api = api ?? new BiliApi();

    /// <summary>合集 / 系列 的稿件列表。两者用同一接口，只是参数不同。</summary>
    public async Task<BiliListPage> GetSeasonArchivesAsync(
        long mid, long seasonId, int pageNum = 1, int pageSize = 30, CancellationToken ct = default)
    {
        var path = $"/x/polymer/web-space/seasons_archives_list?mid={mid}" +
                   $"&season_id={seasonId}&sort_reverse=false&page_num={pageNum}&page_size={pageSize}";
        return await ParseArchivesAsync(path, ct);
    }

    public async Task<BiliListPage> GetSeriesArchivesAsync(
        long mid, long seriesId, int pageNum = 1, int pageSize = 30, CancellationToken ct = default)
    {
        var path = $"/x/series/archives?mid={mid}&series_id={seriesId}" +
                   $"&only_normal=true&sort=desc&pn={pageNum}&ps={pageSize}";
        return await ParseArchivesAsync(path, ct);
    }

    /// <summary>收藏夹内容。favId 是收藏夹 id（ml 号）。</summary>
    public async Task<BiliListPage> GetFavAsync(
        long favId, long mid = 0, int pageNum = 1, int pageSize = 20, CancellationToken ct = default)
    {
        var path = $"/x/v3/fav/resource/list?media_id={favId}&pn={pageNum}&ps={pageSize}" +
                   "&platform=web&keyword=&order=mtime&type=0&tid=0";
        // **这条接口必须不带 cookie 请求**（2026-10-29 决定性实测）：
        //
        // | 姿势 | 结果 |
        // |---|---|
        // | 不带 cookie | **200 成功** |
        // | 带 buvid3（程序自动取的） | **412 风控** |
        //
        // BiliApi 的 GetDataPublicAsync 会先 EnsureBuvidAsync 再带上 cookie，
        // 正好踩中风控。所以这里走 **匿名取数**（不带任何 cookie）。
        var data = await _api.GetDataAnonymousAsync(path, ct);

        var items = new List<BiliListItem>();
        if (data.TryGetProperty("medias", out var medias) && medias.ValueKind == JsonValueKind.Array)
        {
            foreach (var m in medias.EnumerateArray())
            {
                // 收藏夹会把「已失效视频」也列出来，标题是「已失效视频」，bvid 为空
                var bvid = m.TryGetProperty("bvid", out var b) ? b.GetString() ?? "" : "";
                if (string.IsNullOrEmpty(bvid)) continue;
                items.Add(new BiliListItem
                {
                    Bvid = bvid,
                    Aid = m.TryGetProperty("id", out var id) ? id.GetInt64() : 0,
                    Title = m.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "",
                    Cover = m.TryGetProperty("cover", out var c) ? c.GetString() ?? "" : "",
                    DurationSec = m.TryGetProperty("duration", out var d) ? d.GetInt32() : 0,
                    PubDateUnix = m.TryGetProperty("pubtime", out var p) ? p.GetInt64() : 0,
                });
            }
        }

        var hasMore = data.TryGetProperty("has_more", out var hm) && hm.ValueKind == JsonValueKind.True;
        var total = data.TryGetProperty("info", out var info) && info.TryGetProperty("media_count", out var mc)
            ? mc.GetInt32() : items.Count;

        return new BiliListPage { Items = items, HasMore = hasMore, Total = total };
    }

    /// <summary>
    /// **按 UP 主名称搜索**（用户 2026-10-29 要求「搜索影视飓风和极客湾」）。
    ///
    /// ### 为什么需要它
    /// 原来的 GetSpaceVideosAsync 只吃 mid（数字 UID），用户拿到的却是**名字**。
    /// 没有这一步，「按名字找 UP 主再下他的视频」这条最自然的用法根本走不通。
    ///
    /// ### 为什么走公开搜索接口
    /// B站 /x/web-interface/wbi/search/type 需要 WBI 签名。签名要 img_key/sub_key，
    /// 那两个 key 又要先请求 nav 接口 —— 链路长且易被风控。
    /// 这里先用公开路径试；被风控时调用方可以改走 BiliInPage 页内 fetch（浏览器自动带 Cookie）。
    /// 两条路都留着，是因为页内 fetch 需要 WebView 就绪，而批量页可能是纯接口路径。
    /// </summary>
    public async Task<List<BiliUserHit>> SearchUserAsync(
        string keyword, int limit = 10, CancellationToken ct = default)
    {
        var list = new List<BiliUserHit>();
        if (string.IsNullOrWhiteSpace(keyword)) return list;

        // **必须走签名接口**（2026-10-29 实测）：未签名时该接口返回 HTML 反爬页，
        // 不是 JSON —— 表现为「搜到 0 个结果」但也不报错。
        var path = "/x/web-interface/wbi/search/type";
        var pars = new Dictionary<string, string?>
        {
            ["search_type"] = "bili_user",
            ["keyword"] = keyword.Trim(),
            ["page"] = "1",
            ["page_size"] = Math.Clamp(limit, 1, 30).ToString(),
        };

        JsonElement data;
        try { data = await _api.GetSignedDataPublicAsync(path, pars, ct); }
        catch (Exception ex)
        {
            Aria2Engine.Log("[BiliListApi] 搜索「" + keyword + "」失败：" + ex.Message);
            return list;
        }

        if (!data.TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.Array)
            return list;

        foreach (var r in result.EnumerateArray())
        {
            var mid = r.TryGetProperty("mid", out var m) ? m.GetInt64() : 0;
            if (mid <= 0) continue;

            // 搜索接口的字段带 <em class="keyword"> 高亮标签，要去掉
            var name = StripTags(r.TryGetProperty("uname", out var u) ? u.GetString() ?? "" : "");
            var avatar = r.TryGetProperty("upic", out var a) ? (a.GetString() ?? "") : "";
            if (avatar.StartsWith("//")) avatar = "https:" + avatar;

            list.Add(new BiliUserHit
            {
                Mid = mid,
                Name = name,
                Avatar = avatar,
                Fans = r.TryGetProperty("fans", out var f) ? f.GetInt64() : 0,
                Videos = r.TryGetProperty("videos", out var v) ? v.GetInt32() : 0,
                Sign = StripTags(r.TryGetProperty("usign", out var s) ? s.GetString() ?? "" : ""),
            });

            if (list.Count >= limit) break;
        }
        return list;
    }

    /// <summary>去掉搜索结果里的高亮标签。</summary>
    private static string StripTags(string s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        return System.Text.RegularExpressions.Regex.Replace(s, "<[^>]+>", "");
    }

    /// <summary>UP 主投稿列表（第一页，按发布时间倒序）。</summary>
    public async Task<BiliListPage> GetSpaceVideosAsync(
        long mid, int pageNum = 1, int pageSize = 30, CancellationToken ct = default)
    {
        // **这条接口用未签名版**（2026-10-29 实测纠正）：
        // 之前我以为 arc/search 要签名，改成 GetSignedDataPublicAsync 后反而**全部 412**。
        // curl 对照实测：不带任何签名参数 → 200；带 dm_img 指纹 → 412。
        // 结论：这条接口**加了签名反而被拦**，保持未签名路径。
        var path = "/x/space/wbi/arc/search?mid=" + mid + "&ps=" + pageSize
                   + "&pn=" + pageNum + "&order=pubdate";
        var data = await _api.GetDataPublicAsync(path, ct);

        var items = new List<BiliListItem>();
        if (data.TryGetProperty("list", out var list) &&
            list.TryGetProperty("vlist", out var vlist) && vlist.ValueKind == JsonValueKind.Array)
        {
            foreach (var v in vlist.EnumerateArray())
            {
                items.Add(new BiliListItem
                {
                    Bvid = v.TryGetProperty("bvid", out var b) ? b.GetString() ?? "" : "",
                    Aid = v.TryGetProperty("aid", out var a) ? a.GetInt64() : 0,
                    Title = v.TryGetProperty("title", out var tt) ? tt.GetString() ?? "" : "",
                    Cover = v.TryGetProperty("pic", out var c) ? (c.GetString() ?? "").Replace("http://", "https://") : "",
                    DurationSec = ParseDuration(v),
                    PubDateUnix = v.TryGetProperty("created", out var cr) ? cr.GetInt64() : 0,
                });
            }
        }

        var total = 0;
        if (data.TryGetProperty("page", out var pg) && pg.TryGetProperty("count", out var cnt))
            total = cnt.GetInt32();

                Aria2Engine.Log("[BiliListApi] 投稿 mid=" + mid + " items=" + items.Count + " total=" + total + " 顶层字段=" + string.Join(",", data.EnumerateObject().Select(x => x.Name)));
        return new BiliListPage { Items = items, HasMore = items.Count >= pageSize, Total = total };
    }

    /// <summary>合集/系列的通用解析（两者响应结构相同）。</summary>
    private async Task<BiliListPage> ParseArchivesAsync(string path, CancellationToken ct)
    {
        var data = await _api.GetDataPublicAsync(path, ct);

        var items = new List<BiliListItem>();
        if (data.TryGetProperty("archives", out var arr) && arr.ValueKind == JsonValueKind.Array)
        {
            foreach (var a in arr.EnumerateArray())
            {
                items.Add(new BiliListItem
                {
                    Bvid = a.TryGetProperty("bvid", out var b) ? b.GetString() ?? "" : "",
                    Aid = a.TryGetProperty("aid", out var aid) ? aid.GetInt64() : 0,
                    Title = a.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "",
                    Cover = a.TryGetProperty("pic", out var c) ? c.GetString() ?? "" : "",
                    DurationSec = a.TryGetProperty("duration", out var d) ? d.GetInt32() : 0,
                    PubDateUnix = a.TryGetProperty("pubdate", out var p) ? p.GetInt64() : 0,
                });
            }
        }

        var hasMore = false;
        if (data.TryGetProperty("page", out var pg))
        {
            var num = pg.TryGetProperty("page_num", out var pn) ? pn.GetInt32() : 1;
            var size = pg.TryGetProperty("page_size", out var ps) ? ps.GetInt32() : 30;
            var total = pg.TryGetProperty("total", out var tt) ? tt.GetInt32() : items.Count;
            hasMore = num * size < total;
        }

        // total 可能是数字也可能是字符串，两种都认
        var totalVal = items.Count;
        if (data.TryGetProperty("page", out var pg2) && pg2.TryGetProperty("total", out var t2))
        {
            totalVal = t2.ValueKind == JsonValueKind.Number
                ? t2.GetInt32()
                : (int.TryParse(t2.GetString(), out var tv) ? tv : items.Count);
        }
        return new BiliListPage { Items = items, HasMore = hasMore, Total = totalVal };
    }

    /// <summary>UP 主列表里的时长是 "12:34" 字符串，要转秒。</summary>
    private static int ParseDuration(JsonElement e)
    {
        if (!e.TryGetProperty("length", out var len)) return 0;
        var s = len.GetString() ?? "";
        var parts = s.Split((char)58);
        var total = 0;
        foreach (var p in parts)
        {
            if (int.TryParse(p, out var v)) total = total * 60 + v;
        }
        return total;
    }
}