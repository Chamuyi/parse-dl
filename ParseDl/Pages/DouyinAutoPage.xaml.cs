using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
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
    /// <summary>左右两栏布局所需的最小正文宽度（逻辑像素）。低于它就改成上下两行。</summary>
    private const double TwoPaneMinWidth = 820;

    private readonly DouyinAutoStore _auto = DouyinAutoStore.Instance;
    private readonly List<string> _log = new();
    /// <summary>界面是否已建过一次（本页常驻缓存，OnNavigatedTo 会反复触发）。</summary>
    private bool _built;
    private bool _ready;
    private bool _busy;
    private bool? _wideLayout;
    private DouyinAutoCollector? _collector;

    /// <summary>自动下载的命名模板编辑器（与全局设置共用同一实现）。</summary>
    private TemplateEditor? _autoTemplateEditor;
    private TemplateField? _autoDirField;
    private TemplateField? _autoNameField;

    /// <summary>抖音变量表（转成 TemplateEditor 要的格式）。</summary>
    private static readonly IReadOnlyList<TemplateVarInfo> DouyinAutoTemplateVars =
        DouyinTemplate.Vars.Select(v => new TemplateVarInfo(v.Name, v.Desc, v.ParamExample, v.ParamDesc)).ToList();

    private const string AutoVarHint =
        "文件夹模板建议只用「作者 / 作品」级变量；%IMAGE_INDEX%、%EXT% 这类逐文件的变量" +
        "会让每张媒体各建一个文件夹。";

    /// <summary>自动下载模板区里「最后聚焦的那个模板框」—— 点变量就往这里插。</summary>
    private TextBox? _lastTemplateBox;

    public DouyinAutoPage()
    {
        InitializeComponent();

        // **页面常驻缓存**（2026-10-29 用户要求「点其他页面不影响自动下载」）。
        //
        // 原来每次切页都是 Frame.Navigate 新建实例，旧实例被回收 →
        // 它持有的 WebView2 一起销毁 → 抓取循环（靠 ExecuteScriptAsync 滚页）直接断掉。
        // Required = 实例永不回收，切走再回来还是同一个页面、同一个 WebView2。
        NavigationCacheMode = Microsoft.UI.Xaml.Navigation.NavigationCacheMode.Required;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        // **本页是常驻缓存的**（NavigationCacheMode=Required，见构造函数），
        // 所以 OnNavigatedTo 会**反复**触发。首次进来才建界面、才初始化 WebView；
        // 之后每次回来只要把事件重新挂上、把界面上的状态刷一遍即可 ——
        //
        // 否则会出现：页头越加越多、TryAutoRunForTest 重复跑、BuildAll 把控件重建
        // 导致正在跑的抓取进度显示被打断。（2026-10-29 修「切页会停」）
        if (!_built)
        {
        _built = true;

        // **无人值守测试入口**：
        // UIA 的 SetValue 会吞掉换行符（实测 5 条链接粘成一行、长度 524 无换行），
        // SetFocus 在沉底窗口上又拿不到焦点。所以自动化测试改走环境变量。
        // 只在设置了 PARSE_DL_DOUYIN_TARGETS 时触发，正常使用完全不受影响。
        TryAutoRunForTest();
        HeaderHost.Children.Add(UiKit.PageHeader("抖音自动下载",
            "按目标批量滚动抓取 → 收集作品 → 自动提交下载", "\uE945"));
        }

        _auto.Load();
        // **进页面先补查一次台账**（2026-10-30）：把上次进程遗留的 pending
        // 按 aria2 实际状态补成 done。否则重启后不跑批就永远不会推进，
        // 而「跳过已下载」只认 done —— 那些作品会被当成没下过、重复提交。
        _ = ParseDl.Services.Douyin.DouyinEnqueuer.AdvanceLedgerAsync();
        // 订阅先撤再挂，避免切页多次回来叠加多个 handler（会重复刷新 → 看起来像「闪」）
        _auto.Changed -= OnAutoChanged;
        _auto.Changed += OnAutoChanged;
        ApplyLayout(BodyGrid.ActualWidth);
        BuildAll();
        _ = InitWebAsync();
        RefreshToolbar();   // 把 store 里正在跑的进度刷回界面（切回来立刻看到最新状态）
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _auto.Changed -= OnAutoChanged;

        // **切页不停抓取**（2026-10-29 用户要求「点其他页面不影响自动下载」）。
        //
        // 原来这里无条件 `if (_auto.Running) _auto.Stop();` —— 用户只要点一下
        // 别的导航项，正在滚动的抓取就停了。
        //
        // 现在不停了：页面本身设了 NavigationCacheMode=Required（实例常驻、
        // WebView2 不销毁），抓取循环继续在后台滚；切回来重新订阅 Changed 即可看到进度。
        // 真要停，用户自己点「停止」按钮。
        //
        // 唯一的例外：**进程退出**没法拦（那是用户关程序，理应收尾）。
    }

    // ── 自适应布局 ──────────────────────────────────────────────

    private void OnBodyGridSizeChanged(object sender, SizeChangedEventArgs e)
        => ApplyLayout(e.NewSize.Width);

    /// <summary>
    /// 按实际宽度在「左表单 + 右浏览器」与「浏览器在上 / 表单在下」之间切换。
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
            // **恢复左右等分**（2026-10-30 用户：「自动下载不需要看右边的网页，恢复刚才的大小」）。
            // 上一轮为了给浏览器更多空间把左栏固定成 420，但用户在这个页主要是配参数、
            // 不看右边网页，左栏反而被压窄了。恢复 1:1，左栏布局在页面内部优化。
            BodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            BodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 360 });
            BodyGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

            Grid.SetRow(FormCard, 0);
            Grid.SetColumn(FormCard, 0);
            Grid.SetRow(BrowserCard, 0);
            Grid.SetColumn(BrowserCard, 1);
        }
        else
        {
            BodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            BodyGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(2, GridUnitType.Star) });
            BodyGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(3, GridUnitType.Star) });

            Grid.SetRow(BrowserCard, 0);
            Grid.SetColumn(BrowserCard, 0);
            Grid.SetRow(FormCard, 1);
            Grid.SetColumn(FormCard, 0);
        }
    }

    // ── WebView ────────────────────────────────────────────────

    private async Task InitWebAsync()
    {
        // **幂等**（2026-10-29）：页面设了 NavigationCacheMode=Required，
        // 切走再回来会再次调到这里。若重复执行，会重复订阅 WebMessageReceived；
        // 更致命的是最后那句 core.Navigate(HomeUrl) —— 会把正在滚动的页面拽回首页，
        // 抓取直接中断。所以已就绪就立刻返回。
        if (_ready && Web.CoreWebView2 is not null) return;

        try
        {
            await Web.EnsureCoreWebView2Async();
            // 让页面里的 target=_blank / window.open 在**当前 WebView 内**打开，
            // 而不是弹系统浏览器（用户 2026-10-27 报 B 站点视频会开新窗口）。
            ParseDl.Controls.WebViewHelper.KeepNavigationInPlace(Web.CoreWebView2, s => AppendLog(s));
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
        if (result.Media.Count == 0)
        {
            // **别再默默丢掉了**（2026-11-14 修）。
            //
            // 用户报「抖音自动下载抓取到 0 作品、页面显示服务异常」。
            // 拦截器其实**每次都会**上报诊断（endpoints 里有它实际请求过的接口路径），
            // 但这里拿到空媒体就 return，诊断信息全被丢掉 —— 于是完全看不出
            // 是「接口根本没被调用」还是「调用了但被风控拦了」。
            //
            // 现在把诊断记进日志：命中过哪些 /aweme/ 端点、各几次。
            // 有这一行就能分辨：
            //   · endpoints 为空      → 页面的请求钩子没接触到（脚本注入/UA 问题）
            //   · 有 aweme/post 但 0 条 → 接口返回被风控拦（需换登录态/重置设备）
            try
            {
                var diag = DescribeEndpoints(payload);
                if (diag.Length > 0) AppendLog("拦截诊断：" + diag);
                else AppendLog("拦截诊断：本批无媒体，且未观察到 /aweme/ 接口调用");
            }
            catch { }
            return;
        }

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

    /// <summary>
    /// 从拦截器上报的 payload 里抽出「实际请求过的 /aweme/ 端点」摘要。
    /// 只用于日志排查，解析失败一律返回空串，不影响主流程。
    /// </summary>
    private static string DescribeEndpoints(string payload)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(payload);
            if (!doc.RootElement.TryGetProperty("endpoints", out var eps)) return "";
            if (eps.ValueKind != System.Text.Json.JsonValueKind.Object) return "";
            var parts = new List<string>();
            foreach (var p in eps.EnumerateObject())
                parts.Add(p.Name + "×" + p.Value);
            // 最多列 6 条，避免刷屏
            if (parts.Count > 6) parts = parts.GetRange(0, 6);
            return string.Join("，", parts);
        }
        catch { return ""; }
    }

    private void OnAutoChanged()
    {
        // **只重画会变的那一块，别整页重建**（2026-10-30 修「开关跟着闪」）。
        //
        // 原来这里调 BuildAll()，它把 目标名单 / 下载选项 / 任务队列 / 日志
        // 四张卡片**全部 Children.Clear() 后重建**。而抓取过程中 _auto.Refresh()
        // 每秒要触发好几次（每滚一轮、每收集到一批、每提交一次都刷），
        // 于是左边那一堆 ToggleSwitch 被反复销毁重建 ——
        // 用户看到的就是「开关跟着滚动一起闪」。
        //
        // 现在只有任务队列（进度会变）和工具栏文字需要重画；
        // 名单与选项用的都是 _auto / DouyinSettings 里的稳定数据，
        // 运行中本来就不允许修改（输入框 IsEnabled = !_auto.Running），没必要重建。
        // **2026-10-31 加节流**（用户报「跑着跑着程序无响应」）。
        //
        // 抓取主循环每滚一轮就调 _auto.Refresh()，而它又在这里重建整张任务队列
        // （用户那轮是 90 个目标 × 每目标几十条媒体 = 上千行控件）。一秒能触发
        // 好几轮，UI 线程全耗在「销毁控件 → 重新建控件 → 重新布局」上，
        // 窗口就「未响应」了。
        //
        // 现在最多 400ms 重建一次：进度数字的观感几乎没差别，但 UI 线程
        // 的压力降一个数量级。真正的关键路径（滚动/收集/提交）都在后台，
        // 不受这里影响。
        var now = Environment.TickCount64;
        if (now - _lastAutoUiRebuild < 400) return;
        _lastAutoUiRebuild = now;

        DispatcherQueue.TryEnqueue(() =>
        {
            // 导入名单后「按文件名建文件夹」开关的可用性会变 —— 只在键变了时重建。
            RebuildOptionCardIfNeeded();
            BuildTaskCard();
            RefreshToolbar();
        });
    }

    /// <summary>上一次重建任务队列的时间戳（Environment.TickCount64）。</summary>
    private long _lastAutoUiRebuild;

    /// <summary>
    /// 上一次建「下载选项」卡时，影响开关可用性的两个量。
    ///
    /// **为什么要记**（2026-10-31 用户报「我明明导入名单了，按文件名建文件夹开关还是黑的」）：
    /// 那个开关的 IsEnabled 依赖 `ImportFolderName.Length > 0`（导入名单才有名字）。
    /// 而 OnAutoChanged 有意只重建任务队列、不重建选项卡（防跑批时开关跟着闪），
    /// 于是「导入名单」之后选项卡从未重建 —— 开关停在**导入前**算出来的禁用态，
    /// 看起来就是「灰的/黑的、点不动」。只有这两个量变了才需要重算。
    /// </summary>
    private string _optionKey = "\u0001";
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
            // **已导入名单时输入框不再显示整张表格**（2026-10-31 用户要求）：
            // 内容在 _auto._parsed 里照常参与跑批，只是不再堆在框里看得眼花。
            // 一旦用户手动改框内容，TextChanged 会正常走 SetRawText。
            Text = _auto.ImportFolderName.Length > 0 ? "" : _auto.RawText,
            PlaceholderText = _auto.ImportFolderName.Length > 0
                ? "已导入名单（见下方）。如需手动帖链接，直接写在这里即可。"
                : "一行一个目标：\n" +
                  "https://www.douyin.com/user/MS4wLjABAAAA...（作者主页）\n" +
                  "https://www.douyin.com/video/7412345678901234567（作品）\n" +
                  "https://v.douyin.com/xxxx/（短链）\n" +
                  "7412345678901234567（纯作品 ID）\n" +
                  "分享口令整段粘进来也能认\n" +
                  "也可以直接粘「视频插眼导出器」导出的 Markdown 名单表格",
            IsEnabled = !_auto.Running,
        };
        box.TextChanged += (_, _) => _auto.SetRawText(box.Text ?? "");
        panel.Children.Add(box);

        var summary = new StackPanel { Spacing = 2 };
        summary.Children.Add(new TextBlock
        {
            Text = "识别到 " + _auto.Total + " 个目标",
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
        var importBtn = new Button { Content = "导入名单（.md / .txt）", MinWidth = 150, IsEnabled = !_auto.Running };
        importBtn.Click += async (_, _) => await ImportFileAsync();
        row.Children.Add(importBtn);

        // **导入后不再把名单内容写进上面的大输入框**（2026-10-31 用户要求）：
        // 整张 Markdown 表格堆在框里又乱又难看。现在导入只在**导入按钮下方贴一小栏**显示文件名与条数，
        // 大输入框留给「手贴链接」用途（不再被导入内容占满）。
        if (_auto.ImportFolderName.Length > 0)
        {
            var importedBar = new Border
            {
                Background = UiKit.SubtleFill,
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(10, 7, 10, 7),
                Child = new TextBlock
                {
                    Text = "已导入：" + _auto.ImportFolderName + "（" + _auto.Total + " 个目标）",
                    FontSize = 12,
                    Opacity = 0.85,
                    TextWrapping = TextWrapping.Wrap,
                    IsTextSelectionEnabled = true,
                },
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(importedBar, "imported-file-bar");
            row.Children.Add(importedBar);
        }
        panel.Children.Add(row);

        TargetCardHost.Children.Add(UiKit.SectionCard("目标名单", panel,
            ""));   // 不再显示上限（用户 2026-10-30 取消名单数量限制）
    }

    private void BuildOptionCard()
    {
        // 记下「这次是按什么状态建的」，供 OnAutoChanged 判断要不要重建（见 _optionKey 注释）。
        _optionKey = OptionKey();
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

        // ── 抓取/下载选项（用户 2026-10-27：「解析页有的都要有」）──────────
        // 与解析页共用同一份 DouyinConfig，所以这里改了那边也是同一套值，
        // 不存在「两个页面设置打架」的问题。
        var optCfg = DouyinSettings.Current;

        var sourceCombo = new ComboBox { Height = 32, HorizontalAlignment = HorizontalAlignment.Stretch, MinWidth = 0 };
        foreach (var s in Enum.GetValues<DouyinSource>()) sourceCombo.Items.Add(s.Label());
        sourceCombo.SelectedIndex = (int)optCfg.Source;
        sourceCombo.SelectionChanged += (_, _) =>
        {
            DouyinSettings.Mutate(c => c.Source = (DouyinSource)Math.Max(0, sourceCombo.SelectedIndex));
        };
        panel.Children.Add(OptionRow("下载源", sourceCombo));

        if (optCfg.Source.NeedsQualityMode())
        {
            var modeCombo = new ComboBox { Height = 32, HorizontalAlignment = HorizontalAlignment.Stretch, MinWidth = 0 };
            foreach (var m in Enum.GetValues<DouyinQualityMode>()) modeCombo.Items.Add(m.Label());
            modeCombo.SelectedIndex = (int)optCfg.QualityMode;
            modeCombo.SelectionChanged += (_, _) =>
            {
                DouyinSettings.Mutate(c => c.QualityMode = (DouyinQualityMode)Math.Max(0, modeCombo.SelectedIndex));
            };
            panel.Children.Add(OptionRow("质量优先策略", modeCombo));
        }

        var imgCombo = new ComboBox { Height = 32, HorizontalAlignment = HorizontalAlignment.Stretch, MinWidth = 0 };
        foreach (var f in Enum.GetValues<DouyinImageFormat>()) imgCombo.Items.Add(f.Label());
        imgCombo.SelectedIndex = (int)optCfg.ImageFormat;
        imgCombo.SelectionChanged += (_, _) =>
        {
            DouyinSettings.Mutate(c => c.ImageFormat = (DouyinImageFormat)Math.Max(0, imgCombo.SelectedIndex));
        };
        panel.Children.Add(OptionRow("图片格式", imgCombo));

        // **5 个开关排成两列**（2026-10-30 用户要求「优化左边布局」）。
        // 每个占一整行的话，5 个开关就要吃掉 5 行高度，下面模板区被推到很下面。
        // 两列后只占 3 行，且标签短、不会挤。
        var toggleGrid = new Grid { ColumnSpacing = 16, RowSpacing = 4 };
        toggleGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toggleGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var toggleList = new List<FrameworkElement>
        {
            ToggleRow("跳过已下载", DouyinSettings.Current.SkipDownloaded,
                v => DouyinSettings.Mutate(c => c.SkipDownloaded = v)),
            ToggleRow("附带 BGM（图文）", DouyinSettings.Current.IncludeBgm,
                v => DouyinSettings.Mutate(c => c.IncludeBgm = v)),
            ToggleRow("下载配套视频", DouyinSettings.Current.IncludeLivePhoto,
                v => DouyinSettings.Mutate(c => c.IncludeLivePhoto = v)),
            ToggleRow("下载配套图片", DouyinSettings.Current.IncludeLiveImage,
                v => DouyinSettings.Mutate(c => c.IncludeLiveImage = v)),
            ToggleRow("合成实况图", DouyinSettings.Current.LivePhotoAsMotionPhoto,
                v => DouyinSettings.Mutate(c => c.LivePhotoAsMotionPhoto = v)),
        };
        for (var ti = 0; ti < toggleList.Count; ti++)
        {
            Grid.SetRow(toggleList[ti], ti / 2);
            Grid.SetColumn(toggleList[ti], ti % 2);
            toggleGrid.Children.Add(toggleList[ti]);
        }
        for (var tr = 0; tr < 3; tr++)
            toggleGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.Children.Add(toggleGrid);
        // ── 自动下载专属：按模板建文件夹 + 命名模板（用户 2026-10-27）──────
        // 与设置页那套**分开**：这里改了不影响「手动解析单条」用的模板，反之亦然。
        panel.Children.Add(new Border
        {
            Height = new Thickness(1).Top + 1,
            Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            Margin = new Thickness(0, 4, 0, 4),
        });

        // **「按模板建文件夹」开关只在下方出现一次**（2026-10-29 修重复）。
        // 原来这里还有一个 folderRow 开关，和模板下方的 ToggleRow 控制的是
        // **同一个** DouyinSettings.AutoCreateFolder —— 同一个设置两个入口，用户看着重复。
        // 保留模板下方那个：它同时会把「文件夹模板」输入框置灰/启用，逻辑更完整。

        // **「按文件名建文件夹」开关**（2026-10-29 用户要求：「按照文件名再创建文件夹
        // 这个你要加开关，就在自动下载里」）。
        // 控制的是「导入名单时那层顶层文件夹」是否生效：
        //   开 → downloads\<名单文件名>\<文件夹模板>\<文件名模板>
        //   关 → downloads\<文件夹模板>\<文件名模板>
        var byNameRow = new Grid { ColumnSpacing = 8 };
        byNameRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        byNameRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var byNameText = new StackPanel { Spacing = 2 };
        byNameText.Children.Add(new TextBlock
        {
            Text = "按文件名建文件夹",
            FontSize = 13,
            Opacity = 0.85,
        });
        byNameText.Children.Add(new TextBlock
        {
            Text = _auto.ImportFolderName.Length > 0
                ? "会在保存目录下再建一层「" + _auto.ImportFolderName + "」（与最近导入的名单文件同名）"
                : "手贴链接不建这层。只有点「导入名单」时才按名单文件名建一层文件夹",
            FontSize = 11,
            Opacity = 0.6,
            TextWrapping = TextWrapping.Wrap,
        });
        byNameRow.Children.Add(byNameText);
        var byNameToggle = new ToggleSwitch
        {
            IsOn = _auto.FolderByName,
            MinWidth = 0,
            IsEnabled = !_auto.Running && _auto.ImportFolderName.Length > 0,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(byNameToggle, "按文件名建文件夹");
        byNameToggle.Toggled += (_, _) =>
        {
            _auto.SetFolderByName(byNameToggle.IsOn);
            _autoTemplateEditor?.RefreshAll();   // 让文件夹模板的示例立刻反映开关变化
        };
        Grid.SetColumn(byNameToggle, 1);
        byNameRow.Children.Add(byNameToggle);
        panel.Children.Add(byNameRow);

        // **「按模板建文件夹」开关移到模板上方**（2026-10-30 用户要求：
        // 「按照模板创建文件夹放到文件夹模版上面」）—— 它是模板的开关，
        // 放在模板上面读起来是「先决定建不建，再填模板」，比放下面顺。
        panel.Children.Add(ToggleRow("按模板建文件夹",
            DouyinSettings.Current.AutoCreateFolder,
            v =>
            {
                DouyinSettings.Mutate(c => c.AutoCreateFolder = v);
                if (_autoDirField is not null) _autoDirField.SetEnabled(v);
            }));
        if (_autoDirField is not null) _autoDirField.SetEnabled(DouyinSettings.Current.AutoCreateFolder);

        // ── 命名模板（用与全局设置同一个 TemplateEditor）──────────────────
        //
        // 用户 2026-10-27：「抖音自动下载里面的变量，怎么没按照我的要求做，和全局那个一样做」。
        // 之前这里是手搓的 TextBox + 一排变量按钮，与设置页那套 TemplateEditor 完全两样：
        //   · 变量面板是常驻的一长串，不是「点击展开」；
        //   · 没有「填入默认」「恢复默认模板」；
        //   · 没有实时输出示例。
        // 现在直接复用 TemplateEditor —— 与 X/抖音设置页**同一份实现**，行为完全一致：
        // 每个模板框各带一份可展开的变量面板，点变量插到该框，默认折叠。
        _autoTemplateEditor = new TemplateEditor(DouyinAutoTemplateVars, AutoVarHint);

        _autoDirField = _autoTemplateEditor.AddField(new TemplateFieldOptions
        {
            Label = "文件夹模板",
            Hint = "%AUTHOR%",
            DefaultTemplate = "%AUTHOR%",
            EmptyHint = "留空则直接存到保存目录下",
            Preview = RenderAutoDirTemplate,
        }, DouyinSettings.Current.EffectiveAutoDirTemplate);

        _autoNameField = _autoTemplateEditor.AddField(new TemplateFieldOptions
        {
            Label = "文件名模板",
            Hint = DouyinTemplate.DefaultFileNameTemplate,
            DefaultTemplate = DouyinTemplate.DefaultFileNameTemplate,
            EmptyHint = "留空则用默认模板",
            Preview = RenderAutoNameTemplate,
        }, DouyinSettings.Current.EffectiveAutoFileNameTemplate);

        _autoTemplateEditor.FieldChanged += (_, e) =>
        {
            // 文件夹模板写 AutoDirTemplate，文件名模板写 AutoFileNameTemplate
            if (ReferenceEquals(e.Field, _autoDirField))
                DouyinSettings.Mutate(c => c.AutoDirTemplate = e.Value);
            else
                DouyinSettings.Mutate(c => c.AutoFileNameTemplate = e.Value);
        };
        panel.Children.Add(_autoTemplateEditor);

        // 建文件夹开关放在模板下方（它决定文件夹模板是否生效）


        panel.Children.Add(new TextBlock
        {
            Text = "模板改动会自动保存。",
            FontSize = 11.5,
            Opacity = 0.55,
            TextWrapping = TextWrapping.Wrap,
        });
        OptionCardHost.Children.Add(UiKit.SectionCard("下载选项", panel));
    }

    /// <summary>
    /// 「下载选项」卡里那些**会影响启用状态**的量拼成的键。
    /// 导入名单后 ImportFolderName 从空变成「示例标签」，键就变了 → 需要重建选项卡。
    /// </summary>
    private string OptionKey() =>
        (_auto.ImportFolderName ?? "") + "|" + _auto.Running + "|"
        + DouyinSettings.Current.AutoCreateFolder + "|" + DouyinSettings.Current.IncludeLivePhoto;

    /// <summary>
    /// 必要时重建「下载选项」卡（导入名单后那一层开关才会从禁用变可用）。
    /// 只在键真的变了时重建 —— 跑批期间 _auto.Refresh() 每秒多次调用会走空返回，
    /// 不会重复销毁重建开关（那正是 2026-10-30 修过的「开关跟着闪」）。
    /// </summary>
    private void RebuildOptionCardIfNeeded()
    {
        if (OptionKey() == _optionKey) return;
        BuildOptionCard();
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

    /// <summary>
    /// **不再显示「运行日志」卡片**（2026-10-29 用户要求删除）。
    ///
    /// 日志本身仍写进 <see cref="_log"/>（排错、无人值守测试要用），
    /// 只是不在界面上占一大块位置 —— 用户的原话是「删除这个运行日志」。
    /// </summary>
    private void BuildLogCard()
    {
        LogCardHost.Children.Clear();
    }

    private void AppendLog(string line)
    {
        _log.Add(DateTime.Now.ToString("HH:mm:ss") + "  " + line);
        if (_log.Count > 500) _log.RemoveRange(0, _log.Count - 500);
        BuildLogCard();

        // **同时写进日志文件**（2026-11-14 加）。
        //
        // 原来这里只往内存列表 `_log` 里塞，界面上看得到、**文件里一个字都没有**。
        // 后果是「抓到 0 个作品」这种问题根本无法事后排查 —— 本页 25 个 AppendLog
        // 调用点全部不落盘，只能靠人在界面上现看，窗口一关就全没了。
        //
        // 用户 2026-11-14 报「抖音自动下载抓取到 0 作品、页面显示服务异常」，
        // 我翻遍日志文件找不到任何抓取痕迹，才发现是这里不落盘。
        // 走 Aria2Engine.Log 是为了复用同一套路径/按天分文件/保留天数清理。
        try { Aria2Engine.Log("[抖音自动] " + line); } catch { }
    }

    // ── 名单导入 ────────────────────────────────────────────────

    private async Task ImportFileAsync()
    {
        try
        {
            // 2026-10-31：改用新版选择器（旧的 FileOpenPicker + InitializeWithWindow
            // 在非打包应用里必抛 COMException，被 catch 吞掉 = 点了没反应）。
            // 用户 2026-10-27：名单是「视频插眼导出器」导出的 Markdown（.md）。
            var path = await FolderPickerService.PickFileAsync(".md", ".markdown", ".txt");
            if (path is null) return;
            var text = await System.IO.File.ReadAllTextAsync(path);
            var fileName = System.IO.Path.GetFileName(path);
            _auto.SetRawText(text);
            // **记下导入的文件名**，用作下载的顶层文件夹（用户 2026-10-29 要求）：
            // downloads\<名单文件名>\<文件夹模板>\<文件名模板>
            _auto.SetImportFolderName(fileName);
            // **导入后清空大输入框**（2026-10-31 用户要求）：
            // 整张 Markdown 表格堆进去又乱又难看，且下次手贴链接还要先删一大段。
            // 目标已经进 _auto._parsed，清空输入框不影响跑批（它只是展示用）。
            BuildTargetCard();   // 重建目标卡：输入框留空，导入信息显示在按钮下方小栏
            // **导入后立刻重建选项卡**（2026-10-31 用户报「开关还是黑的」）：
            // 「按文件名建文件夹」的 IsEnabled 取决于 ImportFolderName 是否非空，
            // 而选项卡以前只在进页面时建过一次 —— 导入后开关停在导入前的禁用态。
            // 这里直接重建一次，不等 Changed 那条 400ms 节流路径。
            BuildOptionCard();
            AppendLog("已从 " + fileName + " 导入名单（" + _auto.Total + " 个目标）"
                      + (_auto.ImportFolderName.Length > 0
                          ? "，将存入同名文件夹「" + _auto.ImportFolderName + "」" : ""));
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

        // **把页面上下文交给取址器**（2026-10-31）：
        // 队列恢复时要用「按作品 ID 现取地址」，而那需要在内嵌浏览器里执行 fetch
        // （接口要整套登录态与签名参数，自己拼几乎必失败）。
        DouyinAddressResolver.Executor = async (script) =>
        {
            try
            {
                var core = Web.CoreWebView2;
                if (core is null) return null;
                return await core.ExecuteScriptAsync(script);
            }
            catch { return null; }
        };

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
                // **每轮都补查一次台账**（2026-10-30 修）：完成事件可能丢（进程退出、任务被删），
                // 不能只靠 DownloadStore 的完成钩子。这里拿 aria2 的实时状态对一遍，
                // 把「已下完但记录还停在 pending」的补成 done，重启后也一样有效。
                _ = ParseDl.Services.Douyin.DouyinEnqueuer.AdvanceLedgerAsync();
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

        // **带上目标作者的 sec_uid**（2026-11-20）：主页滚动会混入推荐流，
        // 收集器据此滤掉别人的作品。单条作品页 / 短链抠不到 sec_uid 时是空串，
        // 此时不做校验（保持旧行为）。
        _collector = new DouyinAutoCollector { ExpectedSecUid = task.SecUid };
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

            // **作者归属过滤的结果要说话**（2026-11-20）：主页往下滚时会混入推荐流，
            // 收集器已按 sec_uid 把这些别人的作品丢掉。丢了多少、混进来的是谁，
            // 必须让用户看见 —— 否则他会以为「这个号就这么几个作品」。
            if (_collector is { RejectedPostCount: > 0 } rejected)
            {
                AppendLog("[" + task.Label + "] 已过滤 " + rejected.RejectedPostCount +
                          " 个不属于该作者的作品（" + rejected.RejectedByAuthor +
                          " 条媒体，主页推荐流混入" +
                          (rejected.RejectedAuthors.Count > 0
                              ? "：" + string.Join("、", rejected.RejectedAuthors)
                              : "") + "）");
            }

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

            // **严格串行：等这批下完再抓下一个主页**（2026-10-31 用户要求）。
            //
            // 为什么必须这样：抖音直链带时效签名，几小时就 403。
            // 原来是「提交完立刻切下一个主页」，于是队列越堆越长、
            // 前面那批的链接在排队期间就过期了 —— 实测 2000 条一次性报废。
            // 现在一个主页的媒体下完才继续，链接从取到用只隔几分钟，
            // 过期窗口被压到最小。
            //
            // **2026-11-18 豁免**：本次一条新作品都没抓到（Queued == 0，全是「已下载过」），
            // 那就没有任何直链需要保护，没有等待的理由 —— 直接进下一个目标。
            // 这是多主页场景下省时间的主要来源之一：追平即停之后，大量主页都是这种情形。
            if (_auto.AutoDownload && task.Queued > 0)
            {
                await WaitDownloadsAsync(task);
            }
            else if (_auto.AutoDownload && task.Queued == 0 && task.AwemeCount > 0)
            {
                AppendLog("[" + task.Label + "] 本次没有新作品需要下载，直接处理下一个目标");
            }

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
        // **单条作品页不滚动**（2026-10-30 修「填视频链接识别不了 / 无意义滚动」）。
        //
        // 关键：**不能用用户填的原始链接判断**。用户粘的往往是分享短链
        // （`https://v.douyin.com/bD452mp3oJ...`），它既不是 /video/ 也不是主页，
        // 光看字符串根本分不出来 —— 必须等 WebView 跳转完，读**实际落地的 URL**
        // （`https://www.douyin.com/video/7xxx`）才知道是什么页面。
        var landed = SafeLandedUrl();
        if (IsSingleWorkUrl(landed) || IsSingleWorkUrl(_auto.Current?.Url))
        {
            AppendLog("落地页：" + landed);
            return await CollectSingleWorkAsync();
        }


        var cfg = DouyinSettings.Current;
        var scroller = new DouyinAutoScroller(
            maxRounds: cfg.MaxRounds,
            stallLimit: cfg.StallLimit,
            interval: TimeSpan.FromMilliseconds(Math.Max(200, cfg.ScrollIntervalMs)),
            catchUpStop: cfg.CatchUpStop,
            catchUpStreak: cfg.CatchUpStreak);
        scroller.Start();

        // 已经喂给状态机「追平判定」的作品 id，避免同一批重复计入。
        var seen = new HashSet<string>(StringComparer.Ordinal);
        if (cfg.CatchUpStop)
        {
            AppendLog("已开启「自动识别已抓位置」：连续 " + cfg.CatchUpStreak +
                      " 个作品在台账里就判定追平并停止");
        }

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
            var more = scroller.OnRoundResult(report.ScrollHeight, report.ScrollTop, report.Moved);

            var collector = _collector;
            var task = _auto.Current;
            if (collector is not null && task is not null)
            {
                task.AwemeCount = collector.AwemeCount;
                task.MediaCount = collector.Count;
                _auto.Refresh();
            }

            // **追平判定**（2026-11-18）：把这批里还没喂过的作品按出现顺序交给状态机。
            // 抖音按发布时间倒序，所以「连续 N 个都已下载」= 已经追到上次抓到的位置。
            //
            // 注意按 **PostId（作品）** 去重，不是按媒体 Id：一个图集有 N 张图、
            // 它们属于同一个作品，按媒体判会把「连续 N 条」算成 1 条作品。
            if (more && collector is not null && cfg.CatchUpStop)
            {
                foreach (var item in collector.Items)
                {
                    if (string.IsNullOrEmpty(item.PostId) || !seen.Add(item.PostId)) continue;
                    var done = DouyinStore.Instance.Ledger.Contains(item.PostId);
                    if (!scroller.OnBatchSeen(new[] { done })) { more = false; break; }
                }
            }

            // **2026-10-31 删掉「识别到作品就停」**（用户报「没滚到底就切下一个人主页，
            // 抓取不彻底」）。
            //
            // 那条规则是 2026-10-30 为「不要无意义滚动」加的，但它把**自动下载**
            // 和「页面自动加载」当成了同一件事：自动下载要的是**尽量抓满这个人的全部作品**，
            // 而「识别到 1 个就停」等于只抓首屏那十几个就换人。
            // 现在只在「真的滚不动了」（连续 StallLimit 轮 scrollTop 与 scrollHeight
            // 都不动）或到达轮次上限时才停 —— 判定见 DouyinAutoScroller.OnRoundResult。
            if (!more)
            {
                AppendLog("停止滚动：" + DouyinAutoScroller.LabelOf(scroller.StopReason ?? DouyinAutoScrollStop.Stopped)
                          + "（共 " + scroller.Rounds + " 轮，已识别 "
                          + (collector?.AwemeCount ?? 0) + " 个作品）");
                break;
            }

            // **自适应等待**（2026-11-18）：不再固定睡满 ScrollIntervalMs。
            // 页面回报「本轮确实滚动了」→ 立即进入下一轮，只用最小间隔给页面留出
            // 渲染/发游标请求的时间；只有「没滚动」时才退回到配置的间隔，
            // 等它把新内容加载出来。这样正常滚动时每轮省掉几百毫秒。
            var minGap = TimeSpan.FromMilliseconds(250);
            var wait = report.Moved > 0 ? minGap : scroller.Interval;
            if (wait < minGap) wait = minGap;
            await Task.Delay(wait);
        }
        return scroller.StopReason;
    }

    /// <summary>
    /// 是不是「单条作品」链接（`/video/{id}`、`/note/{id}`、或带 modal_id/aweme_id 的）。
    ///
    /// 单条作品页与作者主页是两种完全不同的页面：
    /// 前者是一整屏播放器、没有信息流可滚；后者才是要一直往下翻的列表。
    /// 之前的代码不区分，对单条页也跑滚动循环，于是永远收集到 0 个。
    /// </summary>
    /// <summary>
    /// 取 WebView **当前实际落地的 URL**（短链跳转之后的值）。
    ///
    /// 用户粘的分享短链（`https://v.douyin.com/xxx`）看不出是作品页还是主页，
    /// 只有导航完成后 `CoreWebView2.Source` 才是真正的目标地址。
    /// 拿不到就返回空串，调用方按主页处理。
    /// </summary>
    private string SafeLandedUrl()
    {
        try { return Web.CoreWebView2?.Source ?? ""; }
        catch { return ""; }
    }

    private static bool IsSingleWorkUrl(string? url)
    {
        if (string.IsNullOrWhiteSpace(url)) return false;
        var s = url;
        // 短链（v.douyin.com/xxxx）要等跳转后才知道是什么，先按主页处理 ——
        // 跳转后如果其实是作品页，CollectAsync 里的滚动也只是空转几轮，不会出错。
        if (s.Contains("/video/") || s.Contains("/note/") || s.Contains("/slides/")) return true;
        if (s.Contains("modal_id=") || s.Contains("aweme_id=")) return true;
        return false;
    }

    /// <summary>
    /// 单条作品页的收集：**不滚动**，只等拦截脚本把详情接口的响应送上来。
    ///
    /// 给足 15 秒（详情接口偶尔慢），期间一旦 <see cref="DouyinAutoCollector"/> 收到
    /// 作品就立刻返回，用户不用干等。
    /// </summary>
    private async Task<DouyinAutoScrollStop?> CollectSingleWorkAsync()
    {
        AppendLog("单条作品页，跳过滚动，等待详情接口");
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (_auto.Running && DateTime.UtcNow < deadline)
        {
            var collector = _collector;
            var task = _auto.Current;
            if (collector is not null && task is not null)
            {
                task.AwemeCount = collector.AwemeCount;
                task.MediaCount = collector.Count;
                _auto.Refresh();
                if (collector.AwemeCount > 0)
                {
                    AppendLog("已拿到作品详情（" + collector.Count + " 个媒体）");
                    return DouyinAutoScrollStop.NoGrowth;
                }
            }
            await Task.Delay(400);
        }
        return DouyinAutoScrollStop.NoGrowth;
    }

    /// <summary>
    /// **等这个主页提交的媒体全部下完**（2026-10-31，用户要求「下载完再进行下一个主页」）。
    ///
    /// 判定方式：直接看 DownloadStore 里本模块「还没到终态」的条数。
    /// 全到终态（完成 / 错误 / 移除）就返回 —— 出错的也算「结束」，
    /// 否则一条 403 会让整批永远卡住。
    ///
    /// 超时：目标本身的作品太多时会下很久，这里给一个**宽松上限**（默认 30 分钟），
    /// 到点就记日志继续下一个。用户选的是「严格串行」而非「无限等待」，
    /// 一个卡死的主页不该拖垮整批。
    ///
    /// **2026-11-20 加「被别的模块饿死」的早退**：底层只有一个 aria2 引擎、
    /// 并发槽是全局的，别的模块（实测是 X 的 352 条积压）把槽全占住时，
    /// 抖音这些条目会一直停在「等待中」不动 —— 条数不变、进度不变，
    /// 原来只能干等满 30 分钟才继续。现在只要连续 <see cref="StarveMinutes"/> 分钟
    /// 「本模块一条都没在下、待完成条数也没减少」，就判定为被饿死，直接继续下一个目标。
    /// 这不是放弃：条目仍在队列里，等槽空出来照样会下，只是不阻塞批量流程。
    /// </summary>
    private async Task WaitDownloadsAsync(DouyinAutoTask task)
    {
        const int TimeoutMinutes = 30;
        // 连续多少分钟「本模块 0 条在下 + 待完成条数不减少」就判定被别的模块饿死。
        const int StarveMinutes = 3;

        var deadline = DateTime.UtcNow.AddMinutes(TimeoutMinutes);
        var announced = false;

        var lastPending = -1;
        var lastProgressAt = DateTime.UtcNow;

        while (_auto.Running)
        {
            var mine = DownloadStore.Instance.Items
                .Where(i => i.Module == DouyinEnqueuer.Module)
                .ToList();

            var pending = mine.Count(i =>
                i.Status is AriaStatus.Active or AriaStatus.Waiting or AriaStatus.Paused);

            if (pending == 0) break;

            // 本模块有没有一条真正在下（Active）。0 条 = 槽被别的模块占着。
            var activeMine = mine.Count(i => i.Status == AriaStatus.Active);

            if (!announced)
            {
                announced = true;
                AppendLog("[" + task.Label + "] 等待下载完成（还有 " + pending + " 条）…");
            }

            // 条数变了说明有进展（下完了/失败了），重置饿死计时。
            if (pending != lastPending)
            {
                lastPending = pending;
                lastProgressAt = DateTime.UtcNow;
            }
            else if (activeMine == 0 &&
                     DateTime.UtcNow - lastProgressAt >= TimeSpan.FromMinutes(StarveMinutes))
            {
                AppendLog("[" + task.Label + "] 本模块已 " + StarveMinutes +
                          " 分钟没有一条在下载（并发位被其他模块占满），还剩 " + pending +
                          " 条排队中，先继续下一个目标");
                return;
            }

            if (DateTime.UtcNow >= deadline)
            {
                AppendLog("[" + task.Label + "] 等待超时（" + TimeoutMinutes + " 分钟），还剩 " +
                          pending + " 条未完成，先继续下一个目标");
                return;
            }
            await Task.Delay(1500);
        }

        if (announced)
            AppendLog("[" + task.Label + "] 该目标下载已结束，继续下一个");
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

        // auto: true —— 用自动下载专属模板与建文件夹开关（与设置页那套分开）。
        // 顶层文件夹 = 导入的名单文件名（空则不建这层）
        // 开关关掉时 EffectiveRootFolder 返回空 → 不建这层
        var rootFolder = _auto.EffectiveRootFolder;
        var result = await DouyinEnqueuer.EnqueueAsync(batch.Items, cfg, auto: true, rootFolder: rootFolder);
        task.Queued = result.Queued;
        _auto.Refresh();
        AppendLog("[" + task.Label + "] " + result.Message);
    }

    private static string ShortError(Exception ex)
    {
        var msg = ex.Message ?? "";
        return msg.Length <= 120 ? msg : msg[..120] + "…";
    }

    /// <summary>把变量插到指定模板框的光标处（有选区则替换）。</summary>
    private static void InsertAtCaret(TextBox box, string token)
    {
        var text = box.Text ?? "";
        var start = box.SelectionStart;
        if (start < 0 || start > text.Length) start = text.Length;
        var len = box.SelectionLength;
        if (len < 0 || start + len > text.Length) len = 0;
        box.Text = text.Remove(start, len).Insert(start, token);
        box.Focus(FocusState.Programmatic);
        box.SelectionStart = start + token.Length;
        box.SelectionLength = 0;
    }

    /// <summary>预览模板用的示例条目（不联网，只为让用户看见落点长什么样）。</summary>
    private static DouyinItem PreviewItem()
    {
        var m = new DouyinItem
        {
            Id = "7412345678901234567",
            Url = "https://www.douyin.com/video/7412345678901234567",
            Text = "示例作品描述",
            UserName = "示例作者",
        };
        return m;
    }

    // ── 选项行辅助（与解析页同一套视觉规则）──────────────────────

    /// <summary>标签列固定 88px + 控件列吃满剩余宽度，保证两个下拉同宽同高同基线。</summary>
    private static Grid OptionRow(string label, FrameworkElement control)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(88) });
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

    /// <summary>开关行：开关紧跟标题（距离 ≤24px，遵循用户 2026-09-30 约定）。</summary>
    private static Grid ToggleRow(string label, bool value, Action<bool> onChanged)
    {
        // Grid 撑满整行（StackPanel 只按内容宽，右侧会空一大片 —— 用户 2026-10-27 圈出过）
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 13,
            Opacity = 0.8,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var toggle = new ToggleSwitch
        {
            IsOn = value,
            MinWidth = 0,
            OnContent = "开",
            OffContent = "关",
            VerticalAlignment = VerticalAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, label);
        toggle.Toggled += (_, _) => onChanged(toggle.IsOn);
        Grid.SetColumn(toggle, 1);
        row.Children.Add(toggle);
        return row;
    }

    /// <summary>文件夹模板的实时示例（用同一个模板引擎，避免预览与产出漂移）。</summary>
    /// <summary>
    /// 文件夹模板的实时示例。
    ///
    /// **只展开变量，不拼完整绝对路径**（2026-10-30 用户反馈「文件名示例怎么完整路径」）。
    ///
    /// 原来这里调 `DouyinTemplate.BuildTarget`，它返回的是**最终落盘目录**，
    /// 于是示例变成 `D:\path\to\parse-dl\ParseDl\bin\x64\...\downloads\@示例作者` ——
    /// 几十个字符的安装路径把真正想看的那段（`@示例作者`）淹没了，
    /// 而且在别的机器上跑还会显示完全不同的路径，毫无参考价值。
    ///
    /// 现在与「抖音设置」「X 下载设置」两个页面的预览**同一口径**：
    /// 只做变量展开（`DouyinTemplate.Expand`），用户看到的就是模板本身会变成什么。
    /// </summary>
    private static string RenderAutoDirTemplate(string tpl)
    {
        // 顶层「按文件名建文件夹」那层单独提示，不混进模板示例里
        var expanded = DouyinTemplate.Expand(tpl, PreviewItem()).Trim();
        var root = DouyinAutoStore.Instance.EffectiveRootFolder;
        if (root.Length > 0)
            return root + "\\" + (expanded.Length > 0 ? expanded : "（空）");
        return expanded;
    }

    /// <summary>文件名模板的实时示例（同样只展开变量 + 清洗，不拼路径）。</summary>
    private static string RenderAutoNameTemplate(string tpl)
        => FileNameTemplate.DouyinFilenamify(
            DouyinTemplate.Expand(tpl, PreviewItem()).Trim(), PreviewItem().Id);

    /// <summary>
    /// 无人值守测试入口：环境变量 PARSE_DL_DOUYIN_TARGETS 放目标（换行分隔），
    /// 进页面自动填进输入框并开跑。不设变量时完全不触发。
    /// </summary>
    private void TryAutoRunForTest()
    {
        try
        {
            var raw = Environment.GetEnvironmentVariable("PARSE_DL_DOUYIN_TARGETS");
            if (string.IsNullOrWhiteSpace(raw)) return;

            // **直接写 store，不碰 UI 控件**：输入框是代码动态建的，没有 x:Name。
            _auto.SetRawText(raw.Replace("\\n", Environment.NewLine));
            Aria2Engine.Log("[DouyinAutoPage] 自动测试：注入 " + _auto.RawText.Length + " 字符，识别 " + _auto.Tasks.Count + " 个目标");

            DispatcherQueue.TryEnqueue(async () =>
            {
                await Task.Delay(1500);
                try
                {
                    OnStartClick(this, new RoutedEventArgs());
                    Aria2Engine.Log("[DouyinAutoPage] 自动测试：已提交");
                }
                catch (Exception ex)
                {
                    Aria2Engine.Log("[DouyinAutoPage] 自动测试异常：" + ex.Message);
                }
            });
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[DouyinAutoPage] 自动测试入口异常：" + ex.Message);
        }
    }
}
