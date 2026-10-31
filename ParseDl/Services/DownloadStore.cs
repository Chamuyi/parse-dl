using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;

namespace ParseDl.Services;

/// <summary>一条下载记录（界面绑定的对象）。</summary>
public sealed class DownloadItem : System.ComponentModel.INotifyPropertyChanged
{
    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    private void Raise([System.Runtime.CompilerServices.CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(name));
    /// <summary>批量通知（一次轮询改了多个字段时用，避免逐字段触发）。</summary>
    private void RaiseAll(params string[] names)
    {
        foreach (var n in names) Raise(n);
    }
    private string _gid = "";
    public string Gid { get => _gid; set { if (_gid == value) return; _gid = value; Raise(); } }
    public string Url { get; init; } = "";
    /// <summary>预览图 URL（图片用自身；视频用封面帧）。由入队方传入。</summary>
    private string _previewUrl = "";
    public string PreviewUrl { get => _previewUrl; set { if (_previewUrl == value) return; _previewUrl = value; Raise(); Raise(nameof(ThumbUrl)); } }
    private string _fileName = "";
    public string FileName { get => _fileName; set { if (_fileName == value) return; _fileName = value; Raise(); Raise(nameof(DirText)); } }
    private string _dir = "";
    public string Dir { get => _dir; set { if (_dir == value) return; _dir = value; Raise(); Raise(nameof(DirText)); } }
    public string Module { get; init; } = "X 媒体";

    /// <summary>
    /// 抖音作品 ID + 媒体序号（2026-10-31 加）。
    ///
    /// 直链会过期，但「哪个作品的第几条媒体」是稳定的 ——
    /// 恢复队列时靠这两个字段现取一份新鲜地址。
    /// 非抖音任务留空即可。
    /// </summary>
    public string? AwemeId { get; init; }
    public int MediaIndex { get; init; }

    public DateTime CreatedAt { get; init; } = DateTime.Now;

    /// <summary>
    /// **入队序号**（2026-10-30 加）。
    ///
    /// 为什么不能只靠 CreatedAt 排序：`DateTime.Now` 的精度约 15ms，
    /// 而抖音/B站 批量入队是紧凑循环（抖音实测一秒能入几十条），
    /// 于是**很多条拿到完全相同的时间戳** —— 排序就退化成「看插入位置」，
    /// 实际表现为「顺序看着乱、后加入的跑到前面」。X 那边一条条慢慢来，
    /// 所以以前没暴露出来。
    ///
    /// 这里用一个进程级自增号做**第二排序键**，保证「谁先入队谁在前」绝对稳定。
    /// </summary>
    public long Seq { get; init; } = System.Threading.Interlocked.Increment(ref _seqCounter);

    private static long _seqCounter;

    /// <summary>供队列恢复时把计数器推到已用最大值之后（见 RestoreQueueAsync）。</summary>
    internal static ref long SeqCounter => ref _seqCounter;


    private AriaStatus _status = AriaStatus.Waiting;
    public AriaStatus Status
    {
        get => _status;
        set
        {
            if (_status == value) return;
            _status = value;
            RaiseAll(nameof(Status), nameof(StatusText), nameof(PauseLabel), nameof(RetryVisibility), nameof(ProgressText));
        }
    }
    private long _completed;
    public long CompletedBytes { get => _completed; set { if (_completed == value) return; _completed = value; RaiseAll(nameof(CompletedBytes), nameof(Progress), nameof(ProgressText)); } }
    private long _total;
    public long TotalBytes { get => _total; set { if (_total == value) return; _total = value; RaiseAll(nameof(TotalBytes), nameof(Progress), nameof(ProgressText)); } }
    private long _speed;
    public long SpeedBytesPerSec { get => _speed; set { if (_speed == value) return; _speed = value; RaiseAll(nameof(SpeedBytesPerSec), nameof(SpeedText)); } }
    private string _error = "";
    public string Error { get => _error; set { if (_error == value) return; _error = value; Raise(); } }
    /// <summary>自动重试次数（网络抖动时用）。</summary>
    public int RetryCount { get; set; }
    /// <summary>最近一次重试时间，用于退避。</summary>
    public DateTime? LastRetryAt { get; set; }

    public double Progress => TotalBytes <= 0 ? 0 : (double)CompletedBytes / TotalBytes;
    public string ProgressText => TotalBytes <= 0
        ? "—"
        : $"{FormatSize(CompletedBytes)} / {FormatSize(TotalBytes)}（{Progress:P0}）";
    public string SpeedText => SpeedBytesPerSec <= 0 ? "" : FormatSize(SpeedBytesPerSec) + "/s";
    public string StatusText => Status switch
    {
        AriaStatus.Active => "下载中",
        AriaStatus.Waiting => "等待中",
        AriaStatus.Paused => "已暂停",
        AriaStatus.Error => "错误",
        AriaStatus.Complete => "已完成",
        _ => "已移除",
    };

    // ── XAML 绑定用（x:Bind 只认属性，不认方法）──────────────────

    /// <summary>保存位置（目录 + 文件名），列表里给用户看清存到哪了。</summary>
    public string DirText
    {
        get
        {
            var d = string.IsNullOrEmpty(Dir) ? "（默认目录）" : Dir;
            return d;
        }
    }

    /// <summary>进度百分比（0~100），给 ProgressBar 用。</summary>
    public double Percent => TotalBytes <= 0 ? 0 : Math.Min(100.0, CompletedBytes * 100.0 / TotalBytes);

    /// <summary>大小文本：已完成/总量。</summary>
    public string SizeText
    {
        get
        {
            if (TotalBytes > 0) return FormatSize(CompletedBytes) + " / " + FormatSize(TotalBytes);
            if (CompletedBytes > 0) return FormatSize(CompletedBytes);
            return "";
        }
    }


    /// <summary>预览图 URL（图片用自身；视频用缩略图；没有则空）。</summary>
    /// <summary>
    /// 预览图 URL。
    ///
    /// **图片直链本身就是预览图**；视频 aria2 拿不到首帧，只能留空走占位。
    ///
    /// 注意 X/抖音 的图片 URL 常常**不带扩展名**（如 pbs.twimg.com/media/xxx?format=jpg
    /// 或抖音的 ~tplv-... 路径），原来只按 .jpg/.png 后缀判断，这类图片永远不出图 ——
    /// 现在补上 format= 查询参数与常见 CDN 路径特征。
    /// </summary>
    public string ThumbUrl
    {
        get
        {
            // **优先用入队方给的封面**（视频封面帧就在这里，2026-10-29 修）。
            // 原来只在 Url 后缀像图片时才出图 —— X 视频 URL 是 .mp4，永远没封面。
            if (!string.IsNullOrWhiteSpace(_previewUrl)) return _previewUrl;
            if (string.IsNullOrEmpty(Url)) return "";
            var u = Url.ToLowerInvariant();

            // ① 明确是图片扩展名
            if (u.Contains(".jpg") || u.Contains(".jpeg") || u.Contains(".png")
                || u.Contains(".webp") || u.Contains(".gif") || u.Contains(".bmp"))
                return Url;

            // ② 查询参数里声明了图片格式（X 的 ?format=jpg）
            if (u.Contains("format=jpg") || u.Contains("format=jpeg")
                || u.Contains("format=png") || u.Contains("format=webp"))
                return Url;

            // ③ 常见图片 CDN 路径特征（抖音 / B 站封面）
            if (u.Contains("~tplv-") || u.Contains("/bfs/") || u.Contains("hdslb.com/bfs"))
                return Url;

            // ③ **本地兜底：实况视频用同名静态图当预览**（2026-10-30 修「视频没预览图」）。
            //
            // 实况图的配对视频 xxx_0v.mp4 与静态图 xxx_0.jpg / xxx_0MP.jpg 在同一目录，
            // 天然有一张能用的预览图。用户报「视频没预览图」时，队列里那条视频的
            // PreviewUrl 是空的（历史队列没存封面），这里就靠这条规则补上。
            if (!string.IsNullOrEmpty(_dir) && !string.IsNullOrEmpty(_fileName))
            {
                var stem = System.IO.Path.GetFileNameWithoutExtension(_fileName);
                if (stem.EndsWith("v", StringComparison.OrdinalIgnoreCase))
                {
                    var baseName = stem.Substring(0, stem.Length - 1);
                    foreach (var cand in new[] { baseName + "MP.jpg", baseName + ".jpg", baseName + ".jpeg", baseName + ".png" })
                    {
                        try
                        {
                            var full = System.IO.Path.Combine(_dir, cand);
                            if (System.IO.File.Exists(full)) return new Uri(full).AbsoluteUri;
                        }
                        catch { }
                    }
                }
            }

            // 视频：aria2 拿不到首帧，走占位
            return "";
        }
    }

    /// <summary>状态 + 错误 + 进度合成一行（列表第二行）。</summary>
    public string StatusLine
    {
        get
        {
            var s = StatusText;
            if (!string.IsNullOrEmpty(Error)) s += " — " + Error;
            if (TotalBytes > 0) s += "　" + ProgressText;
            else if (CompletedBytes > 0) s += "　" + FormatSize(CompletedBytes);
            return s;
        }
    }

    /// <summary>暂停按钮的文字（暂停中显示「继续」）。</summary>
    public string PauseLabel => Status == AriaStatus.Paused ? "继续" : "暂停";

    /// <summary>「重试」只在错误态出现 —— 其它状态与暂停/继续重复。</summary>
    public Microsoft.UI.Xaml.Visibility RetryVisibility =>
        Status == AriaStatus.Error ? Microsoft.UI.Xaml.Visibility.Visible
                                   : Microsoft.UI.Xaml.Visibility.Collapsed;

    public static string FormatSize(long bytes)
    {
        if (bytes <= 0) return "0 B";
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double v = bytes;
        var i = 0;
        while (v >= 1024 && i < units.Length - 1) { v /= 1024; i++; }
        return $"{v:0.#} {units[i]}";
    }
}

/// <summary>
/// 下载队列 —— 界面与 aria2 之间的唯一中介。
/// 定时轮询 aria2 的 tellAll，把状态刷到 ObservableCollection 上。
/// </summary>
public sealed class DownloadStore
{
    public static DownloadStore Instance { get; } = new();

