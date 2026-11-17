using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.Bili;

namespace ParseDl.Pages;

/// <summary>解析页的模块身份。</summary>
public enum ParseKind
{
    X,
    Douyin,
    Bili,
}

/// <summary>
/// 解析页 —— X 主页 / 抖音解析下载 / B 站解析下载三页共用。
///
/// 现状（界面上如实标注）：
///   * B 站：已接真实接口 —— 粘链接解析稿件信息与可选清晰度，可入队下载；
///   * X / 抖音：解析逻辑已实现并有离线自测覆盖，但自动抓取需要登录态与
///     WebView2 注入，尚未接上；当前可下载 http/https 直链。
/// </summary>
public sealed partial class ParsePage : Page
{
    private MainWindow? _host;
    private ParseKind _kind = ParseKind.X;
    private TextBox? _input;
    private TextBlock? _status;
    private StackPanel? _resultPanel;
    private Button? _downloadBtn;
    private BiliVideoInfo? _biliInfo;
    private BiliPlayInfo? _biliPlay;
    private BiliApi? _biliApi;

    private sealed record Profile(
        string Title, string Subtitle, string Glyph, string Badge,
        string HeroTitle, string HeroSubtitle, string InputLabel,
        string InputHint, string ActionText, string ModuleName);

    private static Profile ProfileOf(ParseKind kind) => kind switch
    {
        ParseKind.X => new Profile(
            "X 主页", "下载 X 媒体文件", "\uE80F", "X",
            "下载 X 媒体", "粘贴推文链接或图片/视频直链",
            "媒体直链", "粘贴 http(s) 直链", "加入队列", "X 媒体"),
        ParseKind.Douyin => new Profile(
            "解析下载", "抖音媒体下载", "\uE768", "抖",
            "下载抖音媒体", "粘贴分享链接或直链",
            "媒体直链", "粘贴 http(s) 直链", "加入队列", "抖音"),
        _ => new Profile(
            "解析下载", "B 站稿件解析", "\uE768", "B",
            "解析 B 站稿件", "粘贴稿件链接，解析后选择清晰度下载",
            "稿件地址", "如 https://www.bilibili.com/video/BV1xx411c7mD", "解析", "B 站"),
    };

