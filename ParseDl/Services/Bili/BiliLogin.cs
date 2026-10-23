using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.Bili;

/// <summary>登录二维码。</summary>
public sealed record BiliQrCode(string Url, string Key);

/// <summary>登录轮询状态。</summary>
public enum BiliLoginState
{
    Waiting,     // 等待扫码
    Scanned,     // 已扫码，等待手机确认
    Confirmed,   // 已确认，登录成功
    Expired,     // 二维码过期
}

/// <summary>登录结果。State 为 Confirmed 时 Cookie 与 Mid 才有值。</summary>
public sealed record BiliLoginResult(BiliLoginState State, string Cookie, long Mid);

/// <summary>
/// B 站扫码登录 —— 从 Flutter 版 bili_web.dart 的登录部分移植。
///
/// 为什么必须登录：**未登录只能拿到 480P**。1080P 及以上要 SESSDATA cookie。
///
/// 流程：generate 取二维码 → 每 2 秒 poll 一次 → 手机确认后拿到 cookie。
/// 二维码本身就是一张图片地址，交给界面直接显示即可。
/// </summary>
public sealed class BiliLogin
{
    private readonly BiliApi _api;

    public BiliLogin(BiliApi? api = null) => _api = api ?? new BiliApi();

    /// <summary>生成登录二维码：返回二维码图片地址与轮询用的 key。</summary>
    public async Task<BiliQrCode> GenerateQrCodeAsync(CancellationToken ct = default)
    {
        var data = await _api.GetDataPublicAsync("/x/passport-login/web/qrcode/generate", ct);
        var url = data.TryGetProperty("url", out var u) ? u.GetString() ?? "" : "";
        var key = data.TryGetProperty("qrcode_key", out var k) ? k.GetString() ?? "" : "";
        if (string.IsNullOrEmpty(url) || string.IsNullOrEmpty(key))
            throw new BiliApiException("二维码生成失败：响应里没有 url 或 qrcode_key");
        return new BiliQrCode(url, key);
    }

    /// <summary>轮询一次登录状态。</summary>
    public async Task<BiliLoginResult> PollAsync(string qrcodeKey, CancellationToken ct = default)
    {
        var path = "/x/passport-login/web/qrcode/poll?qrcode_key=" + Uri.EscapeDataString(qrcodeKey);
        var data = await _api.GetDataPublicAsync(path, ct);

        var code = 0;
        if (data.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.Number)
            code = c.GetInt32();

        // B 站状态码：0 成功 / 86038 过期 / 86090 已扫码待确认 / 86101 未扫码
        var state = code switch
        {
            0 => BiliLoginState.Confirmed,
            86038 => BiliLoginState.Expired,
            86090 => BiliLoginState.Scanned,
            86101 => BiliLoginState.Waiting,
            _ => BiliLoginState.Waiting,
        };

        if (state != BiliLoginState.Confirmed) return new BiliLoginResult(state, "", 0);

        // 登录成功时 cookie 被 B 站拼在响应里 url 字段的查询串上（实测如此）。
        // 直接取 Set-Cookie 头需要访问 HttpResponseMessage，但 GetDataPublicAsync
        // 只返回 data 节点，所以走 url 字段这条路。
        var cookie = "";
        if (data.TryGetProperty("url", out var u) && u.ValueKind == JsonValueKind.String)
        {
            var raw = u.GetString() ?? "";
            var qi = raw.IndexOf((char)63);
            if (qi >= 0) cookie = raw.Substring(qi + 1).Replace("&", "; ");
        }

        var mid = data.TryGetProperty("mid", out var m) && m.ValueKind == JsonValueKind.Number
            ? m.GetInt64() : 0;

        return new BiliLoginResult(state, cookie, mid);
    }

    /// <summary>
    /// 完整等待流程：轮询到确认或过期。
    /// onStateChanged 用来把状态变化推给界面 —— 用户需要看到「已扫码，请确认」。
    /// </summary>
    public async Task<BiliLoginResult> WaitAsync(string qrcodeKey,
        Action<BiliLoginState>? onStateChanged = null, CancellationToken ct = default)
    {
        // 二维码有效期约 3 分钟，2 秒一次，最多轮 90 次
        for (var i = 0; i < 90; i++)
        {
            if (ct.IsCancellationRequested) break;
            var r = await PollAsync(qrcodeKey, ct);
            onStateChanged?.Invoke(r.State);
            if (r.State == BiliLoginState.Confirmed) return r;
            if (r.State == BiliLoginState.Expired) return r;
            await Task.Delay(2000, ct);
        }
        return new BiliLoginResult(BiliLoginState.Expired, "", 0);
    }
}
