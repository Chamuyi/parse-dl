using System;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.Bili;

namespace ParseDl.Pages;

/// <summary>模块身份（决定文案、图标与设置存储键）。</summary>
public enum ModuleKind
{
    X,
    Douyin,
    Bili,
}

/// <summary>
/// 模块设置页 —— X 下载设置 / 抖音设置 / B 站设置三页共用。
/// 每项改动**立即写盘**（AppSettings.Save），不依赖"保存"按钮。
/// </summary>
public sealed partial class ModuleSettingsPage : Page
{
    private ModuleKind _kind = ModuleKind.X;

    private sealed record Profile(string Title, string Subtitle, string Glyph, string Key);

    private static Profile ProfileOf(ModuleKind kind) => kind switch
    {
        ModuleKind.X => new Profile("X 下载设置", "命名规则 · 抓取节奏", "\uE9E9", "x"),
        ModuleKind.Douyin => new Profile("抖音设置", "滚动抓取 · 命名", "\uE9E9", "douyin"),
        _ => new Profile("B 站设置", "清晰度 · 音轨 · 命名", "\uE9E9", "bili"),
    };

    public ModuleSettingsPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is ModuleKind k) _kind = k;
        Build();
    }

    private void Build()
    {
        Root.Children.Clear();
        var p = ProfileOf(_kind);
        var s = AppSettings.Instance.ForModule(p.Key);

        Root.Children.Add(UiKit.PageHeader(p.Title, p.Subtitle, p.Glyph));

        Root.Children.Add(Group("下载", new (string, string, UIElement)[]
        {
            ("保存目录", "留空则使用全局默认目录（数据目录\\downloads）",
                TextBoxFor(s.SaveDir, v => { s.SaveDir = v; Save(); }, "如：F:\\下载")),
            ("文件名模板", "支持 %POST_TIME% / %USER_SCREEN_NAME% / %POST_ID% / %MEDIA_INDEX% / %EXT%",
                TextBoxFor(s.FileNameTemplate, v => { s.FileNameTemplate = v; Save(); })),
            ("跳过已下载", "同一作品重复下载时自动跳过",
                ToggleFor(s.SkipDownloaded, v => { s.SkipDownloaded = v; Save(); })),
        }));

        if (_kind == ModuleKind.Bili)
        {
            Root.Children.Add(Group("音视频", new (string, string, UIElement)[]
            {
                ("优先清晰度", "有多档时选哪一档",
                    ComboFor(new[] { "最高", "1080P", "720P", "480P" }, s.PreferredQuality,
                        v => { s.PreferredQuality = v; Save(); })),
                ("下载弹幕", "同时保存弹幕 XML",
                    ToggleFor(s.DownloadDanmaku, v => { s.DownloadDanmaku = v; Save(); })),
                ("仅音频", "只取音轨（适合听歌）",
                    ToggleFor(s.AudioOnly, v => { s.AudioOnly = v; Save(); })),
            }));
        }
        else
        {
            Root.Children.Add(Group("抓取", new (string, string, UIElement)[]
            {
                ("每批数量", "一次加载多少条",
                    NumberFor(s.BatchSize, 1, 500, v => { s.BatchSize = (int)v; Save(); })),
                ("请求间隔（毫秒）", "太小容易触发限流",
                    NumberFor(s.RequestIntervalMs, 200, 10000, v => { s.RequestIntervalMs = (int)v; Save(); })),
            }));
        }

        if (_kind == ModuleKind.Douyin)
        {
            Root.Children.Add(Group("滚动抓取", new (string, string, UIElement)[]
            {
                ("每次滚动像素", "模拟真人滚动的步长",
                    NumberFor(s.ScrollStepPx, 100, 3000, v => { s.ScrollStepPx = (int)v; Save(); })),
                ("滚动间隔（毫秒）", "间隔越短越快，也越容易被限流",
                    NumberFor(s.ScrollIntervalMs, 300, 10000, v => { s.ScrollIntervalMs = (int)v; Save(); })),
            }));
        }

        if (_kind == ModuleKind.Bili)
        {
            Root.Children.Add(BuildLoginCard(s));
        }
        else
        {
            Root.Children.Add(new TextBlock
            {
                Text = "设置已实时保存到 " + AppSettings.Instance.FilePath,
                FontSize = 12,
                Opacity = 0.55,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 4, 0, 0),
            });
        }
    }

    private static void Save() => AppSettings.Instance.Save();

    /// <summary>
    /// B 站登录卡片 —— 扫码登录。
    ///
    /// 为什么放这里：**未登录只能拿 480P**，要 1080P 必须登录。登录态存
    /// ModuleSettings.Cookie，BiliApi 会自动带上它。
    /// </summary>
    private UIElement BuildLoginCard(ModuleSettings s)
    {
        var panel = new StackPanel { Spacing = 10 };

        var status = new TextBlock
        {
            Text = string.IsNullOrEmpty(s.Cookie)
                ? "当前未登录（只能下载 480P 及以下）"
                : "已登录（可下载 1080P 及以上）",
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
        };
        panel.Children.Add(status);

        var qrImage = new Image
        {
            Width = 200, Height = 200,
            HorizontalAlignment = HorizontalAlignment.Left,
            Visibility = Visibility.Collapsed,
        };
        panel.Children.Add(qrImage);

        var hint = new TextBlock
        {
            Text = "",
            FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };
        panel.Children.Add(hint);

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var loginBtn = new Button { Content = "扫码登录", MinWidth = 100 };
        var logoutBtn = new Button { Content = "退出登录", MinWidth = 100 };
        row.Children.Add(loginBtn);
        row.Children.Add(logoutBtn);
        panel.Children.Add(row);

        var cts = new System.Threading.CancellationTokenSource();

        loginBtn.Click += async (_, _) =>
        {
            loginBtn.IsEnabled = false;
            status.Text = "正在获取二维码…";
            try
            {
                var login = new BiliLogin();
                var qr = await login.GenerateQrCodeAsync();

                // 二维码就是一张图片地址，直接给 Image 显示
                qrImage.Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(qr.Url));
                qrImage.Visibility = Visibility.Visible;
                hint.Text = "请用 B 站手机客户端扫码，并在手机上确认登录";
                hint.Visibility = Visibility.Visible;
                status.Text = "等待扫码…";

                var result = await login.WaitAsync(qr.Key, st =>
                {
                    // 状态推到界面 —— 用户要知道「扫了但还没确认」
                    switch (st)
                    {
                        case BiliLoginState.Scanned:
                            status.Text = "已扫码，请在手机上点击确认";
                            break;
                        case BiliLoginState.Expired:
                            status.Text = "二维码已过期，请重新点扫码登录";
                            break;
                    }
                }, cts.Token);

                if (result.State == BiliLoginState.Confirmed && !string.IsNullOrEmpty(result.Cookie))
                {
                    s.Cookie = result.Cookie;
                    Save();
                    status.Text = "登录成功，已保存登录态（可下载 1080P 及以上）";
                    qrImage.Visibility = Visibility.Collapsed;
                    hint.Visibility = Visibility.Collapsed;
                }
                else
                {
                    status.Text = "登录未完成：" + result.State;
                }
            }
            catch (Exception ex)
            {
                status.Text = "登录失败：" + ex.Message;
            }
            finally
            {
                loginBtn.IsEnabled = true;
            }
        };

        logoutBtn.Click += (_, _) =>
        {
            s.Cookie = "";
            Save();
            qrImage.Visibility = Visibility.Collapsed;
            hint.Visibility = Visibility.Collapsed;
            status.Text = "已退出登录（只能下载 480P 及以下）";
        };

        return UiKit.SectionCard("B 站登录", panel, "1080P 及以上需要登录");
    }

    private static TextBox TextBoxFor(string value, Action<string> onChange, string? placeholder = null)
    {
        var box = new TextBox { Text = value, PlaceholderText = placeholder ?? "" };
        box.TextChanged += (_, _) => onChange(box.Text);
        return box;
    }

    private static ToggleSwitch ToggleFor(bool value, Action<bool> onChange)
    {
        var t = new ToggleSwitch { IsOn = value };
        t.Toggled += (_, _) => onChange(t.IsOn);
        return t;
    }

    private static NumberBox NumberFor(double value, double min, double max, Action<double> onChange)
    {
        var n = new NumberBox { Value = value, Minimum = min, Maximum = max, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        n.ValueChanged += (_, e) => { if (!double.IsNaN(e.NewValue)) onChange(e.NewValue); };
        return n;
    }

    private static ComboBox ComboFor(string[] items, string selected, Action<string> onChange)
    {
        var c = new ComboBox { ItemsSource = items };
        c.SelectedIndex = Math.Max(0, Array.IndexOf(items, selected));
        c.SelectionChanged += (_, _) =>
        {
            if (c.SelectedItem is string v) onChange(v);
        };
        return c;
    }

    private static Border Group(string title, (string Label, string Hint, UIElement Control)[] rows)
    {
        var stack = new StackPanel { Spacing = 0 };
        for (var i = 0; i < rows.Length; i++)
        {
            var (label, hint, control) = rows[i];
            var row = new Grid { Margin = new Thickness(0, 8, 0, 8) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var texts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(new TextBlock { Text = label, FontSize = 14 });
            texts.Children.Add(new TextBlock { Text = hint, FontSize = 12, Opacity = 0.6 });
            row.Children.Add(texts);

            var fe = (FrameworkElement)control;
            fe.VerticalAlignment = VerticalAlignment.Center;
            fe.MinWidth = 220;
            Grid.SetColumn(fe, 1);
            row.Children.Add(fe);

            stack.Children.Add(row);
        }
        return UiKit.SectionCard(title, stack);
    }
}