    private readonly Aria2Engine _engine = new();

    /// <summary>供台账等外部模块直接查 aria2（跨重启补查 gid 状态）。</summary>
    public Aria2Engine Engine => _engine;
    private readonly DispatcherQueue? _ui;
    private Timer? _pollTimer;
    private int _polling;

    public ObservableCollection<DownloadItem> Items { get; } = new();

    public bool EngineReady { get; private set; }
    public string EngineMessage { get; private set; } = "未启动";

    public DownloadStore()
    {
        _ui = DispatcherQueue.GetForCurrentThread();
    }

    /// <summary>启动引擎（幂等）。</summary>
    public async Task<bool> EnsureEngineAsync()
    {
        if (EngineReady && _engine.IsRunning) return true;
        var ok = await _engine.StartAsync();
        EngineReady = ok;
        EngineMessage = ok ? "aria2 正在运行" : "aria2 启动失败（缺少 aria2c.exe？）";
        if (ok) StartPolling();
        return ok;
    }

    /// <summary>加入一条下载。</summary>
    /// <param name="outName">另存文件名（含扩展名）。为空则让 aria2 按 URL 末段命名。</param>
    /// <summary>
    /// 加入一条下载。
    ///
    /// ### 对齐原项目（Flutter 版 aria2_coordinator._submit）
    /// 原版的做法是：**只 `addUri` + 在 store 里登记一条 pending，不做全量拉取**。
    /// 状态靠轮询慢慢补，入队本身就是个轻操作。
    ///
    /// 我之前的写法是每加一条就 `RefreshOnceAsync()`（内部 `TellAllAsync`
    /// **把 aria2 里所有任务的全字段拉一遍**）。入队 68 条 = 68 次全量拉取，
    /// 队列越长每次越慢，累计把 HttpClient 超时撑爆 —— 用户看到
    /// 「入队异常：HttpClient.Timeout 已过期」。
    ///
    /// 实测对照：单纯 100 次 `aria2.addUri` 只要 **304ms**（单次最慢 133ms），
    /// 说明 RPC 极快，瓶颈完全在「每加一条就全量刷新」。
    ///
    /// 现在按原版语义：**只加任务 + 登记，不刷新**。落盘走防抖（见 ScheduleSave）。
    /// </summary>
    public async Task<(bool Ok, string Message)> AddAsync(
        string url, string module, string? dir = null, string? outName = null, string? previewUrl = null,
        string? awemeId = null, int mediaIndex = 0)
    {
        if (string.IsNullOrWhiteSpace(url)) return (false, "地址为空");
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            (uri.Scheme != "http" && uri.Scheme != "https"))
        {
            return (false, "只支持 http / https 直链");
        }

