using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Web.WebView2.Core;
using ParseDl.Controls;
using ParseDl.Services;
using ParseDl.Services.Bili;

namespace ParseDl.Pages;

/// <summary>
/// B 站批量下载 —— 对齐 Flutter 版 lib/pages/bili_batch_page.dart 与原项目最终形态
/// （左边内嵌浏览器 + 右边批量面板）。
///
/// 为什么左边也要浏览器：找合集 / 收藏夹这件事本身就得在 B 站页面里点，
/// 让用户「在左边找到、把地址拷到右边」比让他在外面复制粘贴省一步。
///
/// 右侧七件事（照原项目）：
///  ① 说明文字；② 多行粘贴框；③ 「识别到 N 个目标」；④ 我的自建收藏夹；
///  ⑤ 每个列表最多下几条；⑥ 多 P 取全部 P 开关；⑦ 开始批量 / 停止。
/// </summary>
public sealed partial class BiliBatchPage : Page
{
    private BiliConfig Cfg => BiliConfig.Instance;
    private const string HomeUrl = "https://www.bilibili.com/";

    private bool _webReady;
    private CancellationTokenSource? _cts;
    private int _targetCount;
    private readonly List<string> _targets = new();

    /// <summary>「每个列表最多下几条」的档位。0 = 不限。</summary>
    private static readonly (string Label, int Value)[] Limits =
    {
        ("不限", 0), ("10 条", 10), ("20 条", 20), ("50 条", 50), ("100 条", 100),
    };

