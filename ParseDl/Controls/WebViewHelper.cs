using System;
using Microsoft.Web.WebView2.Core;

namespace ParseDl.Controls;

/// <summary>
/// WebView2 的公共配置。
///
/// ### 为什么需要（2026-10-27 用户报 B 站「点视频打开新窗口」）
/// WebView2 的默认行为是：页面里 `target="_blank"` 的链接、或 `window.open()`，
/// 会触发 <c>NewWindowRequested</c>，如果没人处理，**WebView2 会把这个请求交给系统**，
/// 结果是弹出系统默认浏览器（用户看到的就是「打开了一个新窗口」）。
///
/// 内嵌浏览器的本意是「在应用里看」，所以这里统一把它改写成**当前 WebView 内导航**。
/// 四个用到 WebView2 的页面（B 站解析、B 站批量、抖音解析、抖音自动）都调这个。
///
/// 注意：必须显式 `e.Handled = true`，否则即使设了 NewWindow 也仍会走系统浏览器。
/// </summary>
public static class WebViewHelper
{
    /// <summary>
    /// 让所有「新窗口」请求改在**当前 WebView 内**打开。
    /// 在 <c>EnsureCoreWebView2Async()</c> 之后调用一次即可。
    /// </summary>
    public static void KeepNavigationInPlace(CoreWebView2 core, Action<string>? onLog = null)
    {
        try
        {
            core.NewWindowRequested += (_, e) =>
            {
                try
                {
                    // 必须置 true —— 否则系统仍会用默认浏览器打开
                    e.Handled = true;
                    var uri = e.Uri;
                    if (!string.IsNullOrEmpty(uri))
                    {
                        onLog?.Invoke("[内嵌浏览器] 新窗口请求改在应用内打开：" + uri);
                        core.Navigate(uri);
                    }
                }
                catch (Exception ex)
                {
                    onLog?.Invoke("[内嵌浏览器] 处理新窗口失败：" + ex.Message);
                }
            };
        }
        catch (Exception ex)
        {
            onLog?.Invoke("[内嵌浏览器] 注册新窗口处理失败：" + ex.Message);
        }
    }
}
