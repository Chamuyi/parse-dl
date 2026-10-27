using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace ParseDl.Services.Douyin;

/// <summary>一次入队的结果统计。</summary>
public sealed class DouyinEnqueueResult
{
    public int Queued { get; set; }
    public int Failed { get; set; }
    public int NotReady { get; set; }
    /// <summary>作品 id → （任务 id、标题、作者）—— 只有确认进入队列的才在这里。</summary>
    public Dictionary<string, (List<string> TaskIds, string? Title, string? Author)> QueuedByAweme { get; } = new();
    public string Message { get; set; } = "";
}

/// <summary>
/// 抖音入队器 —— 把组装好的媒体交给 aria2，并按作品粒度写台账。
///
/// 为什么台账只记「确认进入队列」的作品、而且记的是「在下」（pending）：
/// 早期实现是「整批里成功数 > 0 → 把整批 awemeIds 写进台账」，于是被 aria2
/// 拒绝的作品也被标成「已下载」，用户开着「跳过已下载」时它们会被永久静默跳过。
/// 现在只有该作品的任务全部成功（<see cref="DouyinLedger.Advance"/>）才算下过。
/// </summary>
public static class DouyinEnqueuer
{
    /// <summary>模块名（DownloadsPage 的筛选值，也是台账里的模块标签）。</summary>
    public const string Module = "抖音";

    /// <param name="auto">
    /// true = 自动下载模式：用自动下载专属的模板与「按模板建文件夹」开关
    /// （2026-10-27 用户要求，与设置页那套分开互不影响）。
    /// </param>
    public static async Task<DouyinEnqueueResult> EnqueueAsync(
        IEnumerable<DouyinItem> items,
        DouyinConfig cfg,
        bool writeLedger = true,
        bool auto = false)
    {
        var result = new DouyinEnqueueResult();
        var list = items.ToList();
        if (list.Count == 0) return result;

        if (!await DownloadStore.Instance.EnsureEngineAsync())
        {
            result.NotReady = list.Count;
            result.Message = "下载引擎还没起来（aria2 未就绪）";
            return result;
        }

        foreach (var m in list)
        {
            var (dir, fileName) = DouyinTemplate.BuildTarget(m, cfg, auto);
            try
            {
                var (ok, _) = await DownloadStore.Instance.AddAsync(m.Url, Module, dir, fileName);
                if (!ok)
                {
                    result.Failed++;
                    continue;
                }

                result.Queued++;
                var postId = string.IsNullOrEmpty(m.PostId) ? m.Id : m.PostId;
                var gid = DownloadStore.Instance.Items.FirstOrDefault(i => i.Url == m.Url)?.Gid ?? "";
                if (gid.Length > 0 && !string.IsNullOrEmpty(postId))
                {
                    if (!result.QueuedByAweme.TryGetValue(postId, out var entry))
                        entry = (new List<string>(), m.Text, m.UserName);
                    if (!entry.TaskIds.Contains(gid)) entry.TaskIds.Add(gid);
                    result.QueuedByAweme[postId] = entry;
                }
            }
            catch (Exception ex)
            {
                Aria2Engine.Log("[抖音入队] 失败：" + ex.Message);
                result.Failed++;
            }
        }

        if (writeLedger && result.QueuedByAweme.Count > 0)
        {
            DouyinStore.Instance.Ledger.MarkQueued(result.QueuedByAweme);
            DouyinStore.Instance.NotifyLedgerView();
        }

        var parts = new List<string> { "已提交 " + result.Queued + " 个" };
        if (result.NotReady > 0) parts.Add("未就绪 " + result.NotReady + " 个");
        if (result.Failed > 0) parts.Add("失败 " + result.Failed + " 个");
        result.Message = string.Join("，", parts);
        return result;
    }

    /// <summary>
    /// 按 aria2 的当前状态推进台账（pending → done / 撤销）。
    /// 事件可能丢（进程在完成前退出、任务被从下载管理里删掉），所以这里不依赖
    /// 事件顺序：任何时候拿任务表对一遍就能纠正，启动与刷新时都调一次。
    /// </summary>
    public static bool AdvanceLedger()
    {
        var byGid = new Dictionary<string, AriaStatus>();
        foreach (var it in DownloadStore.Instance.Items)
            if (!string.IsNullOrEmpty(it.Gid)) byGid[it.Gid] = it.Status;

        return DouyinStore.Instance.Ledger.Advance(gid =>
            byGid.TryGetValue(gid, out var st)
                ? st switch
                {
                    AriaStatus.Complete => DouyinTaskState.Complete,
                    AriaStatus.Error => DouyinTaskState.Failed,
                    AriaStatus.Active or AriaStatus.Waiting or AriaStatus.Paused => DouyinTaskState.Running,
                    _ => DouyinTaskState.Unknown,
                }
                : DouyinTaskState.Unknown);
    }
}
