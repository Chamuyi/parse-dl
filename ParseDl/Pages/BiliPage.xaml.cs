using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Web.WebView2.Core;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.Bili;

namespace ParseDl.Pages;

/// <summary>
/// B 站解析下载 —— 对齐 Flutter 版 lib/pages/bili_page.dart（1258 行）与
/// 原项目形态截图（左边浏览、右边抓取）。
///
/// 为什么这一页**必须有** WebView2（与 X 主页相反）：
///  B 站的高清档与字幕都要登录态，而登录态是 HttpOnly cookie —— 它只活在
///  这个 WebView 的会话里，导不出来也不该导出来。让页面自己 fetch，凭据由浏览器补，
///  这样「登录态只用来问有哪些流，不用来取流字节」这条红线才守得住。
///
/// 抓取两条路（照原项目）：
///  * 抓当前页 —— 读内嵌页**当前的网址**交给 BiliLink 解析；
///  * 抓正在播 —— 从 DOM 里读稿件号（页面自带的 __INITIAL_STATE__，
///    退而求其次看 canonical）。多 P 稿件翻到第 5 P 时网址可能还停在第 1 P，
///    所以这两条不是一回事。**读不到就如实说，绝不猜一个 BV 号**（猜错会下错稿件）。
/// </summary>
public sealed partial class BiliPage : Page
{
    private BiliConfig Cfg => BiliConfig.Instance;

    private const string HomeUrl = "https://www.bilibili.com/";

    private bool _webReady;
    private BiliApi? _api;

    /// <summary>当前解析出来的稿件（含全部分P）。</summary>
    private BiliVideoInfo? _info;
    private BiliRef? _ref;

    /// <summary>结果列表里每一行（勾选框 ↔ 分P）的映射。</summary>
    private readonly List<(BiliPart Part, CheckBox Box, Border Row)> _rows = new();
    /// <summary>「抓当前页」列出来的稿件号（列表里只有 BV 号、还没取分 P 详情时用）。</summary>
    private List<string>? _pageBvids;

    private string _saveDir = "";

