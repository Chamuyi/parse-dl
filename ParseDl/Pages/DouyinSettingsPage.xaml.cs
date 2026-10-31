using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.Douyin;

namespace ParseDl.Pages;

/// <summary>
/// 抖音设置页 —— 逐项对齐 Flutter 版 lib/models/douyin_config.dart 的全部配置项，
/// 按「下载 / 抓取 / 滚动 / 筛选 / 命名 / 高级」分组，**每项改动立即写盘**
/// （DouyinSettings.Mutate），不依赖「保存」按钮。
///
/// 与解析页那份紧凑选项是同一份数据：改哪边都即时生效。
/// </summary>
public sealed partial class DouyinSettingsPage : Page
{
    /// <summary>
    /// 抖音侧可用变量（与 Flutter 版 kDouyinTemplateVars 逐条一致：20 个、顺序照抄）。
    /// 元数据取自 DouyinTemplate.Vars（引擎那一份，单一来源），页面不再各写一份文案。
    /// </summary>
    private static readonly TemplateVarInfo[] DouyinVars = DouyinTemplate.Vars
        .Select(v => new TemplateVarInfo(v.Name, v.Desc, v.ParamExample, v.ParamDesc))
        .ToArray();

    /// <summary>文件夹模板的「填入默认」值（对齐 Flutter 版 douyin_section 的 onUseDefault）。</summary>
    private const string DefaultDirTpl = "%AUTHOR%";

    /// <summary>变量面板底部的补充提示（对齐 Flutter 版 douyin_section 的 varHint）。</summary>
    private const string VarHintForDirTemplate =
        "提示：文件夹模板建议只用「作者 / 作品」级变量；%MEDIA_INDEX%、%EXT% 这类逐文件变量会让每条媒体各建一个文件夹。";

    /// <summary>预览用的示例作品（同 Flutter 版 douyinExampleMedia 的那组数）。</summary>
    private static readonly DouyinItem ExampleItem = new()
    {
        Id = "7412345678901234567",
        Type = DouyinMediaType.Video,
        Url = "https://v3-web.douyinvod.com/example/media.mp4",
        PostId = "7412345678901234567",
        Text = "傍晚的海边，风把云吹成一条线。#旅行 #vlog",
        CreatedAt = new DateTime(2024, 1, 20, 21, 15, 36),
        UserId = "1234567890123456",
        UserName = "海边的猫",
        AuthorUniqueId = "haibiandema",
        MediaIndex = 1,
        Width = 1080,
        Height = 1920,
        DurationMs = 45000,
        LikeCount = 12345,
        CommentCount = 678,
        CollectCount = 2345,
        ShareCount = 89,
        Chosen = new DouyinVariant
        {
            Width = 1080,
            Height = 1920,
            Fps = 30,
            Bitrate = 2400000,
            Size = 12582912,
        },
    };

    // 命名模板控件（BuildNamingGroup 里创建；开关回调里要复用它）
    private TemplateEditor? _templateEditor;
    private TemplateField? _dirField;
    private TemplateField? _nameField;

