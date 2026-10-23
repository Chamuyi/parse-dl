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

    private void SaveUnlocked()
    {
        try
        {
            if (_entries.Count > MaxEntries)
                _entries = _entries.Skip(_entries.Count - MaxEntries).ToList();
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(_entries,
                new JsonSerializerOptions { WriteIndented = true }));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[Ledger] 保存台账失败：" + ex.Message);
        }
    }

    /// <summary>记一笔（已存在的 gid 会被更新，不重复追加）。</summary>
    public void Record(DownloadItem item)
    {
        lock (_lock)
        {
            EnsureLoaded();
            var now = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            var existing = _entries.FirstOrDefault(e => e.Gid == item.Gid);
            if (existing is not null)
            {
                _entries.Remove(existing);
                _entries.Add(existing with
                {
                    Status = item.StatusText,
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
                    Status = item.StatusText,
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