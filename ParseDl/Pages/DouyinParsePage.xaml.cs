using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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
/// 结构：左边内嵌浏览器（WebView2）+ 注入拦截脚本，右边下载选项 + 作品列表。
/// 抓取不靠读 HTML，而靠拦截脚本抄页面自己的 XHR/fetch 响应，并且只认
/// **页面真渲染成卡片**的那些作品（见 Services/Douyin/DouyinInterceptor.cs）。
///
/// 本页职责边界：只做「展示 + 触发」。结果仓库是 DouyinStore 单例（切页面不丢），
/// 落盘规则在 DouyinConfig/DouyinSettings，入队在 DouyinEnqueuer。
/// </summary>
public sealed partial class DouyinParsePage : Page
{
    private readonly DouyinStore _store = DouyinStore.Instance;
    private bool _ready;
    private bool _loading;
    private DouyinAutoScroller? _autoScroller;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _autoTimer;
    private bool _suppressOptionEvents;

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
        BuildOptionBar();
        RefreshList();
        _ = InitWebAsync();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _store.Changed -= OnStoreChanged;
        StopAutoScroll();
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
            var height = raw;
            RefreshList();
            StatusText.Text = "当前页面已收集 " + _store.Count + " 个媒体 / " +
                _store.AllAwemeGroupCount + " 个作品（页面高 " + height + "px）。" +
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
    /// 下载源 / 质量策略 / 图片格式三行紧凑选项。
    /// 放在抓取面板里而不是只放设置页：参照实现的这套选项就长在批量下载弹窗上，
    /// 用户抓完一批会就地切换对比效果。设置页那份是**同一份数据**，改哪边都即时生效。
    /// </summary>
    private void BuildOptionBar()
    {
        var cfg = DouyinSettings.Current;
        _suppressOptionEvents = true;
        OptionHost.Children.Clear();

        var sourceCombo = new ComboBox { MinWidth = 260 };
        foreach (var s in Enum.GetValues<DouyinSource>()) sourceCombo.Items.Add(s.Label());
        sourceCombo.SelectedIndex = (int)cfg.Source;
        sourceCombo.SelectionChanged += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.Source = (DouyinSource)sourceCombo.SelectedIndex);
            BuildOptionBar();
            RefreshSummary();
        };
        OptionHost.Children.Add(CompactRow("下载源", sourceCombo));

        if (cfg.Source.NeedsQualityMode())
        {
            var modeCombo = new ComboBox { MinWidth = 200 };
            foreach (var m in Enum.GetValues<DouyinQualityMode>()) modeCombo.Items.Add(m.Label());
            modeCombo.SelectedIndex = (int)cfg.QualityMode;
            modeCombo.SelectionChanged += (_, _) =>
            {
                if (_suppressOptionEvents) return;
                DouyinSettings.Mutate(c => c.QualityMode = (DouyinQualityMode)modeCombo.SelectedIndex);
                RefreshSummary();
            };
            OptionHost.Children.Add(CompactRow("质量优先策略", modeCombo));
        }

        var imgCombo = new ComboBox { MinWidth = 200 };
        foreach (var f in Enum.GetValues<DouyinImageFormat>()) imgCombo.Items.Add(f.Label());
        imgCombo.SelectedIndex = (int)cfg.ImageFormat;
        imgCombo.SelectionChanged += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.ImageFormat = (DouyinImageFormat)imgCombo.SelectedIndex);
        };
        OptionHost.Children.Add(CompactRow("图片格式", imgCombo));

        var skipToggle = new ToggleSwitch { IsOn = cfg.SkipDownloaded, MinWidth = 0 };
        skipToggle.Toggled += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.SkipDownloaded = skipToggle.IsOn);
            RefreshSummary();
        };
        OptionHost.Children.Add(CompactRow("跳过已下载", skipToggle));

        var bgmToggle = new ToggleSwitch { IsOn = cfg.IncludeBgm, MinWidth = 0 };
        bgmToggle.Toggled += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.IncludeBgm = bgmToggle.IsOn);
        };
        OptionHost.Children.Add(CompactRow("附带 BGM（图文）", bgmToggle));

        var liveToggle = new ToggleSwitch { IsOn = cfg.IncludeLivePhoto, MinWidth = 0 };
        liveToggle.Toggled += (_, _) =>
        {
            if (_suppressOptionEvents) return;
            DouyinSettings.Mutate(c => c.IncludeLivePhoto = liveToggle.IsOn);
        };
        OptionHost.Children.Add(CompactRow("实况图配对视频", liveToggle));

        _suppressOptionEvents = false;
    }

    /// <summary>设置项开关必须与标题同行（用户 2026-09-30 约定：距离 ≤24px）。</summary>
    private static Grid CompactRow(string label, FrameworkElement control)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        grid.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 13,
            Opacity = 0.8,
            VerticalAlignment = VerticalAlignment.Center,
        });

        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }

    // ── 列表 ───────────────────────────────────────────────────

    private void OnStoreChanged()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            RefreshList();
        });
    }

    private void RefreshList()
    {
        ResultList.Items.Clear();

        var groups = _store.AwemeGroups;
        foreach (var g in groups)
            ResultList.Items.Add(BuildRow(g));

        RefreshSummary();
    }

    private void RefreshSummary()
    {
        var cfg = DouyinSettings.Current;
        var total = _store.AllAwemeGroupCount;
        var shown = _store.AwemeGroups.Count;

        var text = "共 " + total + " 个作品（媒体 " + _store.Count + " 条）";
        if (_store.HasFilter) text += " · 筛选后 " + shown + " 个作品";
        if (_store.Dropped > 0) text += " · 超出上限已丢弃 " + _store.Dropped + " 条";
        ListSummary.Text = text;

        var sel = _store.SelectedCount;
        DownloadButton.IsEnabled = _store.Count > 0;
        DownloadButton.Content = "开始下载";

        var batch = _store.BuildDownloadList(cfg);
        var why = "已选 " + sel + " 条媒体";
        if (batch.SkippedDownloaded > 0) why += " · 跳过 " + batch.SkippedDownloaded + " 个已下载作品";
        if (batch.SkippedDuration > 0) why += " · 时长不符跳过 " + batch.SkippedDuration + " 条";
        why += " · 待提交 " + batch.Items.Count + " 条";
        DownloadSummary.Text = why;
    }

    private FrameworkElement BuildRow(DouyinAwemeGroup g)
    {
        var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        // 勾选框（三态：整组全选 = true，部分 = null，未选 = false）
        var check = new CheckBox { MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        var state = _store.GroupSelectionOf(g);
        check.IsChecked = state switch
        {
            DouyinSelection.All => true,
            DouyinSelection.Some => null,
            _ => false,
        };
        check.Click += (_, _) =>
        {
            _store.ToggleGroup(g);
        };
        grid.Children.Add(check);

        // 封面
        var cover = new Border
        {
            Width = 64,
            Height = 64,
            CornerRadius = new CornerRadius(6),
            Background = UiKit.SubtleFill,
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = "\uE8B9",
                FontFamily = new FontFamily("Segoe MDL2 Assets"),
                FontSize = 20,
                Opacity = 0.5,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        if (!string.IsNullOrEmpty(g.CoverUrl) && Uri.TryCreate(g.CoverUrl, UriKind.Absolute, out var coverUri))
        {
            cover.Child = new Image
            {
                Source = new BitmapImage(coverUri),
                Stretch = Stretch.UniformToFill,
            };
        }
        Grid.SetColumn(cover, 1);
        grid.Children.Add(cover);

        // 文案 + 元数据
        var texts = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(new TextBlock
        {
            Text = g.Title,
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });

        var meta = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        meta.Children.Add(new TextBlock { Text = g.TypeLabel, FontSize = 11, Opacity = 0.65 });
        if (g.DurationMs is int ms && ms > 0)
            meta.Children.Add(new TextBlock
            {
                Text = DouyinTemplate.FormatDurationSeconds(ms / 1000),
                FontSize = 11,
                Opacity = 0.65,
            });
        meta.Children.Add(new TextBlock
        {
            Text = DouyinTemplate.FormatStatCount(g.LikeCount) + " 赞",
            FontSize = 11,
            Opacity = 0.65,
        });
        if (g.CreatedAt is DateTime t)
            meta.Children.Add(new TextBlock
            {
                Text = t.ToString("yyyy-MM-dd"),
                FontSize = 11,
                Opacity = 0.65,
            });
        texts.Children.Add(meta);
        Grid.SetColumn(texts, 2);
        grid.Children.Add(texts);

        // 已下载标记
        if (_store.IsGroupDownloaded(g))
        {
            var badge = new Border
            {
                Background = UiKit.SubtleFill,
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(8, 3, 8, 3),
                VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock { Text = "已下载", FontSize = 11, Opacity = 0.75 },
            };
            Grid.SetColumn(badge, 3);
            grid.Children.Add(badge);
        }

        return new Border
        {
            BorderThickness = new Thickness(0, 0, 0, 1),
            BorderBrush = UiKit.CardBorder,
            Child = grid,
        };
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
        var authorChecks = new System.Collections.Generic.List<(string Value, CheckBox Box)>();
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
        var tagChecks = new System.Collections.Generic.List<(string Value, CheckBox Box)>();
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
            var why = new System.Collections.Generic.List<string>();
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
