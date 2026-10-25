using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.Douyin;

namespace ParseDl.Pages;

/// <summary>
/// 抖音「自动下载」页 —— 对齐 Flutter 版 lib/pages/douyin_auto_page.dart。
///
/// 抖音没有「按用户取全部作品」的接口，只能真的打开页面往下滚，所以每个目标的
/// 耗时比 X 那边长：打开 → 滚到底（直到轮数上限 / 连续无增长）→ 收集 → 提交。
/// 停止原因必须分开报：「到底了」和「轮数用完了」是两回事，后者意味着这个号的
/// 作品没翻完，用户看到的「下载 N 个」是个不完整的数。
///
/// 本页职责边界：执行循环在这里（需要页面持有的 WebView2），
/// 名单/选项/进度存 DouyinAutoStore（纯数据，切页面不丢）。
/// </summary>
public sealed partial class DouyinAutoPage : Page
{
    private readonly DouyinAutoStore _auto = DouyinAutoStore.Instance;
    private readonly List<string> _log = new();
    private bool _ready;
    private bool _busy;
    private DouyinAutoCollector? _collector;

    public DouyinAutoPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        HeaderHost.Children.Add(UiKit.PageHeader("抖音自动下载",
            "按目标批量滚动抓取 → 收集作品 → 自动提交下载", "\uE945"));

