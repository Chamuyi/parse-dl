using System;
using System.Collections.Generic;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ParseDl.Models;
using ParseDl.Pages;
using ParseDl.Services;

namespace ParseDl;

public sealed partial class MainWindow : Window
{
    private readonly MaterialService _material;

    /// <summary>当前导航项 id（'dashboard' / 'home' / ...）。</summary>
    public string CurrentRouteId { get; private set; } = "dashboard";

    public MainWindow()
    {
        InitializeComponent();

        // 用官方 TitleBar 控件时**不要**再 SetTitleBar —— 控件自己处理拖拽区，
        // 手动 SetTitleBar 会和控件内部逻辑打架（拖不动 / 双击不最大化）。
        ExtendsContentIntoTitleBar = true;
        // 标题栏的 PaneToggle 按钮会和 NavigationView 自带的汉堡按钮**重叠**，
        // 表现为左上角两个方块（实测）。导航用 NavigationView 自己的即可。
        AppTitleBar.IsPaneToggleButtonVisible = false;
        AppTitleBar.IsBackButtonVisible = false;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon("Assets/AppIcon.ico");

        _material = new MaterialService(this);

        // 主题来源必须是 XAML 的实际主题，不是自己记的布尔值。
        // 实测教训：只传布尔值时，浅色下材质仍按深色渲染（深浅差 0）；
        // 参照物图吧也是取 root.ActualTheme（BackdropService.cs:202-204）。
        // 从设置恢复上次的明暗与材质档位
        var cfg = AppSettings.Instance;
        RootGrid.RequestedTheme = cfg.IsDark ? ElementTheme.Dark : ElementTheme.Light;
        RootGrid.ActualThemeChanged += (_, _) =>
        {
            cfg.IsDark = RootGrid.ActualTheme == ElementTheme.Dark;
            cfg.Save();
            _material.Apply(_material.Current, cfg.IsDark);
        };
        var startKind = Enum.TryParse<MaterialKind>(cfg.MaterialKind, out var mk) ? mk : MaterialKind.Mica;
        _material.Apply(startKind, cfg.IsDark);

        // 系统绘制的标题栏按钮（− □ ×）颜色**默认跟随系统主题**，不跟应用内主题。
        // 实测现象：应用切浅色但系统是深色时，按钮是白色 —— 在浅色标题栏上看不见；
        // 反之亦然。必须显式把 AppWindowTitleBar 的按钮前景/背景色对齐应用内主题。
        ApplyTitleBarColors(cfg.IsDark);
        RootGrid.ActualThemeChanged += (_, _) => ApplyTitleBarColors(RootGrid.ActualTheme == ElementTheme.Dark);

        BuildNav();
        NavFrame.Navigate(typeof(DashboardPage), this);

        Activated += (_, e) =>
            _material.UpdateState(RootGrid.ActualTheme == ElementTheme.Dark,
                                  e.WindowActivationState != WindowActivationState.Deactivated);
    }

