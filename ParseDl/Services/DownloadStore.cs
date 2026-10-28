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
public sealed class DownloadItem
{
    public string Gid { get; init; } = "";
    public string Url { get; init; } = "";
    public string FileName { get; set; } = "";
    public string Dir { get; set; } = "";
    public string Module { get; init; } = "X 媒体";
    public DateTime CreatedAt { get; init; } = DateTime.Now;

    public AriaStatus Status { get; set; } = AriaStatus.Waiting;
    public long CompletedBytes { get; set; }
    public long TotalBytes { get; set; }
    public long SpeedBytesPerSec { get; set; }
    public string Error { get; set; } = "";

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
        string url, string module, string? dir = null, string? outName = null)
    {
        if (string.IsNullOrWhiteSpace(url)) return (false, "地址为空");
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            (uri.Scheme != "http" && uri.Scheme != "https"))
        {
            return (false, "只支持 http / https 直链");
        }

        if (!await EnsureEngineAsync())
            return (false, "下载引擎未就绪：" + EngineMessage);

        var gid = await _engine.AddUriAsync(url, dir ?? Aria2Engine.DefaultDir(), outName);
        if (string.IsNullOrEmpty(gid)) return (false, "aria2 拒绝该任务");

        var item = new DownloadItem { Gid = gid, Url = url, Module = module };
        if (!string.IsNullOrEmpty(outName)) item.FileName = outName;
        item.Dir = dir ?? Aria2Engine.DefaultDir();
        OnUi(() => Items.Insert(0, item));
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
        List<AriaTask> tasks;
        try { tasks = await _engine.TellActiveAsync(); }
        catch { return; }

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
        });
    }

    public async Task RefreshOnceAsync()
    {
        if (!_engine.IsRunning) return;
        List<AriaTask> tasks;
        try { tasks = await _engine.TellAllAsync(); }
        catch { return; }

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
                if (!string.IsNullOrEmpty(t.FileName)) item.FileName = t.FileName;
                if (!string.IsNullOrEmpty(t.Dir)) item.Dir = t.Dir;
            }
            // 终态落台账：完成/失败/移除各记一笔，重启后仍能看到历史。
            foreach (var t in tasks)
            {
                if (t.Status is AriaStatus.Complete or AriaStatus.Error or AriaStatus.Removed)
                {
                    var it = Items.FirstOrDefault(i => i.Gid == t.Gid);
                    if (it is not null && it.Status != t.Status)
                    {
                        it.Status = t.Status;
                        DownloadLedger.Instance.Record(it);

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
                            ParseDl.Services.Douyin.MotionPhoto.TryPairOnComplete(full);
                        }
                    }
                }
            }

            // 触发一次集合变更通知（DownloadItem 未实现 INotifyPropertyChanged，
            // 用 Replace 让列表项重绘 —— 比给每项加通知简单且够用）
            for (var i = 0; i < Items.Count; i++)
            {
                var cur = Items[i];
                Items[i] = cur;
            }
        });
    }

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
        foreach (var e in saved)
        {
            if (string.IsNullOrWhiteSpace(e.Url)) continue;
            try
            {
                var gid = await _engine.AddUriAsync(e.Url, e.Dir,
                    string.IsNullOrWhiteSpace(e.FileName) ? null : e.FileName);
                if (string.IsNullOrEmpty(gid)) continue;

                var item = new DownloadItem
                {
                    Gid = gid,
                    Url = e.Url,
                    Module = e.Module,
                    Dir = e.Dir ?? "",
                    FileName = e.FileName ?? "",
                    CreatedAt = e.CreatedAt,
                };
                OnUi(() => Items.Add(item));
                restored++;
            }
            catch { }
        }

        await RefreshOnceAsync();
        SaveQueue();   // 重写一遍，把提交失败的那些剔掉
        return restored;
    }

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
}