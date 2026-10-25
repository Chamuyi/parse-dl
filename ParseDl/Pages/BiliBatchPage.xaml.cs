using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.Bili;

namespace ParseDl.Pages;

/// <summary>
/// B 站批量下载页 —— 对齐 Flutter 版 lib/pages/bili_batch_page.dart（720 行）。
///
/// 覆盖四类列表：主页（UP 主投稿）/ 合集 / 系列 / 收藏夹。
///
/// 为什么必须逐条取流：列表接口只给概要（bvid + 标题 + 时长），播放地址要**单独**
/// 请求 playurl，所以批量入队必须逐条、带节流（连着打会被风控）。
/// 这一层的编排（节流 / 进度 / 成功失败计数）与 Flutter 版 bili_batch_runner.dart
/// 同一套口径：一条失败不影响后面，最后如实报「成功 N 失败 M」。
/// </summary>
public sealed partial class BiliBatchPage : Page
{
    private BiliConfig Cfg => BiliConfig.Instance;

    private TextBox? _urlBox;
    private TextBlock? _status;
    private StackPanel? _listPanel;
    private Button? _enqueueBtn;
    private CancellationTokenSource? _cts;

    private List<BiliListItem> _items = new();
    private readonly List<(BiliListItem Item, CheckBox Box)> _rows = new();
    private string _kindLabel = "";

