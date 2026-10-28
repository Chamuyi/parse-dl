using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.Bili;

/// <summary>视频基本信息。</summary>
public sealed record BiliVideoInfo
{
    public string Bvid { get; init; } = "";
    public long Aid { get; init; }
    public string Title { get; init; } = "";
    public string Desc { get; init; } = "";
    public string Cover { get; init; } = "";
    public long PubDateUnix { get; init; }
    public long OwnerMid { get; init; }
    public string OwnerName { get; init; } = "";
    public int DurationSec { get; init; }
    /// <summary>分 P 列表（单 P 视频只有一项）。</summary>
    public IReadOnlyList<BiliPart> Pages { get; init; } = Array.Empty<BiliPart>();
    /// <summary>
    /// view 接口 data 节点的**原样 JSON**。
    /// 给元数据那一族用（json 档要的就是「原样存一份」，不做过滤与排序）。
    /// </summary>
    public string RawJson { get; init; } = "";

    // ── 统计量（抓取结果列表的第三行要用）──────────────────
    public long ViewCount { get; init; }
    public long LikeCount { get; init; }
    public long CoinCount { get; init; }
    public long FavCount { get; init; }
    public long ShareCount { get; init; }
    public long ReplyCount { get; init; }
    public long DanmakuCount { get; init; }
    /// <summary>分区名（如「游戏」），做「话题」那一行的兜底。</summary>
    public string Tname { get; init; } = "";
    /// <summary>稿件标签（view 接口不回，nfo 那一族另外取；这里留空）。</summary>
    public IReadOnlyList<string> Tags { get; init; } = Array.Empty<string>();
}

public sealed record BiliPart
{
    public int Page { get; init; }
    public string Title { get; init; } = "";
    public int DurationSec { get; init; }
    public string? Cid { get; init; }
}

/// <summary>一条可下载的媒体流（视频或音频）。</summary>
public sealed record BiliStream
{
    public string Url { get; init; } = "";
    /// <summary>清晰度 id（127/120/80/64…）或音频 id（30280…）。</summary>
    public int QualityId { get; init; }
    public string QualityLabel { get; init; } = "";
    /// <summary>编码：AVC / HEVC / AV1，认不出为空。</summary>
    public string Codec { get; init; } = "";
    public long SizeBytes { get; init; }
    /// <summary>dash 的 bandwidth（bps）。音频档位靠它排序 —— 不能按 id 排。</summary>
    public long Bitrate { get; init; }
    public bool IsAudio { get; init; }
}

/// <summary>一次解析拿到的全部可下载内容。</summary>
public sealed record BiliPlayInfo
{
    public long Cid { get; init; }
    /// <summary>true = 新接口 dash（视频音频分离）；false = 老接口 durl（完整单文件）。</summary>
    public bool IsDash { get; init; }
    public IReadOnlyList<BiliStream> Videos { get; init; } = Array.Empty<BiliStream>();
    public IReadOnlyList<BiliStream> Audios { get; init; } = Array.Empty<BiliStream>();
}

/// <summary>B 站接口异常 —— 带可读原因，不要用裸 Exception。</summary>
public sealed class BiliApiException : Exception
{
    public int Code { get; }
    public BiliApiException(string message, int code = -1) : base(message) { Code = code; }
}

/// <summary>
/// B 站 API —— 从 Flutter 版 lib/services/bili_api.dart（1529 行）移植核心部分。
///
/// 设计要点（照搬 Flutter 版的踩坑结论）：
/// 1. **必须带 Referer 与 Origin**：B 站对不带来源的请求返回 -403。
/// 2. **重试次数少**：B 站风控是「越重试越坐实」，拿不到就尽早把原因交出去，
///    而不是把一次网络抖动拖成几十秒。
/// 3. **音频档位不能按 id 排序**：30216 的 id 比 30280 小却更差，只能按固定序。
/// 4. **wbi 签名**：部分接口（playurl / view）要求 wbi 签名，未签名会被风控。
///    这里实现签名算法；拿不到密钥时退回未签名请求并如实标注。
/// </summary>
public sealed class BiliApi
{
    public const string Host = "api.bilibili.com";
    public const string Referer = "https://www.bilibili.com/";
    public const string Origin = "https://www.bilibili.com";