    public BiliPage() { InitializeComponent(); }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Cfg.Load();
        Root.Children.Remove(HeaderHost);
        var header = UiKit.PageHeader("B 站解析下载", "左边浏览，右边抓取", "\uE7F4");
        header.Margin = new Thickness(0, 0, 0, 4);
        HeaderHost.Children.Add(header);
        UpdateCapText();
        _ = InitWebAsync();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        // 离开页面就停掉 WebView2 的导航回调，免得后台还在推状态
        try
        {
            if (_webReady && Web.CoreWebView2 is not null)
                Web.CoreWebView2.NavigationCompleted -= OnWebNavigationCompleted;
        }
        catch { }
    }

    // ── WebView2 ────────────────────────────────────────────

    private async Task InitWebAsync()
    {
        try
        {
            await Web.EnsureCoreWebView2Async();
            // 让页面里的 target=_blank / window.open 在**当前 WebView 内**打开，
            // 而不是弹系统浏览器（用户 2026-10-27 报 B 站点视频会开新窗口）。
            ParseDl.Controls.WebViewHelper.KeepNavigationInPlace(Web.CoreWebView2);
            Web.CoreWebView2.Settings.UserAgent =
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";
            Web.CoreWebView2.Settings.IsStatusBarEnabled = false;

            Web.CoreWebView2.NavigationCompleted += OnWebNavigationCompleted;
            _webReady = true;
            WebFallback.Visibility = Visibility.Collapsed;
            UrlBox.Text = HomeUrl;
            Web.CoreWebView2.Navigate(HomeUrl);

            // 页面就绪后自动查一次登录态（**不轮询**：轮询会把 UI 线挂住）
            await CheckLoginAsync();
        }
        catch (Exception ex)
        {
            WebFallback.Visibility = Visibility.Visible;
            WebFallbackText.Text = "内嵌浏览器初始化失败：" + ex.Message +
                "。若为打包应用，需要 WebView2 运行时（随 Windows App SDK 分发）。";
            LoginText.Text = "登录状态检测不到（浏览器没起来）";
        }
    }

    private void OnWebNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        try { UrlBox.Text = Web.CoreWebView2.Source; } catch { }
    }

    private void Navigate(string url)
    {
        if (!_webReady || Web.CoreWebView2 is null) return;
        if (url.Length == 0) return;
        if (!url.StartsWith("http", StringComparison.OrdinalIgnoreCase)) url = "https://" + url;
        try { Web.CoreWebView2.Navigate(url); }
        catch { }
    }

    private void OnBackClick(object sender, RoutedEventArgs e)
    {
        if (_webReady && Web.CoreWebView2.CanGoBack) Web.CoreWebView2.GoBack();
    }

    private void OnForwardClick(object sender, RoutedEventArgs e)
    {
        if (_webReady && Web.CoreWebView2.CanGoForward) Web.CoreWebView2.GoForward();
    }

    private void OnReloadClick(object sender, RoutedEventArgs e)
    {
        if (_webReady) Web.CoreWebView2.Reload();
    }

    private void OnHomeClick(object sender, RoutedEventArgs e) => Navigate(HomeUrl);

    private void OnUrlKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) Navigate(UrlBox.Text?.Trim() ?? "");
    }

    // ── 登录态 ──────────────────────────────────────────────

    private async void OnCheckLoginClick(object sender, RoutedEventArgs e) => await CheckLoginAsync();

    /// <summary>
    /// 查登录态：**在页面里发 nav 请求**，登录 cookie 由浏览器自己补。
    ///
    /// 三态分开说（照原项目 biliLoginLineText）：「检测不到」与「未登录」不是一回事 ——
    /// 把前者写成后者，用户会去扫码，而根因其实是页面没就绪或被风控。
    /// </summary>
    private async Task CheckLoginAsync()
    {
        if (!_webReady || Web.CoreWebView2 is null)
        {
            LoginText.Text = "登录状态检测不到（浏览器还没就绪）";
            return;
        }
        LoginText.Text = "正在检测登录状态…";
        try
        {
            var body = await BiliInPage.FetchAsync(Web.CoreWebView2,
                "https://api.bilibili.com/x/web-interface/nav", 15000);
            if (string.IsNullOrWhiteSpace(body))
            {
                LoginText.Text = "检测不到登录状态（被风控或页面没就绪）";
                return;
            }
            using var doc = System.Text.Json.JsonDocument.Parse(body);
            var root = doc.RootElement;
            if (!root.TryGetProperty("data", out var data) || data.ValueKind != System.Text.Json.JsonValueKind.Object)
            {
                LoginText.Text = "检测不到登录状态（接口没给数据）";
                return;
            }
            var isLogin = data.TryGetProperty("isLogin", out var il) &&
                          il.ValueKind == System.Text.Json.JsonValueKind.True;
            if (!isLogin)
            {
                LoginText.Text = "未登录（只能取到 480P）";
                return;
            }
            var uname = data.TryGetProperty("uname", out var un) ? un.GetString() ?? "" : "";
            LoginText.Text = uname.Length > 0 ? ("已登录：" + uname) : "已登录（没取到昵称）";

            // 登录后把 cookie 也从页面里带出来一份：**注意这是本版已知偏离**
            // （Flutter 版刻意不落盘 cookie）。这里只在内存里存着给直链接口的
            // 请求头用，落盘由 BiliConfig.Cookie 那一处显式决定。
            //
            // **实现**（2026-10-29 补）：上面这段注释原来只是个 TODO，代码一行没写 ——
            // 结果是「用户在 B 站页面明明登录了，但 Cfg.Cookie 一直是空的」，
            // 所以 playurl 永远按未登录处理，只能取 480P。
            //
            // 这里用 CookieManager 把 SESSDATA 等取出来，**只在内存里给本次会话用**，
            // 不落盘（Flutter 版刻意不落盘 cookie，这里保持一致）。
            await BiliConfig.CaptureCookieFromWebViewAsync(Web.CoreWebView2);
        }
        catch (Exception ex)
        {
            LoginText.Text = "检测不到登录状态（" + ex.Message + "）";
        }
    }

    // ── 抓当前页 / 抓正在播 ─────────────────────────────────

    private async void OnGrabPageClick(object sender, RoutedEventArgs e) => await GrabCurrentPageAsync();

    private async Task GrabCurrentPageAsync()
    {
        if (!_webReady || Web.CoreWebView2 is null)
        {
            SetStatus("内嵌浏览器还没就绪，请稍后再试");
            return;
        }
        var url = "";
        try { url = Web.CoreWebView2.Source ?? ""; } catch { }
        if (url.Length == 0 || url.TrimEnd('/') == HomeUrl.TrimEnd('/'))
        {
            SetStatus("内嵌页还停在首页 —— 先在左边打开一条稿件，再点「抓当前页」");
            return;
        }

        // **「抓当前页」= 抓这个页面上的全部视频**（2026-10-30 用户澄清）。
        //
        // 用户原话：「抓当前页是需要抓当前页面的所有视频，抓当前播放才是现在放的视频」。
        // 原来的实现两个按钮几乎一样 —— 都只取一个 bvid 然后解析那一条，
        // 「抓当前页」根本不是「抓全部」。
        //
        // 现在分两步：
        //  ① 先从页面 DOM 里把能看到的稿件号全捞出来（这是「当前页面的所有视频」）；
        //  ② 捞到多个就把它们当一份名单，直接进批量下载队列；
        //     只捞到一个（单稿件页）就走原来的单条解析，保留分 P 勾选界面。
        var ids = await CollectPageVideoIdsAsync();
        // **多条：直接在右侧列表列出来让用户自选**（2026-10-30 用户要求）。
        //
        // 用户原话：「为什么要去批量页，直接在抓取列表列出来，让我来自选不就行了」。
        // 原来这里只把名单塞进链接框、让用户自己跳去批量下载页 —— 多此一举。
        // 现在直接渲染成勾选列表，和单稿件页的分 P 列表同一个交互。
        if (ids.Count > 1)
        {
            LinkBox.Text = "";
            RenderVideoList(ids);
            SetStatus("当前页共 " + ids.Count + " 条视频，勾选后点「开始下载」");
            Aria2Engine.Log("[B站] 抓当前页拿到 " + ids.Count + " 条：" + string.Join(", ", ids.Take(5))
                + (ids.Count > 5 ? " …" : ""));
            return;
        }

        // 只有 1 条（或 DOM 捞不到）→ 退回「按当前 URL 解析单条」
        LinkBox.Text = url;
        await ParseLinkAsync(url);
    }

    /// <summary>
    /// 把「抓当前页」捞到的一批稿件号**直接渲染成勾选列表**（用户要求：列出来自选）。
    ///
    /// 与单稿件页的分 P 列表共用同一套行样式与勾选逻辑，
    /// 区别只是这里每条是**一个稿件**（BV 号），还没取到分 P 详情 ——
    /// 标题先用 BV 号占位，点「开始下载」时再按 BV 号逐条取流。
    /// </summary>
    private void RenderVideoList(List<string> bvids)
    {
        ResultHost.Children.Clear();
        _rows.Clear();
        _info = null;
        EmptyState.Visibility = Visibility.Collapsed;

        var head = new Grid { Margin = new Thickness(0, 0, 0, 4) };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var headLeft = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        headLeft.Children.Add(new FontIcon { Glyph = "\uE7F4", FontSize = 13, Opacity = 0.8 });
        headLeft.Children.Add(new TextBlock
        {
            Text = "抓取结果 " + bvids.Count + " 个作品", FontSize = 13.5,
            FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center,
        });
        head.Children.Add(headLeft);

        var selectedText = new TextBlock
        {
            Text = "已选 0", FontSize = 12, Opacity = 0.7,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(selectedText, 1);
        selectedText.HorizontalAlignment = HorizontalAlignment.Center;
        head.Children.Add(selectedText);

        var closeBtn = new Button
        {
            Content = "\uE711", FontFamily = new FontFamily("Segoe Fluent Icons"),
            FontSize = 12, Width = 30, Height = 28, Padding = new Thickness(0),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(closeBtn, "关闭抓取结果");
        closeBtn.Click += (_, _) =>
        {
            ResultHost.Children.Clear();
            _rows.Clear();
            _pageBvids = null;
            EmptyState.Visibility = Visibility.Visible;
            UpdateCapText();
        };
        Grid.SetColumn(closeBtn, 2);
        head.Children.Add(closeBtn);
        ResultHost.Children.Add(head);

        _pageBvids = new List<string>(bvids);
        foreach (var bv in bvids)
        {
            var row = BuildPageRow(bv, selectedText);
            _rows.Add((new BiliPart { Title = bv, Page = 0, Cid = null }, (CheckBox)row.Tag, row));
            ResultHost.Children.Add(row);
        }
        UpdateCapText();
        UpdateSelected(selectedText);
    }

    /// <summary>「抓当前页」列表里的一行（一个稿件）。</summary>
    private Border BuildPageRow(string bvid, TextBlock selectedText)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var box = new CheckBox { IsChecked = true, VerticalAlignment = VerticalAlignment.Top };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, "选择 " + bvid);
        box.Checked += (_, _) => UpdateSelected(selectedText);
        box.Unchecked += (_, _) => UpdateSelected(selectedText);
        grid.Children.Add(box);

        var texts = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(new TextBlock
        {
            Text = bvid, FontSize = 13, FontWeight = FontWeights.SemiBold,
            IsTextSelectionEnabled = true,
        });
        texts.Children.Add(new TextBlock
        {
            Text = "点「开始下载」时按此稿件取流", FontSize = 11, Opacity = 0.6,
        });
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);

        return new Border
        {
            Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
            BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8, 8, 6, 8),
            Child = grid,
            Tag = box,
        };
    }

    /// <summary>
    /// 从内嵌页的 DOM 里捞**当前页面上的全部稿件号**（去重、保序）。
    ///
    /// 为什么走 DOM 而不是接口：用户说的「当前页面的所有视频」就是**他现在看到的那些**，
    /// 合集页/推荐位/相关推荐的视频都在 DOM 里，接口反而要按类型分别调、还容易触发风控。
    /// 捞不到就返回空，调用方退回单条解析 —— 不猜、不报错。
    /// </summary>
    private async Task<List<string>> CollectPageVideoIdsAsync()
    {
        var list = new List<string>();
        try
        {
            var js = """
                (function () {
                  var out = [];
                  var seen = {};
                  function push(v) {
                    if (!v) return;
                    var m = /(BV[1-9A-HJ-NP-Za-km-z]{10})/.exec(String(v));
                    if (!m) return;
                    if (seen[m[1]]) return;
                    seen[m[1]] = 1;
                    out.push(m[1]);
                  }
                  try {
                    var as = document.querySelectorAll('a[href*="BV"]');
                    for (var i = 0; i < as.length; i++) push(as[i].getAttribute('href'));
                  } catch (e) {}
                  try {
                    var st = window.__INITIAL_STATE__;
                    if (st) {
                      var s = JSON.stringify(st);
                      var re = /BV[1-9A-HJ-NP-Za-km-z]{10}/g;
                      var mm;
                      var guard = 0;
                      while ((mm = re.exec(s)) !== null && guard++ < 500) push(mm[0]);
                    }
                  } catch (e) {}
                  return out.join(',');
                })()
                """;
            var raw = await Web.CoreWebView2!.ExecuteScriptAsync(js);
            var text = UnquoteJsString(raw);
            foreach (var part in (text ?? "").Split(','))
            {
                var bv = ExtractBvid(part);
                if (bv is not null && !list.Contains(bv)) list.Add(bv);
            }
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[B站] 抓当前页读 DOM 失败：" + ex.Message);
        }
        return list;
    }

    private async void OnGrabPlayingClick(object sender, RoutedEventArgs e) => await GrabPlayingAsync();

    /// <summary>
    /// 抓页面里**正在播放的那一条**。
    /// 读的是同步可得的全局值（executeScript 不 await Promise，写成异步只会拿到
    /// [object Promise]），两级都取不到就如实报「读不到」，不猜。
    /// </summary>
    private async Task GrabPlayingAsync()
    {
        if (!_webReady || Web.CoreWebView2 is null)
        {
            SetStatus("内嵌浏览器还没就绪，请稍后再试");
            return;
        }
        try
        {
            var raw = await Web.CoreWebView2.ExecuteScriptAsync(@"(function () {
  try {
    var st = window.__INITIAL_STATE__;
    if (st) {
      if (st.bvid) return String(st.bvid);
      if (st.videoData && st.videoData.bvid) return String(st.videoData.bvid);
    }
  } catch (e) {}
  try {
    var c = document.querySelector('link[rel=""canonical""]');
    if (c && c.href) return String(c.href);
  } catch (e) {}
  return '';
})()");
            var text = UnquoteJsString(raw);
            var bvid = ExtractBvid(text);
            if (bvid is null)
            {
                SetStatus("读不到正在播放的稿件号 —— 先在左边打开一条视频再抓");
                return;
            }
            LinkBox.Text = bvid;
            await ParseLinkAsync(bvid);
        }
        catch (Exception ex)
        {
            SetStatus("读页面失败：" + ex.Message);
        }
    }

    /// <summary>从脚本返回值里抠 BV 号；抠不到回 null（**绝不猜**）。</summary>
    public static string? ExtractBvid(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return null;
        var m = System.Text.RegularExpressions.Regex.Match(raw!, "BV[1-9A-HJ-NP-Za-km-z]{10}");
        return m.Success ? m.Value : null;
    }

    /// <summary>
    /// ExecuteScriptAsync 返回的是 **JSON 编码过的字符串**（带外层引号与转义）。
    /// 直接当文本用会全是反斜杠转义 —— 必须先按 JSON 字符串解一次。
    /// </summary>
    public static string UnquoteJsString(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return "";
        var t = raw!.Trim();
        if (t.Length < 2 || t[0] != (char)34) return t;
        try { return System.Text.Json.JsonSerializer.Deserialize<string>(t) ?? ""; }
        catch { return t; }
    }

    // ── 解析 ────────────────────────────────────────────────

    private async void OnLinkKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) await ParseLinkAsync(LinkBox.Text?.Trim() ?? "");
    }

    private async void OnParseClick(object sender, RoutedEventArgs e) => await ParseLinkAsync(LinkBox.Text?.Trim() ?? "");

    private async Task ParseLinkAsync(string raw)
    {
        if (raw.Length == 0)
        {
            SetStatus("把 B 站稿件链接或 BV 号粘进来再解析");
            return;
        }
        SetStatus("正在解析…");
        try
        {
            Cfg.Load();
            _api ??= new BiliApi(Cfg.EffectiveCookie);
            _saveDir = Cfg.ResolvedSaveDir;

            var refInfo = await ResolveRefAsync(raw);
            if (refInfo is null)
            {
                SetStatus("认不出这条链接：" + raw + "（支持 BV/av 号、完整视频链接、b23.tv 短链）");
                return;
            }
            if (refInfo.IsList || refInfo.Mid is not null)
            {
                SetStatus("这是列表类链接（合集 / 系列 / 收藏夹 / UP 主空间）—— " +
                          "请到「批量下载」页，那里能一行一条粘进来批量入队。");
                return;
            }

            var info = await _api.GetVideoInfoAsync(refInfo.Bvid, refInfo.Aid);
            if (info.Pages.Count == 0)
            {
                SetStatus("这个稿件没有可下载的分 P（已下架或仅自己可见）");
                return;
            }
            _info = info;
            _ref = refInfo;
            RenderResult(info, refInfo);
            SetStatus("");
        }
        catch (Exception ex)
        {
            SetStatus("解析失败：" + ex.Message);
        }
    }

    /// <summary>把用户输入解析成 BiliRef（短链跟一次重定向）。</summary>
    private async Task<BiliRef?> ResolveRefAsync(string raw)
    {
        var target = raw;
        if (BiliLink.IsShortLink(raw))
        {
            try
            {
                using var http = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(15) };
                var resp = await http.GetAsync(raw.StartsWith("http") ? raw : "https://" + raw);
                target = resp.RequestMessage?.RequestUri?.ToString() ?? raw;
            }
            catch { }
        }
        return BiliLink.Parse(target);
    }

    // ── 抓取结果列表（照原项目浮层结构）──────────────────────

    private void RenderResult(BiliVideoInfo info, BiliRef refInfo)
    {
        ResultHost.Children.Clear();
        _rows.Clear();
        EmptyState.Visibility = Visibility.Collapsed;

        // 顶部：「抓取结果 N 个作品」+「已选 0」+ 关闭
        var head = new Grid { Margin = new Thickness(0, 0, 0, 4) };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var headLeft = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        headLeft.Children.Add(new FontIcon { Glyph = "\uE7F4", FontSize = 13, Opacity = 0.8 });
        headLeft.Children.Add(new TextBlock
        {
            Text = "抓取结果 " + info.Pages.Count + " 个作品", FontSize = 13.5,
            FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center,
        });
        head.Children.Add(headLeft);

        var selectedText = new TextBlock
        {
            Text = "已选 0", FontSize = 12, Opacity = 0.7,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(selectedText, 1);
        selectedText.HorizontalAlignment = HorizontalAlignment.Center;
        head.Children.Add(selectedText);

        var closeBtn = new Button
        {
            Content = "\uE711", FontFamily = new FontFamily("Segoe Fluent Icons"),
            FontSize = 12, Width = 30, Height = 28, Padding = new Thickness(0),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(closeBtn, "关闭抓取结果");
        closeBtn.Click += (_, _) =>
        {
            ResultHost.Children.Clear();
            _rows.Clear();
            _info = null;
            EmptyState.Visibility = Visibility.Visible;
            UpdateCapText();
        };
        Grid.SetColumn(closeBtn, 2);
        head.Children.Add(closeBtn);
        ResultHost.Children.Add(head);

        // 每一行 = 一个分P（原项目按「稿件 → 分P」两级；单 P 稿件只有一行）
        foreach (var part in info.Pages)
        {
            var row = BuildPartRow(info, part, selectedText);
            _rows.Add((part, (CheckBox)row.Tag, row));
            ResultHost.Children.Add(row);
        }

        UpdateCapText();
        UpdateSelected(selectedText);
    }

    /// <summary>
    /// 一条分 P 的行 —— **四行结构**（照原项目抓取结果那张浮层）：
    ///  ① 勾选框 + 封面缩略图；
    ///  ② 类型标签「视频」+ 标题（可多行）；
    ///  ③ 话题/标签文字（B 站这里是 UP 主 + 分P名）；
    ///  ④ 统计行（播放 / 点赞 / 评论 / 收藏 / 分享 + 投稿时间）；
    ///  右上角一个展开箭头，展开后是详情（时长 / CID / 候选清晰度）。
    /// </summary>
    private Border BuildPartRow(BiliVideoInfo info, BiliPart part, TextBlock selectedText)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var box = new CheckBox { IsChecked = true, VerticalAlignment = VerticalAlignment.Top };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, "选择 " + part.Title);
        box.Checked += (_, _) => UpdateSelected(selectedText);
        box.Unchecked += (_, _) => UpdateSelected(selectedText);
        grid.Children.Add(box);

        // 左侧：封面缩略图（约 100x70）
        var cover = new Border
        {
            Width = 100, Height = 70, CornerRadius = new CornerRadius(6),
            Margin = new Thickness(8, 2, 0, 0),
            Background = (Brush)Application.Current.Resources["ControlFillColorSecondaryBrush"],
            VerticalAlignment = VerticalAlignment.Top,
            Child = new Image { Stretch = Stretch.UniformToFill },
        };
        if (!string.IsNullOrEmpty(info.Cover))
        {
            try
            {
                if (cover.Child is Image img)
                    img.Source = new BitmapImage(new Uri(info.Cover + "@.jpg")) { DecodePixelWidth = 200 };
            }
            catch { }
        }
        var coverCell = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
        coverCell.Children.Add(cover);

        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        left.Children.Add(box);
        left.Children.Add(cover);
        Grid.SetColumn(left, 0);
        grid.Children.Remove(box);
        grid.Children.Add(left);

        // 中：四行文本
        var texts = new StackPanel { Spacing = 3 };

        // ② 类型标签 + 标题
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        titleRow.Children.Add(new Border
        {
            Background = UiKit.AccentFill, CornerRadius = new CornerRadius(3),
            Padding = new Thickness(5, 1, 5, 1),
            VerticalAlignment = VerticalAlignment.Top,
            Child = new TextBlock
            {
                Text = part.Page > 0 && info.Pages.Count > 1 ? ("P" + part.Page) : "视频",
                FontSize = 10.5, Foreground = UiKit.OnAccentText,
            },
        });
        titleRow.Children.Add(new TextBlock
        {
            Text = part.Title, FontSize = 13, TextWrapping = TextWrapping.Wrap,
        });
        texts.Children.Add(titleRow);

        // ③ 话题 / 标签行（UP 主 + 稿件标题 + 分区）
        var tagLine = new StringBuilder2();
        tagLine.Add(info.Title);
        if (!string.IsNullOrEmpty(info.Tname)) tagLine.Add(info.Tname);
        texts.Children.Add(new TextBlock
        {
            Text = tagLine.ToString(), FontSize = 11.5, Opacity = 0.55,
            TextWrapping = TextWrapping.Wrap, MaxLines = 2,
        });

        // ④ 统计行
        var stat = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        stat.Children.Add(StatItem("\uEB51", FormatCount(info.LikeCount)));      // 点赞
        stat.Children.Add(StatItem("\uE8AC", FormatCount(info.ReplyCount)));     // 评论
        stat.Children.Add(StatItem("\uE735", FormatCount(info.FavCount)));       // 收藏
        stat.Children.Add(StatItem("\uE72A", FormatCount(info.ShareCount)));     // 分享
        stat.Children.Add(StatItem("\uE7C1", FormatCount(info.ViewCount)));      // 播放
        texts.Children.Add(stat);

        var meta = new TextBlock
        {
            Text = "UP：" + info.OwnerName + "　" + FormatTime(info.PubDateUnix) +
                   "　时长 " + FormatDuration(part.DurationSec),
            FontSize = 11, Opacity = 0.5, TextWrapping = TextWrapping.Wrap,
        };
        texts.Children.Add(meta);

        // 展开后的详情（默认收起）——照原项目的箭头
        var detail = new StackPanel
        {
            Spacing = 2, Visibility = Visibility.Collapsed,
            Margin = new Thickness(0, 4, 0, 0),
        };
        detail.Children.Add(new TextBlock
        {
            Text = "BV：" + info.Bvid + "　CID：" + (part.Cid ?? "—") +
                   "　稿件时长 " + FormatDuration(info.DurationSec),
            FontSize = 11, Opacity = 0.6, TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        detail.Children.Add(new TextBlock
        {
            Text = "画质上限：" + BiliConfig.LabelOf(Cfg.Quality) + "　编码偏好：" + Cfg.Codec +
                   "　容器：" + BiliConfig.IdOf(Cfg.Container).ToUpperInvariant(),
            FontSize = 11, Opacity = 0.6, TextWrapping = TextWrapping.Wrap,
        });
        detail.Children.Add(new TextBlock
        {
            Text = "实际档位要等点下载那条请求回来才知道（B 站按账号权限裁档）",
            FontSize = 11, Opacity = 0.5, TextWrapping = TextWrapping.Wrap,
        });
        texts.Children.Add(detail);

        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);

        // 右：展开箭头
        var expand = new Button
        {
            Content = "\uE70D", FontFamily = new FontFamily("Segoe Fluent Icons"),
            FontSize = 11, Width = 30, Height = 26, Padding = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Top,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(expand, "展开详情");
        expand.Click += (_, _) =>
        {
            var open = detail.Visibility == Visibility.Visible;
            detail.Visibility = open ? Visibility.Collapsed : Visibility.Visible;
            expand.Content = open ? "\uE70D" : "\uE70E";
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
                expand, open ? "展开详情" : "收起详情");
        };
        Grid.SetColumn(expand, 2);
        grid.Children.Add(expand);

        var border = new Border
        {
            Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
            BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8, 8, 6, 8),
            Child = grid,
            Tag = box,
        };
        return border;
    }

    private static UIElement StatItem(string glyph, string text)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3 };
        s.Children.Add(new FontIcon { Glyph = glyph, FontSize = 10.5, Opacity = 0.6 });
        s.Children.Add(new TextBlock { Text = text, FontSize = 11, Opacity = 0.7 });
        return s;
    }

    private void UpdateSelected(TextBlock label)
    {
        var n = _rows.Count(r => r.Box.IsChecked == true);
        label.Text = "已选 " + n;
        DownloadButton.Content = n > 0
            ? ("下载全部（" + n + "）")
            : "下载全部（0）";
        DownloadButton.IsEnabled = n > 0;
        UpdateCapText();
    }

    private void UpdateCapText()
    {
        CapText.Text = "上限 " + BiliConfig.LabelOf(Cfg.Quality);
    }

    // ── 全选 / 全不选 / 下载 ────────────────────────────────

    private void OnSelectAllClick(object sender, RoutedEventArgs e)
    {
        foreach (var (_, box, _) in _rows) box.IsChecked = true;
    }

    private void OnSelectNoneClick(object sender, RoutedEventArgs e)
    {
        foreach (var (_, box, _) in _rows) box.IsChecked = false;
    }

    private async void OnDownloadClick(object sender, RoutedEventArgs e) => await DownloadSelectedAsync();

    /// <summary>
    /// 下载选中的分 P：逐条取播放地址 → 两条流按契约命名入队 → 落附加文件。
    /// **必须节流**（每条之间等 RequestIntervalMs）：连着打 playurl 会被风控。
    /// </summary>
    private async Task DownloadSelectedAsync()
    {
        // **两种模式**（2026-10-30 支持「抓当前页」直接列出多稿件）：
        //
        //  ① 单稿件模式（_info 有值）：列表是这条稿件的分 P，直接用它的 Bvid/Aid。
        //  ② 多稿件模式（_info 为 null、_pageBvids 有值）：列表每行是**一个稿件**，
        //     每行自己的 BV 号存在 Part.Title 里，取流前要先按它查一次分 P 详情。
        var multi = _info is null;
        var chosen = _rows.Where(r => r.Box.IsChecked == true).Select(r => r.Part).ToList();
        if (chosen.Count == 0)
        {
            SetStatus(multi ? "没有勾选任何作品" : "没有勾选任何分 P");
            return;
        }

        DownloadButton.IsEnabled = false;
        var api = _api ??= new BiliApi(Cfg.EffectiveCookie);
        var saveDir = Cfg.ResolvedSaveDir;
        var interval = Math.Max(300, Cfg.RequestIntervalMs);
        var ok = 0; var fail = 0;
        var failures = new List<string>();

        for (var i = 0; i < chosen.Count; i++)
        {
            var part = chosen[i];
            // 提到 try 外面：catch 里报错也要用它的名字
            var realPart = part;
            SetStatus("正在入队 " + (i + 1) + "/" + chosen.Count + "：" + part.Title);
            try
            {
                // 多稿件模式：这一行是一个稿件，先用它的 BV 号查分 P 详情
                BiliVideoInfo info;
                if (multi)
                {
                    var bv = part.Title;
                    var got = await api.GetVideoInfoAsync(bv, null);
                    if (got.Pages.Count == 0)
                    {
                        fail++; failures.Add(bv + "：取不到分 P（已下架或仅自己可见）"); continue;
                    }
                    info = got;
                    realPart = got.Pages[0];
                }
                else
                {
                    info = _info!;
                }

                if (realPart.Cid is not string cidStr || !long.TryParse(cidStr, out var cid))
                {
                    fail++; failures.Add(realPart.Title + "：没有 cid"); continue;
                }

                var play = await api.GetPlayInfoAsync(
                    info.Bvid, cid, BiliConfig.QnOf(Cfg.Quality), info.Aid);
                var pair = BiliDownloadPlan.Plan(play, Cfg.Quality, Cfg.Codec);
                if (!pair.Usable)
                {
                    fail++;
                    failures.Add(realPart.Title + "：" + (pair.Message ?? "取不到可下载的流"));
                    continue;
                }

                var outBase = BuildOutBase(info, realPart, pair, play);
                var partDir = BiliEnqueue.ResolveSaveDir(Cfg, saveDir, info, realPart, pair, play);
                System.IO.Directory.CreateDirectory(partDir);

                var videoName = pair.IsDash
                    ? BiliDownloadPlan.VideoStreamName(outBase)
                    : BiliDownloadPlan.MergedName(outBase, Cfg.Container);
                var (a, msg) = await DownloadStore.Instance.AddAsync(
                    pair.Video!.Url, "B 站", partDir, videoName);
                if (!a) { fail++; failures.Add(realPart.Title + "：" + msg); continue; }

                if (pair.IsDash && pair.Audio is not null)
                {
                    var (a2, msg2) = await DownloadStore.Instance.AddAsync(
                        pair.Audio.Url, "B 站（音频）", partDir,
                        BiliDownloadPlan.AudioStreamName(outBase));
                    if (!a2)
                    {
                        fail++;
                        failures.Add(realPart.Title + "：音频入队失败（" + msg2 + "）");
                        continue;
                    }
                }

                // 附加文件（弹幕/字幕/封面/章节/元数据）——失败只记「没拿到」，不影响主产物
                try
                {
                    await BiliAdditionalRunner.ProduceAsync(
                        new BiliApi(Cfg.EffectiveCookie), Cfg, partDir, outBase, info, cid,
                        part.Title, part.Page);
                }
                catch { }

                ok++;
            }
            catch (Exception ex)
            {
                fail++;
                failures.Add(realPart.Title + "：" + ex.Message);
            }
            if (i < chosen.Count - 1) await Task.Delay(interval);
        }

        var sb = new StringBuilder2();
        sb.Add("入队完成：成功 " + ok + "，失败 " + fail);
        var text = sb.ToString();
        if (failures.Count > 0)
        {
            text += "\n" + string.Join("\n", failures.Take(5));
        }
        SetStatus(text);
        DownloadButton.IsEnabled = true;
        UpdateSelected(new TextBlock());
        foreach (var (_, box, _) in _rows) { }
        RefreshSelectedLabel();
    }

    /// <summary>重新算「已选 N」（下载完不做取消勾选，只刷新数字）。</summary>
    private void RefreshSelectedLabel()
    {
        var head = ResultHost.Children.OfType<Grid>().FirstOrDefault();
        if (head is null) return;
        var label = head.Children.OfType<TextBlock>().FirstOrDefault();
        if (label is null) return;
        var n = _rows.Count(r => r.Box.IsChecked == true);
        label.Text = "已选 " + n;
        DownloadButton.Content = "下载全部（" + n + "）";
    }

    /// <summary>按 B 站模板算 base 名（不含扩展名）——两条流与合并产物共用它。</summary>
    private string BuildOutBase(BiliVideoInfo info, BiliPart part, BiliStreamPair pair, BiliPlayInfo play)
    {
        var ctx = BuildCtx(info, part, pair, play, ".mp4");
        var rendered = BiliTemplate.Sanitize(BiliTemplate.Render(Cfg.EffectiveFileNameTemplate, ctx));
        if (rendered.Length == 0) rendered = info.Bvid + "-P" + part.Page;
        return BiliDownloadPlan.BaseNameFromFileName(rendered);
    }

    private static BiliTemplate.Context BuildCtx(
        BiliVideoInfo info, BiliPart part, BiliStreamPair pair, BiliPlayInfo play, string ext)
    {
        var quality = BiliApi.QualityNames.TryGetValue(pair.VideoQn, out var q) ? q : "";
        if (quality.Length == 0 && pair.Video is not null) quality = pair.Video.QualityLabel;
        return new BiliTemplate.Context
        {
            WorkTitle = info.Title,
            PartTitle = part.Title,
            Part = info.Pages.Count > 1 ? part.Page : 0,
            PartTotal = info.Pages.Count,
            Bvid = info.Bvid,
            Aid = info.Aid,
            Cid = long.TryParse(part.Cid, out var c) ? c : 0,
            UpName = info.OwnerName,
            UpMid = info.OwnerMid,
            Quality = quality,
            Codec = pair.VideoCodec,
            CustomText = BiliConfig.Instance.CustomText,
            DurationSec = part.DurationSec,
            Ext = ext,
        };
    }

    private void SetStatus(string text)
    {
        if (StatusText is null) return;
        StatusText.Text = text;
        StatusText.Visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    // ── 小工具 ──────────────────────────────────────────────

    private static string FormatCount(long n)
    {
        if (n <= 0) return "0";
        if (n >= 100_000_000) return (n / 100_000_000.0).ToString("0.#") + "亿";
        if (n >= 10_000) return (n / 10_000.0).ToString("0.#") + "万";
        return n.ToString();
    }

    private static string FormatTime(long unix)
    {
        if (unix <= 0) return "";
        return DateTimeOffset.FromUnixTimeSeconds(unix).LocalDateTime
            .ToString("yyyy-MM-dd HH:mm:ss");
    }

    private static string FormatDuration(int sec)
    {
        if (sec <= 0) return "—";
        var h = sec / 3600; var m = sec % 3600 / 60; var s = sec % 60;
        return h > 0
            ? h + ":" + m.ToString("D2") + ":" + s.ToString("D2")
            : m + ":" + s.ToString("D2");
    }
}

/// <summary>
/// 极小的字符串拼装助手 —— 只为避免到处写 string.Join/TrimEnd 的噪声。
/// 内部就是 List + Join，不存在隐藏状态。
/// </summary>
internal sealed class StringBuilder2
{
    private readonly List<string> _parts = new();
    public void Add(string? s) { if (!string.IsNullOrWhiteSpace(s)) _parts.Add(s!.Trim()); }
    public override string ToString() => string.Join("　", _parts);
}
