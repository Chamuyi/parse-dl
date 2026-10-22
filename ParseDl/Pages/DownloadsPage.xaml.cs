using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;

namespace ParseDl.Pages;

/// <summary>
/// 下载管理 —— X / 抖音 / B 站三页共用（Flutter 版是同一组件传 feed 参数）。
/// 结构：页头 + Tab 条（自己一张卡）+ 任务列表卡。
/// </summary>
public sealed partial class DownloadsPage : Page
{
    private string _module = "X 媒体";

    public DownloadsPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is string module) _module = module;
        Build();
    }

    private void Build()
    {
        Root.Children.Clear();

        Root.Children.Add(UiKit.PageHeader("下载管理", _module, "\uE896"));

        // Tab 条：自己一张卡，宽度按内容（照抄 Flutter 版的 .tabs2.card）
        var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        foreach (var (label, count) in new (string, int)[]
                 { ("下载中", 0), ("等待中", 0), ("已暂停", 0), ("错误", 0), ("已完成", 0) })
        {
            var btn = new Button
            {
                Content = count > 0 ? $"{label} {count}" : label,
                Padding = new Thickness(12, 6, 12, 6),
                Background = UiKit.SubtleFill,
                BorderThickness = new Thickness(0),
                CornerRadius = new CornerRadius(6),
            };
            tabs.Children.Add(btn);
        }
        var tabCard = new Border
        {
            Background = UiKit.CardBackground,
            BorderBrush = UiKit.CardBorder,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6, 4, 6, 4),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = tabs,
        };
        Root.Children.Add(tabCard);

        // 任务列表卡
        var empty = new StackPanel
        {
            Spacing = 8,
            Padding = new Thickness(0, 24, 0, 24),
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        empty.Children.Add(new FontIcon
        {
            Glyph = "\uE896", FontSize = 28, Opacity = 0.35,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        empty.Children.Add(new TextBlock
        {
            Text = "还没有下载任务",
            FontSize = 14, Opacity = 0.6,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        empty.Children.Add(new TextBlock
        {
            Text = "WinUI 3 版正在迁移中，下载任务列表尚未接入。",
            FontSize = 12, Opacity = 0.45,
            HorizontalAlignment = HorizontalAlignment.Center,
        });

        Root.Children.Add(UiKit.Card(empty));
    }
}
