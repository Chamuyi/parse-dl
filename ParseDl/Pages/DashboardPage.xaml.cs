using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Services;

namespace ParseDl.Pages;

/// <summary>
/// 总览页 —— 软件打开时的默认落地页。
/// 结构照 Flutter 版 lib/pages/dashboard_page.dart：页头 / 主卡片 / 4 统计 /
/// 快捷开始 6 卡 / 模块状态 / 下载引擎 / 环境 / 最近活动。
/// </summary>
public sealed partial class DashboardPage : Page
{
    private MainWindow? _host;

    /// <summary>快捷开始 6 个入口（顺序与 Flutter 版 quickEntries 一致）。</summary>
    private static readonly (string RouteId, string Glyph, string Title, string Sub)[] QuickEntries =
    {
        ("home", "\uE80F", "X 主页", "输入用户 ID 批量下载"),
        ("douyin", "\uE768", "解析抖音作品", "左边浏览，右边抓取"),
        ("bili", "\uE768", "解析 B 站稿件", "支持合集 / 系列 / 收藏夹"),
        ("auto-task", "\uE945", "自动执行", "按名单批量跑 X 用户"),
        ("bili-batch", "\uE8EF", "B 站批量", "主页 / 合集 / 收藏夹"),
        ("douyin-auto", "\uE945", "抖音自动下载", "按目标批量滚动抓取"),
    };

    public DashboardPage()
    {
        InitializeComponent();
        BuildQuickEntries();
        Loaded += (_, _) => Refresh();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _host = e.Parameter as MainWindow;
    }

    private void BuildQuickEntries()
    {
        foreach (var (routeId, glyph, title, sub) in QuickEntries)
        {
            var btn = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Padding = new Thickness(12, 10, 12, 10),
                Margin = new Thickness(0, 0, 8, 8),
                MinHeight = 66,
                Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["ControlFillColorDefaultBrush"],
                BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"],
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
            };

            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var iconBox = new Border
            {
                Width = 32,
                Height = 32,
                CornerRadius = new CornerRadius(6),
                Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["ControlFillColorSecondaryBrush"],
                Child = new FontIcon { Glyph = glyph, FontSize = 14 },
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(iconBox, 0);
            grid.Children.Add(iconBox);

            var texts = new StackPanel
            {
                Margin = new Thickness(12, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Spacing = 2,
            };
            texts.Children.Add(new TextBlock { Text = title, FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            texts.Children.Add(new TextBlock { Text = sub, FontSize = 12, Opacity = 0.65, TextTrimming = TextTrimming.CharacterEllipsis });
            Grid.SetColumn(texts, 1);
            grid.Children.Add(texts);

            var chevron = new FontIcon { Glyph = "\uE76C", FontSize = 10, Opacity = 0.5, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(chevron, 2);
            grid.Children.Add(chevron);

            btn.Content = grid;
            var capturedRoute = routeId;
            btn.Click += (_, _) => _host?.Navigate(capturedRoute);
            QuickGrid.Items.Add(btn);
        }
    }

    private void Refresh()
    {
        try
        {
            DataDirText.Text = AppPaths.DataDir;
        }
        catch (Exception ex)
        {
            DataDirText.Text = "读取失败: " + ex.Message;
        }
    }
}
