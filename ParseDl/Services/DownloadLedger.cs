using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;

namespace ParseDl.Services;

/// <summary>
/// 下载台账 —— 把历史任务落盘到 &lt;数据目录&gt;\download_ledger.json。
///
/// 为什么需要它：aria2 的会话在重启后是空的，但用户要能看到「我之前下过什么」。
/// 台账只记最终结果（完成 / 失败），不记进行中的中间态 —— 中间态是 aria2 的职责。
///
/// 写入时机：由 DownloadStore 在刷新时按需调用（Status 变成终态就记一笔）。
/// 用「读-改-写 + 目录上限」而不是单文件追加：条目要能被去重和裁剪。
/// </summary>
public sealed class DownloadLedger
{
    public static DownloadLedger Instance { get; } = new();

    private const int MaxEntries = 2000;
    private readonly object _lock = new();
    private List<LedgerEntry> _entries = new();
    private bool _loaded;

    public sealed record LedgerEntry
    {
        public string Gid { get; init; } = "";
        public string Url { get; init; } = "";
        public string FileName { get; init; } = "";
        public string Dir { get; init; } = "";
        public string Module { get; init; } = "";
        public string Status { get; init; } = "";
        public long TotalBytes { get; init; }
        public string FinishedAt { get; init; } = "";
        public string Error { get; init; } = "";
    }

    public string FilePath => Path.Combine(AppPaths.DataDir, "download_ledger.json");

    private void EnsureLoaded()
    {
        if (_loaded) return;
        _loaded = true;
        try
        {
            if (!File.Exists(FilePath)) return;
            var json = File.ReadAllText(FilePath);
            var list = JsonSerializer.Deserialize<List<LedgerEntry>>(json);
            if (list is not null) _entries = list;
        }
        catch (Exception ex)
        {
            // 坏文件不阻塞启动，留证据后从头开始
            Aria2Engine.Log("[Ledger] 读取台账失败：" + ex.Message);
            try { File.Move(FilePath, FilePath + ".bad", overwrite: true); } catch { }
        }
    }

    // ==== 2026-10-31 防抖 + 异步落盘 ====
    //
    // 原来每次 Record 都**同步全量序列化 + 两次文件 IO**。台账上限 2000 条、
    // 实测文件已 2 MB，而 DownloadStore 的终态钩子在一轮轮询里会对每个刚变
    // 终态的任务各调一次 Record —— 用户那轮跑了 1355 个媒体，等于上千次
    // 「序列化 2MB + 写盘 + Move」。这些全发生在 UI 线程的轮询回调里，
    // 于是窗口直接「未响应」，日志同时刷屏
    // `[Ledger] 保存台账失败：Access to the path is denied.`
    // （上一次写的 .tmp 还没 Move 完，下一次又来抢同一个文件）。
    //
    // 现在：Record 只改内存 → 防抖 2 秒 → 线程池写盘；失败只记一次日志。
    private void SaveUnlocked()
    {
        _saveTimer?.Dispose();
        _saveTimer = new Timer(_ => SaveNow(), null,
            TimeSpan.FromSeconds(2), Timeout.InfiniteTimeSpan);
    }

    private Timer? _saveTimer;
    private int _saving;              // 0/1，防止两次写盘重叠
    private bool _saveFailedLogged;

    /// <summary>立即同步落盘（进程退出前、以及需要强一致的场合调）。</summary>
    public void Flush()
    {
        _saveTimer?.Dispose();
        _saveTimer = null;
        SaveNow();
    }