        if (!await EnsureEngineAsync())
            return (false, "下载引擎未就绪：" + EngineMessage);

        var targetDir = dir ?? Aria2Engine.DefaultDir();

        // **提交前先处理「同名文件存在但控制文件缺失」**（2026-10-29 找到的真凶之三）。
        //
        // aria2 在 `--continue=true` 下遇到这种情况会**直接失败**，报：
        //   errorCode=13: File ... exists, but a control file(*.aria2) does not exist.
        //   Download was canceled in order to prevent your file from being truncated to 0.
        // 而且**加了 --allow-overwrite=true 也不管用** —— 实测确认（153 个任务全部失败）。
        //
        // 所以只能自己先删掉那个「没有控制文件的旧文件」，让 aria2 当成全新下载。
        // 这正是原项目「跳过已下载」开关存在的意义：不想重下就别入队；
        // 既然入队了，就是要这个文件。
        if (!string.IsNullOrEmpty(outName))
        {
            try
            {
                var full = System.IO.Path.Combine(targetDir, outName);
                var ctrl = full + ".aria2";
                if (System.IO.File.Exists(full) && !System.IO.File.Exists(ctrl))
                    System.IO.File.Delete(full);
            }
            catch { }
        }

        // **Referer 按 URL 域名自动判定**（2026-10-29 回归修复）。
        //
        // 为什么不在调用点逐个传：13 个调用点，漏一个就是一条静默失败。
        // 而这件事本来就有客观判据 —— 看域名就知道该带谁。
        //
        //   B 站 CDN（*.bilivideo.com / *.hdslb.com 等）→ 必须带 B 站 Referer，
        //     否则 1080P 视频流 403 / errorCode=1
        //   其他（video.twimg.com、抖音 CDN）→ **绝不能带**，
        //     带了反而被 CDN 403（实测 X 队列全红就是上一版全局 referer 干的）
        var referer = RefererFor(url);
        var gid = await _engine.AddUriAsync(url, targetDir, outName, referer);
        if (string.IsNullOrEmpty(gid)) return (false, "aria2 拒绝该任务");

        var item = new DownloadItem
        {
            Gid = gid, Url = url, Module = module, PreviewUrl = previewUrl ?? "",
            AwemeId = awemeId, MediaIndex = mediaIndex,
        };
        if (!string.IsNullOrEmpty(outName)) item.FileName = outName;
        item.Dir = dir ?? Aria2Engine.DefaultDir();
        // **加到末尾，保持推送顺序**（2026-10-29 用户要求「按顺序下载」）。
        // 原来是 Insert(0, item) 插到顶部 —— 先识别到 a、后识别到 b，
        // b 就显示在 a 上面，跟实际下载顺序正好相反。
        OnUi(() => Items.Add(item));
        // **不做全量刷新**（对齐原版）：状态由轮询自然补齐。
        // 落盘用防抖，避免每条都写一次文件。
        ScheduleSave();
        return (true, "已加入队列");
    }

    /// <summary>
    /// 暂停 / 继续一条任务。
    ///
    /// **成功后立即更新本地状态**（2026-10-28）：原来只调 aria2 再全量刷新，
    /// 而全量刷新在任务多时极慢，用户按了暂停界面半天没变化 —— 看着就是「没用」。
    /// 现在先把本地状态改掉（界面立刻响应），再让轮询去校准。
    /// </summary>
    public async Task PauseAsync(DownloadItem item)
    {
        var toPaused = item.Status != AriaStatus.Paused;
        if (toPaused) await _engine.PauseAsync(item.Gid);
        else await _engine.UnpauseAsync(item.Gid);

        // aria2 已经接受了，本地先翻状态；真正的校准交给轮询。
        OnUi(() =>
        {
            item.Status = toPaused ? AriaStatus.Paused : AriaStatus.Active;
            item.SpeedBytesPerSec = 0;
        });
        ScheduleSave();
    }

