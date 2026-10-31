using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading.Tasks;

namespace ParseDl.Services.Douyin;

/// <summary>
/// **按作品 ID 现取下载地址**（2026-10-31 加）。
///
/// ### 为什么需要
/// 抖音直链带时效签名（路径里那段 8 位 hex 就是过期时间），几小时就 403。
/// 实测：签名 05:34 过期，11:46 恢复队列提交时 2000 条全部报废。
/// 所以「把 URL 存起来回头再下」这条路根本走不通 —— 必须**存 ID、用时现取**。
///
/// ### 怎么取
/// 在**抖音页面的上下文里**执行 `fetch`，调 `/aweme/v1/web/aweme/detail/`。
/// 走页面上下文而不是自己发 HTTP，是因为这个接口要整套登录态与签名参数
/// （cookie / msToken / a_bogus 之类），自己拼几乎必失败；而页面里 fetch
/// 天然带着当前会话的全部凭据。拦截器（DouyinInterceptor）本来就是靠读
/// 这个接口的响应拿数据的，说明路径与参数都成立。
///
/// 拿到的 JSON 结构与拦截器一致，直接复用 <see cref="DouyinParser"/> 解析。
/// </summary>
public static class DouyinAddressResolver
{
    /// <summary>单个作品的取址结果。</summary>
    public sealed record Resolved(bool Ok, string Url, string Message);

    /// <summary>
    /// 作品 ID → 作品页链接。
    ///
    /// **单一出处**：<see cref="DouyinRefetchHost"/> 的导航与给用户看的
    /// 「手动去下」链接都必须用这个，避免两处各拼一遍导致不一致。
    /// </summary>
    public static string PageUrlFor(string awemeId)
        => "https://www.douyin.com/video/" + (awemeId ?? "");

    /// <summary>
    /// 把「媒体序号」夹到列表下标。
    ///
    /// 约定：<paramref name="mediaIndex"/> 从 **1** 开始（与 %MEDIA_INDEX% 一致），
    /// 0 表示未记录 → 取第一条；越界也回落到第一条（宁可供错不可供空）。
    /// </summary>
    public static int ClampIndex(int mediaIndex, int count)
    {
        if (count <= 0) return 0;
        var idx = mediaIndex <= 0 ? 0 : mediaIndex - 1;
        return idx >= count ? 0 : idx;
    }

    /// <summary>
    /// 页面内 fetch 的脚本。返回 JSON.stringify 后的结果。
    /// 失败时返回 {"ok":false,"msg":"..."}，不抛异常（ExecuteScriptAsync 里抛了外面看不到）。
    /// </summary>
    public static string ScriptFor(string awemeId) => """
(function () {
  var id = 'AWEME_ID';
  var url = '/aweme/v1/web/aweme/detail/?aweme_id=' + id
          + '&device_platform=webapp&aid=6383&channel=channel_pc_web'
          + '&pc_client_type=1&version_code=170400&version_name=17.4.0'
          + '&cookie_enabled=true&platform=PC&downlink=10';
  return fetch(url, { credentials: 'include' })
    .then(function (r) {
      if (!r.ok) { return JSON.stringify({ ok: false, msg: 'HTTP ' + r.status }); }
      return r.text().then(function (t) {
        // 直接把原始 JSON 交回 C# 解析（避免在 JS 里再挑字段，两边容易不一致）
        return JSON.stringify({ ok: true, body: t });
      });
    })
    .catch(function (e) {
      return JSON.stringify({ ok: false, msg: String(e && e.message || e) });
    });
})()
""".Replace("AWEME_ID", awemeId);

    /// <summary>
    /// 从 detail 接口的原始响应里抽第 <paramref name="mediaIndex"/> 条媒体的地址。
    /// </summary>
    /// <remarks>
    /// 结构：`{ "aweme_detail": { "video": { "play_addr": { "url_list": [...] } },
    ///                             "images": [ { "url_list": [...] }, ... ] } }`
    /// 视频与图文的媒体集合不同，这里统一转成 <see cref="DouyinItem"/> 列表后按序号取。
    /// </remarks>
    public static Resolved PickFromDetail(string rawBody, int mediaIndex)
    {
        if (string.IsNullOrWhiteSpace(rawBody))
            return new Resolved(false, "", "detail 接口返回空");

        try
        {
            using var doc = JsonDocument.Parse(rawBody);
            var root = doc.RootElement;

            // 限流/风控时接口会回 status_code != 0 且没有 aweme_detail
            if (root.TryGetProperty("status_code", out var sc) &&
                sc.ValueKind == JsonValueKind.Number && sc.GetInt32() != 0)
                return new Resolved(false, "",
                    "detail 接口返回 status_code=" + sc.GetInt32() + "（多为未登录或被风控）");

            if (!root.TryGetProperty("aweme_detail", out var detail) ||
                detail.ValueKind != JsonValueKind.Object)
                return new Resolved(false, "", "响应里没有 aweme_detail（作品可能已删或需登录）");

            // ParseAweme 返回**一条作品**（媒体在 .Media 里），不是媒体数组
            var aweme = DouyinParser.ParseAweme(detail);
            if (aweme is null || aweme.Media.Count == 0)
                return new Resolved(false, "", "该作品没有可下载的媒体");

            var idx = ClampIndex(mediaIndex, aweme.Media.Count);

            var url = aweme.Media[idx].Url;
            if (string.IsNullOrEmpty(url))
                return new Resolved(false, "", "解析出的地址为空");
            return new Resolved(true, url, "");
        }
        catch (Exception ex)
        {
            return new Resolved(false, "", "解析 detail 响应失败：" + ex.Message);
        }
    }

