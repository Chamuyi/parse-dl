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

    /// <summary>
    /// 快捷开始 6 个入口。**顺序按模块成对排列**（2026-10-30 修）——
    /// 每列上下两个是同一个模块的入口，不再是按行铺导致跨模块错位。
    ///
    /// 列0 = X（主页 / 自动执行）、列1 = 抖音（解析 / 自动下载）、列2 = B站（解析 / 批量）。
    /// </summary>
    private static readonly (string RouteId, string Glyph, string Title, string Sub)[] QuickEntries =
    {
        // 列 0：X
        ("home", "\uE80F", "X 主页", "输入用户 ID 批量下载"),
        ("auto-task", "\uE945", "自动执行", "按名单批量跑 X 用户"),
        // 列 1：抖音
        ("douyin", "\uE768", "解析抖音作品", "左边浏览，右边抓取"),
        ("douyin-auto", "\uE945", "抖音自动下载", "按目标批量滚动抓取"),
        // 列 2：B站
        ("bili", "\uE768", "解析 B 站稿件", "支持合集 / 系列 / 收藏夹"),
        ("bili-batch", "\uE8EF", "B 站批量", "主页 / 合集 / 收藏夹"),
    };

    private DispatcherTimer? _diskTimer;

    public DashboardPage()
    {
        InitializeComponent();
        BuildQuickEntries();
        Loaded += (_, _) =>
        {
            Refresh();
            ApplyResponsive();
            RootScroll.SizeChanged += (_, _) => ApplyResponsive();
            StartDiskTicker();
        };
        Unloaded += (_, _) => StopDiskTicker();
    }

    /// <summary>
    /// **磁盘占用实时刷新**（2026-10-31 用户要求）。
    ///
    /// 为什么需要：DiskUsageLedger 只在下载完成时累加并写盘，
    /// **不会通知界面**。而总览页只有 Loaded 一次 Refresh，
    /// 于是停在总览页看着数字不动（必须切走再切回才变）。
    /// 这里每 2 秒读一次累加值，数字会随下载往上涨。
    /// </summary>
    private void StartDiskTicker()
    {
        if (_diskTimer is not null) return;
        _diskTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _diskTimer.Tick += (_, _) =>
        {
            try
            {
                var b = DiskUsageLedger.TotalBytes;
                if (b > 0) DiskUsage.Text = DownloadItem.FormatSize(b);

                // 「累计下载」也一并跟着走：抖音作品数在下载过程中也会增。
                var total = 0;
                try { var dy = ParseDl.Services.Douyin.DouyinStore.Instance.Ledger; dy.Load(); total += dy.DoneCount; } catch { }
                try { var bl = ParseDl.Services.Bili.BiliLedger.Instance; bl.Load(); total += bl.DoneCount; } catch { }
                try { total += ParseDl.Services.X.XLedger.Count; } catch { }
                LedgerCount.Text = total.ToString();
            }
            catch { }
        };
        _diskTimer.Start();
    }

    private void StopDiskTicker()
    {
        _diskTimer?.Stop();
        _diskTimer = null;
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

            // **按列填充**（2026-10-30 修）：每列上下是同一模块的两个入口。
            Grid.SetColumn(btn, i / 2);
            Grid.SetRow(btn, i % 2);
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
            // 窄窗：右栏整块下移到第 2 行（第 1 行留给「最近活动」）。
            // RowSpan 必须显式归 1 —— 宽窗时它是 2（跨「快捷开始」+「最近活动」两行），
            // 不归位的话右栏会跨到第 2 行上与「最近活动」**重叠**（实测出现过文字叠字）。
            Grid.SetRow(RightStack, 2);
            Grid.SetColumn(RightStack, 0);
            Grid.SetColumnSpan(RightStack, 2);
            Grid.SetRowSpan(RightStack, 1);
            RightCol.Width = new GridLength(0);
        }
        else
        {
            Grid.SetRow(RightStack, 0);
            Grid.SetColumn(RightStack, 1);
            Grid.SetColumnSpan(RightStack, 1);
            // 宽窗：右栏跨「快捷开始」+「最近活动」两行，把左下方那块空白吃掉。
            Grid.SetRowSpan(RightStack, 2);
            RightCol.Width = new GridLength(340);
        }
    }

    /// <summary>
    /// 填「最近活动」—— 取台账里最近的几条（2026-10-30 修）。
    ///
    /// 原来这块 XAML 里写死一行「还没有下载任务」，从来没接过数据，
    /// 所以台账里已经有上百条记录、这里也永远显示空的。
    /// 现在直接读 <see cref="DownloadLedger.Query"/>（最近在前），最多 6 条。
    /// </summary>
    private void RefreshRecentActivity()
    {
        if (RecentActivityHost is null) return;
        RecentActivityHost.Children.Clear();

        IReadOnlyList<DownloadLedger.LedgerEntry> recent;
        try { recent = DownloadLedger.Instance.Query(null, 6); }
        catch { recent = Array.Empty<DownloadLedger.LedgerEntry>(); }

        if (recent.Count == 0)
        {
            RecentActivityHost.Children.Add(new TextBlock
            {
                Text = "还没有下载任务",
                FontSize = 13,
                Opacity = 0.6,
                Margin = new Thickness(0, 8, 0, 8),
            });
            return;
        }

        foreach (var e in recent)
        {
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var left = new StackPanel { Spacing = 2 };
            left.Children.Add(new TextBlock
            {
                Text = string.IsNullOrEmpty(e.FileName) ? e.Url : e.FileName,
                FontSize = 13,
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.NoWrap,
            });
            left.Children.Add(new TextBlock
            {
                // 模块 · 状态 · 大小 · 时间
                Text = (string.IsNullOrEmpty(e.Module) ? "下载" : e.Module)
                     + " · " + e.Status
                     + (e.TotalBytes > 0 ? " · " + DownloadItem.FormatSize(e.TotalBytes) : "")
                     + (string.IsNullOrEmpty(e.FinishedAt) ? "" : " · " + e.FinishedAt),
                FontSize = 11,
                Opacity = 0.55,
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.NoWrap,
            });
            row.Children.Add(left);

            var ok = e.Status == "已完成";
            var badge = new FontIcon
            {
                Glyph = ok ? "\uE73E" : "\uEA39",
                FontSize = 14,
                Opacity = 0.75,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(badge, 1);
            row.Children.Add(badge);

            RecentActivityHost.Children.Add(row);
        }
    }

    private void Refresh()
    {
        try
        {
            // **首次进总览页时按磁盘回填历史**（2026-10-30）：台账钩子长期失效，
            // 历史下过的文件一条都没记上，「累计下载」永远 0。回填幂等，重复调用不重复记。
            try { DownloadLedger.Instance.BackfillFromDisk(); } catch { }

            DataDirText.Text = AppPaths.DataDir;
            // **「本次完成」和「累计下载」必须是两个不同的数**（2026-10-30 修）：
            // 原来两张卡都赋台账的 done 数，永远显示同一个值，用户看成是重复卡。
            //   本次完成 = 当前下载列表里已完成的数量（重启归零，反映这一趟跑了多少）
            //   累计下载 = 台账里的历史累计（跨重启不清零，反映一共下过多少）
            var running = DownloadStore.Instance.Items.Count(i => i.Status == AriaStatus.Active);
            var doneNow = DownloadStore.Instance.Items.Count(i => i.Status == AriaStatus.Complete);
            RunningCount.Text = running.ToString();
            DoneCount.Text = doneNow.ToString();

            // **全部已下载 = 三模块台账合计**（2026-10-31）。
            // 三份台账格式不同，必须各自读：
            //   · 抖音 douyin_downloaded.json（按作品）
            //   · B 站 bili_downloaded.json（按分 P）
            //   · X    x_downloaded.json（专用计数器，因为 download_ledger 上限 2000 会把它挤没）
            var (_, ledgerBytes) = DownloadLedger.Instance.Stats();
            var total = 0;
            try
            {
                var dy = ParseDl.Services.Douyin.DouyinStore.Instance.Ledger;
                dy.Load();
                total += dy.DoneCount;
            }
            catch { }
            try
            {
                var bili = ParseDl.Services.Bili.BiliLedger.Instance;
                bili.Load();
                total += bili.DoneCount;
            }
            catch { }
            try { total += ParseDl.Services.X.XLedger.Count; } catch { }
            LedgerCount.Text = total.ToString();

            // **磁盘占用 = 累加器，不扫盘**（2026-10-31）
            var diskBytes = DiskUsageLedger.TotalBytes;
            if (diskBytes <= 0) diskBytes = ledgerBytes;   // 没累加过就退回台账里的字节数
            DiskUsage.Text = DownloadItem.FormatSize(diskBytes);

            RefreshRecentActivity();

            DataDirText.Text = AppPaths.DataDir;
        }
        catch (Exception ex)
        {
            DataDirText.Text = "读取失败: " + ex.Message;
        }
    }
}