    /// <summary>统一 UA —— 图床与接口都认它，抽出来免得两处漂。</summary>
    public const string UserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";

    /// <summary>画质 id → 标签。只在接口没给文案时兜底。</summary>
    public static readonly IReadOnlyDictionary<int, string> QualityNames = new Dictionary<int, string>
    {
        [127] = "8K", [126] = "杜比视界", [125] = "HDR真彩", [120] = "4K",
        [116] = "1080P60", [112] = "1080P+", [100] = "AI修复", [80] = "1080P",
        [74] = "720P60", [64] = "720P", [32] = "480P", [16] = "360P",
    };

    public static readonly IReadOnlyDictionary<int, string> AudioNames = new Dictionary<int, string>
    {
        [30255] = "杜比全景声", [30251] = "Hi-Res", [30250] = "杜比",
        [30280] = "192K", [30232] = "132K", [30216] = "64K",
    };

    /// <summary>音频档位由高到低。**不能按 id 排** —— 30216 的 id 更小却更差。</summary>
    public static readonly int[] AudioRank = { 30255, 30251, 30250, 30280, 30232, 30216 };

    private readonly HttpClient _http;
    private string _cookie;

    /// <summary>
    /// buvid3 是 B 站的设备指纹 cookie。**没有它，部分接口（尤其登录相关）
    /// 会直接返回 HTML 风控页而不是 JSON** —— 表现为 JsonDocument.Parse 报
    /// "'<' is an invalid start of a value"（实测踩过）。
    /// </summary>
    private string _buvid3 = "";
    private bool _buvidTried;

    public BiliApi(string? cookie = null, HttpClient? http = null)
    {
        _cookie = cookie ?? "";
        _http = http ?? BuildHttp();
    }

    /// <summary>
    /// 建 HttpClient，**带上设置里的代理**（2026-10-29 修）。
    ///
    /// .NET 的 HttpClient 默认**不会**读系统代理（curl 会），
    /// 所以同样的请求 curl 走代理能过、程序直连被 B 站 412 风控拦。
    /// 这里按设置的三态（关闭 / 系统 / 自定义）与 Aria2Engine 同一套口径解析。
    /// </summary>
    private static HttpClient BuildHttp()
    {
        var handler = new HttpClientHandler();
        var h = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
        try
        {
            var cfg = AppSettings.Instance;
            if (cfg.ProxyEnable)
            {
                string? addr = null;
                if (cfg.ProxyUseSystem)
                {
                    // 读 IE/系统代理
                    try
                    {
                        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                            @"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
                        if (key?.GetValue("ProxyEnable") is int on && on == 1)
                            addr = key.GetValue("ProxyServer") as string;
                    }
                    catch { }
                }
                else addr = cfg.ProxyUrl;

                if (!string.IsNullOrWhiteSpace(addr))
                {
                    // ProxyServer 可能是 "http=host:port;https=host:port" 形式
                    var first = addr;
                    if (first.Contains((char)59))
                    {
                        var httpPart = first.Split((char)59)
                            .FirstOrDefault(s => s.StartsWith("http=", StringComparison.OrdinalIgnoreCase));
                        if (httpPart is not null) first = httpPart[5..];
                    }
                    if (!first.Contains("://")) first = "http://" + first;
                    handler.Proxy = new System.Net.WebProxy(first);
                    handler.UseProxy = true;
                }
            }
        }
        catch { }
        return h;
    }

