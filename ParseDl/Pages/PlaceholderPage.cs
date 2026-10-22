using Microsoft.UI.Xaml.Controls;

namespace ParseDl.Pages;

/// <summary>
/// 占位页 —— 尚未迁移的功能页落到这里。
///
/// 存在的意义是「不假装完成」：迁移期间点进去会明确显示"此页尚未迁移"，
/// 而不是白屏或静默失败。每迁移完一个页面就从 MainWindow.Navigate 的
/// 映射里换掉它。
/// </summary>
public sealed partial class PlaceholderPage : Page
{
    private readonly string _label;

    public PlaceholderPage()
    {
        var panel = new StackPanel
        {
            Spacing = 12,
            Padding = new Microsoft.UI.Xaml.Thickness(24),
            VerticalAlignment = Microsoft.UI.Xaml.VerticalAlignment.Center,
            HorizontalAlignment = Microsoft.UI.Xaml.HorizontalAlignment.Center,
        };
        panel.Children.Add(new TextBlock
        {
            Text = "此页尚未迁移到 WinUI 3",
            FontSize = 20,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = Microsoft.UI.Xaml.HorizontalAlignment.Center,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "Flutter 版功能完好，可从 F:\\parse-dl-backup 回滚。",
            FontSize = 13,
            Opacity = 0.7,
            HorizontalAlignment = Microsoft.UI.Xaml.HorizontalAlignment.Center,
        });
        Content = panel;
        _label = string.Empty;
    }
}