    public async Task RemoveAsync(DownloadItem item)
    {
        try { await _engine.RemoveAsync(item.Gid); } catch { }
        OnUi(() => Items.Remove(item));
        SaveQueue();
    }

    public async Task ClearCompletedAsync()
    {
        var done = Items.Where(i => i.Status is AriaStatus.Complete or AriaStatus.Error or AriaStatus.Removed).ToList();
        foreach (var d in done) await RemoveAsync(d);
        try { await _engine.PurgeAsync(); } catch { }
    }

    private void StartPolling()
    {
        if (_pollTimer is not null) return;
        _pollTimer = new Timer(async _ => await SafeRefreshAsync(), null, 800, 800);
    }

    /// <summary>
    /// **轮询专用**：只更新「正在下载」的那几条（对齐原项目 `_pollActive`）。
    ///
    /// 2026-10-28 修：原来轮询调的是 <see cref="RefreshOnceAsync"/>，
    /// 它内部 `TellAllAsync` **把全部任务的全字段拉一遍**。任务一多（实测 372 条）
    /// 单次就要十几秒，而轮询间隔只有 0.8 秒 —— RPC 永远排满，
    /// 于是暂停、重试、刷新全部超时，用户看到的就是「按了都没用」。
    ///
    /// 现在轮询只问 active，开销与「并发数」有关、与「总任务数」无关。
    /// 队列里几百条待下载的任务不再影响界面响应。
    /// </summary>
    private async Task SafeRefreshAsync()
    {
        if (Interlocked.Exchange(ref _polling, 1) == 1) return;
        try { await RefreshActiveOnlyAsync(); }
        catch { }
        finally { Interlocked.Exchange(ref _polling, 0); }
    }

    /// <summary>只刷新正在下载的任务（轮询用）。</summary>
    private async Task RefreshActiveOnlyAsync()
    {
        if (!_engine.IsRunning) return;

        // **不能只查 tellActive**（2026-10-29 修，用户报「卡在 33% 点暂停才变完成」）。
        //
        // aria2 的任务一旦下完就从 tellActive 里消失，落到 stopped。
        // 原来只查 active，于是界面永远停在最后一次看到的进度（比如 33%），
        // 直到用户手动点暂停/刷新触发一次全量同步才发现早就完成了。
        //
        // 现在：① 先拿 active 列表批量更新（快）；
        //      ② 再对「界面上仍显示未完成」的那几条逐个 tellStatus 兜底，
        //         它们可能已经完成/失败但还在 active 之外。
        List<AriaTask> tasks;
        try { tasks = await _engine.TellActiveAsync(); }
        catch { return; }

        var seen = new HashSet<string>();
        foreach (var t in tasks) seen.Add(t.Gid);

        // 找出「界面上还没终态、但这次 active 里没有」的任务
        var stragglers = new List<DownloadItem>();
        foreach (var it in Items)
        {
            if (string.IsNullOrEmpty(it.Gid)) continue;
            if (seen.Contains(it.Gid)) continue;
            if (it.Status is AriaStatus.Complete or AriaStatus.Error or AriaStatus.Removed) continue;
            stragglers.Add(it);
        }

        // 逐个补查（数量通常只有几条，不会拖慢轮询）
        foreach (var it in stragglers)
        {
            try
            {
                var one = await _engine.TellStatusAsync(it.Gid);
                if (one is not null) tasks.Add(one);
            }
            catch { }
        }


        // **记录本轮旧状态**（2026-10-30）：终态钩子要判「刚刚变成完成/失败」，
        // 必须在 OnUi 里被覆盖之前先把旧值取出来。OnUi 可能是 TryEnqueue 异步执行，
        // 所以这张表只能在这里算，不能放进 OnUi 内部。
        var prevStatusOf = new Dictionary<string, AriaStatus>();
        foreach (var t in tasks)
        {
            var cur = Items.FirstOrDefault(x => x.Gid == t.Gid);
            if (cur is not null) prevStatusOf[t.Gid] = cur.Status;
        }
        OnUi(() =>
        {
            foreach (var t in tasks)
            {
                var item = Items.FirstOrDefault(i => i.Gid == t.Gid);
                if (item is null) continue;
                item.Status = t.Status;
                item.CompletedBytes = t.CompletedBytes;
                item.TotalBytes = t.TotalBytes;
                item.SpeedBytesPerSec = t.SpeedBytesPerSec;
                item.Error = t.Error;
            }

            // **终态钩子**（2026-10-30）：轮询这条路径原来完全没有，导致落台账 /
            // B站音视频合并 / 抖音实况图合成只在手动打开下载管理页时才跑。
            RunTerminalHooks(tasks, prevStatusOf);
        });
    }

