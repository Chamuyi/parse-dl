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

    private MainWindow? _host;
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
        _host = e.Parameter as MainWindow;
        // **无人值守测试入口**（2026-10-29）：
        // UIA 读不到本页控件（WebView2 覆盖内容区，WinUI 控件没进 UIA 树），
        // 所以自动化测试改走这里 —— 用环境变量把目标喂进来，进页面就自动跑。
        // 只在设置了 PARSE_DL_BATCH_TARGETS 时触发，正常使用完全不受影响。
        TryAutoRunForTest();
        // 诊断日志（2026-10-29）：页面内容区在 UIA 里读不到，先确认是否走到了这里
        try
        {
            Aria2Engine.Log("[BiliBatchPage] OnNavigatedTo，Root 子元素数=" + Root.Children.Count
                            + "，TargetsBox=" + (TargetsBox is null ? "null" : "ok"));
        }
        catch (Exception ex) { Aria2Engine.Log("[BiliBatchPage] 诊断异常：" + ex.Message); }
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

            var api = new BiliApi(Cfg.EffectiveCookie);
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

        var api = new BiliApi(Cfg.EffectiveCookie);
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
                    List<BiliListItem> works;
                    try
                    {
                        works = await ExpandTargetAsync(api, listApi, raw, limit, ct);
                    }
                    catch (Exception ex)
                    {
                        Aria2Engine.Log("[BiliBatch] 展开「" + raw + "」异常：" + ex.GetType().Name + " " + ex.Message);
                        works = new List<BiliListItem>();
                    }

                    Aria2Engine.Log("[BiliBatch] 目标「" + raw + "」展开中…");                    if (works.Count == 0)
                    {
                        failTargets++;
                        failures.Add(raw + "：没解析出任何稿件");
                        Aria2Engine.Log("[BiliBatch] 目标「" + raw + "」解析为空");
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
        // **也认「UP 主名字」**（2026-10-29 新增）：用户常常只知道名字（影视飓风 / 极客湾），
        // 拿不到 mid。这里先用搜索接口把名字换成 mid，再走原来的投稿列表路径。
        // 只在前面几条都没命中时才搜，避免把 BV 号之类也当名字搜一遍。
        if (refInfo is null && !string.IsNullOrWhiteSpace(target) && !target.Contains("://"))
        {
            try
            {
                var hits = await listApi.SearchUserAsync(target, 5, ct);
                Aria2Engine.Log("[BiliBatch] 搜索名字「" + target + "」…");
                var best = hits.FirstOrDefault();
                if (best is not null && best.Mid > 0)
                {
                    refInfo = new BiliRef { Mid = best.Mid };
                    Aria2Engine.Log("[BiliBatch] 名字「" + target + "」→ mid=" + best.Mid);
                    SetHint("按名字「" + target + "」找到 UP 主：" + best.Name
                            + "（mid=" + best.Mid + "，粉丝 " + best.Fans + "）");
                }
            }
            catch { }
        }
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
            // **第 1 级：读空间页渲染后的 DOM**（2026-10-29 新增）。
            // B站 风控拦得住我们的 HttpClient，但拦不住页面自己 ——
            // 浏览器带真指纹/真 cookie/真 Referer，B站 认它。
            // 所以不调接口，只读页面渲染出来的卡片。
            var domList = await TryReadSpaceDomAsync(mid3, ct);
            if (domList is not null && domList.Count > 0)
                return Trim(domList, limit);

            // **优先走页内 fetch**（2026-10-29）：
            // B 站对 arc/search 是按请求轮换风控的（连续三次实测 200/412/200），
            // 裸 HttpClient 很容易撞上 412 / -352。
            // 页内 fetch 由浏览器自己带全套 Cookie 与指纹，跟原项目同一条路，最稳。
            var pageList = await TryFetchSpaceViaPageAsync(mid3, pageSize, ct);
            if (pageList is not null && pageList.Count > 0)
                return Trim(pageList, limit);

            Aria2Engine.Log("[BiliBatch] 页内 fetch 未拿到，回落接口 mid=" + mid3);
            try
            {
                var p = await listApi.GetSpaceVideosAsync(mid3, 1, pageSize, ct);
                if (p.Items.Count > 0) return Trim(p.Items, limit);
            }
            catch (Exception ex)
            {
                Aria2Engine.Log("[BiliBatch] arc/search 被风控，改用视频搜索：" + ex.Message);
            }

            // **第二级兜底：旧版 arc/search**（2026-10-29 实测发现）：
            // 新版 /x/space/wbi/arc/search 被风控，但旧版 /x/space/arc/search
            // 是**不同端点、不同风控策略**，实测返回过 code:0 且带完整 vlist。
            // 它比「按名字搜视频」准确得多，所以排在搜索之前。
            try
            {
                var legacy = await listApi.GetSpaceVideosLegacyAsync(mid3, 1, pageSize, ct);
                if (legacy.Items.Count > 0)
                {
                    Aria2Engine.Log("[BiliBatch] 旧版接口兜底成功 mid=" + mid3
                                    + " 拿到 " + legacy.Items.Count + " 条");
                    return Trim(legacy.Items, limit);
                }
            }
            catch (Exception ex)
            {
                Aria2Engine.Log("[BiliBatch] 旧版接口失败：" + ex.Message);
            }

            // **最后兜底：按 UP 名搜他的视频**（2026-10-29）：
            // arc/search 被 B 站持续风控（实测连续 5 次 -352），
            // 但 search/type?search_type=video 仍可用，且每条都带 mid/bvid。
            // **多翻几页聚合**（2026-10-29 改进）：
            // B站 搜索按相关度排序，30 条里该 UP 主往往只占 1-2 条，
            // 只取第 1 页永远只能拿到 1 条视频。这里连续翻页，
            // 直到拿够 limit 条或翻到上限为止。
            var collected = new List<BiliListItem>();
            var seenBv = new HashSet<string>();
            var maxPages = limit > 0 ? Math.Min(10, Math.Max(2, limit)) : 5;
            for (var pg = 1; pg <= maxPages && collected.Count < Math.Max(limit, 1); pg++)
            {
                var onePage = await listApi.SearchVideosAsync(target, mid3, pg, 30, ct);
                foreach (var it in onePage.Items)
                {
                    if (seenBv.Add(it.Bvid)) collected.Add(it);
                    if (collected.Count >= Math.Max(limit, 1)) break;
                }
                if (onePage.Items.Count == 0) break;   // 没更多了
                if (collected.Count >= Math.Max(limit, 1)) break;
                await Task.Delay(Math.Max(150, Cfg.RequestIntervalMs), ct);
            }
            var bySearch = new BiliListPage { Items = collected, HasMore = false };
            Aria2Engine.Log("[BiliBatch] 视频搜索翻 " + maxPages + " 页，聚合 " + collected.Count + " 条");
            if (bySearch.Items.Count > 0)
            {
                Aria2Engine.Log("[BiliBatch] 视频搜索兜底成功 mid=" + mid3
                                + " 拿到 " + bySearch.Items.Count + " 条");
                return Trim(bySearch.Items, limit);
            }
            return new List<BiliListItem>();
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

            // **跳过已下载的分 P**（2026-10-29 接上台账）：
            // 之前这个开关是死的（设置页说明写着「台账未接时此项无实际效果」）。
            // 判重口径与原项目一致：pending 与 done 都算「已处理过」，
            // 否则用户手快再点一次会重复提交同一个分 P。
            if (Cfg.SkipDownloaded && BiliLedger.Instance.Contains(info.Bvid, cid))
                continue;

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
            // 入队成功 → 台账记一笔 pending（防重复提交；下完后由轮询改 done）
            try { BiliLedger.Instance.MarkPending(info.Bvid, cid, info.Title, null); } catch { }

            if (pair.IsDash && pair.Audio is not null)
            {
                var (a2, _) = await DownloadStore.Instance.AddAsync(
                    pair.Audio.Url, "B 站（音频）", partDir,
                    BiliDownloadPlan.AudioStreamName(outBase));
                if (!a2) continue;

                // **登记待合并对**（2026-10-29 补）：
                // 之前 DASH 的两条流下完了没人管 —— 目录里只剩 .audio.m4s + .video.m4s，
                // 永远不会有 mp4。这里把「视频/音频/输出」三件事记进合并队列，
                // 下载完成后由 <see cref="BiliMergeWatcher"/> 触发 ffmpeg 合并。
                BiliMergeWatcher.Instance.Register(new BiliMergeRequest
                {
                    OutBase = outBase,
                    Dir = partDir,
                    VideoPath = Path.Combine(partDir, BiliDownloadPlan.VideoStreamName(outBase)),
                    AudioPath = Path.Combine(partDir, BiliDownloadPlan.AudioStreamName(outBase)),
                    OutputPath = Path.Combine(partDir, BiliDownloadPlan.MergedName(outBase, Cfg.Container)),
                    Container = Cfg.Container.ToString().ToLowerInvariant(),
                    DeleteSource = true,
                });
            }

            try
            {
                await BiliAdditionalRunner.ProduceAsync(
                    new BiliApi(Cfg.EffectiveCookie), Cfg, partDir, outBase, info, cid,
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

    /// <summary>往状态栏写一句（批量页顶部那条提示）。</summary>
    private void SetHint(string text)
    {
        try
        {
            if (FindName("HintText") is TextBlock tb) tb.Text = text;
        }
        catch { }
    }

    /// <summary>
    /// 无人值守测试入口：环境变量 PARSE_DL_BATCH_TARGETS 里放目标（换行分隔），
    /// PARSE_DL_BATCH_LIMIT 放每个目标取几条。进页面自动填进输入框并开跑。
    ///
    /// 为什么要有它：本页 WebView2 覆盖内容区，UIA 读不到 TargetsBox，
    /// 外部脚本没法输入。走环境变量是唯一稳定的自动化路径。
    /// **不设环境变量时完全不触发**，正常使用不受影响。
    /// </summary>
    private void TryAutoRunForTest()
    {
        try
        {
            var raw = Environment.GetEnvironmentVariable("PARSE_DL_BATCH_TARGETS");
            if (string.IsNullOrWhiteSpace(raw)) return;

            var limitStr = Environment.GetEnvironmentVariable("PARSE_DL_BATCH_LIMIT");
            if (int.TryParse(limitStr, out var lim) && lim > 0)
            {
                // 选对应的「每个目标取几条」
                for (var k = 0; k < Limits.Length; k++)
                {
                    if (Limits[k].Value == lim) { LimitBox.SelectedIndex = k; break; }
                }
            }

            TargetsBox.Text = raw.Replace("\\n", Environment.NewLine);
            // **必须手动重算 _targetCount**：TextChanged 是异步派发的，            // 这里紧接着读 _targetCount 会还是 0，于是 StartBatchAsync 直接 return            // （第一版就踩了这个：日志显示「已跑完」但 1 秒结束、什么都没下）。            UpdateTargetCount();
            Aria2Engine.Log("[BiliBatchPage] 自动测试：已注入 " + TargetsBox.Text.Length + " 字符目标");

            // 等一帧让 TextChanged 先跑完，再开跑
            DispatcherQueue.TryEnqueue(async () =>
            {
                // **等 WebView 真正就绪**（2026-10-29）：
                // 页内 fetch 要浏览器已停在 B 站域名下，否则回 -403 访问权限不足。
                // 首次进页面时 Web 还在加载首页，800ms 根本不够。
                for (var wait = 0; wait < 30; wait++)
                {
                    await Task.Delay(1000);
                    try
                    {
                        if (_webReady && Web.CoreWebView2 is not null)
                        {
                            var cur = Web.CoreWebView2.Source ?? "";
                            if (cur.Contains("bilibili.com") && !cur.EndsWith("bilibili.com/"))
                                break;
                        }
                    }
                    catch { }
                }
                Aria2Engine.Log("[BiliBatchPage] WebView 就绪检查完成");
            // 取登录 cookie，否则 playurl 只能拿 480P
            await BiliConfig.CaptureCookieFromWebViewAsync(Web.CoreWebView2);
                try
                {
                    await StartBatchAsync();
                    Aria2Engine.Log("[BiliBatchPage] 自动测试：批量已跑完");
                }
                catch (Exception ex)
                {
                    Aria2Engine.Log("[BiliBatchPage] 自动测试异常：" + ex.Message);
                }
            });
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[BiliBatchPage] 自动测试入口异常：" + ex.Message);
        }
    }

    /// <summary>
    /// **用页内 fetch 取 UP 主投稿**（对齐原项目 BiliInPage 那条路）。
    ///
    /// 为什么不用裸 HttpClient：B 站对 arc/search 是按请求轮换风控的 ——
    /// 连续三次实测「200 / 412 / 200」，裸请求很容易撞上 412 或 -352。
    /// 页内 fetch 由浏览器自己带全套 Cookie、指纹与 Referer，最接近真人。
    ///
    /// 返回 null 表示「这条路走不通」（WebView 没就绪 / 解析失败），
    /// 调用方据此回落到接口路径。
    /// </summary>
    /// <summary>
    /// **读空间页渲染后的 DOM 拿视频列表**（2026-10-29 新增，绕开接口风控）。
    ///
    /// 为什么这样做：B站 风控拦的是我们的 HttpClient（签名、dm_img、cookie 都试过了，
    /// 全被 -352/412/-403 拦）。但**页面自己**请求 arc/search 是拦不住的 ——
    /// 浏览器带真指纹、真 cookie、真 Referer，B站 认它。
    /// 所以不调接口，只读页面渲染出来的结果。
    /// </summary>
    private async Task<List<BiliListItem>?> TryReadSpaceDomAsync(long mid, CancellationToken ct)
    {
        if (!_webReady || Web.CoreWebView2 is null) return null;
        try
        {
            var spaceUrl = "https://space.bilibili.com/" + mid + "/video";
            var nav = new TaskCompletionSource<bool>();
            void OnNav(object? s, Microsoft.Web.WebView2.Core.CoreWebView2NavigationCompletedEventArgs e)
            {
                try { Web.CoreWebView2.NavigationCompleted -= OnNav; } catch { }
                nav.TrySetResult(true);
            }
            Web.CoreWebView2.NavigationCompleted += OnNav;
            Web.CoreWebView2.Navigate(spaceUrl);
            await Task.WhenAny(nav.Task, Task.Delay(18000, ct));
            await Task.Delay(4000, ct);   // 等 SPA 把卡片渲染出来

            // 读 DOM：抓所有 BV 号 + 标题
            var script = """
                (function(){
                  var out = [];
                  var links = document.querySelectorAll('a[href*="/video/BV"]');
                  for (var i = 0; i < links.length; i++) {
                    var h = links[i].getAttribute("href") || "";
                    var m = h.match(/BV[0-9A-Za-z]{10}/);
                    if (!m) continue;
                    var t = (links[i].getAttribute("title") || links[i].textContent || "").trim();
                    out.push(m[0] + "\t" + t);
                  }
                  return JSON.stringify(out);
                })()
                """;
            var raw = await Web.CoreWebView2.ExecuteScriptAsync(script);
            var unq = System.Text.Json.JsonSerializer.Deserialize<string>(raw) ?? "";
            var arr = System.Text.Json.JsonSerializer.Deserialize<string[]>(unq) ?? Array.Empty<string>();

            var list = new List<BiliListItem>();
            var seen = new HashSet<string>();
            foreach (var row in arr)
            {
                var parts = row.Split((char)9);
                var bvid = parts[0];
                if (string.IsNullOrEmpty(bvid) || !seen.Add(bvid)) continue;
                list.Add(new BiliListItem
                {
                    Bvid = bvid,
                    Aid = 0,
                    Title = parts.Length > 1 ? parts[1] : bvid,
                    Cover = "",
                    DurationSec = 0,
                    PubDateUnix = 0,
                });
            }
            ParseDl.Services.Bili.BiliProbeArc.DomResult = "DOM 抓到 " + list.Count + " 条 BV 号";
            Aria2Engine.Log("[BiliBatch] DOM 读取 mid=" + mid + " 拿到 " + list.Count + " 条");
            return list;
        }
        catch (Exception ex)
        {
            ParseDl.Services.Bili.BiliProbeArc.DomResult = "DOM 读取异常：" + ex.Message;
            Aria2Engine.Log("[BiliBatch] DOM 读取异常：" + ex.Message);
            return null;
        }
    }

    private async Task<List<BiliListItem>?> TryFetchSpaceViaPageAsync(
        long mid, int pageSize, CancellationToken ct)
    {
        if (!_webReady || Web.CoreWebView2 is null) return null;

        try
        {
            // **先导航到该 UP 的空间页**（2026-10-29）：
            // 直接在首页上下文里 fetch api.bilibili.com 会回 -403 访问权限不足 ——
            // 因为 Referer/Origin 是 www.bilibili.com，而该接口要求来自 space 域。
            // 先跳过去，等加载完再在同源上下文里 fetch。
            var spaceUrl = "https://space.bilibili.com/" + mid + "/video";
            try
            {
                var nav = new TaskCompletionSource<bool>();
                void OnNav(object? s, Microsoft.Web.WebView2.Core.CoreWebView2NavigationCompletedEventArgs e)
                {
                    try { Web.CoreWebView2.NavigationCompleted -= OnNav; } catch { }
                    nav.TrySetResult(true);
                }
                Web.CoreWebView2.NavigationCompleted += OnNav;
                Web.CoreWebView2.Navigate(spaceUrl);
                await Task.WhenAny(nav.Task, Task.Delay(15000, ct));
                await Task.Delay(2500, ct);   // 让页面把 cookie / 指纹都建立起来
            }
            catch (Exception ex)
            {
                Aria2Engine.Log("[BiliBatch] 导航到空间页失败：" + ex.Message);
            }

            var url = "https://api.bilibili.com/x/space/wbi/arc/search"
                      + "?mid=" + mid + "&ps=" + pageSize + "&pn=1&order=pubdate";
            var body = await BiliInPage.FetchAsync(Web.CoreWebView2, url, 20000, ct);
            ParseDl.Services.Bili.BiliProbeArc.InPageResult = "长度 " + (body?.Length ?? 0) + " 前80字: " + (body is null ? "(null)" : (body.Length > 80 ? body.Substring(0, 80) : body));
            if (string.IsNullOrWhiteSpace(body) || body.TrimStart().StartsWith("<"))
            {
                Aria2Engine.Log("[BiliBatch] 页内 fetch 返回非 JSON（长度 " + (body?.Length ?? 0) + "）");
                return null;
            }

            using var doc = System.Text.Json.JsonDocument.Parse(body);
            var root = doc.RootElement;
            if (!root.TryGetProperty("code", out var code) || code.GetInt32() != 0)
            {
                var msg = root.TryGetProperty("message", out var m) ? m.GetString() : "";
                Aria2Engine.Log("[BiliBatch] 页内 fetch 业务错误 code="
                                + (root.TryGetProperty("code", out var c2) ? c2.GetInt32() : 0) + " " + msg);
                return null;
            }
            if (!root.TryGetProperty("data", out var data)) return null;

            var list = new List<BiliListItem>();
            if (data.TryGetProperty("list", out var lst) &&
                lst.TryGetProperty("vlist", out var vlist) &&
                vlist.ValueKind == System.Text.Json.JsonValueKind.Array)
            {
                foreach (var v in vlist.EnumerateArray())
                {
                    list.Add(new BiliListItem
                    {
                        Bvid = v.TryGetProperty("bvid", out var b) ? b.GetString() ?? "" : "",
                        Aid = v.TryGetProperty("aid", out var a) ? a.GetInt64() : 0,
                        Title = v.TryGetProperty("title", out var tt) ? tt.GetString() ?? "" : "",
                        Cover = v.TryGetProperty("pic", out var cc)
                                ? (cc.GetString() ?? "").Replace("http://", "https://") : "",
                        DurationSec = ParseDurationStr(v),
                        PubDateUnix = v.TryGetProperty("created", out var cr) ? cr.GetInt64() : 0,
                    });
                }
            }
            Aria2Engine.Log("[BiliBatch] 页内 fetch 成功 mid=" + mid + " 拿到 " + list.Count + " 条");
            return list;
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[BiliBatch] 页内 fetch 异常：" + ex.Message);
            return null;
        }
    }

    /// <summary>列表接口的时长是 "12:34" 字符串，转秒。</summary>
    private static int ParseDurationStr(System.Text.Json.JsonElement e)
    {
        if (!e.TryGetProperty("length", out var len)) return 0;
        var s = len.GetString() ?? "";
        var total = 0;
        foreach (var part in s.Split((char)58))
            if (int.TryParse(part, out var v)) total = total * 60 + v;
        return total;
    }

    /// <summary>
    /// 批量跑完后给一个「去下载管理」直达按钮（2026-10-29 补）。
    ///
    /// 原项目 bili_page / bili_batch_page 都有这个入口：跑完一批之后
    /// 用户最想干的事就是看队列，让他自己去侧边栏点一遍是多余的。
    /// </summary>
    private void ShowGoDownloadsButton()
    {
        try
        {
            if (_host is null) return;
            if (FindName("GoDownloadsButton") is Button) return;   // 已经有了，不重复加

            var btn = new Button
            {
                Name = "GoDownloadsButton",
                Content = "去下载管理",
                MinWidth = 110,
                Margin = new Thickness(0, 8, 0, 0),
            };
            btn.Click += (_, _) => _host?.Navigate("bili-downloads");
            Root.Children.Add(btn);
        }
        catch { }
    }
}
