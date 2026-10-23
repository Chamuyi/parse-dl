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

        // ── 自测区块 ──────────────────────────────────────
        // 为什么放在界面上：打包应用既透传不了命令行参数、也继承不到父进程环境变量
        // （winapp run 会起独立进程）。一个按钮是唯一可靠的触发方式，
        // 而且用户自己也能随时复验。
        var selfTest = new StackPanel { Spacing = 8 };
        var runBtn = new Button { Content = "运行自测", MinWidth = 110 };
        var resultText = new TextBlock
        {
            Text = "点上方按钮运行离线自测（文件名模板 + B 站链接解析）",
            FontSize = 12,
            Opacity = 0.7,
            TextWrapping = Microsoft.UI.Xaml.TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
        };
        runBtn.Click += (_, _) =>
        {
            try
            {
                var report = SelfTestSuite.RunAll();
                resultText.Text = report;
                var outPath = System.IO.Path.Combine(ParseDl.Services.AppPaths.DataDir, "selftest.txt");
                System.IO.File.WriteAllText(outPath, report);
            }
            catch (Exception ex)
            {
                resultText.Text = "自测异常: " + ex.Message;
            }
        };
        var netBtn = new Button { Content = "测试 B 站接口（联网）", MinWidth = 160, Margin = new Thickness(0, 0, 0, 0) };
        netBtn.Click += async (_, _) =>
        {
            netBtn.IsEnabled = false;
            resultText.Text = "正在请求 B 站…";
            try
            {
                var api = new ParseDl.Services.Bili.BiliApi();
                var info = await api.GetVideoInfoAsync("BV1xx411c7mD");
                var sb2 = new System.Text.StringBuilder();
                sb2.AppendLine("视频：" + info.Title);
                sb2.AppendLine("UP：" + info.OwnerName + "（" + info.OwnerMid + "）");
                sb2.AppendLine("分P数：" + info.Pages.Count + "  时长：" + info.DurationSec + " 秒");
                if (info.Pages.Count > 0 && info.Pages[0].Cid is string cidStr && long.TryParse(cidStr, out var cid))
                {
                    var play = await api.GetPlayInfoAsync(info.Bvid, cid);
                    sb2.AppendLine("视频流：" + play.Videos.Count + " 条，最高 " +
                        (play.Videos.Count > 0 ? play.Videos[0].QualityLabel + " / " + play.Videos[0].Codec : "无"));
                    sb2.AppendLine("音频流：" + play.Audios.Count + " 条，最高 " +
                        (play.Audios.Count > 0 ? play.Audios[0].QualityLabel : "无"));
                }
                resultText.Text = sb2.ToString();
                System.IO.File.WriteAllText(
                    System.IO.Path.Combine(ParseDl.Services.AppPaths.DataDir, "bili_probe.txt"), sb2.ToString());
            }
            catch (Exception ex)
            {
                resultText.Text = "失败：" + ex.GetType().Name + " " + ex.Message;
                try
                {
                    System.IO.File.WriteAllText(
                        System.IO.Path.Combine(ParseDl.Services.AppPaths.DataDir, "bili_probe.txt"),
                        "失败：" + ex);
                }
                catch { }
            }
            finally { netBtn.IsEnabled = true; }
        };
        selfTest.Children.Add(runBtn);
        selfTest.Children.Add(netBtn);
        selfTest.Children.Add(resultText);
        Root.Children.Add(UiKit.SectionCard("自测", selfTest, "离线，不联网"));
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