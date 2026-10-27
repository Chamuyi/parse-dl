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
    private bool _ready;
    private bool _busy;
    private bool? _wideLayout;
    private DouyinAutoCollector? _collector;

    /// <summary>自动下载模板区里「最后聚焦的那个模板框」—— 点变量就往这里插。</summary>
    private TextBox? _lastTemplateBox;

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
        ApplyLayout(BodyGrid.ActualWidth);
        BuildAll();
        _ = InitWebAsync();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _auto.Changed -= OnAutoChanged;
        if (_auto.Running) _auto.Stop();
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
            BodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            BodyGrid.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
                MinWidth = 360,
            });
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
                "分享口令整段粘进来也能认\n" +
                "也可以直接粘「视频插眼导出器」导出的 Markdown 名单表格",
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
        var importBtn = new Button { Content = "导入名单（.md / .txt）", MinWidth = 150, IsEnabled = !_auto.Running };
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

        panel.Children.Add(ToggleRow("跳过已下载",
            DouyinSettings.Current.SkipDownloaded,
            v => DouyinSettings.Mutate(c => c.SkipDownloaded = v)));

        panel.Children.Add(ToggleRow("附带 BGM（图文）",
            DouyinSettings.Current.IncludeBgm,
            v => DouyinSettings.Mutate(c => c.IncludeBgm = v)));

        panel.Children.Add(ToggleRow("实况图配对视频",
            DouyinSettings.Current.IncludeLivePhoto,
            v => DouyinSettings.Mutate(c => c.IncludeLivePhoto = v)));

        panel.Children.Add(ToggleRow("下载配套图片",
            DouyinSettings.Current.IncludeLiveImage,
            v => DouyinSettings.Mutate(c => c.IncludeLiveImage = v)));

        panel.Children.Add(ToggleRow("合成实况图（单个 jpg）",
            DouyinSettings.Current.LivePhotoAsMotionPhoto,
            v => DouyinSettings.Mutate(c => c.LivePhotoAsMotionPhoto = v)));
        // ── 自动下载专属：按模板建文件夹 + 命名模板（用户 2026-10-27）──────
        // 与设置页那套**分开**：这里改了不影响「手动解析单条」用的模板，反之亦然。
        panel.Children.Add(new Border
        {
            Height = new Thickness(1).Top + 1,
            Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            Margin = new Thickness(0, 4, 0, 4),
        });

        var folderRow = new Grid { ColumnSpacing = 8 };
        folderRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        folderRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var folderText = new StackPanel { Spacing = 2 };
        folderText.Children.Add(new TextBlock
        {
            Text = "在下载路径下按文件夹模板建子文件夹",
            FontSize = 13,
            Opacity = 0.85,
        });
        folderText.Children.Add(new TextBlock
        {
            Text = "关掉则所有文件直接落在下载根目录（不建子文件夹）",
            FontSize = 11,
            Opacity = 0.6,
            TextWrapping = TextWrapping.Wrap,
        });
        folderRow.Children.Add(folderText);
        var folderToggle = new ToggleSwitch
        {
            IsOn = DouyinSettings.Current.AutoCreateFolder,
            MinWidth = 0,
            IsEnabled = !_auto.Running,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(folderToggle, "按模板建文件夹");
        folderToggle.Toggled += (_, _) =>
        {
            DouyinSettings.Mutate(c => c.AutoCreateFolder = folderToggle.IsOn);
        };
        Grid.SetColumn(folderToggle, 1);
        folderRow.Children.Add(folderToggle);
        panel.Children.Add(folderRow);

        // 文件夹模板（自动下载专用）
        var dirBox = new TextBox
        {
            Text = DouyinSettings.Current.EffectiveAutoDirTemplate,
            PlaceholderText = "%AUTHOR%",
            IsEnabled = !_auto.Running,
            FontFamily = new FontFamily("Consolas"),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(dirBox, "自动下载文件夹模板");
        dirBox.TextChanged += (_, _) =>
        {
            DouyinSettings.Mutate(c => c.AutoDirTemplate = dirBox.Text ?? "");
        };
        var dirHint = new TextBlock { FontSize = 11, Opacity = 0.6, TextWrapping = TextWrapping.Wrap };
        panel.Children.Add(new TextBlock { Text = "文件夹模板", FontSize = 12, Opacity = 0.8 });
        panel.Children.Add(dirBox);
        panel.Children.Add(dirHint);

        // 文件名模板（自动下载专用）
        var nameBox = new TextBox
        {
            Text = DouyinSettings.Current.EffectiveAutoFileNameTemplate,
            PlaceholderText = DouyinTemplate.DefaultFileNameTemplate,
            IsEnabled = !_auto.Running,
            FontFamily = new FontFamily("Consolas"),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(nameBox, "自动下载文件名模板");
        nameBox.TextChanged += (_, _) =>
        {
            DouyinSettings.Mutate(c => c.AutoFileNameTemplate = nameBox.Text ?? "");
        };
        var nameHint = new TextBlock { FontSize = 11, Opacity = 0.6, TextWrapping = TextWrapping.Wrap };
        panel.Children.Add(new TextBlock { Text = "文件名模板", FontSize = 12, Opacity = 0.8 });
        panel.Children.Add(nameBox);
        panel.Children.Add(nameHint);

        // 记录最后聚焦的模板框
        dirBox.GotFocus += (_, _) => _lastTemplateBox = dirBox;
        nameBox.GotFocus += (_, _) => _lastTemplateBox = nameBox;

        // 可用变量（点变量插到**最后聚焦的那个框**）
        panel.Children.Add(new TextBlock
        {
            Text = "可用变量（点一下插入到上面最后点的那个框）",
            FontSize = 11,
            Opacity = 0.65,
            Margin = new Thickness(0, 6, 0, 2),
        });
        var vars = new StackPanel { Spacing = 1 };
        foreach (var v in DouyinTemplate.Vars)
        {
            var b2 = new Button
            {
                Content = v.Token + "    " + v.Desc,
                FontSize = 11,
                Padding = new Thickness(8, 3, 8, 3),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b2, "变量 " + v.Name);
            b2.Click += (_, _) => InsertAtCaret(_lastTemplateBox ?? nameBox, v.Token);
            vars.Children.Add(b2);
        }
        panel.Children.Add(vars);

        // 预览与启用态：函数体捕获 dirBox/nameBox/dirHint/nameHint，
        // 所以**必须在这些变量初始化之后**才能调用（C# 局部函数的调用顺序约束）。
        void RefreshPreview()
        {
            var cfg = DouyinSettings.Current;
            try
            {
                var (d, f) = DouyinTemplate.BuildTarget(PreviewItem(), cfg, auto: true);
                dirHint.Text = "示例落点：" + d;
                nameHint.Text = "示例文件名：" + f;
            }
            catch (Exception ex)
            {
                dirHint.Text = "模板展开失败：" + ex.Message;
                nameHint.Text = "";
            }
        }
        void SyncEnabled()
        {
            var on = !_auto.Running;
            folderToggle.IsEnabled = on;
            dirBox.IsEnabled = on && DouyinSettings.Current.AutoCreateFolder;
            nameBox.IsEnabled = on;
        }

        folderToggle.Toggled += (_, _) => { SyncEnabled(); RefreshPreview(); };
        dirBox.TextChanged += (_, _) => { SyncEnabled(); RefreshPreview(); };
        nameBox.TextChanged += (_, _) => { SyncEnabled(); RefreshPreview(); };

        SyncEnabled();
        RefreshPreview();
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
            // 用户 2026-10-27：名单是「视频插眼导出器」导出的 Markdown（.md）。
            // 两种都给，反正解析器会自动认表格。
            picker.FileTypeFilter.Add(".md");
            picker.FileTypeFilter.Add(".markdown");
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

        // auto: true —— 用自动下载专属模板与建文件夹开关（与设置页那套分开）。
        var result = await DouyinEnqueuer.EnqueueAsync(batch.Items, cfg, auto: true);
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
}