    public BiliBatchPage() { InitializeComponent(); }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Cfg.Load();
        Build();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        try { _cts?.Cancel(); } catch { }
        _cts = null;
    }

    private void Build()
    {
        Root.Children.Clear();
        Root.Children.Add(UiKit.PageHeader("批量下载", "主页 · 合集 · 系列 · 收藏夹", "\uE8EF"));

        // ── 输入区 ─────────────────────────────────────────────
        var input = new StackPanel { Spacing = 10 };
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _urlBox = new TextBox
        {
            PlaceholderText = "粘贴 UP 主空间 / 合集 / 系列 / 收藏夹链接，如 https://space.bilibili.com/546195",
            Height = 36,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(_urlBox, 0);
        row.Children.Add(_urlBox);

        var loadBtn = new Button
        {
            Content = "加载列表", Height = 36, MinWidth = 96,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        loadBtn.Click += async (_, _) => await LoadListAsync();
        Grid.SetColumn(loadBtn, 1);
        row.Children.Add(loadBtn);
        input.Children.Add(row);

        _status = new TextBlock
        {
            Text = "", FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap,
        };
        input.Children.Add(_status);

        input.Children.Add(new TextBlock
        {
            Text = "支持的链接：\n" +
                   "  · UP 主投稿  https://space.bilibili.com/546195\n" +
                   "  · 合集       https://space.bilibili.com/228292951/channel/collectiondetail?sid=9225450\n" +
                   "  · 系列       https://space.bilibili.com/228292951/channel/seriesdetail?sid=88\n" +
                   "  · 收藏夹     https://www.bilibili.com/medialist/detail/ml152431",
            FontSize = 12, Opacity = 0.6, TextWrapping = TextWrapping.Wrap,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
        });
        Root.Children.Add(UiKit.SectionCard("列表地址", input));

        // ── 结果区 ─────────────────────────────────────────────
        _listPanel = new StackPanel { Spacing = 2 };
        Root.Children.Add(UiKit.SectionCard("列表内容", _listPanel, "默认全选，取消勾选可跳过"));

        // ── 批量操作条 ─────────────────────────────────────────
        var ops = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var allBtn = new Button { Content = "全选", MinWidth = 80 };
        allBtn.Click += (_, _) => SetAll(true);
        var noneBtn = new Button { Content = "全不选", MinWidth = 80 };
        noneBtn.Click += (_, _) => SetAll(false);
        var invertBtn = new Button { Content = "反选", MinWidth = 80 };
        invertBtn.Click += (_, _) =>
        {
            foreach (var (_, box) in _rows) box.IsChecked = box.IsChecked != true;
            UpdateSelectionHint();
        };
        _enqueueBtn = new Button
        {
            Content = "批量入队选中", MinWidth = 140, IsEnabled = false,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        _enqueueBtn.Click += async (_, _) => await EnqueueSelectedAsync();
        ops.Children.Add(allBtn);
        ops.Children.Add(noneBtn);
        ops.Children.Add(invertBtn);
        ops.Children.Add(_enqueueBtn);

        var opsPanel = new StackPanel { Spacing = 8 };
        opsPanel.Children.Add(ops);
        opsPanel.Children.Add(new TextBlock
        {
            Text = "批量入队会逐条请求播放地址，每条之间等 " + Cfg.RequestIntervalMs +
                   " 毫秒（可在 B 站设置里改）—— 连着打会触发风控。",
            FontSize = 12, Opacity = 0.6, TextWrapping = TextWrapping.Wrap,
        });
        Root.Children.Add(UiKit.SectionCard("批量操作", opsPanel));
    }

    private void SetAll(bool value)
    {
        foreach (var (_, box) in _rows) box.IsChecked = value;
        UpdateSelectionHint();
    }

    private void UpdateSelectionHint()
    {
        if (_enqueueBtn is null) return;
        var picked = _rows.Count(r => r.Box.IsChecked == true);
        _enqueueBtn.IsEnabled = picked > 0;
        _enqueueBtn.Content = picked > 0 ? ("批量入队选中（" + picked + "）") : "批量入队选中";
    }

    // ── 加载列表 ─────────────────────────────────────────────

    private async Task LoadListAsync()
    {
        if (_urlBox is null || _status is null || _listPanel is null) return;
        var raw = _urlBox.Text?.Trim() ?? "";
        if (raw.Length == 0) { _status.Text = "请先粘贴列表链接"; return; }

        _listPanel.Children.Clear();
        _rows.Clear();
        _items = new List<BiliListItem>();
        UpdateSelectionHint();
        _status.Text = "正在加载列表…";

        try
        {
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
                _status.Text = "认不出这条链接。支持 UP 主空间 / 合集 / 系列 / 收藏夹。";
                return;
            }

            var api = new BiliApi(Cfg.Cookie);
            var listApi = new BiliListApi(api);

            BiliListPage page;
            if (refInfo.SeasonId is long seasonId)
            {
                if (refInfo.Mid is not long mid)
                {
                    _status.Text = "合集链接里没有 mid。请用 space.bilibili.com/<mid>/channel/collectiondetail?sid=… 这种形态。";
                    return;
                }
                page = await listApi.GetSeasonArchivesAsync(mid, seasonId);
                _kindLabel = "合集";
            }
            else if (refInfo.SeriesId is long seriesId)
            {
                if (refInfo.Mid is not long mid2)
                {
                    _status.Text = "系列链接里没有 mid。请用 space.bilibili.com/<mid>/channel/seriesdetail?sid=… 这种形态。";
                    return;
                }
                page = await listApi.GetSeriesArchivesAsync(mid2, seriesId);
                _kindLabel = "系列";
            }
            else if (refInfo.FavId is long favId)
            {
                page = await listApi.GetFavAsync(favId);
                _kindLabel = "收藏夹";
            }
            else if (refInfo.Mid is long mid3)
            {
                page = await listApi.GetSpaceVideosAsync(mid3, 1, 30);
                _kindLabel = "UP 主投稿";
            }
            else
            {
                _status.Text = "这条链接不是列表（列表 = UP 主空间 / 合集 / 系列 / 收藏夹）。单个稿件请到「解析下载」页。";
                return;
            }

            _items = page.Items.ToList();
            if (_items.Count == 0)
            {
                _status.Text = _kindLabel + "是空的（或该收藏夹不公开）";
                return;
            }

            var header = new TextBlock
            {
                Text = _kindLabel + "：共 " + _items.Count + " 个稿件" +
                       (page.Total > _items.Count ? "（接口报告总数 " + page.Total + "）" : ""),
                FontSize = 14, FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(0, 0, 0, 8),
            };
            _listPanel.Children.Add(header);

            foreach (var it in _items)
            {
                var box = new CheckBox { IsChecked = true, FontSize = 13 };
                var texts = new StackPanel { Spacing = 1 };
                texts.Children.Add(new TextBlock
                {
                    Text = it.Title, FontSize = 13, TextWrapping = TextWrapping.Wrap,
                });
                texts.Children.Add(new TextBlock
                {
                    Text = it.Bvid + "　" + FormatDur(it.DurationSec),
                    FontSize = 11, Opacity = 0.6,
                });
                var cell = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                cell.Children.Add(box);
                cell.Children.Add(texts);

                box.Checked += (_, _) => UpdateSelectionHint();
                box.Unchecked += (_, _) => UpdateSelectionHint();

                _listPanel.Children.Add(cell);
                _rows.Add((it, box));
            }

            UpdateSelectionHint();
            _status.Text = "列表加载成功，默认全选。点「批量入队选中」开始。";
        }
        catch (Exception ex)
        {
            _status.Text = "加载列表失败：" + ex.Message;
        }
    }

    // ── 批量入队 ─────────────────────────────────────────────

    /// <summary>
    /// 批量入队：逐条取播放地址再入队。
    ///
    /// 两条流用**契约命名**入队（base 名 + .video.m4s / .audio.m4s），
    /// 这样下载完成后 BiliMergePipeline 能靠名字直接配对，不需要额外的映射表
    /// （映射表在重启后就丢了，而文件名不会）。
    /// </summary>
    private async Task EnqueueSelectedAsync()
    {
        if (_status is null || _enqueueBtn is null) return;
        var picked = _rows.Where(r => r.Box.IsChecked == true).Select(r => r.Item).ToList();
        if (picked.Count == 0) { _status.Text = "没有选中任何稿件"; return; }

        _enqueueBtn.IsEnabled = false;
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;

        var api = new BiliApi(Cfg.Cookie);
        var interval = Math.Max(300, Cfg.RequestIntervalMs);
        var ok = 0; var skipped = 0; var fail = 0;
        var failures = new List<string>();
        var saveDir = Cfg.ResolvedSaveDir;

        for (var i = 0; i < picked.Count; i++)
        {
            if (ct.IsCancellationRequested) break;
            var it = picked[i];
            _status.Text = "批量入队 " + (i + 1) + "/" + picked.Count + "：" + it.Title;
            try
            {
                var info = await api.GetVideoInfoAsync(it.Bvid, null, ct);
                if (info.Pages.Count == 0) { fail++; failures.Add(it.Title + "：没有分P"); continue; }

                var cidStr = info.Pages[0].Cid;
                if (cidStr is null || !long.TryParse(cidStr, out var cid)) { fail++; failures.Add(it.Title + "：没有 cid"); continue; }

                var play = await api.GetPlayInfoAsync(
                    info.Bvid, cid, BiliConfig.QnOf(Cfg.Quality), null, ct);
                var pair = BiliDownloadPlan.Plan(play, Cfg.Quality, Cfg.Codec);
                if (!pair.Usable)
                {
                    fail++;
                    failures.Add(it.Title + "：" + (pair.Message ?? "取不到可下载的流"));
                    continue;
                }

                var outBase = BuildOutBase(info, it, pair);
                var videoName = pair.IsDash
                    ? BiliDownloadPlan.VideoStreamName(outBase)
                    : outBase + ".mp4";

                var (a, msg) = await DownloadStore.Instance.AddAsync(
                    pair.Video!.Url, "B 站", saveDir, videoName);
                if (!a) { fail++; failures.Add(it.Title + "：" + msg); continue; }

                if (pair.IsDash && pair.Audio is not null)
                {
                    var (a2, msg2) = await DownloadStore.Instance.AddAsync(
                        pair.Audio.Url, "B 站（音频）", saveDir,
                        BiliDownloadPlan.AudioStreamName(outBase));
                    if (!a2)
                    {
                        // 音频没入队就等于下一个没声音的空壳 —— 记失败，不粉饰。
                        fail++;
                        failures.Add(it.Title + "：音频入队失败（" + msg2 + "）");
                        continue;
                    }
                }
                ok++;
            }
            catch (Exception ex)
            {
                fail++;
                failures.Add(it.Title + "：" + ex.Message);
            }

            if (i < picked.Count - 1) await Task.Delay(interval, ct);
        }

        var sb = new System.Text.StringBuilder();
        sb.Append("批量入队完成：成功 " + ok + "，失败 " + fail);
        if (skipped > 0) sb.Append("，跳过 " + skipped);
        sb.Append("。");
        if (failures.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("失败明细（前 10 条）：");
            foreach (var f in failures.Take(10)) sb.AppendLine("  · " + f);
        }
        _status.Text = sb.ToString();
        _enqueueBtn.IsEnabled = true;
        UpdateSelectionHint();
    }

    /// <summary>按模板算 base 名（不含扩展名）—— 合并产物与两条流共用它。</summary>
    private string BuildOutBase(BiliVideoInfo info, BiliListItem item, BiliStreamPair pair)
    {
        var tpl = string.IsNullOrWhiteSpace(Cfg.FileNameTemplate)
            ? "%BILI_TITLE%-%POST_ID%" : Cfg.FileNameTemplate;
        var ctx = new TemplateContext
        {
            PostId = info.Bvid,
            MediaId = info.Bvid,
            UserId = info.OwnerMid.ToString(),
            UserName = info.OwnerName,
            UserScreenName = info.OwnerName,
            BiliTitle = string.IsNullOrWhiteSpace(item.Title) ? info.Title : item.Title,
            BiliPageIndex = info.Pages.Count > 0 ? info.Pages[0].Page : 1,
            BiliQuality = BiliApi.QualityNames.TryGetValue(pair.VideoQn, out var ql) ? ql : "",
            MediaIndex = 1,
            PostTime = info.PubDateUnix > 0
                ? DateTimeOffset.FromUnixTimeSeconds(info.PubDateUnix).LocalDateTime
                : null,
            Extension = "mp4",
        };
        var name = FileNameTemplate.UnicodeFilenamify(FileNameTemplate.Resolve(tpl, ctx));
        if (string.IsNullOrWhiteSpace(name)) name = info.Bvid;
        // 模板里可能带 %EXT%（会渲染成 mp4），base 名必须把这段尾巴剥掉，
        // 否则会落成 冬天.mp4.video.m4s。
        return BiliDownloadPlan.BaseNameFromFileName(name);
    }

    private static string FormatDur(int sec)
    {
        if (sec >= 3600)
            return (sec / 3600) + ":" + (sec % 3600 / 60).ToString("00") + ":" + (sec % 60).ToString("00");
        return (sec / 60) + ":" + (sec % 60).ToString("00");
    }
}