    public async Task RefreshOnceAsync()
    {
        if (!_engine.IsRunning) return;
        List<AriaTask> tasks;
        try { tasks = await _engine.TellAllAsync(); }
        catch { return; }

        // **记录本轮的旧状态**（2026-10-30 修）。
        //
        // 下面第二个循环原来用 it.Status != t.Status 判「这一条刚刚完成」，
        // 但上面第一个循环已经把 item.Status 改成 t.Status 了 —— 判据恒为 false，
        // 于是「终态落台账」「B站音视频合并」「实况图合成」三条完成钩子从来没触发过。
        // 实测证据：目录里 xxx_2.jpg 与 xxx_2v.mp4 并存，日志里一条 [动态照片] 都没有。
        var prevStatusOf = new Dictionary<string, AriaStatus>();
        OnUi(() =>
        {
            foreach (var t in tasks)
            {
                var item = Items.FirstOrDefault(i => i.Gid == t.Gid);
                if (item is null) continue;
                prevStatusOf[t.Gid] = item.Status;
                item.Status = t.Status;
                item.CompletedBytes = t.CompletedBytes;
                item.TotalBytes = t.TotalBytes;
                item.SpeedBytesPerSec = t.SpeedBytesPerSec;
                item.Error = t.Error;
                if (!string.IsNullOrEmpty(t.FileName)) item.FileName = t.FileName;
                if (!string.IsNullOrEmpty(t.Dir)) item.Dir = t.Dir;
            }
            RunTerminalHooks(tasks, prevStatusOf);

            // **不再整列表 Replace**（2026-10-29 修）。
            //
            // 原来这里每轮轮询都把 Items 的每一项替换一遍，靠集合变更强行重绘 ——
            // 用户看到的就是「下载列表一闪一闪」。
            // 现在 DownloadItem 实现了 INotifyPropertyChanged，
            // 属性一变界面自己刷新，不需要这种粗暴手段。
        });
    }
    /// <summary>
    /// **完成 / 失败 / 移除的终态处理**（2026-10-30 从 RefreshOnceAsync 抽出）。
    ///
    /// 为什么必须抽出来：轮询实际走的是 RefreshActiveOnlyAsync，而它原来
    /// **只有状态更新、没有任何终态钩子** —— 于是「落台账 / B站音视频合并 /
    /// 抖音实况图合成」三件事只在用户**手动打开下载管理页**时才有机会跑一次，
    /// 自动下载跑完根本不触发。实测证据：app.log 里 [动态照片] 一条都没有，
    /// 且目录里 xxx_0.jpg 与 xxx_0v.mp4 明明并存、却从来不合并。
    ///
    /// prevStatusOf 必须在调 OnUi **之前**算好 —— OnUi 可能是 TryEnqueue 异步执行，
    /// 在它内部填表再读会是空的。
    /// </summary>
    private void RunTerminalHooks(List<AriaTask> tasks, Dictionary<string, AriaStatus> prevStatusOf)
    {
            foreach (var t in tasks)
            {
                if (t.Status is AriaStatus.Complete or AriaStatus.Error or AriaStatus.Removed)
                {
                    var it = Items.FirstOrDefault(i => i.Gid == t.Gid);
                    // 判据已改为「旧状态 != 新状态」（2026-10-30 修）：原来写 it.Status != t.Status，
                    // 但上一循环已把 it.Status 改成 t.Status，恒为 false，钩子从未触发。
                    if (it is not null && prevStatusOf.TryGetValue(t.Gid, out var was) && was != t.Status)
                    {
                        it.Status = t.Status;
                        DownloadLedger.Instance.Record(it);

                        // **磁盘占用：下完一条累加一次**（2026-10-31）。
                        // 不扫盘的理由：扫一遍 847GB/3万文件要几十秒，
                        // 而且文件被移走后数字会变小 —— 用户要看的是「累计下过多少」。
                        if (t.Status == AriaStatus.Complete)
                        {
                            long realBytes = 0;
                            try
                            {
                                if (!string.IsNullOrEmpty(it.FileName))
                                {
                                    var fp = System.IO.Path.Combine(it.Dir, it.FileName);
                                    if (System.IO.File.Exists(fp)) realBytes = new System.IO.FileInfo(fp).Length;
                                }
                            }
                            catch { }
                            if (realBytes <= 0) realBytes = it.TotalBytes;

                            var mod = string.IsNullOrEmpty(it.Module) ? "other" : it.Module;
                            DiskUsageLedger.Add(mod, realBytes);

                            // X 专用计数器：download_ledger 上限 2000 会把 X 挤没
                            if (it.Module == "X 媒体")
                            {
                                ParseDl.Services.X.XLedger.MarkDone(
                                    it.Gid, it.Url, it.FileName, it.Dir, realBytes);
                            }
                        }

                        // **失败自动重试**（2026-10-29 加）。
                        //
                        // 之前的缺口：aria2 自己的 --max-tries=10 只在单次任务内部重试，
                        // 10 次耗尽后它就把任务标 error 彻底放弃，DownloadStore 只是
                        // 记一笔台账就完事 —— 用户看到的是「下不了，得自己点重试」。
                        //
                        // 而实测走代理时 twimg 的连接会成片超时（code=000），
                        // 隔一会儿再试往往就好了。所以这里补一层**任务级重试**：
                        // 指数退避（10s / 30s / 60s），最多 3 次。
                        if (t.Status == AriaStatus.Error && it.RetryCount < MaxAutoRetries)
                        {
                            var delay = AutoRetryDelays[it.RetryCount];
                            it.RetryCount++;
                            it.LastRetryAt = DateTime.Now;
                            var snapshot = it;
                            _ = Task.Run(async () =>
                            {
                                try { await Task.Delay(delay); } catch { return; }
                                try
                                {
                                    // 重新入队（同一个 URL / 目录 / 文件名）
                                    var gid = await _engine.AddUriAsync(
                                        snapshot.Url, snapshot.Dir, snapshot.FileName,
                                        RefererFor(snapshot.Url));
                                    if (!string.IsNullOrEmpty(gid))
                                    {
                                        OnUi(() =>
                                        {
                                            snapshot.Gid = gid;
                                            snapshot.Status = AriaStatus.Waiting;
                                            snapshot.Error = "";
                                            snapshot.CompletedBytes = 0;
                                        });
                                    }
                                }
                                catch { }
                            });
                        }

                        // 完成即触发 B 站音视频自动合并（用户 2026-10-24 需求第⑤条：
                        // 合并必须自动化，不能让用户再点一次按钮）。
                        // 只有 B 站那一路是 dash 分离流（.video.m4s + .audio.m4s），
                        // X/抖音拿到的本来就是整段文件，NotifyFileReadyAsync 内部
                        // 按落名契约判断，配不上对就立刻返回，不会误合并。
                        if (t.Status == AriaStatus.Complete && !string.IsNullOrEmpty(it.FileName))
                        {
                            var full = System.IO.Path.Combine(it.Dir, it.FileName);
                            _ = ParseDl.Services.Bili.BiliMergePipeline.Instance.NotifyFileReadyAsync(full);

                            // 抖音实况图 → 合成小米/安卓动态照片（单个 jpg，末尾内嵌 mp4）。
                            // 用户 2026-10-27：手机上要能直接看动图，而不是「图 + 视频」两个文件。
                            // 内部按「xxx_2.jpg ↔ xxx_2v.mp4」的命名约定配对，配不上就立刻返回，
                            // 不影响普通图集/普通视频。
                            // 改为**目录级**配对（2026-10-30）：单文件钩子与完成先后强耦合，视频后到就永远配不上。
                            ParseDl.Services.Douyin.MotionPhoto.TryPairOnDirectory(it.Dir);
                            // **台账「下完才写」的实际落地**（2026-10-30）：完成/失败事件一来就推进一次。
                            // 只在 pending 上做 pending → done / 撤销，已 done 的直接跳过，不会重复写盘。
                            _ = ParseDl.Services.Douyin.DouyinEnqueuer.AdvanceLedgerAsync();
                        }
                    }
                }
            }
    }