        _auto.Load();
        _auto.Changed += OnAutoChanged;
        BuildAll();
        _ = InitWebAsync();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _auto.Changed -= OnAutoChanged;
        if (_auto.Running) _auto.Stop();
    }

    // ── WebView ────────────────────────────────────────────────

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
            await core.AddScriptToExecuteOnDocumentCreatedAsync(DouyinInterceptor.Script);
            core.WebMessageReceived += OnWebMessage;
            core.NavigationCompleted += (_, _) => WebPlaceholder.Visibility = Visibility.Collapsed;

            _ready = true;
            WebPlaceholder.Visibility = Visibility.Collapsed;
            core.Navigate(DouyinUrl.HomeUrl);
        }
        catch (Exception ex)
        {
            WebPlaceholder.Text = "WebView2 初始化失败：" + ex.Message;
            AppendLog("WebView2 初始化失败：" + ex.Message);
        }
    }

    /// <summary>拦截脚本的批量结果 → 当前目标的收集器。</summary>
    private void OnWebMessage(object? sender, Microsoft.Web.WebView2.Core.CoreWebView2WebMessageReceivedEventArgs e)
    {
        var collector = _collector;
        if (collector is null) return;

        // 拦截脚本 postMessage 传的是对象 → 必须用 WebMessageAsJson（见解析页同样注释）
        string payload;
        try { payload = e.WebMessageAsJson; }
        catch { return; }
        if (string.IsNullOrEmpty(payload)) return;

        var result = DouyinPayloadParser.Parse(payload);
        if (result.Media.Count == 0) return;

        collector.NoteAweme(result.AwemeCount);
        collector.Ingest(result.Media);

        var task = _auto.Current;
        if (task is not null)
        {
            task.AwemeCount = collector.AwemeCount;
            task.MediaCount = collector.Count;
            _auto.Refresh();
        }
    }

    private void OnAutoChanged()
    {
        DispatcherQueue.TryEnqueue(BuildAll);
    }

    // ── 界面 ───────────────────────────────────────────────────

    private void BuildAll()
    {
        BuildTargetCard();
        BuildOptionCard();
        BuildTaskCard();
        BuildLogCard();
        RefreshToolbar();
    }

    private void RefreshToolbar()
    {
        StartButton.IsEnabled = !_busy && _auto.HasTargets;
        StopButton.IsEnabled = _busy && _auto.Running;
        ClearInputButton.IsEnabled = !_busy;

        if (!_auto.HasTargets)
        {
            ProgressText.Text = "先在左侧填入目标（一行一个链接）";
            return;
        }

        var parts = new List<string>
        {
            "已完成 " + _auto.SettledCount + " / " + _auto.Total,
        };
        if (_auto.FailedCount > 0) parts.Add("失败 " + _auto.FailedCount);
        parts.Add("收集 " + _auto.TotalAweme + " 个作品");
        parts.Add("提交 " + _auto.TotalQueued + " 个媒体");
        if (_auto.TotalSkipped > 0) parts.Add("跳过已下载 " + _auto.TotalSkipped);
        if (_auto.Running) parts.Add("运行中…");
        ProgressText.Text = string.Join(" · ", parts);
    }

    private void BuildTargetCard()
    {
        TargetCardHost.Children.Clear();

        var panel = new StackPanel { Spacing = 8 };

        var box = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 140,
            PlaceholderText = "一行一个目标：\n" +
                "https://www.douyin.com/user/MS4wLjABAAAA...（作者主页）\n" +
                "https://www.douyin.com/video/7412345678901234567（作品）\n" +
                "https://v.douyin.com/xxxx/（短链）\n" +
                "7412345678901234567（纯作品 ID）\n" +
                "分享口令整段粘进来也能认",
            Text = _auto.RawText,
            IsEnabled = !_auto.Running,
        };
        box.TextChanged += (_, _) => _auto.SetRawText(box.Text ?? "");
        panel.Children.Add(box);

        var summary = new StackPanel { Spacing = 2 };
        summary.Children.Add(new TextBlock
        {
            Text = "识别到 " + _auto.Total + " 个目标"
                + (_auto.Truncated > 0 ? "（超出上限丢弃 " + _auto.Truncated + " 个）" : ""),
            FontSize = 12,
            Opacity = 0.75,
        });
        if (_auto.Rejected.Count > 0)
        {
            summary.Children.Add(new TextBlock
            {
                Text = "认不出来的 " + _auto.Rejected.Count + " 行：" +
                    string.Join(" / ", _auto.Rejected.Take(3)),
                FontSize = 11,
                Opacity = 0.6,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        panel.Children.Add(summary);

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var importBtn = new Button { Content = "从 txt 导入", MinWidth = 100, IsEnabled = !_auto.Running };
        importBtn.Click += async (_, _) => await ImportFileAsync();
        row.Children.Add(importBtn);
        panel.Children.Add(row);

        TargetCardHost.Children.Add(UiKit.SectionCard("目标名单", panel,
            "上限 " + DouyinAutoStore.MaxTargets + " 个"));
    }

    private void BuildOptionCard()
    {
        OptionCardHost.Children.Clear();

        var panel = new StackPanel { Spacing = 10 };

        // 每个目标最多滚几轮
        var roundRow = new Grid { ColumnSpacing = 8 };
        roundRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        roundRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        roundRow.Children.Add(new TextBlock
        {
            Text = "每个目标最多滚几轮（一轮 ≈ " + DouyinSettings.Current.ScrollIntervalMs + "ms，约 17~20 条/页）",
            FontSize = 13,
            Opacity = 0.8,
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
        });
        var roundCombo = new ComboBox { MinWidth = 120, IsEnabled = !_auto.Running };
        foreach (var r in DouyinAutoStore.RoundChoices) roundCombo.Items.Add(r.ToString());
        var currentRounds = DouyinSettings.Current.MaxRounds;
        var idx = Array.IndexOf(DouyinAutoStore.RoundChoices, currentRounds);
        roundCombo.SelectedIndex = idx >= 0 ? idx : Array.IndexOf(DouyinAutoStore.RoundChoices, 15);
        roundCombo.SelectionChanged += (_, _) =>
        {
            if (roundCombo.SelectedIndex < 0) return;
            var v = DouyinAutoStore.RoundChoices[roundCombo.SelectedIndex];
            DouyinSettings.Mutate(c => c.MaxRounds = v);
        };
        Grid.SetColumn(roundCombo, 1);
        roundRow.Children.Add(roundCombo);
        panel.Children.Add(roundRow);

        // 自动下载开关
        var autoRow = new Grid { ColumnSpacing = 8 };
        autoRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        autoRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        autoRow.Children.Add(new TextBlock
        {
            Text = "收集完自动提交下载（关掉只收集不下载）",
            FontSize = 13,
            Opacity = 0.8,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var autoToggle = new ToggleSwitch { IsOn = _auto.AutoDownload, MinWidth = 0, IsEnabled = !_auto.Running };
        autoToggle.Toggled += (_, _) => _auto.SetAutoDownload(autoToggle.IsOn);
        Grid.SetColumn(autoToggle, 1);
        autoRow.Children.Add(autoToggle);
        panel.Children.Add(autoRow);

        OptionCardHost.Children.Add(UiKit.SectionCard("跑批选项", panel));
    }

    private void BuildTaskCard()
    {
        TaskCardHost.Children.Clear();

        if (_auto.Total == 0)
        {
            TaskCardHost.Children.Add(UiKit.SectionCard("任务队列", new TextBlock
            {
                Text = "还没有目标。填入名单后这里会显示每个目标的进度。",
                FontSize = 12,
                Opacity = 0.6,
                TextWrapping = TextWrapping.Wrap,
            }));
            return;
        }

        var list = new StackPanel { Spacing = 0 };
        for (var i = 0; i < _auto.Tasks.Count; i++)
        {
            var t = _auto.Tasks[i];
            list.Children.Add(BuildTaskRow(i + 1, t, i == _auto.CurrentIndex));
        }
        TaskCardHost.Children.Add(UiKit.SectionCard("任务队列", list,
            "已完成 " + _auto.SettledCount + " / " + _auto.Total));
    }

    private static FrameworkElement BuildTaskRow(int index, DouyinAutoTask t, bool current)
    {
        var grid = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 5, 0, 5) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        grid.Children.Add(new TextBlock
        {
            Text = index.ToString(),
            FontSize = 12,
            Opacity = 0.55,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var texts = new StackPanel { Spacing = 2 };
        texts.Children.Add(new TextBlock
        {
            Text = t.Label,
            FontSize = 13,
            FontWeight = current ? FontWeights.SemiBold : FontWeights.Normal,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        texts.Children.Add(new TextBlock
        {
            Text = t.Summary,
            FontSize = 11,
            Opacity = 0.65,
            TextWrapping = TextWrapping.Wrap,
        });
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);

        var badge = new Border
        {
            Background = UiKit.SubtleFill,
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(8, 3, 8, 3),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = t.Status.Label(),
                FontSize = 11,
                Opacity = t.Status == DouyinAutoStatus.Failed ? 1 : 0.8,
            },
        };
        Grid.SetColumn(badge, 2);
        grid.Children.Add(badge);

        return new Border
        {
            BorderThickness = new Thickness(0, 0, 0, 1),
            BorderBrush = UiKit.CardBorder,
            Child = grid,
        };
    }

    private void BuildLogCard()
    {
        LogCardHost.Children.Clear();
        var box = new TextBox
        {
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 160,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 12,
            Text = string.Join("\n", _log.TakeLast(120)),
            PlaceholderText = "运行日志会显示在这里",
        };
        LogCardHost.Children.Add(UiKit.SectionCard("运行日志", box, _log.Count + " 行"));
    }

    private void AppendLog(string line)
    {
        _log.Add(DateTime.Now.ToString("HH:mm:ss") + "  " + line);
        if (_log.Count > 500) _log.RemoveRange(0, _log.Count - 500);
        BuildLogCard();
    }

    // ── 名单导入 ────────────────────────────────────────────────

    private async Task ImportFileAsync()
    {
        try
        {
            var picker = new Windows.Storage.Pickers.FileOpenPicker();
            picker.FileTypeFilter.Add(".txt");
            // WinUI 3 必须先把 picker 和窗口句柄关联，否则 ShowAsync 抛异常
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

            var file = await picker.PickSingleFileAsync();
            if (file is null) return;
            var text = await Windows.Storage.FileIO.ReadTextAsync(file);
            _auto.SetRawText(text);
            AppendLog("已从 " + file.Name + " 导入名单（" + _auto.Total + " 个目标）");
        }
        catch (Exception ex)
        {
            AppendLog("导入失败：" + ex.Message);
        }
    }

    // ── 跑批 ───────────────────────────────────────────────────

    private void OnClearInputClick(object sender, RoutedEventArgs e)
    {
        _auto.ClearText();
        AppendLog("已清空名单");
    }

    private void OnStopClick(object sender, RoutedEventArgs e)
    {
        _auto.Stop();
        AppendLog("已请求停止，当前目标跑完就结束");
        RefreshToolbar();
    }

    private async void OnStartClick(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        if (!_auto.HasTargets) { AppendLog("先填至少一个目标"); return; }
        if (!_ready) { AppendLog("内嵌浏览器还没就绪，稍等一下再开始"); return; }

        _busy = true;
        RefreshToolbar();
        _auto.Start();
        AppendLog("开始跑批：" + _auto.Total + " 个目标");

        try
        {
            while (_auto.Running && _auto.CurrentIndex < _auto.Total)
            {
                await RunOneAsync();
                if (!_auto.Running) break;
                _auto.Advance();
            }
        }
        finally
        {
            _auto.Stop();
            _collector = null;
            _busy = false;
            RefreshToolbar();
            AppendLog("跑批结束：完成 " + _auto.SettledCount + "/" + _auto.Total +
                "，失败 " + _auto.FailedCount + "，收集 " + _auto.TotalAweme +
                " 个作品，提交 " + _auto.TotalQueued + " 个媒体");
        }
    }

    /// <summary>跑一个目标：打开 → 滚 → 收集 → 提交。</summary>
    private async Task RunOneAsync()
    {
        var task = _auto.Current;
        if (task is null) return;

        _collector = new DouyinAutoCollector();
        task.Reset();
        task.Status = DouyinAutoStatus.Opening;
        _auto.Refresh();
        AppendLog("[" + task.Label + "] 打开页面");

        try
        {
            var core = Web.CoreWebView2;
            var tcs = new TaskCompletionSource<bool>();
            void Handler(object? s, Microsoft.Web.WebView2.Core.CoreWebView2NavigationCompletedEventArgs a)
            {
                core.NavigationCompleted -= Handler;
                tcs.TrySetResult(a.IsSuccess);
            }
            core.NavigationCompleted += Handler;
            core.Navigate(task.Url);

            var navTask = await Task.WhenAny(tcs.Task, Task.Delay(20000));
            if (navTask != tcs.Task) AppendLog("[" + task.Label + "] 打开超时，继续尝试收集");
            if (!_auto.Running) return;

            // 拦截脚本是异步 postMessage 过来的，加载完成那一刻往往还没收到
            await Task.Delay(1800);
            if (!_auto.Running) return;

            task.Status = DouyinAutoStatus.Collecting;
            _auto.Refresh();
            var reason = await CollectAsync();

            if (reason == DouyinAutoScrollStop.ReachedMaxRounds)
            {
                task.Incomplete = true;
                AppendLog("[" + task.Label + "] 轮数用尽（上限 " +
                    DouyinSettings.Current.MaxRounds + " 轮），已抓 " + task.AwemeCount +
                    " 个作品，可能没翻完");
            }
            if (!_auto.Running) return;

            task.Status = DouyinAutoStatus.Downloading;
            _auto.Refresh();
            await SubmitAsync(task);

            task.Status = task.AwemeCount == 0 ? DouyinAutoStatus.Empty : DouyinAutoStatus.Done;
        }
        catch (Exception ex)
        {
            AppendLog("[" + task.Label + "] 失败：" + ex.Message);
            task.Fail(ShortError(ex));
        }
        finally
        {
            var collector = _collector;
            if (collector is not null)
            {
                task.AwemeCount = collector.AwemeCount;
                task.MediaCount = collector.Count;
            }
            _auto.Refresh();
            AppendLog("[" + task.Label + "] " + task.Summary);
        }
    }

    /// <summary>一直往下滚，直到停止条件满足（轮次上限 / 连续无增长 / 用户停止）。</summary>
    private async Task<DouyinAutoScrollStop?> CollectAsync()
    {
        var cfg = DouyinSettings.Current;
        var scroller = new DouyinAutoScroller(
            maxRounds: cfg.MaxRounds,
            stallLimit: cfg.StallLimit,
            interval: TimeSpan.FromMilliseconds(Math.Max(200, cfg.ScrollIntervalMs)));
        scroller.Start();

        while (_auto.Running && scroller.Running)
        {
            string raw;
            try
            {
                raw = await Web.CoreWebView2.ExecuteScriptAsync(DouyinScripts.AutoScroll);
            }
            catch (Exception ex)
            {
                scroller.Stop(DouyinAutoScrollStop.Error);
                AppendLog("滚动脚本出错：" + ex.Message);
                break;
            }

            var report = DouyinAutoScrollReport.Decode(raw);
            var more = scroller.OnRoundResult(report.ScrollHeight);

            var collector = _collector;
            var task = _auto.Current;
            if (collector is not null && task is not null)
            {
                task.AwemeCount = collector.AwemeCount;
                task.MediaCount = collector.Count;
                _auto.Refresh();
            }

            if (!more) break;
            await Task.Delay(scroller.Interval);
        }
        return scroller.StopReason;
    }

    /// <summary>把当前目标收集到的媒体组装并提交给 aria2（与手动下载同一套规则）。</summary>
    private async Task SubmitAsync(DouyinAutoTask task)
    {
        var collector = _collector;
        if (collector is null || collector.Count == 0) return;

        var cfg = DouyinSettings.Current.Clone();
        var batch = DouyinStore.Assemble(collector.Items, cfg, m => DouyinStore.Instance.IsDownloaded(m));
        task.SkippedDownloaded = batch.SkippedDownloaded;
        _auto.Refresh();

        if (!_auto.AutoDownload || batch.Items.Count == 0) return;

        var result = await DouyinEnqueuer.EnqueueAsync(batch.Items, cfg);
        task.Queued = result.Queued;
        _auto.Refresh();
        AppendLog("[" + task.Label + "] " + result.Message);
    }

    private static string ShortError(Exception ex)
    {
        var msg = ex.Message ?? "";
        return msg.Length <= 120 ? msg : msg[..120] + "…";
    }
}
