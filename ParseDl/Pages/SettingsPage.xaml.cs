using System;
using System.Collections.Generic;
using System.Linq;
using System.Diagnostics;
using System.IO;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;

namespace ParseDl.Pages;

/// <summary>导航到全局设置时带的参数：宿主窗口 + 要显示的分类 id。</summary>
public sealed record SettingsNavArgs(MainWindow Host, string Category);

/// <summary>
/// 全局设置 —— 顶部横向分类 + 居中列内容。
///
/// ### 为什么是「顶部横向」而不是「左侧竖栏」
/// 2026-10-25 用户明确否掉了页面内的左侧分类栏：app 的**主导航**已经是一根左侧栏，
/// 页面里再套一根 = 两层竖栏并排，看起来像多了一级导航，还把内容区挤窄。
/// 分类是同一页内的分节，用顶部横向分段（WinUI SelectorBar，与下载管理页同款控件）
/// 表达「并列的几段」才对，也不与主导航抢层级。
///
/// 六个分类：外观（材质 / 明暗 / 主题色 / 导航形态）/ 下载 / 代理 / 日志 / 数据目录 / 关于。
/// 分类维度与 Flutter 版 settings_page.dart 的 global 分支一致。
///
/// ### 硬性约定
/// 设置项开关必须与标题**同行**、水平距离 ≤24px（用户 2026-09-30 约定）。
/// 本页所有开关都走 [SettingRows.Switch]，间距固定 8px。
/// </summary>
public sealed partial class SettingsPage : Page
{
    private MainWindow? _host;
    private bool _suppressThemeEvent;
    private bool _suppressMaterialEvent;
    /// <summary>主题色预设色板的容器（应用后重建，刷新「当前选中」的标记）。</summary>
    private Grid? _accentBoard;

    /// <summary>自定义色的十六进制输入框（色轮拖动时同步刷新）。</summary>
    private TextBox? _accentHexBox;

    /// <summary>主题色状态提示行。</summary>
    private TextBlock? _accentStatus;

    /// <summary>分类项。</summary>
    private sealed record Category(string Id, string Label, string Glyph);

    private static readonly Category[] Categories =
    {
        new("appearance", "外观", "\uE790"),
        new("download", "下载", "\uE896"),
        new("proxy", "代理", "\uE774"),
        new("logs", "日志", "\uE9D9"),
        new("data", "数据目录", "\uE8B7"),
        new("about", "关于", "\uE946"),
    };

    private static readonly (MaterialKind Kind, string Label, string Hint)[] Materials =
    {
        (MaterialKind.Mica, "Mica", "柔和云母 —— 长驻窗口的基础层"),
        (MaterialKind.MicaAlt, "Mica Alt", "层次云母 —— 带标签页的窗口"),
        (MaterialKind.Acrylic, "Acrylic", "磨砂玻璃 —— 半透明"),
        (MaterialKind.AcrylicThin, "Acrylic Thin", "更透亮的磨砂"),
    };

    private string _currentCategory = "appearance";

    /// <summary>内容区可用宽度（SyncWidth 里算出来）。卡片显式用这个宽度。</summary>
    private double _contentWidth = 900;
    private bool _built;

    public SettingsPage()
    {
        InitializeComponent();
        // 宽度同步：把外层容器宽度定死成 ScrollViewer 的视口宽。
        // 不做这一步，ScrollViewer 的内容宿主会把 Stretch 退化成「按内容宽」，
        // 卡片永远只有 476px（实测），既不居中也很空。
        Loaded += (_, _) =>
        {
            SyncWidth();
            if (!_built) RenderCategory(_currentCategory);
        };
        RootScroll.SizeChanged += (_, _) => SyncWidth();
    }

    /// <summary>把 WidthHost 宽度同步成 ScrollViewer 视口宽（减掉 Padding）。</summary>
    private void SyncWidth()
    {
        var w = RootScroll.ActualWidth - RootScroll.Padding.Left - RootScroll.Padding.Right;
        if (w <= 0) return;
        WidthHost.Width = w;
        var target = Math.Min(w, 900);
        if (Math.Abs(target - _contentWidth) > 0.5)
        {
            _contentWidth = target;
            if (_built) RenderCategory(_currentCategory);
        }
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        // 两种入参都接：新形态是 SettingsNavArgs（带分类 id），
        // 旧的直接传 MainWindow 也兼容（默认落到「外观」）。
        switch (e.Parameter)
        {
            case SettingsNavArgs args:
                _host = args.Host;
                if (CategoryIds.Contains(args.Category)) _currentCategory = args.Category;
                break;
            case MainWindow host:
                _host = host;
                break;
        }
        _built = false;
        RenderCategory(_currentCategory);
    }

    /// <summary>合法分类 id 集合（与 NavModel.SettingsGroup 的子项一一对应）。</summary>
    private static readonly HashSet<string> CategoryIds =
        new(Categories.Select(c => c.Id), StringComparer.Ordinal);