    /// <summary>最多自动重试几次。</summary>
    /// <summary>
    /// 最多自动重试几次。
    ///
    /// **从 3 提到 6**（2026-10-29 用户反馈「下载失败数量有点多」）。
    ///
    /// 实测根因：走代理时 pbs.twimg.com / video.twimg.com 的连接是**随机抖动**的 ——
    /// 同一批 URL 用 curl 走代理连试 15 次，4 次直接 000；aria2 单跑 8 次失败 3 次。
    /// 而 aria2 自己的 --max-tries=10 是**单次任务内部**重试，遇到
    /// `WinTLS: Failed to encrypt a message! 上下文已过期` 这类握手层错误会直接放弃、
    /// 不再重试（实测确认）。所以必须在任务级多给几次机会。
    ///
    /// 抖动是随机的，多试几次命中率显著提高 —— 实测同进程连下 10 次 0 失败。
    /// </summary>
    private const int MaxAutoRetries = 6;

    /// <summary>
    /// 指数退避间隔（秒）。**首次从 10s 缩到 5s**（2026-10-29）。
    ///
    /// 原来 10/30/60 —— 用户看到的是「失败了，等半天没动静」。
    /// 抖动恢复通常只要几秒，首跳太保守只会拖长整体时间。
    /// 后面的间隔仍逐次拉长，避免把代理压垮。
    /// </summary>
    private static readonly TimeSpan[] AutoRetryDelays =
    {
        TimeSpan.FromSeconds(5),
        TimeSpan.FromSeconds(10),
        TimeSpan.FromSeconds(20),
        TimeSpan.FromSeconds(40),
        TimeSpan.FromSeconds(60),
        TimeSpan.FromSeconds(90),
    };

    private void OnUi(Action action)
    {
        if (_ui is null || _ui.HasThreadAccess) { action(); return; }
        _ui.TryEnqueue(() => action());
    }

    // ── 队列持久化（2026-10-28 加）────────────────────────────────
    //
    // **为什么必须做**：用户反馈「任务队列重启不能清空啊」。
    // 之前队列只存在内存里，GID 是 aria2 运行时生成的，进程一重启全丢 ——
    // 68 个任务下到一半重启，剩下的全部消失，只能重新加载重新下。
    //
    // **做法**：把「能重建任务所需的最小信息」落盘（URL / 文件名 / 目录 / 模块），
    // 启动时重新提交给 aria2。**不能存 GID** —— 那是运行时句柄，重启必失效。
    // aria2 启动参数带 --continue=true，所以已下完的部分会续传，不会从头再来。
    //
    // 只存「未完成」的任务：已完成的没必要占队列（历史另有 download_ledger 台账）。

    private static string QueueFile =>
        System.IO.Path.Combine(ParseDl.Services.AppPaths.DataDir, "download_queue.json");

    /// <summary>
    /// **防抖落盘**（对齐原项目 download_store.dart 的 _saveTimer，那里也是 2 秒）。
    ///
    /// 批量入队时如果每条都写一次文件，68 条就是 68 次全量序列化 + 写盘；
    /// 防抖后无论加多少条，**只写一次**。定时器到期或进程退出前会真正落盘。
    /// </summary>
    private void ScheduleSave()
    {
        _saveTimer?.Dispose();
        _saveTimer = new System.Threading.Timer(_ => SaveQueue(), null,
            TimeSpan.FromSeconds(2), System.Threading.Timeout.InfiniteTimeSpan);
    }

    private System.Threading.Timer? _saveTimer;

    /// <summary>把当前未完成任务写盘。失败不抛（落盘失败不该影响下载）。</summary>
    private void SaveQueue()
    {
        try
        {
            var snapshot = Items
                .Where(i => i.Status is not (AriaStatus.Complete or AriaStatus.Removed))
                .Select(i => new QueueEntry
                {
                    Url = i.Url,
                    FileName = i.FileName,
                    Dir = i.Dir,
                    Module = i.Module,
                    CreatedAt = i.CreatedAt,
                    CompletedBytes = i.CompletedBytes,
                    TotalBytes = i.TotalBytes,
                    PreviewUrl = i.PreviewUrl,
                    Seq = i.Seq,
                    AwemeId = i.AwemeId,
                    MediaIndex = i.MediaIndex,
                })
                .ToList();
            var json = JsonSerializer.Serialize(snapshot, new JsonSerializerOptions { WriteIndented = true });
            System.IO.File.WriteAllText(QueueFile, json);
        }
        catch { }
    }