    public ParsePage() { InitializeComponent(); }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is ParseNavArgs args)
        {
            _kind = args.Kind;
            _host = args.Host;
        }
        Build();
    }

    private void Build()
    {
        Root.Children.Clear();
        var p = ProfileOf(_kind);
        Root.Children.Add(UiKit.PageHeader(p.Title, p.Subtitle, p.Glyph));

        var hero = new StackPanel { Spacing = 8 };
        var badgeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        badgeRow.Children.Add(new Border
        {
            Width = 36, Height = 36, CornerRadius = new CornerRadius(8),
            Background = UiKit.AccentFill,
            Child = new TextBlock
            {
                Text = p.Badge, FontSize = 16, FontWeight = FontWeights.SemiBold,
                Foreground = UiKit.OnAccentText,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        });
        badgeRow.Children.Add(new TextBlock
        {
            Text = p.HeroTitle, FontSize = 20, FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        hero.Children.Add(badgeRow);
        hero.Children.Add(new TextBlock { Text = p.HeroSubtitle, FontSize = 13, Opacity = 0.7 });
        Root.Children.Add(UiKit.Card(hero, 20));

        var inputPanel = new StackPanel { Spacing = 10 };
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _input = new TextBox
        {
            PlaceholderText = p.InputHint, Height = 36,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(_input, 0);
        row.Children.Add(_input);
        var actionBtn = new Button
        {
            Content = p.ActionText, Height = 36, MinWidth = 96,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        actionBtn.Click += async (_, _) => await OnPrimaryActionAsync();
        Grid.SetColumn(actionBtn, 1);
        row.Children.Add(actionBtn);
        inputPanel.Children.Add(row);
        _status = new TextBlock { Text = "", FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
        inputPanel.Children.Add(_status);
        Root.Children.Add(UiKit.SectionCard(p.InputLabel, inputPanel));

        _resultPanel = new StackPanel { Spacing = 8 };
        Root.Children.Add(UiKit.SectionCard("解析结果", _resultPanel, "B 站稿件的清晰度列表"));

        var notes = new StackPanel { Spacing = 6 };
        if (_kind == ParseKind.Bili)
        {
            notes.Children.Add(Bullet("已支持：BV 号 / 完整链接 / b23.tv 短链，解析稿件信息"));
            notes.Children.Add(Bullet("已支持：列出全部清晰度与音频档位，选中后可入队下载"));
            notes.Children.Add(Bullet("未登录只能取 480P；1080P 及以上需要登录（到「B 站设置」页扫码）"));
            notes.Children.Add(Bullet("下载完成后自动把视频流与音频流合并成成品 mp4（容器与开关在 B 站设置页）"));
            notes.Children.Add(Bullet("合集 / 系列 / 收藏夹 / UP 主投稿 → 到「批量下载」页勾选批量入队"));
        }
        else if (_kind == ParseKind.Douyin)
        {
            notes.Children.Add(Bullet("已支持：http / https 直链，交给 aria2 多线程下载"));
            notes.Children.Add(Bullet("已支持：分享链接解析与作品 JSON 解析（离线自测覆盖）"));
            notes.Children.Add(Bullet("未支持：自动抓取页面（需要 WebView2 注入，待接）"));
        }
        else
        {
            notes.Children.Add(Bullet("已支持：http / https 直链，交给 aria2 多线程下载"));
            notes.Children.Add(Bullet("已支持：推文 JSON 解析与图片 URL 归一化（离线自测覆盖）"));
            notes.Children.Add(Bullet("未支持：自动抓取时间线（需要登录态 + WebView2，待接）"));
        }
        Root.Children.Add(UiKit.SectionCard("能力说明", notes));
    }

    private static UIElement Bullet(string text)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new TextBlock { Text = "•", FontSize = 13, Opacity = 0.6 });
        row.Children.Add(new TextBlock { Text = text, FontSize = 13, Opacity = 0.85, TextWrapping = TextWrapping.Wrap });
        return row;
    }

    private async Task OnPrimaryActionAsync()
    {
        if (_kind == ParseKind.Bili) { await ParseBiliAsync(); return; }
        if (_input is null || _status is null) return;
        var url = _input.Text?.Trim() ?? "";
        var p = ProfileOf(_kind);
        _status.Text = "正在加入队列…";
        var (ok, msg) = await DownloadStore.Instance.AddAsync(url, p.ModuleName);
        _status.Text = ok ? ("已入队：" + msg + "，可到下载管理查看进度") : ("失败：" + msg);
        if (ok) _input.Text = "";
    }


    // ── B 站解析 ─────────────────────────────────────────────

    /// <summary>
    /// 解析一条 B 站链接。
    ///
    /// 修 bug（2026-10-25）三处：
    ///  1. av 号被拒：原实现直接返回「当前只支持 BV 号解析（av 号待接）」，
    ///     而 BiliLink 明明已经解析出了 Aid。现在 aid 也能解析（view 接口支持 aid）；
    ///  2. 合集 / 系列 / 收藏夹 / UP 主空间被塞进本页：原实现自己拉列表、自己
    ///     批量入队，与「批量下载」页重复且缺省选与节流。现在统一导到批量下载页；
    ///  3. 链接里有 p 参数（分P）时被忽略：原实现永远取第 0 个分P。
    ///     现在按链接里的 p 预选对应分P。
    /// </summary>
    private async Task ParseBiliAsync()
    {
        if (_input is null || _status is null || _resultPanel is null) return;
        var raw = _input.Text?.Trim() ?? "";
        _status.Text = "正在解析…";
        _resultPanel.Children.Clear();
        _biliInfo = null;
        _biliPlay = null;

        var target = raw;
        if (BiliLink.IsShortLink(raw))
        {
            try
            {
                using var http = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(15) };
                var resp = await http.GetAsync(raw.StartsWith("http") ? raw : "https://" + raw);
                target = resp.RequestMessage?.RequestUri?.ToString() ?? raw;
            }
            catch { }
        }

        var refInfo = BiliLink.Parse(target);
        if (refInfo is null)
        {
            _status.Text = "认不出这条链接。支持 BV 号 / av 号 / 完整视频链接 / b23.tv 短链；" +
                           "合集、系列、收藏夹、UP 主空间请到「批量下载」页。";
            return;
        }

        if (refInfo.IsList || refInfo.Mid is not null)
        {
            _status.Text = "这是列表类链接（合集 / 系列 / 收藏夹 / UP 主空间）。" +
                           "请到左侧「B 站下载 → 批量下载」页，那里可以勾选并批量入队。";
            return;
        }

        if (!refInfo.IsVideo)
        {
            _status.Text = "认不出这条链接。支持 BV 号 / av 号 / 完整视频链接 / b23.tv 短链。";
            return;
        }

        try
        {
            Cfg.Load();
            _biliApi = new BiliApi(Cfg.EffectiveCookie);

            _biliInfo = await _biliApi.GetVideoInfoAsync(refInfo.Bvid, refInfo.Aid);
            var info = _biliInfo;

            _resultPanel.Children.Add(new TextBlock
            {
                Text = info.Title, FontSize = 15, FontWeight = FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            _resultPanel.Children.Add(new TextBlock
            {
                Text = "UP：" + info.OwnerName + "　分P：" + info.Pages.Count +
                       "　时长：" + FormatDur(info.DurationSec) +
                       "　" + (Cfg.IsLoggedIn ? "已登录" : "未登录（最高只能取 480P）"),
                FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap,
            });

            // 分P 选择：链接里带 ?p=N 时预选第 N 个（1 基 → 0 基）
            var initialPage = 0;
            if (refInfo.PartIndex is int part && part >= 1 && part <= info.Pages.Count)
                initialPage = part - 1;

            ComboBox? pageBox = null;
            if (info.Pages.Count > 1)
            {
                pageBox = new ComboBox { MinWidth = 420, HorizontalAlignment = HorizontalAlignment.Left };
                foreach (var pg in info.Pages) pageBox.Items.Add("P" + pg.Page + "　" + pg.Title);
                pageBox.SelectedIndex = initialPage;
                _resultPanel.Children.Add(new TextBlock { Text = "选择分 P", FontSize = 12, Opacity = 0.6 });
                _resultPanel.Children.Add(pageBox);
            }

            // 画质上限：与 Flutter 版一致 —— 这里选的是**上限**，实际档位由账号权限决定
            var qualityRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            qualityRow.Children.Add(new TextBlock
            {
                Text = "画质上限", FontSize = 12, Opacity = 0.7,
                VerticalAlignment = VerticalAlignment.Center,
            });
            var qualityBox = new ComboBox { MinWidth = 200 };
            var qualityValues = Enum.GetValues<BiliQuality>();
            foreach (var q in qualityValues) qualityBox.Items.Add(BiliConfig.LabelOf(q));
            qualityBox.SelectedIndex = Array.IndexOf(qualityValues, Cfg.Quality);
            if (qualityBox.SelectedIndex < 0) qualityBox.SelectedIndex = 0;
            qualityRow.Children.Add(qualityBox);
            _resultPanel.Children.Add(qualityRow);

            _downloadBtn = new Button
            {
                Content = "下载选中清晰度", MinWidth = 150, IsEnabled = false,
                HorizontalAlignment = HorizontalAlignment.Left,
            };
            _downloadBtn.Click += async (_, _) => await EnqueueSelectedAsync();
            _resultPanel.Children.Add(_downloadBtn);

            _streamPageIndex = initialPage;
            if (pageBox is not null)
            {
                pageBox.SelectionChanged += async (_, _) =>
                {
                    if (_biliApi is not null && pageBox.SelectedIndex >= 0)
                        await LoadStreamsAsync(_biliApi, info, pageBox.SelectedIndex);
                };
            }
            qualityBox.SelectionChanged += async (_, _) =>
            {
                if (qualityBox.SelectedIndex >= 0)
                {
                    Cfg.Quality = qualityValues[qualityBox.SelectedIndex];
                    Cfg.Save();
                }
                if (_biliApi is not null) await LoadStreamsAsync(_biliApi, info, _streamPageIndex);
            };

            await LoadStreamsAsync(_biliApi, info, initialPage);
            _status.Text = "解析成功";
        }
        catch (Exception ex)
        {
            _status.Text = "解析失败：" + ex.Message;
        }
    }

    /// <summary>当前选中的分P 下标（0 基）—— 画质上限改了就按它重取。</summary>
    private int _streamPageIndex;

    /// <summary>
    /// 取某分P 的播放地址并按设置选流。
    ///
    /// 必须如实报告实际拿到的档位：用户选了 1080P60 但只拿到 1080P 是正常结果
    /// （B 站按账号权限裁），瞒着他说「已按 1080P60 下载」就是说谎。
    /// </summary>
    private async Task LoadStreamsAsync(BiliApi api, BiliVideoInfo info, int pageIndex)
    {
        if (_status is null || _resultPanel is null) return;
        if (pageIndex < 0 || pageIndex >= info.Pages.Count) return;
        _streamPageIndex = pageIndex;

        var page = info.Pages[pageIndex];
        if (page.Cid is not string cidStr || !long.TryParse(cidStr, out var cid))
        {
            _status.Text = "该分P没有 cid，取不到播放地址";
            return;
        }

        try
        {
            _biliPlay = await api.GetPlayInfoAsync(info.Bvid, cid, BiliConfig.QnOf(Cfg.Quality), info.Aid);
            var play = _biliPlay;
            var pair = BiliDownloadPlan.Plan(play, Cfg.Quality, Cfg.Codec);

            // 清掉上一次的流信息块 —— 分P 或上限变化后必须重画，
            // 否则每切一次分P 就往上叠一块（原实现叠了满屏的清晰度列表）。
            for (var i = _resultPanel.Children.Count - 1; i >= 0; i--)
            {
                if (_resultPanel.Children[i] is FrameworkElement fe && fe.Tag is string tag &&
                    tag == "stream-info")
                    _resultPanel.Children.RemoveAt(i);
            }

            var box = new StackPanel { Spacing = 6, Tag = "stream-info" };

            if (!pair.Usable)
            {
                box.Children.Add(new TextBlock
                {
                    Text = pair.Message ?? "取不到可下载的流",
                    FontSize = 13, TextWrapping = TextWrapping.Wrap,
                    Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(
                        Windows.UI.Color.FromArgb(255, 214, 90, 90)),
                });
            }
            else
            {
                var actualLabel = play.Videos
                    .FirstOrDefault(v => v.QualityId == pair.VideoQn)?.QualityLabel ?? ("Q" + pair.VideoQn);
                var capLabel = BiliConfig.LabelOf(Cfg.Quality);
                var degraded = Cfg.Quality != BiliQuality.Highest &&
                               !string.Equals(actualLabel, capLabel, StringComparison.OrdinalIgnoreCase);
                box.Children.Add(new TextBlock
                {
                    Text = "实际档位：" + actualLabel +
                           (pair.VideoCodec.Length > 0 ? " / " + pair.VideoCodec : "") +
                           (pair.Video is not null ? "　" + FormatSize(pair.Video.SizeBytes) : "") +
                           (degraded ? "（上限 " + capLabel + " 没取到，B 站按账号权限只给到这一档）" : ""),
                    FontSize = 13, TextWrapping = TextWrapping.Wrap,
                });
                box.Children.Add(new TextBlock
                {
                    Text = pair.Audio is not null
                        ? ("音频：" + pair.Audio.QualityLabel + "　" + FormatSize(pair.Audio.SizeBytes) +
                           (pair.NeedsMerge
                               ? "　→ 下载完成后自动合并成 " + BiliConfig.IdOf(Cfg.Container).ToUpperInvariant()
                               : ""))
                        : "音频：无独立音轨（这个文件本身就是完整成品，不需要合并）",
                    FontSize = 12, Opacity = 0.65, TextWrapping = TextWrapping.Wrap,
                });
                box.Children.Add(new TextBlock
                {
                    Text = "候选：" + string.Join(" / ", play.Videos.Select(v =>
                        v.QualityLabel + (v.Codec.Length > 0 ? "-" + v.Codec : ""))),
                    FontSize = 11, Opacity = 0.5, TextWrapping = TextWrapping.Wrap,
                });
                if (!Cfg.MergeAfterDownload && pair.NeedsMerge)
                {
                    box.Children.Add(new TextBlock
                    {
                        Text = "提示：自动合并当前是关的，两条流下完不会自动合成品。" +
                               "可在 B 站设置页打开，或在那里点「扫描并合并待处理」。",
                        FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap,
                    });
                }
            }

            _resultPanel.Children.Add(box);
            if (_downloadBtn is not null) _downloadBtn.IsEnabled = pair.Usable;
        }
        catch (Exception ex)
        {
            _status.Text = "取播放地址失败：" + ex.Message;
        }
    }

    /// <summary>
    /// 入队选中清晰度。
    ///
    /// 修 bug（2026-10-25）四处：
    ///  1. 两条流落成同名的 .mp4 / .m4a：原实现视频写 name.mp4、音频写 name.m4a，
    ///     而自动合并靠「同一 base 名配对」，同 base 又同名会让产物覆盖视频源。
    ///     现在按契约落成 name.video.m4s / name.audio.m4s；
    ///  2. 音频只取 Audios[0]：那是按 id 排的（30216 的 id 更小却更差）。
    ///     现在走 BiliDownloadPlan，按码率取最高；
    ///  3. 没有音频流时照样只下视频：DASH 的视频流单独不是可播放文件，
    ///     下一个 0 秒空壳比明确报错更坏。现在判不可用并如实说明；
    ///  4. 附加文件在这里同步做完：弹幕/字幕/封面/章节/元数据现在走
    ///     BiliAdditionalRunner，失败进「没拿到」清单而不是静默吞。
    /// </summary>
    private async Task EnqueueSelectedAsync()
    {
        if (_biliPlay is null || _status is null || _biliInfo is null) return;
        var play = _biliPlay;
        var info = _biliInfo;
        var pageIndex = _streamPageIndex;
        var pageTitle = pageIndex >= 0 && pageIndex < info.Pages.Count ? info.Pages[pageIndex].Title : info.Title;
        var pageNo = pageIndex >= 0 && pageIndex < info.Pages.Count ? info.Pages[pageIndex].Page : 1;

        var pair = BiliDownloadPlan.Plan(play, Cfg.Quality, Cfg.Codec);
        if (!pair.Usable)
        {
            _status.Text = "不能入队：" + (pair.Message ?? "没取到可下载的流");
            return;
        }

        var saveDir = Cfg.ResolvedSaveDir;
        var outBase = MakeOutBase(info, pageTitle, pageNo, pair);
        _status.Text = "正在入队…";

        // ── 主产物：视频流（durl 退化路径直接一个成品文件）───────────────
        var videoName = pair.IsDash
            ? BiliDownloadPlan.VideoStreamName(outBase)
            : BiliDownloadPlan.MergedName(outBase, Cfg.Container);
        var (ok, msg) = await DownloadStore.Instance.AddAsync(pair.Video!.Url, "B 站", saveDir, videoName);
        if (!ok) { _status.Text = "视频入队失败：" + msg; return; }

        var notes = new List<string> { "视频已入队（" + pair.Video.QualityLabel + "）" };

        // ── 音频流：DASH 必须两条一起下，否则下下来没声音 ──────────────
        if (pair.IsDash && pair.Audio is not null)
        {
            var (ok2, msg2) = await DownloadStore.Instance.AddAsync(
                pair.Audio.Url, "B 站（音频）", saveDir, BiliDownloadPlan.AudioStreamName(outBase));
            if (ok2) notes.Add("音频已入队（" + pair.Audio.QualityLabel + "）");
            else notes.Add("音频入队失败：" + msg2 + "（只下视频会没有声音）");
        }

        // ── 附加文件：不走 aria2，接口拉回来直接写盘 ──────────────────
        try
        {
            var outcome = await BiliAdditionalRunner.ProduceAsync(
                new BiliApi(Cfg.EffectiveCookie), Cfg, saveDir, outBase, info, play.Cid,
                pageTitle, pageNo);
            if (outcome.Written.Count > 0)
                notes.Add("附加文件 " + outcome.Written.Count + " 个：" + string.Join("、", outcome.Written));
            if (outcome.Missing.Count > 0)
                notes.Add("没拿到：" + string.Join("、", outcome.Missing));
        }
        catch (Exception ex)
        {
            notes.Add("附加文件失败：" + ex.Message);
        }

        if (pair.NeedsMerge)
        {
            notes.Add(Cfg.MergeAfterDownload
                ? "下载完成后会自动合并为 " + outBase + "." + BiliConfig.IdOf(Cfg.Container)
                : "已关闭自动合并，到 B 站设置页可手动补跑");
        }

        _status.Text = string.Join("；", notes) + "。可到下载管理查看进度。";
    }

    /// <summary>
    /// 按模板算 base 名（不含扩展名）—— 两条流与合并产物共用它，配对全靠这个名字。
    ///
    /// 模板里可能带 %EXT%（渲染成 mp4），base 名必须把这段尾巴剥掉，
    /// 否则会落成「冬天.mp4.video.m4s」，配对扫描就认不出来了。
    /// </summary>
    private string MakeOutBase(BiliVideoInfo info, string pageTitle, int pageNo, BiliStreamPair pair)
    {
        var tpl = string.IsNullOrWhiteSpace(Cfg.FileNameTemplate)
            ? "%BILI_TITLE%-%POST_ID%" : Cfg.FileNameTemplate;
        var title = string.IsNullOrWhiteSpace(pageTitle) || info.Pages.Count <= 1
            ? info.Title
            : (info.Title + "-" + pageTitle);
        var ctx = new TemplateContext
        {
            PostId = info.Bvid,
            MediaId = info.Bvid,
            UserId = info.OwnerMid.ToString(),
            UserName = info.OwnerName,
            UserScreenName = info.OwnerName,
            BiliTitle = title,
            BiliPageIndex = pageNo,
            BiliQuality = BiliApi.QualityNames.TryGetValue(pair.VideoQn, out var ql) ? ql : "",
            MediaIndex = 1,
            PostTime = info.PubDateUnix > 0
                ? DateTimeOffset.FromUnixTimeSeconds(info.PubDateUnix).LocalDateTime
                : null,
            Extension = "mp4",
        };
        var rendered = FileNameTemplate.UnicodeFilenamify(FileNameTemplate.Resolve(tpl, ctx));
        if (string.IsNullOrWhiteSpace(rendered)) rendered = info.Bvid;
        return BiliDownloadPlan.BaseNameFromFileName(rendered);
    }

    private BiliConfig Cfg => BiliConfig.Instance;

    private static string FormatDur(int sec)
    {
        if (sec >= 3600)
            return (sec / 3600) + ":" + (sec % 3600 / 60).ToString("00") + ":" + (sec % 60).ToString("00");
        return (sec / 60) + ":" + (sec % 60).ToString("00");
    }

    private static string FormatSize(long bytes)
    {
        if (bytes <= 0) return "大小未知";
        string[] units = { "B", "KB", "MB", "GB" };
        double v = bytes; var i = 0;
        while (v >= 1024 && i < units.Length - 1) { v /= 1024; i++; }
        return v.ToString("0.#") + " " + units[i];
    }
}


/// <summary>导航参数：告诉 ParsePage 该显示哪个模块。</summary>
public sealed record ParseNavArgs(ParseKind Kind, MainWindow Host);