    /// <summary>取 buvid3 设备指纹（一次即可，之后复用）。失败不抛 —— 尽力而为。</summary>
    private async Task EnsureBuvidAsync(CancellationToken ct)
    {
        if (_buvidTried) return;
        _buvidTried = true;
        try
        {
            using var req = NewRequest("https://" + Host + "/x/frontend/finger/spi");
            using var resp = await _http.SendAsync(req, ct);
            var text = await resp.Content.ReadAsStringAsync(ct);
            using var doc = JsonDocument.Parse(text);
            if (doc.RootElement.TryGetProperty("data", out var data))
            {
                if (data.TryGetProperty("b_3", out var b3)) _buvid3 = b3.GetString() ?? "";
                else if (data.TryGetProperty("buvid3", out var b3b)) _buvid3 = b3b.GetString() ?? "";
            }
        }
        catch
        {
            // 拿不到就继续 —— 不阻断主流程
        }
    }

    /// <summary>把 buvid3 并进 Cookie 头（已有的 cookie 保留）。</summary>
    private string EffectiveCookie()
    {
        if (string.IsNullOrEmpty(_buvid3)) return _cookie;
        if (_cookie.Contains("buvid3=")) return _cookie;
        return _cookie.Length == 0 ? ("buvid3=" + _buvid3) : (_cookie + "; buvid3=" + _buvid3);
    }

    private HttpRequestMessage NewRequest(string url)
    {
        var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.TryAddWithoutValidation("Referer", Referer);
        req.Headers.TryAddWithoutValidation("Origin", Origin);
        req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        var cookie = EffectiveCookie();
        if (cookie.Length > 0) req.Headers.TryAddWithoutValidation("Cookie", cookie);
        return req;
    }

    /// <summary>发一次请求并取出 JSON 的 data 节点。失败重试 3 次（共 4 次尝试）。</summary>
    private async Task<JsonElement> GetDataAsync(string path, CancellationToken ct = default)
    {
        await EnsureBuvidAsync(ct);
        var url = path.StartsWith("http") ? path : "https://" + Host + path;
        Exception? last = null;
        for (var attempt = 0; attempt < 4; attempt++)
        {
            try
            {
                using var req = NewRequest(url);
                using var resp = await _http.SendAsync(req, ct);
                var text = await resp.Content.ReadAsStringAsync(ct);

                // 风控/错误时 B 站会返回 HTML 页面，直接 Parse 会报
                // "'<' is an invalid start of a value"，那个报错对用户毫无意义。
                // 这里先判形状，给出可读原因。
                var trimmed = text.TrimStart();
                if (trimmed.Length > 0 && (trimmed[0] == (char)60 || trimmed[0] == (char)91))
                {
                    var isArray = trimmed[0] == (char)91;
                    if (!isArray)
                    {
                        var status = (int)resp.StatusCode;
                        throw new BiliApiException(
                            "B 站返回了 HTML 而不是 JSON（HTTP " + status + "）。" +
                            "通常是触发了风控，稍后再试；若持续出现，检查网络或换网络环境。");
                    }
                }

                using var doc = JsonDocument.Parse(text);
                var root = doc.RootElement;
                if (root.TryGetProperty("code", out var codeEl))
                {
                    var code = codeEl.GetInt32();
                    if (code != 0)
                    {
                        var msg = root.TryGetProperty("message", out var m) ? m.GetString() ?? "" : "";
                        throw new BiliApiException($"B 站返回错误 {code}：{msg}", code);
                    }
                }
                if (root.TryGetProperty("data", out var data)) return data.Clone();
                if (root.TryGetProperty("result", out var result)) return result.Clone();
                return root.Clone();
            }
            catch (BiliApiException)
            {
                // 业务错误不重试 —— 重试只会加重风控
                throw;
            }
            catch (Exception ex)
            {
                last = ex;
                if (attempt < 3) await Task.Delay(600 * (attempt + 1), ct);
            }
        }
        throw new BiliApiException($"请求失败（已重试 4 次）：{last?.Message}");
    }

