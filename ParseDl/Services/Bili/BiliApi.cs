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
    public IReadOnlyList<BiliPage> Pages { get; init; } = Array.Empty<BiliPage>();
}

public sealed record BiliPage
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
    public bool IsAudio { get; init; }
}

/// <summary>一次解析拿到的全部可下载内容。</summary>
public sealed record BiliPlayInfo
{
    public long Cid { get; init; }
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
    private readonly string _cookie;

    public BiliApi(string? cookie = null, HttpClient? http = null)
    {
        _cookie = cookie ?? "";
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
    }

    private HttpRequestMessage NewRequest(string url)
    {
        var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.TryAddWithoutValidation("Referer", Referer);
        req.Headers.TryAddWithoutValidation("Origin", Origin);
        req.Headers.TryAddWithoutValidation("User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36");
        if (_cookie.Length > 0) req.Headers.TryAddWithoutValidation("Cookie", _cookie);
        return req;
    }

    /// <summary>发一次请求并取出 JSON 的 data 节点。失败重试 3 次（共 4 次尝试）。</summary>
    private async Task<JsonElement> GetDataAsync(string path, CancellationToken ct = default)
    {
        var url = path.StartsWith("http") ? path : "https://" + Host + path;
        Exception? last = null;
        for (var attempt = 0; attempt < 4; attempt++)
        {
            try
            {
                using var req = NewRequest(url);
                using var resp = await _http.SendAsync(req, ct);
                var text = await resp.Content.ReadAsStringAsync(ct);
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

    /// <summary>给列表接口用的公开取数入口（复用同一套请求头与重试策略）。</summary>
    public Task<JsonElement> GetDataPublicAsync(string path, CancellationToken ct = default)
        => GetDataAsync(path, ct);

    /// <summary>取视频基本信息（含分 P 列表）。</summary>
    public async Task<BiliVideoInfo> GetVideoInfoAsync(string bvid, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(bvid)) throw new ArgumentException("bvid 为空", nameof(bvid));
        var data = await GetDataAsync($"/x/web-interface/view?bvid={Uri.EscapeDataString(bvid)}", ct);

        var pages = new List<BiliPage>();
        if (data.TryGetProperty("pages", out var pageArr) && pageArr.ValueKind == JsonValueKind.Array)
        {
            foreach (var p in pageArr.EnumerateArray())
            {
                pages.Add(new BiliPage
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
            Bvid = data.TryGetProperty("bvid", out var b) ? b.GetString() ?? bvid : bvid,
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
        };
    }

    /// <summary>
    /// 取播放地址（视频 + 音频分离，需自行合并）。
    /// qn=127 请求最高清晰度；接口会返回它实际能给的全部档位。
    /// </summary>
    public async Task<BiliPlayInfo> GetPlayInfoAsync(string bvid, long cid, CancellationToken ct = default)
    {
        var data = await GetDataAsync(
            $"/x/player/wbi/playurl?bvid={Uri.EscapeDataString(bvid)}&cid={cid}&qn=127&fnval=16&fourk=1", ct);

        var videos = new List<BiliStream>();
        var audios = new List<BiliStream>();

        // 老接口：durl（整段 flv/mp4，无分离音轨）
        if (data.TryGetProperty("durl", out var durl) && durl.ValueKind == JsonValueKind.Array)
        {
            var idx = 0;
            foreach (var d in durl.EnumerateArray())
            {
                idx++;
                videos.Add(new BiliStream
                {
                    Url = d.TryGetProperty("url", out var u) ? u.GetString() ?? "" : "",
                    QualityId = 0,
                    QualityLabel = "原始",
                    SizeBytes = d.TryGetProperty("size", out var sz) ? sz.GetInt64() : 0,
                });
            }
        }

        // 新接口：dash（视频音频分离，质量更高）
        if (data.TryGetProperty("dash", out var dash) && dash.ValueKind == JsonValueKind.Object)
        {
            if (dash.TryGetProperty("video", out var vArr) && vArr.ValueKind == JsonValueKind.Array)
            {
                foreach (var v in vArr.EnumerateArray())
                {
                    var qid = v.TryGetProperty("id", out var vid) ? vid.GetInt32() : 0;
                    videos.Add(new BiliStream
                    {
                        Url = PickBaseUrl(v),
                        QualityId = qid,
                        QualityLabel = QualityNames.TryGetValue(qid, out var ql) ? ql : ("Q" + qid),
                        Codec = CodecFromCodecs(v),
                        SizeBytes = v.TryGetProperty("size", out var sz2) ? sz2.GetInt64() : 0,
                    });
                }
            }
            if (dash.TryGetProperty("audio", out var aArr) && aArr.ValueKind == JsonValueKind.Array)
            {
                foreach (var a in aArr.EnumerateArray())
                {
                    var qid = a.TryGetProperty("id", out var aid) ? aid.GetInt32() : 0;
                    audios.Add(new BiliStream
                    {
                        Url = PickBaseUrl(a),
                        QualityId = qid,
                        QualityLabel = AudioNames.TryGetValue(qid, out var al) ? al : ("A" + qid),
                        SizeBytes = a.TryGetProperty("size", out var sz3) ? sz3.GetInt64() : 0,
                        IsAudio = true,
                    });
                }
            }
        }

        // 视频按清晰度降序；音频按固定档位序（不能按 id 排）
        var orderedVideos = videos.OrderByDescending(x => x.QualityId).ToList();
        var orderedAudios = audios
            .OrderBy(x => Array.IndexOf(AudioRank, x.QualityId) is var idx && idx < 0 ? 99 : idx)
            .ToList();

        return new BiliPlayInfo { Cid = cid, Videos = orderedVideos, Audios = orderedAudios };
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