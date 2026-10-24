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

            // 前景：深色主题用白，浅色主题用近黑（与 WinUI 标准一致）
            var fg = isDark
                ? Windows.UI.Color.FromArgb(255, 255, 255, 255)
                : Windows.UI.Color.FromArgb(255, 0, 0, 0);
            // hover/pressed 稍微提亮/压暗，让交互有反馈
            var hoverFg = isDark
                ? Windows.UI.Color.FromArgb(255, 255, 255, 255)
                : Windows.UI.Color.FromArgb(255, 0, 0, 0);
            var transparent = Windows.UI.Color.FromArgb(0, 0, 0, 0);
            var hoverBg = isDark
                ? Windows.UI.Color.FromArgb(30, 255, 255, 255)
                : Windows.UI.Color.FromArgb(20, 0, 0, 0);
            var pressedBg = isDark
                ? Windows.UI.Color.FromArgb(50, 255, 255, 255)
                : Windows.UI.Color.FromArgb(35, 0, 0, 0);

            tb.ButtonBackgroundColor = transparent;
            tb.ButtonInactiveBackgroundColor = transparent;
            tb.ButtonForegroundColor = fg;
            tb.ButtonInactiveForegroundColor = fg;
            tb.ButtonHoverBackgroundColor = hoverBg;
            tb.ButtonHoverForegroundColor = hoverFg;
            tb.ButtonPressedBackgroundColor = pressedBg;
            tb.ButtonPressedForegroundColor = hoverFg;
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

            // X 主页与抖音解析：自动抓取需要内嵌浏览器（公开接口拿不到数据）
            case "home":
                NavFrame.Navigate(typeof(BrowsePage), new BrowseNavArgs(BrowseKind.X, this));
                break;
            case "douyin":
                NavFrame.Navigate(typeof(BrowsePage), new BrowseNavArgs(BrowseKind.Douyin, this));
                break;
            case "bili":
            case "bili-batch":
                NavFrame.Navigate(typeof(ParsePage), new ParseNavArgs(ParseKind.Bili, this));
                break;

            // 三个模块的下载管理页共用 DownloadsPage
            case "download-management":
                NavFrame.Navigate(typeof(DownloadsPage), "X 媒体");
                break;
            case "douyin-downloads":
                NavFrame.Navigate(typeof(DownloadsPage), "抖音");
                break;
            case "bili-downloads":
                NavFrame.Navigate(typeof(DownloadsPage), "B 站");
                break;

            // 自动执行 / 自动下载 共用 AutoTaskPage
            case "auto-task":
                NavFrame.Navigate(typeof(AutoTaskPage), "x");
                break;
            case "douyin-auto":
                NavFrame.Navigate(typeof(AutoTaskPage), "douyin");
                break;

            // 三个模块设置页共用 ModuleSettingsPage
            case "x-settings":
                NavFrame.Navigate(typeof(ModuleSettingsPage), ModuleKind.X);
                break;
            case "douyin-settings":
                NavFrame.Navigate(typeof(ModuleSettingsPage), ModuleKind.Douyin);
                break;
            case "bili-settings":
                NavFrame.Navigate(typeof(ModuleSettingsPage), ModuleKind.Bili);
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