    /// <summary>取二进制响应（弹幕 seg.so 返回 protobuf，不是 JSON）。</summary>
    public async Task<byte[]> GetBytesAsync(string path, CancellationToken ct = default)
    {
        await EnsureBuvidAsync(ct);
        var url = path.StartsWith("http") ? path : "https://" + Host + path;
        using var req = NewRequest(url);
        using var resp = await _http.SendAsync(req, ct);
        if (!resp.IsSuccessStatusCode)
        {
            var status = (int)resp.StatusCode;
            throw new BiliApiException("请求失败（HTTP " + status + "）：" + path);
        }
        return await resp.Content.ReadAsByteArrayAsync(ct);
    }

    /// <summary>取二进制响应，**走 wbi 签名**（弹幕 seg.so 在新版接口下需要签名）。</summary>
    public async Task<byte[]> GetSignedBytesAsync(
        string path, IDictionary<string, string?> parameters, CancellationToken ct = default)
    {
        var key = await EnsureMixinKeyAsync(ct);
        var kv = new Dictionary<string, string?>(parameters, StringComparer.Ordinal);
        var signed = BiliWbi.Sign(kv, key);
        var query = BiliWbi.Query(signed);
        return await GetBytesAsync(path + (path.Contains((char)63) ? "&" : "?") + query, ct);
    }

