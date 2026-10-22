using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;

namespace ParseDl.Pages;

/// <summary>模块身份（决定文案与图标）。</summary>
public enum ModuleKind
{
    X,
    Douyin,
    Bili,
}

/// <summary>
/// 模块设置页 —— X 下载设置 / 抖音设置 / B 站设置三页共用。
/// 结构照 Flutter 版：页头 + 若干设置组卡片（每项一行：标题 + 说明 + 控件）。
/// </summary>
public sealed partial class ModuleSettingsPage : Page
{
    private ModuleKind _kind = ModuleKind.X;

    private sealed record Profile(string Title, string Subtitle, string Glyph);

    private static Profile ProfileOf(ModuleKind kind) => kind switch
    {
        ModuleKind.X => new Profile("X 下载设置", "代理 · 命名规则 · 并发", "\uE9E9"),
        ModuleKind.Douyin => new Profile("抖音设置", "滚动抓取 · 去重 · 命名", "\uE9E9"),
        _ => new Profile("B 站设置", "清晰度 · 音轨 · 命名", "\uE9E9"),
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
        Root.Children.Add(UiKit.PageHeader(p.Title, p.Subtitle, p.Glyph));

        switch (_kind)
        {
            case ModuleKind.X:
                Root.Children.Add(Group("下载", new (string, string, UIElement)[]
                {
                    ("保存目录", "留空则使用全局设置里的默认目录", new TextBox { PlaceholderText = "如：F:\\X媒体" }),
                    ("文件名模板", "支持 %USER_SCREEN_NAME% / %POST_ID% / %MEDIA_INDEX%", new TextBox { Text = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%" }),
                    ("跳过已下载", "同一作品重复下载时自动跳过", new ToggleSwitch { IsOn = true }),
                }));
                Root.Children.Add(Group("抓取", new (string, string, UIElement)[]
                {
                    ("每批数量", "一次加载多少条作品", new NumberBox { Value = 50, Minimum = 1, Maximum = 500 }),
                    ("请求间隔（毫秒）", "太小容易触发限流", new NumberBox { Value = 800, Minimum = 200, Maximum = 10000 }),
                }));
                break;

            case ModuleKind.Douyin:
                Root.Children.Add(Group("下载", new (string, string, UIElement)[]
                {
                    ("保存目录", "留空则使用全局设置里的默认目录", new TextBox { PlaceholderText = "如：F:\\抖音" }),
                    ("文件名模板", "支持 %POST_TIME% / %USER_SCREEN_NAME% / %MEDIA_INDEX%", new TextBox { Text = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%" }),
                    ("跳过已下载", "同一作品重复下载时自动跳过", new ToggleSwitch { IsOn = true }),
                }));
                Root.Children.Add(Group("滚动抓取", new (string, string, UIElement)[]
                {
                    ("每次滚动像素", "模拟真人滚动的步长", new NumberBox { Value = 600, Minimum = 100, Maximum = 3000 }),
                    ("滚动间隔（毫秒）", "间隔越短越快，也越容易被限流", new NumberBox { Value = 1200, Minimum = 300, Maximum = 10000 }),
                }));
                break;

            default:
                Root.Children.Add(Group("下载", new (string, string, UIElement)[]
                {
                    ("保存目录", "留空则使用全局设置里的默认目录", new TextBox { PlaceholderText = "如：F:\\B站" }),
                    ("文件名模板", "支持 %POST_TIME% / %USER_SCREEN_NAME% / %MEDIA_INDEX%", new TextBox { Text = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%" }),
                    ("跳过已下载", "同一稿件重复下载时自动跳过", new ToggleSwitch { IsOn = true }),
                }));
                Root.Children.Add(Group("音视频", new (string, string, UIElement)[]
                {
                    ("优先清晰度", "有多档时选哪一档", new ComboBox { ItemsSource = new[] { "最高", "1080P", "720P", "480P" }, SelectedIndex = 0 }),
                    ("下载弹幕", "同时保存弹幕 XML", new ToggleSwitch { IsOn = false }),
                    ("仅音频", "只取音轨（适合听歌）", new ToggleSwitch { IsOn = false }),
                }));
                break;
        }

        Root.Children.Add(new TextBlock
        {
            Text = "提示：WinUI 3 版正在迁移中，本页设置项尚未接入持久化与下载逻辑（界面骨架已就位）。",
            FontSize = 12,
            Opacity = 0.55,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 4, 0, 0),
        });
    }

    /// <summary>一组设置项：每项一行（左标题+说明，右控件）。</summary>
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