    private void RenderCategory(string id)
    {
        if (ContentRoot is null) return;
        ContentRoot.Children.Clear();
        // ContentRoot 现在是 Grid（不是 StackPanel）：每加一个子元素要配一行 Auto，
        // 否则所有卡片会叠在第 0 行上。清空时把行定义也重置。
        ContentRoot.RowDefinitions.Clear();

        // 页头固定写「设置」，分类名由顶部的 SelectorBar 表达 ——
        // 两处都写分类名（「外观设置」+ 选中的「外观」）是同一句话说两遍。
        AddRow(UiKit.PageHeader("设置", SubtitleOf(id), "\uE713"));

        switch (id)
        {
            case "appearance":
                AddRow(BuildAppearance());
                break;
            case "download":
                AddRow(BuildDownload());
                break;
            case "proxy":
                AddRow(BuildProxy());
                break;
            case "logs":
                AddRow(BuildLogs());
                break;
            case "data":
                AddRow(BuildDataDir());
                break;
            default:
                AddRow(BuildAbout());
                break;
        }
        _built = true;
    }

    private static string SubtitleOf(string id) => id switch
    {
        "appearance" => "窗口材质 · 明暗 · 主题色 · 导航形态",
        "download" => "保存目录 · 并发 · 模板 · 日志开关",
        "proxy" => "代理地址与系统代理",
        "logs" => "运行日志与排障",
        "data" => "设置文件与下载落点",
        _ => "版本与许可",
    };

    // ── 外观 ────────────────────────────────────────────────

    private UIElement BuildAppearance()
    {
        var panel = new StackPanel { Spacing = 16 };

        // ① 窗口材质：四档分段单选
        var materialPanel = new StackPanel { Spacing = 6 };
        var group = "material-" + Guid.NewGuid().ToString("N");
        _suppressMaterialEvent = true;
        foreach (var (kind, label, hint) in Materials)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var rb = new RadioButton
            {
                Content = label,
                GroupName = group,
                Tag = kind,
                MinWidth = 130,
                IsChecked = _host is not null && kind == _host.CurrentMaterial,
            };
            AutomationProperties.SetName(rb, "material-" + kind);
            rb.Checked += OnMaterialChecked;
            row.Children.Add(rb);
            row.Children.Add(new TextBlock { Text = hint, FontSize = 12, Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center });
            materialPanel.Children.Add(row);
        }
        _suppressMaterialEvent = false;
        panel.Children.Add(SettingRows.Card("窗口材质",
            "四档全部由 Windows App SDK 官方合成控制器绘制",
            materialPanel));

        // ② 明暗
        var themeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var tg = "theme-" + Guid.NewGuid().ToString("N");
        var darkRadio = new RadioButton { Content = "深色", GroupName = tg, Tag = true, MinWidth = 100 };
        var lightRadio = new RadioButton { Content = "浅色", GroupName = tg, Tag = false, MinWidth = 100 };
        AutomationProperties.SetName(darkRadio, "theme-dark");
        AutomationProperties.SetName(lightRadio, "theme-light");
        _suppressThemeEvent = true;
        var isDark = _host?.IsDarkTheme ?? AppSettings.Instance.IsDark;
        darkRadio.IsChecked = isDark;
        lightRadio.IsChecked = !isDark;
        _suppressThemeEvent = false;
        darkRadio.Checked += OnThemeChecked;
        lightRadio.Checked += OnThemeChecked;
        themeRow.Children.Add(darkRadio);
        themeRow.Children.Add(lightRadio);
        panel.Children.Add(SettingRows.Card("明暗", "切换后材质会带着真实主题重新应用", themeRow));

        // ③ 主题色 —— 真接逻辑：预设色板 + 自定义色轮 + 实时预览
        panel.Children.Add(BuildAccentCard());

        // ④ 导航形态（同上）
        var navNote = new StackPanel { Spacing = 6 };
        navNote.Children.Add(SettingRows.Description(
            "WinUI 版目前固定为左侧导航栏（NavigationView，PaneDisplayMode=Left）。" +
            "原 Flutter 版的「底部悬浮 Dock / 常规侧边栏」二选一尚未移植 —— 切换要改 MainWindow 的 NavigationView，" +
            "不在本页可改的范围内。"));
        panel.Children.Add(SettingRows.Card("导航形态", "左侧栏 / 悬浮 Dock", navNote));

