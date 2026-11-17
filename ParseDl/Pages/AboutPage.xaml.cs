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
        info.Children.Add(UiKit.InfoRow("许可", "GPL-3.0", selectable: true));
        info.Children.Add(UiKit.InfoRow("作者", "茶沐依", selectable: true));
        info.Children.Add(UiKit.InfoRow("系统要求", "Windows 10 1809+ / Windows 11 · 需 Edge WebView2 运行时", selectable: true));
        // **路径单独占一整行**（2026-10-30 用户报「日志和数据目录是不是太长了」）：
        // UiKit.InfoRow 的值列是 Auto 宽，长路径会把标签挤到左边、还溢出卡片。
        // 这里改成「标签一行 + 路径一行」，路径可选中复制、自动换行。
        info.Children.Add(PathRow("日志目录", "userdata\\logs", System.IO.Path.Combine(AppPaths.DataDir, "logs")));
        info.Children.Add(PathRow("数据目录", "userdata", AppPaths.DataDir));
        left.Children.Add(info);

        var leftCard = UiKit.Card(left, 28);
        Grid.SetColumn(leftCard, 0);
        cols.Children.Add(leftCard);

        var right = new StackPanel { Spacing = 10 };
        right.Children.Add(new TextBlock { Text = "本机环境", FontSize = 16, FontWeight = FontWeights.SemiBold });
        right.Children.Add(UiKit.InfoRow("操作系统", OsDisplayName(), selectable: true));
        right.Children.Add(UiKit.InfoRow("处理器架构", System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString()));
        right.Children.Add(UiKit.InfoRow(".NET 版本", Environment.Version.ToString()));
        right.Children.Add(UiKit.InfoRow("运行时", System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription, selectable: true));

        var rightCard = UiKit.Card(right, 28);
        Grid.SetColumn(rightCard, 1);
        cols.Children.Add(rightCard);

        Root.Children.Add(cols);

        BuildLicenseAndCredits();
    }

    /// <summary>
    /// 路径一行：**标签与值同行**，值可省略、悬停看完整路径（2026-10-30）。
    ///
    /// 演进过程：① 原来用 UiKit.InfoRow，值列 Auto 宽 + 100+ 字符的绝对路径
    /// → 标签被挤扁、顶破卡片；② 改成「标签一行 + 路径一行」，但路径缩成
    /// userdata\\logs 之后只有十几个字符，再占一行就是白浪费空间。
    /// 现在：标签 Auto + 值 *（左对齐、超长省略），一行搞定，完整路径进 ToolTip。
    /// </summary>
    private static UIElement PathRow(string label, string shortPath, string fullPath)
    {
        var grid = new Grid { Margin = new Thickness(0, 3, 0, 3) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        grid.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 13,
            Opacity = 0.7,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var value = new TextBlock
        {
            Text = shortPath,
            FontSize = 12,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            IsTextSelectionEnabled = true,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        };
        ToolTipService.SetToolTip(value, fullPath);
        Grid.SetColumn(value, 1);
        grid.Children.Add(value);
        return grid;
    }

    /// <summary>
    /// 人类可读的系统版本（2026-10-30 用户问「为什么是 Microsoft Windows NT 10.0.26300.0」）。
    ///
    /// 不能直接用 Environment.OSVersion.VersionString —— 那是旧式内部串，
    /// 既看不出是 Win10 还是 Win11，也读不出 26H2 这种发行代号。
    /// 也不能用注册表 ProductName —— 微软至今把 Win11 也写成 "Windows 10"。
    /// 唯一可靠的是 CurrentBuild：>= 22000 即 Windows 11（22000 是 Win11 首个 RTM 版本）。
    /// </summary>
    private static string OsDisplayName()
    {
        try
        {
            using var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                @"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion");
            if (k is null) return Environment.OSVersion.VersionString;

            var buildStr = k.GetValue("CurrentBuild") as string;
            var disp = k.GetValue("DisplayVersion") as string;
            var ubr = k.GetValue("UBR");
            if (!int.TryParse(buildStr, out var build)) return Environment.OSVersion.VersionString;

            var name = build switch
            {
                >= 22000 => "Windows 11",
                >= 10240 => "Windows 10",
                >= 9600 => "Windows 8.1",
                >= 9200 => "Windows 8",
                >= 7600 => "Windows 7",
                _ => "Windows",
            };

            var sb = new System.Text.StringBuilder(name);
            if (!string.IsNullOrWhiteSpace(disp)) sb.Append(" · ").Append(disp);
            sb.Append(" · Build ").Append(build);
            if (ubr is int u && u > 0) sb.Append(".").Append(u);
            return sb.ToString();
        }
        catch
        {
            return Environment.OSVersion.VersionString;
        }
    }

    private static string AppVersion()
    {
        // **版本号只认程序集，不要在这里写死**（2026-11-18 修）。
        //
        // 原来这里把主版本硬编码成 "1.3"：csproj 的 <Version> 改成 1.5 之后，
        // 关于页依然显示「1.3 (1.5.0.0)」，两处不一致且改版本时极易漏掉这一处。
        // 现在统一从 Assembly 的 Version 推：csproj <Version>1.5.0</Version>
        // → AssemblyVersion 1.5.0.0 → 显示「1.5.0 (1.5.0.0)」。
        try
        {
            var asm = Assembly.GetExecutingAssembly();
            var v = asm.GetName().Version;
            if (v is null) return "未知";
            // Major.Minor.Build 去掉末尾的 .0，读者看到 1.5.0 而不是 1.5.0.0
            var brief = v.Revision > 0
                ? $"{v.Major}.{v.Minor}.{v.Build}.{v.Revision}"
                : $"{v.Major}.{v.Minor}.{v.Build}";
            return $"{brief} ({v})";
        }
        catch
        {
            return "未知";
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
            Text = "GNU General Public License v3.0",
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "Copyright (C) 2026 茶沐依",
            FontSize = 12,
            Opacity = 0.75,
            IsTextSelectionEnabled = true,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "本程序是自由软件：你可以依据自由软件基金会发布的 GNU 通用公共许可证（第 3 版）"
                 + "的条款，对它进行再分发和/或修改。本程序基于「希望它有用」的目的分发，"
                 + "但不提供任何担保，也不保证适销性或适用于特定用途 —— 详见 GNU 通用公共许可证。"

                 + "You may redistribute and/or modify it under the terms of the GNU General "
                 + "Public License as published by the Free Software Foundation, version 3."
                 + " This program is distributed in the hope that it will be useful, but "
                 + "WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY "
                 + "or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License "
                 + "for more details: https://www.gnu.org/licenses/gpl-3.0.html",
            FontSize = 11.5,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        Root.Children.Add(UiKit.SectionCard("条款全文", panel, "GPL-3.0"));

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
