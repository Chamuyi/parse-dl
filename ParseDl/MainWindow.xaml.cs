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
        RootGrid.RequestedTheme = ElementTheme.Dark;
        RootGrid.ActualThemeChanged += (_, _) =>
            _material.Apply(_material.Current, RootGrid.ActualTheme == ElementTheme.Dark);
        _material.Apply(MaterialKind.Mica, RootGrid.ActualTheme == ElementTheme.Dark);

        BuildNav();
        NavFrame.Navigate(typeof(DashboardPage), this);

        Activated += (_, e) =>
            _material.UpdateState(RootGrid.ActualTheme == ElementTheme.Dark,
                                  e.WindowActivationState != WindowActivationState.Deactivated);
    }

    /// <summary>供设置页切换材质。</summary>
    public bool ApplyMaterial(MaterialKind kind, bool isDark) => _material.Apply(kind, isDark);

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

            // 三个模块的解析页共用 ParsePage，靠参数区分
            case "home":
                NavFrame.Navigate(typeof(ParsePage), new ParseNavArgs(ParseKind.X, this));
                break;
            case "douyin":
                NavFrame.Navigate(typeof(ParsePage), new ParseNavArgs(ParseKind.Douyin, this));
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