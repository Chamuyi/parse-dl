using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;

namespace ParseDl.Pages;

/// <summary>
/// 自动执行页 —— X「自动执行」与抖音「自动下载」共用。
/// 结构：页头 + 任务卡（启停 + 名单/目标）+ 运行日志卡。
/// </summary>
public sealed partial class AutoTaskPage : Page
{
    private bool _isDouyin;

    public AutoTaskPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _isDouyin = e.Parameter is string s && s == "douyin";
        Build();
    }

    private void Build()
    {
        Root.Children.Clear();

        var title = _isDouyin ? "自动下载" : "自动执行";
        var subtitle = _isDouyin ? "按目标批量滚动抓取" : "按名单批量跑 X 用户";
        Root.Children.Add(UiKit.PageHeader(title, subtitle, "\uE945"));

        // 任务卡
        var panel = new StackPanel { Spacing = 12 };

        var headRow = new Grid();
        headRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        headRow.Children.Add(new TextBlock
        {
            Text = _isDouyin ? "抓取目标" : "用户名单",
            FontSize = 14,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var toggle = new ToggleSwitch { OffContent = "已停止", OnContent = "运行中", IsOn = false };
        Grid.SetColumn(toggle, 1);
        headRow.Children.Add(toggle);
        panel.Children.Add(headRow);

        panel.Children.Add(new TextBox
        {
            PlaceholderText = _isDouyin
                ? "每行一个目标（用户主页 / 话题 / 音乐链接）"
                : "每行一个 X 用户 ID",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 120,
        });

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(new Button
        {
            Content = "开始",
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
            MinWidth = 88,
        });
        actions.Children.Add(new Button { Content = "暂停", MinWidth = 88 });
        actions.Children.Add(new Button { Content = "清空", MinWidth = 88 });
        panel.Children.Add(actions);

        Root.Children.Add(UiKit.SectionCard("任务", panel));

        // 运行日志
        var log = new StackPanel { Spacing = 6 };
        log.Children.Add(new TextBlock
        {
            Text = "还没有运行记录",
            FontSize = 13,
            Opacity = 0.6,
        });
        log.Children.Add(new TextBlock
        {
            Text = "WinUI 3 版正在迁移中，自动任务的调度与日志尚未接入。",
            FontSize = 12,
            Opacity = 0.45,
            TextWrapping = TextWrapping.Wrap,
        });
        Root.Children.Add(UiKit.SectionCard("运行日志", log));
    }
}
