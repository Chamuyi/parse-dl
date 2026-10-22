using System;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;

namespace ParseDl.Pages;

/// <summary>解析页的模块身份。三个模块共用同一套页面结构。</summary>
public enum ParseKind
{
    X,
    Douyin,
    Bili,
}

/// <summary>
/// 解析页 —— X 主页 / 抖音解析下载 / B 站解析下载三页共用。
///
/// 当前能力：接受 **http/https 直链**（图片、视频、音频、压缩包都行）并交给
/// 真实的 aria2 引擎下载；加入后可直接跳转下载管理看进度。
/// 平台专用解析（X/抖音/B站的页面抓取与 API）尚未移植 —— 界面上如实标注，
/// 不假装支持。
/// </summary>
public sealed partial class ParsePage : Page
{
    private MainWindow? _host;
    private ParseKind _kind = ParseKind.X;
    private TextBox? _input;
    private TextBlock? _status;

    private sealed record Profile(
        string Title, string Subtitle, string Glyph, string Badge,
        string HeroTitle, string HeroSubtitle, string InputLabel,
        string InputHint, string ActionText, string ModuleName);

    private static Profile ProfileOf(ParseKind kind) => kind switch
    {
        ParseKind.X => new Profile(
            "X 主页", "下载 X 媒体文件", "\uE80F", "X",
            "下载 X 媒体", "粘贴图片 / 视频直链，交给 aria2 多线程下载",
            "媒体直链", "粘贴 http(s) 直链，如 https://pbs.twimg.com/media/xxx.jpg", "加入队列", "X 媒体"),
        ParseKind.Douyin => new Profile(
            "解析下载", "抖音媒体下载", "\uE768", "抖",
            "下载抖音媒体", "粘贴视频 / 图片直链，交给 aria2 多线程下载",
            "媒体直链", "粘贴 http(s) 直链", "加入队列", "抖音"),
        _ => new Profile(
            "解析下载", "B 站媒体下载", "\uE768", "B",
            "下载 B 站媒体", "粘贴音视频直链，交给 aria2 多线程下载",
            "媒体直链", "粘贴 http(s) 直链", "加入队列", "B 站"),
    };

    public ParsePage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is ParseNavArgs args)
        {
            _kind = args.Kind;
            _host = args.Host;
        }
        Build();
    }

    private void Build()
    {
        Root.Children.Clear();
        var p = ProfileOf(_kind);

        Root.Children.Add(UiKit.PageHeader(p.Title, p.Subtitle, p.Glyph));

        // Hero
        var hero = new StackPanel { Spacing = 8 };
        var badgeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        badgeRow.Children.Add(new Border
        {
            Width = 36, Height = 36, CornerRadius = new CornerRadius(8),
            Background = UiKit.AccentFill,
            Child = new TextBlock
            {
                Text = p.Badge, FontSize = 16, FontWeight = FontWeights.SemiBold,
                Foreground = UiKit.OnAccentText,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        });
        badgeRow.Children.Add(new TextBlock
        {
            Text = p.HeroTitle, FontSize = 20, FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        hero.Children.Add(badgeRow);
        hero.Children.Add(new TextBlock { Text = p.HeroSubtitle, FontSize = 13, Opacity = 0.7 });
        Root.Children.Add(UiKit.Card(hero, 20));

        // 输入 + 加入队列
        var inputPanel = new StackPanel { Spacing = 10 };
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _input = new TextBox
        {
            PlaceholderText = p.InputHint,
            Height = 36,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(_input, 0);
        row.Children.Add(_input);

        var actionBtn = new Button
        {
            Content = p.ActionText,
            Height = 36,
            MinWidth = 96,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        actionBtn.Click += async (_, _) => await OnAddAsync();
        Grid.SetColumn(actionBtn, 1);
        row.Children.Add(actionBtn);

        inputPanel.Children.Add(row);

        _status = new TextBlock { Text = "", FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
        inputPanel.Children.Add(_status);

        Root.Children.Add(UiKit.SectionCard(p.InputLabel, inputPanel));

        // 说明卡：如实写清已支持 / 未支持
        var notes = new StackPanel { Spacing = 6 };
        notes.Children.Add(Bullet("已支持：http / https 直链，多线程分片、断点续传（aria2 引擎）"));
        notes.Children.Add(Bullet("已支持：下载进度实时刷新、暂停 / 继续 / 移除、打开下载目录"));
        notes.Children.Add(Bullet("未支持：平台专用解析（X / 抖音 / B 站 的页面抓取、登录态、合集遍历）"));
        Root.Children.Add(UiKit.SectionCard("能力说明", notes));
    }

    private static UIElement Bullet(string text)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new TextBlock { Text = "•", FontSize = 13, Opacity = 0.6 });
        row.Children.Add(new TextBlock { Text = text, FontSize = 13, Opacity = 0.85, TextWrapping = TextWrapping.Wrap });
        return row;
    }

    private async System.Threading.Tasks.Task OnAddAsync()
    {
        if (_input is null || _status is null) return;
        var url = _input.Text?.Trim() ?? "";
        var p = ProfileOf(_kind);

        _status.Text = "正在加入队列…";
        var (ok, msg) = await DownloadStore.Instance.AddAsync(url, p.ModuleName);
        _status.Text = ok ? $"✅ {msg}，可到「下载管理」查看进度" : $"❌ {msg}";
        if (ok) _input.Text = "";
    }
}

/// <summary>导航参数：告诉 ParsePage 该显示哪个模块。</summary>
public sealed record ParseNavArgs(ParseKind Kind, MainWindow Host);
