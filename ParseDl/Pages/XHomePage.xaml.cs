using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.X;

namespace ParseDl.Pages;

/// <summary>
/// X 主页 —— 输入用户名 / ID / 主页链接 → 加载用户与作品列表 → 勾选后入队下载。
///
/// **这一页没有 WebView**：数据全部由 <see cref="XHomeApi"/> 通过 GraphQL /
/// REST 请求取回，形态与 Flutter 版 lib/pages/homepage_page.dart 一致。
/// （旧的 BrowsePage 是 WebView2 抓取页，留给抖音抓取用，不在这里。）
/// </summary>
public sealed partial class XHomePage : Page
{
    private const int AutoFillMaxPages = 12;
    private const string ModuleName = "X 媒体";

    // **用进程级单例**（2026-10-28）：原来 `new()` 是页面实例字段，
    // 切页返回后页面重建 → 已加载作品与勾选全丢，用户要重新输入用户名重新加载。
    private readonly XHomeStore _store = XHomeStore.Instance;
    private readonly List<TileRef> _tiles = new();

    private MainWindow? _host;
    private XHomeApi? _api;

    private TextBox? _input;
    private Button? _loadButton;
    private TextBlock? _status;

    private StackPanel? _resultHost;
    private Grid? _grid;

    private Button? _downloadButton;
    private Button? _selectAllButton;
    private TextBlock? _downloadStatus;
    private TextBlock? _selectionText;

    private bool _busy;
    private int _autoFillCount;

    /// <summary>网格里一张作品卡的三个可更新部件（勾选时只改这三处，不整页重建）。</summary>
    private sealed record TileRef(string PostId, Border Card, Border Mark);

