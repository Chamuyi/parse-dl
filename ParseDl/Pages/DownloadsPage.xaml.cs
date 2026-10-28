using ParseDl.Services.X;
using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;

namespace ParseDl.Pages;

/// <summary>
/// 下载管理 —— X / 抖音 / B 站 三种模式共用本页，形态全部由
/// <see cref="DownloadFeed"/> 决定（Tab 集合、空态文案、历史台账名、
/// 有没有「合并音视频」入口）。
///
/// 为什么重写：原来只靠一个 `module` 字符串过滤，三个模块的下载管理长得
/// 一模一样，于是 X 页上出现了「清空历史台账」（全局动作）和「合并音视频」
/// （B 站 dash 分离流专用）；Tab 条则是自绘 Button 塞 Border，窄容器里被挤压，
/// 「下载中」「错误」两个 Tab 直接看不见。现在：
///   1. Tab 换成 WinUI 官方分段控件 SelectorBar，六个 Tab 常驻显示、计数为 0 也在；
///   2. 按钮集合按模块裁剪（合并只给 B 站，清台账从本页移除）；
///   3. 数据来源从「module 字符串相等」升级成 feed 的 ModuleKeys 集合
///      （B 站要同时认「B 站」与「B 站（音频）」两个键）。
/// 数据来自真实的 aria2 队列（DownloadStore），不是假数据。
/// </summary>
public sealed partial class DownloadsPage : Page
{
    /// <summary>本进程是否已尝试恢复过队列（避免反复进出页面重复提交任务）。</summary>
    private static bool _queueRestored;

    /// <summary>上一次渲染历史台账的内容签名（一样就跳过重建，避免闪烁）。</summary>
    private string _historySignature = "";

    /// <summary>上一次渲染「任务创建中」区块的内容签名。</summary>
    private string _creationSignature = "";

    /// <summary>已提示过的最近完成任务 id（避免重复弹同一句）。</summary>
    private string _lastCreationResult = "";

    private DownloadFeed _feed = DownloadFeed.X;
    private DownloadTabSpec _tab = DownloadFeed.DefaultTabs[0];

    /// <summary>构建 Tab 期间置 true —— 否则设置 SelectedItem 会触发一次多余的重建。</summary>
    private bool _suppressSelection;

    private DispatcherTimer? _timer;

    public DownloadsPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _feed = DownloadFeed.FromParameter(e.Parameter);
        _tab = _feed.Tabs[0];
        BuildChrome();
        RebuildTabs();

        // **先立刻用本地已有数据画一遍**（2026-10-29 修「返回页面先空白」）：
        //
        // 之前这里只有 `_ = EnsureEngineThenRefreshAsync()`，它内部第一步是
        // `await EnsureEngineAsync()` —— 引擎没起来时要等它启动（几百毫秒到几秒），
        // 期间页面**一片空白**，然后列表才「突然出现」。
        //
        // DownloadStore 里的任务列表本来就是进程级单例、一直在内存里，
        // 所以进页面时**同步画一次**就够了，用户立刻看到内容；
        // 之后的引擎启动 / 队列恢复 / 数据刷新再慢慢补上。
        UiRefresh();

