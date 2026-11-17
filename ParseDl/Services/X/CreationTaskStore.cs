using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.X;

/// <summary>「创建下载任务」的执行状态（对齐原项目 CreationStatus）。</summary>
public enum CreationStatus { Waiting, Active }

/// <summary>
/// 一个「创建下载任务」—— **一次爬取动作**的载体。
///
/// ### 为什么要有它（移植自原项目 creation_task_store.dart）
/// 主页点「开始下载」时，媒体列表可能只加载了第一页，而用户要的是这个用户的**全部**媒体。
/// 原版的做法不是当场把剩余页拉完再入队（那会让界面卡住、看着像没反应），而是：
///
///   1. 点按钮 → 登记一个 CreationTask 就**立刻返回**（下载管理页立刻出现「任务创建中」）
///   2. 后台串行取队头 → 翻页 → **逐条**投给 aria2
///   3. 每翻一页更新「已发送 / 已跳过」，下载管理页实时看得见
///   4. 跑完（或没有下一页）就摘掉这个任务
///
/// **一次只跑一个**（与原版 `scheduleCreationTasks` 的
/// `if (creationTasks.find(t => t.status === 'active')) return` 一致），
/// 免得多个任务同时翻页把 X 接口打出风控。
/// </summary>
public sealed class CreationTask
{
    public string Id { get; init; } = "";
    /// <summary>要爬的账号（显示用）。</summary>
    public string ScreenName { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public string UserId { get; init; } = "";

    /// <summary>
    /// 用哪一份设置（过滤条件 / 保存目录模板等）。
    /// 空 = 主页那套 <c>ForModule("x")</c>；自动执行传 <c>x_auto</c> 用自己的那份。
    /// </summary>
    public string SettingsKey { get; init; } = "";
    public string Avatar { get; init; } = "";

    public CreationStatus Status { get; set; } = CreationStatus.Waiting;
    /// <summary>已成功投给 aria2 的媒体数。</summary>
    public int CompleteCount { get; set; }
    /// <summary>被过滤 / 同名跳过的媒体数。</summary>
    public int SkipCount { get; set; }
    /// <summary>aria2 明确拒绝的数量（**不能**算进「已发送」）。</summary>
    public int FailCount { get; set; }
    /// <summary>已翻页次数。</summary>
    public int Pages { get; set; }
    public string? Error { get; set; }
    public bool Cancelled { get; set; }

    /// <summary>
    /// 跑完信号（自动执行要等它）。
    ///
    /// 主页点「开始下载」不需要等 —— 它只负责登记完就返回。
    /// 但自动执行是「一个账号跑完再跑下一个」，必须能等到这个账号真正结束，
    /// 否则账号间隔会变成「刚登记完就跳到下一个」，翻页任务全堆在队列里。
    /// </summary>
    internal TaskCompletionSource Done { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public DateTime CreatedAt { get; init; } = DateTime.Now;

    public bool IsActive => Status == CreationStatus.Active;

    /// <summary>跑完之后的一句话结果（界面用来告诉用户到底发生了什么）。</summary>
    public string ResultText
    {
        get
        {
            if (Error is not null) return "失败：" + Error;
            if (CompleteCount == 0 && FailCount == 0 && SkipCount > 0)
                return "全部 " + SkipCount + " 个都已存在，已跳过";
            var s = "已加入 " + CompleteCount + " 个";
            if (SkipCount > 0) s += "，跳过 " + SkipCount + " 个已存在";
            if (FailCount > 0) s += "，" + FailCount + " 个失败";
            return s;
        }
    }

    public string ProgressText => "已发送 " + CompleteCount + "　已跳过 " + SkipCount
        + (FailCount > 0 ? "　失败 " + FailCount : "");

    /// <summary>被 X 限流后已自动重排的次数（上限 <see cref="CreationTaskStore.MaxRateLimitRetries"/>）。</summary>
    public int RateLimitRetries { get; set; }

    /// <summary>
    /// 重排重跑时要**从第一页重新抓**。
    ///
    /// 重排的语义是「这一路都没抓通」，此时 cursor 可能已经推进到中间，
    /// 沿用旧 cursor 会漏掉前面那几页。已经入队的文件会被「跳过（文件已存在）」挡住，
    /// 所以从头抓不会造成重复下载。
    /// </summary>
    public bool RestartFromScratch { get; set; }
}

/// <summary>
/// 「创建下载任务」的后台队列（单例）。
///
/// 状态放在进程级单例里，切页不丢；下载管理页订阅 <see cref="Changed"/> 实时刷新。
/// </summary>
public sealed class CreationTaskStore
{
    public static CreationTaskStore Instance { get; } = new();

    private readonly List<CreationTask> _tasks = new();
    private int _seq;
    private bool _pumping;

    /// <summary>
    /// 单条账号被限流后最多自动重排几次（2026-11-03 加）。
    ///
    /// 取 3 次：X 的限流窗口按 15 分钟计，配合 <see cref="XHomeApi"/> 里
    /// 最高 20 分钟的单次等待，3 次足够跨过大多数窗口；再多就会让整个队列
    /// 长时间停在同一个账号上，后面的账号全被堵住。
    /// </summary>
    public const int MaxRateLimitRetries = 3;

    /// <summary>这个异常是不是「被 X 限流」。按状态码判，不靠消息文本猜。</summary>
    private static bool IsRateLimited(Exception ex)
        => ex is XHomeException { StatusCode: 429 };

    /// <summary>
    /// 可被任务取消标志打断的等待。
    /// 用 200ms 粒度轮询 <see cref="CreationTask.Cancelled"/>，
    /// 用户点「取消」后最多 200 毫秒就退出，不会傻等满一个间隔。
    /// </summary>
    private static async Task SleepCancellableAsync(int ms, CreationTask t)
    {
        for (var left = ms; left > 0 && !t.Cancelled; left -= 200)
            await Task.Delay(Math.Min(200, left));
    }

    /// <summary>
    /// 任务之间的间隔（2026-11-03 加）。
    ///
    /// 原来一个账号跑完立刻跑下一个，132 个账号首尾相连零间隔，
    /// 这是成片 429 的直接推手。间隔取「请求间隔」设置，下限 1 秒。
    /// </summary>
    private static int TaskGapMs()
        => Math.Max(1000, AppSettings.Instance.ForModule("x").RequestIntervalMs);

    /// <summary>队列变化通知（界面上抛到 UI 线程）。</summary>
    public event Action? Changed;

    public IReadOnlyList<CreationTask> Tasks
    {
        get { lock (_tasks) return _tasks.ToList(); }
    }

    public int Count { get { lock (_tasks) return _tasks.Count; } }

    /// <summary>正在翻页的那个（没有则 null）。</summary>
    public CreationTask? ActiveTask
    {
        get { lock (_tasks) return _tasks.FirstOrDefault(t => t.IsActive); }
    }

    private void Notify()
    {
        try { Changed?.Invoke(); } catch { }
    }

    /// <summary>
    /// 登记一个创建任务并**立即返回**（这就是「点一下就开始推送到下载管理」的关键）。
    /// 真正的翻页在后台 <see cref="PumpAsync"/> 里串行执行。
    /// </summary>
    public CreationTask Create(string userId, string screenName, string displayName, string avatar,
        string settingsKey = "")
    {
        var t = new CreationTask
        {
            Id = "ct_" + DateTime.Now.Ticks + "_" + (_seq++),
            UserId = userId,
            ScreenName = screenName,
            DisplayName = string.IsNullOrWhiteSpace(displayName) ? screenName : displayName,
            Avatar = avatar,
            SettingsKey = settingsKey,
        };
        lock (_tasks) _tasks.Add(t);
        Notify();
        _ = PumpAsync();          // 不 await —— 让它在后台跑
        return t;
    }

    /// <summary>取消一个任务。等待中的直接出队；正在跑的会在下一个检查点停下。</summary>
    public void Cancel(string id)
    {
        CreationTask? t;
        lock (_tasks) t = _tasks.FirstOrDefault(x => x.Id == id);
        if (t is null) return;
        t.Cancelled = true;
        if (!t.IsActive)
        {
            lock (_tasks) _tasks.Remove(t);
        }
        Notify();
    }

    /// <summary>
    /// 最近一个跑完的任务（保留一小会儿，让界面能告诉用户「到底发生了什么」）。
    ///
    /// 为什么需要：任务跑完立刻从队列摘掉，用户只看到「任务创建中」一闪而过，
    /// 完全不知道结果 —— 全部跳过时会以为「下载卡住了」（2026-10-29 实测踩到）。
    /// </summary>
    public CreationTask? LastFinished { get; private set; }

    private void Remove(CreationTask t)
    {
        LastFinished = t;
        try { t.Done.TrySetResult(); } catch { }   // 唤醒等着它的自动执行
        lock (_tasks) _tasks.Remove(t);
        Notify();
    }

    /// <summary>串行泵：一次只跑队头那个，跑完摘掉再取下一个。</summary>
    private async Task PumpAsync()
    {
        if (_pumping) return;
        _pumping = true;
        try
        {
            while (true)
            {
                CreationTask? t;
                lock (_tasks) t = _tasks.FirstOrDefault();
                if (t is null) break;

                if (t.Cancelled) { Remove(t); continue; }

                t.Status = CreationStatus.Active;
                Notify();

                try
                {
                    await RunAsync(t);
                }
                catch (Exception ex)
                {
                    t.Error = ex.Message;
                }
                finally
                {
                    Remove(t);
                }

                // **账号之间要喘口气**（2026-11-03 加）。
                // 原来一个跑完立刻跑下一个，132 个账号首尾相连零间隔 ——
                // 这是成片 429 的直接推手。间隔取「请求间隔」设置，下限 1 秒。
                if (!t.Cancelled) await Task.Delay(TaskGapMs());
            }
        }
        finally
        {
            _pumping = false;
        }
    }

    /// <summary>
    /// 单个任务的执行体：**翻页 → 逐条入队 → 每页刷新计数**。
    /// 与主页「开始下载」原来的「先拉完全部页再入队」完全不同 ——
    /// 那是让界面等几十秒，这个是边翻边推，下载管理页实时看得见。
    /// </summary>
    private async Task RunAsync(CreationTask t)
    {
        Aria2Engine.Log("[创建任务] 开始 RunAsync id=" + t.Id + " user=" + t.ScreenName + " userId=" + t.UserId);
        // **按任务指定的设置槽取配置**（空 = 主页那套）。
        var cfg = string.IsNullOrEmpty(t.SettingsKey)
            ? AppSettings.Instance.ForModule("x")
            : AppSettings.Instance.ForAutoTask();
        var api = new XHomeApi(cfg.EffectiveCookie);
        if (!api.HasLogin) { t.Error = "未登录，无法创建下载任务"; return; }

        var settings = cfg;
        var types = (settings.MediaTypeFilter ?? "")
            .Split((char)44, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim().ToLowerInvariant())
            .ToHashSet();
        DateTime? dateFrom = null, dateTo = null;
        if (settings.TimeRangeEnabled)
        {
            if (DateTime.TryParse(settings.DateFrom, out var df)) dateFrom = df.Date;
            if (DateTime.TryParse(settings.DateTo, out var dt)) dateTo = dt.Date.AddDays(1).AddSeconds(-1);
        }

        string? cursor = null;
        var emptyStreak = 0;

        // **真正用上「请求间隔」设置**（2026-11-03 修）。
        //
        // 这个设置项在 X 设置页里存在很久了（说明写着「每次抓取之间的间隔。
        // 太小容易触发 X 的限流」），但 X 这条链路上**没有任何代码读它** ——
        // 132 个账号是零间隔连打的，于是成片 429。
        // 下限 500ms 兜底，防止用户把值调到 0 又立刻被限流。
        var intervalMs = Math.Max(500, settings.RequestIntervalMs);

        // **限流重排要重置计数**（2026-11-03）：不清零的话界面上会保留上一轮的
        // 「已发送/已跳过」，重跑一遍数字会翻倍，用户以为下了两遍。
        if (t.RestartFromScratch)
        {
            t.RestartFromScratch = false;
            t.Pages = 0; t.CompleteCount = 0; t.SkipCount = 0; t.FailCount = 0;
            Notify();
        }

        for (var page = 0; page < 200; page++)
        {
            if (t.Cancelled) return;

            IReadOnlyList<XPost> posts;
            string? next;
            try
            {
                var res = await api.GetMediasAsync(t.UserId, cursor, 100);
                posts = res.Posts;
                next = res.NextCursor;
            }
            catch (Exception ex)
            {
                // **限流不算「这条账号失败」**：排队重来，别让用户看到成片红字。
                if (IsRateLimited(ex) && t.RateLimitRetries < MaxRateLimitRetries)
                {
                    t.RateLimitRetries++;
                    t.Error = $"被 X 限流，已自动排队重试（第 {t.RateLimitRetries}/{MaxRateLimitRetries} 次）";
                    Aria2Engine.Log($"[创建任务] {t.ScreenName} 被限流，重新入队（第 {t.RateLimitRetries} 次）");
                    t.RestartFromScratch = true;
                    lock (_tasks) _tasks.Add(t);   // 排到队尾，等前面积压的任务先跑
                    Notify();
                    return;
                }
                t.Error = XHomeApi.MapError(ex);
                return;
            }

            // 翻页之间也要间隔 —— 一次拉 100 条、连翻十几页同样是密集请求。
            // 这里没有 CancellationToken（这个是后台队列，靠 t.Cancelled 取消），
            // 所以用「分段 sleep + 每 200ms 查一次取消标志」，取消时最多迟 200ms 退出。
            if (page > 0) await SleepCancellableAsync(intervalMs, t);

            t.Pages++;
            t.Status = CreationStatus.Active;
            Notify();     // 每页刷一次，界面能看到进度在动
            Aria2Engine.Log("[创建任务] 第 " + t.Pages + " 页 拿到 " + posts.Count + " 条作品"
                + " 已发送=" + t.CompleteCount + " 已跳过=" + t.SkipCount + " 失败=" + t.FailCount
                + " nextCursor=" + (string.IsNullOrEmpty(next) ? "(空)" : "有"));

            foreach (var post in posts)
            {
                if (t.Cancelled) return;

                for (var mi = 0; mi < post.Media.Count; mi++)
                {
                    if (t.Cancelled) return;
                    var m = post.Media[mi];

                    // 媒体类型 / 日期范围过滤 → 计入跳过
                    if (types.Count > 0 && !types.Contains(m.Type)) { t.SkipCount++; continue; }
                    if (dateFrom is not null && post.CreatedAt is not null && post.CreatedAt.Value < dateFrom) { t.SkipCount++; continue; }
                    if (dateTo is not null && post.CreatedAt is not null && post.CreatedAt.Value > dateTo) { t.SkipCount++; continue; }

                    var name = XNaming.NameFor(post, mi);
                    var dir = XNaming.DirFor(post, mi);
                    if (!string.IsNullOrEmpty(dir))
                    {
                        try
                        {
                            var full = System.IO.Path.Combine(dir, name);
                            if (System.IO.File.Exists(full))
                            {
                                t.SkipCount++;
                                Aria2Engine.Log("[创建任务] 跳过（文件已存在）：" + name);
                                if (t.SkipCount % 3 == 0) Notify();
                                continue;
                            }
                        }
                        catch { }
                    }

                    var (ok, msg) = await DownloadStore.Instance.AddAsync(m.Url, "X 媒体", dir, name, m.PreviewUrl);
                    if (ok) t.CompleteCount++;
                    else
                    {
                        t.FailCount++;
                        Aria2Engine.Log("[创建任务] 入队失败：" + name + " → " + msg);
                    }
                    Aria2Engine.Log("[创建任务] 入队结果 ok=" + ok + " 已发送=" + t.CompleteCount
                        + " 已跳过=" + t.SkipCount + " 失败=" + t.FailCount + " file=" + name);

                    // 每 10 条刷一次，避免过于频繁
                    // **每 3 条刷一次**（2026-10-29 修）。
                    // 原来是每 10 条 —— 一个用户通常只有十几条媒体，
                    // 于是界面上「已发送」长时间停在 0，看着像卡住了。
                    if ((t.CompleteCount + t.FailCount + t.SkipCount) % 3 == 0) Notify();
                }
            }

            emptyStreak = posts.Count == 0 ? emptyStreak + 1 : 0;
            cursor = next;
            if (string.IsNullOrEmpty(cursor) || emptyStreak >= 3) break;
        }

        Notify();
        Aria2Engine.Log("[创建任务] RunAsync 结束 id=" + t.Id + " 已发送=" + t.CompleteCount
            + " 已跳过=" + t.SkipCount + " 失败=" + t.FailCount + " 页数=" + t.Pages
            + " error=" + (t.Error ?? "(无)"));
    }
}
