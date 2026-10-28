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
    public DateTime CreatedAt { get; init; } = DateTime.Now;

    public bool IsActive => Status == CreationStatus.Active;

    public string ProgressText => "已发送 " + CompleteCount + "　已跳过 " + SkipCount
        + (FailCount > 0 ? "　失败 " + FailCount : "");
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
    public CreationTask Create(string userId, string screenName, string displayName, string avatar)
    {
        var t = new CreationTask
        {
            Id = "ct_" + DateTime.Now.Ticks + "_" + (_seq++),
            UserId = userId,
            ScreenName = screenName,
            DisplayName = string.IsNullOrWhiteSpace(displayName) ? screenName : displayName,
            Avatar = avatar,
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

    private void Remove(CreationTask t)
    {
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
        var cfg = AppSettings.Instance.ForModule("x");
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
                t.Error = XHomeApi.MapError(ex);
                return;
            }

            t.Pages++;
            t.Status = CreationStatus.Active;
            Notify();     // 每页刷一次，界面能看到进度在动

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
                            if (System.IO.File.Exists(full)) { t.SkipCount++; continue; }
                        }
                        catch { }
                    }

                    var (ok, _) = await DownloadStore.Instance.AddAsync(m.Url, "X 媒体", dir, name);
                    if (ok) t.CompleteCount++;
                    else t.FailCount++;

                    // 每 10 条刷一次，避免过于频繁
                    if ((t.CompleteCount + t.FailCount) % 10 == 0) Notify();
                }
            }

            emptyStreak = posts.Count == 0 ? emptyStreak + 1 : 0;
            cursor = next;
            if (string.IsNullOrEmpty(cursor) || emptyStreak >= 3) break;
        }

        Notify();
    }
}
