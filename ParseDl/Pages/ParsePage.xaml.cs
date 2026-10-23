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
    private ComboBox? _qualityBox;
    private Button? _downloadBtn;
    private BiliVideoInfo? _biliInfo;
    private BiliPlayInfo? _biliPlay;
    private BiliApi? _biliApi;
    private BiliListApi? _listApi;
    private List<BiliListItem> _batchItems = new();
    private StackPanel? _batchPanel;

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
            notes.Children.Add(Bullet("未登录只能取 480P；1080P 及以上需要登录（登录功能待接）"));
            notes.Children.Add(Bullet("未支持：合集 / 系列 / 收藏夹批量（接口已实现，界面待接）"));
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

    private async Task ParseBiliAsync()
    {
        if (_input is null || _status is null || _resultPanel is null) return;
        var raw = _input.Text?.Trim() ?? "";
        _status.Text = "正在解析…";
        _resultPanel.Children.Clear();
        _biliInfo = null; _biliPlay = null;

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
            _status.Text = "认不出这条链接。支持 BV 号、完整视频链接、b23.tv 短链、合集/系列/收藏夹/UP 主空间。";
            return;
        }

        // 列表链接走批量流程
        if (refInfo.IsList || refInfo.Mid is not null)
        {
            await LoadBatchListAsync(refInfo);
            return;
        }

        if (!refInfo.IsVideo)
        {
            _status.Text = "认不出这条链接。支持 BV 号、完整视频链接、b23.tv 短链、合集/系列/收藏夹/UP 主空间。";
            return;
        }

        try
        {
            _biliApi = new BiliApi(AppSettings.Instance.ForModule("bili").Cookie);
            if (string.IsNullOrEmpty(refInfo.Bvid))
            {
                _status.Text = "当前只支持 BV 号解析（av 号待接）";
                return;
            }

            _biliInfo = await _biliApi.GetVideoInfoAsync(refInfo.Bvid);
            var info = _biliInfo;

            _resultPanel.Children.Add(new TextBlock
            {
                Text = info.Title, FontSize = 15, FontWeight = FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            _resultPanel.Children.Add(new TextBlock
            {
                Text = "UP：" + info.OwnerName + "　分P：" + info.Pages.Count
                       + "　时长：" + FormatDur(info.DurationSec),
                FontSize = 12, Opacity = 0.7,
            });

            if (info.Pages.Count > 1)
            {
                var pageBox = new ComboBox { MinWidth = 340, HorizontalAlignment = HorizontalAlignment.Left };
                foreach (var pg in info.Pages) pageBox.Items.Add("P" + pg.Page + "　" + pg.Title);
                pageBox.SelectedIndex = 0;
                _resultPanel.Children.Add(new TextBlock { Text = "选择分 P", FontSize = 12, Opacity = 0.6 });
                _resultPanel.Children.Add(pageBox);
                pageBox.SelectionChanged += async (_, _) =>
                {
                    if (_biliApi is not null) await LoadStreamsAsync(_biliApi, info, pageBox.SelectedIndex);
                };
            }

            _downloadBtn = new Button
            {
                Content = "下载选中清晰度", MinWidth = 140, IsEnabled = false,
                HorizontalAlignment = HorizontalAlignment.Left,
            };
            _downloadBtn.Click += async (_, _) => await EnqueueSelectedAsync();
            _resultPanel.Children.Add(_downloadBtn);

            await LoadStreamsAsync(_biliApi, info, 0);
            _status.Text = "解析成功";
        }
        catch (Exception ex)
        {
            _status.Text = "解析失败：" + ex.Message;
        }
    }

    private async Task LoadStreamsAsync(BiliApi api, BiliVideoInfo info, int pageIndex)
    {
        if (_status is null || _resultPanel is null) return;
        if (pageIndex < 0 || pageIndex >= info.Pages.Count) return;
        var page = info.Pages[pageIndex];
        if (page.Cid is not string cidStr || !long.TryParse(cidStr, out var cid))
        {
            _status.Text = "该分P没有 cid，取不到播放地址";
            return;
        }

        try
        {
            _biliPlay = await api.GetPlayInfoAsync(info.Bvid, cid);
            var play = _biliPlay;

            _qualityBox = new ComboBox { MinWidth = 380, HorizontalAlignment = HorizontalAlignment.Left };
            foreach (var v in play.Videos)
            {
                var label = v.QualityLabel + (v.Codec.Length > 0 ? " / " + v.Codec : "");
                _qualityBox.Items.Add(label + "　" + FormatSize(v.SizeBytes));
            }
            if (play.Videos.Count > 0) _qualityBox.SelectedIndex = 0;

            _resultPanel.Children.Add(new TextBlock
            {
                Text = "视频清晰度（" + play.Videos.Count + " 条）",
                FontSize = 12, Opacity = 0.6,
            });
            _resultPanel.Children.Add(_qualityBox);
            _resultPanel.Children.Add(new TextBlock
            {
                Text = play.Audios.Count > 0
                    ? ("音频档位：" + string.Join(" / ", play.Audios.Select(a => a.QualityLabel)))
                    : "无独立音频流",
                FontSize = 12, Opacity = 0.6, TextWrapping = TextWrapping.Wrap,
            });
            if (_downloadBtn is not null) _downloadBtn.IsEnabled = play.Videos.Count > 0;
        }
        catch (Exception ex)
        {
            _status.Text = "取播放地址失败：" + ex.Message;
        }
    }

    private async Task EnqueueSelectedAsync()
    {
        if (_biliPlay is null || _qualityBox is null || _status is null || _biliInfo is null) return;
        var idx = _qualityBox.SelectedIndex;
        if (idx < 0 || idx >= _biliPlay.Videos.Count) return;

        var video = _biliPlay.Videos[idx];
        var name = MakeFileName();

        var (ok, msg) = await DownloadStore.Instance.AddAsync(video.Url, "B 站", null, name + ".mp4");
        _status.Text = ok ? ("视频已入队（" + video.QualityLabel + "）") : ("视频入队失败：" + msg);

        // 音视频分离的稿件必须单独下音频，否则下下来没声音
        if (ok && _biliPlay.Audios.Count > 0)
        {
            var audio = _biliPlay.Audios[0];
            var (ok2, msg2) = await DownloadStore.Instance.AddAsync(audio.Url, "B 站（音频）", null, name + ".m4a");
            _status.Text += ok2 ? ("；音频已入队（" + audio.QualityLabel + "）") : ("；音频入队失败：" + msg2);
        }
        _status.Text += "。可到下载管理查看进度。";
    }

    /// <summary>
    /// 列表批量下载 —— 合集 / 系列 / 收藏夹 / UP 主投稿。
    ///
    /// 为什么单独一条路径：列表里每个稿件的播放地址都要**单独请求** playurl，
    /// 不能靠一次请求拿全，所以这里必须逐条、带节流（否则触发风控）。
    /// </summary>
    private async Task LoadBatchListAsync(BiliRef refInfo)
    {
        if (_status is null || _resultPanel is null) return;
        _status.Text = "正在加载列表…";

        try
        {
            _listApi ??= new BiliListApi(new BiliApi(AppSettings.Instance.ForModule("bili").Cookie));

            BiliListPage page;
            var kind = "";
            if (refInfo.SeasonId is long seasonId && refInfo.Mid is long mid1)
            {
                page = await _listApi.GetSeasonArchivesAsync(mid1, seasonId);
                kind = "合集";
            }
            else if (refInfo.SeriesId is long seriesId && refInfo.Mid is long mid2)
            {
                page = await _listApi.GetSeriesArchivesAsync(mid2, seriesId);
                kind = "系列";
            }
            else if (refInfo.FavId is long favId)
            {
                page = await _listApi.GetFavAsync(favId);
                kind = "收藏夹";
            }
            else if (refInfo.Mid is long mid3)
            {
                page = await _listApi.GetSpaceVideosAsync(mid3);
                kind = "UP 主投稿";
            }
            else
            {
                _status.Text = "列表链接里缺少必要参数（合集要 mid+season_id，系列要 mid+series_id）";
                return;
            }

            _batchItems = page.Items.ToList();
            if (_batchItems.Count == 0)
            {
                _status.Text = "列表" + kind + "是空的（或该收藏夹不公开）";
                return;
            }

            _resultPanel.Children.Add(new TextBlock
            {
                Text = kind + "：共 " + _batchItems.Count + " 个稿件"
                       + (page.Total > _batchItems.Count ? "（接口报告总数 " + page.Total + "，本页 " + _batchItems.Count + "）" : ""),
                FontSize = 15, FontWeight = FontWeights.SemiBold,
            });

            _batchPanel = new StackPanel { Spacing = 4 };
            foreach (var it in _batchItems)
            {
                var cb = new CheckBox
                {
                    Content = it.Title + "　" + FormatDur(it.DurationSec),
                    IsChecked = true,
                    FontSize = 13,
                };
                _batchPanel.Children.Add(cb);
            }
            _resultPanel.Children.Add(_batchPanel);

            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var selectAll = new Button { Content = "全选", MinWidth = 80 };
            selectAll.Click += (_, _) =>
            {
                foreach (var c in _batchPanel!.Children.OfType<CheckBox>()) c.IsChecked = true;
            };
            var selectNone = new Button { Content = "全不选", MinWidth = 80 };
            selectNone.Click += (_, _) =>
            {
                foreach (var c in _batchPanel!.Children.OfType<CheckBox>()) c.IsChecked = false;
            };
            var batchBtn = new Button
            {
                Content = "批量下载选中", MinWidth = 130,
                Style = (Style)Application.Current.Resources["AccentButtonStyle"],
            };
            batchBtn.Click += async (_, _) => await EnqueueBatchAsync(batchBtn);
            row.Children.Add(selectAll);
            row.Children.Add(selectNone);
            row.Children.Add(batchBtn);
            _resultPanel.Children.Add(row);

            _status.Text = "列表加载成功。默认全选，点「批量下载选中」逐条入队。";
        }
        catch (Exception ex)
        {
            _status.Text = "加载列表失败：" + ex.Message;
        }
    }

    /// <summary>
    /// 批量入队：逐条取播放地址再入队。
    /// **必须节流** —— 列表里每个稿件都要单独请求 playurl，连着打会被 B 站风控。
    /// </summary>
    private async Task EnqueueBatchAsync(Button trigger)
    {
        if (_batchPanel is null || _status is null || _listApi is null) return;
        var boxes = _batchPanel.Children.OfType<CheckBox>().ToList();
        var picked = new List<BiliListItem>();
        for (var i = 0; i < boxes.Count && i < _batchItems.Count; i++)
            if (boxes[i].IsChecked == true) picked.Add(_batchItems[i]);

        if (picked.Count == 0) { _status.Text = "没有选中任何稿件"; return; }

        trigger.IsEnabled = false;
        var interval = Math.Max(300, AppSettings.Instance.ForModule("bili").RequestIntervalMs);
        var api = new BiliApi(AppSettings.Instance.ForModule("bili").Cookie);
        var ok = 0; var fail = 0;

        for (var i = 0; i < picked.Count; i++)
        {
            var it = picked[i];
            _status.Text = "批量入队 " + (i + 1) + "/" + picked.Count + "：" + it.Title;
            try
            {
                var info = await api.GetVideoInfoAsync(it.Bvid);
                if (info.Pages.Count == 0) { fail++; continue; }
                var cid = info.Pages[0].Cid;
                if (cid is not string cidStr || !long.TryParse(cidStr, out var cidVal)) { fail++; continue; }

                var play = await api.GetPlayInfoAsync(it.Bvid, cidVal);
                if (play.Videos.Count == 0) { fail++; continue; }

                var settings = AppSettings.Instance.ForModule("bili");
                var tpl = string.IsNullOrWhiteSpace(settings.FileNameTemplate)
                    ? "%BILI_TITLE%-%POST_ID%" : settings.FileNameTemplate;
                var ctx = new TemplateContext
                {
                    PostId = it.Bvid, MediaId = it.Bvid,
                    UserName = info.OwnerName, BiliTitle = it.Title,
                };
                var name = FileNameTemplate.UnicodeFilenamify(FileNameTemplate.Resolve(tpl, ctx));
                if (string.IsNullOrWhiteSpace(name)) name = it.Bvid;

                var (a, _) = await DownloadStore.Instance.AddAsync(play.Videos[0].Url, "B 站", null, name + ".mp4");
                if (!a) { fail++; continue; }
                ok++;

                if (play.Audios.Count > 0)
                {
                    await DownloadStore.Instance.AddAsync(play.Audios[0].Url, "B 站（音频）", null, name + ".m4a");
                }
            }
            catch
            {
                fail++;
            }

            if (i < picked.Count - 1) await Task.Delay(interval);
        }

        _status.Text = "批量入队完成：成功 " + ok + "，失败 " + fail + "。可到下载管理查看进度。";
        trigger.IsEnabled = true;
    }

    /// <summary>按模板生成文件名（B 站默认用 标题-BV号）。</summary>
    private string MakeFileName()
    {
        var info = _biliInfo!;
        var settings = AppSettings.Instance.ForModule("bili");
        var tpl = string.IsNullOrWhiteSpace(settings.FileNameTemplate)
            ? "%BILI_TITLE%-%POST_ID%" : settings.FileNameTemplate;
        var ctx = new TemplateContext
        {
            PostId = info.Bvid,
            UserName = info.OwnerName,
            MediaId = info.Bvid,
            BiliTitle = info.Title,
        };
        var f = FileNameTemplate.UnicodeFilenamify(FileNameTemplate.Resolve(tpl, ctx));
        return string.IsNullOrWhiteSpace(f) ? info.Bvid : f;
    }

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