    /// <summary>
    /// **匿名取数**（不带任何 cookie）。
    ///
    /// 为什么需要单独一个入口：B 站的风控是「带 buvid3 反而更容易被拦」——
    /// 实测同一条 arc/search 请求，不带 cookie 返回 200，带 buvid3 返回 412。
    /// 这类接口就该裸着问。
    /// </summary>
    public async Task<JsonElement> GetDataAnonymousAsync(string path, CancellationToken ct = default)
    {
        var url = path.StartsWith("http") ? path : "https://" + Host + path;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                req.Headers.TryAddWithoutValidation("Referer", Referer);
                req.Headers.TryAddWithoutValidation("Origin", Origin);
                req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
                // **刻意不设 Cookie**
                using var resp = await _http.SendAsync(req, ct);
                var text = await resp.Content.ReadAsStringAsync(ct);
                // **412 要重试，不能直接放弃**（2026-10-29 实测）：
                // B 站对 arc/search 是按请求轮换风控的 —— 连续三次实测
                // 「第1次 200 / 第2次 412 / 第3次 200」。所以重试一次往往就过。
                if (text.TrimStart().StartsWith("<"))
                {
                    if (attempt < 2)
                    {
                        await Task.Delay(600 * (attempt + 1), ct);
                        continue;
                    }
                    throw new BiliApiException("B 站返回了 HTML 而不是 JSON（HTTP " + (int)resp.StatusCode
                        + "）。已重试 " + (attempt + 1) + " 次仍被风控，稍后再试。");
                }
                using var doc = JsonDocument.Parse(text);
                var root = doc.RootElement.Clone();
                if (root.TryGetProperty("code", out var code) && code.GetInt32() != 0)
                {
                    var c = code.GetInt32();
                    // -352 = 风控校验失败，-412 同理：都属于「下一次可能就过」，重试
                    if ((c == -352 || c == -412) && attempt < 2)
                    {
                        await Task.Delay(600 * (attempt + 1), ct);
                        continue;
                    }
                    throw new BiliApiException("B 站返回错误 " + c + "："
                        + (root.TryGetProperty("message", out var m) ? m.GetString() : ""));
                }
                return root.TryGetProperty("data", out var d) ? d.Clone() : root;
            }
            catch (BiliApiException) { throw; }
            catch when (attempt < 2) { await Task.Delay(300 * (attempt + 1), ct); }
        }
        throw new BiliApiException("匿名取数失败：" + url);
    }

    /// <summary>给列表接口用的公开取数入口（复用同一套请求头与重试策略）。</summary>
    public Task<JsonElement> GetDataPublicAsync(string path, CancellationToken ct = default)
        => GetDataAsync(path, ct);

    /// <summary>给列表 / 弹幕 / 字幕用的**已签名**取数入口。</summary>
    public Task<JsonElement> GetSignedDataPublicAsync(
        string path, IDictionary<string, string?> parameters, CancellationToken ct = default)
        => GetSignedDataAsync(path, parameters, ct);

    // ── wbi 签名 ─────────────────────────────────────────────

    private string _mixinKey = "";
    private DateTime _mixinKeyAt = DateTime.MinValue;
    private readonly SemaphoreSlim _wbiLock = new(1, 1);

    /// <summary>密钥按天轮换，缓存 6 小时足够；并发首次请求只取一次。</summary>
    private async Task<string> EnsureMixinKeyAsync(CancellationToken ct)
    {
        if (_mixinKey.Length == BiliWbi.MixinKeyLength &&
            (DateTime.UtcNow - _mixinKeyAt).TotalHours < 6)
            return _mixinKey;

        await _wbiLock.WaitAsync(ct);
        try
        {
            if (_mixinKey.Length == BiliWbi.MixinKeyLength &&
                (DateTime.UtcNow - _mixinKeyAt).TotalHours < 6)
                return _mixinKey;

            // nav 未登录时也回 wbi_img（这正是匿名也能签名的原因）。
            // **不能用 GetDataAsync**：未登录时 nav 的 code 是 -101，
            // 那个方法会当成业务错误直接抛，而我们要的只是 data.wbi_img。
            var root = await GetRawAsync("https://" + Host + "/x/web-interface/nav", ct);
            var imgUrl = "";
            var subUrl = "";
            if (root.TryGetProperty("data", out var data) &&
                data.TryGetProperty("wbi_img", out var wbi))
            {
                if (wbi.TryGetProperty("img_url", out var iu)) imgUrl = iu.GetString() ?? "";
                if (wbi.TryGetProperty("sub_url", out var su)) subUrl = su.GetString() ?? "";
            }
            if (imgUrl.Length == 0 || subUrl.Length == 0)
                throw new BiliApiException("取 wbi 签名密钥失败：nav 响应里没有 wbi_img（img_url/sub_url）");

            _mixinKey = BiliWbi.MixinKey(BiliWbi.KeyFromUrl(imgUrl), BiliWbi.KeyFromUrl(subUrl));
            _mixinKeyAt = DateTime.UtcNow;
            return _mixinKey;
        }
        finally
        {
            _wbiLock.Release();
        }
    }

    /// <summary>发一次原始请求，取回完整响应体（**不检查 code**）—— 只给 nav 这类「非 0 也有数据」的接口用。</summary>
    private async Task<JsonElement> GetRawAsync(string url, CancellationToken ct)
    {
        await EnsureBuvidAsync(ct);
        using var req = NewRequest(url);
        using var resp = await _http.SendAsync(req, ct);
        var text = await resp.Content.ReadAsStringAsync(ct);
        var trimmed = text.TrimStart();
        if (trimmed.Length == 0 || trimmed[0] == (char)60)
            throw new BiliApiException("B 站返回了 HTML 而不是 JSON（HTTP " + (int)resp.StatusCode + "），通常是触发风控。");
        using var doc = JsonDocument.Parse(text);
        return doc.RootElement.Clone();
    }

    /// <summary>
    /// 走 wbi 签名的取数（playurl / view / space arc / 弹幕 / 字幕都用它）。
    ///
    /// **签名用过滤后的值拼 query，发出的请求必须用同一串字节**，否则服务端重算出的
    /// w_rid 对不上 —— 所以这里把 BiliWbi.Sign 的结果直接喂给 BiliWbi.Query。
    /// </summary>
    public async Task<JsonElement> GetSignedDataAsync(
        string path, IDictionary<string, string?> parameters, CancellationToken ct = default)
    {
        var key = await EnsureMixinKeyAsync(ct);
        var kv = new Dictionary<string, string?>(parameters, StringComparer.Ordinal);
        var signed = BiliWbi.Sign(kv, key);
        var query = BiliWbi.Query(signed);
        var url = path + (path.Contains((char)63) ? "&" : "?") + query;
        return await GetDataAsync(url, ct);
    }

    /// <summary>取视频基本信息（含分 P 列表）。bvid 与 aid 传其一即可（av 号路径靠 aid）。</summary>
    public async Task<BiliVideoInfo> GetVideoInfoAsync(
        string? bvid = null, long? aid = null, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(bvid) && aid is null)
            throw new ArgumentException("bvid 与 aid 至少要有一个", nameof(bvid));

        var requestBvid = bvid;
        var data = await GetDataAsync(
            "/x/web-interface/view?" + (string.IsNullOrWhiteSpace(requestBvid)
                ? ("aid=" + aid)
                : ("bvid=" + Uri.EscapeDataString(requestBvid!) + (aid is null ? "" : ("&aid=" + aid)))), ct);
        if (string.IsNullOrWhiteSpace(requestBvid) && data.TryGetProperty("bvid", out var bv))
            requestBvid = bv.GetString() ?? "";

        var pages = new List<BiliPart>();
        if (data.TryGetProperty("pages", out var pageArr) && pageArr.ValueKind == JsonValueKind.Array)
        {
            foreach (var p in pageArr.EnumerateArray())
            {
                pages.Add(new BiliPart
                {
                    Page = p.TryGetProperty("page", out var pn) ? pn.GetInt32() : 0,
                    Title = p.TryGetProperty("part", out var pt) ? pt.GetString() ?? "" : "",
                    DurationSec = p.TryGetProperty("duration", out var pd) ? pd.GetInt32() : 0,
                    Cid = p.TryGetProperty("cid", out var pc) ? pc.ToString() : null,
                });
            }
        }

        return new BiliVideoInfo
        {
            Bvid = data.TryGetProperty("bvid", out var b) ? b.GetString() ?? (requestBvid ?? "") : (requestBvid ?? ""),
            Aid = data.TryGetProperty("aid", out var a) ? a.GetInt64() : 0,
            Title = data.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "",
            Desc = data.TryGetProperty("desc", out var d) ? d.GetString() ?? "" : "",
            Cover = data.TryGetProperty("pic", out var pic) ? pic.GetString() ?? "" : "",
            PubDateUnix = data.TryGetProperty("pubdate", out var pd2) ? pd2.GetInt64() : 0,
            DurationSec = data.TryGetProperty("duration", out var dur) ? dur.GetInt32() : 0,
            OwnerMid = data.TryGetProperty("owner", out var owner) && owner.TryGetProperty("mid", out var om)
                ? om.GetInt64() : 0,
            OwnerName = data.TryGetProperty("owner", out var owner2) && owner2.TryGetProperty("name", out var on)
                ? on.GetString() ?? "" : "",
            Pages = pages,
            RawJson = data.GetRawText(),
            ViewCount = StatOf(data, "view"),
            LikeCount = StatOf(data, "like"),
            CoinCount = StatOf(data, "coin"),
            FavCount = StatOf(data, "favorite"),
            ShareCount = StatOf(data, "share"),
            ReplyCount = StatOf(data, "reply"),
            DanmakuCount = StatOf(data, "danmaku"),
            Tname = data.TryGetProperty("tname", out var tn) ? tn.GetString() ?? "" : "",
        };
    }

    /// <summary>
    /// 取播放地址（视频 + 音频分离，需自行合并）。
    ///
    /// [qn] 是**上限**而不是档位：B 站会按账号权限在 support_formats 里裁掉拿不到的
    /// 高阶档，所以「传 116 只给到 80」是正常结果；匿名时通常只给到 32（480P）。
    ///
    /// **必须走 wbi 签名**（原实现直接拼裸 query 是 bug 之一）：未签名的
    /// /x/player/wbi/playurl 会被风控，表现为 code=-403 或空响应。
    /// </summary>
    public async Task<BiliPlayInfo> GetPlayInfoAsync(
        string? bvid, long cid, int qn = 127, long? aid = null, CancellationToken ct = default)
    {
        if (cid <= 0) throw new ArgumentException("cid 非法", nameof(cid));
        if (string.IsNullOrWhiteSpace(bvid) && aid is null)
            throw new ArgumentException("bvid 与 aid 至少要有一个", nameof(bvid));

        var data = await GetSignedDataAsync("/x/player/wbi/playurl", new Dictionary<string, string?>
        {
            ["bvid"] = bvid,
            ["aid"] = aid?.ToString(),
            ["cid"] = cid.ToString(),
            ["qn"] = qn.ToString(),
            ["fnval"] = "4048",   // 4048 = dash + 全部特性（原实现用的 16 拿不到 HDR/杜比档）
            ["fnver"] = "0",
            ["fourk"] = "1",
        }, ct);

        // support_formats 里那一份才是 B 站自己怎么说这一档的，优先用它
        var labels = QualityLabelsByQn(data);

        var videos = new List<BiliStream>();
        var audios = new List<BiliStream>();
        var isDash = false;

        // 新接口：dash（视频音频分离，质量更高）
        if (data.TryGetProperty("dash", out var dash) && dash.ValueKind == JsonValueKind.Object)
        {
            isDash = true;
            if (dash.TryGetProperty("video", out var vArr) && vArr.ValueKind == JsonValueKind.Array)
            {
                foreach (var v in vArr.EnumerateArray())
                {
                    var qid = v.TryGetProperty("id", out var vid) ? vid.GetInt32() : 0;
                    videos.Add(new BiliStream
                    {
                        Url = PickBaseUrl(v),
                        QualityId = qid,
                        QualityLabel = labels.TryGetValue(qid, out var ql) && ql.Length > 0
                            ? ql
                            : (QualityNames.TryGetValue(qid, out var ql2) ? ql2 : ("Q" + qid)),
                        Codec = CodecFromCodecs(v),
                        SizeBytes = v.TryGetProperty("size", out var sz2) ? sz2.GetInt64() : 0,
                        Bitrate = v.TryGetProperty("bandwidth", out var bw) ? bw.GetInt64() : 0,
                    });
                }
            }
            if (dash.TryGetProperty("audio", out var aArr) && aArr.ValueKind == JsonValueKind.Array)
            {
                foreach (var a in aArr.EnumerateArray())
                {
                    var qid = a.TryGetProperty("id", out var aidEl) ? aidEl.GetInt32() : 0;
                    audios.Add(new BiliStream
                    {
                        Url = PickBaseUrl(a),
                        QualityId = qid,
                        QualityLabel = AudioNames.TryGetValue(qid, out var al) ? al : ("A" + qid),
                        SizeBytes = a.TryGetProperty("size", out var sz3) ? sz3.GetInt64() : 0,
                        Bitrate = a.TryGetProperty("bandwidth", out var abw) ? abw.GetInt64() : 0,
                        IsAudio = true,
                    });
                }
            }
        }

        // 老接口：durl（整段 flv/mp4，无分离音轨）—— 只在没有 dash 时才算数，
        // 两者同时存在时以 dash 为准（durl 那几条是低清兜底，混进来会污染选流）。
        if (!isDash && data.TryGetProperty("durl", out var durl) && durl.ValueKind == JsonValueKind.Array)
        {
            var serverQn = data.TryGetProperty("quality", out var qEl) && qEl.ValueKind == JsonValueKind.Number
                ? qEl.GetInt32() : 0;
            foreach (var d in durl.EnumerateArray())
            {
                videos.Add(new BiliStream
                {
                    Url = d.TryGetProperty("url", out var u) ? u.GetString() ?? "" : "",
                    QualityId = serverQn,
                    QualityLabel = labels.TryGetValue(serverQn, out var ql3) && ql3.Length > 0
                        ? ql3
                        : (QualityNames.TryGetValue(serverQn, out var ql4) ? ql4 : "原始"),
                    SizeBytes = d.TryGetProperty("size", out var sz) ? sz.GetInt64() : 0,
                });
            }
        }

        // 视频按清晰度降序；音频按码率降序（码率单调，且不怕 B 站新增音质档）
        var orderedVideos = videos.OrderByDescending(x => x.QualityId).ToList();
        var orderedAudios = audios
            .OrderByDescending(x => x.Bitrate)
            .ThenBy(x => Array.IndexOf(AudioRank, x.QualityId) is var idx && idx < 0 ? 99 : idx)
            .ToList();

        return new BiliPlayInfo
        {
            Cid = cid,
            IsDash = isDash,
            Videos = orderedVideos,
            Audios = orderedAudios,
        };
    }

    /// <summary>data.stat.{name} 取数值；没有就 0（不猜）。</summary>
    private static long StatOf(JsonElement data, string name)
    {
        if (!data.TryGetProperty("stat", out var stat) || stat.ValueKind != JsonValueKind.Object)
            return 0;
        if (!stat.TryGetProperty(name, out var v) || v.ValueKind != JsonValueKind.Number)
            return 0;
        return v.GetInt64();
    }

    /// <summary>
    /// support_formats[] → qn 到文案的映射。
    /// 三个历史字段名（quality_desc / new_description / display_desc）都要认。
    /// </summary>
    public static Dictionary<int, string> QualityLabelsByQn(JsonElement data)
    {
        var map = new Dictionary<int, string>();
        if (!data.TryGetProperty("support_formats", out var arr) || arr.ValueKind != JsonValueKind.Array)
            return map;
        foreach (var f in arr.EnumerateArray())
        {
            if (!f.TryGetProperty("quality", out var q) || q.ValueKind != JsonValueKind.Number) continue;
            var qn = q.GetInt32();
            foreach (var key in new[] { "new_description", "display_desc", "quality_desc" })
            {
                if (!f.TryGetProperty(key, out var v)) continue;
                var s = v.GetString();
                if (!string.IsNullOrWhiteSpace(s)) { map[qn] = s!.Trim(); break; }
            }
        }
        return map;
    }

    /// <summary>dash 的 baseUrl 可能为空但有 backupUrl，取第一个可用的。</summary>
    private static string PickBaseUrl(JsonElement e)
    {
        if (e.TryGetProperty("baseUrl", out var b) && !string.IsNullOrEmpty(b.GetString()))
            return b.GetString()!;
        if (e.TryGetProperty("base_url", out var b2) && !string.IsNullOrEmpty(b2.GetString()))
            return b2.GetString()!;
        if (e.TryGetProperty("backupUrl", out var arr) && arr.ValueKind == JsonValueKind.Array)
        {
            foreach (var u in arr.EnumerateArray())
            {
                var s = u.GetString();
                if (!string.IsNullOrEmpty(s)) return s!;
            }
        }
        return "";
    }

    /// <summary>从 RFC 6381 编码串认族：avc1.640032 / hev1.1.6 / av01.0.17M。</summary>
    public static string CodecFromCodecs(JsonElement e)
    {
        var codecs = e.TryGetProperty("codecs", out var c) ? c.GetString() ?? "" : "";
        if (string.IsNullOrEmpty(codecs)) return "";
        var prefix = codecs.Split((char)46)[0].ToLowerInvariant();
        return prefix switch
        {
            "avc1" => "AVC",
            "hev1" or "hvc1" or "dvh1" => "HEVC",
            "av01" => "AV1",
            _ => "",
        };
    }
}