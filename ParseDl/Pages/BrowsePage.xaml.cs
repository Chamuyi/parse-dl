using System;
using System.IO;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Web.WebView2.Core;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.Douyin;
using ParseDl.Services.X;

namespace ParseDl.Pages;

/// <summary>浏览器页面服务于哪个平台。</summary>
public enum BrowseKind { X, Douyin }

/// <summary>
/// 内嵌浏览器 —— X / 抖音的页面抓取入口。
///
/// 为什么必须有它：这两个平台都没有「给个 id 就返回 JSON」的公开接口，
/// 唯一可行的路子是**打开真实页面、从中提取数据**。Flutter 版用的也是这个办法
/// （douyin_interceptor_js.dart 867 行 + WebView2 注入）。
///
/// 抓着方式：注入脚本读页面里的内嵌 JSON（抖音 _ROUTER_DATA / X 的初始状态），
/// 再交给各自的解析器（已实现并有离线自测覆盖）。
/// </summary>
public sealed partial class BrowsePage : Page
{
    private BrowseKind _kind = BrowseKind.Douyin;
    private bool _ready;
    private System.Collections.Generic.List<string>? _capturedX;

    public BrowsePage() { InitializeComponent(); }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is BrowseNavArgs args) _kind = args.Kind;

        HeaderHost.Children.Add(UiKit.PageHeader(
            _kind == BrowseKind.Douyin ? "抖音网页抓取" : "X 网页抓取",
            _kind == BrowseKind.Douyin
                ? "打开抖音页面并抓取作品（需先登录）"
                : "打开 X 页面并抓取推文（需先登录）",
            "\uE774"));

        UrlBox.Text = _kind == BrowseKind.Douyin ? "https://www.douyin.com/" : "https://x.com/";
        StatusText.Text = "首次使用请先登录，登录态会保存在 WebView2 数据目录里，之后不用重复登录。";
        _ = InitWebAsync();
    }

    private async Task InitWebAsync()
    {
        try
        {
            // WebView2 用户数据目录：**必须在进程启动前设环境变量 WEBVIEW2_USER_DATA_FOLDER**，
            // 或者用带参数的 EnsureCoreWebView2Async(env)。这里两条路都试过：
            //   * CreateAsync 因程序集同名类型冲突（Core.dll vs Core.Projection.dll）解析不到重载；
            //   * 反射在运行期也找不到三参数版本（投影类型上没有）。
            // 所以先用**默认环境**把功能跑通 —— 数据目录落在 exe 同级的
            // <exe目录>\ParseDl.exe.WebView2\，登录态同样能跨重启保留（只是不在 userdata 下）。
            // 要改到 userdata 下，需在 App 启动前设 WEBVIEW2_USER_DATA_FOLDER 环境变量，
            // 那是后续优化项，不影响功能。
            await Web.EnsureCoreWebView2Async();

            // 普通桌面 UA —— 默认 UA 带 "WebView" 字样，很多站点会给不同页面
            Web.CoreWebView2.Settings.UserAgent =
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";
            Web.CoreWebView2.Settings.IsStatusBarEnabled = false;

            // X 的数据不在 HTML 里 —— 页面是客户端渲染的，推文数据通过 GraphQL
            // 接口异步拉取。所以必须**拦截网络响应**才能拿到，读 outerHTML 是空的。
            // 抖音相反：它把数据塞在页面里的 _ROUTER_DATA，读 HTML 就够。
            if (_kind == BrowseKind.X)
            {
                _capturedX = new System.Collections.Generic.List<string>();
                Web.CoreWebView2.WebResourceResponseReceived += async (_, e) =>
                {
                    try
                    {
                        var uri = e.Request.Uri ?? "";
                        // 只关心时间线接口，其他响应不读（读正文很贵）
                        if (!uri.Contains("graphql") && !uri.Contains("UserTweets") &&
                            !uri.Contains("UserMedia")) return;
                        if (_capturedX.Count >= 20) return;

                        var raw = await e.Response.GetContentAsync();
                        if (raw is null) return;
                        // IRandomAccessStream 不是 System.IO.Stream，要 AsStreamForRead 转一次
                        using var netStream = raw.AsStreamForRead();
                        using var reader = new System.IO.StreamReader(netStream);
                        var body = await reader.ReadToEndAsync();
                        if (!string.IsNullOrEmpty(body) && body.Contains("tweet_results"))
                            _capturedX.Add(body);
                    }
                    catch
                    {
                        // 读响应失败不影响浏览
                    }
                };
            }

            Web.CoreWebView2.NavigationCompleted += (_, _) =>
            {
                UrlBox.Text = Web.CoreWebView2.Source;
                StatusText.Text = "页面已加载。登录后滚动到目标内容，再点「抓取本页」。";
            };

            _ready = true;
            Web.CoreWebView2.Navigate(UrlBox.Text);
        }
        catch (Exception ex)
        {
            StatusText.Text = "WebView2 初始化失败：" + ex.Message +
                "（若为打包应用，需要 WebView2 框架包依赖）";
        }
    }

    private void OnBackClick(object sender, RoutedEventArgs e)
    {
        if (_ready && Web.CoreWebView2.CanGoBack) Web.CoreWebView2.GoBack();
    }

    private void OnGoClick(object sender, RoutedEventArgs e) => Navigate();

    private void OnUrlKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) Navigate();
    }

    private void Navigate()
    {
        if (!_ready) { StatusText.Text = "WebView2 还没就绪。"; return; }
        var url = UrlBox.Text?.Trim() ?? "";
        if (url.Length == 0) return;
        if (!url.StartsWith("http")) url = "https://" + url;
        try { Web.CoreWebView2.Navigate(url); }
        catch (Exception ex) { StatusText.Text = "导航失败：" + ex.Message; }
    }

    /// <summary>
    /// 抓取当前页：把页面 HTML 拿回来，交给对应平台的解析器。
    ///
    /// 为什么要取完整 HTML 而不是让脚本直接返回 JSON：抖音的容器名有多个版本
    /// （_ROUTER_DATA / RENDER_DATA / __INITIAL_STATE__），解析逻辑在 C# 侧
    /// 已经写过并有自测覆盖，脚本只管把原文搬回来，职责更清楚。
    /// </summary>
    private async void OnCaptureClick(object sender, RoutedEventArgs e)
    {
        if (!_ready || Web.CoreWebView2 is null) { StatusText.Text = "WebView2 还没就绪。"; return; }
        CaptureButton.IsEnabled = false;
        StatusText.Text = "正在抓取页面…";
        try
        {
            var html = await Web.CoreWebView2.ExecuteScriptAsync("document.documentElement.outerHTML");
            html = UnquoteJsString(html);
            StatusText.Text = "页面已取回（" + html.Length + " 字符），正在解析…";

            if (_kind == BrowseKind.Douyin)
            {
                var json = DouyinParser.ExtractEmbeddedJson(html);
                if (string.IsNullOrEmpty(json))
                {
                    StatusText.Text = "这个页面里没有找到抖音的数据容器。请打开具体作品页或用户主页后再抓。";
                    return;
                }
                using var doc = System.Text.Json.JsonDocument.Parse(json);
                var list = DouyinParser.ParseAllAwemes(doc.RootElement);
                if (list.Count == 0)
                {
                    StatusText.Text = "页面里没有解析出作品（可能需要先登录、或该页不含作品列表）。";
                    return;
                }

                var added = 0;
                foreach (var a in list)
                {
                    foreach (var m in a.Media)
                    {
                        var name = DouyinNameFor(a, m);
                        // refresh: false —— 批量入队不做全量刷新，收尾统一 FlushAsync。
                        // 否则每加一条就 TellAllAsync 拉全部任务，作品一多就把超时撑爆。
                        var (ok, _) = await DownloadStore.Instance.AddAsync(
                            m.Url, "抖音", null, name);
                        if (ok) added++;
                    }
                }
                DownloadStore.Instance.Flush();
                StatusText.Text = "解析出 " + list.Count + " 个作品，媒体入队 " + added + " 条。";
            }
            else
            {
                // X：用拦截到的响应
                if (_capturedX is null || _capturedX.Count == 0)
                {
                    StatusText.Text = "还没抓到 X 的接口响应。请先登录，然后滚动页面让推文加载出来，再点抓取。";
                    return;
                }

                var totalPosts = 0;
                var totalMedia = 0;
                var addedMedia = 0;
                foreach (var body in _capturedX)
                {
                    try
                    {
                        using var xdoc = System.Text.Json.JsonDocument.Parse(body);
                        var page = XApi.ParseTimeline(xdoc.RootElement);
                        totalPosts += page.Posts.Count;
                        foreach (var p in page.Posts)
                        {
                            for (var mi = 0; mi < p.Media.Count; mi++)
                            {
                                var m = p.Media[mi];
                                totalMedia++;
                                var name = XNameFor(p, mi);
                                var ext = m.Type == "video" ? "mp4" : "jpg";
                                var (ok2, _) = await DownloadStore.Instance.AddAsync(
                                    m.Url, "X 媒体", null, name + "." + ext);
                                if (ok2) addedMedia++;
                            }
                        }
                    }
                    catch
                    {
                        // 单个响应解析失败不影响其他
                    }
                }

                DownloadStore.Instance.Flush();

                if (totalMedia == 0)
                {
                    StatusText.Text = "抓到 " + _capturedX.Count + " 个响应，"
                        + totalPosts + " 条推文，但没有媒体（可能都是纯文字推文）。";
                }
                else
                {
                    StatusText.Text = "抓到 " + _capturedX.Count + " 个响应，"
                        + totalPosts + " 条推文，" + totalMedia + " 条媒体，入队 " + addedMedia + " 条。";
                }
            }
        }
        catch (Exception ex)
        {
            StatusText.Text = "抓取失败：" + ex.Message;
        }
        finally
        {
            CaptureButton.IsEnabled = true;
        }
    }

    /// <summary>X 媒体按模板命名。</summary>
    private static string XNameFor(XPost p, int mediaIndex)
    {
        var m = p.Media[mediaIndex];
        var settings = AppSettings.Instance.ForModule("x");
        var tpl = string.IsNullOrWhiteSpace(settings.FileNameTemplate)
            ? "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%" : settings.FileNameTemplate;
        var ctx = new TemplateContext
        {
            PostId = p.Id,
            PostTime = p.CreatedAt,
            UserId = p.UserId,
            UserName = p.UserName,
            UserScreenName = p.UserScreenName,
            MediaId = m.Id,
            MediaIndex = mediaIndex + 1,
            MediaCount = p.Media.Count,
            MediaWidth = m.Width,
            MediaHeight = m.Height,
            Extension = m.Type == "video" ? "mp4" : "jpg",
            Content = p.Text,
        };
        var name = FileNameTemplate.UnicodeFilenamify(FileNameTemplate.Resolve(tpl, ctx));
        return string.IsNullOrWhiteSpace(name) ? (p.Id + "_" + (mediaIndex + 1)) : name;
    }

    /// <summary>抖音媒体按模板命名。</summary>
    private static string DouyinNameFor(DouyinAweme a, DouyinMedia m)
    {
        var settings = AppSettings.Instance.ForModule("douyin");
        var tpl = string.IsNullOrWhiteSpace(settings.FileNameTemplate)
            ? "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%" : settings.FileNameTemplate;
        var ext = m.Type == "video" ? "mp4" : "jpg";
        var ctx = new TemplateContext
        {
            PostId = a.Id,
            PostTime = a.CreatedAt,
            UserName = a.AuthorName,
            UserScreenName = a.AuthorUniqueId,
            MediaId = a.Id,
            MediaIndex = m.Index,
            Extension = ext,
            Content = a.Desc,
        };
        var name = FileNameTemplate.ResolveDouyin(tpl, ctx);
        return string.IsNullOrWhiteSpace(name) ? (a.Id + "_" + m.Index + "." + ext) : (name + "." + ext);
    }

    /// <summary>
    /// ExecuteScriptAsync 返回的是 **JSON 编码过的字符串**（带外层引号与转义）。
    /// 直接当 HTML 用会全是 \n 和 \" —— 必须先按 JSON 字符串解一次。
    /// </summary>
    private static string UnquoteJsString(string raw)
    {
        if (string.IsNullOrEmpty(raw)) return "";
        raw = raw.Trim();
        if (raw.Length < 2 || raw[0] != (char)34) return raw;
        try
        {
            return System.Text.Json.JsonSerializer.Deserialize<string>(raw) ?? "";
        }
        catch
        {
            return raw;
        }
    }
}

/// <summary>浏览页导航参数。</summary>
public sealed record BrowseNavArgs(BrowseKind Kind, MainWindow Host);