    public XHomePage() { InitializeComponent(); }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is MainWindow host) _host = host;
        Build();

        // 内容宽度 = min(视口宽度, 1200)：宽窗居中、窄窗占满（同自动执行页做法）
        PageScroll.SizeChanged += (_, _) => SyncRootWidth();
        SyncRootWidth();
    }

    /// <summary>把根面板宽度夹到「可用宽度上限 1200」（可用宽度 = 视口 − ScrollViewer 的左右内边距）。</summary>
    private void SyncRootWidth()
    {
        var vw = PageScroll.ViewportWidth;
        if (vw <= 0) return;
        var pad = PageScroll.Padding.Left + PageScroll.Padding.Right;
        Root.Width = Math.Min(1200, Math.Max(0, vw - pad));
    }

    // ── 界面骨架 ──────────────────────────────────────────────

    private void Build()
    {
        Root.Children.Clear();

        Root.Children.Add(UiKit.PageHeader("X 主页", "下载某个 X 用户的全部媒体", "\uE80F"));
        Root.Children.Add(BuildHero());
        Root.Children.Add(BuildSearchCard());

        _resultHost = new StackPanel { Spacing = 14 };
        Root.Children.Add(_resultHost);

        Root.Children.Add(BuildNotesCard());

        PageScroll.ViewChanged += (_, _) => LoadMoreIfNearBottom();
        RebuildApi();

        // **把 store 里已有的状态回填到重建后的界面**（2026-10-28）。
        // store 现在是进程级单例，切走再回来数据还在，但 Build() 会重建控件 ——
        // 不回填的话界面一片空白，用户以为被重置了（正是反馈的现象：
        // 「从主页点到其他页面返回，这页就被重置了」）。
        RestoreFromStore();
    }

    /// <summary>
    /// 用单例 store 里已有的状态把界面填回去（切页返回时调用）。
    /// 只在确实加载过东西时才动界面，避免首次进入时把占位文案冲掉。
    /// </summary>
    private void RestoreFromStore()
    {
        if (_input is not null && _store.User is not null)
        {
            _input.Text = string.IsNullOrEmpty(_store.User.ScreenName)
                ? (_store.User.Name ?? "")
                : _store.User.ScreenName;
        }

        if (_store.Posts.Count == 0) return;

        RenderResults();
        SetStatus("已加载 " + _store.Posts.Count + " 条作品 · " + _store.TotalMedia + " 个媒体"
                  + (_store.HasMore ? "（可继续加载）" : "（已到底）"));
        UpdateDownloadCard();
    }

    private UIElement BuildHero()
    {
        var stack = new StackPanel { Spacing = 10 };

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 12,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(new Border
        {
            Width = 36,
            Height = 36,
            CornerRadius = new CornerRadius(8),
            Background = UiKit.AccentFill,
            Child = new TextBlock
            {
                Text = "X",
                FontSize = 16,
                FontWeight = FontWeights.SemiBold,
                Foreground = UiKit.OnAccentText,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        });
        row.Children.Add(new TextBlock
        {
            Text = "下载某个 X 用户的全部媒体",
            FontSize = 20,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        stack.Children.Add(row);
        stack.Children.Add(new TextBlock
        {
            Text = "输入用户 ID，加载后开始批量下载图片与视频",
            FontSize = 13,
            Opacity = 0.7,
        });

        return UiKit.Card(stack, 20);
    }

    private UIElement BuildSearchCard()
    {
        var stack = new StackPanel { Spacing = 10 };

        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _input = new TextBox
        {
            PlaceholderText = "请输入 X 用户名 / ID / 主页链接，如 nasa 或 https://x.com/nasa",
            Height = 36,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        _input.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) _ = LoadAsync();
        };
        Grid.SetColumn(_input, 0);
        row.Children.Add(_input);

        _loadButton = new Button
        {
            Content = "加载",
            Height = 36,
            MinWidth = 96,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        _loadButton.Click += async (_, _) => await LoadAsync();
        Grid.SetColumn(_loadButton, 1);
        row.Children.Add(_loadButton);

        stack.Children.Add(row);

        _status = new TextBlock
        {
            Text = "",
            FontSize = 12,
            Opacity = 0.75,
            TextWrapping = TextWrapping.Wrap,
        };
        stack.Children.Add(_status);

        return UiKit.SectionCard("加载 X 用户", stack);
    }

    private UIElement BuildNotesCard()
    {
        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(Bullet("本页不内嵌浏览器：用户与作品数据由 X 的 GraphQL / REST 接口取回"));
        stack.Children.Add(Bullet("需要登录：登录入口只在「X 下载设置 → 账号」，本页不放登录 UI"));
        stack.Children.Add(Bullet("勾选作品后点「下载所选」只下勾中的；不勾选则下载全部已加载作品"));
        stack.Children.Add(Bullet("文件名按「X 下载设置 → 文件名模板」生成，模块固定记为「X 媒体」"));
        stack.Children.Add(Bullet("已下载过的媒体按「X 下载设置 → 跳过已下载」自动跳过"));
        stack.Children.Add(Bullet("X 翻到末尾时接口只回游标不出内容 —— 连续两页无媒体即自动收工"));

        var testBtn = new Button
        {
            Content = "运行离线自测",
            MinWidth = 120,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 6, 0, 0),
        };
        testBtn.Click += async (_, _) => await RunSelfTestAsync();
        stack.Children.Add(testBtn);

        return UiKit.SectionCard("能力说明", stack);
    }

    private static UIElement Bullet(string text)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new TextBlock { Text = "•", FontSize = 13, Opacity = 0.6 });
        row.Children.Add(new TextBlock
        {
            Text = text,
            FontSize = 13,
            Opacity = 0.85,
            TextWrapping = TextWrapping.Wrap,
        });
        return row;
    }

    // ── 登录态 ────────────────────────────────────────────────

    private void RebuildApi()
    {
        _api = new XHomeApi(AppSettings.Instance.ForModule("x").EffectiveCookie);
    }

    private void SetStatus(string text)
    {
        if (_status is not null) _status.Text = text;
    }

    // ── 加载 ─────────────────────────────────────────────────

    private async Task LoadAsync()
    {
        if (_busy) return;
        var raw = _input?.Text?.Trim() ?? "";
        if (raw.Length == 0)
        {
            SetStatus("请输入 X 用户名 / ID / 主页链接");
            return;
        }

        RebuildApi();
        if (_api?.HasLogin != true)
        {
            // 本页不放登录 UI（与原项目 homepage_page.dart 一致）：未登录时点加载只提示去设置页。
            // 文案照抄原项目 homepage_page.dart:122 的 toast。
            SetStatus("请先在「设置」中登录 X 账号");
            return;
        }

        _busy = true;
        _autoFillCount = 0;
        if (_loadButton is not null) _loadButton.IsEnabled = false;
        SetStatus("正在加载用户…");
        _store.Clear();
        RenderResults();

        try
        {
            var user = await _api.GetUserAsync(raw);
            _store.SetUser(user);
            RenderResults();
            SetStatus("已加载 " + user.DisplayName
                      + (string.IsNullOrEmpty(user.ScreenName) ? "" : "（@" + user.ScreenName + "）"));

            if (string.IsNullOrEmpty(user.Id))
            {
                SetStatus("接口没返回用户 ID，无法加载作品列表");
                return;
            }
            // **不能调 LoadMoreAsync**（2026-10-28 修）：它开头有 `if (... || _busy) return;`，
            // 而这里 _busy 正是 true —— 调用被静默吞掉，一页都不加载。
            // 表现：显示「共 68 个媒体」但作品列表 0 条，必须用户自己点「加载更多」。
            // 首次加载**只拉一页**（用户 2026-10-28：「默认在作品列表加载几个，
            // 不用全部加载出来，想看的话自己点加载更多，但是下载必须全部」）。
            // 所以这里不自动补全剩余页 —— 想看全部由用户点「加载更多」，
            // 或由「开始下载」在入队前自动拉全（见 StartDownloadAsync）。
            await LoadOnePageLockedAsync();
        }
        catch (Exception ex)
        {
            SetStatus(XHomeApi.MapError(ex));
        }
        finally
        {
            _busy = false;
            if (_loadButton is not null) _loadButton.IsEnabled = true;
            UpdateDownloadCard();
        }
    }

    private async Task LoadMoreAsync()
    {
        if (_api is null || _store.LoadingMore || _busy) return;
        await LoadOnePageLockedAsync();
    }

    /// <summary>
    /// 拉一页并渲染。**不检查 _busy** —— 供首次加载复用（那时 _busy 必然是 true）。
    /// 并发保护只靠 <c>_store.LoadingMore</c>，够用：它包住整个拉取+渲染过程。
    /// </summary>
    private async Task LoadOnePageLockedAsync()
    {
        if (_api is null || _store.LoadingMore) return;
        var userId = _store.User?.Id;
        if (string.IsNullOrEmpty(userId) || !_store.HasMore) return;

        _store.LoadingMore = true;
        UpdateDownloadCard();

        try
        {
            var cursor = _store.NextCursor;
            var page = await _api.GetMediasAsync(userId, cursor);
            _store.Append(page, cursor);

            RenderResults();
            SetStatus(_store.Posts.Count == 0
                ? "该用户暂无媒体（或登录态已失效）"
                : "已加载 " + _store.Posts.Count + " 条作品 · " + _store.TotalMedia + " 个媒体"
                  + (_store.HasMore ? "（可继续加载）" : "（已到底）"));
            AutoFillIfNeeded();
        }
        catch (Exception ex)
        {
            SetStatus(XHomeApi.MapError(ex));
        }
        finally
        {
            _store.LoadingMore = false;
            UpdateDownloadCard();
        }
    }

    /// <summary>内容撑不满一屏时用户滚不动 —— 自动再拉一页（有页数上限防死循环）。</summary>
    private void AutoFillIfNeeded()
    {
        if (_autoFillCount >= AutoFillMaxPages) return;
        if (!_store.HasMore || _store.LoadingMore || _busy) return;

        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_store.HasMore || _store.LoadingMore || _busy) return;
            if (_autoFillCount >= AutoFillMaxPages) return;
            if (PageScroll.ScrollableHeight > 0) return;   // 已经有滚动空间
            _autoFillCount++;
            _ = LoadMoreAsync();
        });
    }

    private void LoadMoreIfNearBottom()
    {
        if (_busy || _store.LoadingMore || !_store.HasMore) return;
        if (PageScroll.ScrollableHeight - PageScroll.VerticalOffset < 600)
            _ = LoadMoreAsync();
    }

    // ── 结果区 ────────────────────────────────────────────────

    private void RenderResults()
    {
        if (_resultHost is null) return;

        _resultHost.Children.Clear();
        _tiles.Clear();
        _grid = null;
        _downloadButton = null;
        _selectAllButton = null;
        _downloadStatus = null;
        _selectionText = null;

        var user = _store.User;
        if (user is null) return;

        _resultHost.Children.Add(BuildUserCard(user));
        _resultHost.Children.Add(BuildDownloadCard());
        _resultHost.Children.Add(BuildMediaSection());
        UpdateDownloadCard();
    }

    private static UIElement BuildUserCard(XHomeUser user)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };

        var avatar = new Border
        {
            Width = 56,
            Height = 56,
            CornerRadius = new CornerRadius(28),
            Background = UiKit.SubtleFill,
            Child = new FontIcon
            {
                Glyph = "\uE77B",
                FontSize = 24,
                Foreground = UiKit.AccentFill,
            },
        };
        if (!string.IsNullOrEmpty(user.Avatar))
        {
            var img = new Image { Width = 56, Height = 56, Stretch = Stretch.UniformToFill };
            try { img.Source = new BitmapImage(new Uri(user.Avatar!)); } catch { }
            img.ImageFailed += (_, _) =>
            {
                avatar.Child = new FontIcon
                {
                    Glyph = "\uE77B",
                    FontSize = 24,
                    Foreground = UiKit.AccentFill,
                };
            };
            avatar.Child = new Border { CornerRadius = new CornerRadius(28), Child = img };
        }
        row.Children.Add(avatar);

        var info = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        var nameRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        nameRow.Children.Add(new TextBlock
        {
            Text = user.DisplayName,
            FontSize = 17,
            FontWeight = FontWeights.SemiBold,
        });
        nameRow.Children.Add(new TextBlock
        {
            Text = "共 " + (user.MediaCount?.ToString() ?? "-") + " 个媒体",
            FontSize = 13,
            Opacity = 0.6,
            VerticalAlignment = VerticalAlignment.Center,
        });
        info.Children.Add(nameRow);

        if (!string.IsNullOrEmpty(user.ScreenName))
            info.Children.Add(new TextBlock
            {
                Text = "@" + user.ScreenName,
                FontSize = 13,
                Foreground = UiKit.AccentFill,
            });
        if (!string.IsNullOrEmpty(user.Description))
            info.Children.Add(new TextBlock
            {
                Text = user.Description,
                FontSize = 12,
                Opacity = 0.6,
                MaxLines = 2,
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.Wrap,
            });

        row.Children.Add(info);
        return UiKit.Card(row, 20);
    }

    private UIElement BuildDownloadCard()
    {
        var stack = new StackPanel { Spacing = 12 };

        var head = new Grid { ColumnSpacing = 12 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        left.Children.Add(new FontIcon
        {
            Glyph = "\uE896",
            FontSize = 20,
            Foreground = UiKit.AccentFill,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var texts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(new TextBlock
        {
            Text = "下载 @" + (_store.User?.ScreenName ?? _store.User?.Name ?? "该用户") + " 的媒体",
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
        });
        _downloadStatus = new TextBlock { FontSize = 12, Opacity = 0.6 };
        texts.Children.Add(_downloadStatus);
        left.Children.Add(texts);
        Grid.SetColumn(left, 0);
        head.Children.Add(left);

        _downloadButton = new Button
        {
            MinWidth = 130,
            VerticalAlignment = VerticalAlignment.Center,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        _downloadButton.Click += async (_, _) => await StartDownloadAsync();
        Grid.SetColumn(_downloadButton, 1);
        head.Children.Add(_downloadButton);

        stack.Children.Add(head);

        var selectRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        _selectionText = new TextBlock
        {
            FontSize = 12,
            Opacity = 0.6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        selectRow.Children.Add(_selectionText);
        _selectAllButton = new Button { MinWidth = 88 };
        _selectAllButton.Click += (_, _) => ToggleSelectAll();
        selectRow.Children.Add(_selectAllButton);
        stack.Children.Add(selectRow);

        return UiKit.Card(stack, 16);
    }

    private UIElement BuildMediaSection()
    {
        var stack = new StackPanel { Spacing = 10 };

        if (_store.Posts.Count == 0)
        {
            var empty = new StackPanel { Spacing = 10, Padding = new Thickness(0, 30, 0, 30) };
            empty.Children.Add(new FontIcon
            {
                Glyph = "\uE91B",
                FontSize = 32,
                Opacity = 0.5,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            empty.Children.Add(new TextBlock
            {
                Text = "该用户暂无媒体",
                FontSize = 14,
                Opacity = 0.6,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            stack.Children.Add(empty);
        }
        else
        {
            _grid = new Grid { ColumnSpacing = 10, RowSpacing = 10 };
            stack.Children.Add(_grid);
            RenderTiles();
        }

        var foot = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var moreBtn = new Button
        {
            Content = "加载更多",
            MinWidth = 100,
            IsEnabled = _store.HasMore && !_store.LoadingMore,
        };
        moreBtn.Click += async (_, _) =>
        {
            moreBtn.IsEnabled = false;
            await LoadMoreAsync();
        };
        foot.Children.Add(moreBtn);
        foot.Children.Add(new TextBlock
        {
            Text = _store.LoadingMore
                ? "正在加载…"
                : (_store.HasMore ? "还有更多作品（滚动到底也会自动加载）" : "已到底"),
            FontSize = 12,
            Opacity = 0.6,
            VerticalAlignment = VerticalAlignment.Center,
        });
        stack.Children.Add(foot);

        return UiKit.SectionCard("作品列表", stack,
            _store.Posts.Count + " 条作品 · " + _store.TotalMedia + " 个媒体");
    }

    private void RenderTiles()
    {
        if (_grid is null) return;
        _grid.Children.Clear();
        _grid.RowDefinitions.Clear();
        _grid.ColumnDefinitions.Clear();
        _tiles.Clear();

        var posts = _store.Posts;
        if (posts.Count == 0) return;

        var cols = ColumnsForWidth();
        for (var i = 0; i < cols; i++)
            _grid.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });

        var rows = (posts.Count + cols - 1) / cols;
        for (var r = 0; r < rows; r++)
            _grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        for (var i = 0; i < posts.Count; i++)
        {
            var tile = BuildTile(posts[i]);
            Grid.SetRow(tile.Card, i / cols);
            Grid.SetColumn(tile.Card, i % cols);
            _grid.Children.Add(tile.Card);
            _tiles.Add(tile);
        }
    }

    /// <summary>列数按可用宽度自适应（窗口可缩到 880，固定 4 列会把文字挤没）。</summary>
    private int ColumnsForWidth()
    {
        var w = ActualWidth > 0 ? ActualWidth : 1100;
        if (w >= 1100) return 4;
        if (w >= 820) return 3;
        if (w >= 540) return 2;
        return 1;
    }

    private TileRef BuildTile(XPost post)
    {
        var stack = new StackPanel();

        var imageHost = new Grid { Height = 150 };
        var first = post.Media.Count > 0 ? post.Media[0] : null;
        var img = new Image { Stretch = Stretch.UniformToFill };
        if (first is not null && !string.IsNullOrEmpty(first.PreviewUrl))
        {
            try { img.Source = new BitmapImage(new Uri(first.PreviewUrl)); } catch { }
        }
        imageHost.Children.Add(img);

        imageHost.Children.Add(new Border
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Black),
            Opacity = 0.72,
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(6, 2, 6, 2),
            Margin = new Thickness(0, 0, 6, 6),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Child = new TextBlock
            {
                Text = MediaBadge(post),
                FontSize = 10,
                FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
            },
        });

        var mark = new Border
        {
            Width = 22,
            Height = 22,
            CornerRadius = new CornerRadius(11),
            Background = UiKit.AccentFill,
            Margin = new Thickness(6, 6, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Visibility = Visibility.Collapsed,
            Child = new FontIcon
            {
                Glyph = "\uE73E",
                FontSize = 12,
                Foreground = UiKit.OnAccentText,
            },
        };
        imageHost.Children.Add(mark);

        stack.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(8, 8, 0, 0),
            Background = UiKit.SubtleFill,
            Child = imageHost,
        });

        var text = post.Text ?? "";
        if (text.Length > 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = text,
                FontSize = 12,
                Margin = new Thickness(10, 8, 10, 0),
                MaxLines = 2,
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.Wrap,
            });
        }

        stack.Children.Add(new TextBlock
        {
            Text = MetaLine(post),
            FontSize = 11,
            Opacity = 0.6,
            Margin = new Thickness(10, 6, 10, 10),
        });

        var card = new Border
        {
            Background = UiKit.CardBackground,
            BorderBrush = UiKit.CardBorder,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = stack,
        };

        var tile = new TileRef(post.Id, card, mark);
        card.Tapped += (_, _) => TogglePost(post.Id);
        UpdateTileVisual(tile);
        return tile;
    }

    private static string MediaBadge(XPost post)
    {
        if (post.Media.Count > 1) return post.Media.Count + " 项";
        if (post.Media.Count == 0) return "无媒体";
        return post.Media[0].Type switch
        {
            "video" => "MP4",
            "gif" => "GIF",
            _ => "图片",
        };
    }

    private static string MetaLine(XPost post)
    {
        var time = post.CreatedAt is DateTime t
            ? t.ToLocalTime().ToString("yyyy-MM-dd HH:mm")
            : "未知时间";
        return time + " · " + post.Media.Count + " 个媒体";
    }

    private void UpdateTileVisual(TileRef tile)
    {
        var selected = _store.IsSelected(tile.PostId);
        tile.Card.BorderBrush = selected ? UiKit.AccentFill : UiKit.CardBorder;
        tile.Card.BorderThickness = new Thickness(selected ? 2 : 1);
        tile.Mark.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
    }

    private void TogglePost(string postId)
    {
        _store.Toggle(postId);
        foreach (var t in _tiles)
            if (t.PostId == postId) UpdateTileVisual(t);
        UpdateDownloadCard();
    }

    private void ToggleSelectAll()
    {
        if (_store.SelectedCount > 0) _store.ClearSelection();
        else _store.SelectAll();
        foreach (var t in _tiles) UpdateTileVisual(t);
        UpdateDownloadCard();
    }

    private void UpdateDownloadCard()
    {
        var total = _store.Posts.Count;
        var sel = _store.SelectedCount;
        var selMedia = _store.Posts.Where(p => _store.IsSelected(p.Id)).Sum(p => p.Media.Count);

        if (_downloadStatus is not null)
            _downloadStatus.Text = _store.LoadingMore
                ? "正在加载…"
                : (sel > 0
                    ? "已选 " + sel + " 个作品（" + selMedia + " 个媒体），只下勾中的"
                    : "已加载 " + total + " 条作品 · " + _store.TotalMedia + " 个媒体，未勾选时下载全部");

        if (_selectionText is not null)
            _selectionText.Text = sel > 0 ? "已选 " + sel + " / " + total : "点击卡片即可勾选";

        if (_selectAllButton is not null)
            _selectAllButton.Content = sel > 0 ? "清空选择" : "全选";

        if (_downloadButton is not null)
        {
            _downloadButton.Content = sel > 0 ? "下载所选" : "开始下载";
            _downloadButton.IsEnabled = !_busy && total > 0;
        }
    }

    // ── 入队下载 ──────────────────────────────────────────────

        private Task StartDownloadAsync()
    {
        if (_busy) return Task.CompletedTask;
        if (_store.User is null) return Task.CompletedTask;

        // **对齐原项目：点「开始下载」只登记一个「创建中」任务就立刻返回**，
        // 真正的翻页 + 逐条入队在后台串行执行（CreationTaskStore）。
        //
        // 之前的做法是「当场把所有页拉完再入队」—— 用户要的 189 个媒体要翻 10 页、
        // 每页等 1~2 秒，界面看起来就像卡死了。原版不是这么做的：
        // 它立刻返回，下载管理页顶部出现「共 N 个任务创建中」，
        // 边翻边推，用户能实时看到「已发送 / 已跳过」在涨。
        //
        // **例外**：用户勾选了具体作品时，只下勾中的那几个 —— 那些已经在本地列表里，
        // 不需要翻页，直接走原来的即时入队路径。
        if (_store.SelectedCount == 0)
        {
            var u = _store.User;
            if (string.IsNullOrEmpty(u.Id))
            {
                SetStatus("接口没返回用户 ID，无法创建下载任务");
                return Task.CompletedTask;
            }

            CreationTaskStore.Instance.Create(
                u.Id, u.ScreenName ?? "", u.DisplayName ?? "", u.Avatar ?? "");

            SetStatus("已提交到下载管理，正在后台抓取「" + (u.DisplayName ?? u.ScreenName)
                      + "」的全部媒体（进度见下载管理页顶部）");
            return Task.CompletedTask;
        }

        // ── 勾选了作品：只下勾中的，直接即时入队 ──────────────────────
        return EnqueueSelectedAsync();
    }

    /// <summary>只入队「勾选中的」作品（不翻页，用户明确只要这几个）。</summary>
    private async Task EnqueueSelectedAsync()
    {
        var posts = _store.PostsForDownload();
        if (posts.Count == 0)
        {
            SetStatus("没有可下载的作品");
            return;
        }

        var settings = AppSettings.Instance.ForModule("x");
        var skip = settings.SkipDownloaded;
        var types = (settings.MediaTypeFilter ?? "")
            .Split((char)44, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim().ToLowerInvariant())
            .ToHashSet();

        _busy = true;
        UpdateDownloadCard();
        var queued = 0; var skipped = 0; var failed = 0;

        try
        {
            foreach (var post in posts)
            {
                for (var i = 0; i < post.Media.Count; i++)
                {
                    var m = post.Media[i];
                    if (types.Count > 0 && !types.Contains(m.Type)) continue;

                    var name = XNaming.NameFor(post, i);
                    var dir = XNaming.DirFor(post, i);
                    name = FileNameTemplate.ClampForFullPath(dir ?? "", name);

                    if (skip && !string.IsNullOrEmpty(dir))
                    {
                        try
                        {
                            if (System.IO.File.Exists(System.IO.Path.Combine(dir, name)))
                            { skipped++; continue; }
                        }
                        catch { }
                    }

                    var (ok, _) = await DownloadStore.Instance.AddAsync(m.Url, ModuleName, dir, name);
                    if (ok) queued++; else failed++;
                }
            }
            DownloadStore.Instance.Flush();

            var parts = new List<string> { "已入队 " + queued + " 个" };
            if (skipped > 0) parts.Add("跳过 " + skipped + " 个已存在");
            if (failed > 0) parts.Add(failed + " 个失败");
            SetStatus(string.Join("，", parts));
        }
        catch (Exception ex)
        {
            SetStatus("入队异常：" + ex.Message);
        }
        finally
        {
            _busy = false;
            UpdateDownloadCard();
        }
    }    /// <summary>
    /// 已下载集合：下载台账里「已完成」的 URL + 当前队列里所有 URL。
    /// 台账是唯一能跨重启记住「下过什么」的地方（aria2 会话重启就空）。
    /// </summary>
    private static HashSet<string> BuildDownloadedSet()
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var e in DownloadLedger.Instance.Query(ModuleName, 2000))
                if (e.Status == "已完成" && !string.IsNullOrEmpty(e.Url)) set.Add(e.Url);
        }
        catch { }
        try
        {
            foreach (var it in DownloadStore.Instance.Items)
                if (!string.IsNullOrEmpty(it.Url)) set.Add(it.Url);
        }
        catch { }
        return set;
    }

    /// <summary>按「X 下载设置 → 文件名模板」生成文件名（默认模板已含 %EXT%）。</summary>
    // ── 自测 ─────────────────────────────────────────────────

    private async Task RunSelfTestAsync()
    {
        var text = XHomeSelfTest.Run();
        var dlg = new ContentDialog
        {
            Title = "X 主页离线自测",
            Content = new ScrollViewer
            {
                MaxHeight = 420,
                Content = new TextBlock
                {
                    Text = text,
                    FontFamily = new FontFamily("Consolas"),
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                },
            },
            CloseButtonText = "关闭",
            XamlRoot = XamlRoot,
        };
        await dlg.ShowAsync();
    }

    /// <summary>
    /// 把所有分页都拉完（直到没有下一页，或触发安全上限）。
    ///
    /// 收敛判据与 <see cref="XHomeStore.PageHasMore"/> 一致：连续多页没有新增即认为到底，
    /// 避免 X 在末尾反复返回「还有下一页」但内容为空时无限翻。
    /// </summary>
    private async Task LoadAllPagesAsync(bool render = true)
    {
        var userId = _store.User?.Id;
        if (string.IsNullOrEmpty(userId) || _api is null) return;

        const int maxPages = 200;   // 防护上限：200 页 × 20 条 = 4000 条
        var page = 0;
        var noGrowth = 0;

        while (_store.HasMore && page < maxPages)
        {
            var before = _store.Posts.Count;
            page++;
            SetStatus("正在加载全部作品… 第 " + page + " 页，已有 " + before + " 条");

            try
            {
                var cursor = _store.NextCursor;
                var res = await _api.GetMediasAsync(userId, cursor);
                _store.Append(res, cursor);
            }
            catch (Exception ex)
            {
                // 中途失败不丢弃已加载的，如实告知
                RenderResults();
                SetStatus("加载中断（已加载 " + _store.Posts.Count + " 条）：" + XHomeApi.MapError(ex));
                return;
            }

            noGrowth = _store.Posts.Count > before ? 0 : noGrowth + 1;
            if (noGrowth >= 3) break;
        }

        RenderResults();
        SetStatus("已加载全部 " + _store.Posts.Count + " 条作品 · " + _store.TotalMedia + " 个媒体"
                  + (_store.HasMore ? "（已达翻页上限）" : "（已到底）"));
    }
}
