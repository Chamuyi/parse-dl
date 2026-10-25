using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;

namespace ParseDl.Pages;

/// <summary>
/// 全局设置 —— 左侧分类 + 右侧内容。
///
/// ### 为什么改成分组式
/// 原来是一列平铺的五张卡（材质 / 主题 / 下载 / 日志 / 数据目录），
/// 设置项一多就只能往下滚，且「找一个设置」要在整页里肉眼扫。
/// 现在左侧固定六个分类，右侧只渲染当前分类的内容 —— 一屏之内看完一类。
///
/// ### 分类与 Flutter 版的对应
/// Flutter 版（lib/pages/settings_page.dart 的 global 分支）是双栏平铺：
/// 左栏 外观 + 代理，右栏 下载 + 应用。分类维度相同，只是这里改成单选切换。
/// 分类：外观（材质 / 深浅 / 主题色 / 导航形态）/ 下载 / 代理 / 日志 / 数据目录 / 关于。
///
/// ### 硬性约定
/// 设置项开关必须与标题**同行**、水平距离 ≤24px（用户 2026-09-30 约定）。
/// 本页所有开关都走 [SettingRows.Switch]，间距固定 8px。
/// </summary>
public sealed partial class SettingsPage : Page
{
    private MainWindow? _host;
    private bool _suppressThemeEvent;
    private bool _suppressMaterialEvent;

    /// <summary>左侧分类项。</summary>
    private sealed record Category(string Id, string Label, string Glyph);

    private static readonly Category[] Categories =
    {
        new("appearance", "外观", "\uE790"),
        new("download", "下载", "\uE896"),
        new("proxy", "代理", "\uE774"),
        new("logs", "日志", "\uE9D9"),
        new("data", "数据目录", "\uE8B7"),
        new("about", "关于", "\uE946"),
    };

    private static readonly (MaterialKind Kind, string Label, string Hint)[] Materials =
    {
        (MaterialKind.Mica, "Mica", "柔和云母 —— 长驻窗口的基础层"),
        (MaterialKind.MicaAlt, "Mica Alt", "层次云母 —— 带标签页的窗口"),
        (MaterialKind.Acrylic, "Acrylic", "磨砂玻璃 —— 半透明"),
        (MaterialKind.AcrylicThin, "Acrylic Thin", "更透亮的磨砂"),
    };

    private string _currentCategory = "appearance";
    private bool _built;

    public SettingsPage()
    {
        InitializeComponent();
        BuildCategoryList();
        Loaded += (_, _) => { if (!_built) RenderCategory(_currentCategory); };
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _host = e.Parameter as MainWindow;
        _built = false;
        RenderCategory(_currentCategory);
    }

    // ── 左侧分类 ────────────────────────────────────────────