    private void SaveNow()
    {
        // 已经在写就跳过 —— 防抖到期会再来一次，不排队堆积
        if (Interlocked.Exchange(ref _saving, 1) == 1) return;
        try
        {
            List<LedgerEntry> snapshot;
            lock (_lock)
            {
                if (_entries.Count > MaxEntries)
                    _entries = _entries.Skip(_entries.Count - MaxEntries).ToList();
                snapshot = _entries.ToList();
            }

            var tmp = FilePath + ".tmp";
            var json = JsonSerializer.Serialize(snapshot,
                new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(tmp, json);
            File.Move(tmp, FilePath, overwrite: true);
            _saveFailedLogged = false;
        }
        catch (Exception ex)
        {
            // 失败只记一次，避免「每次终态都刷一行」把日志打爆
            if (!_saveFailedLogged)
            {
                _saveFailedLogged = true;
                Aria2Engine.Log("[Ledger] 保存台账失败（后续相同错误不再重复记录）：" + ex.Message);
            }
        }
        finally
        {
            Interlocked.Exchange(ref _saving, 0);
        }
    }

    /// <summary>记一笔（已存在的 gid 会被更新，不重复追加）。</summary>
    public void Record(DownloadItem item) => Record(item, null);

    /// <summary>
    /// 记一笔，<paramref name="statusOverride"/> 非空时用它当状态文案。
    ///
    /// **为什么要这个重载**（2026-11-20）：用户取消下载时任务从界面列表直接移除，
    /// 状态没走到任何终态，于是 <c>RunTerminalHooks</c> 的「旧状态 != 新状态」永远不成立，
    /// 台账里连一条痕迹都没有 —— 用户事后问「我取消的那批记录在哪」时无从查起。
    /// 取消要走这里显式写一条「已取消」。
    /// </summary>
    public void Record(DownloadItem item, string? statusOverride)
    {
        lock (_lock)
        {
            EnsureLoaded();
            var now = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            var status = string.IsNullOrEmpty(statusOverride) ? item.StatusText : statusOverride!;
            var existing = _entries.FirstOrDefault(e => e.Gid == item.Gid);
            if (existing is not null)
            {
                _entries.Remove(existing);
                _entries.Add(existing with
                {
                    Status = status,
                    TotalBytes = item.TotalBytes,
                    FileName = item.FileName,
                    Dir = item.Dir,
                    FinishedAt = now,
                    Error = item.Error,
                });
            }
            else
            {
                _entries.Add(new LedgerEntry
                {
                    Gid = item.Gid,
                    Url = item.Url,
                    FileName = item.FileName,
                    Dir = item.Dir,
                    Module = item.Module,
                    Status = status,
                    TotalBytes = item.TotalBytes,
                    FinishedAt = now,
                    Error = item.Error,
                });
            }
            SaveUnlocked();
        }
    }

    /// <summary>取台账（最近的在前）。</summary>
    public IReadOnlyList<LedgerEntry> Query(string? module = null, int limit = 200)
    {
        lock (_lock)
        {
            EnsureLoaded();
            IEnumerable<LedgerEntry> q = _entries;
            if (!string.IsNullOrEmpty(module)) q = q.Where(e => e.Module == module);
            return q.Reverse().Take(limit).ToList();
        }
    }

    /// <summary>统计已完成的条目数与总字节数（给总览页用）。</summary>
    public (int Count, long Bytes) Stats()
    {
        lock (_lock)
        {
            EnsureLoaded();
            var done = _entries.Where(e => e.Status == "已完成").ToList();
            return (done.Count, done.Sum(e => e.TotalBytes));
        }
    }

    /// <summary>清空台账（不回删文件）。</summary>
    /// <summary>
    /// **按磁盘现状回填历史**（2026-10-30 加）。
    ///
    /// 为什么需要：台账钩子长期失效（见 DownloadStore.RunTerminalHooks 注释），
    /// 历史上真实下过的文件一条都没记上 —— 实测 exe/downloads 下有 103 个文件，
    /// 台账却是 []，总览页「累计下载」永远显示 0。
    ///
    /// 做法：扫下载根目录，把「台账里还没有的」文件补记成已完成（按 目录+文件名 去重）。
    /// **幂等**：重复调用不会重复记。
    /// 只认结果文件，不认中间件：跳过 .aria2 控制文件、.tmp、以及实况图的 .orig.jpg 备份。
    /// </summary>
    public int BackfillFromDisk()
    {
        var root = AppPaths.DefaultDownloadDir;
        if (!Directory.Exists(root)) return 0;

        lock (_lock)
        {
            EnsureLoaded();
            var known = new HashSet<string>();
            foreach (var e in _entries) known.Add(e.Dir + "|" + e.FileName);

            var added = 0;
            foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                var name = Path.GetFileName(file);
                if (name.EndsWith(".aria2", StringComparison.OrdinalIgnoreCase)) continue;
                if (name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase)) continue;
                if (name.EndsWith(".orig.jpg", StringComparison.OrdinalIgnoreCase)) continue;
                var dir = Path.GetDirectoryName(file) ?? "";
                if (!known.Add(dir + "|" + name)) continue;

                long size = 0;
                try { size = new FileInfo(file).Length; } catch { }
                var when = "";
                try { when = File.GetLastWriteTime(file).ToString("yyyy-MM-dd HH:mm:ss"); } catch { }

                _entries.Add(new LedgerEntry
                {
                    Gid = "disk:" + name,
                    Url = "",
                    FileName = name,
                    Dir = dir,
                    Module = "历史回填",
                    Status = "已完成",
                    TotalBytes = size,
                    FinishedAt = when,
                });
                added++;
            }

            if (added > 0) SaveUnlocked();
            Aria2Engine.Log($"[Ledger] backfill added={added} total={_entries.Count}");
            return added;
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            _entries = new List<LedgerEntry>();
            _loaded = true;
            SaveUnlocked();
        }
    }
}