using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.X;
using Windows.UI;

namespace ParseDl.Pages;

/// <summary>
/// 自动执行页 —— 按名单批量跑（对齐 Flutter 版 lib/pages/auto_task_page.dart）。
///
/// 分区顺序与原项目逐条对应：
///   ① 页头「自动执行 / 按名单批量跑」
///   ② 顶部告警条（运行中提示 / 未登录告警）
///   ③ 左栏：名单来源 → 历史名单 → 下载配置（与主页共用）→ 执行设置
///   ④ 右栏：下载记录（原项目是右侧一栏，空态「还没有下载记录」）
///   ⑤ 底部说明
///
/// 状态都在 <see cref="AutoTaskStore"/>（单例）里 —— 切走页面不丢进度。
/// </summary>
public sealed partial class AutoTaskPage : Page
{
    private const string ModuleKey = "x";

    private readonly AutoTaskStore _store = AutoTaskStore.Instance;
    private static ModuleSettings S => AppSettings.Instance.ForModule(ModuleKey);

    private StackPanel? _alertHost;
    private TextBlock? _notice;
    private StackPanel? _fileNameHost;
    private TextBox? _rawBox;
    private TextBlock? _parseSummary;
    private StackPanel? _presetHost;
    private TextBlock? _presetCount;
    private StackPanel? _configHost;
    private StackPanel? _resultHost;
    private Button? _startBtn;
    private Button? _pauseBtn;
    private Button? _stopBtn;
    private Button? _clearBtn;

    // ── 关注列表（用户 2026-10-28 需求）───────────────────────────
    // 「可自选」= 既支持全选也支持只挑几个：拉取后逐个人勾选，再把选中的填进名单。
    private TextBlock? _followingStatus;
    private StackPanel? _followingListHost;
    private Button? _fetchFollowingBtn;
    private readonly List<XFollowingUser> _following = new();
    private readonly HashSet<string> _followingChecked = new(StringComparer.Ordinal);

    /// <summary>下载配置区所有 chip（点一下只重刷这几处的配色，不重建整页）。</summary>
    private readonly List<(Button Btn, TextBlock Text, Func<bool> Selected)> _configChips = new();

    private int _page = 1;
    private int _pageSize = 12;

    public AutoTaskPage() { InitializeComponent(); }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _store.Changed += OnStoreChanged;
        Build();