        _ = EnsureEngineThenRefreshAsync();
        StartTimer();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        StopTimer();
    }

    /// <summary>
    /// 先确保 aria2 起来了再刷新。
    /// 只调 RefreshOnceAsync 的话，引擎没启动时它直接 return（`if (!_engine.IsRunning) return;`），
    /// 页面会一直挂着「aria2 未启动」横幅、Tab 全是 0 —— 用户以为页面坏了。
    /// 引擎启动是幂等的，重复调用无副作用。
    /// </summary>
    private async System.Threading.Tasks.Task EnsureEngineThenRefreshAsync()
    {
        try { await DownloadStore.Instance.EnsureEngineAsync(); } catch { }

        // **恢复上次没跑完的队列**（2026-10-28 用户要求：「任务队列重启不能清空」）。
        // 只在进程内第一次进本页时恢复一次 —— 反复进出页面不该重复提交任务。
        // 恢复的是 URL / 文件名 / 目录（**不含 GID**），aria2 靠 --continue 续传已有部分。
        if (!_queueRestored)
        {
            _queueRestored = true;
            try
            {
                var n = await DownloadStore.Instance.RestoreQueueAsync();
                if (n > 0 && ToolbarHint is not null)
                    ToolbarHint.Text = "已恢复上次未完成的 " + n + " 个任务";
            }
            catch { }
        }

        await RefreshAsync();
    }
    /// <summary>每 0.8 秒刷一次（与 Flutter 版同频；下载中/速度要肉眼可见地在动）。</summary>
    private void StartTimer()
    {
        StopTimer();
        // 只重绘、不拉数据：DownloadStore 自己每 0.8 秒轮询一次 aria2，
        // 这里再调 RefreshOnceAsync 等于把 aria2 的 RPC 请求量翻倍。
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(800) };
        _timer.Tick += (_, _) => UiRefresh();
        _timer.Start();
    }

    private void StopTimer()
    {
        if (_timer is null) return;
        _timer.Stop();
        _timer = null;
    }

    /// <summary>页头 + 模块相关的静态文案。切换模块时只做一次，不随刷新重画。</summary>
    private void BuildChrome()
    {
        HeaderHost.Children.Clear();
        HeaderHost.Children.Add(UiKit.PageHeader("下载管理", _feed.Subtitle, "\uE896"));

        HistoryTitleText.Text = _feed.HistoryTitle;

        // 合并音视频只给 B 站：它的 dash 是分离流，下完必须合。
        // X / 抖音 拿到的是合流文件，画这个按钮等于给用户一个点了只会说
        // 「没有找到可合并的配对」的死按钮。
        MergeButton.Visibility = _feed.SupportsMerge ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>
    /// 建 Tab 条（只在进入页面时建一次）。**六个 Tab 全部常驻**，
    /// 计数为 0 也照样显示 —— 这是这次修 bug 的核心判据：用户必须一眼看出
    /// 这是一排 Tab，而不是一两个孤立按钮。
    /// </summary>
    private void RebuildTabs()
    {
        _suppressSelection = true;
        TabSelector.Items.Clear();

        SelectorBarItem? toSelect = null;
        foreach (var tab in _feed.Tabs)
        {
            var item = new SelectorBarItem
            {
                // 计数为 0 也写出来：只显示「全部 3」而把「错误」藏掉，
                // 用户会以为筛选器坏了。全角括号避免与标题粘连。
                Text = $"{tab.Title}（{_feed.CountFor(tab)}）",
                Tag = tab,
            };
            TabSelector.Items.Add(item);
            if (ReferenceEquals(tab, _tab) || tab.Title == _tab.Title) toSelect = item;
        }

        TabSelector.SelectedItem = toSelect ?? TabSelector.Items.FirstOrDefault();
        _suppressSelection = false;
    }

    /// <summary>
    /// 就地更新 Tab 上的计数。
    /// 不重建控件：每 0.8 秒 Clear 一次再重加，选中态与键盘焦点都会被打断，
    /// 鼠标停在 Tab 上时还会闪。数字没变就不碰。
    /// </summary>
    private void UpdateTabCounts()
    {
        if (TabSelector.Items.Count != _feed.Tabs.Count) { RebuildTabs(); return; }
        for (var i = 0; i < _feed.Tabs.Count; i++)
        {
            var want = $"{_feed.Tabs[i].Title}（{_feed.CountFor(_feed.Tabs[i])}）";
            if (TabSelector.Items[i].Text != want) TabSelector.Items[i].Text = want;
        }
    }

    private async void OnTabSelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (_suppressSelection) return;
        if (sender.SelectedItem?.Tag is DownloadTabSpec tab)
        {
            _tab = tab;
            await RefreshAsync();
        }
    }

    /// <summary>先主动拉一次 aria2 状态，再重绘整个页面。</summary>
    private async System.Threading.Tasks.Task RefreshAsync()
    {
        try { await DownloadStore.Instance.RefreshOnceAsync(); } catch { }
        UiRefresh();
    }

    /// <summary>重绘整个页面（Tab 计数 + 任务列表 + 历史台账），不碰 aria2。</summary>
    private void UiRefresh()
    {
        // Tab 计数会随任务状态变化，跟着刷；但只改文字、不重建控件。
        UpdateTabCounts();
        RenderTasks();
        RenderHistory();
        RenderCreation();
        RenderToolbarState();
    }

    private void RenderTasks()
    {
        // **用 ItemsSource 而不是逐个 Add 控件**（2026-10-28 修卡死）：
        // ListView 只会为「可见的那几行」生成容器（虚拟化），
        // 378 个任务也只构建十几个。原来往 StackPanel 里逐个 Add，
        // 再配合每 0.8 秒一次的清空重建，界面直接「未响应」。
        var items = _feed.ItemsFor(_tab);
        if (items.Count == 0)
        {
            // **空态用独立的 TextBlock，不往 ItemsSource 里塞控件**（2026-10-28 修闪退）：
            // ItemTemplate 声明了 x:DataType=DownloadItem，塞别的对象会 x:Bind cast 失败
            // → InvalidCastException → 整个程序闪退（crash.log 里抓到过）。
            TaskList.Visibility = Visibility.Collapsed;
            EmptyHint.Visibility = Visibility.Visible;
            EmptyTitle.Text = "「" + _tab.Title + "」里还没有任务";
            EmptyDetail.Text = _feed.EmptyHint;
            _renderedSignature = "";
            return;
        }

        TaskList.Visibility = Visibility.Visible;
        EmptyHint.Visibility = Visibility.Collapsed;
        // **按「条目签名」判断要不要重设 ItemsSource**（2026-10-28 修闪烁）。
        //
        // 之前用 ReferenceEquals 比对 —— 但 ItemsFor() 每次都 ToList() 返回新列表，
        // 引用永远不相等，于是每 0.8 秒都整表重设一次 → 列表持续闪。
        // 现在比内容：任务数 + 首尾 GID + 各条状态。
        var sig = items.Count + "|" + items[0].Gid + "|" + items[^1].Gid
                  + "|" + items[0].Status + "|" + items[^1].Status
                  + "|" + string.Join((char)44, items.Select(i => (int)i.Status));
        if (sig == _renderedSignature)
        {
            // 内容没变：只就地更新可见行的文字（进度/速度会变），不重建列表。
            UpdateRowTexts();
            return;
        }

        _renderedSignature = sig;
        TaskList.ItemsSource = items;
    }

    /// <summary>上一次塞进 ListView 的集合引用（用于判断要不要整表重设）。</summary>
    /// <summary>上一次渲染的任务列表内容签名（一样就不重设 ItemsSource，避免闪烁）。</summary>
    private string _renderedSignature = "";

    /// <summary>就地更新已生成行的文字（不重建控件）。</summary>
    private void UpdateRowTexts()
    {
        // ListView 的容器是按需生成的，已生成的才需要刷新；
        // 未生成的会在滚动进来时用最新数据构建。
        for (var i = 0; i < TaskList.Items.Count; i++)
        {
            if (TaskList.ContainerFromIndex(i) is not ListViewItem lvi) continue;
            if (lvi.Content is not Grid g || g.Children.Count == 0) continue;
            if (g.Children[0] is not StackPanel sp || sp.Children.Count < 2) continue;
            if (TaskList.Items[i] is not DownloadItem it) continue;

            if (sp.Children[0] is TextBlock nameTb) nameTb.Text = it.FileName;
            if (sp.Children[1] is TextBlock statusTb)
                statusTb.Text = it.StatusText + (string.IsNullOrEmpty(it.Error) ? "" : " — " + it.Error)
                                + (string.IsNullOrEmpty(it.ProgressText) ? "" : "　" + it.ProgressText);
        }
    }
    /// <summary>工具栏可用性 + 提示语。计数与操作都只覆盖本模块（不能把别家的队列停掉）。</summary>
    private void RenderToolbarState()
    {
        var all = _feed.AllItems();
        var active = all.Count(i => i.Status is AriaStatus.Active or AriaStatus.Waiting);
        var paused = all.Count(i => i.Status == AriaStatus.Paused);
        var done = all.Count(i => i.Status is AriaStatus.Complete or AriaStatus.Error or AriaStatus.Removed);
        var failed = all.Count(i => i.Status == AriaStatus.Error);

        PauseAllButton.IsEnabled = active > 0;
        ResumeAllButton.IsEnabled = paused > 0;
        ClearCompletedButton.IsEnabled = done > 0;

        // 「重试全部」只在「错误」Tab 出现：别的 Tab 里没有可重试的东西。
        var onErrorTab = _tab.Status == AriaStatus.Error;
        RetryAllButton.Visibility = onErrorTab ? Visibility.Visible : Visibility.Collapsed;
        RetryAllButton.Content = $"重试全部（{failed}）";
        RetryAllButton.IsEnabled = failed > 0;

        ToolbarHint.Text = DownloadStore.Instance.EngineReady
            ? (all.Count == 0 ? "暂无任务" : $"本模块 {all.Count} 个任务")
            : "aria2 未启动";

        var ready = DownloadStore.Instance.EngineReady;
        EngineBanner.Visibility = ready ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>渲染本模块的历史台账。</summary>
    /// <summary>
    /// 渲染历史台账。**内容没变就完全不动控件**（2026-10-28 修闪烁）。
    ///
    /// 之前每 0.8 秒 `Children.Clear()` 再重建一遍，即使数据一个字没变 ——
    /// 界面就会持续闪。现在先比对「条目签名」，一样就直接返回。
    /// </summary>
    private void RenderHistory()
    {
        var entries = _feed.History();

        // 用「条数 + 首尾条目」做轻量签名，够判断有没有变化。
        var signature = entries.Count == 0
            ? "empty"
            : entries.Count + "|" + entries[0].FileName + "|" + entries[^1].FileName
                          + "|" + entries[0].Status + "|" + entries[^1].Status;
        if (signature == _historySignature) return;
        _historySignature = signature;

        HistoryPanel.Children.Clear();
        if (entries.Count == 0)
        {
            HistoryPanel.Children.Add(new TextBlock
            {
                Text = _feed.HistoryEmptyHint,
                FontSize = 13, Opacity = 0.6, TextWrapping = TextWrapping.Wrap,
            });
            return;
        }

        foreach (var e in entries)
        {
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var left = new StackPanel { Spacing = 2 };
            left.Children.Add(new TextBlock
            {
                Text = string.IsNullOrEmpty(e.FileName) ? e.Url : e.FileName,
                FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis,
            });
            left.Children.Add(new TextBlock
            {
                Text = e.Status + "　" + DownloadItem.FormatSize(e.TotalBytes) + "　" + e.FinishedAt,
                FontSize = 12, Opacity = 0.6,
            });
            g.Children.Add(left);

            var openOne = new Button { Content = "打开位置", MinWidth = 80 };
            var dir = e.Dir;
            openOne.Click += (_, _) => OpenFolder(string.IsNullOrEmpty(dir) ? Aria2Engine.DefaultDir() : dir);
            Grid.SetColumn(openOne, 1);
            g.Children.Add(openOne);

            HistoryPanel.Children.Add(new Border
            {
                Background = UiKit.SubtleFill,
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(10, 8, 10, 8),
                Child = g,
            });
        }
    }

    // ── 工具栏动作 ────────────────────────────────────────────

    private async void OnPauseAllClick(object sender, RoutedEventArgs e)
    {
        var targets = _feed.AllItems()
            .Where(i => i.Status is AriaStatus.Active or AriaStatus.Waiting).ToList();
        if (targets.Count == 0) { await ShowInfoAsync("没有正在进行的任务"); return; }

        // **先给回执再动手**（2026-10-28）：几百个任务逐个 RPC 要几秒到十几秒，
        // 原来期间界面毫无反应，用户只会觉得「按了没用」。
        ToolbarHint.Text = $"正在暂停 {targets.Count} 个任务…";
        PauseAllButton.IsEnabled = false;

        // **一次 RPC 批量暂停**（2026-10-28）：原来逐条调，几百个任务时
        // aria2 串行处理要排队几分钟，界面看着就像「按了没用」。
        var ok = DownloadStore.Instance.PauseManyAsync(targets, toPaused: true);

        await RefreshAsync();
        PauseAllButton.IsEnabled = true;

        await ShowInfoAsync($"已暂停 {ok.Result} 个任务（后台正在通知下载器）");


    }

    private async void OnResumeAllClick(object sender, RoutedEventArgs e)
    {
        var targets = _feed.AllItems().Where(i => i.Status == AriaStatus.Paused).ToList();
        if (targets.Count == 0) { await ShowInfoAsync("没有已暂停的任务"); return; }

        ToolbarHint.Text = $"正在继续 {targets.Count} 个任务…";
        ResumeAllButton.IsEnabled = false;

        // 与暂停同一条路：本地先翻状态，RPC 后台跑（不阻塞界面）。
        var n = DownloadStore.Instance.PauseManyAsync(targets, toPaused: false).Result;

        await RefreshAsync();
        ResumeAllButton.IsEnabled = true;
        await ShowInfoAsync($"已继续 {n} 个任务（后台正在通知下载器）");
    }

    private async void OnClearCompletedClick(object sender, RoutedEventArgs e)
    {
        // 只清本模块的终态任务：aria2 的 purge 是全局的，不能连带清掉别的模块。
        var targets = _feed.AllItems()
            .Where(i => i.Status is AriaStatus.Complete or AriaStatus.Error or AriaStatus.Removed)
            .ToList();
        foreach (var it in targets)
        {
            try { await DownloadStore.Instance.RemoveAsync(it); }
            catch { }
        }
        await RefreshAsync();
    }

    private async void OnRetryAllClick(object sender, RoutedEventArgs e)
    {
        // 「错误」Tab 里没有可重试的东西时按钮是禁用的，这里只防一手。
        var failed = _feed.AllItems().Where(i => i.Status == AriaStatus.Error).ToList();
        if (failed.Count == 0) { await ShowInfoAsync("没有可重试的任务"); return; }

        ToolbarHint.Text = $"正在重试 {failed.Count} 个任务…";
        RetryAllButton.IsEnabled = false;
        var ok = 0;
        foreach (var it in failed)
        {
            if (await RetryAsync(it)) ok++;
        }

        await RefreshAsync();
        RetryAllButton.IsEnabled = true;

        // 结局汇总成一条提示：几十条失败各弹一个对话框等于没有提示。
        await ShowInfoAsync(ok == failed.Count
            ? $"已重新排队 {ok} 个任务"
            : $"已重新排队 {ok} / {failed.Count} 个任务（其余仍失败，可能是源已失效）");
    }

    /// <summary>
    /// 重新入队一条错误任务：先移除旧记录，再按原 URL / 模块 / 目标文件名重新投递。
    /// 返回是否投递成功。批量重试逐条走同一条路，避免「单条能重试、批量把台账弄丢」。
    /// </summary>
    private static async System.Threading.Tasks.Task<bool> RetryAsync(DownloadItem item)
    {
        try
        {
            await DownloadStore.Instance.RemoveAsync(item);
            var (ok, _) = await DownloadStore.Instance.AddAsync(
                item.Url,
                item.Module,
                string.IsNullOrEmpty(item.Dir) ? null : item.Dir,
                string.IsNullOrEmpty(item.FileName) ? null : item.FileName);
            return ok;
        }
        catch
        {
            return false;
        }
    }

    private void OnOpenDirClick(object sender, RoutedEventArgs e) => OpenFolder(Aria2Engine.DefaultDir());

    /// <summary>
    /// 合并音视频 —— **只在 B 站模式可见**（见 <see cref="DownloadFeed.SupportsMerge"/>）。
    /// B 站 dash 把视频与音频分成两个文件，不合就是一个只有画面没声音的 mp4。
    /// </summary>
    private async void OnMergeClick(object sender, RoutedEventArgs e)
    {
        var dir = Aria2Engine.DefaultDir();
        var pairs = MediaMerger.FindPairs(dir);
        if (pairs.Count == 0)
        {
            await ShowInfoAsync("没有找到可合并的配对（需要同名的视频 + 音频文件）");
            return;
        }

        var okCount = 0;
        var failCount = 0;
        var lastErr = "";
        foreach (var (video, audio, output) in pairs)
        {
            var r = await MediaMerger.MergeAsync(video, audio, output);
            if (r.Ok) okCount++;
            else { failCount++; lastErr = r.Message; }
        }

        await ShowInfoAsync(failCount == 0
            ? $"合并完成 {okCount} 个"
            : $"合并完成 {okCount} 个，失败 {failCount} 个。最后错误：{lastErr}");
    }

    // ── 通用件 ────────────────────────────────────────────────

    private static void OpenFolder(string dir)
    {
        try
        {
            System.IO.Directory.CreateDirectory(dir);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = dir,
                UseShellExecute = true,
            });
        }
        catch { }
    }

    /// <summary>用 ContentDialog 报结果。批量操作必须给回执，不能静默。</summary>
    private async System.Threading.Tasks.Task ShowInfoAsync(string message)
    {
        try
        {
            var dlg = new ContentDialog
            {
                Title = "提示",
                Content = message,
                CloseButtonText = "知道了",
                XamlRoot = XamlRoot,
            };
            await dlg.ShowAsync();
        }
        catch
        {
            // XamlRoot 还没准备好时（页面未加载完）忽略，避免崩溃
        }
    }

    private UIElement BuildRow(DownloadItem item)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var texts = new StackPanel { Spacing = 4 };
        texts.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(item.FileName) ? item.Url : item.FileName,
            FontSize = 13,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });

        texts.Children.Add(new ProgressBar
        {
            Value = item.Progress * 100,
            Maximum = 100,
            Height = 3,
            Margin = new Thickness(0, 2, 0, 2),
        });

        var meta = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        meta.Children.Add(new TextBlock { Text = item.StatusText, FontSize = 12, Opacity = 0.7 });
        meta.Children.Add(new TextBlock { Text = item.ProgressText, FontSize = 12, Opacity = 0.7 });
        if (!string.IsNullOrEmpty(item.SpeedText))
            meta.Children.Add(new TextBlock { Text = item.SpeedText, FontSize = 12, Opacity = 0.7 });
        if (!string.IsNullOrEmpty(item.Error))
            meta.Children.Add(new TextBlock
            {
                Text = item.Error, FontSize = 12, Opacity = 0.7,
                TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 320,
            });
        texts.Children.Add(meta);
        grid.Children.Add(texts);

        var btns = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var pauseBtn = new Button
        {
            Content = item.Status == AriaStatus.Paused ? "继续" : "暂停",
            MinWidth = 60,
            IsEnabled = item.Status is AriaStatus.Active or AriaStatus.Waiting or AriaStatus.Paused,
        };
        pauseBtn.Click += async (_, _) => { await DownloadStore.Instance.PauseAsync(item); await RefreshAsync(); };
        btns.Children.Add(pauseBtn);

        // 「重试」只在错误态出现 —— 其它状态下它和「暂停/继续」重复。
        if (item.Status == AriaStatus.Error)
        {
            var retryBtn = new Button { Content = "重试", MinWidth = 60 };
            retryBtn.Click += async (_, _) =>
            {
                // 重试 = 先移除旧记录再按原参数重新入队。
                // 不走 DownloadStore 新增接口：那份文件不在本任务的写范围内，
                // 而已有的 RemoveAsync/AddAsync 组合语义等价。
                await RetryAsync(item);
                await RefreshAsync();
            };
            btns.Children.Add(retryBtn);
        }

        var openBtn = new Button { Content = "打开文件夹", MinWidth = 90 };
        openBtn.Click += (_, _) => OpenFolder(string.IsNullOrEmpty(item.Dir) ? Aria2Engine.DefaultDir() : item.Dir);
        btns.Children.Add(openBtn);

        var removeBtn = new Button { Content = "移除", MinWidth = 60 };
        removeBtn.Click += async (_, _) => { await DownloadStore.Instance.RemoveAsync(item); await RefreshAsync(); };
        btns.Children.Add(removeBtn);

        Grid.SetColumn(btns, 1);
        grid.Children.Add(btns);

        return new Border
        {
            Background = UiKit.SubtleFill,
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(12, 10, 12, 10),
            Child = grid,
        };
    }

    // ── 行内按钮（DataTemplate 里的，靠 DataContext 找回 DownloadItem）──────

    private static DownloadItem? ItemOf(object sender)
        => (sender as Microsoft.UI.Xaml.FrameworkElement)?.DataContext as DownloadItem;

    private async void OnRowPauseClick(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { } it) return;
        try { await DownloadStore.Instance.PauseAsync(it); } catch { }
        await RefreshAsync();
    }

    private async void OnRowRetryClick(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { } it) return;
        var ok = await RetryAsync(it);
        if (!ok) await ShowInfoAsync("重试失败：源可能已失效");
        await RefreshAsync();
    }

    private void OnRowOpenFolderClick(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { } it) return;
        OpenFolder(string.IsNullOrEmpty(it.Dir) ? Aria2Engine.DefaultDir() : it.Dir);
    }

    private async void OnRowRemoveClick(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { } it) return;
        await DownloadStore.Instance.RemoveAsync(it);
        await RefreshAsync();
    }

    // ── 一键清空整个下载列表（用户 2026-10-28）────────────────────

    /// <summary>
    /// 清空本模块的**全部**下载任务（不只是已完成的）。
    ///
    /// 与「清除已完成」的区别：那个只清终态（完成/错误/移除），
    /// 这个连正在下载、等待中的一起清掉 —— 用户要的是「列表归零重来」。
    /// 会先确认，避免误点。**只影响本模块**，不碰其它模块的队列。
    /// </summary>
    private async void OnClearAllClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var all = _feed.AllItems();
            if (all.Count == 0) { await ShowInfoAsync("列表已经是空的"); return; }

            var dlg = new ContentDialog
            {
                Title = "清空下载列表？",
                Content = "将移除本模块的全部 " + all.Count + " 个任务（含正在下载的）。" + Environment.NewLine
                          + "已下载到磁盘的文件不会被删除。",
                PrimaryButtonText = "清空",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = XamlRoot,
            };
            var r = await dlg.ShowAsync();
            if (r != ContentDialogResult.Primary) return;

            ClearAllButton.IsEnabled = false;
            ToolbarHint.Text = "正在清空 " + all.Count + " 个任务…";

            // 本地先清空 + 后台通知 aria2（逐条 await 会让 188 条清几分钟）
            var ok = DownloadStore.Instance.RemoveManyAsync(all).Result;

            await RefreshAsync();
            ClearAllButton.IsEnabled = true;
            await ShowInfoAsync("已清空 " + ok + " / " + all.Count + " 个任务");
        }
        catch (Exception ex)
        {
            // **不静默吞**：清空失败必须让人知道，否则看起来就是「按了没反应」。
            ClearAllButton.IsEnabled = true;
            try { await ShowInfoAsync("清空失败：" + ex.Message); } catch { }
        }
    }

    // ── 「任务创建中」区块（对齐原项目 CreationTasks）─────────────────

    /// <summary>
    /// 渲染顶部「共 N 个任务创建中」区块。
    ///
    /// 只有 X 侧会显示（原项目注释：那是 X 的翻页抓取概念），
    /// 抖音/B 站走的是另一套入队路径，没有这个区块。
    /// 内容签名没变就不重建，避免闪。
    /// </summary>
    private void RenderCreation()
    {
        var tasks = CreationTaskStore.Instance.Tasks;

        // 只有 X 模块显示
        if (!_feed.ModuleKeys.Contains("X 媒体"))
        {
            if (CreationCard.Visibility == Visibility.Visible)
                CreationCard.Visibility = Visibility.Collapsed;
            _creationSignature = "";
            return;
        }

        // **任务跑完了要留一条结果**（2026-10-29）：
        // 之前跑完立刻摘掉、区块瞬间消失，用户完全不知道结果 ——
        // 全部跳过时会以为「下载卡住了」。现在把最后一条的结果留在工具栏上。
        if (tasks.Count == 0)
        {
            if (CreationCard.Visibility == Visibility.Visible)
                CreationCard.Visibility = Visibility.Collapsed;
            _creationSignature = "";

            var done = CreationTaskStore.Instance.LastFinished;
            if (done is not null && _lastCreationResult != done.Id)
            {
                _lastCreationResult = done.Id;
                ToolbarHint.Text = done.DisplayName + "：" + done.ResultText;
            }
            return;
        }

        var sig = tasks.Count + "|" + string.Join((char)44,
            tasks.Select(x => x.Id + ":" + x.CompleteCount + ":" + x.SkipCount + ":" + (x.Error ?? "")));
        if (sig == _creationSignature) return;
        _creationSignature = sig;

        CreationCard.Visibility = Visibility.Visible;
        var active = CreationTaskStore.Instance.ActiveTask;
        CreationTitle.Text = active is not null
            ? "共 " + tasks.Count + " 个任务创建中"
            : "共 " + tasks.Count + " 个任务排队中";

        CreationList.Children.Clear();
        foreach (var task in tasks)
        {
            var g = new Grid { ColumnSpacing = 8 };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var name = new TextBlock
            {
                Text = task.DisplayName + (string.IsNullOrEmpty(task.ScreenName) ? "" : "  @" + task.ScreenName),
                FontSize = 12.5,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            g.Children.Add(name);

            var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            right.Children.Add(new TextBlock
            {
                Text = task.Error is not null ? ("失败：" + task.Error) : task.ProgressText,
                FontSize = 11.5,
                Opacity = task.Error is not null ? 0.9 : 0.6,
                Foreground = task.Error is not null
                    ? (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"]
                    : null,
                VerticalAlignment = VerticalAlignment.Center,
            });

            var cancel = new Button { Content = "取消", MinWidth = 52, Padding = new Thickness(8, 2, 8, 2) };
            var id = task.Id;
            cancel.Click += (_, _) => CreationTaskStore.Instance.Cancel(id);
            right.Children.Add(cancel);

            Grid.SetColumn(right, 1);
            g.Children.Add(right);

            CreationList.Children.Add(g);
        }
    }

    private void OnCancelCreationClick(object sender, RoutedEventArgs e)
    {
        var active = CreationTaskStore.Instance.ActiveTask;
        if (active is not null) CreationTaskStore.Instance.Cancel(active.Id);
        RenderCreation();
    }

    // ── 缩略图加载（用户 2026-10-28 要求「加预览图」）────────────────

    private static readonly System.Net.Http.HttpClient _thumbHttp = CreateThumbHttp();

    private static System.Net.Http.HttpClient CreateThumbHttp()
    {
        var h = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        // X 的图床需要 UA，否则 403。
        h.DefaultRequestHeaders.UserAgent.ParseAdd(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36");
        return h;
    }

    /// <summary>缩略图缓存（URL → BitmapImage），避免滚动时重复下载。</summary>
    private static readonly Dictionary<string, Microsoft.UI.Xaml.Media.Imaging.BitmapImage> _thumbCache = new();

    /// <summary>
    /// 给一行的预览图控件塞图片。
    ///
    /// 列表是虚拟化的，容器会复用，所以每次生成容器时都要**重新按当前 DataContext 取图**。
    /// 图片下载失败静默忽略（占位灰底还在，不能因为一张图挂掉整个列表）。
    /// </summary>
    private static async void LoadThumb(Image image, string url)
    {
        if (string.IsNullOrEmpty(url)) return;

        if (_thumbCache.TryGetValue(url, out var cached))
        {
            image.Source = cached;
            return;
        }

        try
        {
            var bytes = await _thumbHttp.GetByteArrayAsync(url);
            if (bytes.Length == 0) return;

            var bmp = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
            using var ms = new MemoryStream(bytes);
            var ras = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            using (var w = new Windows.Storage.Streams.DataWriter(ras.GetOutputStreamAt(0)))
            {
                w.WriteBytes(bytes);
                await w.StoreAsync();
                await w.FlushAsync();
                w.DetachStream();
            }
            ras.Seek(0);
            await bmp.SetSourceAsync(ras);

            _thumbCache[url] = bmp;
            image.Source = bmp;
        }
        catch { }
    }

    /// <summary>列表容器生成/复用时，按当前 DataContext 重新加载预览图。</summary>
    private void OnTaskContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is not DownloadItem item) return;
        var thumb = FindThumb(args.ItemContainer.ContentTemplateRoot as DependencyObject);
        if (thumb is not null) LoadThumb(thumb, item.ThumbUrl);
    }

    private static Image? FindThumb(DependencyObject? root)
    {
        if (root is null) return null;
        if (root is Image img) return img;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var found = FindThumb(VisualTreeHelper.GetChild(root, i));
            if (found is not null) return found;
        }
        return null;
    }
}