    public DouyinSettingsPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Build();
    }

    private void Build()
    {
        Root.Children.Clear();
        var cfg = DouyinSettings.Current;

        Root.Children.Add(UiKit.PageHeader("抖音设置", "下载 · 抓取 · 滚动 · 筛选 · 命名", "\uE9E9"));

        Root.Children.Add(Group("下载", new (string, string, UIElement)[]
        {
            ("下载源", "指定用哪一路地址（对齐参照实现的 6 个档位）",
                Combo(Enum.GetValues<DouyinSource>().Select(s => s.Label()).ToArray(),
                    (int)cfg.Source, v => Mutate(c => c.Source = (DouyinSource)v))),
            ("质量优先策略", "仅「质量优先」两档生效；权重见 Services/Douyin/DouyinSourceResolver.cs",
                Combo(Enum.GetValues<DouyinQualityMode>().Select(m => m.Label()).ToArray(),
                    (int)cfg.QualityMode, v => Mutate(c => c.QualityMode = (DouyinQualityMode)v))),
            ("图片格式偏好", "「其它格式优先」把非 webp 的镜像排到前面（不改 URL）",
                Combo(Enum.GetValues<DouyinImageFormat>().Select(f => f.Label()).ToArray(),
                    (int)cfg.ImageFormat, v => Mutate(c => c.ImageFormat = (DouyinImageFormat)v))),
            ("过滤低画质", "滤掉档位名含 low 的变体",
                Toggle(cfg.FilterLowQuality, v => Mutate(c => c.FilterLowQuality = v))),
            ("排除 ByteVC1", "ByteVC1 兼容性差；「兼容性+质量优先」档强制排除",
                Toggle(cfg.FilterByteVc1, v => Mutate(c => c.FilterByteVc1 = v))),
            ("下载配套视频", "图文作品的实况图额外下载配对视频",
                Toggle(cfg.IncludeLivePhoto, v => Mutate(c => c.IncludeLivePhoto = v))),
            ("下载配套图片", "实况图的静态图是否也下载；关掉则只下配套视频。图片与视频两个开关互不影响",
                Toggle(cfg.IncludeLiveImage, v => Mutate(c => c.IncludeLiveImage = v))),
            // 用户 2026-10-27：小米手机上要能直接看动图（动态照片 = 单个 jpg 内嵌 mp4）
            ("合成实况图（单个 jpg）", "把实况图合成一个 jpg（小米/安卓动态照片），手机上直接看动图",
                Toggle(cfg.LivePhotoAsMotionPhoto, v => Mutate(c => c.LivePhotoAsMotionPhoto = v))),
            ("附带 BGM", "图文作品附带下载 BGM（按地址在整批内去重）",
                Toggle(cfg.IncludeBgm, v => Mutate(c => c.IncludeBgm = v))),
            ("跳过已下载", "按作品粒度台账跳过（推荐开着）",
                Toggle(cfg.SkipDownloaded, v => Mutate(c => c.SkipDownloaded = v))),
            ("按作品聚合", "同一作品的多个媒体排在连续位置",
                Toggle(cfg.GroupByAweme, v => Mutate(c => c.GroupByAweme = v))),
            ("时长筛选", "只影响视频本身的时长（图片不受影响）",
                Toggle(cfg.TimeRangeEnabled, v => Mutate(c => c.TimeRangeEnabled = v))),
            ("时长下限（秒）", "小于这个时长的视频跳过",
                Number(cfg.TimeStartSec, 0, 100000, v => Mutate(c => c.TimeStartSec = (int)v))),
            ("时长上限（秒）", "大于这个时长的视频跳过",
                Number(cfg.TimeEndSec, 0, 100000, v => Mutate(c => c.TimeEndSec = (int)v))),
            ("aria2 并发数", "对齐参照实现的 limit（默认 4；实际并发还受全局上限约束）",
                Number(cfg.Concurrency, 1, 16, v => Mutate(c => c.Concurrency = (int)v))),
            ("自定义文本", "%CUSTOM_TEXT% 的输出内容",
                Text(cfg.CustomText, v => Mutate(c => c.CustomText = v))),
        }));

        Root.Children.Add(Group("抓取", new (string, string, UIElement)[]
        {
            ("每批数量", "一次处理多少条",
                Number(cfg.BatchSize, 1, 500, v => Mutate(c => c.BatchSize = (int)v))),
            ("请求间隔（毫秒）", "太小容易触发限流",
                Number(cfg.RequestIntervalMs, 200, 10000, v => Mutate(c => c.RequestIntervalMs = (int)v))),
        }));

        Root.Children.Add(Group("滚动抓取", new (string, string, UIElement)[]
        {
            ("每次滚动像素", "模拟真人滚动的步长",
                Number(cfg.ScrollStepPx, 100, 3000, v => Mutate(c => c.ScrollStepPx = (int)v))),
            ("滚动间隔（毫秒）", "两轮之间给页面留的加载时间",
                Number(cfg.ScrollIntervalMs, 200, 10000, v => Mutate(c => c.ScrollIntervalMs = (int)v))),
            ("每个目标最多滚几轮", "一轮 = 把页面直接跳到底一次；作品上千的大号可调高",
                Number(cfg.MaxRounds, 1, 200, v => Mutate(c => c.MaxRounds = (int)v))),
            ("判定「到底」的连续轮数", "连续这么多轮页面高度没变才算到底（默认 6，约 4 秒）",
                Number(cfg.StallLimit, 1, 30, v => Mutate(c => c.StallLimit = (int)v))),
        }));

        Root.Children.Add(Group("筛选默认值", new (string, string, UIElement)[]
        {
            ("关键词", "进页面时的默认筛选关键词",
                Text(cfg.FilterKeyword, v => Mutate(c => c.FilterKeyword = v))),
            ("日期范围", "按发布时间筛",
                Combo(Enum.GetValues<DouyinDateRange>().Select(r => r.Label()).ToArray(),
                    (int)cfg.FilterDateRange, v => Mutate(c => c.FilterDateRange = (DouyinDateRange)v))),
            ("最短时长（秒）", "0 或留空 = 不限",
                Number(cfg.FilterMinDurationSec ?? 0, 0, 100000,
                    v => Mutate(c => c.FilterMinDurationSec = v > 0 ? (int)v : null))),
            ("最长时长（秒）", "0 = 不限",
                Number(cfg.FilterMaxDurationSec ?? 0, 0, 100000,
                    v => Mutate(c => c.FilterMaxDurationSec = v > 0 ? (int)v : null))),
            ("标签匹配", "多个标签时是「任一」还是「全部」命中",
                Combo(new[] { DouyinTagMode.Any.Label(), DouyinTagMode.All.Label() },
                    cfg.FilterTagMode == DouyinTagMode.All ? 1 : 0,
                    v => Mutate(c => c.FilterTagMode = v == 1 ? DouyinTagMode.All : DouyinTagMode.Any))),
        }));

        Root.Children.Add(BuildNamingGroup(cfg));
        Root.Children.Add(BuildAdvancedGroup());

        Root.Children.Add(new TextBlock
        {
            Text = "设置已实时保存到 " + DouyinSettings.FilePath,
            FontSize = 12,
            Opacity = 0.55,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 4, 0, 0),
        });
    }

    private static void Mutate(Action<DouyinConfig> change) => DouyinSettings.Mutate(change);

    /// <summary>
    /// 文件夹模板的输出示例：只做变量展开、不做整串清洗（与 Flutter 版
    /// douyin_section 的 example: resolveVariables(...) 同口径 —— 目录名不是文件名，
    /// 清掉 / 就没法演示多级目录了）。
    /// </summary>
    private static string RenderDirTemplate(string template)
        => DouyinTemplate.Expand(template, ExampleItem).Trim();

    /// <summary>
    /// 文件名模板的输出示例：展开 + 抖音侧整串清洗，与真正下载走**同一条**路径
    /// （DouyinTemplate.BuildTarget 里的 FileNameTemplate.DouyinFilenamify），
    /// 所以「输出示例」与落盘名字不可能漂移。
    /// </summary>
    private static string RenderNameTemplate(string template)
        => FileNameTemplate.DouyinFilenamify(
            DouyinTemplate.Expand(template, ExampleItem).Trim(), ExampleItem.Id);

    // ── 命名 ───────────────────────────────────────────────────

    private UIElement BuildNamingGroup(DouyinConfig cfg)
    {
        var panel = new StackPanel { Spacing = 10 };

        // 保存根目录
        var dirGrid = new Grid { ColumnSpacing = 8 };
        dirGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        dirGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var dirTexts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        dirTexts.Children.Add(new TextBlock { Text = "保存目录", FontSize = 14 });
        dirTexts.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(cfg.SaveDirBase)
                ? "留空 = 用默认目录（数据目录\\downloads）"
                : cfg.SaveDirBase,
            FontSize = 12,
            Opacity = 0.6,
            TextWrapping = TextWrapping.Wrap,
        });
        dirGrid.Children.Add(dirTexts);

        var dirButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var pickBtn = new Button { Content = "选择文件夹", MinWidth = 100 };
        pickBtn.Click += async (_, _) =>
        {
            var folder = await FolderPickerService.PickAsync(cfg.SaveDirBase);
            if (folder is null) return;
            Mutate(c => c.SaveDirBase = folder);
            Build();
        };
        var clearBtn = new Button { Content = "清除", MinWidth = 70 };
        clearBtn.Click += (_, _) => { Mutate(c => c.SaveDirBase = ""); Build(); };
        dirButtons.Children.Add(pickBtn);
        dirButtons.Children.Add(clearBtn);
        Grid.SetColumn(dirButtons, 1);
        dirGrid.Children.Add(dirButtons);
        panel.Children.Add(dirGrid);

        panel.Children.Add(Row("启用保存文件夹", "开 = 按文件夹模板建子目录；关 = 全部平铺在保存目录里",
            Toggle(cfg.EnableSaveFolder, v =>
            {
                Mutate(c => c.EnableSaveFolder = v);
                // 重建一次：文件夹模板的可用性与空提示文案都跟着这个开关走
                // （对齐 Flutter 版 TemplateRow 的 enabled + emptyHint 两条）
                Build();
            })));

        // 「启用模版」预设
        var presetRow = new Grid { ColumnSpacing = 8 };
        presetRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        presetRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var presetTexts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        presetTexts.Children.Add(new TextBlock { Text = "启用模版", FontSize = 14 });
        presetTexts.Children.Add(new TextBlock
        {
            Text = "一键把文件夹模板 + 文件模板填成现成组合（之后仍可手动微调）",
            FontSize = 12,
            Opacity = 0.6,
            TextWrapping = TextWrapping.Wrap,
        });
        presetRow.Children.Add(presetTexts);

        var presetCombo = new ComboBox { MinWidth = 260 };
        var presetIds = new List<string>();
        foreach (var p in DouyinTemplate.Presets)
        {
            presetCombo.Items.Add(p.Label);
            presetIds.Add(p.Id);
        }
        presetCombo.Items.Add("自定义");
        presetIds.Add(DouyinTemplate.CustomPresetId);

        var currentPreset = DouyinTemplate.PresetIdOf(cfg.DirTemplate, cfg.FileNameTemplate);
        var presetIndex = presetIds.IndexOf(currentPreset);
        presetCombo.SelectedIndex = presetIndex >= 0 ? presetIndex : presetIds.Count - 1;
        presetCombo.SelectionChanged += (_, _) =>
        {
            var i = presetCombo.SelectedIndex;
            if (i < 0 || i >= DouyinTemplate.Presets.Count) return;
            var p = DouyinTemplate.Presets[i];
            Mutate(c =>
            {
                c.DirTemplate = p.DirTemplate;
                c.FileNameTemplate = p.FileNameTemplate;
            });
            Build();
        };
        Grid.SetColumn(presetCombo, 1);
        presetRow.Children.Add(presetCombo);
        panel.Children.Add(presetRow);

        // ── 命名模板：与 X 设置页同一份控件（Controls/TemplateEditor.cs）──
        //
        // 对齐 Flutter 版 lib/widgets/douyin_section.dart 的两个 TemplateRow：
        // 文件夹模板（受「启用保存文件夹」开关约束）与文件名模板各自带
        // 「填入默认」与「输出示例」；「可用变量」面板只有一份，点「插入」插到
        // **当前正在编辑的那个框**。
        panel.Children.Add(new TextBlock
        {
            Text = "命名模板",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 4, 0, 0),
        });

        _templateEditor = new TemplateEditor(DouyinVars, VarHintForDirTemplate);

        _dirField = _templateEditor.AddField(new TemplateFieldOptions
        {
            Label = "文件夹模板",
            Hint = DefaultDirTpl,
            DefaultTemplate = DefaultDirTpl,
            EmptyHint = cfg.EnableSaveFolder
                ? "留空则直接存到保存目录下"
                : "「启用保存文件夹」已关闭 —— 文件全部平铺在保存目录下",
            Preview = RenderDirTemplate,
            Enabled = cfg.EnableSaveFolder,
        }, cfg.DirTemplate);

        _nameField = _templateEditor.AddField(new TemplateFieldOptions
        {
            Label = "文件名模板",
            Hint = DouyinTemplate.DefaultFileNameTemplate,
            DefaultTemplate = DouyinTemplate.DefaultFileNameTemplate,
            EmptyHint = "留空则使用「媒体ID_时间戳.扩展名」",
            Preview = RenderNameTemplate,
        }, cfg.FileNameTemplate);

        _templateEditor.FieldChanged += (_, e) =>
        {
            if (ReferenceEquals(e.Field, _dirField)) Mutate(c => c.DirTemplate = e.Value);
            else if (ReferenceEquals(e.Field, _nameField)) Mutate(c => c.FileNameTemplate = e.Value);
        };
        panel.Children.Add(_templateEditor);

        panel.Children.Add(new TextBlock
        {
            Text = "模板改动会自动保存",
            FontSize = 11.5,
            Opacity = 0.55,
            TextWrapping = TextWrapping.Wrap,
        });

        return UiKit.SectionCard("命名", panel);
    }

    // ── 高级 ───────────────────────────────────────────────────

    private UIElement BuildAdvancedGroup()
    {
        var panel = new StackPanel { Spacing = 10 };
        var ledger = DouyinStore.Instance.Ledger;
        ledger.Load();

        panel.Children.Add(new TextBlock
        {
            Text = "已下载台账：" + ledger.DoneCount + " 个作品（按作品粒度，跳过已下载就查它）",
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "台账文件：" + ledger.FilePath,
            FontSize = 12,
            Opacity = 0.6,
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.Wrap,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "设置文件：" + DouyinSettings.FilePath,
            FontSize = 12,
            Opacity = 0.6,
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.Wrap,
        });

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var clearBtn = new Button { Content = "清除下载记录", MinWidth = 120 };
        var status = new TextBlock { FontSize = 12, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center };
        clearBtn.Click += (_, _) =>
        {
            var ok = ledger.Clear();
            status.Text = ok ? "已清除" : "清除失败（写盘出错，详见日志）";
            Build();
        };
        row.Children.Add(clearBtn);
        row.Children.Add(status);
        panel.Children.Add(row);

        return UiKit.SectionCard("高级", panel);
    }

    // ── 控件工厂（设置项开关必须与标题同行）────────────────────

    private static UIElement Row(string label, string hint, UIElement control)
    {
        var grid = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var texts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(new TextBlock { Text = label, FontSize = 14 });
        texts.Children.Add(new TextBlock { Text = hint, FontSize = 12, Opacity = 0.6, TextWrapping = TextWrapping.Wrap });
        grid.Children.Add(texts);

        var fe = (FrameworkElement)control;
        fe.VerticalAlignment = VerticalAlignment.Center;
        if (fe.MinWidth == 0) fe.MinWidth = 200;
        Grid.SetColumn(fe, 1);
        grid.Children.Add(fe);
        return grid;
    }

    private static Border Group(string title, (string Label, string Hint, UIElement Control)[] rows)
    {
        var stack = new StackPanel { Spacing = 0 };
        foreach (var (label, hint, control) in rows)
            stack.Children.Add(Row(label, hint, control));
        return UiKit.SectionCard(title, stack);
    }

    private static ToggleSwitch Toggle(bool value, Action<bool> onChange)
    {
        var t = new ToggleSwitch { IsOn = value, MinWidth = 0 };
        t.Toggled += (_, _) => onChange(t.IsOn);
        return t;
    }

    private static TextBox Text(string value, Action<string> onChange, double minWidth = 220)
    {
        var box = new TextBox { Text = value, MinWidth = minWidth };
        box.TextChanged += (_, _) => onChange(box.Text ?? "");
        return box;
    }

    private static NumberBox Number(double value, double min, double max, Action<double> onChange)
    {
        var n = new NumberBox
        {
            Value = value,
            Minimum = min,
            Maximum = max,
            MinWidth = 160,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
        };
        n.ValueChanged += (_, e) =>
        {
            if (!double.IsNaN(e.NewValue)) onChange(e.NewValue);
        };
        return n;
    }

    private static ComboBox Combo(string[] items, int selected, Action<int> onChange)
    {
        var c = new ComboBox { MinWidth = 260 };
        foreach (var i in items) c.Items.Add(i);
        c.SelectedIndex = selected >= 0 && selected < items.Length ? selected : 0;
        c.SelectionChanged += (_, _) =>
        {
            if (c.SelectedIndex >= 0) onChange(c.SelectedIndex);
        };
        return c;
    }
}