    /// <summary>
    /// 把系统标题栏按钮的颜色对齐应用内主题。
    ///
    /// 为什么必须手动设：AppWindowTitleBar 的 ButtonForegroundColor 默认取**系统**主题，
    /// 与应用内 RootGrid.RequestedTheme 无关。用户报「浅色模式下三个按键不可分辨」
    /// 就是这个原因（应用浅色 + 系统深色 → 按钮是白字，落在浅色标题栏上）。
    ///
    /// 背景色用透明：标题栏本身要露出材质，不能盖一层实色。
    /// </summary>
    private void ApplyTitleBarColors(bool isDark)
    {
        try
        {
            var tb = AppWindow.TitleBar;
            if (tb is null) return;

            // ── 2026-10-25 重做（真机取证后的结论）──────────────────────
            //
            // 用户报的两个现象在这里一次说清：
            //
            // (1)「浅色下三键不可辨」根因不在配色，而在**主题没生效**：
            //     AppPaths 原来把数据目录指到包安装目录（AppX\userdata），
            //     AppContainer 写不进 settings.json，于是「切浅色 → 重启 → 又是深色」。
            //     用户那张截图里标题栏其实是浅色的（因为当次运行切成功了），
            //     但按钮前景仍是系统深色主题的白 —— 两个主题打架。
            //     现在 AppPaths 落在包容器 LocalState，IsDark 能持久化，
            //     且下面的颜色**跟随应用内主题**而不是系统主题。
            //
            // (2)「hover 是黑块、没有图标」根因是**透明度**：
            //     AppWindowTitleBar 的 Button*BackgroundColor 只接受**不透明**
            //     颜色，我上一版传的是 alpha=20 的半透明黑，系统把 alpha 丢掉
            //     当纯黑画（截图里就是纯黑方块）；同时前景我也设成了黑，
            //     黑底黑字 → 图标消失。
            //
            // 现在的取值全部照 WinUI 官方标题栏配色（不透明，与系统一致）：
            //   浅色：hover #E6E6E6 / pressed #D2D2D2 / 前景 #1A1A1A
            //   深色：hover #323232 / pressed #1E1E1E / 前景 #FFFFFF
            //   关闭键：hover #C42B1C + 白字（Windows 11 惯例，WinUI 同样如此）
            Windows.UI.Color Rgb(byte r, byte g, byte b) => Windows.UI.Color.FromArgb(255, r, g, b);

            var fg = isDark ? Rgb(0xFF, 0xFF, 0xFF) : Rgb(0x1A, 0x1A, 0x1A);
            var fgInactive = isDark ? Rgb(0x9A, 0x9A, 0x9A) : Rgb(0x8A, 0x8A, 0x8A);

            var hoverBg = isDark ? Rgb(0x32, 0x32, 0x32) : Rgb(0xE6, 0xE6, 0xE6);
            var pressedBg = isDark ? Rgb(0x1E, 0x1E, 0x1E) : Rgb(0xD2, 0xD2, 0xD2);

            tb.ButtonBackgroundColor = Windows.UI.Color.FromArgb(0, 0, 0, 0);
            tb.ButtonInactiveBackgroundColor = Windows.UI.Color.FromArgb(0, 0, 0, 0);
            tb.ButtonForegroundColor = fg;
            tb.ButtonInactiveForegroundColor = fgInactive;
            tb.ButtonHoverBackgroundColor = hoverBg;
            tb.ButtonHoverForegroundColor = fg;
            tb.ButtonPressedBackgroundColor = pressedBg;
            tb.ButtonPressedForegroundColor = fg;

        }
        catch
        {
            // 非 Win11 或旧系统上这些 API 可能不可用，忽略即可
        }
    }

    /// <summary>供设置页切换材质。</summary>
    public bool ApplyMaterial(MaterialKind kind, bool isDark)
    {
        var ok = _material.Apply(kind, isDark);
        if (ok)
        {
            AppSettings.Instance.MaterialKind = kind.ToString();
            AppSettings.Instance.IsDark = isDark;
            AppSettings.Instance.Save();
        }
        return ok;
    }

    public MaterialKind CurrentMaterial => _material.Current;

    /// <summary>切换界面明暗。改 RequestedTheme 后由 ActualThemeChanged 带着
    /// 真实主题重挂材质，避免"界面变了材质没变"。</summary>
    public void ApplyTheme(bool isDark) =>
        RootGrid.RequestedTheme = isDark ? ElementTheme.Dark : ElementTheme.Light;

    public bool IsDarkTheme => _material.IsDark;

    private void BuildNav()
    {
        var menu = NavView.MenuItems;

        foreach (var item in NavModel.Primary)
        {
            menu.Add(CreateItem(item));
        }

        foreach (var group in NavModel.Groups)
        {
            var parent = new NavigationViewItem
            {
                Content = group.Label,
                Tag = group.Id,
                SelectsOnInvoked = false,
            };
            parent.Icon = new FontIcon { Glyph = group.Glyph };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(parent, "group-" + group.Id);
            foreach (var child in group.Children)
            {
                parent.MenuItems.Add(CreateItem(child));
            }
            menu.Add(parent);
        }

        foreach (var item in NavModel.Standalone)
        {
            menu.Add(CreateItem(item));
        }

        // 默认选中总览
        if (menu[0] is NavigationViewItem first)
        {
            NavView.SelectedItem = first;
        }
    }

