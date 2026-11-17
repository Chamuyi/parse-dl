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
/// 六个分类：外观（材质 / 明暗 / 主题色）/ 下载 / 代理 / 日志 / 数据目录 / 关于。
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

    /// <summary>
    /// **正在试色的颜色**（2026-10-30 修「实时预览不能实时」）。
    ///
    /// 色轮拖动时把颜色放这里，预览直接用它渲染 —— 但**不写盘**（拖一次会写几十次）。
    /// 点「应用自定义色」后才清空，落盘并全局生效。null 表示「预览当前已生效的色」。
    /// </summary>
    private string? _pendingAccentHex;

    /// <summary>预览控件的宿主容器（每次刷新重建里面的三个控件）。</summary>
    private StackPanel? _previewHost;

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
        "appearance" => "窗口材质 · 明暗 · 主题色",
        "download" => "保存目录 · 并发 · 模板 · 日志开关",
        "proxy" => "代理地址与系统代理",
        "logs" => "运行日志与排障",
        "data" => "设置文件与下载落点",
        _ => "版本与许可",
    };

    // ── 外观 ────────────────────────────────────────────────

    /// <summary>
    /// 材质方格的选中态描边色 —— 取当前强调色（跟明暗走）。
    ///
    /// AccentService 没有直接暴露「当前显示色」，用 Resolve 解析出当前预设的 Fill。
    /// </summary>
    private static SolidColorBrush AccentStrokeBrush(bool isDark)
    {
        var (fill, _, _, _) = AccentService.Resolve(
            AccentService.CurrentId, AccentService.CurrentCustomHex, isDark);
        return AccentService.TryParseHex(fill, out var c)
            ? new SolidColorBrush(c)
            : new SolidColorBrush(Windows.UI.Color.FromArgb(255, 30, 144, 255));   // DodgerBlue 兜底
    }

    /// <summary>
    /// 窗口材质的**方格选择板**（2026-10-30 用户要求「做成方格，点击切换」）。
    ///
    /// 每格是一张卡片：大标题（材质名）+ 一行说明；整格可点，选中格用强调色描边。
    /// 2 列自适应 —— 内容区宽度不够时自动变 1 列（由外层 StackPanel 的换行实现）。
    /// </summary>
    private UIElement BuildMaterialBoard()
    {
        var board = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var host = _host;
        var current = host?.CurrentMaterial ?? MaterialKind.Mica;

        foreach (var (kind, label, hint) in Materials)
        {
            var selected = kind == current;
            var tile = new Button
            {
                Tag = kind,
                MinWidth = 200,
                MinHeight = 64,
                Padding = new Thickness(14, 10, 14, 10),
                HorizontalContentAlignment = HorizontalAlignment.Left,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                // 选中格用强调色描边；未选中用默认卡片描边
                BorderThickness = new Thickness(selected ? 2 : 1),
                BorderBrush = selected ? AccentStrokeBrush(host?.IsDarkTheme ?? true)
                                       : (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            };
            AutomationProperties.SetName(tile, "material-" + kind);

            var inner = new StackPanel { Spacing = 3 };
            inner.Children.Add(new TextBlock { Text = label, FontSize = 14, FontWeight = FontWeights.SemiBold });
            inner.Children.Add(new TextBlock { Text = hint, FontSize = 11, Opacity = 0.6, TextWrapping = TextWrapping.Wrap });
            tile.Content = inner;

            tile.Click += OnMaterialTileClick;
            board.Children.Add(tile);
        }
        return board;
    }

    /// <summary>点材质方格 → 立即切换，然后整页重建以刷新选中描边。</summary>
    private void OnMaterialTileClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button b || b.Tag is not MaterialKind kind) return;
        if (_host is null) return;
        _host.ApplyMaterial(kind, _host.IsDarkTheme);
        // 重建外观页：选中描边要跟着挪
        RenderCategory("appearance");
    }

    private UIElement BuildAppearance()
    {
        var panel = new StackPanel { Spacing = 16 };

        // ① 窗口材质：**方格卡片，点一下直接切换**（2026-10-30 用户要求）
        //
        // 原来是四行 RadioButton + 右侧灰色说明文字，占地方又不好点。
        // 现在做成 2 列方格：每格一个大标题 + 一行说明，整格可点，选中格描边高亮。
        panel.Children.Add(SettingRows.Card("窗口材质",
            "点一下立即切换 · 四档全部由 Windows App SDK 官方合成控制器绘制",
            BuildMaterialBoard()));

        // ② 明暗 —— **三选一：跟随系统 / 深色 / 浅色**（2026-10-30 用户要求加「跟随系统」）
        var themeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var tg = "theme-" + Guid.NewGuid().ToString("N");
        var curMode = AppSettings.Instance.ThemeMode;
        var isDark = _host?.IsDarkTheme ?? AppSettings.Instance.IsDark;

        _suppressThemeEvent = true;
        foreach (var (mode, label, name) in new[]
                 {
                     ("System", "跟随系统", "theme-system"),
                     ("Dark", "深色", "theme-dark"),
                     ("Light", "浅色", "theme-light"),
                 })
        {
            var rb = new RadioButton
            {
                Content = label,
                GroupName = tg,
                Tag = mode,
                MinWidth = 100,
                IsChecked = curMode == mode,
            };
            AutomationProperties.SetName(rb, name);
            rb.Checked += OnThemeChecked;
            themeRow.Children.Add(rb);
        }
        _suppressThemeEvent = false;

        // 「跟随系统」时补一句当前实际生效的明暗，避免用户看不出到底走的哪一档
        var themeCard = new StackPanel { Spacing = 8 };
        themeCard.Children.Add(themeRow);
        if (curMode == "System")
        {
            themeCard.Children.Add(SettingRows.Description(
                "当前系统是" + (isDark ? "深色" : "浅色") + "，界面正跟随它；系统切换时会自动跟着变。"));
        }
        panel.Children.Add(SettingRows.Card("明暗", "切换后材质会带着真实主题重新应用", themeCard));

        // ③ 主题色 —— 真接逻辑：预设色板 + 自定义色轮 + 实时预览
        panel.Children.Add(BuildAccentCard());

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

        // 色轮 ↔ 十六进制框双向同步，**并且都把颜色喂给预览**（2026-10-30 修）。
        //
        // 原来这里只更新输入框文字：拖动色轮时预览纹丝不动，用户看到的「实时预览」
        // 其实只在点「应用自定义色」之后才变 —— 名不副实。
        // 现在拖动即写入 _pendingAccentHex 并刷新预览（仍然不写盘）。
        var syncing = false;
        colorPicker.ColorChanged += (s, e) =>
        {
            if (syncing || _accentHexBox is null) return;
            syncing = true;
            _accentHexBox.Text = AccentService.Hex(s.Color);
            syncing = false;
            _pendingAccentHex = AccentService.Hex(s.Color);
            RefreshAccentPreview();
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
                // 手填十六进制同样即时反馈到预览
                _pendingAccentHex = AccentService.Hex(c);
                RefreshAccentPreview();
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
            // 定稿：清掉「试色」状态，真正落盘并全局生效
            _pendingAccentHex = null;
            ApplyAccent(AccentService.CustomId, AccentService.Hex(c));
            _accentStatus!.Text = "已应用：" + AccentService.Hex(c);
        };

        custom.Children.Add(colorPicker);

        // **自定义色做成「点击展开」的卡片**（2026-10-30 用户要求）：
        // 默认收起 —— 色轮 + RGB + 十六进制占很高，展开后会把预设色板和预览都挤下去。
        // 点标题栏展开/收起，箭头跟着翻。
        var expander = new Expander
        {
            Header = new StackPanel
            {
                Spacing = 2,
                Children =
                {
                    new TextBlock { Text = "自定义色", FontSize = 14, FontWeight = FontWeights.SemiBold },
                    new TextBlock { Text = "点这里展开色轮，或直接填十六进制；点「应用自定义色」生效。", FontSize = 11, Opacity = 0.6, TextWrapping = TextWrapping.Wrap },
                },
            },
            Content = custom,
            IsExpanded = false,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Margin = new Thickness(0, 4, 0, 0),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(expander, "accent-custom-expander");
        panel.Children.Add(expander);

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
        // 点预设也意味着「放弃正在试的颜色」，否则预览会停在试色上不跟走。
        _pendingAccentHex = null;
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

        // **每次刷新重建控件**，而不是改已加载控件的 Resources（2026-10-30 实测）。
        //
        // 试过给 Button/ToggleSwitch 的 Resources 塞 AccentButtonBackground 等键：
        // 控件一旦 Loaded，模板已经把颜色固化，改 Resources 不会重新解析 ——
        // 实测只有「选中态」那个自绘 Border 变了，按钮和开关纹丝不动。
        // 重建控件最稳：新实例在挂到可视树时会重新走模板应用。
        _previewHost = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, VerticalAlignment = VerticalAlignment.Center };
        wrap.Children.Add(_previewHost);
        RebuildPreviewControls();
        return wrap;
    }

    /// <summary>按当前（或正在试的）颜色重建预览的三个控件。</summary>
    private void RebuildPreviewControls()
    {
        if (_previewHost is null) return;
        _previewHost.Children.Clear();

        var isDark = _host?.IsDarkTheme ?? AppSettings.Instance.IsDark;
        string fillHex, onAccentHex;
        if (!string.IsNullOrEmpty(_pendingAccentHex))
        {
            fillHex = _pendingAccentHex!;
            var (_, _, _, onAcc) = AccentService.Resolve(AccentService.CustomId, fillHex, isDark);
            onAccentHex = onAcc;
        }
        else
        {
            (fillHex, _, _, onAccentHex) = ResolveAccentForUi(isDark);
        }

        var hasFill = AccentService.TryParseHex(fillHex, out var fill);
        var hasOn = AccentService.TryParseHex(onAccentHex, out var onAccent);
        var fillBrush = hasFill ? new SolidColorBrush(fill) : null;
        var onBrush = hasOn ? new SolidColorBrush(onAccent) : null;

        // ① 主要按钮 —— 用显式配色，不走 AccentButtonStyle（那个读全局资源）
        var btn = new Button
        {
            Content = "主要按钮",
            Background = fillBrush,
            Foreground = onBrush,
            BorderBrush = fillBrush,
            BorderThickness = new Thickness(1),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(btn, "accent-preview-button");
        _previewButton = btn;
        _previewHost.Children.Add(btn);

        // ② 开关
        var toggleWrap = new StackPanel { Orientation = Orientation.Horizontal, Spacing = SettingRows.InlineGap, VerticalAlignment = VerticalAlignment.Center };
        toggleWrap.Children.Add(new TextBlock { Text = "开关", FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
        var toggle = new ToggleSwitch { IsOn = true, OnContent = "", OffContent = "", MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        // 开关的开态轨道是模板里的 ToggleSwitchFillOn，只能在实例资源上覆盖；
        // 新建的实例尚未加载，此时塞 Resources 是有效的。
        if (fillBrush is not null)
        {
            toggle.Resources["ToggleSwitchFillOn"] = fillBrush;
            toggle.Resources["ToggleSwitchFillOnPointerOver"] = fillBrush;
            toggle.Resources["ToggleSwitchFillOnPressed"] = fillBrush;
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, "accent-preview-toggle");
        _previewToggle = toggle;
        toggleWrap.Children.Add(toggle);
        _previewHost.Children.Add(toggleWrap);

        // ③ 选中态色块
        var chip = new Border
        {
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(12, 6, 12, 6),
            VerticalAlignment = VerticalAlignment.Center,
            Background = fillBrush,
            Child = new TextBlock { Text = "选中态", FontSize = 13, Foreground = onBrush },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(chip, "accent-preview-selected");
        _previewSelectedChip = chip;
        _previewHost.Children.Add(chip);
    }

    /// <summary>
    /// 刷新预览 —— **直接重建那三个控件**（2026-10-30 实测结论）。
    ///
    /// 走过一次弯路：给已加载的 Button/ToggleSwitch 改 `Resources` 里的
    /// `AccentButtonBackground` / `ToggleSwitchFillOn` 是**无效**的 —— 控件模板在
    /// Loaded 时已把颜色固化，事后改字典不会重新解析（实测只有自绘的 Border 变了）。
    /// 重建控件最稳：新实例挂上可视树时会重新应用模板。
    /// </summary>
    private void RefreshAccentPreview() => RebuildPreviewControls();
    /// <summary>取当前选择在指定明暗下的 (fill, secondary, tertiary, onAccent)。</summary>
    /// <remarks>
    /// 直接转调 AccentService.Resolve：公式只有服务里那一份。
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
        if (sender is not RadioButton rb || rb.Tag is not string mode) return;

        // 先落偏好（SetThemeMode 会顺带把 IsDark 解析成实际生效值）
        AppSettings.Instance.SetThemeMode(mode);
        AppSettings.Instance.Save();
        var dark = AppSettings.Instance.IsDark;

        // 改 RootGrid.RequestedTheme 而不是直接调材质：MainWindow 订阅了
        // ActualThemeChanged，会带着真实主题重新 Apply，界面与材质才一致。
        _host.ApplyTheme(dark);

        // 强调色分浅/深两套：切了明暗要**重新应用一次**，否则界面已经变浅色、
        // 强调色还停在深色那一套（浅底上的亮蓝按钮对比度会掉）。
        AccentService.Apply(AccentService.CurrentId, AppSettings.Instance.AccentHex, dark);

        // 色板与预览也跟着刷（色块取的是「该明暗下的那一档」）
        RebuildAccentBoard();
        RefreshAccentPreview();

        // 重建外观页：让「当前系统是深色/浅色」那行说明跟着更新
        RenderCategory("appearance");
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
                var (ok, msg) = FolderPickerService.VerifyWritable(folder);
                if (!ok) { status.Text = "❌ 该目录不可写：" + msg; return; }
                cfg.SaveDirBase = folder;
                cfg.Save();
                dirBox.Text = folder;
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
        // **并发固定为 1（串行下载）**（2026-10-29 用户要求「按顺序下载」）。
        dl.Children.Add(SettingRows.Card("下载顺序",
            "按推送顺序逐个下载（同时只下 1 个）",
            new TextBlock
            {
                Text = "先识别到的先下，下完再下一条 —— 顺序固定，不可调。",
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            }));
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

        // **必须与真正写日志的地方同源**（2026-10-30 修）：直接用 Aria2Engine.LogDir。
        // 不要在这里再拼一次路径 —— 拼两次就会分叉，之前就是这样导致显示的目录是空的。
        var logDir = Aria2Engine.LogDir;
        var logFile = Aria2Engine.LogFilePath;
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
        // **显示本次运行的日志文件**（2026-10-30）：每次启动新建一个、按启动时间命名，
        // 所以用户最关心的是「现在这个进程写到哪个文件」。
        info.Children.Add(SettingRows.Description("本次运行的日志文件："));
        info.Children.Add(new TextBlock
        {
            Text = Path.GetFileName(logFile),
            FontSize = 12,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        var openFile = new Button { Content = "打开本次日志" };
        openFile.Click += (_, _) =>
        {
            try { OpenInExplorer(logFile); }
            catch { OpenInExplorer(logDir); }
        };
        info.Children.Add(openFile);
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

    /// <summary>
    /// 用资源管理器打开「目录」或「文件」（2026-10-30 修「打开本次日志没反应」）。
    ///
    /// **必须区分文件和目录**：原来这里无条件 `Directory.CreateDirectory(path)`，
    /// 传进来的是文件路径时它会直接抛异常（同名文件已存在），然后被空 catch 吞掉 ——
    /// 表现就是「按钮点了完全没反应」。
    ///   · 文件：用 `explorer.exe /select,"文件"` 定位并选中它；
    ///   · 目录：不存在就建，再用 shell 打开。
    /// </summary>
    private static void OpenInExplorer(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "/select,\"" + path + "\"",
                    UseShellExecute = true,
                });
                return;
            }

            if (!Directory.Exists(path)) Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
        }
        catch (Exception ex)
        {
            // 打不开不该让页面崩，但要留下痕迹便于排查
            Aria2Engine.Log("[打开位置] 失败：" + path + " → " + ex.Message);
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
