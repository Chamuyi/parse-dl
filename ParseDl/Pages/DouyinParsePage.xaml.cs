using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.Douyin;

namespace ParseDl.Pages;

/// <summary>
/// 抖音解析下载页 —— 对齐 Flutter 版 lib/pages/douyin_page.dart。
///
/// 结构：左边内嵌浏览器（WebView2）+ 注入拦截脚本，右边下载选项 + **方格缩略图**
/// 抓取结果（对齐原项目形态：一格一个作品，点击放大）。
/// 抓取不靠读 HTML，而靠拦截脚本抄页面自己的 XHR/fetch 响应，并且只认
/// **页面真渲染成卡片**的那些作品（见 Services/Douyin/DouyinInterceptor.cs）。
///
/// 自适应策略（2026-10-25 用户投诉「右栏被截断」）：
///   · BodyGrid 按**实际宽度**切换布局 —— &gt;= 820 逻辑像素时左右两栏（各 *，右栏
///     MinWidth 380）；&lt; 820 时改成上下两行（浏览器在上、抓取面板在下），
///     于是右栏内容永远不会被窗口右边界裁掉；
///   · 右栏两列都是星号宽度，跟随窗口比例伸缩，不用固定像素；
///   · 面板内两个下拉用同一套网格（标签列固定 88 + 控件列 *、同高 32）→ 等宽等高同基线；
///   · 操作按钮排是自写的 DouyinWrapPanel，放不下就换行，不会横向溢出。
/// </summary>
public sealed partial class DouyinParsePage : Page
{
    /// <summary>左右两栏布局所需的最小正文宽度（逻辑像素）。低于它就改成上下两行。</summary>
    private const double TwoPaneMinWidth = 820;

    /// <summary>缩略图格子边长（逻辑像素）。</summary>
    private const double TileSize = 104;

    /// <summary>选项区标签列宽度 —— 两个下拉共用它，保证等宽等高同基线。</summary>
    private const double OptionLabelWidth = 76;

    /// <summary>下拉框统一高度。</summary>
    private const double OptionControlHeight = 28;

    private readonly DouyinStore _store = DouyinStore.Instance;
    private bool _ready;
    private bool _loading;
    private bool? _wideLayout;
    private DouyinAutoScroller? _autoScroller;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _autoTimer;
    private bool _suppressOptionEvents;
    /// <summary>详情浮层是否已打开（ContentDialog 不能同时弹两个）。</summary>
    private bool _detailOpen;
    /// <summary>点勾选圈后的短暂抑制窗口 —— 免得同一次点击又弹出预览。</summary>
    private DateTime _suppressTileClickUntil;

    public DouyinParsePage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        HeaderHost.Children.Add(UiKit.PageHeader("抖音解析下载",
            "打开抖音页面 → 抓取作品 → 筛选勾选 → 批量下载（需先登录）", "\uE768"));