    private static NavigationViewItem CreateItem(NavItem item)
    {
        var nvi = new NavigationViewItem
        {
            Content = item.Label,
            Tag = item.Id,
        };
        nvi.Icon = new FontIcon { Glyph = item.Glyph };
        // 三个模块里都有「解析下载」「下载管理」，UIA 按名字匹配会点到第一个。
        // 用 Tag 做自动化名称（Tag 是唯一的），既不影响显示文字，又能被精确定位。
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(nvi, item.Id);
        return nvi;
    }

    /// <summary>标题栏的汉堡按钮：切换 NavigationView 侧栏展开/收起。</summary>
    private void TitleBar_PaneToggleRequested(TitleBar sender, object args)
    {
        NavView.IsPaneOpen = !NavView.IsPaneOpen;
    }

    private void NavView_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item) return;
        if (item.Tag is not string routeId) return;
        Navigate(routeId);
    }

    /// <summary>页面内跳转（总览页的快捷卡用它）。</summary>
    public void Navigate(string routeId)
    {
        if (routeId == CurrentRouteId && NavFrame.Content is not null) return;
        CurrentRouteId = routeId;
        BreadcrumbText.Text = LabelOf(routeId);

        switch (routeId)
        {
            case "dashboard":
                NavFrame.Navigate(typeof(DashboardPage), this);
                break;

            case "settings":
                NavFrame.Navigate(typeof(SettingsPage), this);
                break;

            case "about":
                NavFrame.Navigate(typeof(AboutPage), this);
                break;

            // X 主页：**不再用 WebView**（用户 2026-10-24 需求第③条）。
            // 走 Flutter 原项目 homepage_page.dart 的形态：输入用户 → 解析作品
            // 列表 → 勾选 → 按模板入队。抖音解析仍走 BrowsePage（它确实要靠内嵌
            // 浏览器做滚动抓取）。
            case "home":
                NavFrame.Navigate(typeof(XHomePage), this);
                break;
            case "douyin":
                NavFrame.Navigate(typeof(DouyinParsePage), this);
                break;
            case "bili":
                // 用户 2026-10-25 需求：B 站解析要像原项目一样「左浏览、右抓取」，
                // 所以走 BiliPage（内嵌 WebView2），不再用纯表单的 ParsePage。
                NavFrame.Navigate(typeof(BiliPage), this);
                break;
            case "bili-batch":
                NavFrame.Navigate(typeof(BiliBatchPage), this);
                break;

            // 三个模块的下载管理页共用 DownloadsPage，但形态按模块分家
            // （DownloadFeed 提供各自的 Tab 集合/空态/历史标题/合并开关）。
            case "download-management":
                NavFrame.Navigate(typeof(DownloadsPage), DownloadModuleKind.X);
                break;
            case "douyin-downloads":
                NavFrame.Navigate(typeof(DownloadsPage), DownloadModuleKind.Douyin);
                break;
            case "bili-downloads":
                NavFrame.Navigate(typeof(DownloadsPage), DownloadModuleKind.Bili);
                break;

            case "auto-task":
                NavFrame.Navigate(typeof(AutoTaskPage), "x");
                break;
            case "douyin-auto":
                NavFrame.Navigate(typeof(DouyinAutoPage), this);
                break;

            // 三个模块各有独立设置页（内容量差得远，不能共用）
            case "x-settings":
                NavFrame.Navigate(typeof(XSettingsPage), this);
                break;
            case "douyin-settings":
                NavFrame.Navigate(typeof(DouyinSettingsPage), this);
                break;
            case "bili-settings":
                NavFrame.Navigate(typeof(BiliSettingsPage), this);
                break;

            default:
                NavFrame.Navigate(typeof(PlaceholderPage), this);
                break;
        }
    }

    private static string LabelOf(string routeId)
    {
        foreach (var item in NavModel.Primary)
            if (item.Id == routeId) return item.Label;
        foreach (var g in NavModel.Groups)
            foreach (var c in g.Children)
                if (c.Id == routeId) return c.Label;
        foreach (var item in NavModel.Standalone)
            if (item.Id == routeId) return item.Label;
        return routeId;
    }
}