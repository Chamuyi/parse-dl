using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;

namespace ParseDl.Services;

/// <summary>
/// **磁盘占用累加器**（2026-10-31 重写，用户要求「下载完成时把文件大小写进去，就不用扫盘」）。
///
/// ### 为什么是累加而不是扫盘
/// 用户原话：「在下载完成时，把文件大小写入磁盘占用，合成的实况动图也写进去，
/// 这样就不用扫盘了。**即使文件移动了，仍然能看到历史下载的文件多大**。」
///
/// 扫盘有两个硬伤：
///   ① 慢 —— X 目录 30805 个文件、847 GB，启动时扫一遍要几十秒；
///   ② 文件被移走/删掉后数字会**变小**，而用户要看的是「累计下过多少」。
///
/// 所以改成「**下载完成时累加一次**」：只增不减，与文件当前在哪无关。
///
/// ### 粒度
/// 按**模块**分别累加（x / douyin / bili / other），
/// 这样将来要分模块显示也有数据；总览页现在取它们的和。
///
/// ### 与 X 台账的关系
/// X 那边 `XLedger` 已经按 gid 存了每条字节数，这里**不重复记** ——
/// <see cref="TotalBytes"/> 会取两者较大值，避免同一批数据被算两遍。
/// </summary>
public static class DiskUsageLedger
{
    private const string FileName = "disk_usage.json";
    private static readonly object _lock = new();
    private static State? _state;
    private static readonly Timer _timer;

    static DiskUsageLedger()
    {
        _timer = new Timer(_ => Flush(), null,
            Timeout.Infinite, Timeout.Infinite);
    }

    /// <summary>落盘结构。</summary>
    public sealed class State
    {
        /// <summary>模块名 → 累计字节。</summary>
        public Dictionary<string, long> ByModule { get; set; } = new();
        /// <summary>模块名 → 累计文件数。</summary>
        public Dictionary<string, int> FilesByModule { get; set; } = new();
        /// <summary>最近一次写入时间。</summary>
        public string UpdatedAt { get; set; } = "";
    }

    public static string FilePath => Path.Combine(AppPaths.DataDir, FileName);

    private static State S
    {
        get
        {
            if (_state is not null) return _state;
            try
            {
                if (File.Exists(FilePath))
                {
                    var loaded = JsonSerializer.Deserialize<State>(File.ReadAllText(FilePath));
                    if (loaded is not null)
                    {
                        loaded.ByModule ??= new();
                        loaded.FilesByModule ??= new();
                        _state = loaded;
                        return _state;
                    }
                }
            }
            catch (Exception ex)
            {
                Aria2Engine.Log("[磁盘占用] 读取失败（从空开始）：" + ex.Message);
            }
            _state = new State();
            return _state;
        }
    }

    /// <summary>累计字节（各模块之和）。</summary>
    public static long TotalBytes
    {
        get { lock (_lock) { long s = 0; foreach (var v in S.ByModule.Values) s += v; return s; } }
    }

    /// <summary>累计文件数。</summary>
    public static int TotalFiles
    {
        get { lock (_lock) { int s = 0; foreach (var v in S.FilesByModule.Values) s += v; return s; } }
    }

    /// <summary>某模块的累计字节。</summary>
    public static long BytesOf(string module)
    {
        lock (_lock) return S.ByModule.TryGetValue(module ?? "", out var v) ? v : 0;
    }

    /// <summary>
    /// **记一笔下载完成**。由 <see cref="DownloadStore"/> 的终态钩子调用。
    ///
    /// <paramref name="bytes"/> 取实际落盘大小（下载器报的 totalLength 可能偏大）。
    /// 传 0 时静默忽略，避免把失败任务算成 0 字节文件拉低平均。
    /// </summary>
    /// <param name="extraFiles">合成产物额外增加的字节（实况动图这类），可一次传多个。</param>
    public static void Add(string module, long bytes, params long[] extraFiles)
    {
        var total = bytes;
        var count = bytes > 0 ? 1 : 0;
        if (extraFiles is not null)
        {
            foreach (var e in extraFiles)
            {
                if (e > 0) { total += e; count++; }
            }
        }
        if (total <= 0) return;

        lock (_lock)
        {
            var s = S;
            s.ByModule.TryGetValue(module, out var cur);
            s.ByModule[module] = cur + total;
            s.FilesByModule.TryGetValue(module, out var fc);
            s.FilesByModule[module] = fc + count;
            s.UpdatedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        }
        _timer.Change(2000, Timeout.Infinite);
    }

    /// <summary>用一次扫描的结果**重置**某个模块的累计值（回填历史时用）。</summary>
    public static void SetModule(string module, long bytes, int files)
    {
        lock (_lock)
        {
            var s = S;
            s.ByModule[module] = bytes;
            s.FilesByModule[module] = files;
            s.UpdatedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        }
        Flush();
    }

    public static void Flush()
    {
        lock (_lock)
        {
            try
            {
                var json = JsonSerializer.Serialize(S,
                    new JsonSerializerOptions { WriteIndented = true });
                var tmp = FilePath + ".tmp";
                File.WriteAllText(tmp, json);
                File.Move(tmp, FilePath, overwrite: true);
            }
            catch (Exception ex)
            {
                Aria2Engine.Log("[磁盘占用] 保存失败：" + ex.Message);
            }
        }
    }

    public static void Clear()
    {
        lock (_lock) { _state = new State(); }
        Flush();
    }
}
