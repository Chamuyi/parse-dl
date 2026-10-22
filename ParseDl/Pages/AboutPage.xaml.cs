using System;
using System.Reflection;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ParseDl.Controls;
using ParseDl.Services;

namespace ParseDl.Pages;

/// <summary>
/// 关于页 —— 结构照 Flutter 版 lib/pages/about_page.dart：
/// 页头 + 双栏（左：标识/版本/许可；右：本机环境）。
/// </summary>
public sealed partial class AboutPage : Page
{
    public AboutPage()
    {
        InitializeComponent();
        Build();
    }

    private void Build()
    {
        Root.Children.Add(UiKit.PageHeader("关于", "版本、许可与本机环境", "\uE946"));

        var cols = new Grid { ColumnSpacing = 12 };
        cols.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        cols.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var left = new StackPanel { Spacing = 22 };

        var brand = new Grid();
        brand.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        brand.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var logo = new Border
        {
            Width = 64,
            Height = 64,
            CornerRadius = new CornerRadius(12),
            Background = UiKit.AccentFill,
            Child = new FontIcon
            {
                Glyph = "\uE896",
                FontSize = 30,
                Foreground = UiKit.OnAccentText,
            },
        };
        brand.Children.Add(logo);

        var brandText = new StackPanel { Margin = new Thickness(20, 0, 0, 0), Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        brandText.Children.Add(new TextBlock { Text = "解析下载器", FontSize = 22, FontWeight = FontWeights.SemiBold });
        brandText.Children.Add(new TextBlock { Text = "批量下载 X、抖音与 B 站的图片与视频", FontSize = 13, Opacity = 0.7 });
        Grid.SetColumn(brandText, 1);
        brand.Children.Add(brandText);
        left.Children.Add(brand);

        var info = new StackPanel();
        info.Children.Add(UiKit.InfoRow("版本", AppVersion(), selectable: true));
        info.Children.Add(UiKit.InfoRow("架构", "WinUI 3 · Windows App SDK", selectable: true));
        info.Children.Add(UiKit.InfoRow("许可", "MIT License", selectable: true));
        info.Children.Add(UiKit.InfoRow("数据目录", AppPaths.DataDir, selectable: true));
        left.Children.Add(info);

        var leftCard = UiKit.Card(left, 28);
        Grid.SetColumn(leftCard, 0);
        cols.Children.Add(leftCard);

        var right = new StackPanel { Spacing = 10 };
        right.Children.Add(new TextBlock { Text = "本机环境", FontSize = 16, FontWeight = FontWeights.SemiBold });
        right.Children.Add(UiKit.InfoRow("操作系统", Environment.OSVersion.VersionString, selectable: true));
        right.Children.Add(UiKit.InfoRow("处理器架构", System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString()));
        right.Children.Add(UiKit.InfoRow(".NET 版本", Environment.Version.ToString()));
        right.Children.Add(UiKit.InfoRow("运行时", System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription, selectable: true));
        right.Children.Add(new TextBlock
        {
            Text = "窗口材质由 Windows App SDK 官方合成控制器绘制（MicaController / DesktopAcrylicController），与图吧工具箱同一套 API。",
            FontSize = 12,
            Opacity = 0.65,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 8, 0, 0),
        });

        var rightCard = UiKit.Card(right, 28);
        Grid.SetColumn(rightCard, 1);
        cols.Children.Add(rightCard);

        Root.Children.Add(cols);
    }

    private static string AppVersion()
    {
        try
        {
            var asm = Assembly.GetExecutingAssembly();
            var v = asm.GetName().Version;
            return v is null ? "1.3" : $"1.3 ({v})";
        }
        catch
        {
            return "1.3";
        }
    }
}
