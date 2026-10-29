using System;
using System.Threading.Tasks;

namespace ParseDl.Services.Bili;

public static class BiliProbeArc
{
    public static string? DomResult;
    public static string? InPageResult;

    /// <summary>
    /// 探测：不再调接口，改读**空间页渲染后的 DOM**。
    ///
    /// 思路：B站 空间页是 SPA，页面自己会用浏览器环境（真指纹 + 真 cookie）
    /// 去请求 arc/search 并把结果渲染成卡片。我们不调接口，只读渲染结果 ——
    /// 这样绕开了接口风控（风控拦的是我们的 HttpClient，拦不住页面自己）。
    /// </summary>
    public static async Task<string> RunAsync()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("DOM 读取结果: " + (DomResult ?? "(未执行)"));
        sb.AppendLine("页面内 fetch  : " + (InPageResult ?? "(未执行)"));
        return sb.ToString();
    }
}
