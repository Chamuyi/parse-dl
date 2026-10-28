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
        info.Children.Add(UiKit.InfoRow("作者", "parse-dl 项目组", selectable: true));
        info.Children.Add(UiKit.InfoRow("系统要求", "Windows 10 1809+ / Windows 11 · 需 Edge WebView2 运行时", selectable: true));
        info.Children.Add(UiKit.InfoRow("日志目录", System.IO.Path.Combine(AppPaths.DataDir, "logs"), selectable: true));
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
        var loginBtn2 = new Button { Content = "测试登录接口", MinWidth = 120 };
        loginBtn2.Click += async (_, _) =>
        {
            loginBtn2.IsEnabled = false;
            resultText.Text = "正在测试扫码登录接口…";
            try
            {
                var login = new ParseDl.Services.Bili.BiliLogin();
                var qr = await login.GenerateQrCodeAsync();
                var sb3 = new System.Text.StringBuilder();
                sb3.AppendLine("✅ 二维码生成成功");
                sb3.AppendLine("轮询 key：" + qr.Key);
                sb3.AppendLine("二维码地址：" + qr.Url);
                var poll = await login.PollAsync(qr.Key);
                sb3.AppendLine("首次轮询状态：" + poll.State + "（未扫码时应为 Waiting）");
                resultText.Text = sb3.ToString();
                System.IO.File.WriteAllText(
                    System.IO.Path.Combine(ParseDl.Services.AppPaths.DataDir, "bili_login_probe.txt"), sb3.ToString());
            }
            catch (Exception ex)
            {
                resultText.Text = "❌ " + ex.GetType().Name + "：" + ex.Message;
                try
                {
                    System.IO.File.WriteAllText(
                        System.IO.Path.Combine(ParseDl.Services.AppPaths.DataDir, "bili_login_probe.txt"),
                        "失败：" + ex);
                }
                catch { }
            }
            finally { loginBtn2.IsEnabled = true; }
        };
        selfTest.Children.Add(runBtn);
        selfTest.Children.Add(netBtn);
        selfTest.Children.Add(loginBtn2);
        selfTest.Children.Add(resultText);
        Root.Children.Add(UiKit.SectionCard("自测", selfTest, "离线，不联网"));
        BuildLicenseAndCredits();
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

    /// <summary>
    /// 条款全文 + 开源组件（2026-10-29 补）。
    ///
    /// 原项目 about_page 有这两块，WinUI3 版之前只有版本/环境信息 ——
    /// 用户在原版能看到的许可条款与依赖清单，这边看不到。
    /// </summary>
    private void BuildLicenseAndCredits()
    {
        var panel = new StackPanel { Spacing = 8 };

        panel.Children.Add(new TextBlock
        {
            Text = "MIT License",
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "Copyright (c) 2026 parse-dl",
            FontSize = 12,
            Opacity = 0.75,
            IsTextSelectionEnabled = true,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "Permission is hereby granted, free of charge, to any person obtaining a copy of "
                 + "this software and associated documentation files (the \"Software\"), to deal in the "
                 + "Software without restriction, including without limitation the rights to use, copy, "
                 + "modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, "
                 + "and to permit persons to whom the Software is furnished to do so, subject to the "
                 + "following conditions:\n\n"
                 + "The above copyright notice and this permission notice shall be included in all "
                 + "copies or substantial portions of the Software.\n\n"
                 + "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, "
                 + "INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A "
                 + "PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT "
                 + "HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF "
                 + "CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE "
                 + "OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.",
            FontSize = 11.5,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        Root.Children.Add(UiKit.SectionCard("条款全文", panel, "MIT License"));

        var credits = new StackPanel { Spacing = 4 };
        foreach (var (name, note) in new (string, string)[]
        {
            ("Windows App SDK (WinUI 3)", "MIT · 界面框架与窗口材质"),
            ("aria2c", "GPL-2.0 · 下载引擎（独立进程）"),
            ("ffmpeg", "LGPL/GPL · B 站 DASH 音视频合并"),
            ("WebView2", "Microsoft · 抖音 / B 站内嵌浏览"),
            ("CommunityToolkit", "MIT · 辅助控件"),
        })
        {
            credits.Children.Add(UiKit.InfoRow(name, note));
        }
        Root.Children.Add(UiKit.SectionCard("使用的开源组件", credits, "各自的许可证见其仓库"));
    }
}
