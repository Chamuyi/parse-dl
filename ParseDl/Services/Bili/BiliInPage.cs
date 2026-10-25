using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;

namespace ParseDl.Services.Bili;

/// <summary>
/// 在 B 站内嵌页面里发一个 GET，把响应体读回来 —— 对齐 Flutter 版
/// lib/services/bili_web.dart 的 BiliInPage。
///
/// **为什么要走「页内 fetch」而不是 C# 的 HttpClient：**
/// B 站的登录态（SESSDATA 等）是 HttpOnly cookie，JS 读不到、我们也导不出来，
/// 但它就在那个 WebView 的会话里。让页面自己 fetch(..., {credentials:'include'})，
/// Cookie / Referer / Origin 全部由浏览器补 —— 我们不需要碰凭据，也不用把它
/// 抄进任何文件或日志。这就是「登录态只用来问有哪些流」的落点。
///
/// 实现方式：ExecuteScriptAsync **不 await Promise**，只能「发起 + 反复读全局变量」。
/// 结果槽位用 ASCII 哨兵标记「还没写完」与「抛错了」—— 正常的 B 站响应一定是
/// 花括号开头的 JSON，撞不上这两个串。
/// </summary>
public static class BiliInPage
{
    private const string Pending = "@@PD@@";
    private const string ErrorPrefix = "@@ERR@@";

    /// <summary>页内发一个 GET，返回**原始响应体**（不判 code、不取 data）。</summary>
    public static async Task<string> FetchAsync(
        CoreWebView2 core, string url, int timeoutMs = 20000, CancellationToken ct = default)
    {
        var key = "pd_" + Guid.NewGuid().ToString("N");
        var keyLit = Lit(key);
        var urlLit = Lit(url);
        var pendingLit = Lit(Pending);
        var errLit = Lit(ErrorPrefix);

        // ① 发起请求：把结果写进 window[key]
        var startScript =
            "(function(){try{window[" + keyLit + "]=" + pendingLit + ";" +
            "fetch(" + urlLit + ",{credentials:'include'})" +
            ".then(function(r){return r.text();})" +
            ".then(function(t){window[" + keyLit + "]=t;})" +
            ".catch(function(e){window[" + keyLit + "]=" + errLit + "+String(e);});" +
            "}catch(e){window[" + keyLit + "]=" + errLit + "+String(e);}})()";

        await core.ExecuteScriptAsync(startScript);

        // ② 轮询读槽位
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        var readScript = "String(window[" + keyLit + "]||'')";
        while (DateTime.UtcNow < deadline)
        {
            ct.ThrowIfCancellationRequested();
            var raw = await core.ExecuteScriptAsync(readScript);
            var value = Unquote(raw);
            if (value == Pending || value.Length == 0)
            {
                await Task.Delay(60, ct);
                continue;
            }
            // 顺手清掉，别让全局对象越长越大
            try { await core.ExecuteScriptAsync("try{delete window[" + keyLit + "];}catch(e){}"); }
            catch { }

            if (value.StartsWith(ErrorPrefix, StringComparison.Ordinal))
                throw new InvalidOperationException("页内请求失败：" + value.Substring(ErrorPrefix.Length));
            return value;
        }

        try { await core.ExecuteScriptAsync("try{delete window[" + keyLit + "];}catch(e){}"); }
        catch { }
        throw new TimeoutException("页内请求超时（" + (timeoutMs / 1000) + "s）：" + url);
    }

    /// <summary>把字符串变成安全的 JS 字面量（用 JSON 编码，引号与反斜杠都稳）。</summary>
    private static string Lit(string s) => System.Text.Json.JsonSerializer.Serialize(s);

    /// <summary>ExecuteScriptAsync 返回的是 JSON 编码过的字符串，要先解一次。</summary>
    public static string Unquote(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return "";
        var t = raw!.Trim();
        if (t.Length < 2 || t[0] != (char)34) return t;
        try { return System.Text.Json.JsonSerializer.Deserialize<string>(t) ?? ""; }
        catch { return t; }
    }
}
