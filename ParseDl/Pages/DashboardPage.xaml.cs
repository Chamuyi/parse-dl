using System;
using System.Linq;
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
        Loaded += (_, _) =>
        {
            Refresh();
            ApplyResponsive();
            RootScroll.SizeChanged += (_, _) => ApplyResponsive();
        };
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _host = e.Parameter as MainWindow;
    }

    private void BuildQuickEntries()
    {
        // 3 列 × 2 行：卡片按星号列宽拉伸，窗口变宽/变窄都跟着走。
        // 旧版塞进 ItemsWrapGrid + 固定宽度，右侧留白一大片，被用户当场指出。
        for (var i = 0; i < QuickEntries.Length; i++)
        {
            var (routeId, glyph, title, sub) = QuickEntries[i];
            var btn = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Padding = new Thickness(12, 10, 12, 10),
                MinHeight = 66,
                // 卡片底色必须用 ThemeResource 的 CardBackgroundFillColorDefault ——
                // ControlFillColorDefault 在浅色下几乎与页面底同色，方框「看不见」
                // 就是用户报的那一条。
                Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
                BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
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
                Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["AccentFillColorDefaultBrush"],
                Child = new FontIcon
                {
                    Glyph = glyph,
                    FontSize = 14,
                    Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextOnAccentFillColorPrimaryBrush"],
                },
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
            texts.Children.Add(new TextBlock
            {
                Text = sub,
                FontSize = 12,
                Opacity = 0.65,
                TextWrapping = TextWrapping.NoWrap,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            Grid.SetColumn(texts, 1);
            grid.Children.Add(texts);

            var chevron = new FontIcon { Glyph = "\uE76C", FontSize = 10, Opacity = 0.5, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(chevron, 2);
            grid.Children.Add(chevron);

            btn.Content = grid;
            var capturedRoute = routeId;
            btn.Click += (_, _) => _host?.Navigate(capturedRoute);

            Grid.SetRow(btn, i / 3);
            Grid.SetColumn(btn, i % 3);
            QuickGrid.Children.Add(btn);
        }
    }

    /// <summary>
    /// 自适应布局：窗口宽 &lt; 1000 时把右侧三张卡（模块状态 / 下载引擎 / 环境）
    /// 从「右栏」搬到下方并铺满整行，避免窄窗口下被挤压或截断。
    /// 用户报的「最大化后位置变了、被截断」就是固定像素列 + 不换行导致的。
    /// </summary>
    private void ApplyResponsive()
    {
        var width = RootScroll.ActualWidth;
        if (width <= 0) return;
        var narrow = width < 1000;

        if (narrow)
        {
            Grid.SetRow(RightStack, 1);
            Grid.SetColumn(RightStack, 0);
            Grid.SetColumnSpan(RightStack, 2);
            RightCol.Width = new GridLength(0);
        }
        else
        {
            Grid.SetRow(RightStack, 0);
            Grid.SetColumn(RightStack, 1);
            Grid.SetColumnSpan(RightStack, 1);
            RightCol.Width = new GridLength(340);
        }
    }

    private void Refresh()
    {
        try
        {
            DataDirText.Text = AppPaths.DataDir;

            // 统计卡接真实台账 —— 之前全是写死的 0，用户看不出下过什么。
            var (count, bytes) = DownloadLedger.Instance.Stats();
            DoneCount.Text = count.ToString();
            LedgerCount.Text = count.ToString();
            DiskUsage.Text = DownloadItem.FormatSize(bytes);

            // 进行中取当前队列里活动任务数
            var running = DownloadStore.Instance.Items.Count(i => i.Status == AriaStatus.Active);
            RunningCount.Text = running.ToString();

            DataDirText.Text = AppPaths.DataDir;
        }
        catch (Exception ex)
        {
            DataDirText.Text = "读取失败: " + ex.Message;
        }
    }
}