        // 内容宽度 = min(视口宽度, 1200)：宽窗时居中留白对称，窄窗时占满；
        // 用代码夹宽度而不是只靠 XAML 的 Stretch/Center —— 后者在
        // Center + MaxWidth 下会被内容的自然宽度收缩，卡片会变窄。
        PageScroll.SizeChanged += (_, _) => SyncRootWidth();
        PageScroll.ViewChanged += (_, _) => SyncRootWidth();
        SyncRootWidth();
    }

    /// <summary>把根面板宽度夹到「可用宽度上限 1200」（可用宽度 = 视口 − ScrollViewer 的左右内边距）。</summary>
    private void SyncRootWidth()
    {
        var vw = PageScroll.ViewportWidth;
        if (vw <= 0) return;
        var pad = PageScroll.Padding.Left + PageScroll.Padding.Right;
        Root.Width = Math.Min(1200, Math.Max(0, vw - pad));
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _store.Changed -= OnStoreChanged;
        _store.SaveInput();
    }

    private void OnStoreChanged() => DispatcherQueue.TryEnqueue(RefreshDynamic);

    // ── 界面骨架 ──────────────────────────────────────────────

    private void Build()
    {
        Root.Children.Clear();
        _configChips.Clear();

        Root.Children.Add(UiKit.PageHeader("自动执行", "按名单批量跑", "\uE945"));

        // ② 告警条
        _alertHost = new StackPanel { Spacing = 14 };
        Root.Children.Add(_alertHost);

        // 一句操作反馈（原项目用 toast；WinUI 版放在告警条下方一行，不弹窗打断）
        _notice = new TextBlock
        {
            FontSize = 12.5,
            Visibility = Visibility.Collapsed,
            TextWrapping = TextWrapping.Wrap,
        };
        Root.Children.Add(_notice);

        // ③④ 双栏：左 flex 115 / 右 flex 100，间距 11（对齐原项目 .cols）
        var cols = new Grid { ColumnSpacing = 11 };
        cols.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(115, GridUnitType.Star) });
        cols.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(100, GridUnitType.Star) });

        var left = new StackPanel { Spacing = 14 };
        left.Children.Add(BuildSourceCard());
        left.Children.Add(BuildFollowingCard());
        left.Children.Add(BuildPresetsCard());
        left.Children.Add(BuildConfigCard());
        left.Children.Add(BuildExecutionCard());
        Grid.SetColumn(left, 0);
        cols.Children.Add(left);

        var right = new StackPanel { Spacing = 14 };
        _resultHost = new StackPanel();
        right.Children.Add(UiKit.Card(_resultHost, 16));
        Grid.SetColumn(right, 1);
        cols.Children.Add(right);

        Root.Children.Add(cols);

        // ⑤ 底部说明
        Root.Children.Add(new TextBlock
        {
            Text = "说明：任务创建后会进入后台队列串行执行，实际下载进度请到【下载管理】查看。",
            FontSize = 12.5,
            Opacity = 0.62,
            TextWrapping = TextWrapping.Wrap,
        });

        RefreshAlerts();
        RefreshSource();
        RefreshFollowing();
        RefreshPresets();
        RefreshConfig();
        RefreshResults();
        RefreshButtons();
    }

    // ── ② 告警条 ──────────────────────────────────────────────

    private void RefreshAlerts()
    {
        if (_alertHost is null) return;
        _alertHost.Children.Clear();

        if (_store.Running)
            _alertHost.Children.Add(Alert(UiKit.AccentFill, "\uE946",
                "批量任务正在后台执行，切换到其他页面也不会中断，回来即可继续查看进度。"));

        if (!AutoTaskStore.HasLogin)
            _alertHost.Children.Add(Alert(CriticalBrush, "\uE7BA",
                "尚未登录 X 账号，请先在【设置】中登录后再执行批量任务。"));
    }

    /// <summary>
    /// 主题画刷取值带兜底：资源键在运行期才解析，键名写错会抛 KeyNotFound 而不是编译报错，
    /// 所以这里取不到就给一个同义的手工色（红/绿），页面不至于整块崩掉。
    /// </summary>
    private static Brush ThemeBrush(string key, Color fallback)
    {
        if (Application.Current.Resources.TryGetValue(key, out var v) && v is Brush b) return b;
        return new SolidColorBrush(fallback);
    }

    private static Brush CriticalBrush =>
        ThemeBrush("SystemFillColorCriticalBrush", Color.FromArgb(255, 196, 43, 28));

    private static Border Alert(Brush tone, string glyph, string text)
    {
        var color = tone is SolidColorBrush sb ? sb.Color : Microsoft.UI.Colors.Red;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new FontIcon
        {
            Glyph = glyph,
            FontSize = 14,
            Foreground = tone,
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(new TextBlock
        {
            Text = text,
            FontSize = 13,
            Foreground = tone,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        });

        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(26, color.R, color.G, color.B)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(89, color.R, color.G, color.B)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(14, 11, 14, 11),
            Child = row,
        };
    }

    private void SetNotice(string text, bool error = false)
    {
        if (_notice is null) return;
        _notice.Text = text;
        _notice.Foreground = error ? CriticalBrush : UiKit.AccentFill;
        _notice.Visibility = Visibility.Visible;
    }

    // ── ③-1 名单来源 ──────────────────────────────────────────

    private UIElement BuildSourceCard()
    {
        var panel = new StackPanel { Spacing = 10 };

        // 文件行：左边文件名 / 说明，右边「选择 txt 文件」
        var fileRow = new Grid { ColumnSpacing = 10 };
        fileRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        fileRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _fileNameHost = new StackPanel();
        Grid.SetColumn(_fileNameHost, 0);
        fileRow.Children.Add(_fileNameHost);

        var pickBtn = new Button { Content = "选择 txt 文件", MinWidth = 110 };
        pickBtn.Click += async (_, _) => await ImportFileAsync();
        Grid.SetColumn(pickBtn, 1);
        fileRow.Children.Add(pickBtn);

        panel.Children.Add(fileRow);

        _rawBox = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 120,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 13,
            PlaceholderText = "也可以直接粘贴，每行一个：\nexample_user\n@sample_media_01\nhttps://x.com/demo_handle",
            Text = _store.RawText,
        };
        _rawBox.TextChanged += (_, _) => _store.SetRawText(_rawBox.Text);
        panel.Children.Add(_rawBox);

        _parseSummary = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.Wrap };
        panel.Children.Add(_parseSummary);

        return UiKit.SectionCard("名单来源", panel);
    }

    private void RefreshSource()
    {
        if (_fileNameHost is null) return;
        _shownFileName = _store.FileName;
        _fileNameHost.Children.Clear();
        _fileNameHost.Children.Add(new Border
        {
            Background = UiKit.SubtleFill,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12, 12, 12, 12),
            Child = new TextBlock
            {
                Text = _store.FileName.Length == 0
                    ? "每行一个用户 ID，支持：纯ID / @ID / 主页链接 / 带行号"
                    : _store.FileName,
                FontSize = 13.5,
                Opacity = _store.FileName.Length == 0 ? 0.62 : 1.0,
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.NoWrap,
            },
        });
        RefreshParseSummary();
    }

    private void RefreshParseSummary()
    {
        if (_parseSummary is null) return;
        var parsed = _store.Parsed;
        var preview = string.Join("、", parsed.Ids.Take(8));

        // 直接在本 TextBlock 上重建 Inline（Run 不能从一个父级搬到另一个父级，会抛异常）
        _parseSummary.Inlines.Clear();
        _parseSummary.Inlines.Add(new Run { Text = "已解析 " });
        _parseSummary.Inlines.Add(new Run
        {
            Text = parsed.Ids.Count.ToString(),
            Foreground = UiKit.AccentFill,
            FontWeight = FontWeights.SemiBold,
        });
        _parseSummary.Inlines.Add(new Run { Text = " 个有效用户 ID" });
        if (parsed.Skipped > 0)
        {
            _parseSummary.Inlines.Add(new Run { Text = "，另有 " });
            _parseSummary.Inlines.Add(new Run { Text = parsed.Skipped.ToString(), Foreground = CriticalBrush, FontWeight = FontWeights.SemiBold });
            _parseSummary.Inlines.Add(new Run { Text = " 行无法识别已跳过" });
        }
        if (parsed.Ids.Count > 0)
        {
            _parseSummary.Inlines.Add(new Run { Text = "：" });
            _parseSummary.Inlines.Add(new Run { Text = preview + (parsed.Ids.Count > 8 ? " …" : "") });
        }
    }

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

            // 顺序要紧：先灌进输入框（会触发 TextChanged → SetRawText，它会把 FileName 清空），
            // 再 SetFileName，否则刚选的文件名立刻被抹掉。
            if (_rawBox is not null) _rawBox.Text = text;
            _store.SetRawText(text);
            _store.SetFileName(file.Name);

            var lines = AutoTaskStore.ParseIds(text);
            SetNotice("已读取 " + lines.Ids.Count + " 行有效名单");
            RefreshSource();
            RefreshButtons();
        }
        catch (Exception ex)
        {
            SetNotice("选择文件失败：" + ex.Message, error: true);
        }
    }

    // ── ③-2 历史名单 ──────────────────────────────────────────

    private UIElement BuildPresetsCard()
    {
        _presetHost = new StackPanel { Spacing = 10 };
        return UiKit.Card(_presetHost, 16);
    }

    private void RefreshPresets()
    {
        if (_presetHost is null) return;
        _presetHost.Children.Clear();

        var presets = _store.Presets;

        var head = new Grid { ColumnSpacing = 8 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        title.Children.Add(new FontIcon { Glyph = "\uE81C", FontSize = 15, Foreground = UiKit.AccentFill, VerticalAlignment = VerticalAlignment.Center });
        title.Children.Add(new TextBlock { Text = "历史名单", FontSize = 16, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        _presetCount = new TextBlock { Text = "（" + presets.Count + "）", FontSize = 12, Opacity = 0.5, VerticalAlignment = VerticalAlignment.Center };
        title.Children.Add(_presetCount);
        Grid.SetColumn(title, 0);
        head.Children.Add(title);

        if (_store.RawText.Trim().Length > 0)
        {
            var saveBtn = new Button { Content = "保存当前", MinWidth = 96 };
            saveBtn.Click += async (_, _) => await SavePresetAsync();
            Grid.SetColumn(saveBtn, 1);
            head.Children.Add(saveBtn);
        }
        _presetHost.Children.Add(head);

        if (presets.Count == 0)
        {
            _presetHost.Children.Add(new Border
            {
                Background = UiKit.SubtleFill,
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12, 16, 12, 16),
                Child = new TextBlock
                {
                    Text = "还没有保存的名单。粘贴或导入名单后，点「保存当前」即可加入历史。",
                    FontSize = 12.5,
                    Opacity = 0.7,
                    TextWrapping = TextWrapping.Wrap,
                },
            });
            return;
        }

        var wrap = new StackPanel { Spacing = 8 };
        foreach (var p in presets) wrap.Children.Add(BuildPresetChip(p));
        _presetHost.Children.Add(wrap);
    }

    private UIElement BuildPresetChip(AutoTaskPreset p)
    {
        var active = p.Id == _store.ActivePresetId;

        var textStack = new StackPanel { Spacing = 2 };
        textStack.Children.Add(new TextBlock
        {
            Text = p.Name,
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        textStack.Children.Add(new TextBlock
        {
            Text = p.LineCount + " 个 · " + p.CreatedAt.ToString("yyyy-MM-dd HH:mm"),
            FontSize = 11,
            Opacity = 0.62,
        });

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new FontIcon
        {
            Glyph = active ? "\uE1CB" : "\uE718",
            FontSize = 13,
            Foreground = active ? UiKit.AccentFill : UiKit.SubtleFill,
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(textStack);

        var loadBtn = new Button
        {
            Content = row,
            Padding = new Thickness(12, 8, 12, 8),
            CornerRadius = new CornerRadius(10),
            MinWidth = 0,
            MinHeight = 0,
            Background = active ? UiKit.SubtleFill : null,
            BorderBrush = active ? UiKit.AccentFill : UiKit.CardBorder,
            BorderThickness = new Thickness(active ? 1.2 : 0.6),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(loadBtn, "载入名单 " + p.Name);
        loadBtn.Click += (_, _) =>
        {
            _store.LoadPreset(p.Id);
            if (_rawBox is not null) _rawBox.Text = _store.RawText;
            SetNotice("已载入历史名单：" + p.Name);
            RefreshSource();
        };

        var moreBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE712", FontSize = 12, Opacity = 0.7 },
            Padding = new Thickness(6, 6, 6, 6),
            MinWidth = 0,
            MinHeight = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(moreBtn, "名单操作 " + p.Name);

        var menu = new MenuFlyout();
        var load = new MenuFlyoutItem { Text = "载入" };
        load.Click += (_, _) =>
        {
            _store.LoadPreset(p.Id);
            if (_rawBox is not null) _rawBox.Text = _store.RawText;
            SetNotice("已载入历史名单：" + p.Name);
            RefreshSource();
        };
        var rename = new MenuFlyoutItem { Text = "重命名" };
        rename.Click += async (_, _) => await RenamePresetAsync(p);
        var del = new MenuFlyoutItem { Text = "删除" };
        del.Click += async (_, _) => await DeletePresetAsync(p);
        menu.Items.Add(load);
        menu.Items.Add(rename);
        menu.Items.Add(del);
        moreBtn.Click += (_, _) => menu.ShowAt(moreBtn);

        var outer = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        outer.Children.Add(loadBtn);
        outer.Children.Add(moreBtn);
        outer.HorizontalAlignment = HorizontalAlignment.Left;
        return outer;
    }

    private async Task SavePresetAsync()
    {
        var box = new TextBox { PlaceholderText = "名称（可留空，自动用当前时间）" };
        var dlg = new ContentDialog
        {
            Title = "保存为预设",
            Content = box,
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };
        if (await dlg.ShowAsync() != ContentDialogResult.Primary) return;

        var (ok, entry) = _store.SaveAsPreset(box.Text);
        if (!ok || entry is null)
        {
            SetNotice("保存失败：名单为空，或预设写入出错", error: true);
            return;
        }
        SetNotice("已保存到历史：" + entry.Name);
        RefreshPresets();
    }

    private async Task RenamePresetAsync(AutoTaskPreset p)
    {
        var box = new TextBox { Text = p.Name };
        var dlg = new ContentDialog
        {
            Title = "重命名",
            Content = box,
            PrimaryButtonText = "确定",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };
        if (await dlg.ShowAsync() != ContentDialogResult.Primary) return;
        _store.RenamePreset(p.Id, box.Text);
        RefreshPresets();
    }

    private async Task DeletePresetAsync(AutoTaskPreset p)
    {
        var dlg = new ContentDialog
        {
            Title = "删除「" + p.Name + "」？",
            Content = "该预设只删除历史记录，不影响当前名单。",
            PrimaryButtonText = "删除",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };
        if (await dlg.ShowAsync() != ContentDialogResult.Primary) return;
        _store.DeletePreset(p.Id);
        RefreshPresets();
    }

    // ── ③-3 下载配置（与主页共用）──────────────────────────────

    private UIElement BuildConfigCard()
    {
        _configHost = new StackPanel { Spacing = 14 };
        return UiKit.SectionCard("下载配置（与主页共用）", _configHost);
    }

    private void RefreshConfig()
    {
        if (_configHost is null) return;
        _configHost.Children.Clear();
        _configChips.Clear();   // 旧 chip 已随父面板丢弃，别留在列表里


        // 日期范围
        var datePanel = new StackPanel { Spacing = 6 };
        datePanel.Children.Add(FieldLabel("日期范围"));

        var dateChips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        void AddDateChip(string label, Func<bool> selected, Action onClick) =>
            dateChips.Children.Add(Chip(label, selected, onClick));
        AddDateChip("不限", () => !S.TimeRangeEnabled || (S.DateFrom.Length == 0 && S.DateTo.Length == 0), () =>
        {
            S.TimeRangeEnabled = false;
            S.DateFrom = "";
            S.DateTo = "";
            AppSettings.Instance.Save();
            RefreshConfig();
        });
        AddDateChip("最近 7 天", () => IsPresetAround(7), () => ApplyPresetDays(7));
        AddDateChip("最近 1 个月", () => IsPresetAround(30), () => ApplyPresetDays(30));
        AddDateChip("最近 1 年", () => IsPresetAround(365), () => ApplyPresetDays(365));
        dateChips.Children.Add(Chip(CustomRangeLabel(), () => IsCustomRange(), async () => await PickRangeAsync()));
        datePanel.Children.Add(dateChips);
        _configHost.Children.Add(datePanel);

        // 媒体类型
        var mediaPanel = new StackPanel { Spacing = 6 };
        mediaPanel.Children.Add(FieldLabel("媒体类型"));
        var mediaChips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var (id, label) in new[] { ("image", "照片"), ("video", "视频"), ("gif", "GIF"), ("audio", "音频") })
        {
            var key = id;
            mediaChips.Children.Add(Chip(label,
                () => MediaTypes().Contains(key),
                () => ToggleMediaType(key)));
        }
        mediaPanel.Children.Add(mediaChips);
        _configHost.Children.Add(mediaPanel);

        // 下载源
        var sourcePanel = new StackPanel { Spacing = 6 };
        sourcePanel.Children.Add(FieldLabel("下载源"));
        sourcePanel.Children.Add(new TextBlock
        {
            Text = "帖子能下载到更早的推文，但爬取速度较慢；媒体可能下载不到更早的推文，但爬取速度更快。",
            FontSize = 12,
            Opacity = 0.62,
            TextWrapping = TextWrapping.Wrap,
        });
        var sourceChips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        sourceChips.Children.Add(Chip("帖子", () => S.Source == "tweets", () => SetSource("tweets")));
        sourceChips.Children.Add(Chip("媒体", () => S.Source != "tweets", () => SetSource("medias")));
        sourcePanel.Children.Add(sourceChips);
        _configHost.Children.Add(sourcePanel);
    }

    private static TextBlock FieldLabel(string text) =>
        new() { Text = text, FontSize = 13, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };

    private Button Chip(string label, Func<bool> selected, Action onClick)
    {
        var text = new TextBlock { Text = label, FontSize = 12.5 };
        var btn = new Button
        {
            Content = text,
            Padding = new Thickness(10, 5, 10, 5),
            CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(1),
            MinWidth = 0,
            MinHeight = 0,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(btn, label);
        var entry = (btn, text, selected);
        _configChips.Add(entry);
        StyleChip(entry);
        btn.Click += (_, _) =>
        {
            onClick();
            foreach (var c in _configChips) StyleChip(c);
        };
        return btn;
    }

    private static void StyleChip((Button Btn, TextBlock Text, Func<bool> Selected) chip)
    {
        var accent = AccentColor();
        var on = chip.Selected();
        if (on)
        {
            chip.Btn.Background = new SolidColorBrush(Color.FromArgb(40, accent.R, accent.G, accent.B));
            chip.Btn.BorderBrush = new SolidColorBrush(Color.FromArgb(153, accent.R, accent.G, accent.B));
            chip.Text.Foreground = new SolidColorBrush(accent);
            chip.Text.FontWeight = FontWeights.SemiBold;
        }
        else
        {
            chip.Btn.Background = UiKit.SubtleFill;
            chip.Btn.BorderBrush = UiKit.CardBorder;
            chip.Text.Foreground = ThemeBrush("TextFillColorPrimaryBrush", Microsoft.UI.Colors.White);
            chip.Text.FontWeight = FontWeights.Normal;
        }
    }

    private static Color AccentColor() =>
        UiKit.AccentFill is SolidColorBrush sb ? sb.Color : Color.FromArgb(255, 0, 120, 212);

    private static HashSet<string> MediaTypes() =>
        (S.MediaTypeFilter ?? "").Split((char)44, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim().ToLowerInvariant()).ToHashSet();

    private static void ToggleMediaType(string id)
    {
        var set = MediaTypes();
        if (!set.Remove(id)) set.Add(id);
        // 固定顺序输出（与 X 下载设置页同一写法），便于人读 JSON
        S.MediaTypeFilter = string.Join(",", new[] { "image", "video", "gif", "audio" }.Where(set.Contains));
        AppSettings.Instance.Save();
    }

    private static void SetSource(string id)
    {
        S.Source = id;
        AppSettings.Instance.Save();
    }

    private static bool IsPresetAround(int days)
    {
        if (!S.TimeRangeEnabled) return false;
        if (!DateTime.TryParse(S.DateFrom, out var from)) return false;
        if (!DateTime.TryParse(S.DateTo, out var to)) return false;
        var target = DateTime.Now.AddDays(-days);
        return Math.Abs((from.Date - target.Date).TotalDays) <= 1 && to.Date == DateTime.Now.Date;
    }

    private static void ApplyPresetDays(int days)
    {
        var now = DateTime.Now;
        S.TimeRangeEnabled = true;
        S.DateFrom = now.AddDays(-days).ToString("yyyy-MM-dd");
        S.DateTo = now.ToString("yyyy-MM-dd");
        AppSettings.Instance.Save();
    }

    private static bool IsCustomRange() =>
        S.TimeRangeEnabled
        && !IsPresetAround(7) && !IsPresetAround(30) && !IsPresetAround(365)
        && (S.DateFrom.Length > 0 || S.DateTo.Length > 0);

    private static string CustomRangeLabel()
    {
        var none = S.DateFrom.Length == 0 && S.DateTo.Length == 0;
        if (!S.TimeRangeEnabled || none) return "不限";
        return (S.DateFrom.Length > 0 ? S.DateFrom : "不限") + "  ~  " + (S.DateTo.Length > 0 ? S.DateTo : "不限");
    }

    private async Task PickRangeAsync()
    {
        var from = new CalendarDatePicker
        {
            PlaceholderText = "起始日期",
            DateFormat = "{year.full}-{month.integer(2)}-{day.integer(2)}",
            MinWidth = 180,
            Header = "起始",
        };
        var to = new CalendarDatePicker
        {
            PlaceholderText = "结束日期",
            DateFormat = "{year.full}-{month.integer(2)}-{day.integer(2)}",
            MinWidth = 180,
            Header = "结束",
        };
        if (DateTime.TryParse(S.DateFrom, out var f)) from.Date = f;
        if (DateTime.TryParse(S.DateTo, out var t)) to.Date = t;

        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(from);
        panel.Children.Add(to);

        var dlg = new ContentDialog
        {
            Title = "自定义日期范围",
            Content = panel,
            PrimaryButtonText = "确定",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };
        if (await dlg.ShowAsync() != ContentDialogResult.Primary) return;

        S.TimeRangeEnabled = true;
        S.DateFrom = from.Date?.ToString("yyyy-MM-dd") ?? "";
        S.DateTo = to.Date?.ToString("yyyy-MM-dd") ?? "";
        AppSettings.Instance.Save();
        RefreshConfig();
    }

    // ── ③-4 执行设置 ──────────────────────────────────────────

    private UIElement BuildExecutionCard()
    {
        var panel = new StackPanel { Spacing = 14 };

        panel.Children.Add(NumberField("每个账号间隔（秒）", _store.IntervalSec, 0, 600,
            v => _store.SetIntervalSec((int)v)));

        panel.Children.Add(NumberField("单个加载超时（秒）", _store.TimeoutSec, 10, 1800,
            v => _store.SetTimeoutSec((int)v)));

        var check = new CheckBox
        {
            Content = "失败后继续下一个",
            IsChecked = _store.SkipOnError,
            MinWidth = 0,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(check, "失败后继续下一个");
        check.Checked += (_, _) => _store.SetSkipOnError(true);
        check.Unchecked += (_, _) => _store.SetSkipOnError(false);
        panel.Children.Add(check);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _startBtn = new Button
        {
            Content = "开始执行",
            MinWidth = 100,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        _startBtn.Click += async (_, _) => await StartRunAsync();
        actions.Children.Add(_startBtn);

        _pauseBtn = new Button { Content = "暂停", MinWidth = 88 };
        _pauseBtn.Click += (_, _) =>
        {
            _store.TogglePause();
            RefreshButtons();
        };
        actions.Children.Add(_pauseBtn);

        _stopBtn = new Button { Content = "停止", MinWidth = 88 };
        _stopBtn.Click += (_, _) =>
        {
            _store.Stop();
            RefreshButtons();
        };
        actions.Children.Add(_stopBtn);

        _clearBtn = new Button { Content = "清空结果", MinWidth = 100 };
        _clearBtn.Click += (_, _) =>
        {
            _store.ClearItems();
            _page = 1;
            RefreshResults();
        };
        actions.Children.Add(_clearBtn);

        panel.Children.Add(actions);
        return UiKit.SectionCard("执行设置", panel);
    }

    private static UIElement NumberField(string label, int value, int min, int max, Action<double> onChanged)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 13,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var box = new NumberBox
        {
            Value = value,
            Minimum = min,
            Maximum = max,
            SmallChange = 1,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
            Width = 120,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, label);
        box.ValueChanged += (_, e) =>
        {
            if (double.IsNaN(e.NewValue)) return;
            onChanged(e.NewValue);
        };
        row.Children.Add(box);
        return row;
    }

    private async Task StartRunAsync()
    {
        var err = await _store.StartAsync();
        if (err is not null)
        {
            SetNotice(err, error: true);
        }
        else
        {
            _page = 1;
            SetNotice("批量任务已启动，可切到下载管理查看进度");
        }
        RefreshAlerts();
        RefreshButtons();
        RefreshResults();
    }

    private void RefreshButtons()
    {
        var parsed = _store.Parsed;
        if (_startBtn is not null)
            _startBtn.IsEnabled = !_store.Running && AutoTaskStore.HasLogin && parsed.Ids.Count > 0;
        if (_pauseBtn is not null)
        {
            _pauseBtn.IsEnabled = _store.Running;
            _pauseBtn.Content = _store.Paused ? "继续" : "暂停";
        }
        if (_stopBtn is not null) _stopBtn.IsEnabled = _store.Running;
        if (_clearBtn is not null) _clearBtn.IsEnabled = !_store.Running;
    }

    // ── ④ 下载记录（右栏）──────────────────────────────────────

    private void RefreshResults()
    {
        if (_resultHost is null) return;
        _resultHost.Children.Clear();

        var items = _store.Items;
        if (items.Count == 0)
        {
            _resultHost.Children.Add(new TextBlock
            {
                Text = "还没有下载记录",
                FontSize = 13,
                Opacity = 0.55,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 24, 0, 24),
            });
            return;
        }

        var done = items.Count(i => i.Status == AutoTaskStatus.Done);
        var fail = items.Count(i => i.Status == AutoTaskStatus.Fail);
        var finished = done + fail;
        var percent = items.Count == 0 ? 0 : (int)Math.Round(finished * 100.0 / items.Count);

        _resultHost.Children.Add(new ProgressBar
        {
            Value = items.Count == 0 ? 0 : finished * 100.0 / items.Count,
            Maximum = 100,
            MinHeight = 6,
        });
        _resultHost.Children.Add(new TextBlock
        {
            Text = "共 " + items.Count + " 个 · 成功 " + done + " · 失败 " + fail + " · 完成 " + percent + "%",
            FontSize = 12.5,
            Opacity = 0.62,
            Margin = new Thickness(0, 6, 0, 8),
        });

        var totalPages = Math.Max(1, (int)Math.Ceiling(items.Count / (double)_pageSize));
        if (_page > totalPages) _page = totalPages;
        var start = (_page - 1) * _pageSize;
        // 只取当前页，并带上下标（避免逐行 IndexOf 的 O(n²)）
        var slice = items.Skip(start).Take(_pageSize).Select((it, k) => (Item: it, Index: start + k + 1)).ToList();

        // 表头
        var header = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 6, 0, 6) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        AddCell(header, 0, "#", true);
        AddCell(header, 1, "用户 ID", true);
        AddCell(header, 2, "状态", true);
        AddCell(header, 3, "说明", true);
        _resultHost.Children.Add(header);

        foreach (var (it, index) in slice)
        {
            var row = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 3, 0, 3) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            AddCell(row, 0, index.ToString(), false);
            AddCell(row, 1, it.Id, false, monospace: true);
            var badge = StatusBadge(it.Status);
            Grid.SetColumn(badge, 2);
            row.Children.Add(badge);
            var msg = new TextBlock
            {
                Text = it.Message ?? "-",
                FontSize = 12.5,
                Opacity = 0.62,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            ToolTipService.SetToolTip(msg, it.Message ?? "-");
            Grid.SetColumn(msg, 3);
            row.Children.Add(msg);
            _resultHost.Children.Add(row);
        }

        // 分页
        var foot = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Margin = new Thickness(0, 10, 0, 0),
        };
        foot.Children.Add(new TextBlock
        {
            Text = "第 " + (start + 1) + "-" + Math.Min(start + slice.Count, items.Count) + " 条 / 共 " + items.Count,
            FontSize = 12,
            Opacity = 0.62,
            VerticalAlignment = VerticalAlignment.Center,
        });
        foot.Children.Add(new TextBlock
        {
            Text = "每页",
            FontSize = 12,
            Opacity = 0.62,
            VerticalAlignment = VerticalAlignment.Center,
        });
        foreach (var n in new[] { 10, 20, 50, 100 })
        {
            var size = n;
            var b = new Button
            {
                Content = new TextBlock
                {
                    Text = size.ToString(),
                    FontSize = 12,
                    Opacity = _pageSize == size ? 1.0 : 0.6,
                    FontWeight = _pageSize == size ? FontWeights.SemiBold : FontWeights.Normal,
                },
                Padding = new Thickness(6, 2, 6, 2),
                MinWidth = 0,
                MinHeight = 0,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
            };
            b.Click += (_, _) =>
            {
                _pageSize = size;
                _page = 1;
                RefreshResults();
            };
            foot.Children.Add(b);
        }

        var prev = new Button { Content = "‹ 上一页", MinWidth = 0, IsEnabled = _page > 1 };
        prev.Click += (_, _) => { _page--; RefreshResults(); };
        var next = new Button { Content = "下一页 ›", MinWidth = 0, IsEnabled = _page < totalPages };
        next.Click += (_, _) => { _page++; RefreshResults(); };
        foot.Children.Add(prev);
        foot.Children.Add(next);
        foot.Children.Add(new TextBlock
        {
            Text = _page + " / " + totalPages,
            FontSize = 12,
            Opacity = 0.62,
            VerticalAlignment = VerticalAlignment.Center,
        });
        _resultHost.Children.Add(foot);
    }

    private static void AddCell(Grid grid, int column, string text, bool header, bool monospace = false)
    {
        var tb = new TextBlock
        {
            Text = text,
            FontSize = header ? 12 : 13,
            Opacity = header ? 0.62 : 1.0,
            FontWeight = header ? FontWeights.SemiBold : FontWeights.Normal,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.NoWrap,
        };
        if (monospace) tb.FontFamily = new FontFamily("Consolas");
        Grid.SetColumn(tb, column);
        grid.Children.Add(tb);
    }

    private static Border StatusBadge(AutoTaskStatus status)
    {
        var (label, brush, glyph) = status switch
        {
            AutoTaskStatus.Loading => ("加载中", UiKit.AccentFill, "\uE895"),
            AutoTaskStatus.Done => ("已创建任务", SuccessBrush, "\uE73E"),
            AutoTaskStatus.Fail => ("失败", CriticalBrush, "\uEA39"),
            _ => ("等待中", ThemeBrush("TextFillColorSecondaryBrush", Color.FromArgb(255, 128, 128, 128)), "\uE823"),
        };
        var color = brush is SolidColorBrush sb ? sb.Color : Microsoft.UI.Colors.Gray;

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        row.Children.Add(new FontIcon { Glyph = glyph, FontSize = 10, Foreground = brush, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock { Text = label, FontSize = 11, Foreground = brush, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });

        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(31, color.R, color.G, color.B)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(77, color.R, color.G, color.B)),
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(6, 2, 6, 2),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
            Child = row,
        };
    }

    private static Brush SuccessBrush =>
        ThemeBrush("SystemFillColorSuccessBrush", Color.FromArgb(255, 15, 123, 15));

    // ── 状态变化 ──────────────────────────────────────────────

    private void RefreshDynamic()
    {
        RefreshAlerts();
        RefreshButtons();
        RefreshResults();
        RefreshParseSummary();

        // 手改名单会让 store 清掉「来源文件名」，界面上那行也要跟着变
        if (_shownFileName != _store.FileName)
        {
            _shownFileName = _store.FileName;
            RefreshSource();
        }
    }

    private string _shownFileName = "";

    // ── ③-1b 关注列表 ───────────────────────────────────────────

    /// <summary>
    /// 「按关注列表下载」卡片。用户 2026-10-28：「在 x 自动下载里面加一个，按照关注列表下载」。
    ///
    /// 交互按用户确认的「可自选」来做：
    ///   ① 点「拉取关注列表」→ 分页拉完（关注几百人会有多页）；
    ///   ② 列表里逐个人显示头像/昵称/@handle，**默认全勾上**，可以取消；
    ///   ③ 点「把勾选的填入名单」→ 写进上面的名单输入框（走现有批量执行流程，不另造一套执行器）。
    /// </summary>
    private UIElement BuildFollowingCard()
    {
        var panel = new StackPanel { Spacing = 10 };

        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _followingStatus = new TextBlock
        {
            Text = "还没拉取。关注几百人时会翻很多页，稍等。",
            FontSize = 12.5,
            Opacity = 0.75,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(_followingStatus, 0);
        row.Children.Add(_followingStatus);

        _fetchFollowingBtn = new Button { Content = "拉取关注列表", MinWidth = 110 };
        _fetchFollowingBtn.Click += async (_, _) => await FetchFollowingAsync();
        Grid.SetColumn(_fetchFollowingBtn, 1);
        row.Children.Add(_fetchFollowingBtn);

        var fillBtn = new Button { Content = "把勾选的填入名单", MinWidth = 130 };
        fillBtn.Click += (_, _) => FillFromFollowing();
        Grid.SetColumn(fillBtn, 2);
        row.Children.Add(fillBtn);

        panel.Children.Add(row);

        // 全选 / 全不选 / 只看有作品的
        var ops = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var allBtn = new Button { Content = "全选", MinWidth = 70 };
        allBtn.Click += (_, _) => { foreach (var u in _following) _followingChecked.Add(u.Id); RefreshFollowing(); };
        ops.Children.Add(allBtn);
        var noneBtn = new Button { Content = "全不选", MinWidth = 70 };
        noneBtn.Click += (_, _) => { _followingChecked.Clear(); RefreshFollowing(); };
        ops.Children.Add(noneBtn);
        panel.Children.Add(ops);

        _followingListHost = new StackPanel { Spacing = 2 };
        panel.Children.Add(_followingListHost);

        return UiKit.SectionCard("按关注列表下载", panel);
    }

    private void RefreshFollowing()
    {
        if (_followingListHost is null || _followingStatus is null) return;
        _followingListHost.Children.Clear();

        if (_following.Count == 0)
        {
            _followingStatus.Text = "还没拉取。关注几百人时会翻很多页，稍等。";
            return;
        }

        _followingStatus.Text = "共 " + _following.Count + " 个关注，已勾选 " + _followingChecked.Count + " 个";

        // 列表可能几百行：只渲染前 200 个，其余用文字说明，避免一次性堆控件卡住界面
        const int showMax = 200;
        foreach (var u in _following.Take(showMax))
        {
            var item = new CheckBox
            {
                IsChecked = _followingChecked.Contains(u.Id),
                Content = u.Name + "  @" + u.ScreenName +
                          (u.MediaCount > 0 ? "  （" + u.MediaCount + " 个作品）" : ""),
                FontSize = 12.5,
            };
            item.Checked += (_, _) => _followingChecked.Add(u.Id);
            item.Unchecked += (_, _) => _followingChecked.Remove(u.Id);
            _followingListHost.Children.Add(item);
        }
        if (_following.Count > showMax)
        {
            _followingListHost.Children.Add(new TextBlock
            {
                Text = "（列表较长，只显示前 " + showMax + " 个；全选仍会作用于全部 " + _following.Count + " 个）",
                FontSize = 11.5,
                Opacity = 0.6,
                TextWrapping = TextWrapping.Wrap,
            });
        }
    }

    private async Task FetchFollowingAsync()
    {
        if (_fetchFollowingBtn is null || _followingStatus is null) return;
        _fetchFollowingBtn.IsEnabled = false;
        _followingStatus.Text = "正在拉取…";
        try
        {
            var api = new ParseDl.Services.X.XHomeApi(AppSettings.Instance.ForModule(ModuleKey).EffectiveCookie);
            if (!api.HasLogin) { _followingStatus.Text = "未登录：请先在 X 下载设置里填入 Cookie"; return; }

            // 关注列表接口要「当前登录账号的 user_id」。
            // 设置里存的是 LastVerifiedUser（@handle），用它反查 user_id。
            var sn = AppSettings.Instance.ForModule(ModuleKey).LastVerifiedUser;
            if (string.IsNullOrWhiteSpace(sn))
            {
                _followingStatus.Text = "读不到当前账号，请先到「X 下载设置」点一次「保存并验证」";
                return;
            }
            _followingStatus.Text = "正在确认当前账号…";
            var me = (await api.GetUserAsync(sn)).Id;
            if (string.IsNullOrWhiteSpace(me))
            {
                _followingStatus.Text = "确认当前账号失败（拿不到 user_id）";
                return;
            }

            var following = new ParseDl.Services.X.XFollowingApi(api);
            var users = await following.GetAllFollowingAsync(me, maxPages: 20,
                onProgress: (page, count) => DispatcherQueue.TryEnqueue(() =>
                    _followingStatus.Text = "正在拉取…第 " + page + " 页，已拿到 " + count + " 人"));

            _following.Clear();
            _followingChecked.Clear();
            _following.AddRange(users);
            // 默认全勾上（用户可再取消）
            foreach (var u in users) _followingChecked.Add(u.Id);
            RefreshFollowing();
        }
        catch (Exception ex)
        {
            _followingStatus.Text = "拉取失败：" + ex.Message;
        }
        finally
        {
            _fetchFollowingBtn.IsEnabled = true;
        }
    }

    /// <summary>把勾选的关注用户填进名单输入框（走现有批量执行流程）。</summary>
    private void FillFromFollowing()
    {
        var picked = _following.Where(u => _followingChecked.Contains(u.Id)).ToList();
        if (picked.Count == 0) { SetNotice("没有勾选任何人", error: true); return; }

        // 用 @handle 而不是裸数字 ID —— 名单解析器认得多，而且用户肉眼能核对
        var text = string.Join(Environment.NewLine, picked.Select(u => "@" + u.ScreenName));
        if (_rawBox is not null) _rawBox.Text = text;
        _store.SetRawText(text);
        _store.SetFileName("来自关注列表（" + picked.Count + " 人）");
        SetNotice("已把 " + picked.Count + " 个关注用户填入名单，可以直接点开始");
        RefreshSource();
        RefreshButtons();
    }
}
