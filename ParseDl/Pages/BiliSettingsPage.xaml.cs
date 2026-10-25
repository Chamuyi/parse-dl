using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.Bili;

namespace ParseDl.Pages;

/// <summary>
/// B 站设置页 —— 对齐 Flutter 版 bili_config.dart 的全部选项 + 扫码登录。
///
/// 与其它两个模块的设置页（ModuleSettingsPage）分开的原因：
/// B 站这一族选项比 X / 抖音多得多（画质上限、编码偏好、容器、五类附加文件、
/// 轨序、合并开关），塞进共用的两栏布局里会变成一屏挤不下的长列表。
///
/// **每项改动立即写盘**（BiliConfig.Save），不依赖"保存"按钮 —— 与其它设置页一致。
/// </summary>
public sealed partial class BiliSettingsPage : Page
{
    private BiliConfig Cfg => BiliConfig.Instance;

    // 登录相关的界面对象（Build 时创建，按钮回调里要用）
    private TextBlock? _loginStatus;
    private Image? _qrImage;
    private TextBlock? _qrHint;
    private Button? _loginBtn;
    private CancellationTokenSource? _loginCts;

    public BiliSettingsPage() { InitializeComponent(); }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Build();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        // 离开页面就掐掉轮询 —— 否则一次登录会拖 3 分钟的轮询在后台跑。
        try { _loginCts?.Cancel(); } catch { }
        _loginCts = null;
    }

    private void Build()
    {
        Root.Children.Clear();
        Cfg.Load();

        Root.Children.Add(UiKit.PageHeader("B 站设置", "清晰度 · 音轨 · 编码 · 附加文件 · 命名 · 登录", "\uE9E9"));

        Root.Children.Add(Group("画质与编码", new (string, string, UIElement)[]
        {
            ("清晰度上限", "B 站会按账号权限再裁一刀，所以「选了 1080P60 只拿到 1080P」是正常结果",
                Combo(Enum.GetValues<BiliQuality>().Select(q => BiliConfig.LabelOf(q)).ToArray(),
                      BiliConfig.LabelOf(Cfg.Quality),
                      v => { Cfg.Quality = Enum.GetValues<BiliQuality>()[Array.IndexOf(
                          Enum.GetValues<BiliQuality>().Select(BiliConfig.LabelOf).ToArray(), v)]; Save(); })),
            ("编码偏好", "自动 = 兼容性优先（AVC > HEVC > AV1）；显式偏好落空时退回兼容顺序，不会判失败",
                Combo(new[] { "自动（兼容性优先）", "H.264 / AVC", "H.265 / HEVC", "AV1" },
                      CodecLabel(Cfg.Codec),
                      v => { Cfg.Codec = CodecFromLabel(v); Save(); })),
            ("音轨", "有多条音轨时取哪一条（按码率，不按 id 排）",
                Combo(AudioOptions(), AudioLabelOf(Cfg.AudioQualityId),
                      v => { Cfg.AudioQualityId = AudioIdOf(v); Save(); })),
            ("仅下载音频", "只取音轨，适合听歌；此时不做合并",
                Toggle(Cfg.AudioOnly, v => { Cfg.AudioOnly = v; Save(); })),
        }));

        Root.Children.Add(Group("合并", new (string, string, UIElement)[]
        {
            ("下载完成后自动合并", "B 站 DASH 是分开的视频流 + 音频流，各自都不能单独播放，必须合并成成品",
                Toggle(Cfg.MergeAfterDownload, v => { Cfg.MergeAfterDownload = v; Save(); })),
            ("合并后删除原始流", "关掉会留着 .video.m4s / .audio.m4s（占双份空间，但能自己重跑）",
                Toggle(Cfg.DeleteStreamsAfterMerge, v => { Cfg.DeleteStreamsAfterMerge = v; Save(); })),
            ("产物容器", "MKV 才能内封 ASS 字幕轨；MP4 兼容性最好",
                Combo(new[] { "MP4（兼容性最好）", "MKV（可内封字幕轨）" },
                      Cfg.Container == BiliContainer.Mkv ? "MKV（可内封字幕轨）" : "MP4（兼容性最好）",
                      v => { Cfg.Container = v.StartsWith("MKV") ? BiliContainer.Mkv : BiliContainer.Mp4; Save(); })),
            ("ffmpeg 状态", "合并要靠随包的 ffmpeg.exe；找不到时合并会失败并如实报原因",
                new TextBlock
                {
                    Text = FfmpegStatusText(),
                    FontSize = 12,
                    Opacity = 0.8,
                    TextWrapping = TextWrapping.Wrap,
                }),
        }));

        Root.Children.Add(Group("附加文件", new (string, string, UIElement)[]
        {
            ("保存弹幕", "弹幕 XML 侧文件；选 ASS 时可在 MKV 里内封",
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
            ("保存字幕", "字幕是登录用户才有的权益，未登录时拿不到（会如实列进「没拿到」）",
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
            ("保存章节", "稿件有分段章节时写 ffmetadata 并在合并时写进成品",
                Toggle(Cfg.SaveChapter, v => { Cfg.SaveChapter = v; Save(); })),
            ("保存元数据", "nfo 给媒体库读（要多取一次标签接口）；json 是原样存一份解析结果",
                Toggle(Cfg.SaveMetadata, v => { Cfg.SaveMetadata = v; Save(); })),
            ("元数据格式", "nfo / json",
                Combo(new[] { "json", "nfo" }, Cfg.MetadataFormat == BiliMetadataFormat.Nfo ? "nfo" : "json",
                      v => { Cfg.MetadataFormat = v == "nfo" ? BiliMetadataFormat.Nfo : BiliMetadataFormat.Json; Save(); })),
            ("轨序优先", "弹幕轨与字幕轨撞在一起时谁排前面（默认轨另有判据：中文优先、弹幕垫底）",
                Combo(new[] { "字幕优先", "弹幕优先" },
                      Cfg.TrackPriority == BiliTrackPriority.DanmakuFirst ? "弹幕优先" : "字幕优先",
                      v => { Cfg.TrackPriority = v == "弹幕优先"
                                 ? BiliTrackPriority.DanmakuFirst : BiliTrackPriority.SubtitleFirst; Save(); })),
        }));

        Root.Children.Add(BuildMergeToolsCard());

        Root.Children.Add(BuildNamingCard());

        Root.Children.Add(Group("节奏", new (string, string, UIElement)[]
        {
            ("请求间隔（毫秒）", "批量解析时每条之间等多久 —— 太小容易触发风控",
                Number(Cfg.RequestIntervalMs, 200, 10000, v => { Cfg.RequestIntervalMs = (int)v; Save(); })),
            ("并发下载数", "交给 aria2 同时下几个文件",
                Number(Cfg.MaxConcurrent, 1, 16, v => { Cfg.MaxConcurrent = (int)v; Save(); })),
            ("跳过已下载", "同名成品已存在时跳过",
                Toggle(Cfg.SkipDownloaded, v => { Cfg.SkipDownloaded = v; Save(); })),
        }));

        Root.Children.Add(BuildLoginCard());

        Root.Children.Add(new TextBlock
        {
            Text = "设置已实时保存到 " + Cfg.FilePath,
            FontSize = 12,
            Opacity = 0.55,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 4, 0, 0),
        });
    }

    private static void Save() => BiliConfig.Instance.Save();

    // ── 命名模板 ─────────────────────────────────────────────

    /// <summary>
    /// 合并工具卡 —— **手工触发的自测入口**。
    ///
    /// 为什么必须做成按钮：打包应用既透传不了命令行参数、也继承不到父进程环境变量
    /// （winapp run 起独立进程），一个按钮是唯一可靠的触发方式，用户自己也能随时复验。
    /// 日常不需要点它 —— 正常路径是「下载完成 → DownloadStore 终态回调 → 自动合并」，
    /// 这个入口用于自测与「补合并」（重启后扫目录重建配对）。
    /// </summary>
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
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
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

    private UIElement BuildNamingCard()
    {
        var panel = new StackPanel { Spacing = 8 };

        // 保存目录（留空 = 全局默认 downloads）—— 选目录必须走系统选择器，
        // 打包应用对用户任意路径的写入会被拦。
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
                var (ok, msg) = FolderPickerService.VerifyWritable(folder.Path);
                Cfg.SaveDir = folder.Path;
                Save();
                dirBox.Text = folder.Path;
                if (!ok) _loginStatus?.Text = "该目录不可写：" + msg;
            }
            catch { }
        };
        dirRow.Children.Add(dirBox);
        dirRow.Children.Add(pickBtn);
        panel.Children.Add(new TextBlock { Text = "保存目录", FontSize = 14 });
        panel.Children.Add(dirRow);
        panel.Children.Add(new TextBlock
        {
            Text = "留空则落到全局默认目录（数据目录下的 downloads）",
            FontSize = 12, Opacity = 0.6, TextWrapping = TextWrapping.Wrap,
        });

        panel.Children.Add(new TextBlock
        {
            Text = "文件名模板", FontSize = 14, Margin = new Thickness(0, 8, 0, 0),
        });
        var box = new TextBox
        {
            Text = Cfg.FileNameTemplate,
            PlaceholderText = "留空 = 标题-BV号",
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
        };
        box.TextChanged += (_, _) => { Cfg.FileNameTemplate = box.Text; Save(); };
        panel.Children.Add(box);
        panel.Children.Add(new TextBlock
        {
            Text = "可用变量：%BILI_TITLE%（稿件标题） %BILI_PAGE%（分P号） %BILI_QUALITY%（实际拿到的档位）" +
                   " %POST_ID%（BV 号） %USER_SCREEN_NAME%（UP 主） %MEDIA_INDEX% %POST_TIME% %EXT%",
            FontSize = 12, Opacity = 0.6, TextWrapping = TextWrapping.Wrap,
        });

        // 预览：用一组假数据渲染一次，让用户立刻看到落名长什么样
        var preview = new TextBlock
        {
            Text = "预览：" + PreviewName(),
            FontSize = 12, Opacity = 0.85, TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        panel.Children.Add(preview);
        box.TextChanged += (_, _) => preview.Text = "预览：" + PreviewName();

        return UiKit.SectionCard("文件名模板", panel, "B 站专用");
    }

    private string PreviewName()
    {
        var tpl = string.IsNullOrWhiteSpace(Cfg.FileNameTemplate)
            ? "%BILI_TITLE%-%POST_ID%" : Cfg.FileNameTemplate;
        var ctx = new TemplateContext
        {
            PostId = "BV1xx411c7mD",
            UserName = "某个UP主",
            UserScreenName = "某个UP主",
            MediaId = "BV1xx411c7mD",
            BiliTitle = "示例稿件标题",
            BiliPageIndex = 1,
            BiliQuality = "1080P",
            MediaIndex = 1,
            PostTime = new DateTime(2026, 10, 25, 12, 0, 0),
            Extension = "mp4",
        };
        try
        {
            var name = FileNameTemplate.UnicodeFilenamify(FileNameTemplate.Resolve(tpl, ctx));
            return string.IsNullOrWhiteSpace(name) ? "（模板渲染为空，将退回 BV 号）" : name + ".mp4";
        }
        catch (Exception ex)
        {
            return "（模板渲染失败：" + ex.Message + "）";
        }
    }

    // ── 扫码登录 ─────────────────────────────────────────────

    private UIElement BuildLoginCard()
    {
        var panel = new StackPanel { Spacing = 10 };

        _loginStatus = new TextBlock
        {
            Text = Cfg.IsLoggedIn
                ? "当前已登录（可下载 1080P 及以上）"
                : "当前未登录（B 站只给 480P 及以下）",
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
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
            Text = "",
            FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap,
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
            var login = new BiliLogin(new BiliApi(Cfg.Cookie));
            var qr = await login.GenerateQrCodeAsync(_loginCts.Token);

            // 二维码就是一张图片地址，直接给 Image 显示
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

    // ── 小工具 ───────────────────────────────────────────────

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

    private static ToggleSwitch Toggle(bool value, Action<bool> onChange)
    {
        var t = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "" };
        t.Toggled += (_, _) => onChange(t.IsOn);
        return t;
    }

    private static NumberBox Number(double value, double min, double max, Action<double> onChange)
    {
        var n = new NumberBox
        {
            Value = value, Minimum = min, Maximum = max,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
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
    /// 一组设置项。**开关与标题同行**（用户 2026-09-30 的约定：开关必须与标题同行，
    /// 距离 ≤24px —— 推到行尾会被判据判红），所以这里不用两栏 Grid 把控件推到右边，
    /// 而是「标题 + 说明」在左、控件紧随其后（HorizontalAlignment=Left）。
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