    /// <summary>
    /// 启动时恢复队列：把上次没跑完的任务重新提交给 aria2。
    /// 返回恢复条数（0 表示没有待恢复任务）。
    /// </summary>
    public async Task<int> RestoreQueueAsync()
    {
        List<QueueEntry>? saved = null;
        try
        {
            if (!System.IO.File.Exists(QueueFile)) return 0;
            var json = System.IO.File.ReadAllText(QueueFile);
            saved = JsonSerializer.Deserialize<List<QueueEntry>>(json);
        }
        catch { return 0; }
        if (saved is null || saved.Count == 0) return 0;

        if (!await EnsureEngineAsync()) return 0;

        var restored = 0;
        var expired = 0;
        var refreshed = 0;
        foreach (var e in saved)
        {
            if (string.IsNullOrWhiteSpace(e.Url)) continue;
            try
            {
                // **恢复时也要做同样的前置清理**（2026-10-29）：
                // 这条路径直接调 _engine.AddUriAsync，绕过了 AddAsync 里的清理逻辑，
                // 于是重启后恢复队列时，那些「文件已存在但无控制文件」的任务
                // 仍然全部 errorCode=13 失败 —— 界面看着就是「下载卡住」。
                var fileName = string.IsNullOrWhiteSpace(e.FileName) ? null : e.FileName;

                // 文件已存在且非空 → 认为已经下完，不再重复提交
                // （否则 aria2 会报 errorCode=13「文件存在但无控制文件」直接失败）
                if (!string.IsNullOrEmpty(fileName) && !string.IsNullOrEmpty(e.Dir))
                {
                    try
                    {
                        var full = System.IO.Path.Combine(e.Dir, fileName);
                        if (System.IO.File.Exists(full) && new System.IO.FileInfo(full).Length > 0)
                            continue;
                    }
                    catch { }
                }

                // **链接过期就现取一份新地址**（2026-10-31 重做）。
                //
                // 抖音 CDN 直链带时效签名（URL 路径里那段 8 位 hex 就是过期时间），
                // 到点一律 403。实测用户队列 5029 条签名 05:34 过期、
                // 11:58 恢复时全部报废，重试一万次也没用。
                //
                // 现在的做法：队列里存了作品 ID（AwemeId），过期就用它回页面
                // 现取一份新鲜地址；取不到才跳过并计数。
                var url = e.Url;
                if (SignedUrl.IsExpired(url))
                {
                    var fresh = await ParseDl.Services.Douyin.DouyinAddressResolver
                        .ResolveAsync(e.AwemeId ?? "", e.MediaIndex);
                    if (fresh.Ok)
                    {
                        url = fresh.Url;
                        refreshed++;
                    }
                    else
                    {
                        expired++;
                        continue;
                    }
                }

                var gid = await _engine.AddUriAsync(url, e.Dir, fileName);
                if (string.IsNullOrEmpty(gid)) continue;

                var item = new DownloadItem
                {
                    Gid = gid,
                    Url = e.Url,
                    Module = e.Module,
                    Dir = e.Dir ?? "",
                    FileName = e.FileName ?? "",
                    CreatedAt = e.CreatedAt,
                    PreviewUrl = e.PreviewUrl ?? "",
                    Seq = e.Seq,
                    AwemeId = e.AwemeId,
                    MediaIndex = e.MediaIndex,
                };
                OnUi(() => Items.Add(item));
                restored++;
            }
            catch { }
        }

        await RefreshOnceAsync();

        // **恢复后把序号计数器推到最大值之后**（2026-10-30）：
        // 否则重启后新入队的 Seq 从 1 重新开始，比恢复回来的旧任务还小，
        // 排序变成「新任务跑到最前面」—— 与「先入队先在前」正好相反。
        try
        {
            var maxSeq = Items.Count == 0 ? 0 : Items.Max(x => x.Seq);
            if (maxSeq > 0) System.Threading.Interlocked.Exchange(ref DownloadItem.SeqCounter, maxSeq);
        }
        catch { }
        SaveQueue();   // 重写一遍，把提交失败的那些剔掉

        // 过期被跳过的那些条**已经从队列里剔掉了**（SaveQueue 只存未完成任务，
        // 而它们压根没进 Items），所以这里只要把数字报出去，让用户知道
        // 「不是重试没用，是链接早过期了，得重新抓一遍」。
        if (refreshed > 0)
        {
            Aria2Engine.Log($"[队列恢复] {refreshed} 条链接已过期，已按作品 ID 现取新地址");
        }
        if (expired > 0)
        {
            LastRestoreExpired = expired;
            Aria2Engine.Log($"[队列恢复] 跳过 {expired} 条已过期链接（抖音 CDN 直链带时效签名，需重新抓取）");
        }
        return restored;
    }

    /// <summary>上次恢复队列时因签名过期被跳过的条数（给界面提示用）。</summary>
    public int LastRestoreExpired { get; private set; }

    /// <summary>落盘用的最小字段集（**不含 GID** —— 运行时句柄重启即失效）。</summary>
    private sealed class QueueEntry
    {
        public string Url { get; set; } = "";
        public string? FileName { get; set; }
        public string? Dir { get; set; }
        public string Module { get; set; } = "";
        public DateTime CreatedAt { get; set; }
        public long CompletedBytes { get; set; }
        public long TotalBytes { get; set; }
        /// <summary>预览图 URL（2026-10-29 修「重启后视频没封面」：之前没存，恢复时封面全丢）。</summary>
        public string? PreviewUrl { get; set; }
        public long Seq { get; set; }

