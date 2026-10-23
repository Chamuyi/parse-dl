using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;

namespace ParseDl.Pages;

/// <summary>
/// 下载管理 —— X / 抖音 / B 站三页共用（Flutter 版是同一组件传 feed 参数）。
/// 数据来自真实的 aria2 队列（DownloadStore），不是假数据。
/// </summary>
public sealed partial class DownloadsPage : Page
{
    private string _module = "X 媒体";
    private readonly List<string> _filters = new() { "全部", "下载中", "等待中", "已暂停", "错误", "已完成" };
    private string _filter = "全部";
    private StackPanel? _tabPanel;
    private StackPanel? _listPanel;
    private StackPanel? _ledgerPanel;
    private TextBlock? _emptyHint;

    public DownloadsPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is string module) _module = module;
        Build();
        _ = RefreshAsync();
    }

    private void Build()
    {
        Root.Children.Clear();
        Root.Children.Add(UiKit.PageHeader("下载管理", _module, "\uE896"));

        // Tab 条：自己一张卡，宽度按内容（照抄 Flutter 版的 .tabs2.card）
        _tabPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        Root.Children.Add(new Border
        {
            Background = UiKit.CardBackground,
            BorderBrush = UiKit.CardBorder,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6, 4, 6, 4),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = _tabPanel,
        });

        // 任务列表
        _listPanel = new StackPanel { Spacing = 8 };
        _emptyHint = new TextBlock
        {
            Text = "还没有下载任务。到「解析下载」页粘贴 http/https 直链即可加入队列。",
            FontSize = 13,
            Opacity = 0.6,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 16, 0, 16),
        };
        _listPanel.Children.Add(_emptyHint);
        Root.Children.Add(UiKit.SectionCard("任务", _listPanel, "每 0.8 秒自动刷新"));

        // 底部操作
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 4, 0, 0) };
        var clearBtn = new Button { Content = "清除已完成", MinWidth = 110 };
        clearBtn.Click += async (_, _) =>
        {
            await DownloadStore.Instance.ClearCompletedAsync();
            await RefreshAsync();
        };
        actions.Children.Add(clearBtn);

        var openBtn = new Button { Content = "打开下载目录", MinWidth = 120 };
        openBtn.Click += (_, _) =>
        {
            try
            {
                var dir = Aria2Engine.DefaultDir();
                System.IO.Directory.CreateDirectory(dir);
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = dir,
                    UseShellExecute = true,
                });
            }
            catch { }
        };
        actions.Children.Add(openBtn);

        var clearLedgerBtn = new Button { Content = "清空历史台账", MinWidth = 120 };
        clearLedgerBtn.Click += async (_, _) =>
        {
            DownloadLedger.Instance.Clear();
            await RefreshAsync();
        };
        actions.Children.Add(clearLedgerBtn);

        // 合并音视频 —— B站 dash 是分离流，下完必须合，否则只有画面没声音。
        var mergeBtn = new Button { Content = "合并音视频", MinWidth = 110 };
        mergeBtn.Click += async (_, _) =>
        {
            var dir = Aria2Engine.DefaultDir();
            var pairs = MediaMerger.FindPairs(dir);
            if (pairs.Count == 0)
            {
                await ShowInfoAsync("没有找到可合并的配对（需要同名的视频 + 音频文件）");
                return;
            }

            var okCount = 0; var failCount = 0; var lastErr = "";
            foreach (var (video, audio, output) in pairs)
            {
                var r = await MediaMerger.MergeAsync(video, audio, output);
                if (r.Ok) okCount++; else { failCount++; lastErr = r.Message; }
            }
            await ShowInfoAsync(failCount == 0
                ? ("合并完成 " + okCount + " 个")
                : ("合并完成 " + okCount + " 个，失败 " + failCount + " 个。最后错误：" + lastErr));
        };
        actions.Children.Add(mergeBtn);

        Root.Children.Add(actions);

        // 历史台账：aria2 的会话重启后是空的，用户要能看到「之前下过什么」。
        // 数据来自 DownloadLedger（落盘 download_ledger.json）。
        _ledgerPanel = new StackPanel { Spacing = 6 };
        Root.Children.Add(UiKit.SectionCard("历史台账", _ledgerPanel, "来自 download_ledger.json"));

        RebuildTabs();
    }

    private void RebuildTabs()
    {
        if (_tabPanel is null) return;
        _tabPanel.Children.Clear();
        var items = DownloadStore.Instance.Items.Where(MatchesModule).ToList();
        foreach (var f in _filters)
        {
            var count = f == "全部" ? items.Count : items.Count(i => i.StatusText == f);
            var isActive = f == _filter;
            var btn = new Button
            {
                Content = count > 0 ? $"{f} {count}" : f,
                Padding = new Thickness(12, 6, 12, 6),
                Background = isActive ? UiKit.AccentFill : UiKit.SubtleFill,
                Foreground = isActive ? UiKit.OnAccentText : null,
                BorderThickness = new Thickness(0),
                CornerRadius = new CornerRadius(6),
            };
            var captured = f;
            btn.Click += async (_, _) =>
            {
                _filter = captured;
                RebuildTabs();
                await RefreshAsync();
            };
            _tabPanel.Children.Add(btn);
        }
    }

    private bool MatchesModule(DownloadItem i) => i.Module == _module;

    private async System.Threading.Tasks.Task RefreshAsync()
    {
        await DownloadStore.Instance.RefreshOnceAsync();
        if (_listPanel is null) return;

        var items = DownloadStore.Instance.Items.Where(MatchesModule).ToList();
        if (_filter != "全部") items = items.Where(i => i.StatusText == _filter).ToList();

        _listPanel.Children.Clear();
        if (items.Count == 0)
        {
            _listPanel.Children.Add(_emptyHint!);
            return;
        }

        foreach (var it in items)
        {
            _listPanel.Children.Add(BuildRow(it));
        }

        RenderLedger();
    }

    /// <summary>渲染历史台账（只显示与当前模块相关的条目）。</summary>
    private void RenderLedger()
    {
        if (_ledgerPanel is null) return;
        _ledgerPanel.Children.Clear();

        var entries = DownloadLedger.Instance.Query(_module, 60);
        if (entries.Count == 0)
        {
            _ledgerPanel.Children.Add(new TextBlock
            {
                Text = "暂无历史记录。任务完成后会自动记入台账。",
                FontSize = 13, Opacity = 0.6, TextWrapping = TextWrapping.Wrap,
            });
            return;
        }

        foreach (var e in entries)
        {
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var left = new StackPanel { Spacing = 2 };
            left.Children.Add(new TextBlock
            {
                Text = string.IsNullOrEmpty(e.FileName) ? e.Url : e.FileName,
                FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis,
            });
            left.Children.Add(new TextBlock
            {
                Text = e.Status + "　" + DownloadItem.FormatSize(e.TotalBytes) + "　" + e.FinishedAt,
                FontSize = 12, Opacity = 0.6,
            });
            g.Children.Add(left);

            var openOne = new Button { Content = "打开位置", MinWidth = 80 };
            var dir = e.Dir;
            openOne.Click += (_, _) =>
            {
                try
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = string.IsNullOrEmpty(dir) ? Aria2Engine.DefaultDir() : dir,
                        UseShellExecute = true,
                    });
                }
                catch { }
            };
            Grid.SetColumn(openOne, 1);
            g.Children.Add(openOne);

            _ledgerPanel.Children.Add(new Border
            {
                Background = UiKit.SubtleFill,
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(10, 8, 10, 8),
                Child = g,
            });
        }
    }

    /// <summary>用 ContentDialog 报结果。批量操作必须给回执，不能静默。</summary>
    private async System.Threading.Tasks.Task ShowInfoAsync(string message)
    {
        try
        {
            var dlg = new ContentDialog
            {
                Title = "提示",
                Content = message,
                CloseButtonText = "知道了",
                XamlRoot = XamlRoot,
            };
            await dlg.ShowAsync();
        }
        catch
        {
            // XamlRoot 还没准备好时（页面未加载完）忽略，避免崩溃
        }
    }

    private UIElement BuildRow(DownloadItem item)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var texts = new StackPanel { Spacing = 4 };
        texts.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(item.FileName) ? item.Url : item.FileName,
            FontSize = 13,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });

        var bar = new ProgressBar
        {
            Value = item.Progress * 100,
            Maximum = 100,
            Height = 3,
            Margin = new Thickness(0, 2, 0, 2),
        };
        texts.Children.Add(bar);

        var meta = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        meta.Children.Add(new TextBlock { Text = item.StatusText, FontSize = 12, Opacity = 0.7 });
        meta.Children.Add(new TextBlock { Text = item.ProgressText, FontSize = 12, Opacity = 0.7 });
        if (!string.IsNullOrEmpty(item.SpeedText))
            meta.Children.Add(new TextBlock { Text = item.SpeedText, FontSize = 12, Opacity = 0.7 });
        texts.Children.Add(meta);
        grid.Children.Add(texts);

        var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        var pauseBtn = new Button
        {
            Content = item.Status == AriaStatus.Paused ? "继续" : "暂停",
            MinWidth = 60,
            IsEnabled = item.Status is AriaStatus.Active or AriaStatus.Waiting or AriaStatus.Paused,
        };
        pauseBtn.Click += async (_, _) => { await DownloadStore.Instance.PauseAsync(item); await RefreshAsync(); };
        btns.Children.Add(pauseBtn);

        var removeBtn = new Button { Content = "移除", MinWidth = 60 };
        removeBtn.Click += async (_, _) => { await DownloadStore.Instance.RemoveAsync(item); await RefreshAsync(); };
        btns.Children.Add(removeBtn);

        Grid.SetColumn(btns, 1);
        grid.Children.Add(btns);

        return new Border
        {
            Background = UiKit.SubtleFill,
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(12, 10, 12, 10),
            Child = grid,
        };
    }
}