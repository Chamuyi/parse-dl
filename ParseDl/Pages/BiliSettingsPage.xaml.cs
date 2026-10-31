using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.Bili;

namespace ParseDl.Pages;

/// <summary>
/// B 站设置页 —— 对照原项目 lib/widgets/bili_section.dart（613 行，B 站设置面板）
/// 与 lib/models/bili_config.dart（690 行）把配置项补齐。
///
/// 与原项目一致的分组顺序（用户按这个顺序找东西）：
///  画质与编码 → 容器与合并 → 附加文件 → 弹幕/字幕样式 → 自定义文本
///  → 保存与命名（含「启用保存文件夹」+「启用模版」预设）→ 命名模板（可展开变量面板）
///  → 节奏 → 登录 → 合并工具。
///
/// 三条与 Flutter 版刻意对齐的交互：
///  1. **开关与标题同行**（用户 2026-09-30 约定：距离 ≤24px，不许推到行尾）；
///  2. **变量面板可展开**，点变量把 token 插到**当前聚焦的模板框**光标处；
///  3. 「把字幕内封进容器」这类**有前置条件**的开关，必须在说明里写明缺哪一条，
///     不许像参照实现那样静默失效。
/// </summary>
public sealed partial class BiliSettingsPage : Page
{
    private BiliConfig Cfg => BiliConfig.Instance;

    private TextBlock? _loginStatus;
    private Image? _qrImage;
    private TextBlock? _qrHint;
    private Button? _loginBtn;
    private CancellationTokenSource? _loginCts;

    /// <summary>当前聚焦的模板输入框 —— 变量面板点一下就往这里插。</summary>
    private TextBox? _focusedTemplate;

    // 模板框（要重画预览时按引用回填）
    private TextBox? _dirTplBox;
    private TextBox? _nameTplBox;
    private TextBlock? _dirPreview;
    private TextBlock? _namePreview;

