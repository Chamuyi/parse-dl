using System;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;

namespace ParseDl.Pages;

/// <summary>解析页的模块身份。三个模块共用同一套页面结构。</summary>
public enum ParseKind
{
    X,
    Douyin,
    Bili,
}

/// <summary>
/// 解析页 —— X 主页 / 抖音解析下载 / B 站解析下载三页共用的结构。
///
/// 为什么合并成一个页面类：Flutter 版这三页是三个文件、各自上千行，但
/// 骨架完全相同（页头 → Hero 横幅 → 输入卡 → 结果区）。差异只有文案、
/// 图标与具体 API。合并后差异集中在 <see cref="Profile"/> 里，
/// 加模块不用再复制一份布局。
/// </summary>
public sealed partial class ParsePage : Page
{
    private MainWindow? _host;
    private ParseKind _kind = ParseKind.X;

    private sealed record Profile(
        string Title, string Subtitle, string Glyph, string Badge,
        string HeroTitle, string HeroSubtitle, string InputLabel,
        string InputHint, string ActionText);

    private static Profile ProfileOf(ParseKind kind) => kind switch
    {
        ParseKind.X => new Profile(
            "X 主页", "下载某个 X 用户的全部媒体", "\uE80F", "X",
            "下载某个 X 用户的全部媒体", "输入用户 ID，加载后开始批量下载图片与视频",
            "请输入用户 ID", "请输入用户 ID，如：example_user", "加载"),
        ParseKind.Douyin => new Profile(
            "解析下载", "抖音作品解析与下载", "\uE768", "抖",
            "解析抖音作品", "左边浏览，右边抓取",
            "作品链接", "粘贴抖音分享链接或作品 ID", "解析"),
        _ => new Profile(
            "解析下载", "B 站稿件解析与下载", "\uE768", "B",
            "解析 B 站稿件", "支持合集 / 系列 / 收藏夹",
            "稿件地址", "粘贴 B 站视频 / 合集 / 收藏夹链接", "解析"),
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

        // Hero 横幅：徽标 + 标题 + 副题 + 状态胶囊
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

        // 输入卡
        var inputPanel = new StackPanel { Spacing = 10 };
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var box = new TextBox
        {
            PlaceholderText = p.InputHint,
            Height = 36,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(box, 0);
        row.Children.Add(box);

        var actionBtn = new Button
        {
            Content = p.ActionText,
            Height = 36,
            MinWidth = 88,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        Grid.SetColumn(actionBtn, 1);
        row.Children.Add(actionBtn);

        inputPanel.Children.Add(row);
        inputPanel.Children.Add(new TextBlock
        {
            Text = "提示：WinUI 3 版正在迁移中，本页的解析与下载逻辑尚未接入（界面骨架已就位）。",
            FontSize = 12,
            Opacity = 0.6,
            TextWrapping = TextWrapping.Wrap,
        });
        Root.Children.Add(UiKit.SectionCard(p.InputLabel, inputPanel));
    }
}

/// <summary>导航参数：告诉 ParsePage 该显示哪个模块。</summary>
public sealed record ParseNavArgs(ParseKind Kind, MainWindow Host);