    /// <summary>
    /// 让调用方注入「执行页面脚本」的实现（页面持有 WebView2，服务层拿不到）。
    /// 返回脚本的原始返回值；页面未就绪时返回 null。
    ///
    /// **2026-11-01 起这条路径不再是主路**：脚本里只有 aweme_id 与静态参数、
    /// 没有 a_bogus 签名，实测裸调该接口 403。真正生效的是下面的
    /// <see cref="ResolveViaPageAsync"/>（打开作品页、让页面自己发请求）。
    /// 保留它是因为解析页/自动下载页本来就跑着抖音页面，走它更省事；
    /// 但它失败时调用方应回落到页面导航那条路。
    /// </summary>
    public static Func<string, Task<string?>>? Executor { get; set; }

    /// <summary>
    /// **统一取址入口**（2026-11-01）—— 按作品 ID 现取一条新鲜直链。
    ///
    /// 顺序：
    ///   ① 若调用方注入过 <see cref="Executor"/>（解析页/自动下载页正跑着抖音页面），
    ///      先试「页面内 fetch 接口」那条 —— 省一次导航；
    ///   ② 失败或没注入，回落到 <see cref="DouyinRefetchHost.RefetchAsync"/>：
    ///      用隐藏 WebView 打开作品页，让页面自己带签名请求，拦截器抄响应。
    ///
    /// 为什么要回落：① 那条脚本**没有 a_bogus 签名**，实测裸调 403，
    /// 历史上从未成功过（日志里一条「已按作品 ID 现取新地址」都没有）；
    /// ② 那条路依赖某个页面实例活着，用户切页/没打开抖音页时就没有上下文。
    /// </summary>
    public static async Task<Resolved> ResolveAnyAsync(string awemeId, int mediaIndex)
    {
        if (string.IsNullOrWhiteSpace(awemeId))
            return new Resolved(false, "", "没有作品 ID，无法重新取地址");

        if (Executor is not null)
        {
            var viaApi = await ResolveAsync(awemeId, mediaIndex);
            if (viaApi.Ok) return viaApi;
            Aria2Engine.Log("[取址] 接口路径失败（" + viaApi.Message + "），改用打开作品页取址");
        }

        return await DouyinRefetchHost.RefetchAsync(awemeId, mediaIndex);
    }

    /// <summary>按作品 ID 现取一条新鲜地址（页面内 fetch 接口版）。失败返回 Ok=false + 原因。</summary>
    public static async Task<Resolved> ResolveAsync(string awemeId, int mediaIndex)
    {
        if (string.IsNullOrWhiteSpace(awemeId))
            return new Resolved(false, "", "没有作品 ID，无法重新取地址");
        var exec = Executor;
        if (exec is null)
            return new Resolved(false, "", "没有可用的页面上下文（内嵌浏览器未就绪）");

        string? raw;
        try { raw = await exec(ScriptFor(awemeId)); }
        catch (Exception ex) { return new Resolved(false, "", "执行取址脚本失败：" + ex.Message); }
        if (string.IsNullOrEmpty(raw))
            return new Resolved(false, "", "取址脚本没有返回内容");

        // ExecuteScriptAsync 的返回值是 JSON 编码过的字符串（外层带引号），先解一层
        var text = DouyinAutoScrollReport.UnquoteJsonString(raw);
        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            if (!root.TryGetProperty("ok", out var okEl) || okEl.ValueKind != JsonValueKind.True)
            {
                var msg = root.TryGetProperty("msg", out var m) ? m.GetString() : "未知错误";
                return new Resolved(false, "", "取址失败：" + msg);
            }
            var body = root.TryGetProperty("body", out var b) ? b.GetString() ?? "" : "";
            return PickFromDetail(body, mediaIndex);
        }
        catch (Exception ex)
        {
            return new Resolved(false, "", "取址返回值解析失败：" + ex.Message);
        }
    }
}
