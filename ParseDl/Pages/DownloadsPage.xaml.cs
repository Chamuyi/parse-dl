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

    /// <summary>
    /// 粘性工具栏提示（2026-10-29 修「点了没反应」）。
    ///
    /// **为什么需要**：RenderToolbarState 每 0.8 秒都会把 ToolbarHint 改回
    /// 「本模块 N 个任务」—— 于是任何操作回执（「已暂停 3 个」「已加入 12 个，跳过 3 个」）
    /// 最多显示 0.8 秒就被抹掉，用户看到的就是「按了没反应」。
    /// 现在回执带到期时间，未到期就不被覆盖。
    /// </summary>
    private string _stickyHint = "";
    private DateTime _stickyUntil = DateTime.MinValue;

    /// <summary>写一条会保留几秒的工具栏提示（期间不被轮询覆盖）。</summary>
    private void SetStickyHint(string message, int seconds = 8)
    {
        _stickyHint = message ?? "";
        _stickyUntil = DateTime.Now.AddSeconds(seconds);
        if (ToolbarHint is not null) ToolbarHint.Text = _stickyHint;
    }

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
        // **ItemsSource 只在进页面时设一次**（2026-10-29 修闪烁）：
        // 之后所有变化都走 ObservableCollection 的增量通知，
        // 绝不再整表替换 —— 那是 ListView 全量重建容器的根源。
        TaskList.ItemsSource = _visibleTasks;

        UiRefresh();

        _ = EnsureEngineThenRefreshAsync();

        // **订阅创建任务队列的变化**（2026-10-29）：
        // 之前完全没有订阅 —— 只能靠每 0.8 秒的本地重绘碰运气，
        // 而重绘只读 CreationTaskStore.Tasks，计数变了也不会额外触发，
        // 于是「已发送 / 已跳过」看起来长期不动。
        CreationTaskStore.Instance.Changed -= OnCreationChanged;
        CreationTaskStore.Instance.Changed += OnCreationChanged;
        StartTimer();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        StopTimer();
        CreationTaskStore.Instance.Changed -= OnCreationChanged;
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
                    SetStickyHint("已恢复上次未完成的 " + n + " 个任务");
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
        RenderCreation();
        RenderToolbarState();
    }

    private void RenderTasks()
    {
        // **ListView 的 ItemsSource 只设一次，之后全部走「增量同步」**（2026-10-29 修闪烁）。
        //
        // 之前每次渲染都 `TaskList.ItemsSource = items`（items 是 ToList() 出来的新 List）——
        // **整表替换**会让 ListView 丢弃全部容器重新生成，用户看到的就是「列表一闪一闪」。
        // 之前用「内容签名」挡了一层，但签名挡不住真正的场景：
        // 批量下载时每入队一条、每完成一条，**集合本身**都在变，签名必然变，
        // 于是整表还是被反复重设 —— 仿真队列（一次性加完）测不出来，实机就闪。
        //
        // 现在：持有一个长期存在的 ObservableCollection，按目标列表做「删多余 / 移位 / 补缺」，
        // ListView 只重绘真正变动的那些行，滚动位置与选中态也不会被打断。
        var items = _feed.ItemsFor(_tab);

        // 切 Tab 时整批都换了，直接清空重建，避免逐条 Move 的抖动。
        if (!string.Equals(_syncedTabTitle, _tab.Title, StringComparison.Ordinal))
        {
            _syncedTabTitle = _tab.Title;
            _visibleTasks.Clear();
        }

        if (items.Count == 0)
        {
            // **空态用独立的 TextBlock，不往 ItemsSource 里塞控件**（2026-10-28 修闪退）：
            // ItemTemplate 声明了 x:DataType=DownloadItem，塞别的对象会 x:Bind cast 失败
            // → InvalidCastException → 整个程序闪退（crash.log 里抓到过）。
            if (_visibleTasks.Count > 0) _visibleTasks.Clear();
            TaskList.Visibility = Visibility.Collapsed;
            EmptyHint.Visibility = Visibility.Visible;
            EmptyTitle.Text = "「" + _tab.Title + "」里还没有任务";
            EmptyDetail.Text = _feed.EmptyHint;
            return;
        }

        TaskList.Visibility = Visibility.Visible;
        EmptyHint.Visibility = Visibility.Collapsed;

        SyncVisibleTasks(items);
    }

    /// <summary>
    /// 把 <see cref="_visibleTasks"/> 增量同步成 <paramref name="target"/> 的样子。
    ///
    /// 只动真正有差异的行：多出来的删、缺的插、位置不对的 Move。
    /// **绝不整体替换 ItemsSource** —— 那会让 ListView 全量重建容器，就是「一闪一闪」的来源。
    /// </summary>
    private void SyncVisibleTasks(List<DownloadItem> target)
    {
        var wanted = new HashSet<DownloadItem>(target);
        var added = 0; var removed = 0; var moved = 0;


        // ① 删掉目标里没有的（从后往前，避免索引位移）
        for (var i = _visibleTasks.Count - 1; i >= 0; i--)
        {
            if (!wanted.Contains(_visibleTasks[i])) { _visibleTasks.RemoveAt(i); removed++; }
        }

        // ② 按目标顺序补齐 / 移位
        for (var i = 0; i < target.Count; i++)
        {
            var want = target[i];
            if (i < _visibleTasks.Count && ReferenceEquals(_visibleTasks[i], want)) continue;

            var existing = _visibleTasks.IndexOf(want);
            if (existing >= 0) { _visibleTasks.Move(existing, i); moved++; }
            else { _visibleTasks.Insert(i, want); added++; }
        }
        _syncCount++;
        if (added > 0 || removed > 0 || moved > 0)
        {
            Aria2Engine.Log("[列表同步] 第 " + _syncCount + " 次：新增=" + added
                + " 删除=" + removed + " 移位=" + moved
                + " 当前行数=" + _visibleTasks.Count);
        }
    }

    /// <summary>当前真正绑在 ListView 上的集合（长期存在，只做增量变动）。</summary>
    private readonly System.Collections.ObjectModel.ObservableCollection<DownloadItem> _visibleTasks = new();

    /// <summary>上一次同步用的 Tab 标题（切 Tab 时整批换，需清空重建）。</summary>
    private string _syncedTabTitle = "";


    /// <summary>渲染同步次数（仅用于诊断日志，验证「不再整表重建」）。</summary>
    private int _syncCount;

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

        // **粘性提示优先**（2026-10-29）：操作回执要能留住，
        // 否则每 0.8 秒被这里覆盖回「本模块 N 个任务」，用户以为按钮没用。
        var baseHint = DownloadStore.Instance.EngineReady
            ? (all.Count == 0 ? "暂无任务" : $"本模块 {all.Count} 个任务")
            : "aria2 未启动";
        if (_stickyHint.Length > 0 && DateTime.Now < _stickyUntil)
            ToolbarHint.Text = _stickyHint;
        else
        {
            _stickyHint = "";
            ToolbarHint.Text = baseHint;
        }

        var ready = DownloadStore.Instance.EngineReady;
        EngineBanner.Visibility = ready ? Visibility.Collapsed : Visibility.Visible;
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

    /// <summary>上一次重试是不是因为「签名过期」被拒的（给提示文案用）。</summary>
    private static bool LastRetryExpired;

    private async void OnRetryAllClick(object sender, RoutedEventArgs e)
    {
        // 「错误」Tab 里没有可重试的东西时按钮是禁用的，这里只防一手。
        var failed = _feed.AllItems().Where(i => i.Status == AriaStatus.Error).ToList();
        if (failed.Count == 0) { await ShowInfoAsync("没有可重试的任务"); return; }

        // **先分出「签名已过期」的那批**（2026-10-31 用户报「上千个错误任务，
        // 重试后仍旧无法下载」）：这些重试一万次也没用，必须重新抓取。
        // 单独统计出来，别把它混进「重试成功/失败」里让人以为还有救。
        var expiredOnes = failed.Where(i => SignedUrl.IsExpired(i.Url)).ToList();

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
        var msg = ok == failed.Count
            ? $"已重新排队 {ok} 个任务"
            : $"已重新排队 {ok} / {failed.Count} 个任务（其余仍失败，可能是源已失效）";
        if (expiredOnes.Count > 0)
        {
            msg += "\n\n其中 " + expiredOnes.Count + " 个是**下载签名已过期**的链接"
                 + "（抖音直链带时效，过期后一律 403）。"
                 + "这些重试没有意义，需要回抖音页重新抓取才能拿到新链接。";
        }
        await ShowInfoAsync(msg);
    }

    /// <summary>
    /// 重新入队一条错误任务：先移除旧记录，再按原 URL / 模块 / 目标文件名重新投递。
    /// 返回是否投递成功。批量重试逐条走同一条路，避免「单条能重试、批量把台账弄丢」。
    /// </summary>
    private static async System.Threading.Tasks.Task<bool> RetryAsync(DownloadItem item)
    {
        try
        {
            // **过期链接不再直接拒掉，改成现取新地址**（2026-11-01）。
            //
            // 原来这里是「过期 → return false」，只给用户一句「需重新抓取」，
            // 等于把活推回给人。现在按作品 ID 现取一份新鲜直链再提交：
            // 页面自己带签名请求，拦截器抄响应，签名怎么变都不用跟着改。
            // 取不到才把「作者 + 作品 ID + 链接」写进错误信息，让用户手动处理。
            var url = item.Url;
            if (SignedUrl.IsExpired(url))
            {
                LastRetryExpired = true;
                var fresh = await ParseDl.Services.Douyin.DouyinAddressResolver
                    .ResolveAnyAsync(item.AwemeId ?? "", item.MediaIndex);
                if (!fresh.Ok)
                {
                    item.Error = "重试失败（链接已过期且取址失败：" + fresh.Message + "）"
                                 + "｜作者：" + (string.IsNullOrEmpty(item.Author) ? "未知" : item.Author)
                                 + "｜作品：" + (string.IsNullOrEmpty(item.AwemeId)
                                     ? "（无 ID）"
                                     : "https://www.douyin.com/video/" + item.AwemeId);
                    return false;
                }
                url = fresh.Url;
            }

            await DownloadStore.Instance.RemoveAsync(item);
            var (ok, _) = await DownloadStore.Instance.AddAsync(
                url,
                item.Module,
                string.IsNullOrEmpty(item.Dir) ? null : item.Dir,
                string.IsNullOrEmpty(item.FileName) ? null : item.FileName,
                awemeId: item.AwemeId,
                mediaIndex: item.MediaIndex);
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

    /// <summary>
    /// 报操作结果 —— **用工具栏的提示文字，不弹对话框**（2026-10-29 用户要求「提示框删了」）。
    ///
    /// 批量操作确实要给回执（不能静默），但每次点「全部暂停」「清空列表」
    /// 都弹一个模态框、还得点「知道了」才能继续，很打断操作。
    /// 工具栏那行 `ToolbarHint` 本来就是干这个的，写那儿就行。
    /// </summary>
    private System.Threading.Tasks.Task ShowInfoAsync(string message)
    {
        try
        {
            SetStickyHint(message);
        }
        catch { }
        return System.Threading.Tasks.Task.CompletedTask;
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
        LastRetryExpired = false;
        var ok = await RetryAsync(it);
        if (!ok)
        {
            await ShowInfoAsync(LastRetryExpired
                ? "这个链接的下载签名已经过期（抖音直链带时效）。\n\n重试没用，需要回抖音页重新抓取一次，才能拿到新链接。"
                : "重试失败：源可能已失效");
        }
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
    /// <summary>创建任务队列变化 → 抛回 UI 线程重绘区块。</summary>
    private void OnCreationChanged()
    {
        if (DispatcherQueue is null) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            RenderCreation();
        });
    }

    private void RenderCreation()
    {
        var tasks = CreationTaskStore.Instance.Tasks;

        // 只有 X 模块显示
        if (!_feed.ModuleKeys.Contains("X 媒体"))
        {
            if (CreationCard.Visibility == Visibility.Visible)
                CreationCard.Visibility = Visibility.Collapsed;
            _creationSignature = "";
            _creationRows.Clear();
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
            _creationRows.Clear();

            var done = CreationTaskStore.Instance.LastFinished;
            if (done is not null && _lastCreationResult != done.Id)
            {
                _lastCreationResult = done.Id;
                SetStickyHint(done.DisplayName + "：" + done.ResultText, 12);
            }
            return;
        }

        // **结构签名只含「有哪些任务」**（2026-10-29 修闪烁）。
        // 之前签名里带了 CompleteCount / SkipCount —— 每翻一页计数就变，
        // 于是 CreationList.Children.Clear() 再逐行重建，整个区块持续闪。
        // 现在计数变化只改行内 TextBlock 的文字，控件本身不重建。
        var sig = string.Join((char)44, tasks.Select(x => x.Id));
        var structureChanged = sig != _creationSignature;
        _creationSignature = sig;

        CreationCard.Visibility = Visibility.Visible;
        var active = CreationTaskStore.Instance.ActiveTask;
        // 「已发送 / 已跳过」**不放在标题里**（2026-10-29 用户要求位置对齐原项目）：
        // 原项目 lib/pages/download_management_page.dart 的 _CreationTasksSection
        // 标题行只有「共 N 个任务创建中」+ 一句说明；两个计数在 _CreationTaskRow 的**行内**、
        // 昵称右侧。
        var title = active is not null
            ? "共 " + tasks.Count + " 个任务创建中"
            : "共 " + tasks.Count + " 个任务排队中";
        if (CreationTitle.Text != title) CreationTitle.Text = title;

        if (structureChanged)
        {
            CreationList.Children.Clear();
            _creationRows.Clear();
        }

        foreach (var task in tasks)
        {
            if (!_creationRows.TryGetValue(task.Id, out var row))
            {
                row = BuildCreationRow(task);
                _creationRows[task.Id] = row;
                CreationList.Children.Add(row.Root);
            }
            UpdateCreationRow(row, task);
        }
    }

    /// <summary>一行「创建中」任务里需要就地更新的控件引用。</summary>
    private sealed class CreationRow
    {
        public Grid Root = null!;
        public TextBlock Sent = null!;
        public TextBlock Skip = null!;
        public TextBlock Fail = null!;
    }

    private readonly Dictionary<string, CreationRow> _creationRows = new();

    /// <summary>建一行（**只在任务集合变化时建**，计数变化走 UpdateCreationRow）。</summary>
    private CreationRow BuildCreationRow(CreationTask task)
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
        // 计数放**行内、昵称右侧**，与原项目 _CreationTaskRow 一致（2026-10-29）。
        // 原项目文案带全角冒号：「已发送：N」「已跳过：N」。
        var sent = new TextBlock
        {
            Text = "已发送：0",
            FontSize = 11.5,
            Opacity = 0.6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        right.Children.Add(sent);

        var skipRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 3,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        var skip = new TextBlock
        {
            Text = "已跳过：0",
            FontSize = 11.5,
            Opacity = 0.6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        skipRow.Children.Add(skip);
        var skipTip = new FontIcon
        {
            Glyph = "\uE897", // Help
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.6,
        };
        ToolTipService.SetToolTip(skipTip,
            "以下几种情况会跳过：\n"
            + "1. 文件名已存在且开启了「跳过相同文件」开关；\n"
            + "2. 推文时间超出设定的日期范围。");
        skipRow.Children.Add(skipTip);
        right.Children.Add(skipRow);

        var fail = new TextBlock
        {
            Text = "失败：0",
            FontSize = 11.5,
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"],
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        right.Children.Add(fail);

        var cancel = new Button { Content = "取消", MinWidth = 52, Padding = new Thickness(8, 2, 8, 2) };
        var id = task.Id;
        cancel.Click += (_, _) => CreationTaskStore.Instance.Cancel(id);
        right.Children.Add(cancel);

        Grid.SetColumn(right, 1);
        g.Children.Add(right);

        return new CreationRow { Root = g, Sent = sent, Skip = skip, Fail = fail };
    }

    /// <summary>就地刷新一行里的三个计数（不碰控件树）。</summary>
    private static void UpdateCreationRow(CreationRow row, CreationTask task)
    {
        var sent = "已发送：" + task.CompleteCount;
        if (row.Sent.Text != sent) row.Sent.Text = sent;

        var skip = "已跳过：" + task.SkipCount;
        if (row.Skip.Text != skip) row.Skip.Text = skip;
        var skipVisible = task.SkipCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (row.Skip.Parent is FrameworkElement skipRow && skipRow.Visibility != skipVisible)
            skipRow.Visibility = skipVisible;

        var fail = task.Error is not null ? "失败：" + task.Error : "失败：" + task.FailCount;
        if (row.Fail.Text != fail) row.Fail.Text = fail;
        var failVisible = (task.FailCount > 0 || task.Error is not null)
            ? Visibility.Visible : Visibility.Collapsed;
        if (row.Fail.Visibility != failVisible) row.Fail.Visibility = failVisible;
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

    /// <summary>缩略图字节缓存（URL → 图片字节）。**存字节不存 BitmapImage**：</summary>
    /// 同一个 ImageSource 实例塞给多个 Image 容器会抛异常，所以每次按字节新建 BitmapImage。
    private static readonly Dictionary<string, byte[]> _thumbCache = new();

    /// <summary>每个 Image 控件当前已渲染的 URL —— 防止同一张图被反复重设导致图片区闪。</summary>
    private static readonly Dictionary<Microsoft.UI.Xaml.Controls.Image, string> _renderedUrl = new();

    /// <summary>
    /// 给一行的预览图控件塞图片。
    ///
    /// 列表是虚拟化的，容器会复用，所以每次生成容器时都要**重新按当前 DataContext 取图**。
    /// 图片下载失败静默忽略（占位灰底还在，不能因为一张图挂掉整个列表）。
    /// </summary>
    private static async void LoadThumb(Image image, string url)
    {
        if (string.IsNullOrEmpty(url))
        {
            if (image.Source is not null) { image.Source = null; _renderedUrl.Remove(image); }
            return;
        }

        // **已经是这张图就直接返回**（2026-10-29 修「图片区闪」）。
        //
        // ContainerContentChanging 每次容器内容变化都会调到这里，OnThumbLoaded 也会 ——
        // 同一个容器一次刷新里可能被调用好几次。若每次都重新 SetSourceAsync，
        // 图片会「先空白 → 再出图」，肉眼就是一闪一闪。
        if (_renderedUrl.TryGetValue(image, out var cur) && cur == url && image.Source is not null)
            return;

        _renderedUrl[image] = url;

        // **缓存的必须是字节，不是 BitmapImage**：同一个 ImageSource 实例塞给多个
        // Image 容器会抛异常，而列表容器是虚拟化复用的 —— 一张图会被多行同时引用。
        if (_thumbCache.TryGetValue(url, out var cachedBytes))
        {
            await SetImageSource(image, cachedBytes, url);
            return;
        }

        try
        {
            // **本地文件（file://）不能走 HttpClient**（2026-10-30 加）：
            // 实况视频的预览图是磁盘上已有的 jpg，用 Uri.LocalPath 直接读字节。
            byte[] bytes;
            if (url.StartsWith("file://", StringComparison.OrdinalIgnoreCase))
            {
                var local = new Uri(url).LocalPath;
                bytes = await System.IO.File.ReadAllBytesAsync(local);
            }
            else
            {
                bytes = await _thumbHttp.GetByteArrayAsync(url);
            }
            if (bytes.Length == 0)
            {
                Aria2Engine.Log("[缩略图] 空字节：" + url);
                _renderedUrl.Remove(image);
                return;
            }

            _thumbCache[url] = bytes;
            await SetImageSource(image, bytes, url);
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[缩略图] 下载失败：" + url + " → " + ex.GetType().Name + ": " + ex.Message);
            _renderedUrl.Remove(image);   // 撤掉标记，下次容器复用时可重试一次
        }
    }

    /// <summary>把图片字节设成 Image.Source（每次新建 BitmapImage，避免跨容器共享实例）。</summary>
    /// <summary>把图片字节设成 Image.Source（每次新建 BitmapImage，避免跨容器共享实例）。</summary>
    private static async Task SetImageSource(Image image, byte[] bytes, string url)
    {
        try
        {
            var bmp = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
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
            image.Source = bmp;
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[缩略图] 解码失败：" + url + " → " + ex.Message);
            _renderedUrl.Remove(image);
        }
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

    /// <summary>预览图加载失败：不崩，也不留破图。</summary>
    private void OnThumbFailed(object sender, Microsoft.UI.Xaml.ExceptionRoutedEventArgs e)
    {
        if (sender is Microsoft.UI.Xaml.Controls.Image img) img.Source = null;
    }

    /// <summary>
    /// 把行的 Tag（缩略图 URL 字符串）转成 Image.Source。
    ///
    /// **为什么不能直接 x:Bind ThumbUrl 到 Image.Source**（2026-10-29 踩坑）：
    /// x:Bind 不做隐式类型转换，string → ImageSource 会抛
    /// 「The value cannot be converted to type ImageSource」，
    /// 在 MeasureOverride 里抛 → 0xc000027b 直接闪退（crash.log 抓到过）。
    /// 所以 XAML 里只把 URL 绑到 Tag（string 安全），真正设 Source 走这里。
    /// </summary>
    private void OnThumbLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is not Microsoft.UI.Xaml.Controls.Image img) return;
        var url = img.Tag as string;
        if (string.IsNullOrWhiteSpace(url))
        {
            if (img.Source is not null) img.Source = null;
            return;
        }

        // **必须走缓存**（2026-10-29 修「下载时列表一闪一闪」的真凶之一）。
        //
        // 原来这里是 `img.Source = new BitmapImage(new Uri(url))` —— 每次容器重建
        // 都会**重新发起一次网络请求 + 重新解码**，而且完全没用 _thumbCache。
        // 列表只要有行增删（下载中每入队/每完成一条都会），容器就会重建，
        // 图片区于是反复「空白 → 加载中 → 出图」，肉眼看就是一闪一闪。
        // 现在统一走 LoadThumb（内存缓存 + 已下载的图直接命中，不再发请求）。
        if (img.Source is not null) return;   // 已经有图就别重设，避免闪
        LoadThumb(img, url);
    }
}