        return panel;
    }

    // ── 主题色（强调色）─────────────────────────────────────

    /// <summary>
    /// 主题色卡片：预设色板 + 自定义色（ColorPicker 色轮 + 十六进制）+ 实时预览。
    ///
    /// 三件东西各司其职：
    ///  * 色板 —— 8 套预设，点一下立即生效，当前选中的那格有描边 + 对勾标记；
    ///  * 自定义 —— WinUI 官方 ColorPicker 当色轮（用户原话「加一个自选轮盘」），
    ///    旁边一个十六进制框，两边互相同步；改完点「应用」才落盘（拖色轮时不宜每像素写盘）；
    ///  * 预览 —— 一个按钮 / 一个开关 / 一个选中态，全部用真实控件而不是画色块，
    ///    这样预览里看到的就是界面上真正的样子。
    /// </summary>
    private UIElement BuildAccentCard()
    {
        var panel = new StackPanel { Spacing = 14 };

        panel.Children.Add(SettingRows.Description(
            "选一套预设，或者自己调一个颜色。切换立即生效并保存，下次启动自动恢复。"));

        // ① 预设色板
        _accentBoard = new Grid { ColumnSpacing = 10, RowSpacing = 10 };
        for (var i = 0; i < 4; i++)
            _accentBoard.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _accentBoard.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _accentBoard.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.Children.Add(_accentBoard);
        RebuildAccentBoard();

        // ② 自定义色
        var custom = new StackPanel { Spacing = 10 };

        var colorPicker = new ColorPicker
        {
            IsAlphaEnabled = false,
            IsAlphaSliderVisible = false,
            IsAlphaTextInputVisible = false,
            IsColorChannelTextInputVisible = true,
            IsHexInputVisible = true,
            IsMoreButtonVisible = false,
            ColorSpectrumShape = ColorSpectrumShape.Ring,
            MinWidth = 320,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(colorPicker, "accent-color-picker");
        // 色轮初值 = 当前**实际生效**的那个色（预设时取该预设的 fill），
        // 而不是写死默认蓝 —— 否则用户选过紫罗兰，打开色轮还停在蓝色。
        if (AccentService.TryParseHex(CurrentAccentHex(), out var seed)) colorPicker.Color = seed;

        var hexRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _accentHexBox = new TextBox
        {
            Text = AccentService.Hex(colorPicker.Color),
            Width = 120,
            FontFamily = new FontFamily("Consolas"),
            PlaceholderText = "#RRGGBB",
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_accentHexBox, "accent-hex");
        hexRow.Children.Add(_accentHexBox);

        var applyBtn = new Button { Content = "应用自定义色", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(applyBtn, "accent-apply-custom");
        hexRow.Children.Add(applyBtn);
        custom.Children.Add(hexRow);

        _accentStatus = new TextBlock { FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
        custom.Children.Add(_accentStatus);

        // 色轮 ↔ 十六进制框双向同步。拖动色轮时**不写盘**，只更新输入框文字。
        var syncing = false;
        colorPicker.ColorChanged += (s, e) =>
        {
            if (syncing || _accentHexBox is null) return;
            syncing = true;
            _accentHexBox.Text = AccentService.Hex(s.Color);
            syncing = false;
        };
        _accentHexBox.TextChanged += (_, _) =>
        {
            if (syncing) return;
            if (AccentService.TryParseHex(_accentHexBox.Text, out var c))
            {
                syncing = true;
                colorPicker.Color = c;
                syncing = false;
                _accentStatus!.Text = "";
            }
            else
            {
                _accentStatus!.Text = "十六进制格式不对，应形如 #0078D4";
            }
        };

        applyBtn.Click += (_, _) =>
        {
            if (!AccentService.TryParseHex(_accentHexBox?.Text, out var c))
            {
                _accentStatus!.Text = "十六进制格式不对，应形如 #0078D4";
                return;
            }
            ApplyAccent(AccentService.CustomId, AccentService.Hex(c));
        };

        custom.Children.Add(colorPicker);
        panel.Children.Add(SettingRows.Row("自定义色", "色轮上取色，或直接填十六进制；点「应用自定义色」生效。", custom));

        // ③ 实时预览
        panel.Children.Add(BuildAccentPreview());

        return SettingRows.Card("主题色", "按钮、开关、选中态与链接用的强调色", panel);
    }

    /// <summary>重建预设色板（换色后调用，刷新「当前选中」的标记）。</summary>
    private void RebuildAccentBoard()
    {
        if (_accentBoard is null) return;
        _accentBoard.Children.Clear();

        var currentId = AccentService.CurrentId;
        var isDark = _host?.IsDarkTheme ?? AppSettings.Instance.IsDark;

        for (var i = 0; i < AccentService.Presets.Count; i++)
        {
            var preset = AccentService.Presets[i];
            var selected = !string.Equals(currentId, AccentService.CustomId, StringComparison.OrdinalIgnoreCase)
                           && string.Equals(currentId, preset.Id, StringComparison.OrdinalIgnoreCase);
            var swatchColor = AccentService.TryParseHex(
                isDark ? preset.DarkBase : preset.LightBase, out var sc) ? sc : Windows.UI.Color.FromArgb(255, 128, 128, 128);

            var tile = new Border
            {
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(10, 8, 10, 8),
                Background = selected ? SettingRows.SubtleFill : new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0)),
                BorderBrush = selected ? new SolidColorBrush(swatchColor) : SettingRows.CardBorder,
                BorderThickness = new Thickness(selected ? 2 : 1),
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(tile, "accent-preset-" + preset.Id);
            ToolTipService.SetToolTip(tile, preset.Hint);

            var body = new StackPanel { Spacing = 6 };
            var topRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            topRow.Children.Add(new Border
            {
                Width = 20, Height = 20, CornerRadius = new CornerRadius(10),
                Background = new SolidColorBrush(swatchColor),
                BorderBrush = SettingRows.CardBorder, BorderThickness = new Thickness(1),
            });
            topRow.Children.Add(new TextBlock
            {
                Text = preset.Name, FontSize = 13,
                VerticalAlignment = VerticalAlignment.Center,
                FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal,
            });
            if (selected)
            {
                topRow.Children.Add(new FontIcon
                {
                    Glyph = "\uE73E", FontSize = 12,
                    Foreground = new SolidColorBrush(swatchColor),
                    VerticalAlignment = VerticalAlignment.Center,
                });
            }
            body.Children.Add(topRow);
            body.Children.Add(new TextBlock
            {
                Text = AccentService.Hex(swatchColor), FontSize = 11, Opacity = 0.6,
                FontFamily = new FontFamily("Consolas"),
            });
            tile.Child = body;

            // 点一下生效。用 Button 包一层拿到 hover / 键盘可达性：
            // Border 没有 Click，直接挂 PointerPressed 既无键盘支持也没焦点框。
            var button = new Button
            {
                Content = tile,
                Padding = new Thickness(0),
                BorderThickness = new Thickness(0),
                Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0)),
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                VerticalContentAlignment = VerticalAlignment.Stretch,
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "accent-apply-" + preset.Id);
            var id = preset.Id;
            button.Click += (_, _) => ApplyAccent(id, null);

            Grid.SetColumn(button, i % 4);
            Grid.SetRow(button, i / 4);
            _accentBoard.Children.Add(button);
        }
    }

    /// <summary>应用一套配色：写设置 → 应用到应用级资源 → 刷新色板与状态行。</summary>
    private void ApplyAccent(string id, string? customHex)
    {
        var cfg = AppSettings.Instance;
        cfg.AccentPreset = id;
        if (!string.IsNullOrWhiteSpace(customHex)) cfg.AccentHex = customHex!;
        cfg.Save();

        var isDark = _host?.IsDarkTheme ?? cfg.IsDark;
        var ok = AccentService.Apply(id, cfg.AccentHex, isDark);

        var name = string.Equals(id, AccentService.CustomId, StringComparison.OrdinalIgnoreCase)
            ? "自定义 " + cfg.AccentHex
            : AccentService.PresetOf(id).Name;
        if (_accentStatus is not null)
        {
            _accentStatus.Text = ok
                ? $"已应用「{name}」—— 已写入浅色与深色两套主题字典"
                : $"⚠ 界面资源不可用，未能应用「{name}」（设置已保存，下次启动会再试）";
        }

        RebuildAccentBoard();
        RefreshAccentPreview();
    }

    /// <summary>当前应显示在色轮 / 十六进制框里的色值（当前实际生效的那个 fill）。</summary>
    private string CurrentAccentHex()
    {
        var isDark = _host?.IsDarkTheme ?? AppSettings.Instance.IsDark;
        var (fill, _, _, _) = ResolveAccentForUi(isDark);
        return fill;
    }

    /// <summary>预览区的三个控件引用，换色后要刷。</summary>
    private Button? _previewButton;
    private ToggleSwitch? _previewToggle;
    private Border? _previewSelectedChip;

    /// <summary>
    /// 实时预览：按钮 / 开关 / 选中态各一个，**全部用真实控件**。
    /// 画三个色块只能说明「色值是多少」，说明不了「界面里长什么样」——
    /// 按钮上的字会不会看不清、开关拨到开是什么样，只有真控件能看出来。
    /// </summary>
    private UIElement BuildAccentPreview()
    {
        var wrap = new StackPanel { Spacing = 8 };
        wrap.Children.Add(new TextBlock { Text = "实时预览", FontSize = 12, Opacity = 0.6 });

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, VerticalAlignment = VerticalAlignment.Center };

        _previewButton = new Button { Content = "主要按钮", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_previewButton, "accent-preview-button");
        row.Children.Add(_previewButton);

        var toggleWrap = new StackPanel { Orientation = Orientation.Horizontal, Spacing = SettingRows.InlineGap, VerticalAlignment = VerticalAlignment.Center };
        toggleWrap.Children.Add(new TextBlock { Text = "开关", FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
        _previewToggle = new ToggleSwitch { IsOn = true, OnContent = "", OffContent = "", MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_previewToggle, "accent-preview-toggle");
        toggleWrap.Children.Add(_previewToggle);
        row.Children.Add(toggleWrap);

        _previewSelectedChip = new Border
        {
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(12, 6, 12, 6),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = "选中态", FontSize = 13 },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_previewSelectedChip, "accent-preview-selected");
        row.Children.Add(_previewSelectedChip);

        wrap.Children.Add(row);
        RefreshAccentPreview();
        return wrap;
    }

    /// <summary>把预览里的选中态配色刷成当前强调色（按钮与开关由系统按资源自动跟）。</summary>
    private void RefreshAccentPreview()
    {
        if (_previewSelectedChip is null) return;
        var isDark = _host?.IsDarkTheme ?? AppSettings.Instance.IsDark;
        var (fillHex, _, _, onAccentHex) = ResolveAccentForUi(isDark);
        if (!AccentService.TryParseHex(fillHex, out var fill)) return;
        if (!AccentService.TryParseHex(onAccentHex, out var onAccent)) return;

        _previewSelectedChip.Background = new SolidColorBrush(fill);
        if (_previewSelectedChip.Child is TextBlock tb) tb.Foreground = new SolidColorBrush(onAccent);
    }

    /// <summary>取当前选择在指定明暗下的 (fill, secondary, tertiary, onAccent)。</summary>
    /// <remarks>
    /// 直接转调 [AccentService.Resolve]：公式只有服务里那一份。
    /// 早先在页面里另抄了一遍（还抄错了方向），预览与实际生效颜色对不上。
    /// </remarks>
    private static (string Fill, string Secondary, string Tertiary, string OnAccent) ResolveAccentForUi(bool isDark)
        => AccentService.Resolve(AccentService.CurrentId, AppSettings.Instance.AccentHex, isDark);

    private void OnMaterialChecked(object sender, RoutedEventArgs e)
    {
        if (_suppressMaterialEvent) return;
        if (sender is not RadioButton rb || rb.Tag is not MaterialKind kind) return;
        if (_host is null) return;
        _host.ApplyMaterial(kind, _host.IsDarkTheme);
    }

    private void OnThemeChecked(object sender, RoutedEventArgs e)
    {
        if (_suppressThemeEvent || _host is null) return;
        if (sender is not RadioButton rb || rb.Tag is not bool dark) return;
        // 改 RootGrid.RequestedTheme 而不是直接调材质：MainWindow 订阅了
        // ActualThemeChanged，会带着真实主题重新 Apply，界面与材质才一致。
        _host.ApplyTheme(dark);

        // 强调色分浅/深两套：切了明暗要**重新应用一次**，否则界面已经变浅色、
        // 强调色还停在深色那一套（浅底上的亮蓝按钮对比度会掉）。
        AppSettings.Instance.IsDark = dark;
        AppSettings.Instance.Save();
        AccentService.Apply(AccentService.CurrentId, AppSettings.Instance.AccentHex, dark);

        // 色板与预览也跟着刷（色块取的是「该明暗下的那一档」）
        RebuildAccentBoard();
        RefreshAccentPreview();
    }

    // ── 下载 ────────────────────────────────────────────────

    private UIElement BuildDownload()
    {
        var cfg = AppSettings.Instance;
        var panel = new StackPanel { Spacing = 16 };

        var dirPanel = new StackPanel { Spacing = 8 };
        var dirRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var dirBox = new TextBox
        {
            Text = cfg.SaveDirBase,
            IsReadOnly = true,
            MinWidth = 340,
            PlaceholderText = "未选择（用默认目录）",
        };
        dirRow.Children.Add(dirBox);
        var status = new TextBlock { Text = "", FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };

        var pick = new Button { Content = "选择文件夹" };
        pick.Click += async (_, _) =>
        {
            try
            {
                var folder = await FolderPickerService.PickAsync();
                if (folder is null) return;
                var (ok, msg) = FolderPickerService.VerifyWritable(folder.Path);
                if (!ok) { status.Text = "❌ 该目录不可写：" + msg; return; }
                cfg.SaveDirBase = folder.Path;
                cfg.Save();
                dirBox.Text = folder.Path;
                status.Text = "✅ 已保存，立即生效";
            }
            catch (Exception ex)
            {
                status.Text = "❌ 选择失败：" + ex.GetType().Name + " " + ex.Message;
            }
        };
        dirRow.Children.Add(pick);

        var clear = new Button { Content = "清除" };
        clear.Click += (_, _) =>
        {
            cfg.SaveDirBase = "";
            cfg.Save();
            dirBox.Text = "";
            status.Text = "已清除，改用默认目录（数据目录\\downloads）";
        };
        dirRow.Children.Add(clear);
        dirPanel.Children.Add(dirRow);
        dirPanel.Children.Add(status);
        panel.Children.Add(SettingRows.Card("保存目录", "留空则使用 数据目录\\downloads", dirPanel));

        var dl = new StackPanel { Spacing = 16 };
        dl.Children.Add(SettingRows.Number("并发上限",
            "aria2 同时下载的任务数（1-16）",
            cfg.MaxConcurrent, 1, 16,
            v => { cfg.MaxConcurrent = (int)v; cfg.Save(); }));
        dl.Children.Add(SettingRows.Number("请求间隔（毫秒）",
            "每次接口请求之间的间隔，太小容易触发限流",
            cfg.RequestIntervalMs, 200, 10000,
            v => { cfg.RequestIntervalMs = (int)v; cfg.Save(); }));
        dl.Children.Add(SettingRows.Number("每批数量",
            "一次加载多少条",
            cfg.BatchSize, 1, 500,
            v => { cfg.BatchSize = (int)v; cfg.Save(); }));
        dl.Children.Add(SettingRows.Switch("跳过同名文件",
            "按模板算出的完整路径已存在则跳过，不重新下载",
            cfg.SameFileSkip,
            v => { cfg.SameFileSkip = v; cfg.Save(); }));
        panel.Children.Add(SettingRows.Card("下载引擎", "并发 · 间隔 · 跳过策略", dl));

        var tplPanel = new StackPanel { Spacing = 8 };
        var tplBox = new TextBox
        {
            Text = cfg.FileNameTemplate,
            FontFamily = new FontFamily("Consolas"),
            PlaceholderText = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%",
        };
        var preview = new TextBlock { Text = "", FontSize = 12, FontFamily = new FontFamily("Consolas"), TextWrapping = TextWrapping.Wrap, Opacity = 0.8 };
        void Update()
        {
            cfg.FileNameTemplate = tplBox.Text ?? "";
            cfg.Save();
            preview.Text = PreviewOf(cfg.FileNameTemplate);
        }
        tplBox.TextChanged += (_, _) => Update();
        tplPanel.Children.Add(tplBox);
        tplPanel.Children.Add(new TextBlock
        {
            Text = "变量：%POST_TIME% %USER_SCREEN_NAME% %POST_ID% %MEDIA_INDEX% %EXT% 等，各模块设置页里列出完整清单。",
            FontSize = 12, Opacity = 0.62, TextWrapping = TextWrapping.Wrap,
        });
        tplPanel.Children.Add(new TextBlock { Text = "输出示例", FontSize = 12, Opacity = 0.6 });
        tplPanel.Children.Add(preview);
        panel.Children.Add(SettingRows.Card("默认文件名模板", "各模块没有单独设置时使用", tplPanel));
        Update();

        return panel;
    }

    private static string PreviewOf(string template)
    {
        var ctx = new TemplateContext
        {
            PostId = "1734567890123456789",
            PostTime = new DateTime(2024, 1, 20, 21, 15, 36),
            UserId = "1234567890",
            UserName = "示例作者",
            UserScreenName = "example_user",
            MediaId = "1734567890123456799",
            MediaType = "image",
            Extension = ".jpg",
            MediaIndex = 1,
            MediaCount = 4,
            Content = "示例推文正文",
        };
        var s = FileNameTemplate.Resolve(template ?? "", ctx).Trim();
        return s.Length == 0 ? "（模板为空，将回退为 媒体ID_时间戳.扩展名）" : s;
    }

    // ── 代理 ────────────────────────────────────────────────

    private UIElement BuildProxy()
    {
        var cfg = AppSettings.Instance;
        var panel = new StackPanel { Spacing = 16 };

        panel.Children.Add(SettingRows.Switch("启用代理",
            "关闭后所有接口请求直连",
            cfg.ProxyEnable,
            v => { cfg.ProxyEnable = v; cfg.Save(); }));

        panel.Children.Add(SettingRows.Switch("使用系统代理",
            "读 Windows「Internet 选项」里的代理设置；关闭后使用下面填的地址",
            cfg.ProxyUseSystem,
            v => { cfg.ProxyUseSystem = v; cfg.Save(); }));

        var urlBox = new TextBox
        {
            Text = cfg.ProxyUrl,
            PlaceholderText = "http://127.0.0.1:7890",
            FontFamily = new FontFamily("Consolas"),
        };
        var urlStatus = new TextBlock { Text = "", FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
        urlBox.TextChanged += (_, _) =>
        {
            cfg.ProxyUrl = urlBox.Text ?? "";
            cfg.Save();
            var empty = cfg.ProxyEnable && !cfg.ProxyUseSystem && cfg.ProxyUrl.Trim().Length == 0;
            urlStatus.Text = empty ? "❌ 启用代理且不用系统代理时，地址必填" : "";
        };
        panel.Children.Add(SettingRows.Row("代理地址", "形如 http://127.0.0.1:7890；不用系统代理时必填。", urlBox));
        panel.Children.Add(urlStatus);

        return SettingRows.Card("代理", "接口请求走哪条线路", panel);
    }

    // ── 日志 ────────────────────────────────────────────────

    private UIElement BuildLogs()
    {
        var cfg = AppSettings.Instance;
        var panel = new StackPanel { Spacing = 16 };

        panel.Children.Add(SettingRows.Switch("写运行日志",
            "关掉可减少磁盘写入（下载引擎的逐任务日志随之停止）",
            cfg.WriteLogs,
            v => { cfg.WriteLogs = v; cfg.Save(); }));

        var logDir = Path.Combine(AppPaths.DataDir, "logs");
        var info = new StackPanel { Spacing = 6 };
        info.Children.Add(new TextBlock
        {
            Text = logDir,
            FontSize = 12,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        info.Children.Add(SettingRows.Description(Directory.Exists(logDir)
            ? "该目录已存在。"
            : "该目录尚未创建 —— 还没有产生过日志。"));
        var open = new Button { Content = "打开日志目录" };
        open.Click += (_, _) => OpenInExplorer(logDir);
        info.Children.Add(open);
        panel.Children.Add(SettingRows.Card("日志", "运行日志落点", info));

        // ── 自动删除（用户 2026-10-26：「日志增加自动删除，可以选择时间删除或者不删除」）
        var cleanPanel = new StackPanel { Spacing = 10 };

        var options = new[] { "不自动删除", "保留 1 天", "保留 3 天", "保留 7 天", "保留 30 天" };
        var dayValues = new[] { 0, 1, 3, 7, 30 };
        var combo = new ComboBox { MinWidth = 180 };
        foreach (var o in options) combo.Items.Add(o);
        var idx0 = Array.IndexOf(dayValues, cfg.LogRetentionDays);
        combo.SelectedIndex = idx0 >= 0 ? idx0 : 0;
        AutomationProperties.SetName(combo, "日志保留策略");

        var status = new TextBlock { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
        void RefreshStatus()
        {
            var d = AppSettings.Instance.LogRetentionDays;
            status.Text = d <= 0
                ? "当前：不自动删除，日志会一直留着。"
                : $"当前：超过 {d} 天的日志会在下次启动时自动删除。";
        }
        RefreshStatus();

        combo.SelectionChanged += (_, _) =>
        {
            var i2 = combo.SelectedIndex;
            if (i2 < 0 || i2 >= dayValues.Length) return;
            AppSettings.Instance.LogRetentionDays = dayValues[i2];
            AppSettings.Instance.Save();
            RefreshStatus();
        };

        var cleanNow = new Button { Content = "立即清理过期日志", MinWidth = 150 };
        AutomationProperties.SetName(cleanNow, "立即清理过期日志");
        var cleanResult = new TextBlock { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
        cleanNow.Click += (_, _) =>
        {
            var n = Aria2Engine.PurgeOldLogs();
            cleanResult.Text = n > 0 ? $"已删除 {n} 个过期日志文件。" : "没有需要清理的日志（策略为「不自动删除」时不会删任何文件）。";
        };

        cleanPanel.Children.Add(SettingRows.Description("日志按下面的策略自动清理；选「不自动删除」则一直保留。"));
        cleanPanel.Children.Add(combo);
        cleanPanel.Children.Add(status);
        cleanPanel.Children.Add(cleanNow);
        cleanPanel.Children.Add(cleanResult);
        panel.Children.Add(SettingRows.Card("自动清理", "按保留天数删除旧日志", cleanPanel));

        return panel;
    }

    // ── 数据目录 ────────────────────────────────────────────

    private UIElement BuildDataDir()
    {
        var panel = new StackPanel { Spacing = 16 };

        var dataPanel = new StackPanel { Spacing = 8 };
        dataPanel.Children.Add(new TextBlock
        {
            Text = AppPaths.DataDir,
            FontSize = 13,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        dataPanel.Children.Add(SettingRows.Description(
            "数据跟着软件走：默认在 exe 同级的 userdata\\ 下；安装到不可写位置时退到 LocalAppData\\ParseDl。"));
        var openData = new Button { Content = "打开数据目录" };
        openData.Click += (_, _) => OpenInExplorer(AppPaths.DataDir);
        dataPanel.Children.Add(openData);
        panel.Children.Add(SettingRows.Card("数据目录", "设置、台账与下载记录都存这里", dataPanel));

        // 用户 2026-10-26 要求「下载路径默认也要在安装路径下」—— 这里显式把默认下载
        // 目录露出来，省得用户去猜文件落哪了。设置里填了自定义目录时如实显示自定义值。
        var dlPanel = new StackPanel { Spacing = 8 };
        var custom = AppSettings.Instance.SaveDirBase;
        var effective = Aria2Engine.DefaultDir();
        dlPanel.Children.Add(new TextBlock
        {
            Text = effective,
            FontSize = 13,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        dlPanel.Children.Add(SettingRows.Description(
            string.IsNullOrWhiteSpace(custom)
                ? "默认在安装目录下的 downloads\\（与软件同目录，拷走整个文件夹就带走全部数据）。" +
                  (string.IsNullOrEmpty(Aria2Engine.LastDirError) ? "" : "\n注意：" + Aria2Engine.LastDirError)
                : "已自定义为上面这个目录（留空则回到安装目录下的 downloads\\）。"));
        var openDl = new Button { Content = "打开下载目录" };
        openDl.Click += (_, _) => OpenInExplorer(effective);
        dlPanel.Children.Add(openDl);
        panel.Children.Add(SettingRows.Card("默认下载目录", "下载产物默认落点", dlPanel));

        var filePanel = new StackPanel { Spacing = 6 };
        filePanel.Children.Add(new TextBlock
        {
            Text = AppSettings.Instance.FilePath,
            FontSize = 12,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        var exists = File.Exists(AppSettings.Instance.FilePath);
        filePanel.Children.Add(SettingRows.Description(exists
            ? "设置文件已存在。"
            : "设置文件尚未生成 —— 还没有改过任何设置。"));
        panel.Children.Add(SettingRows.Card("设置文件", "settings.json", filePanel));

        // ── 下载台账：清空入口 ──────────────────────────────────
        // 这个动作原来错放在「X 下载管理」页里（用户 2026-10-24 需求第④条
        // 明确点名 X 不该有它）。它是**全局**动作 —— 台账跨三个模块共用一份
        // DownloadLedger，所以入口放在全局设置的数据目录分类下，且必须二次确认。
        var ledgerPanel = new StackPanel { Spacing = 8 };
        ledgerPanel.Children.Add(SettingRows.Description(
            "当前台账共 " + DownloadLedger.Instance.Stats().Count + " 条记录（三个模块共用）。清空只删台账，不动已下载的文件。"));

        var clearLedger = new Button { Content = "清空下载台账", MinWidth = 140 };
        AutomationProperties.SetName(clearLedger, "ClearLedgerButton");
        var ledgerStatus = new TextBlock { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
        clearLedger.Click += async (_, _) =>
        {
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = "清空下载台账？",
                Content = "将删除 " + DownloadLedger.Instance.Stats().Count + " 条台账记录。已下载到磁盘的文件不会被删除；" +
                          "清空后「跳过已下载」会重新下载这些内容。",
                PrimaryButtonText = "清空",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var n = DownloadLedger.Instance.Stats().Count;
            DownloadLedger.Instance.Clear();
            ledgerStatus.Text = $"已清空 {n} 条台账记录。";
        };
        ledgerPanel.Children.Add(clearLedger);
        ledgerPanel.Children.Add(ledgerStatus);
        panel.Children.Add(SettingRows.Card("下载台账", "跨模块共用的已下载记录", ledgerPanel));

        return panel;
    }

    private static void OpenInExplorer(string path)
    {
        try
        {
            if (!Directory.Exists(path)) Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
        }
        catch
        {
            // 打不开资源管理器不该让页面崩
        }
    }

    // ── 关于 ────────────────────────────────────────────────

    private UIElement BuildAbout()
    {
        var panel = new StackPanel { Spacing = 16 };

        var version = typeof(SettingsPage).Assembly.GetName().Version?.ToString() ?? "未知";
        var info = new StackPanel { Spacing = 6 };
        info.Children.Add(new TextBlock { Text = "parse-dl · WinUI 3 版", FontSize = 14, FontWeight = FontWeights.SemiBold });
        info.Children.Add(SettingRows.Description("版本 " + version));
        info.Children.Add(SettingRows.Description(
            "下载解析工具：X / 抖音 / B 站三个模块各自独立设置，共用同一个 aria2 下载引擎。"));
        var openAbout = new Button { Content = "打开完整关于页" };
        openAbout.Click += (_, _) => _host?.Navigate("about");
        info.Children.Add(openAbout);
        panel.Children.Add(SettingRows.Card("关于", "版本与许可", info));

        return panel;
    }

    /// <summary>
    /// 往 ContentRoot（Grid）里加一行。ContentRoot 用 Grid 而不是 StackPanel，
    /// 是为了让卡片能撑满 MaxWidth —— 竖直 StackPanel 的宽度由最宽子元素决定，
    /// 会和卡片的 Stretch 互相等待，最终整列收缩到内容宽度（实测只有 476px）。
    /// </summary>
    private void AddRow(UIElement child)
    {
        var row = ContentRoot.RowDefinitions.Count;
        ContentRoot.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        if (child is FrameworkElement fe)
        {
            Grid.SetRow(fe, row);
            // **显式设宽度**（2026-10-26 实测，第 5 次才定案）：
            // SettingRows.Card 内部是 StackPanel，而 StackPanel 的宽度 = 最宽子元素宽度；
            // 它作为 Grid 的 Auto 行子元素时，父级不给它定宽，于是整条链一路按内容宽收缩
            // （实测卡片 476px，可用宽 1223）。所有 HorizontalAlignment 写法都救不了。
            // 唯一可靠做法：直接把宽度数值写死到子元素上。
            fe.HorizontalAlignment = HorizontalAlignment.Stretch;
            fe.Width = _contentWidth;
        }
        ContentRoot.Children.Add(child);
    }
}
