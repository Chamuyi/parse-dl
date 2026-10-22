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

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon("Assets/AppIcon.ico");

        _material = new MaterialService(this);
        // 默认 Mica + 深色（与 Flutter 版默认一致：mica / system）
        _material.Apply(MaterialKind.Mica, isDark: true);

        BuildNav();
        NavFrame.Navigate(typeof(DashboardPage), this);

        Activated += (_, e) =>
            _material.UpdateState(_material.IsDark, e.WindowActivationState != WindowActivationState.Deactivated);
    }

    /// <summary>供设置页切换材质。</summary>
    public bool ApplyMaterial(MaterialKind kind, bool isDark) => _material.Apply(kind, isDark);

    public MaterialKind CurrentMaterial => _material.Current;

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

        var pageType = routeId switch
        {
            "dashboard" => typeof(DashboardPage),
            "home" or "douyin" or "bili" or "bili-batch" => typeof(PlaceholderPage),
            "download-management" or "douyin-downloads" or "bili-downloads" => typeof(PlaceholderPage),
            "auto-task" or "douyin-auto" => typeof(PlaceholderPage),
            "settings" => typeof(SettingsPage),
            "about" => typeof(AboutPage),
            _ => typeof(PlaceholderPage),
        };
        NavFrame.Navigate(pageType, this);
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