    public BiliSettingsPage() { InitializeComponent(); }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Build();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        try { _loginCts?.Cancel(); } catch { }
        _loginCts = null;
    }

    private void Build()
    {
        Root.Children.Clear();
        Cfg.Load();

        Root.Children.Add(UiKit.PageHeader("B 站设置",
            "画质 · 编码 · 容器 · 附加文件 · 命名模板 · 登录", "\uE9E9"));

        BuildQualityAndCodec();
        BuildContainerAndMerge();
        BuildAdditionalFiles();
        BuildDanmakuStyle();
        BuildCustomText();
        BuildSaveAndNaming();
        BuildTemplates();
        BuildPacing();
        Root.Children.Add(BuildMergeToolsCard());
        Root.Children.Add(BuildLoginCard());

        Root.Children.Add(new TextBlock
        {
            Text = "设置已实时保存到 " + Cfg.FilePath,
            FontSize = 12, Opacity = 0.55, TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 4, 0, 0),
        });
    }

    private static void Save() => BiliConfig.Instance.Save();

    // ① 画质与编码 ─────────────────────────────────────────

    private void BuildQualityAndCodec()
    {
        var qualityValues = Enum.GetValues<BiliQuality>();
        var qualityLabels = qualityValues.Select(BiliConfig.LabelOf).ToArray();

        var rows = new List<(string, string, UIElement)>
        {
            ("画质上限", "这是**上限**不是保证：B 站会按账号权限在 support_formats 里裁掉拿不到的高阶档，所以「选了 1080P60 只拿到 1080P」是正常结果",
                Combo(qualityLabels, BiliConfig.LabelOf(Cfg.Quality), v =>
                {
                    var idx = Array.IndexOf(qualityLabels, v);
                    if (idx >= 0) Cfg.Quality = qualityValues[idx];
                    Save();
                })),
            ("编码偏好", "自动 = 兼容性优先（AVC > HEVC > AV1）；显式偏好落空时退回兼容顺序，不会判失败",
                Combo(new[] { "自动（兼容性优先）", "H.264 / AVC", "H.265 / HEVC", "AV1" },
                    CodecLabel(Cfg.Codec), v => { Cfg.Codec = CodecFromLabel(v); Save(); })),
            ("并发数", "同时下载几个文件（交给 aria2）",
                Number(Cfg.MaxConcurrent, 1, 16, v => { Cfg.MaxConcurrent = (int)v; Save(); })),
            ("音轨", "有多条音轨时取哪一条（按码率，不按 id 排）",
                Combo(AudioOptions(), AudioLabelOf(Cfg.AudioQualityId),
                    v => { Cfg.AudioQualityId = AudioIdOf(v); Save(); })),
            ("仅下载音频", "只取音轨，适合听歌；此时不做合并",
                Toggle(Cfg.AudioOnly, v => { Cfg.AudioOnly = v; Save(); })),
        };
        Root.Children.Add(Group("画质与编码", rows.ToArray()));
    }

    // ② 容器与合并 ─────────────────────────────────────────

    private void BuildContainerAndMerge()
    {
        Root.Children.Add(Group("容器与合并", new (string, string, UIElement)[]
        {
            ("下载完成后合并", "B 站 DASH 是分开的视频流 + 音频流，各自都不能单独播放，必须合并成成品",
                Toggle(Cfg.MergeAfterDownload, v => { Cfg.MergeAfterDownload = v; Save(); })),
            ("合并后删除原始流", "关掉会留着 .video.m4s / .audio.m4s（占双份空间，但能自己重跑）",
                Toggle(Cfg.DeleteStreamsAfterMerge, v => { Cfg.DeleteStreamsAfterMerge = v; Save(); })),
            ("容器", "MKV 才能内封 ASS 字幕轨；MP4 兼容性最好",
                Combo(new[] { "MP4（兼容性最好）", "MKV（可内封字幕轨）" },
                    Cfg.Container == BiliContainer.Mkv ? "MKV（可内封字幕轨）" : "MP4（兼容性最好）",
                    v => { Cfg.Container = v.StartsWith("MKV") ? BiliContainer.Mkv : BiliContainer.Mp4; Save(); })),
            ("限速（KB/s）", "0 = 不限。走 aria2 的 per-task 选项，不是全局启动参数",
                Number(Cfg.SpeedLimitKbps, 0, 200000, v => { Cfg.SpeedLimitKbps = (int)v; Save(); })),
            ("ffmpeg 目录", "留空 = 用随包那份。要白名单构建没有的能力（h264/hevc 编码、ffprobe）就指到完整版的目录",
                DirPickerRow(Cfg.FfmpegDir, v => { Cfg.FfmpegDir = v; Save(); })),
            ("ffmpeg 状态", "合并要靠它；找不到时合并会失败并如实报原因",
                new TextBlock
                {
                    Text = FfmpegStatusText(),
                    FontSize = 12, Opacity = 0.8, TextWrapping = TextWrapping.Wrap,
                }),
        }));
    }

    // ③ 附加文件 ───────────────────────────────────────────

    private void BuildAdditionalFiles()
    {
        Root.Children.Add(Group("附加文件", new (string, string, UIElement)[]
        {
            ("保存弹幕", "弹幕 XML/JSON 侧文件；选 ASS 时可在 MKV 里内封",
                Toggle(Cfg.SaveDanmaku, v => { Cfg.SaveDanmaku = v; Save(); })),
            ("弹幕格式", "只有 ASS 能作为字幕轨内封进 MKV",
                Combo(new[] { "ASS（可内封）", "XML（弹姬格式）", "JSON" },
                    Cfg.DanmakuFormat switch
                    {
                        BiliDanmakuFormat.Ass => "ASS（可内封）",
                        BiliDanmakuFormat.Json => "JSON",
                        _ => "XML（弹姬格式）",
                    },
                    v => { Cfg.DanmakuFormat = v.StartsWith("ASS") ? BiliDanmakuFormat.Ass
                                                        : v == "JSON" ? BiliDanmakuFormat.Json
                                                        : BiliDanmakuFormat.Xml; Save(); })),
            ("保存字幕", "字幕是登录用户才有的权益，未登录拿不到（会如实列进「没拿到」）",
                Toggle(Cfg.SaveSubtitle, v => { Cfg.SaveSubtitle = v; Save(); })),
            ("字幕格式", "只有 ASS 谈得上内封",
                Combo(new[] { "SRT", "ASS（可内封）", "TXT（纯文本）" },
                    Cfg.SubtitleFormat switch
                    {
                        BiliSubtitleFormat.Ass => "ASS（可内封）",
                        BiliSubtitleFormat.Txt => "TXT（纯文本）",
                        _ => "SRT",
                    },
                    v => { Cfg.SubtitleFormat = v.StartsWith("ASS") ? BiliSubtitleFormat.Ass
                                                       : v.StartsWith("TXT") ? BiliSubtitleFormat.Txt
                                                       : BiliSubtitleFormat.Srt; Save(); })),
            ("只要这几种语言", "用逗号分隔的语言码，如 zh-cn,ai-en；留空 = 不筛选，有几条取几条",
                TextBoxFor(string.Join(",", Cfg.SubtitleLangs),
                    v => { Cfg.SubtitleLangs = v.Split(new[] { ',', '，' },
                        StringSplitOptions.RemoveEmptyEntries).Select(x => x.Trim()).Where(x => x.Length > 0).ToList(); Save(); },
                    "留空 = 全部")),
            ("仅人工字幕", "AI 字幕的语言码带 ai- 前缀，开了就不取。未登录时 B 站根本不返回 AI 字幕，这个开关在匿名态下没有可观测效果",
                Toggle(Cfg.SubtitleManualOnly, v => { Cfg.SubtitleManualOnly = v; Save(); })),
            ("把字幕内封进容器", SubtitleEmbedHint(),
                Toggle(Cfg.EmbedSubtitleTrack, v => { Cfg.EmbedSubtitleTrack = v; Save(); })),
            ("保存封面", "走 B 站图床的后缀缩放语法，不本地转码",
                Toggle(Cfg.SaveCover, v => { Cfg.SaveCover = v; Save(); })),
            ("封面格式", "jpg / png / webp / avif",
                Combo(new[] { "jpg", "png", "webp", "avif" }, BiliAdditional.CoverExt(Cfg.CoverFormat),
                    v => { Cfg.CoverFormat = v switch
                           {
                               "png" => BiliCoverFormat.Png,
                               "webp" => BiliCoverFormat.Webp,
                               "avif" => BiliCoverFormat.Avif,
                               _ => BiliCoverFormat.Jpg,
                           }; Save(); })),
            ("保存章节", "稿件有分段章节时写 ffmetadata，并在合并时写进成品",
                Toggle(Cfg.SaveChapter, v => { Cfg.SaveChapter = v; Save(); })),
            ("保存元数据", "nfo 给媒体库读（要多取一次标签接口）；json 是原样存一份解析结果",
                Toggle(Cfg.SaveMetadata, v => { Cfg.SaveMetadata = v; Save(); })),
            ("元数据格式", "nfo / json",
                Combo(new[] { "NFO（媒体库）", "JSON" },
                    Cfg.MetadataFormat == BiliMetadataFormat.Nfo ? "NFO（媒体库）" : "JSON",
                    v => { Cfg.MetadataFormat = v.StartsWith("NFO") ? BiliMetadataFormat.Nfo
                                                                   : BiliMetadataFormat.Json; Save(); })),
            ("轨序优先", "弹幕轨与字幕轨撞在一起时谁排前面（默认轨另有判据：中文优先、弹幕垫底）",
                Combo(new[] { "字幕优先", "弹幕优先" },
                    Cfg.TrackPriority == BiliTrackPriority.DanmakuFirst ? "弹幕优先" : "字幕优先",
                    v => { Cfg.TrackPriority = v == "弹幕优先"
                               ? BiliTrackPriority.DanmakuFirst : BiliTrackPriority.SubtitleFirst; Save(); })),
        }));
    }

    /// <summary>
    /// 「内封字幕」那条说明必须**写明缺哪一条前置条件** —— 原项目的教训：
    /// 静默失效等于用户点了没反应，还以为程序坏了。
    /// </summary>
    private string SubtitleEmbedHint()
    {
        var missing = new List<string>();
        if (Cfg.Container != BiliContainer.Mkv) missing.Add("容器不是 MKV");
        if (!Cfg.MergeAfterDownload) missing.Add("没开自动合并");
        if (Cfg.SubtitleFormat != BiliSubtitleFormat.Ass) missing.Add("字幕格式不是 ASS");
        return missing.Count == 0
            ? "当前三个前置条件都满足，字幕会作为轨道塞进成品"
            : "当前缺：" + string.Join("、", missing) + " —— 这三个条件缺一条这个开关都不生效";
    }

    // ④ 弹幕 / 字幕样式 ────────────────────────────────────

    private void BuildDanmakuStyle()
    {
        Root.Children.Add(Group("弹幕样式（仅 ASS 生效）", new (string, string, UIElement)[]
        {
            ("字体", "libass 按系统字体名找，中文环境用 Microsoft YaHei 最稳",
                TextBoxFor(Cfg.DanmakuFontFace, v => { Cfg.DanmakuFontFace = v; Save(); },
                    "Microsoft YaHei")),
            ("字号", "ASS 的 Fontsize",
                Number(Cfg.DanmakuFontSize, 8, 96, v => { Cfg.DanmakuFontSize = (int)v; Save(); })),
            ("不透明度（%）", "0 = 全透明，100 = 不透明",
                Number(Cfg.DanmakuOpacity, 0, 100, v => { Cfg.DanmakuOpacity = (int)v; Save(); })),
            ("底部边距（px）", "ASS 的 MarginV",
                Number(Cfg.DanmakuMarginV, 0, 400, v => { Cfg.DanmakuMarginV = (int)v; Save(); })),
        }));
    }

    // ⑤ 自定义文本 ─────────────────────────────────────────

    private void BuildCustomText()
    {
        Root.Children.Add(Group("自定义文本", new (string, string, UIElement)[]
        {
            ("%CUSTOM_TEXT% 的内容", "模板里用 %CUSTOM_TEXT% 就能取到这一段；也可写 %CUSTOM_TEXT,t=32% 截断到 32 字",
                TextBoxFor(Cfg.CustomText, v => { Cfg.CustomText = v; Save(); },
                    "例如：自制 · 搬运请注明出处")),
        }));
    }

    // ⑥ 保存与命名 ─────────────────────────────────────────

    private void BuildSaveAndNaming()
    {
        var panel = new StackPanel { Spacing = 10 };

        // 保存目录（系统选择器 —— 打包应用对任意路径的写入会被拦）
        var dirRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var dirBox = new TextBox
        {
            Text = Cfg.SaveDir,
            PlaceholderText = "留空 = " + Aria2Engine.DefaultDir(),
            Width = 460,
        };
        dirBox.TextChanged += (_, _) => { Cfg.SaveDir = dirBox.Text; Save(); };
        var pickBtn = new Button { Content = "选择…", MinWidth = 80 };
        pickBtn.Click += async (_, _) =>
        {
            try
            {
                var folder = await FolderPickerService.PickAsync(
                    string.IsNullOrWhiteSpace(Cfg.SaveDir) ? null : Cfg.SaveDir);
                if (folder is null) return;
                Cfg.SaveDir = folder;
                Save();
                dirBox.Text = folder;
            }
            catch { }
        };
        dirRow.Children.Add(dirBox);
        dirRow.Children.Add(pickBtn);
        panel.Children.Add(SettingRows.Header("保存目录", "留空则落到全局默认目录（数据目录下的 downloads）"));
        panel.Children.Add(dirRow);

        panel.Children.Add(SettingRows.Divider());
        panel.Children.Add(SettingRows.Switch("跳过已下载的分 P", "按 bvid + cid 台账跳过（台账未接时此项无实际效果）",
            Cfg.SkipDownloaded, v => { Cfg.SkipDownloaded = v; Save(); }));
        panel.Children.Add(SettingRows.Switch("同一稿件的分 P 排在一起", "多 P 稿件入队时保持连续",
            Cfg.GroupByWork, v => { Cfg.GroupByWork = v; Save(); }));
        panel.Children.Add(SettingRows.Switch("启用保存文件夹", "开 = 按文件夹模板建子目录；关 = 全部平铺在保存目录下",
            Cfg.EnableSaveFolder, v => { Cfg.EnableSaveFolder = v; Save(); }));

        // 「启用模版」预设
        var presets = new[] { "按作品分文件夹（推荐）", "按「UP 主 / 作品」两级文件夹", "全部平铺（不建子文件夹）", "按 BV 号分文件夹", "自定义" };
        panel.Children.Add(SettingRows.Row("启用模版", "选完仍可手动微调；手改过模板后这里会显示「自定义」",
            Combo(presets, CurrentPresetLabel(), v => ApplyPreset(v))));

        Root.Children.Add(SettingRows.Card("保存与命名", null, panel));
    }

    private static readonly (string Label, string Dir, string Name)[] Presets =
    {
        ("按作品分文件夹（推荐）", BiliConfig.DefaultDirTemplate, BiliConfig.DefaultFileNameTemplate),
        ("按「UP 主 / 作品」两级文件夹", "%UP_NAME%/%WORK_TITLE%", "<P%P%->%PART_TITLE%%EXT%"),
        ("全部平铺（不建子文件夹）", "", "%WORK_TITLE%<-%PART_TITLE%>-%QUALITY%%EXT%"),
        ("按 BV 号分文件夹", "%BVID%", "<P%P%->%PART_TITLE%-%QUALITY%-%CODEC%%EXT%"),
    };

    private string CurrentPresetLabel()
    {
        foreach (var (label, dir, name) in Presets)
        {
            if (Cfg.DirTemplate == dir && Cfg.FileNameTemplate == name) return label;
        }
        return "自定义";
    }

    private void ApplyPreset(string label)
    {
        foreach (var (l, dir, name) in Presets)
        {
            if (l != label) continue;
            Cfg.DirTemplate = dir;
            Cfg.FileNameTemplate = name;
            Save();
            if (_dirTplBox is not null) _dirTplBox.Text = dir;
            if (_nameTplBox is not null) _nameTplBox.Text = name;
            RefreshTemplates();
            return;
        }
    }

    // ⑦ 命名模板（可展开变量面板）──────────────────────────

    private void BuildTemplates()
    {
        var panel = new StackPanel { Spacing = 12 };

        // **2026-10-26 用户要求「做的和原来一样，点击展开，点变量插入」**：
        // 原项目是**每个模板框各带一份「可用变量」可展开面板**，点哪个框下面的
        // 「插入」就插到哪个框 —— 不是两框共用一份靠焦点猜。现在改成同一形态。
        _dirTplBox = TemplateBox(Cfg.DirTemplate, BiliConfig.DefaultDirTemplate,
            v => { Cfg.DirTemplate = v; Save(); RefreshTemplates(); },
            "留空则直接存到保存目录下");
        panel.Children.Add(TemplateRow("文件夹模板", _dirTplBox, BiliConfig.DefaultDirTemplate,
            "提示：文件夹模板建议只用「作品 / UP 主」这一级的变量；%MEDIA_INDEX%、%EXT% 这类逐文件的变量会让每个文件各建一个文件夹。分 P 想挤进同一个目录就别在这里放 %P%。",
            out _dirPreview));
        _dirPreview = new TextBlock { FontSize = 11.5, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        panel.Children.Add(_dirPreview);
        panel.Children.Add(BuildVarsPanel(_dirTplBox));

        panel.Children.Add(SettingRows.Divider());

        _nameTplBox = TemplateBox(Cfg.FileNameTemplate, BiliConfig.DefaultFileNameTemplate,
            v => { Cfg.FileNameTemplate = v; Save(); RefreshTemplates(); },
            "留空 = 用默认模板");
        panel.Children.Add(TemplateRow("文件模板", _nameTplBox, BiliConfig.DefaultFileNameTemplate,
            "默认 %WORK_TITLE%<-P%P%>-%QUALITY%%EXT%：单 P 落「标题-1080P.mp4」，多 P 落「标题P03-1080P.mp4」（可选段让单 P 不出现 P0）。",
            out _namePreview));
        _namePreview = new TextBlock { FontSize = 11.5, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        panel.Children.Add(_namePreview);
        panel.Children.Add(BuildVarsPanel(_nameTplBox));

        panel.Children.Add(new TextBlock
        {
            Text = "改动会自动保存", FontSize = 11.5, Opacity = 0.55,
        });

        Root.Children.Add(SettingRows.Card("命名模板", "每个模板框各带一份可展开变量面板，点「插入」就插到该框", panel));
        RefreshTemplates();
    }
    private TextBox TemplateBox(string value, string defaultValue, Action<string> onChange, string placeholder)
    {
        var box = new TextBox
        {
            Text = value,
            PlaceholderText = placeholder,
            FontFamily = new FontFamily("Consolas"),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        box.TextChanged += (_, _) => onChange(box.Text);
        // 记录「当前聚焦的框」—— 变量面板点一下要插到这里
        box.GotFocus += (_, _) => _focusedTemplate = box;
        return box;
    }

    private UIElement TemplateRow(string label, TextBox box, string defaultValue,
        string hint, out TextBlock preview)
    {
        var panel = new StackPanel { Spacing = 6 };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        head.Children.Add(new TextBlock
        {
            Text = label, FontSize = 14, VerticalAlignment = VerticalAlignment.Center,
        });
        var resetBtn = new Button
        {
            Content = "填入默认", FontSize = 11.5, Padding = new Thickness(8, 3, 8, 3),
            MinHeight = 26,
        };
        resetBtn.Click += (_, _) => { box.Text = defaultValue; };
        head.Children.Add(resetBtn);
        panel.Children.Add(head);
        panel.Children.Add(box);
        panel.Children.Add(SettingRows.Description(hint));
        preview = null!;
        return panel;
    }

    /// <summary>
    /// 变量面板（**可展开**，照原项目 TemplateRow 的 vars 那一块）。
    /// 点一个变量 → 把 %NAME% 插到**当前聚焦的模板框**的光标位置。
    /// 没有聚焦框时插到文件模板（那是用户最常改的那个）。
    /// </summary>
    private UIElement BuildVarsPanel(TextBox target)
    {
        var grid = new WrapPanel2 { };
        foreach (var v in BiliTemplate.Vars)
        {
            var btn = new Button
            {
                Content = "%" + v.Name + "%",
                FontSize = 11, Padding = new Thickness(7, 3, 7, 3),
                MinHeight = 26, Margin = new Thickness(0, 0, 6, 6),
                FontFamily = new FontFamily("Consolas"),
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(btn, "变量 " + v.Name);
            ToolTipService.SetToolTip(btn, v.Desc + (v.Params is null ? "" : "（参数：" + v.Params + "）"));
            var token = "%" + v.Name + "%";
            btn.Click += (_, _) => InsertTokenTo(target, token);
            grid.Children.Add(btn);
        }

        var expander = new Expander
        {
            Header = "可用变量（" + BiliTemplate.Vars.Count + " 个）",
            IsExpanded = false,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = new StackPanel
            {
                Spacing = 6,
                Padding = new Thickness(0, 8, 0, 0),
                Children =
                {
                    SettingRows.Description("点一个变量，它会插到当前聚焦的模板框光标处。带参数用法：%CUSTOM_TEXT,t=32%（截断到 32 字）、%POST_TIME,d=1%（只要日期）。"),
                    grid,
                },
            },
        };
        return expander;
    }

    /// <summary>把 token 插到**指定**模板框的光标处（每框自带面板，目标明确，不靠焦点猜）。</summary>
    private static void InsertTokenTo(TextBox box, string token)
    {
        if (box is null) return;
        var text = box.Text ?? "";
        var start = box.SelectionStart;
        if (start < 0 || start > text.Length) start = text.Length;
        var len = box.SelectionLength;
        if (len > 0) text = text.Remove(start, Math.Min(len, text.Length - start));
        box.Text = text.Insert(start, token);
        box.SelectionStart = start + token.Length;
        box.SelectionLength = 0;
        box.Focus(FocusState.Programmatic);
    }
    /// <summary>把 token 插到当前聚焦框的光标处；没有聚焦框就落到文件模板。</summary>
    private void InsertToken(string token)
    {
        var box = _focusedTemplate ?? _nameTplBox;
        if (box is null) return;
        var start = box.SelectionStart;
        var len = box.SelectionLength;
        var text = box.Text ?? "";
        if (start < 0 || start > text.Length) start = text.Length;
        if (len > 0) text = text.Remove(start, Math.Min(len, text.Length - start));
        box.Text = text.Insert(start, token);
        box.SelectionStart = start + token.Length;
        box.Focus(FocusState.Programmatic);
        RefreshTemplates();
    }

    /// <summary>重算两处预览（用一组假数据渲染，让用户立刻看到落名长什么样）。</summary>
    private void RefreshTemplates()
    {
        if (_dirPreview is not null)
        {
            var dir = BiliTemplate.Render(Cfg.EffectiveDirTemplate, ExampleCtx());
            _dirPreview.Text = string.IsNullOrWhiteSpace(dir)
                ? "文件夹预览：（空 —— 文件会直接落在保存目录下）"
                : "文件夹预览：" + dir;
        }
        if (_namePreview is not null)
        {
            var name = BiliTemplate.Render(Cfg.EffectiveFileNameTemplate, ExampleCtx());
            var clean = BiliTemplate.Sanitize(name);
            _namePreview.Text = clean.Length == 0
                ? "文件预览：（模板渲染为空 —— 会退回 BV 号兜底）"
                : "文件预览：" + clean + ".mp4";
        }
    }

    private static BiliTemplate.Context ExampleCtx() => new()
    {
        WorkTitle = "怪东西分享9.0",
        PartTitle = "第03集",
        Part = 3,
        PartTotal = 12,
        Bvid = "BV1gHps6yEHL",
        Aid = 170001,
        Cid = 123456789,
        UpName = "影视飓风",
        UpMid = 946974,
        Quality = "1080P",
        Codec = "AVC",
        CustomText = "自制",
        Width = 1920,
        Height = 1080,
        DurationSec = 754,
        PostTime = new DateTime(2026, 10, 9, 12, 34, 56),
        Ext = ".mp4",
    };

    // ⑧ 节奏 ───────────────────────────────────────────────

    private void BuildPacing()
    {
        Root.Children.Add(Group("节奏", new (string, string, UIElement)[]
        {
            ("请求间隔（毫秒）", "批量解析时每条之间等多久 —— 太小容易触发风控",
                Number(Cfg.RequestIntervalMs, 200, 10000, v => { Cfg.RequestIntervalMs = (int)v; Save(); })),
        }));
    }

    // ⑨ 合并工具（手工自测入口）────────────────────────────

    private UIElement BuildMergeToolsCard()
    {
        var panel = new StackPanel { Spacing = 8 };

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var scanBtn = new Button { Content = "扫描并合并待处理", MinWidth = 150 };
        var testBtn = new Button { Content = "合并自测（造样本）", MinWidth = 150 };
        row.Children.Add(scanBtn);
        row.Children.Add(testBtn);
        panel.Children.Add(row);

        var output = new TextBlock
        {
            Text = "「扫描并合并」扫保存目录里的 .video.m4s / .audio.m4s 配对并合并；" +
                   "「合并自测」会造一对样本流、跑真合并、再用 ffprobe 验货。",
            FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            FontFamily = new FontFamily("Consolas"),
        };
        panel.Children.Add(output);

        scanBtn.Click += async (_, _) =>
        {
            scanBtn.IsEnabled = false;
            output.Text = "正在扫描 " + Cfg.ResolvedSaveDir + " …";
            try
            {
                var results = await BiliMergePipeline.Instance.ScanAndMergeAsync(Cfg.ResolvedSaveDir);
                if (results.Count == 0)
                {
                    output.Text = "没有待合并的配对（" + Cfg.ResolvedSaveDir + "）。";
                }
                else
                {
                    var sb = new System.Text.StringBuilder();
                    sb.AppendLine("合并 " + results.Count + " 对：成功 " +
                                  results.Count(x => x.Ok) + "，失败 " + results.Count(x => !x.Ok));
                    foreach (var x in results)
                    {
                        sb.AppendLine((x.Ok ? "  OK   " : "  FAIL ") +
                                      System.IO.Path.GetFileName(x.OutputPath) +
                                      (x.Ok ? "" : ("  " + x.Failure + "：" + x.Message)));
                    }
                    output.Text = sb.ToString();
                    WriteReport(output.Text, "bili_merge_manual.txt");
                }
            }
            catch (Exception ex)
            {
                output.Text = "扫描失败：" + ex.Message;
            }
            finally { scanBtn.IsEnabled = true; }
        };

        testBtn.Click += async (_, _) =>
        {
            testBtn.IsEnabled = false;
            output.Text = "正在跑合并自测（造样本 + 真合并 + ffprobe 验货）…";
            try
            {
                var report = await BiliMergePipeline.Instance.RunSelfTestAsync(Cfg.ResolvedSaveDir);
                output.Text = report;
                WriteReport(report, "bili_merge_selftest.txt");
            }
            catch (Exception ex)
            {
                output.Text = "自测异常：" + ex.GetType().Name + " " + ex.Message;
            }
            finally { testBtn.IsEnabled = true; }
        };

        return UiKit.SectionCard("音视频合并", panel, "下载完成后自动进行，这里可手工补跑");
    }

    private static void WriteReport(string text, string fileName)
    {
        try
        {
            System.IO.File.WriteAllText(
                System.IO.Path.Combine(AppPaths.DataDir, fileName), text,
                System.Text.Encoding.UTF8);
        }
        catch { }
    }

    // ⑩ 登录 ───────────────────────────────────────────────

    private UIElement BuildLoginCard()
    {
        var panel = new StackPanel { Spacing = 10 };

        _loginStatus = new TextBlock
        {
            Text = Cfg.IsLoggedIn
                ? "当前已登录（可下载 1080P 及以上）"
                : "当前未登录（B 站只给 480P 及以下）",
            FontSize = 13, TextWrapping = TextWrapping.Wrap,
        };
        panel.Children.Add(_loginStatus);

        _qrImage = new Image
        {
            Width = 200, Height = 200,
            HorizontalAlignment = HorizontalAlignment.Left,
            Visibility = Visibility.Collapsed,
        };
        panel.Children.Add(_qrImage);

        _qrHint = new TextBlock
        {
            Text = "", FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };
        panel.Children.Add(_qrHint);

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _loginBtn = new Button { Content = "扫码登录", MinWidth = 100 };
        var logoutBtn = new Button { Content = "退出登录", MinWidth = 100 };
        row.Children.Add(_loginBtn);
        row.Children.Add(logoutBtn);
        panel.Children.Add(row);

        _loginBtn.Click += async (_, _) => await DoLoginAsync();
        logoutBtn.Click += (_, _) =>
        {
            Cfg.Cookie = "";
            Save();
            if (_qrImage is not null) _qrImage.Visibility = Visibility.Collapsed;
            if (_qrHint is not null) _qrHint.Visibility = Visibility.Collapsed;
            if (_loginStatus is not null) _loginStatus.Text = "已退出登录（B 站只给 480P 及以下）";
        };

        return UiKit.SectionCard("B 站登录", panel, "1080P 及以上需要登录");
    }

    private async Task DoLoginAsync()
    {
        if (_loginBtn is null || _loginStatus is null || _qrImage is null || _qrHint is null) return;
        _loginBtn.IsEnabled = false;
        _loginStatus.Text = "正在获取二维码…";
        try
        {
            _loginCts?.Cancel();
            _loginCts = new CancellationTokenSource();
            var login = new BiliLogin(new BiliApi(Cfg.EffectiveCookie));
            var qr = await login.GenerateQrCodeAsync(_loginCts.Token);

            _qrImage.Source = new BitmapImage(new Uri(qr.Url));
            _qrImage.Visibility = Visibility.Visible;
            _qrHint.Text = "请用 B 站手机客户端扫码，并在手机上确认登录";
            _qrHint.Visibility = Visibility.Visible;
            _loginStatus.Text = "等待扫码…";

            var result = await login.WaitAsync(qr.Key, st =>
            {
                switch (st)
                {
                    case BiliLoginState.Scanned:
                        _loginStatus.Text = "已扫码，请在手机上点击确认";
                        break;
                    case BiliLoginState.Expired:
                        _loginStatus.Text = "二维码已过期，请重新点扫码登录";
                        break;
                }
            }, _loginCts.Token);

            if (result.State == BiliLoginState.Confirmed && !string.IsNullOrEmpty(result.Cookie))
            {
                Cfg.Cookie = result.Cookie;
                Save();
                _loginStatus.Text = "登录成功，已保存登录态（可下载 1080P 及以上）";
                _qrImage.Visibility = Visibility.Collapsed;
                _qrHint.Visibility = Visibility.Collapsed;
            }
            else if (result.State != BiliLoginState.Confirmed)
            {
                _loginStatus.Text = "登录未完成：" + result.State;
            }
        }
        catch (OperationCanceledException)
        {
            _loginStatus.Text = "已取消登录";
        }
        catch (Exception ex)
        {
            _loginStatus.Text = "登录失败：" + ex.Message;
        }
        finally
        {
            _loginBtn.IsEnabled = true;
        }
    }

    // ── 小工具 ──────────────────────────────────────────────

    private static string FfmpegStatusText()
    {
        var exe = BiliMergePipeline.ResolveFfmpeg();
        return exe is null
            ? "未找到 ffmpeg.exe —— 合并会失败。应随包分发到程序目录（Assets 里那份会复制到输出根目录）。"
            : "已找到：" + exe;
    }

    private static string CodecLabel(BiliCodec c) => c switch
    {
        BiliCodec.Avc => "H.264 / AVC",
        BiliCodec.Hevc => "H.265 / HEVC",
        BiliCodec.Av1 => "AV1",
        _ => "自动（兼容性优先）",
    };

    private static BiliCodec CodecFromLabel(string v) => v switch
    {
        "H.264 / AVC" => BiliCodec.Avc,
        "H.265 / HEVC" => BiliCodec.Hevc,
        "AV1" => BiliCodec.Av1,
        _ => BiliCodec.Auto,
    };

    private static readonly (int Id, string Label)[] AudioOptionsTable =
    {
        (0, "最高可用"),
        (30251, "Hi-Res"),
        (30250, "杜比"),
        (30280, "192K"),
        (30232, "132K"),
        (30216, "64K"),
    };

    private static string[] AudioOptions() => AudioOptionsTable.Select(x => x.Label).ToArray();

    private static string AudioLabelOf(int id) =>
        AudioOptionsTable.FirstOrDefault(x => x.Id == id).Label ?? "最高可用";

    private static int AudioIdOf(string label) =>
        AudioOptionsTable.FirstOrDefault(x => x.Label == label).Id;

    private static TextBox TextBoxFor(string value, Action<string> onChange, string? placeholder = null)
    {
        var box = new TextBox { Text = value, PlaceholderText = placeholder ?? "" };
        box.TextChanged += (_, _) => onChange(box.Text);
        return box;
    }

    /// <summary>目录选择行：输入框 + 「选择…」按钮（走系统 FolderPicker）。</summary>
    private static UIElement DirPickerRow(string value, Action<string> onChange)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var box = new TextBox { Text = value, PlaceholderText = "留空 = 用随包那份", Width = 420 };
        box.TextChanged += (_, _) => onChange(box.Text);
        var pick = new Button { Content = "选择…", MinWidth = 80 };
        pick.Click += async (_, _) =>
        {
            try
            {
                var folder = await FolderPickerService.PickAsync(
                    string.IsNullOrWhiteSpace(box.Text) ? null : box.Text);
                if (folder is null) return;
                box.Text = folder;
            }
            catch { }
        };
        row.Children.Add(box);
        row.Children.Add(pick);
        return row;
    }

    private static ToggleSwitch Toggle(bool value, Action<bool> onChange)
    {
        var t = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "", MinWidth = 0 };
        t.Toggled += (_, _) => onChange(t.IsOn);
        return t;
    }

    private static NumberBox Number(double value, double min, double max, Action<double> onChange)
    {
        var n = new NumberBox
        {
            Value = value, Minimum = min, Maximum = max,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
            MinWidth = 150,
        };
        n.ValueChanged += (_, e) => { if (!double.IsNaN(e.NewValue)) onChange(e.NewValue); };
        return n;
    }

    private static ComboBox Combo(string[] items, string selected, Action<string> onChange)
    {
        var c = new ComboBox { ItemsSource = items, MinWidth = 220 };
        var idx = Array.IndexOf(items, selected);
        c.SelectedIndex = idx >= 0 ? idx : 0;
        c.SelectionChanged += (_, _) => { if (c.SelectedItem is string v) onChange(v); };
        return c;
    }

    /// <summary>
    /// 一组设置项。**开关与标题同行**（用户 2026-09-30 约定：距离 ≤24px），
    /// 所以控件紧跟标题而不是推到行尾。
    /// </summary>
    private static Border Group(string title, (string Label, string Hint, UIElement Control)[] rows)
    {
        var stack = new StackPanel { Spacing = 0 };
        foreach (var (label, hint, control) in rows)
        {
            var row = new StackPanel { Spacing = 4, Margin = new Thickness(0, 8, 0, 8) };
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            head.Children.Add(new TextBlock
            {
                Text = label, FontSize = 14, VerticalAlignment = VerticalAlignment.Center,
            });
            var fe = (FrameworkElement)control;
            fe.VerticalAlignment = VerticalAlignment.Center;
            head.Children.Add(fe);
            row.Children.Add(head);
            row.Children.Add(new TextBlock
            {
                Text = hint, FontSize = 12, Opacity = 0.6, TextWrapping = TextWrapping.Wrap,
            });
            stack.Children.Add(row);
        }
        return UiKit.SectionCard(title, stack);
    }
}

/// <summary>
/// 极简横向流式面板 —— 变量按钮多了要自动换行。
/// WinUI 3 的 WrapPanel 在 Community Toolkit 里（本项目没引那个包），
/// 所以自己写一个：MeasureOverride 按可用宽累加、ArrangeOverride 按行摆放。
/// </summary>
internal sealed class WrapPanel2 : Panel
{
    protected override Size MeasureOverride(Size availableSize)
    {
        var width = double.IsInfinity(availableSize.Width) ? 600 : availableSize.Width;
        double x = 0, y = 0, lineH = 0;
        foreach (var child in Children)
        {
            child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var w = child.DesiredSize.Width;
            var h = child.DesiredSize.Height;
            if (x + w > width && x > 0)
            {
                x = 0;
                y += lineH;
                lineH = 0;
            }
            x += w;
            lineH = Math.Max(lineH, h);
        }
        return new Size(width, y + lineH);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var width = double.IsInfinity(finalSize.Width) ? 600 : finalSize.Width;
        double x = 0, y = 0, lineH = 0;
        foreach (var child in Children)
        {
            var w = child.DesiredSize.Width;
            var h = child.DesiredSize.Height;
            if (x + w > width && x > 0)
            {
                x = 0;
                y += lineH;
                lineH = 0;
            }
            child.Arrange(new Rect(x, y, w, h));
            x += w;
            lineH = Math.Max(lineH, h);
        }
        return new Size(width, y + lineH);
    }
}