    public BiliBatchPage() { InitializeComponent(); }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Cfg.Load();
        HeaderHost.Children.Add(UiKit.PageHeader("B 站批量下载", "主页 / 合集 / 系列 / 收藏夹", "\uE8EF"));
        LimitBox.ItemsSource = Limits.Select(x => x.Label).ToArray();
        LimitBox.SelectedIndex = 0;
        TakeAllPartsSwitch.IsOn = false;
        UpdateTargetCount();
        _ = InitWebAsync();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        try { _cts?.Cancel(); } catch { }
        _cts = null;
    }

    // ── WebView2（左）──────────────────────────────────────

    private async Task InitWebAsync()
    {
        try
        {
            await Web.EnsureCoreWebView2Async();
            // 让页面里的 target=_blank / window.open 在**当前 WebView 内**打开，
            // 而不是弹系统浏览器（用户 2026-10-27 报 B 站点视频会开新窗口）。
            ParseDl.Controls.WebViewHelper.KeepNavigationInPlace(Web.CoreWebView2);
            Web.CoreWebView2.Settings.UserAgent =
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";
            Web.CoreWebView2.Settings.IsStatusBarEnabled = false;
            _webReady = true;
            WebFallback.Visibility = Visibility.Collapsed;
            Web.CoreWebView2.Navigate(HomeUrl);
        }
        catch (Exception ex)
        {
            WebFallback.Visibility = Visibility.Visible;
            WebFallbackText.Text = "内嵌浏览器初始化失败：" + ex.Message;
        }
    }

    // ── 粘贴框 → 目标识别 ──────────────────────────────────

    private void OnTargetsChanged(object sender, TextChangedEventArgs e) => UpdateTargetCount();

    /// <summary>
    /// 识别粘贴框里的目标：一行一条，去掉空行与重复。
    /// **不在这里判它是不是合法链接** —— 那是开始批量时逐条报错的事；
    /// 现在只把「看起来像目标的行」数出来，用户才知道自己粘了几条。
    /// </summary>
    private void UpdateTargetCount()
    {
        _targets.Clear();
        var text = TargetsBox.Text ?? "";
        foreach (var raw in text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            if (_targets.Contains(line, StringComparer.OrdinalIgnoreCase)) continue;
            _targets.Add(line);
        }
        _targetCount = _targets.Count;
        TargetCountText.Text = "识别到 " + _targetCount + " 个目标";
        StartButton.IsEnabled = _targetCount > 0;
    }

    // ── 我的自建收藏夹 ─────────────────────────────────────

    /// <summary>
    /// 列出「我建的」收藏夹。**需要登录态** —— 收藏夹列表接口按 up_mid 查，
    /// 而未登录拿不到自己的 mid。所以先从内嵌页面把 nav 读出来拿 mid
    /// （页内 fetch 会带上 WebView 会话里的 cookie），再查 created/list-all。
    /// </summary>
    private async void OnListFavClick(object sender, RoutedEventArgs e)
    {
        FavListButton.IsEnabled = false;
        HintText.Text = "正在读取登录态…";
        try
        {
            if (!_webReady || Web.CoreWebView2 is null)
            {
                HintText.Text = "内嵌浏览器还没就绪，请稍后再试";
                return;
            }
            var navBody = await BiliInPage.FetchAsync(Web.CoreWebView2,
                "https://api.bilibili.com/x/web-interface/nav", 15000);
            long mid = 0;
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(navBody);
                if (doc.RootElement.TryGetProperty("data", out var d) &&
                    d.TryGetProperty("mid", out var m) &&
                    m.ValueKind == System.Text.Json.JsonValueKind.Number)
                    mid = m.GetInt64();
            }
            catch { }

            if (mid <= 0)
            {
                HintText.Text = "读不到你的账号（未登录？）。请先在左边页面登录 B 站，再点这里。";
                return;
            }

            var api = new BiliApi(Cfg.Cookie);
            var data = await api.GetDataPublicAsync(
                "/x/v3/fav/folder/created/list-all?up_mid=" + mid);
            var urls = new List<string>();
            if (data.TryGetProperty("list", out var list) &&
                list.ValueKind == System.Text.Json.JsonValueKind.Array)
            {
                foreach (var f in list.EnumerateArray())
                {
                    var id = f.TryGetProperty("id", out var i) ? i.GetInt64() : 0;
                    if (id <= 0) continue;
                    urls.Add("https://www.bilibili.com/medialist/detail/ml" + id);
                }
            }

            if (urls.Count == 0)
            {
                HintText.Text = "你的账号下没有自建收藏夹（或接口没返回）。别人的收藏夹请直接贴链接。";
                return;
            }

            // 追加到粘贴框末尾 —— 用户点这个按钮的意图就是「把这些也加进来」
            var existing = TargetsBox.Text ?? "";
            var sb = new System.Text.StringBuilder(existing.TrimEnd());
            var added = 0;
            foreach (var url in urls)
            {
                if (existing.Contains(url, StringComparison.OrdinalIgnoreCase)) continue;
                if (sb.Length > 0) sb.AppendLine();
                sb.Append(url);
                added++;
            }
            TargetsBox.Text = sb.ToString();
            UpdateTargetCount();
            HintText.Text = "已加入 " + added + " 个自建收藏夹（共识别到 " + _targetCount + " 个目标）";
        }
        catch (Exception ex)
        {
            HintText.Text = "列收藏夹失败：" + ex.Message;
        }
        finally
        {
            FavListButton.IsEnabled = true;
        }
    }

    // ── 开始批量 / 停止 ────────────────────────────────────

    private async void OnStartClick(object sender, RoutedEventArgs e) => await StartBatchAsync();

    private void OnStopClick(object sender, RoutedEventArgs e)
    {
        try { _cts?.Cancel(); } catch { }
        HintText.Text = "已请求停止（正在跑的那一条会走完）";
    }

    /// <summary>
    /// 批量：逐条目标 → 展开成稿件列表 → 逐条取流 → 入队。
    ///
    /// 三条硬约束（都是踩过的）：
    ///  1. **每条之间必须节流**（RequestIntervalMs）：列表接口 + 每个稿件的
    ///     playurl 连着打，一定会被风控；
    ///  2. **「每个列表最多下几条」是硬上限**：一个 20P 合集全取就是几百条队列，
    ///     用户没要求全量时不要替他决定；
    ///  3. **「多 P 稿件取全部 P」默认关**：默认只取第 1P（原项目的说明文字就是这个口径）。
    /// </summary>
    private async Task StartBatchAsync()
    {
        if (_targetCount == 0) return;
        StartButton.IsEnabled = false;
        StopButton.IsEnabled = true;
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;

        var api = new BiliApi(Cfg.Cookie);
        var listApi = new BiliListApi(api);
        var saveDir = Cfg.ResolvedSaveDir;
        var limit = LimitBox.SelectedIndex >= 0 ? Limits[LimitBox.SelectedIndex].Value : 0;
        var takeAllParts = TakeAllPartsSwitch.IsOn;
        var interval = Math.Max(300, Cfg.RequestIntervalMs);

        var okTargets = 0; var failTargets = 0;
        var failures = new List<string>();
        var total = 0;

        try
        {
            for (var ti = 0; ti < _targets.Count; ti++)
            {
                if (ct.IsCancellationRequested) break;
                var raw = _targets[ti];
                HintText.Text = "目标 " + (ti + 1) + "/" + _targets.Count + "：" + Shorten(raw);

                try
                {
                    var works = await ExpandTargetAsync(api, listApi, raw, limit, ct);
                    if (works.Count == 0)
                    {
                        failTargets++;
                        failures.Add(raw + "：没解析出任何稿件");
                        continue;
                    }

                    var perTargetOk = 0;
                    foreach (var work in works)
                    {
                        if (ct.IsCancellationRequested) break;
                        try
                        {
                            var queued = await EnqueueWorkAsync(api, work, saveDir, takeAllParts, ct);
                            total += queued;
                            if (queued > 0) perTargetOk++;
                        }
                        catch (Exception ex)
                        {
                            failures.Add(work.Title + "：" + ex.Message);
                        }
                        if (ct.IsCancellationRequested) break;
                        await Task.Delay(interval, ct);
                    }
                    if (perTargetOk > 0) okTargets++; else failTargets++;
                }
                catch (OperationCanceledException) { break; }
                catch (Exception ex)
                {
                    failTargets++;
                    failures.Add(raw + "：" + ex.Message);
                }

                if (ti < _targets.Count - 1) await Task.Delay(interval, ct);
            }
        }
        catch (OperationCanceledException) { }

        var sb = new System.Text.StringBuilder();
        sb.Append("批量完成：目标 " + okTargets + " 个成功 / " + failTargets + " 个失败，共入队 " + total + " 条分P。");
        if (failures.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("失败明细（前 8 条）：");
            foreach (var f in failures.Take(8)) sb.AppendLine("  · " + f);
        }
        HintText.Text = sb.ToString();

        StartButton.IsEnabled = _targetCount > 0;
        StopButton.IsEnabled = false;
        _cts = null;
    }

    /// <summary>一条目标 → 稿件列表。支持：UP 主空间 / 合集 / 系列 / 收藏夹 / 单个稿件 / 裸 id。</summary>
    private async Task<List<BiliListItem>> ExpandTargetAsync(
        BiliApi api, BiliListApi listApi, string raw, int limit, CancellationToken ct)
    {
        var target = raw;
        if (BiliLink.IsShortLink(raw))
        {
            try
            {
                using var http = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(15) };
                var resp = await http.GetAsync(raw.StartsWith("http") ? raw : "https://" + raw, ct);
                target = resp.RequestMessage?.RequestUri?.ToString() ?? raw;
            }
            catch { }
        }

        // 也认「那串 id」：纯数字默认当 UP 主 mid（原项目说明里写了「或那串 id」）
        var refInfo = BiliLink.Parse(target);
        if (refInfo is null && long.TryParse(target, out var midOnly))
            refInfo = new BiliRef { Mid = midOnly };
        if (refInfo is null) return new List<BiliListItem>();

        var pageSize = limit > 0 ? Math.Min(limit, 30) : 30;

        if (refInfo.SeasonId is long seasonId && refInfo.Mid is long mid)
        {
            var p = await listApi.GetSeasonArchivesAsync(mid, seasonId, 1, pageSize, ct);
            return Trim(p.Items, limit);
        }
        if (refInfo.SeriesId is long seriesId && refInfo.Mid is long mid2)
        {
            var p = await listApi.GetSeriesArchivesAsync(mid2, seriesId, 1, pageSize, ct);
            return Trim(p.Items, limit);
        }
        if (refInfo.FavId is long favId)
        {
            var p = await listApi.GetFavAsync(favId, 0, 1, pageSize, ct);
            return Trim(p.Items, limit);
        }
        if (refInfo.Mid is long mid3)
        {
            var p = await listApi.GetSpaceVideosAsync(mid3, 1, pageSize, ct);
            return Trim(p.Items, limit);
        }
        if (refInfo.IsVideo)
        {
            // 单条稿件：当作只有这一条
            var info = await api.GetVideoInfoAsync(refInfo.Bvid, refInfo.Aid, ct);
            return new List<BiliListItem>
            {
                new BiliListItem
                {
                    Bvid = info.Bvid, Aid = info.Aid, Title = info.Title,
                    Cover = info.Cover, DurationSec = info.DurationSec,
                    PubDateUnix = info.PubDateUnix,
                },
            };
        }
        return new List<BiliListItem>();
    }

    private static List<BiliListItem> Trim(IReadOnlyList<BiliListItem> items, int limit) =>
        limit > 0 ? items.Take(limit).ToList() : items.ToList();

    /// <summary>一个稿件 → 入队它的分 P，返回入队条数。</summary>
    private async Task<int> EnqueueWorkAsync(
        BiliApi api, BiliListItem work, string saveDir, bool takeAllParts, CancellationToken ct)
    {
        var info = await api.GetVideoInfoAsync(work.Bvid, work.Aid > 0 ? work.Aid : null, ct);
        if (info.Pages.Count == 0) return 0;

        // 默认只取第 1P：一个 20P 的合集全取就是几百条队列（原项目的说明文字）
        var parts = takeAllParts ? info.Pages.ToList() : new List<BiliPart> { info.Pages[0] };
        var queued = 0;

        foreach (var part in parts)
        {
            if (ct.IsCancellationRequested) break;
            if (part.Cid is not string cidStr || !long.TryParse(cidStr, out var cid)) continue;

            var play = await api.GetPlayInfoAsync(
                info.Bvid, cid, BiliConfig.QnOf(Cfg.Quality), info.Aid, ct);
            var pair = BiliDownloadPlan.Plan(play, Cfg.Quality, Cfg.Codec);
            if (!pair.Usable) continue;

            var outBase = BuildOutBase(info, part, pair, cid);
            var partDir = BiliEnqueue.ResolveSaveDir(Cfg, saveDir, info, part, pair, play);
            Directory.CreateDirectory(partDir);

            var videoName = pair.IsDash
                ? BiliDownloadPlan.VideoStreamName(outBase)
                : BiliDownloadPlan.MergedName(outBase, Cfg.Container);
            var (a, _) = await DownloadStore.Instance.AddAsync(
                pair.Video!.Url, "B 站", partDir, videoName);
            if (!a) continue;

            if (pair.IsDash && pair.Audio is not null)
            {
                var (a2, _) = await DownloadStore.Instance.AddAsync(
                    pair.Audio.Url, "B 站（音频）", partDir,
                    BiliDownloadPlan.AudioStreamName(outBase));
                if (!a2) continue;
            }

            try
            {
                await BiliAdditionalRunner.ProduceAsync(
                    new BiliApi(Cfg.Cookie), Cfg, partDir, outBase, info, cid,
                    part.Title, part.Page, ct);
            }
            catch { }

            queued++;
            await Task.Delay(Math.Max(200, Cfg.RequestIntervalMs), ct);
        }
        return queued;
    }

    /// <summary>按 B 站模板算 base 名（不含扩展名）—— 两条流与合并产物共用它。</summary>
    private string BuildOutBase(BiliVideoInfo info, BiliPart part, BiliStreamPair pair, long cid)
    {
        var ctx = new BiliTemplate.Context
        {
            WorkTitle = info.Title,
            PartTitle = part.Title,
            Part = info.Pages.Count > 1 ? part.Page : 0,
            PartTotal = info.Pages.Count,
            Bvid = info.Bvid,
            Aid = info.Aid,
            Cid = cid,
            UpName = info.OwnerName,
            UpMid = info.OwnerMid,
            Quality = pair.Video?.QualityLabel ?? "",
            Codec = pair.VideoCodec,
            CustomText = Cfg.CustomText,
            DurationSec = part.DurationSec,
            Ext = ".mp4",
        };
        var rendered = BiliTemplate.Sanitize(
            BiliTemplate.Render(Cfg.EffectiveFileNameTemplate, ctx));
        if (rendered.Length == 0) rendered = info.Bvid + "-P" + part.Page;
        return BiliDownloadPlan.BaseNameFromFileName(rendered);
    }

    private static string Shorten(string s) => s.Length <= 56 ? s : (s.Substring(0, 56) + "…");
}
