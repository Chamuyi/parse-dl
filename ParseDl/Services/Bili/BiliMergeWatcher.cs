using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.Bili;

/// <summary>
/// **B 站 DASH 合并的触发者**（2026-10-29 新增）。
///
/// ### 为什么需要它
/// 入队时视频流与音频流是**两条独立任务**分别投给 aria2 的。
/// 两条都下完之后必须用 ffmpeg 合成一个 mp4，否则目录里永远只有
/// `.video.m4s` + `.audio.m4s`，用户拿不到能播的文件。
///
/// 之前 <see cref="BiliMergePipeline"/> 写好了但**没有任何地方调用它** ——
/// 实测下载完的目录里只有两条 m4s，没有 mp4。这个类补上那一环。
///
/// ### 触发方式
/// 入队时 <see cref="Register"/> 登记「视频/音频/输出」三件事；
/// 之后每隔一会儿扫一遍：**两条源文件都存在且非空**就触发合并。
/// 用轮询而不是事件，是因为 aria2 的完成通知会漏（尤其是重启后续传的任务），
/// 轮询「看文件在不在」永远是对的。
/// </summary>
public sealed class BiliMergeWatcher
{
    public static BiliMergeWatcher Instance { get; } = new();

    /// <summary>扫描间隔。太短浪费 IO，太长用户等得久。</summary>
    private static readonly TimeSpan ScanInterval = TimeSpan.FromSeconds(3);

    private readonly List<BiliMergeRequest> _pending = new();
    private readonly BiliMergePipeline _pipeline = new();
    private readonly object _lock = new();
    private CancellationTokenSource? _cts;
    private bool _running;

    /// <summary>已成功合并的条数（界面/日志用）。</summary>
    public int MergedCount { get; private set; }
    /// <summary>合并失败的条数。</summary>
    public int FailedCount { get; private set; }

    /// <summary>登记一对「视频 + 音频 → mp4」。同一条重复登记会被忽略。</summary>
    public void Register(BiliMergeRequest req)
    {
        if (string.IsNullOrEmpty(req.VideoPath) || string.IsNullOrEmpty(req.AudioPath)) return;
        lock (_lock)
        {
            if (_pending.Any(x => x.VideoPath == req.VideoPath)) return;
            _pending.Add(req);
        }
        Aria2Engine.Log("[BiliMerge] 登记待合并：" + Path.GetFileName(req.OutputPath));
        EnsureRunning();
    }

    private void EnsureRunning()
    {
        if (_running) return;
        _running = true;
        _cts = new CancellationTokenSource();
        _ = Task.Run(() => LoopAsync(_cts.Token));
    }

    /// <summary>停止扫描（退出时调用）。</summary>
    public void Stop()
    {
        try { _cts?.Cancel(); } catch { }
        _running = false;
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(ScanInterval, ct); }
            catch (OperationCanceledException) { break; }

            List<BiliMergeRequest> ready;
            lock (_lock)
            {
                ready = _pending.Where(IsReady).ToList();
                foreach (var r in ready) _pending.Remove(r);
            }
            if (ready.Count == 0) continue;

            foreach (var req in ready)
            {
                if (ct.IsCancellationRequested) break;
                try
                {
                    var res = await _pipeline.MergeAsync(req, ct);
                    if (res.Ok)
                    {
                        MergedCount++;
                        Aria2Engine.Log("[BiliMerge] 合并成功：" + Path.GetFileName(req.OutputPath));
                    }
                    else
                    {
                        FailedCount++;
                        Aria2Engine.Log("[BiliMerge] 合并失败（" + res.Failure + "）："
                                        + res.Message + "  文件=" + Path.GetFileName(req.OutputPath));
                    }
                }
                catch (Exception ex)
                {
                    FailedCount++;
                    Aria2Engine.Log("[BiliMerge] 合并异常：" + ex.Message);
                }
            }
        }
    }

    /// <summary>两条源文件都在、都非空、且输出还没生成 → 可以合并。</summary>
    private static bool IsReady(BiliMergeRequest r)
    {
        try
        {
            if (!File.Exists(r.VideoPath)) return false;
            if (!File.Exists(r.AudioPath)) return false;
            // 0 字节说明 aria2 还没真正写（或写失败了），继续等
            if (new FileInfo(r.VideoPath).Length <= 0) return false;
            if (new FileInfo(r.AudioPath).Length <= 0) return false;
            // 已经合并过（输出存在且非空）就不再重复做
            if (File.Exists(r.OutputPath) && new FileInfo(r.OutputPath).Length > 0) return false;
            return true;
        }
        catch { return false; }
    }
}