        _store.Changed += OnStoreChanged;
        _store.Ledger.Load();
        UrlBox.Text = string.IsNullOrEmpty(_store.LastUrl) ? DouyinUrl.HomeUrl : _store.LastUrl;
        BuildActionBar();
        BuildOptionBar();
        ApplyLayout(BodyGrid.ActualWidth);
        RefreshList();
        _ = InitWebAsync();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _store.Changed -= OnStoreChanged;
        StopAutoScroll();
    }

    // ── 自适应布局 ──────────────────────────────────────────────

    private void OnBodyGridSizeChanged(object sender, SizeChangedEventArgs e)
        => ApplyLayout(e.NewSize.Width);

    /// <summary>
    /// 按实际宽度在「左右两栏」与「上下两行」之间切换。
    /// 只在跨越阈值时重排，避免拖动窗口时每帧都改一遍集合。
    /// </summary>
    private void ApplyLayout(double width)
    {
        if (width <= 0) return;
        var wide = width >= TwoPaneMinWidth;
        if (_wideLayout is not null && _wideLayout.Value == wide) return;
        _wideLayout = wide;

        BodyGrid.ColumnDefinitions.Clear();
        BodyGrid.RowDefinitions.Clear();

        if (wide)
        {
            // **左右 3:2**（用户 2026-10-26：「Web 有点小，右侧抓取太大了」）。
            // 原来这里是 1:1 —— 抖音网页在窄栏里只露出中间一小块，而右栏选项区
            // 本来就撑不满、留白多。左边是干活主区，右边只是选项 + 结果网格。
            // 注意：这段在**代码**里，XAML 里改列宽会被这里覆盖（踩过一次）。
            BodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3, GridUnitType.Star) });
            BodyGrid.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(2, GridUnitType.Star),
                MinWidth = 380,
            });
            BodyGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

            Grid.SetRow(BrowserCard, 0);
            Grid.SetColumn(BrowserCard, 0);
            Grid.SetRow(CaptureCard, 0);
            Grid.SetColumn(CaptureCard, 1);
        }
        else
        {
            BodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            // 浏览器约 29%、抓取面板约 71% —— 抓取面板里有 6 行选项 + 按钮排 + 网格，
            // 给少了网格会被挤成一条缝（面板是用户真正要看的那个）
            BodyGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(2, GridUnitType.Star) });
            BodyGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(5, GridUnitType.Star) });

            Grid.SetRow(BrowserCard, 0);
            Grid.SetColumn(BrowserCard, 0);
            Grid.SetRow(CaptureCard, 1);
            Grid.SetColumn(CaptureCard, 0);
        }
    }

    // ── 内嵌浏览器 ──────────────────────────────────────────────

    private async Task InitWebAsync()
    {
        try
        {
            await Web.EnsureCoreWebView2Async();
            // 让页面里的 target=_blank / window.open 在**当前 WebView 内**打开，
            // 而不是弹系统浏览器（用户 2026-10-27 报 B 站点视频会开新窗口）。
            ParseDl.Controls.WebViewHelper.KeepNavigationInPlace(Web.CoreWebView2);

            var core = Web.CoreWebView2;
            core.Settings.UserAgent =
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
            core.Settings.IsStatusBarEnabled = false;

            // 注册一次即对之后所有文档生效（含 SPA 内部跳转后的新文档）
            await core.AddScriptToExecuteOnDocumentCreatedAsync(DouyinInterceptor.Script);

            core.WebMessageReceived += OnWebMessage;

            core.NavigationStarting += (_, args) =>
            {
                _loading = true;
                UrlBox.Text = args.Uri ?? UrlBox.Text;
                StatusText.Text = "正在打开 " + args.Uri + " …";
            };

            core.NavigationCompleted += (_, args) =>
            {
                _loading = false;
                UrlBox.Text = core.Source;
                // 换页即刻换「结果分组」：列表里只会是当前页面的内容
                _store.SetCurrentUrl(core.Source);
                StatusText.Text = args.IsSuccess
                    ? "页面已加载。登录后滚动到目标内容，作品会自动出现在右侧。"
                    : "页面加载失败：" + args.WebErrorStatus;
                WebPlaceholder.Visibility = Visibility.Collapsed;
            };

            _ready = true;
            WebPlaceholder.Visibility = Visibility.Collapsed;
            StatusText.Text = "首次使用请先登录，登录态保存在 WebView2 数据目录里，之后不用重复登录。";
            core.Navigate(UrlBox.Text);
        }
        catch (Exception ex)
        {
            WebPlaceholder.Text = "WebView2 初始化失败：" + ex.Message +
                "（若为打包应用，需要 WebView2 框架包依赖）";
            StatusText.Text = WebPlaceholder.Text;
        }
    }

    /// <summary>
    /// 拦截脚本回传的载荷 → 结果仓库。
    /// 载荷形状见 DouyinPayloadParser：{__pd:'douyin', items:[...]}。
    /// </summary>
    private void OnWebMessage(object? sender, Microsoft.Web.WebView2.Core.CoreWebView2WebMessageReceivedEventArgs e)
    {
        // 拦截脚本 postMessage 传的是**对象**，不是字符串 —— 这时
        // TryGetWebMessageAsString() 会抛异常（它只对字符串载荷有效），
        // 必须用 WebMessageAsJson 取，拿到的正是那段 JSON。
        string payload;
        try { payload = e.WebMessageAsJson; }
        catch { return; }
        if (string.IsNullOrEmpty(payload)) return;

        // ── 诊断用：把拦截到的原始载荷落盘（只在设了环境变量 PARSE_DL_DUMP_PAYLOAD 时开）
        // 用途：排查「实况图下不来」这类问题 → 必须看真实 images[].video 有没有值。
        // 正常使用不写盘，不影响性能。
        try
        {
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("PARSE_DL_DUMP_PAYLOAD")))
            {
                var dumpDir = System.IO.Path.Combine(AppPaths.DataDir, "payload_dump");
                System.IO.Directory.CreateDirectory(dumpDir);
                var f = System.IO.Path.Combine(dumpDir, DateTime.Now.ToString("HHmmss_fff") + ".json");
                System.IO.File.WriteAllText(f, payload);
            }
        }
        catch { }

        var result = DouyinPayloadParser.Parse(payload);
        if (result.Media.Count == 0) return;

        var added = _store.Ingest(result.Media);
        if (added > 0)
        {
            StatusText.Text = "页面出现 " + result.AwemeCount + " 条作品 / 新增 " + added +
                " 个媒体（累计 " + _store.Count + "）";
        }
    }

    private void OnBackClick(object sender, RoutedEventArgs e)
    {
        if (_ready && Web.CoreWebView2.CanGoBack) Web.CoreWebView2.GoBack();
    }

    private void OnForwardClick(object sender, RoutedEventArgs e)
    {
        if (_ready && Web.CoreWebView2.CanGoForward) Web.CoreWebView2.GoForward();
    }

    private void OnReloadClick(object sender, RoutedEventArgs e)
    {
        if (_ready) Web.CoreWebView2.Reload();
    }

    private void OnHomeClick(object sender, RoutedEventArgs e) => Navigate(DouyinUrl.HomeUrl);

    private void OnGoClick(object sender, RoutedEventArgs e) => Navigate(UrlBox.Text);

    private void OnUrlKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) Navigate(UrlBox.Text);
    }

    private void Navigate(string? raw)
    {
        if (!_ready) { StatusText.Text = "内嵌浏览器还没就绪，请稍后再试。"; return; }
        // 与「自动下载」的目标解析共用同一套判断 —— 分享口令也能直接粘进来
        var target = DouyinUrl.Normalize(raw) ?? (raw ?? "").Trim();
        if (target.Length == 0) return;
        try { Web.CoreWebView2.Navigate(target); }
        catch (Exception ex) { StatusText.Text = "打开这个地址失败：" + ex.Message; }
    }

    /// <summary>诊断：确认拦截脚本挂上没、捞了多少条。</summary>
    private async void OnDiagnoseClick(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        try
        {
            var raw = await Web.CoreWebView2.ExecuteScriptAsync(
                "JSON.stringify(window.__pdDouyinInfo ? window.__pdDouyinInfo() : {hooked:false})");
            var text = DouyinAutoScrollReport.UnquoteJsonString(raw);
            StatusText.Text = "拦截脚本状态：" + text;
        }
        catch (Exception ex)
        {
            StatusText.Text = "诊断失败：" + ex.Message;
        }
    }

    // ── 自动加载（滚动到底让抖音吐下一页）────────────────────────

    private void OnAutoScrollClick(object sender, RoutedEventArgs e)
    {
        if (_autoScroller is not null && _autoScroller.Running) { StopAutoScroll(); return; }
        if (!_ready) { StatusText.Text = "内嵌浏览器还没就绪。"; return; }

        var cfg = DouyinSettings.Current;
        _autoScroller = new DouyinAutoScroller(
            maxRounds: cfg.MaxRounds,
            stallLimit: cfg.StallLimit,
            interval: TimeSpan.FromMilliseconds(Math.Max(200, cfg.ScrollIntervalMs)));
        _autoScroller.Start();
        SetAutoScrollVisual(true);

        _autoTimer = DispatcherQueue.CreateTimer();
        _autoTimer.Interval = _autoScroller.Interval;
        _autoTimer.Tick += async (_, _) => await AutoScrollTickAsync();
        _autoTimer.Start();
    }

    private void StopAutoScroll()
    {
        _autoTimer?.Stop();
        _autoTimer = null;
        _autoScroller?.Stop(DouyinAutoScrollStop.Stopped);
        _autoScroller = null;
        SetAutoScrollVisual(false);
    }

    /// <summary>
    /// 自动加载按钮的**图标状态**（2026-10-30 图标化后不再改文字）。
    /// 运行中：方块「停止」图标 + 强调色；空闲：方框内下滚图标 + 普通色。
    /// 悬停提示同步换，否则图标改了但提示还写着「自动加载」。
    /// </summary>
    private void SetAutoScrollVisual(bool running)
    {
        if (AutoScrollIcon is null) return;
        // E896 = 方块（停止）；E72D = 方框内下滚（与「下载」区分）
        AutoScrollIcon.Glyph = running ? "\uE896" : "\uE72D";
        AutoScrollButton.Foreground = running
            ? (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"]
            : (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorPrimaryBrush"];
        ToolTipService.SetToolTip(AutoScrollButton,
            running ? "停止自动加载" : "自动加载（持续下滚抓取）");
    }

    private async Task AutoScrollTickAsync()
    {
        var scroller = _autoScroller;
        if (scroller is null || !scroller.Running || !_ready) { StopAutoScroll(); return; }

        // 页面还在加载时先不滚：这时滚到的 scrollHeight 是半成品，
        // 状态机会把它误判成「没长高」并提前收工。
        if (_loading)
        {
            StatusText.Text = "自动加载：等页面加载完成…";
            return;
        }

        try
        {
            var raw = await Web.CoreWebView2.ExecuteScriptAsync(DouyinScripts.AutoScroll);
            var report = DouyinAutoScrollReport.Decode(raw);
            var more = scroller.OnRoundResult(report.ScrollHeight);
            StatusText.Text = "自动加载：" + scroller.Describe +
                "（滚动容器 " + (report.Hit.Length == 0 ? "?" : report.Hit) +
                "，页面高 " + report.ScrollHeight + "px，已收集 " + _store.Count + " 条）";

            if (!more)
            {
                var reason = scroller.StopReason;
                var label = reason is null ? "" : DouyinAutoScrollLabel(reason.Value);
                StopAutoScroll();
                StatusText.Text = "自动加载结束：" + label + "，共 " + _store.Count + " 条媒体。";
            }
        }
        catch (Exception ex)
        {
            StopAutoScroll();
            StatusText.Text = "自动加载出错停止：" + ex.Message;
        }
    }

    private static string DouyinAutoScrollLabel(DouyinAutoScrollStop r) => r switch
    {
        DouyinAutoScrollStop.Stopped => "已手动停止",
        DouyinAutoScrollStop.ReachedMaxRounds => "已达本次滚动上限",
        DouyinAutoScrollStop.NoGrowth => "已到底（没有更多内容）",
        _ => "出错停止",
    };

    // ── 下载选项（对齐参照实现「下载设置」）────────────────────────

    /// <summary>
    /// 下载源 / 质量策略 / 图片格式 + 三个开关。
    ///
    /// **两个下拉必须同宽同高同基线**（用户 2026-10-25 明确投诉「上面两个框怎么
    /// 大小不一致」）：都走同一个 <see cref="OptionRow"/> —— 标签列固定 88px、
    /// 控件列吃满剩余宽度、控件高度统一 32px。所以「下载源」和「图片格式」的框
    /// 尺寸完全一致，不会一个高一个矮。
    ///
    /// 开关按用户 2026-09-30 的约定**与标题同行且距离 ≤24px**（不推到行尾）。
    /// </summary>
    private void BuildOptionBar()
    {
        var cfg = DouyinSettings.Current;
        _suppressOptionEvents = true;
        // OptionHost 现在是 Grid（XAML 里改的）—— 必须逐行累加，否则所有子元素
        // 都落在 Row 0 上、互相叠住。原先是 StackPanel，只要 Add 就行。
        OptionHost.Children.Clear();
        OptionHost.RowDefinitions.Clear();
        void AddOption(FrameworkElement child)
        {
            OptionHost.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(child, OptionHost.RowDefinitions.Count - 1);
            OptionHost.Children.Add(child);
        }
        // **开关收成两列**（2026-10-29 用户要求「紧凑一点，让下面预览露出来」）：
        // 原来 5 个开关各占一整行，加上 3 个下拉一共 8 行，把下面的缩略图网格挤得只剩一条缝。
        var _toggles = new List<FrameworkElement>();

        var sourceCombo = new ComboBox
        {
            Height = OptionControlHeight,
            Padding = new Thickness(10, 0, 4, 0),   // 收紧内边距，给文字腾宽度
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            MinWidth = 0,
        };
        // 每一项也带 ToolTip —— 展开列表时也能看到完整说明
        // （ComboBoxItem 的内容就是短标签，长文本靠这里补全）
        foreach (var s in Enum.GetValues<DouyinSource>())
        {
            var it = new ComboBoxItem { Content = s.Label() };
            ToolTipService.SetToolTip(it, s.Detail());
            sourceCombo.Items.Add(it);
        }
        sourceCombo.SelectedIndex = (int)cfg.Source;
        sourceCombo.SelectionChanged += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.Source = (DouyinSource)Math.Max(0, sourceCombo.SelectedIndex));
            BuildOptionBar();
            RefreshSummary();
        };
        // 悬停显示完整说明（下拉框宽度有限，短标签 + ToolTip 才能既完整又不被截断）
        ToolTipService.SetToolTip(sourceCombo, cfg.Source.Detail());
        sourceCombo.SelectionChanged += (_, _) =>
            ToolTipService.SetToolTip(sourceCombo, cfg.Source.Detail());
        AddOption(OptionRow("下载源", sourceCombo));

        if (cfg.Source.NeedsQualityMode())
        {
            var modeCombo = new ComboBox
            {
                Height = OptionControlHeight,
            Padding = new Thickness(10, 0, 4, 0),   // 收紧内边距，给文字腾宽度
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                MinWidth = 0,
            };
            foreach (var m in Enum.GetValues<DouyinQualityMode>()) modeCombo.Items.Add(m.Label());
            modeCombo.SelectedIndex = (int)cfg.QualityMode;
            modeCombo.SelectionChanged += (_, _) =>
            {
                if (_suppressOptionEvents) return;
                DouyinSettings.Mutate(c => c.QualityMode = (DouyinQualityMode)Math.Max(0, modeCombo.SelectedIndex));
                RefreshSummary();
            };
            AddOption(OptionRow("质量优先", modeCombo));
        }

        var imgCombo = new ComboBox
        {
            Height = OptionControlHeight,
            Padding = new Thickness(10, 0, 4, 0),   // 收紧内边距，给文字腾宽度
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            MinWidth = 0,
        };
        foreach (var f in Enum.GetValues<DouyinImageFormat>()) imgCombo.Items.Add(f.Label());
        imgCombo.SelectedIndex = (int)cfg.ImageFormat;
        imgCombo.SelectionChanged += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.ImageFormat = (DouyinImageFormat)Math.Max(0, imgCombo.SelectedIndex));
        };
        AddOption(OptionRow("图片格式", imgCombo));

        var skipToggle = new ToggleSwitch { MinHeight = 0, OnContent = "", OffContent = "", IsOn = cfg.SkipDownloaded, MinWidth = 0 };
        skipToggle.Toggled += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.SkipDownloaded = skipToggle.IsOn);
            RefreshSummary();
        };
        _toggles.Add(IconToggle("跳过已下载", "\uE8B7", skipToggle, "跳过已下载"));

        var bgmToggle = new ToggleSwitch { MinHeight = 0, OnContent = "", OffContent = "", IsOn = cfg.IncludeBgm, MinWidth = 0 };
        bgmToggle.Toggled += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.IncludeBgm = bgmToggle.IsOn);
        };
        _toggles.Add(IconToggle("BGM", "\uE8D6", bgmToggle, "附带 BGM"));

        var liveToggle = new ToggleSwitch { MinHeight = 0, OnContent = "", OffContent = "", IsOn = cfg.IncludeLivePhoto, MinWidth = 0 };
        liveToggle.Toggled += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.IncludeLivePhoto = liveToggle.IsOn);
        };
        _toggles.Add(IconToggle("配套视频", "\uE714", liveToggle, "下载配套视频"));

        // 「下载配套图片」（用户 2026-10-27：下载配套视频，图片也会一块下载吗）
        // 开：图 + 视频都下；关：只下配对视频、不下静态图。
        // 注意：开了「合成实况图」时静态图是合成原料，会强制保留（见 DouyinStore.Assemble）。
        var liveImgToggle = new ToggleSwitch { MinHeight = 0, OnContent = "", OffContent = "", IsOn = cfg.IncludeLiveImage, MinWidth = 0 };
        liveImgToggle.Toggled += (_, _) =>
        {
            DouyinSettings.Mutate(c => c.IncludeLiveImage = liveImgToggle.IsOn);
        };
        _toggles.Add(IconToggle("配套图片", "\uEB9F", liveImgToggle, "下载配套图片"));

        // 用户 2026-10-27：手机上要能直接看动图（小米动态照片 = 单个 jpg 内嵌 mp4）
        var mpToggle = new ToggleSwitch { MinHeight = 0, OnContent = "", OffContent = "", IsOn = cfg.LivePhotoAsMotionPhoto, MinWidth = 0 };
        mpToggle.Toggled += (_, _) =>
        {
            DouyinSettings.Mutate(c => c.LivePhotoAsMotionPhoto = mpToggle.IsOn);
        };
        _toggles.Add(IconToggle("实况图", "\uE91B", mpToggle, "合成实况图"));

        // **开关收成两列**（2026-10-29 用户要求「紧凑一点，让下面预览露出来」）。
        // 原来 5 个开关各占一整行 + 3 个下拉，一共 8 行，
        // 把下面的缩略图网格挤得只剩一条缝。两列后 5 个开关只占 3 行。
        // **用换行面板，不用等宽两列 Grid**（2026-10-29 用户反馈「按钮截断了」）。
        //
        // 两列 Grid 每列固定占一半宽度，标签一长就被裁：
        // 「下载配套视频」显示成「下载配套视」、「附带 BGM（图文）」少了右括号。
        // DouyinWrapPanel 按**内容实际宽度**排，放不下就换到下一行 —— 标签永远不会被压。
        var toggleWrap = new DouyinWrapPanel { RowGap = 2, ColumnGap = 18, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var t in _toggles) toggleWrap.Children.Add(t);
        AddOption(toggleWrap);

        _suppressOptionEvents = false;
    }

    /// <summary>标签列固定宽 + 控件列吃满剩余 —— 同一套网格保证控件等宽等高同基线。</summary>
    private static Grid OptionRow(string label, FrameworkElement control)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(OptionLabelWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        grid.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 13,
            Opacity = 0.8,
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
        });

        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }

    /// <summary>
    /// **图标 + 短词的开关**（2026-10-30 用户要求「这几个能做图标吗」）。
    ///
    /// 与纯图标按钮不同：这五个是**布尔开关**，图标要同时表达「是什么」和「开/关」。
    /// 纯图标在 470px 右栏里认不出「配套视频」和「配套图片」的区别，
    /// 所以保留 2~4 字短词当语义锚点，图标只负责快速定位。
    ///
    /// 视觉：开 = 强调色描边 + 强调色图标/文字；关 = 普通描边 + 灰色。
    /// 提示：ToolTip 显示完整原名（如「下载配套视频」），弥补短词的信息损失。
    /// </summary>
    private static FrameworkElement IconToggle(string shortLabel, string glyph, ToggleSwitch toggle, string fullLabel)
    {
        var icon = new FontIcon { Glyph = glyph, FontSize = 13 };
        var text = new TextBlock { Text = shortLabel, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        var body = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        body.Children.Add(icon);
        body.Children.Add(text);

        var btn = new Button
        {
            Content = body,
            Padding = new Thickness(8, 2, 9, 2),
            MinWidth = 0,
            MinHeight = 0,
            CornerRadius = new CornerRadius(6),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        ToolTipService.SetToolTip(btn, fullLabel);

        // 开关本体不显示（HideToggle 用的还是原 ToggleSwitch，逻辑零改动）
        void Paint()
        {
            var on = toggle.IsOn;
            var accent = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"];
            var normal = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorPrimaryBrush"];
            var border = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[
                on ? "AccentFillColorDefaultBrush" : "CardStrokeColorDefaultBrush"];
            icon.Foreground = on ? accent : normal;
            text.Foreground = on ? accent : normal;
            text.Opacity = on ? 1.0 : 0.75;
            btn.BorderBrush = border;
            btn.BorderThickness = new Thickness(1);
        }
        Paint();
        toggle.Toggled += (_, _) => Paint();

        // 点按钮 = 翻开关（ToggleSwitch 本身不进可视树，状态仍由它持有）
        btn.Click += (_, _) => toggle.IsOn = !toggle.IsOn;
        return btn;
    }

    /// <summary>开关行：开关紧跟标题（距离 ≤24px，遵循用户 2026-09-30 的约定）。</summary>
    /// <summary>
    /// 开关行：标题 + 开关，**宽度只由内容决定**。
    ///
    /// 用户 2026-09-30 约定开关与标题同行且距离 ≤24px（不推到行尾）。
    ///
    /// **2026-10-29 修「按钮截断了」**：原来这里第三列是 Star（为了撑满整行、
    /// 免得右边一大片空），但开关行现在放进了 DouyinWrapPanel ——
    /// Star 列会把它撑成整行宽，标签反而被挤窄、末尾被裁
    /// （「下载配套视频」显示成「下载配套视」）。
    /// 现在只保留 Auto + Auto 两列，宽度=内容宽度，交给换行面板排布。
    /// </summary>
    private static Grid ToggleRow(string label, ToggleSwitch toggle)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 13,
            Opacity = 0.8,
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.NoWrap,   // 不换行、不被压
        });
        toggle.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(toggle, 1);
        row.Children.Add(toggle);
        return row;
    }

    // ── 操作按钮排（换行，不截断）────────────────────────────────

    /// <summary>
    /// 操作按钮排：**水平定宽按钮组，不换行**（2026-10-30 改）。
    ///
    /// 原先是自写的 DouyinWrapPanel（放不下就换行）。但 ActionHost 现在位于
    /// 合并行左段的 Auto 列里，Auto/StackPanel 在测量阶段传给子元素的是
    /// PositiveInfinity —— 换行面板拿到无穷宽就永远不换行，DesiredSize 撑到
    /// 几百像素，整条右段被推出右栏边界（实测只剩 4 个图标、垃圾桶不见）。
    /// 现在这排本身就是**定宽图标按钮**（5 个约 230px），最窄右栏 380px 也放得下，
    /// 不需要换行能力，改用普通横向 StackPanel 即可。
    /// </summary>
    private void BuildActionBar()
    {
        ActionHost.Children.Clear();

        // **图标化**（2026-10-30 用户要求）：文字按钮换图标 + 悬停提示。
        //
        // **2026-10-30 删重复**（用户：「全选其实做了，而且重复了，有三个，保留第一个」）：
        // 「全选」在本页曾经有三个入口 ——
        //   ① 行首的三态图标 SelectAllButton（未选/半选/全选，点一下切换）
        //   ② 这里的 E73E「全选 / 取消全选」
        //   ③ 这里的 E711「清空勾选」
        // ②③ 与 ① 的语义完全重合（① 本身就能全选也能清空），故删除 ②③，只保留行首 ①。
        // 分组线也随之去掉（勾选类已无成员）：类型选择 | 操作类。
        ActionHost.Children.Add(IconButton("\uE714", "只选视频", OnSelectVideoClick));
        ActionHost.Children.Add(IconButton("\uEB9F", "只选图文", OnSelectImageClick));
        ActionHost.Children.Add(IconSep());
        ActionHost.Children.Add(IconButton("\uE71C", "筛选", OnFilterClick));
        ActionHost.Children.Add(IconButton("\uE74D", "清空结果", OnClearClick));
    }

    /// <summary>
    /// 操作按钮：**纯图标 + 悬停提示**（2026-10-30 用户要求「用图标代替按键」）。
    /// 这些都是瞬时动作，图标是通用符号（勾/叉/播放/图片/漏斗/垃圾桶），不需要文字锚点。
    /// </summary>
    private static Button IconButton(string glyph, string tip, RoutedEventHandler handler)
    {
        var b = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(8, 4, 8, 4),
            CornerRadius = new CornerRadius(5),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(b, tip);
        b.Click += handler;
        return b;
    }

    /// <summary>图标组之间的细分隔线。</summary>
    private static Border IconSep() => new()
    {
        Width = 1,
        Height = 18,
        Margin = new Thickness(3, 0, 3, 0),
        Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
        VerticalAlignment = VerticalAlignment.Center,
    };

    private void OnSelectAllBoxClick(object sender, RoutedEventArgs e)
    {
        // 三态：当前不是「全选」就全选，已经是全选就清空
        // （2026-10-30 从 CheckBox 改成 FontIcon 按钮，故不再回写 SelectAllBox.IsChecked）
        var wantAll = _store.SelectionState != true;
        _store.SetAllSelected(wantAll);
        UpdateSelectAllIcon();
    }

    /// <summary>
    /// 全选按钮：**方格三态**（2026-10-31 用户定稿）。
    ///   未选 E739（空方格）· 半选 E73C（横线方格）· 全选 E73A（打勾方格，强调色）
    /// 点一下由未选变打勾即全选，再点一下勾消失即取消全选。
    /// </summary>
    private void UpdateSelectAllIcon()
    {
        var state = _store.SelectionState;
        SelectAllIcon.Glyph = state == true ? "" : state == null ? "" : "";
        SelectAllIcon.Foreground = state == true
            ? UiKit.AccentFill
            : (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        ToolTipService.SetToolTip(SelectAllButton, state == true ? "取消全选" : "全选");
    }

    private void OnSelectVideoClick(object sender, RoutedEventArgs e) => _store.SelectAllOfType(true);
    private void OnSelectImageClick(object sender, RoutedEventArgs e) => _store.SelectAllOfType(false);
    private void OnClearClick(object sender, RoutedEventArgs e)
    {
        _store.Clear();
        StatusText.Text = "已清空抓取结果（已下载台账不受影响）。";
    }
    private async void OnFilterClick(object sender, RoutedEventArgs e)
    {
        var facets = _store.Facets;
        var current = _store.Filter;

        var panel = new StackPanel { Spacing = 10, MinWidth = 360 };

        var keyword = new TextBox
        {
            Header = "关键词",
            PlaceholderText = "匹配文案 / 作者名 / 标签",
            Text = current.Keyword,
        };
        panel.Children.Add(keyword);

        var dateCombo = new ComboBox { Header = "发布日期", MinWidth = 200 };
        var ranges = Enum.GetValues<DouyinDateRange>();
        foreach (var r in ranges) dateCombo.Items.Add(r.Label());
        dateCombo.SelectedIndex = Array.IndexOf(ranges, current.QuickRange);
        panel.Children.Add(dateCombo);

        var minDur = new NumberBox
        {
            Header = "最短时长（秒）",
            Minimum = 0,
            Maximum = 100000,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
        };
        if (current.MinDurationSec is int mn) minDur.Value = mn;
        panel.Children.Add(minDur);

        var maxDur = new NumberBox
        {
            Header = "最长时长（秒，0 = 不限）",
            Minimum = 0,
            Maximum = 100000,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
        };
        if (current.MaxDurationSec is int mx) maxDur.Value = mx;
        panel.Children.Add(maxDur);

        var tagMode = new ComboBox { Header = "标签匹配", MinWidth = 140 };
        tagMode.Items.Add(DouyinTagMode.Any.Label());
        tagMode.Items.Add(DouyinTagMode.All.Label());
        tagMode.SelectedIndex = current.TagMode == DouyinTagMode.All ? 1 : 0;
        panel.Children.Add(tagMode);

        var authorBox = new StackPanel { Spacing = 4 };
        authorBox.Children.Add(new TextBlock { Text = "作者（任一命中）", FontSize = 12, Opacity = 0.7 });
        var authorChecks = new List<(string Value, CheckBox Box)>();
        foreach (var a in facets.Authors.Take(20))
        {
            var cb = new CheckBox { Content = a, IsChecked = current.AuthorIds.Contains(a), FontSize = 12 };
            authorChecks.Add((a, cb));
            authorBox.Children.Add(cb);
        }
        if (facets.Authors.Count == 0)
            authorBox.Children.Add(new TextBlock { Text = "（先抓到作品才有候选）", FontSize = 11, Opacity = 0.55 });
        panel.Children.Add(authorBox);

        var tagWrap = new StackPanel { Spacing = 4 };
        tagWrap.Children.Add(new TextBlock { Text = "标签", FontSize = 12, Opacity = 0.7 });
        var tagChecks = new List<(string Value, CheckBox Box)>();
        foreach (var t in facets.Tags.Take(20))
        {
            var cb = new CheckBox { Content = t, IsChecked = current.Tags.Contains(t), FontSize = 12 };
            tagChecks.Add((t, cb));
            tagWrap.Children.Add(cb);
        }
        if (facets.Tags.Count == 0)
            tagWrap.Children.Add(new TextBlock { Text = "（先抓到作品才有候选）", FontSize = 11, Opacity = 0.55 });
        panel.Children.Add(tagWrap);

        var groupToggle = new ToggleSwitch
        {
            Header = "同一作品的媒体连续排列",
            IsOn = current.GroupByAweme,
            MinWidth = 0,
        };
        panel.Children.Add(groupToggle);

        var scroll = new ScrollViewer
        {
            Content = panel,
            MaxHeight = 460,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled,
        };

        var dialog = new ContentDialog
        {
            Title = "筛选",
            Content = scroll,
            PrimaryButtonText = "应用",
            SecondaryButtonText = "重置",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.None) return;

        var filter = new DouyinFilter();
        if (result == ContentDialogResult.Primary)
        {
            filter.Keyword = keyword.Text ?? "";
            filter.QuickRange = ranges[Math.Max(0, dateCombo.SelectedIndex)];
            if (!double.IsNaN(minDur.Value) && minDur.Value > 0) filter.MinDurationSec = (int)minDur.Value;
            if (!double.IsNaN(maxDur.Value) && maxDur.Value > 0) filter.MaxDurationSec = (int)maxDur.Value;
            filter.TagMode = tagMode.SelectedIndex == 1 ? DouyinTagMode.All : DouyinTagMode.Any;
            filter.AuthorIds = authorChecks.Where(x => x.Box.IsChecked == true).Select(x => x.Value).ToHashSet();
            filter.Tags = tagChecks.Where(x => x.Box.IsChecked == true).Select(x => x.Value).ToHashSet();
            filter.GroupByAweme = groupToggle.IsOn;

            // 持久化，下次进页面还在
            DouyinSettings.Mutate(c =>
            {
                c.FilterKeyword = filter.Keyword;
                c.FilterDateRange = filter.QuickRange;
                c.FilterMinDurationSec = filter.MinDurationSec;
                c.FilterMaxDurationSec = filter.MaxDurationSec;
                c.FilterTagMode = filter.TagMode;
            });
        }

        _store.SetFilter(filter);
    }
    private async void OnDownloadClick(object sender, RoutedEventArgs e)
    {
        var cfg = DouyinSettings.Current.Clone();
        var batch = _store.BuildDownloadList(cfg);

        // 一个都没剩下时也要给说法 —— 否则用户点下去毫无反应
        if (batch.Items.Count == 0)
        {
            var why = new List<string>();
            if (batch.SkippedDownloaded > 0) why.Add(batch.SkippedDownloaded + " 个已下载作品");
            if (batch.SkippedDuration > 0) why.Add(batch.SkippedDuration + " 条不符合时长范围");
            StatusText.Text = why.Count == 0 ? "没有可下载的条目。" : "这批全部被跳过（" + string.Join("，", why) + "）。";
            return;
        }

        DownloadButton.IsEnabled = false;
        StatusText.Text = "正在提交 " + batch.Items.Count + " 条到下载队列…";
        try
        {
            var r = await DouyinEnqueuer.EnqueueAsync(batch.Items, cfg);
            StatusText.Text = r.Message
                + (batch.SkippedDownloaded > 0 ? "，跳过 " + batch.SkippedDownloaded + " 个已下载作品" : "")
                + (batch.SkippedDuration > 0 ? "，时长不符跳过 " + batch.SkippedDuration + " 条" : "");
        }
        catch (Exception ex)
        {
            StatusText.Text = "提交失败：" + ex.Message;
        }
        finally
        {
            DownloadButton.IsEnabled = true;
            RefreshList();
        }
    }

    // ── 结果网格 ───────────────────────────────────────────────

    private void OnStoreChanged()
    {
        DispatcherQueue.TryEnqueue(RefreshList);
    }

    private void RefreshList()
    {
        ResultGrid.Items.Clear();

        var groups = _store.AwemeGroups;
        foreach (var g in groups)
            ResultGrid.Items.Add(BuildTile(g));

        RefreshSummary();
    }

    private void RefreshSummary()
    {
        var cfg = DouyinSettings.Current;
        var total = _store.AllAwemeGroupCount;
        var shown = _store.AwemeGroups.Count;

        // 空状态只留四个字 —— 这句要和图标组、已选数挤在同一行，长句会把行撑开。
        // 完整说明进 ToolTip（用户要的是「一行」，不是「一句话」）。
        var text = _store.Count == 0
            ? "还没有抓到内容"
            : "共 " + total + " 个作品（媒体 " + _store.Count + " 条）";
        ToolTipService.SetToolTip(ListSummary, _store.Count == 0
            ? "还没有抓到内容：先在左边登录并滚动页面，作品会自动出现在这里。"
            : text);
        if (_store.HasFilter) text += " · 筛选后 " + shown + " 个作品";
        if (_store.Dropped > 0) text += " · 超出上限已丢弃 " + _store.Dropped + " 条";
        ListSummary.Text = text;

        var sel = _store.SelectedCount;
        SelectedCountText.Text = "已选 " + sel;
        UpdateSelectAllIcon();

        DownloadButton.IsEnabled = _store.Count > 0;

        var batch = _store.BuildDownloadList(cfg);
        var why = "已选 " + sel + " 条媒体";
        if (batch.SkippedDownloaded > 0) why += " · 跳过 " + batch.SkippedDownloaded + " 个已下载作品";
        if (batch.SkippedDuration > 0) why += " · 时长不符跳过 " + batch.SkippedDuration + " 条";
        why += " · 待提交 " + batch.Items.Count + " 条";
        DownloadSummary.Text = why;
    }

    // -- 详情浮层（点击展开完整列表）------------------------

    /// <summary>
    /// **详情浮层**（2026-10-30 用户要求「再加一个点击展开详情」）。
    ///
    /// 右侧网格只能看缩略图，标题/互动数/标签/时间都挤不下。这个浮层把每条作品
    /// 展开成一行完整信息，并支持直接勾选与底部「下载全部」。
    ///
    /// 用 ContentDialog 而不是自绘 Popup：它自带遮罩、焦点圈闭、ESC 关闭与键盘可达性。
    /// </summary>
    private async void OnOpenDetailClick(object sender, RoutedEventArgs e)
    {
        if (_detailOpen) return;   // ContentDialog 不能同时弹两个
        _detailOpen = true;
        try
        {
            var groups = _store.AwemeGroups;
            if (groups.Count == 0)
            {
                StatusText.Text = "还没有抓到作品，先在左边滚动页面。";
                return;
            }

            var list = new StackPanel { Spacing = 2 };
            foreach (var g in groups) list.Children.Add(BuildDetailRow(g));

            var scroll = new ScrollViewer
            {
                Content = list,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollMode = ScrollMode.Disabled,
                Padding = new Thickness(0, 4, 8, 4),
            };

            var body = new StackPanel();
            body.Children.Add(new TextBlock
            {
                Text = groups.Count + " 个作品",
                FontSize = 12,
                Opacity = 0.6,
                Margin = new Thickness(0, 0, 0, 8),
            });
            body.Children.Add(scroll);

            var dlg = new ContentDialog
            {
                Title = "抓取结果",
                Content = body,
                CloseButtonText = "关闭",
                PrimaryButtonText = "下载全部（" + groups.Count + "）",
                DefaultButton = ContentDialogButton.Primary,
                XamlRoot = XamlRoot,
            };
            // 默认 ContentDialog 只有 ~548px 宽，列表会挤成一条缝 —— 放大到接近整窗
            dlg.Resources["ContentDialogMaxWidth"] = 1120.0;
            dlg.Resources["ContentDialogMinWidth"] = 900.0;

            var r = await dlg.ShowAsync();
            if (r == ContentDialogResult.Primary)
            {
                _store.SetAllSelected(true);   // 「下载全部」= 先全选，再走原有下载流程
                RefreshList();
                OnDownloadClick(null!, new RoutedEventArgs());
            }
        }
        catch (Exception ex)
        {
            StatusText.Text = "展开详情失败：" + ex.Message;
        }
        finally
        {
            _detailOpen = false;
        }
    }

    /// <summary>详情浮层一行：勾选 + 缩略图 + 标题/互动数/标签·时间 + 类型徽章。</summary>
    private FrameworkElement BuildDetailRow(DouyinAwemeGroup g)
    {
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(6, 8, 6, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var cb = new CheckBox
        {
            IsChecked = _store.GroupSelectionOf(g) == DouyinSelection.All,
            MinWidth = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        cb.Checked += (_, _) => { if (_store.GroupSelectionOf(g) != DouyinSelection.All) _store.ToggleGroup(g); RefreshList(); };
        cb.Unchecked += (_, _) => { if (_store.GroupSelectionOf(g) == DouyinSelection.All) _store.ToggleGroup(g); RefreshList(); };
        Grid.SetColumn(cb, 0);
        grid.Children.Add(cb);

        var thumb = new Border
        {
            Width = 96, Height = 96, CornerRadius = new CornerRadius(6),
            Background = UiKit.SubtleFill,
        };
        var img = new Image { Stretch = Stretch.UniformToFill, Width = 96, Height = 96 };
        thumb.Child = img;
        if (!string.IsNullOrWhiteSpace(g.CoverUrl))
        {
            try { img.Source = new BitmapImage(new Uri(g.CoverUrl)) { DecodePixelWidth = 192 }; }
            catch { }
        }
        Grid.SetColumn(thumb, 1);
        grid.Children.Add(thumb);

        var info = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        info.Children.Add(new TextBlock
        {
            Text = g.Title,
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        info.Children.Add(new TextBlock
        {
            Text = "赞 " + g.LikeCount + "    评 " + g.CommentCount
                 + "    藏 " + g.CollectCount + "    转 " + g.ShareCount,
            FontSize = 11.5,
            Opacity = 0.7,
        });
        var tagLine = g.Tags.Count > 0 ? string.Join(" ", g.Tags) : "";
        var when = g.CreatedAt is null ? "" : g.CreatedAt.Value.ToString("yyyy-MM-dd HH:mm:ss");
        info.Children.Add(new TextBlock
        {
            Text = (tagLine.Length > 0 ? tagLine + " · " : "") + when,
            FontSize = 11.5,
            Opacity = 0.5,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        Grid.SetColumn(info, 2);
        grid.Children.Add(info);

        var kind = g.HasMainVideo ? "视频" : g.HasLiveVideo ? "实况" : "图文";
        var badge = new Border
        {
            Background = UiKit.AccentFill,
            CornerRadius = new CornerRadius(3),
            Padding = new Thickness(6, 1, 6, 1),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 4, 0, 0),
            Child = new TextBlock { Text = kind, FontSize = 10.5, Foreground = UiKit.OnAccentText },
        };
        Grid.SetColumn(badge, 3);
        grid.Children.Add(badge);

        return grid;
    }

    /// <summary>
    /// 一个作品 = 一个方格：封面铺满 + 时长角标（右下）+ 勾选圈（左上）+ 已下载标。
    /// 点击方格弹出放大预览（见 <see cref="ShowPreviewAsync"/>）。
    /// </summary>
    private FrameworkElement BuildTile(DouyinAwemeGroup g)
    {
        var root = new Grid { Width = TileSize, Height = TileSize };

        // 封面（铺满整格）
        var cover = new Border
        {
            CornerRadius = new CornerRadius(6),
            Background = UiKit.SubtleFill,
            Child = new TextBlock
            {
                Text = "\uE8B9",
                FontFamily = new FontFamily("Segoe MDL2 Assets"),
                FontSize = 22,
                Opacity = 0.45,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        if (!string.IsNullOrEmpty(g.CoverUrl) && Uri.TryCreate(g.CoverUrl, UriKind.Absolute, out var coverUri))
        {
            // 缩略图按解码尺寸限制一下：网格里几十上百张，原图解码太贵
            cover.Child = new Image
            {
                Source = new BitmapImage(new Uri(g.CoverUrl)) { DecodePixelWidth = 208 },
                Stretch = Stretch.UniformToFill,
            };
        }
        root.Children.Add(cover);

        // 勾选圈（左上角，圆形按钮 —— 保留批量勾选能力）
        var selected = _store.GroupSelectionOf(g) != DouyinSelection.None;
        var check = new Button
        {
            Content = new FontIcon
            {
                Glyph = selected ? "\uE73E" : "\uE739",
                FontSize = 12,
                Foreground = selected ? UiKit.OnAccentText : UiKit.CardBackground,
            },
            Width = 24,
            Height = 24,
            MinWidth = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(12),
            Background = selected ? UiKit.AccentFill : UiKit.SubtleFill,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(6, 6, 0, 0),
        };
        ToolTipService.SetToolTip(check, "勾选 / 取消这个作品");
        check.Click += (_, _) =>
        {
            // 点勾选圈不要再冒出一次「打开预览」—— WinUI 的 Button.Click 没有
            // Handled 可设，所以用一个短窗口标记，OnTileClick 里据此忽略。
            _suppressTileClickUntil = DateTime.Now.AddMilliseconds(300);
            _store.ToggleGroup(g);
        };
        root.Children.Add(check);

        // 时长角标（右下）
        var duration = g.DurationMs is int ms && ms > 0 ? DouyinTemplate.FormatDurationSeconds(ms / 1000) : null;
        var badgeText = duration ?? (g.ImageCount > 0 ? g.ImageCount + " 图" : null);
        if (badgeText is not null)
        {
            var badge = new Border
            {
                Background = new SolidColorBrush(Windows.UI.Color.FromArgb(170, 0, 0, 0)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(5, 1, 5, 1),
                Margin = new Thickness(0, 0, 5, 5),
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Bottom,
                Child = new TextBlock
                {
                    Text = badgeText,
                    FontSize = 11,
                    Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 255, 255)),
                },
            };
            root.Children.Add(badge);
        }

        // 类型标（左下：视频 / 图文 / 视频+N图）
        var typeTag = new Border
        {
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(150, 0, 0, 0)),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(5, 1, 5, 1),
            Margin = new Thickness(5, 0, 0, 5),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
            Child = new TextBlock
            {
                Text = g.TypeLabel,
                FontSize = 10,
                Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 255, 255)),
            },
        };
        root.Children.Add(typeTag);

        // 已下载标记（右上）
        if (_store.IsGroupDownloaded(g))
        {
            var done = new Border
            {
                Background = new SolidColorBrush(Windows.UI.Color.FromArgb(190, 0, 100, 0)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(5, 1, 5, 1),
                Margin = new Thickness(0, 6, 6, 0),
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Child = new TextBlock
                {
                    Text = "已下载",
                    FontSize = 10,
                    Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 255, 255)),
                },
            };
            root.Children.Add(done);
        }

        // 选中时描一圈强调色边
        if (selected)
        {
            root.Children.Add(new Border
            {
                BorderBrush = UiKit.AccentFill,
                BorderThickness = new Thickness(2),
                CornerRadius = new CornerRadius(6),
                IsHitTestVisible = false,
            });
        }

        var tile = new Border
        {
            Padding = new Thickness(0),
            Child = root,
            // 点格子弹预览时靠 Tag 找回这个作品
            Tag = g,
        };
        ToolTipService.SetToolTip(tile, g.Title);
        return tile;
    }

    /// <summary>点击方格 → 放大预览（大图 + 标题 + 时长 + 点赞 + 日期 + 媒体地址）。</summary>
    private async void OnTileClick(object sender, ItemClickEventArgs e)
    {
        if (DateTime.Now < _suppressTileClickUntil) return;

        // Items 里塞的是控件而不是数据对象，靠 Tag 找回对应的作品
        if (e.ClickedItem is Border { Tag: DouyinAwemeGroup g })
            await ShowPreviewAsync(g);
    }

    private async Task ShowPreviewAsync(DouyinAwemeGroup g)
    {
        var panel = new StackPanel { Spacing = 12, MinWidth = 420 };

        // 大图
        if (!string.IsNullOrEmpty(g.CoverUrl) && Uri.TryCreate(g.CoverUrl, UriKind.Absolute, out var uri))
        {
            panel.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(8),
                Background = UiKit.SubtleFill,
                HorizontalAlignment = HorizontalAlignment.Center,
                Child = new Image
                {
                    Source = new BitmapImage(uri),
                    Stretch = Stretch.Uniform,
                    MaxHeight = 380,
                    MaxWidth = 380,
                },
            });
        }

        panel.Children.Add(new TextBlock
        {
            Text = g.Title,
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });

        var info = new StackPanel { Spacing = 0 };
        info.Children.Add(UiKit.InfoRow("类型", g.TypeLabel));
        info.Children.Add(UiKit.InfoRow("时长",
            g.DurationMs is int ms && ms > 0 ? DouyinTemplate.FormatDurationSeconds(ms / 1000) : "—"));
        info.Children.Add(UiKit.InfoRow("媒体条数", g.Count.ToString()));
        info.Children.Add(UiKit.InfoRow("点赞", DouyinTemplate.FormatStatCount(g.LikeCount)));
        info.Children.Add(UiKit.InfoRow("评论", DouyinTemplate.FormatStatCount(g.CommentCount)));
        info.Children.Add(UiKit.InfoRow("收藏", DouyinTemplate.FormatStatCount(g.CollectCount)));
        info.Children.Add(UiKit.InfoRow("分享", DouyinTemplate.FormatStatCount(g.ShareCount)));
        info.Children.Add(UiKit.InfoRow("发布时间",
            g.CreatedAt is DateTime t ? t.ToString("yyyy-MM-dd HH:mm") : "未知"));
        info.Children.Add(UiKit.InfoRow("作品 ID", g.AwemeId, selectable: true));
        if (!string.IsNullOrEmpty(g.Lead.UserName))
            info.Children.Add(UiKit.InfoRow("作者", "@" + g.Lead.UserName, selectable: true));
        if (g.Tags.Count > 0)
            info.Children.Add(UiKit.InfoRow("标签", string.Join(" / ", g.Tags), selectable: true));
        info.Children.Add(UiKit.InfoRow("已下载", _store.IsGroupDownloaded(g) ? "是" : "否"));
        panel.Children.Add(info);

        // 媒体地址（一条媒体一行）
        var urls = new StackPanel { Spacing = 4 };
        urls.Children.Add(new TextBlock { Text = "媒体地址", FontSize = 12, Opacity = 0.7 });
        foreach (var m in g.Items)
        {
            urls.Children.Add(new TextBlock
            {
                Text = "#" + m.MediaIndex + " " + (m.IsVideo ? "视频" : m.IsImage ? "图片" : "音频") + "  " + m.Url,
                FontSize = 11,
                Opacity = 0.65,
                IsTextSelectionEnabled = true,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        panel.Children.Add(urls);

        var dialog = new ContentDialog
        {
            Title = "作品预览",
            Content = new ScrollViewer
            {
                Content = panel,
                MaxHeight = 560,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                HorizontalScrollMode = ScrollMode.Disabled,
            },
            PrimaryButtonText = _store.GroupSelectionOf(g) == DouyinSelection.All ? "取消勾选" : "勾选这个作品",
            CloseButtonText = "关闭",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            _store.ToggleGroup(g);
        }
    }
}