        /// <summary>
        /// **作品 ID + 媒体序号（2026-10-31 加）**。
        ///
        /// 抖音的下载直链带时效签名，几小时就 403（实测：签名 05:34 过期，
        /// 11:46 恢复队列提交时全部失效，2000 条一次性报废）。
        /// 光存 URL 的队列因此**天然不可恢复** —— 中断一次就全军覆没。
        ///
        /// 现在把「重新取地址」所需的原料一起存下来：作品 ID + 该作品内第几条媒体。
        /// 恢复队列时若 URL 已过期，就用这两个字段回页面现取一份新地址。
        /// </summary>
        public string? AwemeId { get; set; }
        public int MediaIndex { get; set; }
    }

    /// <summary>立即落盘（不等防抖）。批量入队收尾、或即将退出时调用。</summary>
    public void Flush()
    {
        _saveTimer?.Dispose();
        _saveTimer = null;
        SaveQueue();
    }
    /// <summary>
    /// **批量暂停 / 继续**（2026-10-28）：一次 RPC 搞定，不再逐条。
    /// aria2 的 pause/unpause 支持多 GID 参数；逐条调在几百任务时要排队几分钟。
    /// </summary>
    public Task<int> PauseManyAsync(IReadOnlyList<DownloadItem> items, bool toPaused)
    {
        var gids = items.Select(i => i.Gid).Where(g => !string.IsNullOrEmpty(g)).ToList();
        if (gids.Count == 0) return Task.FromResult(0);

        // **先翻本地状态，界面立刻响应**（2026-10-28）。
        //
        // 实测：aria2 在承载大量真实下载时，它的 RPC 事件循环会饱和 ——
        // 单次调用可能几十秒才返回（实测 getVersion 都要 20 秒超时）。
        // 如果这里 `await` 整轮，用户点「全部暂停」就要僵住几分钟，
        // 看起来跟「没反应」一模一样。所以：**本地先改，RPC 后台慢慢发**。
        OnUi(() =>
        {
            foreach (var it in items)
            {
                it.Status = toPaused ? AriaStatus.Paused : AriaStatus.Active;
                it.SpeedBytesPerSec = 0;
            }
        });
        ScheduleSave();

        // RPC 放到后台跑：不阻塞调用方，失败也不影响界面（状态由轮询校准）。
        _ = Task.Run(async () =>
        {
            foreach (var g in gids)
            {
                try
                {
                    if (toPaused) await _engine.PauseAsync(g);
                    else await _engine.UnpauseAsync(g);
                }
                catch { }
            }
        });

        return Task.FromResult(gids.Count);
    }

    /// <summary>
    /// **批量移除**（2026-10-28）：本地列表先清空、界面立刻归零，
    /// 再在后台逐条通知 aria2。
    ///
    /// 为什么不能逐条 await：aria2 的 RPC 在任务多时要排队，
    /// 188 条逐个等会花几十秒，用户看到的是「点了清空只少了 1 个」。
    /// </summary>
    public Task<int> RemoveManyAsync(IReadOnlyList<DownloadItem> items)
    {
        if (items.Count == 0) return Task.FromResult(0);

        var gids = items.Select(i => i.Gid).Where(g => !string.IsNullOrEmpty(g)).ToList();

        // 本地立刻移除：界面马上归零
        OnUi(() =>
        {
            foreach (var it in items) Items.Remove(it);
        });
        ScheduleSave();

        // 后台通知 aria2 删任务，不阻塞界面
        _ = Task.Run(async () =>
        {
            foreach (var g in gids)
            {
                try { await _engine.RemoveAsync(g); } catch { }
            }
        });

        return Task.FromResult(items.Count);
    }

    /// <summary>
    /// 按 URL 域名决定要不要带 Referer，以及带谁。
    ///
    /// 判据是 CDN 的实际行为，不是猜：
    /// * B 站 1080P 视频流的 CDN **校验 Referer**，不带就 403（errorCode=1）
    /// * X 的 video.twimg.com **带 B 站 Referer 反而 403**（实测 code=403 size=0）
    /// * 抖音 CDN 不需要 Referer
    ///
    /// 所以只有 B 站系域名带，其余一律不带。
    /// </summary>
    public static string? RefererFor(string url)
    {
        if (string.IsNullOrEmpty(url)) return null;
        try
        {
            var host = new Uri(url).Host.ToLowerInvariant();
            // B 站系：视频/音频流走 *.bilivideo.com，封面/弹幕走 *.hdslb.com
            if (host.EndsWith(".bilivideo.com") || host.EndsWith(".bilivideo.cn")
                || host.EndsWith(".hdslb.com") || host.EndsWith(".bilibili.com"))
                return "https://www.bilibili.com/";

            // **抖音 CDN 必须带抖音 Referer**（2026-10-31 实测纠正）。
            //
            // 之前的注释写着「抖音 CDN 绝不能带 Referer」，那个结论是**错的**。
            // 实测（同一条真实直链）：
            //   直连不带 Referer        → 403 size=352
            //   带 Referer: douyin.com    → 200 size=195956 ✅
            // 原因：抖音 CDN 对 video/tos 路径做 Referer 白名单校验，不带就当盗链。
            // 当时归因到「全局 referer 导致 X 全部 403」，于是把抖音一起误伤了。
            if (host.EndsWith(".douyinvod.com") || host.EndsWith(".douyinpic.com")
                || host.EndsWith(".douyinstatic.com") || host.EndsWith(".douyin.com")
                || host.EndsWith(".iesdouyin.com"))
                return "https://www.douyin.com/";

            return null;
        }
        catch { return null; }
    }
}
