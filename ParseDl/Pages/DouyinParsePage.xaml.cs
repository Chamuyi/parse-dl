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
    private const double OptionLabelWidth = 88;

    /// <summary>下拉框统一高度。</summary>
    private const double OptionControlHeight = 32;

    private readonly DouyinStore _store = DouyinStore.Instance;
    private bool _ready;
    private bool _loading;
    private bool? _wideLayout;
    private DouyinAutoScroller? _autoScroller;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _autoTimer;
    private bool _suppressOptionEvents;
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
            BodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            BodyGrid.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
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

    /// <summary>「抓取本页」：提示当前页已有多少条，并把结果按筛选重排一次。</summary>
    private async void OnCaptureClick(object sender, RoutedEventArgs e)
    {
        if (!_ready) { StatusText.Text = "内嵌浏览器还没就绪。"; return; }
        CaptureButton.IsEnabled = false;
        try
        {
            StatusText.Text = "正在统计页面上的作品…";
            var raw = await Web.CoreWebView2.ExecuteScriptAsync("document.documentElement.scrollHeight");
            RefreshList();
            StatusText.Text = "当前页面已收集 " + _store.Count + " 个媒体 / " +
                _store.AllAwemeGroupCount + " 个作品（页面高 " + raw + "px）。" +
                "若列表为空，请先登录并向下滚动让卡片加载出来。";
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
        AutoScrollButton.Content = "停止加载";

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
        AutoScrollButton.Content = "自动加载";
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
        OptionHost.Children.Clear();

        var sourceCombo = new ComboBox
        {
            Height = OptionControlHeight,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            MinWidth = 0,
        };
        foreach (var s in Enum.GetValues<DouyinSource>()) sourceCombo.Items.Add(s.Label());
        sourceCombo.SelectedIndex = (int)cfg.Source;
        sourceCombo.SelectionChanged += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.Source = (DouyinSource)Math.Max(0, sourceCombo.SelectedIndex));
            BuildOptionBar();
            RefreshSummary();
        };
        OptionHost.Children.Add(OptionRow("下载源", sourceCombo));

        if (cfg.Source.NeedsQualityMode())
        {
            var modeCombo = new ComboBox
            {
                Height = OptionControlHeight,
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
            OptionHost.Children.Add(OptionRow("质量优先策略", modeCombo));
        }

        var imgCombo = new ComboBox
        {
            Height = OptionControlHeight,
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
        OptionHost.Children.Add(OptionRow("图片格式", imgCombo));

        var skipToggle = new ToggleSwitch { IsOn = cfg.SkipDownloaded, MinWidth = 0, OnContent = "开", OffContent = "关" };
        skipToggle.Toggled += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.SkipDownloaded = skipToggle.IsOn);
            RefreshSummary();
        };
        OptionHost.Children.Add(ToggleRow("跳过已下载", skipToggle));

        var bgmToggle = new ToggleSwitch { IsOn = cfg.IncludeBgm, MinWidth = 0, OnContent = "开", OffContent = "关" };
        bgmToggle.Toggled += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.IncludeBgm = bgmToggle.IsOn);
        };
        OptionHost.Children.Add(ToggleRow("附带 BGM（图文）", bgmToggle));

        var liveToggle = new ToggleSwitch { IsOn = cfg.IncludeLivePhoto, MinWidth = 0, OnContent = "开", OffContent = "关" };
        liveToggle.Toggled += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.IncludeLivePhoto = liveToggle.IsOn);
        };
        OptionHost.Children.Add(ToggleRow("实况图配对视频", liveToggle));

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

    /// <summary>开关行：开关紧跟标题（距离 ≤24px，遵循用户 2026-09-30 的约定）。</summary>
    private static StackPanel ToggleRow(string label, ToggleSwitch toggle)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        row.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 13,
            Opacity = 0.8,
            VerticalAlignment = VerticalAlignment.Center,
        });
        toggle.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(toggle);
        return row;
    }

    // ── 操作按钮排（换行，不截断）────────────────────────────────

    /// <summary>把操作按钮装进自写的换行面板 —— 窗口变窄时换行而不是被裁掉。</summary>
    private void BuildActionBar()
    {
        ActionHost.Children.Clear();
        var wrap = new DouyinWrapPanel { RowGap = 6, ColumnGap = 6 };

        wrap.Children.Add(MiniButton("全部", OnSelectAllClick));
        wrap.Children.Add(MiniButton("清空勾选", OnSelectNoneClick));
        wrap.Children.Add(MiniButton("选全部视频", OnSelectVideoClick));
        wrap.Children.Add(MiniButton("选全部图文", OnSelectImageClick));
        wrap.Children.Add(MiniButton("筛选", OnFilterClick));
        wrap.Children.Add(MiniButton("清空结果", OnClearClick));

        ActionHost.Children.Add(wrap);
    }

    private static Button MiniButton(string text, RoutedEventHandler handler)
    {
        var b = new Button { Content = text, MinWidth = 0, Padding = new Thickness(12, 5, 12, 5) };
        b.Click += handler;
        return b;
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

        var text = _store.Count == 0
            ? "还没有抓到内容：先在左边登录并滚动页面，作品会自动出现在这里。"
            : "共 " + total + " 个作品（媒体 " + _store.Count + " 条）";
        if (_store.HasFilter) text += " · 筛选后 " + shown + " 个作品";
        if (_store.Dropped > 0) text += " · 超出上限已丢弃 " + _store.Dropped + " 条";
        ListSummary.Text = text;

        var sel = _store.SelectedCount;
        SelectedCountText.Text = "已选 " + sel;
        SelectAllBox.IsChecked = _store.SelectionState;

        DownloadButton.IsEnabled = _store.Count > 0;

        var batch = _store.BuildDownloadList(cfg);
        var why = "已选 " + sel + " 条媒体";
        if (batch.SkippedDownloaded > 0) why += " · 跳过 " + batch.SkippedDownloaded + " 个已下载作品";
        if (batch.SkippedDuration > 0) why += " · 时长不符跳过 " + batch.SkippedDuration + " 条";
        why += " · 待提交 " + batch.Items.Count + " 条";
        DownloadSummary.Text = why;
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

    private void OnSelectAllBoxClick(object sender, RoutedEventArgs e)
    {
        // 三态：不是「全选」状态就全选，已经是全选就清空
        var wantAll = _store.SelectionState != true;
        _store.SetAllSelected(wantAll);
        SelectAllBox.IsChecked = _store.SelectionState;
    }

    private void OnSelectAllClick(object sender, RoutedEventArgs e) => _store.SetAllSelected(true);
    private void OnSelectNoneClick(object sender, RoutedEventArgs e) => _store.SetAllSelected(false);
    private void OnSelectVideoClick(object sender, RoutedEventArgs e) => _store.SelectAllOfType(true);
    private void OnSelectImageClick(object sender, RoutedEventArgs e) => _store.SelectAllOfType(false);

    private void OnClearClick(object sender, RoutedEventArgs e)
    {
        _store.Clear();
        StatusText.Text = "已清空抓取结果（已下载台账不受影响）。";
    }

    // ── 筛选面板 ────────────────────────────────────────────────

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

    // ── 入队 ───────────────────────────────────────────────────

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
}