    private void BuildCategoryList()
    {
        // 用 Items.Add 而不是 ItemsSource：直接塞 ListViewItem 进 ItemsSource 会让
        // 生成器多套一层容器，选中态与自动化名称都容易错位。Items 是容器集合，语义明确。
        foreach (var c in Categories)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            row.Children.Add(new FontIcon { Glyph = c.Glyph, FontSize = 15, VerticalAlignment = VerticalAlignment.Center });
            row.Children.Add(new TextBlock { Text = c.Label, FontSize = 14, VerticalAlignment = VerticalAlignment.Center });

            var item = new ListViewItem { Content = row, Tag = c.Id, Padding = new Thickness(10, 8, 10, 8) };
            AutomationProperties.SetName(item, "settings-category-" + c.Id);
            CategoryList.Items.Add(item);
        }
        CategoryList.SelectedIndex = 0;
    }

    private void OnCategoryChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CategoryList.SelectedItem is not ListViewItem item) return;
        if (item.Tag is not string id) return;
        _currentCategory = id;
        RenderCategory(id);
    }

    private void RenderCategory(string id)
    {
        if (ContentRoot is null) return;
        ContentRoot.Children.Clear();

        var c = Array.Find(Categories, x => x.Id == id) ?? Categories[0];
        ContentRoot.Children.Add(UiKit.PageHeader(c.Label + "设置", SubtitleOf(id), c.Glyph));

        switch (id)
        {
            case "appearance":
                ContentRoot.Children.Add(BuildAppearance());
                break;
            case "download":
                ContentRoot.Children.Add(BuildDownload());
                break;
            case "proxy":
                ContentRoot.Children.Add(BuildProxy());
                break;
            case "logs":
                ContentRoot.Children.Add(BuildLogs());
                break;
            case "data":
                ContentRoot.Children.Add(BuildDataDir());
                break;
            default:
                ContentRoot.Children.Add(BuildAbout());
                break;
        }
        _built = true;
    }

    private static string SubtitleOf(string id) => id switch
    {
        "appearance" => "窗口材质 · 明暗 · 主题色 · 导航形态",
        "download" => "保存目录 · 并发 · 模板 · 日志开关",
        "proxy" => "代理地址与系统代理",
        "logs" => "运行日志与排障",
        "data" => "设置文件与下载落点",
        _ => "版本与许可",
    };

    // ── 外观 ────────────────────────────────────────────────

    private UIElement BuildAppearance()
    {
        var panel = new StackPanel { Spacing = 16 };

        // ① 窗口材质：四档分段单选
        var materialPanel = new StackPanel { Spacing = 6 };
        var group = "material-" + Guid.NewGuid().ToString("N");
        _suppressMaterialEvent = true;
        foreach (var (kind, label, hint) in Materials)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var rb = new RadioButton
            {
                Content = label,
                GroupName = group,
                Tag = kind,
                MinWidth = 130,
                IsChecked = _host is not null && kind == _host.CurrentMaterial,
            };
            AutomationProperties.SetName(rb, "material-" + kind);
            rb.Checked += OnMaterialChecked;
            row.Children.Add(rb);
            row.Children.Add(new TextBlock { Text = hint, FontSize = 12, Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center });
            materialPanel.Children.Add(row);
        }
        _suppressMaterialEvent = false;
        panel.Children.Add(SettingRows.Card("窗口材质",
            "四档全部由 Windows App SDK 官方合成控制器绘制",
            materialPanel));

        // ② 明暗
        var themeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var tg = "theme-" + Guid.NewGuid().ToString("N");
        var darkRadio = new RadioButton { Content = "深色", GroupName = tg, Tag = true, MinWidth = 100 };
        var lightRadio = new RadioButton { Content = "浅色", GroupName = tg, Tag = false, MinWidth = 100 };
        AutomationProperties.SetName(darkRadio, "theme-dark");
        AutomationProperties.SetName(lightRadio, "theme-light");
        _suppressThemeEvent = true;
        var isDark = _host?.IsDarkTheme ?? AppSettings.Instance.IsDark;
        darkRadio.IsChecked = isDark;
        lightRadio.IsChecked = !isDark;
        _suppressThemeEvent = false;
        darkRadio.Checked += OnThemeChecked;
        lightRadio.Checked += OnThemeChecked;
        themeRow.Children.Add(darkRadio);
        themeRow.Children.Add(lightRadio);
        panel.Children.Add(SettingRows.Card("明暗", "切换后材质会带着真实主题重新应用", themeRow));

        // ③ 主题色（如实说明当前实现）
        var accentNote = new StackPanel { Spacing = 6 };
        accentNote.Children.Add(SettingRows.Description(
            "WinUI 版的强调色目前直接取 Windows 系统强调色（个性化 → 颜色），没有独立的三档选择器。" +
            "原 Flutter 版的 Windows 蓝 / 紫罗兰 / 跟随系统三选一尚未移植 —— 需要改 App.xaml 的资源字典，" +
            "不在本页可改的范围内，所以这里如实标注而不是摆一个点了没反应的选项。"));
        accentNote.Children.Add(BuildColorPreview());
        panel.Children.Add(SettingRows.Card("主题色", "按钮、选中态与链接用的强调色", accentNote));

        // ④ 导航形态（同上）
        var navNote = new StackPanel { Spacing = 6 };
        navNote.Children.Add(SettingRows.Description(
            "WinUI 版目前固定为左侧导航栏（NavigationView，PaneDisplayMode=Left）。" +
            "原 Flutter 版的「底部悬浮 Dock / 常规侧边栏」二选一尚未移植 —— 切换要改 MainWindow 的 NavigationView，" +
            "不在本页可改的范围内。"));
        panel.Children.Add(SettingRows.Card("导航形态", "左侧栏 / 悬浮 Dock", navNote));

        return panel;
    }

    private static UIElement BuildColorPreview()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var key in new[] { "AccentFillColorDefaultBrush", "AccentFillColorSecondaryBrush", "AccentFillColorTertiaryBrush" })
        {
            if (Application.Current.Resources.TryGetValue(key, out var brush) && brush is Brush b)
            {
                row.Children.Add(new Border
                {
                    Width = 48, Height = 24, CornerRadius = new CornerRadius(4),
                    Background = b, BorderBrush = SettingRows.CardBorder, BorderThickness = new Thickness(1),
                });
            }
        }
        row.Children.Add(new TextBlock { Text = "系统强调色", FontSize = 12, Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center });
        return row;
    }

    private void OnMaterialChecked(object sender, RoutedEventArgs e)
    {
        if (_suppressMaterialEvent) return;
        if (sender is not RadioButton rb || rb.Tag is not MaterialKind kind) return;
        if (_host is null) return;
        _host.ApplyMaterial(kind, _host.IsDarkTheme);
    }

    private void OnThemeChecked(object sender, RoutedEventArgs e)
    {
        if (_suppressThemeEvent || _host is null) return;
        if (sender is not RadioButton rb || rb.Tag is not bool dark) return;
        // 改 RootGrid.RequestedTheme 而不是直接调材质：MainWindow 订阅了
        // ActualThemeChanged，会带着真实主题重新 Apply，界面与材质才一致。
        _host.ApplyTheme(dark);
    }

    // ── 下载 ────────────────────────────────────────────────

    private UIElement BuildDownload()
    {
        var cfg = AppSettings.Instance;
        var panel = new StackPanel { Spacing = 16 };

        var dirPanel = new StackPanel { Spacing = 8 };
        var dirRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var dirBox = new TextBox
        {
            Text = cfg.SaveDirBase,
            IsReadOnly = true,
            MinWidth = 340,
            PlaceholderText = "未选择（用默认目录）",
        };
        dirRow.Children.Add(dirBox);
        var status = new TextBlock { Text = "", FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };

        var pick = new Button { Content = "选择文件夹" };
        pick.Click += async (_, _) =>
        {
            try
            {
                var folder = await FolderPickerService.PickAsync();
                if (folder is null) return;
                var (ok, msg) = FolderPickerService.VerifyWritable(folder.Path);
                if (!ok) { status.Text = "❌ 该目录不可写：" + msg; return; }
                cfg.SaveDirBase = folder.Path;
                cfg.Save();
                dirBox.Text = folder.Path;
                status.Text = "✅ 已保存，立即生效";
            }
            catch (Exception ex)
            {
                status.Text = "❌ 选择失败：" + ex.GetType().Name + " " + ex.Message;
            }
        };
        dirRow.Children.Add(pick);

        var clear = new Button { Content = "清除" };
        clear.Click += (_, _) =>
        {
            cfg.SaveDirBase = "";
            cfg.Save();
            dirBox.Text = "";
            status.Text = "已清除，改用默认目录（数据目录\\downloads）";
        };
        dirRow.Children.Add(clear);
        dirPanel.Children.Add(dirRow);
        dirPanel.Children.Add(status);
        panel.Children.Add(SettingRows.Card("保存目录", "留空则使用 数据目录\\downloads", dirPanel));

        var dl = new StackPanel { Spacing = 16 };
        dl.Children.Add(SettingRows.Number("并发上限",
            "aria2 同时下载的任务数（1-16）",
            cfg.MaxConcurrent, 1, 16,
            v => { cfg.MaxConcurrent = (int)v; cfg.Save(); }));
        dl.Children.Add(SettingRows.Number("请求间隔（毫秒）",
            "每次接口请求之间的间隔，太小容易触发限流",
            cfg.RequestIntervalMs, 200, 10000,
            v => { cfg.RequestIntervalMs = (int)v; cfg.Save(); }));
        dl.Children.Add(SettingRows.Number("每批数量",
            "一次加载多少条",
            cfg.BatchSize, 1, 500,
            v => { cfg.BatchSize = (int)v; cfg.Save(); }));
        dl.Children.Add(SettingRows.Switch("跳过同名文件",
            "按模板算出的完整路径已存在则跳过，不重新下载",
            cfg.SameFileSkip,
            v => { cfg.SameFileSkip = v; cfg.Save(); }));
        panel.Children.Add(SettingRows.Card("下载引擎", "并发 · 间隔 · 跳过策略", dl));

        var tplPanel = new StackPanel { Spacing = 8 };
        var tplBox = new TextBox
        {
            Text = cfg.FileNameTemplate,
            FontFamily = new FontFamily("Consolas"),
            PlaceholderText = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%",
        };
        var preview = new TextBlock { Text = "", FontSize = 12, FontFamily = new FontFamily("Consolas"), TextWrapping = TextWrapping.Wrap, Opacity = 0.8 };
        void Update()
        {
            cfg.FileNameTemplate = tplBox.Text ?? "";
            cfg.Save();
            preview.Text = PreviewOf(cfg.FileNameTemplate);
        }
        tplBox.TextChanged += (_, _) => Update();
        tplPanel.Children.Add(tplBox);
        tplPanel.Children.Add(new TextBlock
        {
            Text = "变量：%POST_TIME% %USER_SCREEN_NAME% %POST_ID% %MEDIA_INDEX% %EXT% 等，各模块设置页里列出完整清单。",
            FontSize = 12, Opacity = 0.62, TextWrapping = TextWrapping.Wrap,
        });
        tplPanel.Children.Add(new TextBlock { Text = "输出示例", FontSize = 12, Opacity = 0.6 });
        tplPanel.Children.Add(preview);
        panel.Children.Add(SettingRows.Card("默认文件名模板", "各模块没有单独设置时使用", tplPanel));
        Update();

        return panel;
    }

    private static string PreviewOf(string template)
    {
        var ctx = new TemplateContext
        {
            PostId = "1734567890123456789",
            PostTime = new DateTime(2024, 1, 20, 21, 15, 36),
            UserId = "1234567890",
            UserName = "示例作者",
            UserScreenName = "example_user",
            MediaId = "1734567890123456799",
            MediaType = "image",
            Extension = ".jpg",
            MediaIndex = 1,
            MediaCount = 4,
            Content = "示例推文正文",
        };
        var s = FileNameTemplate.Resolve(template ?? "", ctx).Trim();
        return s.Length == 0 ? "（模板为空，将回退为 媒体ID_时间戳.扩展名）" : s;
    }

    // ── 代理 ────────────────────────────────────────────────

    private UIElement BuildProxy()
    {
        var cfg = AppSettings.Instance;
        var panel = new StackPanel { Spacing = 16 };

        panel.Children.Add(SettingRows.Switch("启用代理",
            "关闭后所有接口请求直连",
            cfg.ProxyEnable,
            v => { cfg.ProxyEnable = v; cfg.Save(); }));

        panel.Children.Add(SettingRows.Switch("使用系统代理",
            "读 Windows「Internet 选项」里的代理设置；关闭后使用下面填的地址",
            cfg.ProxyUseSystem,
            v => { cfg.ProxyUseSystem = v; cfg.Save(); }));

        var urlBox = new TextBox
        {
            Text = cfg.ProxyUrl,
            PlaceholderText = "http://127.0.0.1:7890",
            FontFamily = new FontFamily("Consolas"),
        };
        var urlStatus = new TextBlock { Text = "", FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
        urlBox.TextChanged += (_, _) =>
        {
            cfg.ProxyUrl = urlBox.Text ?? "";
            cfg.Save();
            var empty = cfg.ProxyEnable && !cfg.ProxyUseSystem && cfg.ProxyUrl.Trim().Length == 0;
            urlStatus.Text = empty ? "❌ 启用代理且不用系统代理时，地址必填" : "";
        };
        panel.Children.Add(SettingRows.Row("代理地址", "形如 http://127.0.0.1:7890；不用系统代理时必填。", urlBox));
        panel.Children.Add(urlStatus);

        return SettingRows.Card("代理", "接口请求走哪条线路", panel);
    }

    // ── 日志 ────────────────────────────────────────────────

    private UIElement BuildLogs()
    {
        var cfg = AppSettings.Instance;
        var panel = new StackPanel { Spacing = 16 };

        panel.Children.Add(SettingRows.Switch("写运行日志",
            "关掉可减少磁盘写入（下载引擎的逐任务日志随之停止）",
            cfg.WriteLogs,
            v => { cfg.WriteLogs = v; cfg.Save(); }));

        var logDir = Path.Combine(AppPaths.DataDir, "logs");
        var info = new StackPanel { Spacing = 6 };
        info.Children.Add(new TextBlock
        {
            Text = logDir,
            FontSize = 12,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        info.Children.Add(SettingRows.Description(Directory.Exists(logDir)
            ? "该目录已存在。"
            : "该目录尚未创建 —— 还没有产生过日志。"));
        var open = new Button { Content = "打开日志目录" };
        open.Click += (_, _) => OpenInExplorer(logDir);
        info.Children.Add(open);
        panel.Children.Add(SettingRows.Card("日志", "运行日志落点", info));

        return panel;
    }

    // ── 数据目录 ────────────────────────────────────────────

    private UIElement BuildDataDir()
    {
        var panel = new StackPanel { Spacing = 16 };

        var dataPanel = new StackPanel { Spacing = 8 };
        dataPanel.Children.Add(new TextBlock
        {
            Text = AppPaths.DataDir,
            FontSize = 13,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        dataPanel.Children.Add(SettingRows.Description(
            "数据跟着软件走：默认在 exe 同级的 userdata\\ 下；安装到不可写位置时退到 LocalAppData\\ParseDl。"));
        var openData = new Button { Content = "打开数据目录" };
        openData.Click += (_, _) => OpenInExplorer(AppPaths.DataDir);
        dataPanel.Children.Add(openData);
        panel.Children.Add(SettingRows.Card("数据目录", "设置、台账与下载记录都存这里", dataPanel));

        var filePanel = new StackPanel { Spacing = 6 };
        filePanel.Children.Add(new TextBlock
        {
            Text = AppSettings.Instance.FilePath,
            FontSize = 12,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        var exists = File.Exists(AppSettings.Instance.FilePath);
        filePanel.Children.Add(SettingRows.Description(exists
            ? "设置文件已存在。"
            : "设置文件尚未生成 —— 还没有改过任何设置。"));
        panel.Children.Add(SettingRows.Card("设置文件", "settings.json", filePanel));

        return panel;
    }

    private static void OpenInExplorer(string path)
    {
        try
        {
            if (!Directory.Exists(path)) Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
        }
        catch
        {
            // 打不开资源管理器不该让页面崩
        }
    }

    // ── 关于 ────────────────────────────────────────────────

    private UIElement BuildAbout()
    {
        var panel = new StackPanel { Spacing = 16 };

        var version = typeof(SettingsPage).Assembly.GetName().Version?.ToString() ?? "未知";
        var info = new StackPanel { Spacing = 6 };
        info.Children.Add(new TextBlock { Text = "parse-dl · WinUI 3 版", FontSize = 14, FontWeight = FontWeights.SemiBold });
        info.Children.Add(SettingRows.Description("版本 " + version));
        info.Children.Add(SettingRows.Description(
            "下载解析工具：X / 抖音 / B 站三个模块各自独立设置，共用同一个 aria2 下载引擎。"));
        var openAbout = new Button { Content = "打开完整关于页" };
        openAbout.Click += (_, _) => _host?.Navigate("about");
        info.Children.Add(openAbout);
        panel.Children.Add(SettingRows.Card("关于", "版本与许可", info));

        return panel;
    }
}
