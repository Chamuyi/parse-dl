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
    public Dictionary<string, (List<string> TaskIds, string? Title, string? Author, string? Dir)> QueuedByAweme { get; } = new();
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
        bool auto = false,
        string rootFolder = "")
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
            var (dir, fileName) = DouyinTemplate.BuildTarget(m, cfg, auto, rootFolder);
            try
            {
                // **必须把封面带进队列**（2026-10-30 修「视频没预览图」）：
                // AddAsync 的第 5 个参数是 previewUrl，原来没传 —— 视频条目 Url 是 .mp4，
                // ThumbUrl 拿不到图就返回空，列表里永远是灰块。m.PreviewUrl 是抖音给的封面帧。
                // **带上作品 ID + 媒体序号**（2026-10-31）：直链会过期，
                // 队列恢复时要靠这两个字段回页面现取新地址。
                // PostId 是所属作品；为空时退回 Id（单条媒体页的情况）。
                var awemeId = string.IsNullOrEmpty(m.PostId) ? m.Id : m.PostId;
                // **把作者名也带进队列**（2026-11-01 用户要求）：链接取不回来时
                // 要能告诉用户「作者是谁 + 作品 ID + 链接」，让他手动去找。
                var (ok, _) = await DownloadStore.Instance.AddAsync(
                    m.Url, Module, dir, fileName, m.PreviewUrl,
                    awemeId: awemeId, mediaIndex: m.MediaIndex, author: m.UserName);
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
                        entry = (new List<string>(), m.Text, m.UserName, dir);
                    if (!entry.TaskIds.Contains(gid)) entry.TaskIds.Add(gid);
                    result.QueuedByAweme[postId] = (entry.TaskIds, entry.Title, entry.Author, entry.Dir ?? dir);
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
    /// 按 aria2 的实际状态推进台账（pending → done / 撤销）。
    ///
    /// **必须直接问 aria2，不能只看 DownloadStore.Instance.Items**（2026-10-30 修）：
    /// Items 是内存里的下载列表，重启后是空的 —— 而台账里的 gid 是上一进程留下的。
    /// 于是 Advance 拿到 Unknown 就跳过，那条记录**永远停在 pending**，
    /// 「跳过已下载」再也认不出它（实测 douyin_downloaded.json 里 240 条全 pending）。
    ///
    /// 现在：先在内存表里查；查不到就逐条 tellStatus 补查。
    /// 只有 aria2 明确报错（gid 已不存在）才保持 Unknown —— 不猜。
    /// </summary>
    public static async Task<bool> AdvanceLedgerAsync()
    {
        var byGid = new Dictionary<string, AriaStatus>();
        foreach (var it in DownloadStore.Instance.Items)
            if (!string.IsNullOrEmpty(it.Gid)) byGid[it.Gid] = it.Status;

        // 内存表里查不到、但台账还欠着的 gid —— 逐条问 aria2
        var ledger = DouyinStore.Instance.Ledger;
        var missing = new List<string>();
        foreach (var gid in ledger.PendingTaskIds())
        {
            if (byGid.ContainsKey(gid)) continue;
            if (missing.Contains(gid)) continue;
            missing.Add(gid);
        }

        foreach (var gid in missing)
        {
            try
            {
                var one = await DownloadStore.Instance.Engine.TellStatusAsync(gid);
                if (one is not null) byGid[gid] = one.Status;
            }
            catch { }
        }

        return ledger.Advance(gid =>
            byGid.TryGetValue(gid, out var st)
                ? st switch
                {
                    AriaStatus.Complete => DouyinTaskState.Complete,
                    AriaStatus.Error or AriaStatus.Removed => DouyinTaskState.Failed,
                    AriaStatus.Active or AriaStatus.Waiting or AriaStatus.Paused => DouyinTaskState.Running,
                    _ => DouyinTaskState.Unknown,
                }
                : DouyinTaskState.Unknown);
    }
}
