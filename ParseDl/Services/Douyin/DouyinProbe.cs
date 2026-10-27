using System;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace ParseDl.Services.Douyin;

/// <summary>
/// 抖音载荷探针（诊断工具，不是产品功能）。
///
/// 用途：给一个作品链接，打开它、注入拦截脚本、把**真实拿到的数据**落盘，
/// 然后退出。用来回答「这个作品的实况图数据到底长什么样」这类问题 ——
/// 靠截图或猜字段是答不了的。
///
/// 触发方式：<c>解析下载器.exe --probe &lt;url&gt;</c>
/// 输出：<c>userdata\probe\&lt;时间&gt;.json</c>（拦截到的载荷 + 页面内嵌数据）
///
/// 为什么单独做：主窗口那条路要用户登录、点按钮、等界面刷新，不适合自动化取证；
/// 这里只要一个 WebView2，跑完就退，不打扰用户。
/// </summary>
public static class DouyinProbe
{
    /// <summary>--probe 传入的网址（由 Program.Main 在启动前设好）。</summary>
    public static string? Url { get; set; }

    /// <summary>是否为探针模式。</summary>
    public static bool Enabled => !string.IsNullOrEmpty(Url);

    /// <summary>跑一次探针，返回退出码。</summary>
    public static async Task<int> RunAsync(string url, int waitSeconds = 25)
    {
        var dir = Path.Combine(AppPaths.DataDir, "probe");
        Directory.CreateDirectory(dir);
        var stamp = DateTime.Now.ToString("HHmmss");
        var outPath = Path.Combine(dir, stamp + ".json");

        var report = new System.Text.StringBuilder();
        report.AppendLine("{");
        report.AppendLine("  \"url\": " + JsonSerializer.Serialize(url) + ",");

        Window? window = null;
        WebView2? web = null;
        var captured = new System.Collections.Generic.List<string>();

        try
        {
            window = new Window { Title = "抖音载荷探针" };
            web = new WebView2 { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
            window.Content = web;
            window.Activate();

            await web.EnsureCoreWebView2Async();
            var core = web.CoreWebView2;
            core.Settings.UserAgent =
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

            // 抄一份拦截到的原始载荷
            core.WebMessageReceived += (_, e) =>
            {
                try
                {
                    var payload = e.WebMessageAsJson;
                    if (!string.IsNullOrEmpty(payload)) captured.Add(payload);
                }
                catch { }
            };

            await core.AddScriptToExecuteOnDocumentCreatedAsync(DouyinInterceptor.Script);

            core.Navigate(url);

            // 等页面自己发请求（抖音是单页应用，首屏数据可能内嵌、也可能 XHR）
            for (var i = 0; i < waitSeconds; i++)
            {
                await Task.Delay(1000);
                if (captured.Count > 0 && i >= 5) break;
            }

            // 再从页面内嵌数据里抽一次
            string? pageData = null;
            try
            {
                var raw = await core.ExecuteScriptAsync("window.__pdPageData ? window.__pdPageData() : ''");
                pageData = raw;
            }
            catch { }

            // 拦截器自检 + 当前 URL + 页面可见文本（判断是没登录还是没发请求）
            string? info = null, curUrl = null, bodyText = null;
            try { info = await core.ExecuteScriptAsync("window.__pdDouyinInfo ? JSON.stringify(window.__pdDouyinInfo()) : ''"); } catch { }
            try { curUrl = core.Source; } catch { }
            try { bodyText = await core.ExecuteScriptAsync("(document.body && document.body.innerText || '').slice(0, 600)"); } catch { }

            report.AppendLine("  \"capturedCount\": " + captured.Count + ",");
            report.AppendLine("  \"captured\": [");
            for (var i = 0; i < captured.Count; i++)
            {
                report.Append("    ").Append(JsonSerializer.Serialize(captured[i]));
                report.AppendLine(i == captured.Count - 1 ? "" : ",");
            }
            report.AppendLine("  ],");
            report.AppendLine("  \"pageData\": " + (pageData is null ? "null" : JsonSerializer.Serialize(pageData)) + ",");
            report.AppendLine("  \"info\": " + (info is null ? "null" : JsonSerializer.Serialize(info)) + ",");
            report.AppendLine("  \"currentUrl\": " + (curUrl is null ? "null" : JsonSerializer.Serialize(curUrl)) + ",");
            report.AppendLine("  \"bodyText\": " + (bodyText is null ? "null" : JsonSerializer.Serialize(bodyText)));
            report.AppendLine("}");
        }
        catch (Exception ex)
        {
            report.AppendLine("  \"error\": " + JsonSerializer.Serialize(ex.ToString()));
            report.AppendLine("}");
        }
        finally
        {
            try { File.WriteAllText(outPath, report.ToString()); } catch { }
            try { window?.Close(); } catch { }
        }

        return 0;
    }
}
