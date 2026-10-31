using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace ParseDl.Services.X;

/// <summary>
/// **X 下载台账**（2026-10-31 加，用户要求「下载一个计数一，往上加」）。
///
/// ### 为什么不能直接用 download_ledger.json
/// 那份是**任务级**台账，`MaxEntries = 2000`，超出就丢掉最老的。
/// X 一次批量能下几百上千个媒体，几轮就把自己的记录挤没了 ——
/// 实测用户那边 `download_ledger.json` 里 **一条 X 都没有**，
/// 所以总览页 X 的计数恒为 0。用户要的是「累计下过多少」，那就得有个
/// **只增不删的计数器**，而不是会被裁剪的明细表。
///
/// ### 做法
/// 一条记录 = 一个已下载的媒体（按 gid 去重，同一个不会数两次）。
/// 只存必要字段，不做上限裁剪；数量级到几十万也才十几 MB，
/// 而且只在完成时写一次（走防抖，不阻塞下载）。
/// </summary>
public static class XLedger
{
    private const string FileName = "x_downloaded.json";
    private static readonly object _lock = new();
    private static Dictionary<string, Record>? _records;
    private static bool _dirty;
    private static readonly System.Threading.Timer _timer;

    static XLedger()
    {
        // 防抖 3 秒落盘：批量下载时每秒可能完成几十个，不能每个都写文件。
        _timer = new System.Threading.Timer(_ => Flush(), null,
            System.Threading.Timeout.Infinite, System.Threading.Timeout.Infinite);
    }

    /// <summary>一条已下载记录。</summary>
    public sealed class Record
    {
        public string Gid { get; set; } = "";
        public string PostId { get; set; } = "";
        public string FileName { get; set; } = "";
        public string Dir { get; set; } = "";
        public long Bytes { get; set; }
        public string At { get; set; } = "";
    }

    public static string FilePath => Path.Combine(AppPaths.DataDir, FileName);

    private static Dictionary<string, Record> Records
    {
        get
        {
            if (_records is not null) return _records;
            _records = new Dictionary<string, Record>(StringComparer.Ordinal);
            try
            {
                if (File.Exists(FilePath))
                {
                    var loaded = JsonSerializer.Deserialize<Dictionary<string, Record>>(
                        File.ReadAllText(FilePath));
                    if (loaded is not null)
                        _records = new Dictionary<string, Record>(loaded, StringComparer.Ordinal);
                }
            }
            catch (Exception ex)
            {
                Aria2Engine.Log("[X 台账] 读取失败（从空开始）：" + ex.Message);
            }
            return _records;
        }
    }

    /// <summary>已下载的媒体总数（总览页用）。</summary>
    public static int Count { get { lock (_lock) return Records.Count; } }

    /// <summary>累计字节数。</summary>
    public static long TotalBytes
    {
        get { lock (_lock) { long s = 0; foreach (var r in Records.Values) s += r.Bytes; return s; } }
    }

    /// <summary>
    /// 记一条「下完了」。按 gid 去重 —— 同一个任务重复回调只算一次。
    /// 由 <see cref="DownloadStore"/> 的终态钩子在 Complete 时调用。
    /// </summary>
    public static void MarkDone(string gid, string postId, string fileName, string dir, long bytes)
    {
        if (string.IsNullOrWhiteSpace(gid)) return;
        lock (_lock)
        {
            var map = Records;
            if (map.ContainsKey(gid)) return;   // 已经记过，不重复计数
            map[gid] = new Record
            {
                Gid = gid,
                PostId = postId ?? "",
                FileName = fileName ?? "",
                Dir = dir ?? "",
                Bytes = bytes,
                At = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            };
            _dirty = true;
        }
        _timer.Change(3000, System.Threading.Timeout.Infinite);
    }

    public static void Flush()
    {
        lock (_lock)
        {
            if (!_dirty || _records is null) return;
            try
            {
                var json = JsonSerializer.Serialize(_records,
                    new JsonSerializerOptions { WriteIndented = false });
                var tmp = FilePath + ".tmp";
                File.WriteAllText(tmp, json);
                File.Move(tmp, FilePath, overwrite: true);
                _dirty = false;
            }
            catch (Exception ex)
            {
                Aria2Engine.Log("[X 台账] 保存失败：" + ex.Message);
            }
        }
    }

    public static void Clear()
    {
        lock (_lock) { _records?.Clear(); _dirty = true; Flush(); }
    }
}
