using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ParseDl.Services.Douyin;

/// <summary>台账记录状态：pending = 已提交还没全成功；done = 全部任务成功（真正的「已下载」）。</summary>
public enum DouyinLedgerState { Pending, Done }

/// <summary>台账侧看到的工作状态（由调用方从 AriaStatus 映射过来）。</summary>
public enum DouyinTaskState { Complete, Failed, Running, Unknown }

/// <summary>一条下载记录（作品粒度）。</summary>
public sealed class DouyinDownloadRecord
{
    public string AwemeId { get; init; } = "";
    /// <summary>下载时间（epoch millis）。v1 老记录没有这个值。</summary>
    public long? At { get; init; }
    public string? Title { get; init; }
    public string? Author { get; init; }
    public DouyinLedgerState State { get; init; } = DouyinLedgerState.Done;
    /// <summary>这条作品提交过的任务 id（aria2 gid）。只用于推进 Pending → Done。</summary>
    public List<string> TaskIds { get; init; } = new();

    public bool IsDone => State == DouyinLedgerState.Done;
    public DateTime? Time => At is null ? null : DateTimeOffset.FromUnixTimeMilliseconds(At.Value).LocalDateTime;
}

/// <summary>
/// 「已下载」台账 —— 对齐 Flutter 版 lib/services/douyin_ledger.dart。
///
/// **粒度是「作品」而不是「文件」**（键 = aweme_id）：一条图文里少下了一张图，
/// 整条作品也算已下载，这样「跳过已下载 N 个」的数字才和作品数对得上。
///
/// 相对浏览器形态的改动：存文件（&lt;数据目录&gt;\douyin_downloaded.json）而不是
/// localStorage；形状校验（读到坏数据整份丢弃）；v3 起记录时间/标题/作者/状态/任务 id；
/// 按条数上限丢最旧（不按当前列表裁剪 —— 那会让历史凭空消失）。
/// </summary>
public sealed class DouyinLedger
{
    public const string FileName = "douyin_downloaded.json";
    public const int FormatVersion = 3;
    /// <summary>记录条数上限（超出丢最旧）。实测重度用户 5215 条，取 20000。</summary>
    public const int MaxRecords = 20000;

    private readonly object _gate = new();
    private Dictionary<string, DouyinDownloadRecord> _records = new();
    private bool _loaded;

    public string FilePath => Path.Combine(AppPaths.DataDir, FileName);

    public bool Loaded { get { lock (_gate) return _loaded; } }

    /// <summary>台账里的全部条目数（含还在下的）—— 「跳过已下载」按这个集合判。</summary>
    public int Count { get { lock (_gate) { EnsureLoaded(); return _records.Count; } } }

    /// <summary>已下完的作品数 —— 界面上「已下载 N 个」用它。</summary>
    public int DoneCount { get { lock (_gate) { EnsureLoaded(); return _records.Values.Count(r => r.IsDone); } } }

    public bool Contains(string awemeId)
    {
        lock (_gate)
        {
            EnsureLoaded();
            return !string.IsNullOrEmpty(awemeId) && _records.ContainsKey(awemeId);
        }
    }

    public bool ContainsMedia(string? postId) => !string.IsNullOrEmpty(postId) && Contains(postId!);

    /// <summary>已下完的记录，按下载时间从新到旧；没有时间的（老记录）排最后。</summary>
    public List<DouyinDownloadRecord> Records
    {
        get
        {
            lock (_gate)
            {
                EnsureLoaded();
                var list = _records.Values.Where(r => r.IsDone).ToList();
                list.Sort((a, b) =>
                {
                    if (a.At is null && b.At is null) return string.CompareOrdinal(a.AwemeId, b.AwemeId);
                    if (a.At is null) return 1;
                    if (b.At is null) return -1;
                    return b.At.Value.CompareTo(a.At.Value);
                });
                return list;
            }
        }
    }

    public void Load()
    {
        lock (_gate)
        {
            EnsureLoaded();
        }
    }

    private void EnsureLoaded()
    {
        if (_loaded) return;
        _loaded = true;
        try
        {
            if (!File.Exists(FilePath)) return;
            _records = Decode(File.ReadAllText(FilePath));
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[抖音台账] 读取失败：" + ex.Message);
            _records = new();
        }
    }

    /// <summary>解析台账：v3 / v2 / v1 都认；形状不对整份丢弃。</summary>
    private static Dictionary<string, DouyinDownloadRecord> Decode(string raw)
    {
        var outMap = new Dictionary<string, DouyinDownloadRecord>();
        try
        {
            var node = JsonNode.Parse(raw) as JsonObject;
            if (node is null) return outMap;

            var items = node["items"] as JsonObject;
            var ver = node["version"];
            var version = ver is null ? -1 : (int.TryParse(ver.ToString(), out var v) ? v : -1);

            if ((version == FormatVersion || version == 2) && items is not null)
            {
                foreach (var kv in items)
                {
                    if (string.IsNullOrEmpty(kv.Key)) continue;
                    if (kv.Value is not JsonObject o) continue;
                    var t = o["t"];
                    var f = o["f"] as JsonArray;
                    outMap[kv.Key] = new DouyinDownloadRecord
                    {
                        AwemeId = kv.Key,
                        At = t is null ? null : (long.TryParse(t.ToString(), out var at) ? at : null),
                        Title = Str(o["text"]),
                        Author = Str(o["user"]),
                        // v2 没有 s，缺省按「已下载」
                        State = (o["s"]?.ToString() == "pending") ? DouyinLedgerState.Pending : DouyinLedgerState.Done,
                        TaskIds = f is null ? new List<string>()
                            : f.Select(x => x?.ToString() ?? "").Where(x => x.Length > 0).ToList(),
                    };
                }
                return outMap;
            }

            // v1（以及任何 {id: true} 形状）
            foreach (var kv in node)
            {
                if (string.IsNullOrEmpty(kv.Key)) continue;
                if (kv.Value is JsonValue jv && jv.TryGetValue<bool>(out var b) && b)
                    outMap[kv.Key] = new DouyinDownloadRecord { AwemeId = kv.Key };
            }
        }
        catch
        {
            // 整份丢弃
        }
        return outMap;
    }

    private static string? Str(JsonNode? n)
    {
        var s = n?.ToString()?.Trim();
        return string.IsNullOrEmpty(s) ? null : s;
    }

    /// <summary>时间戳保证严格递增：同一毫秒内连续标记多条时顺序才确定。</summary>
    private long NextStamp()
    {
        var now = DateTimeOffset.Now.ToUnixTimeMilliseconds();
        long maxAt = 0;
        foreach (var r in _records.Values)
            if (r.At is not null && r.At.Value > maxAt) maxAt = r.At.Value;
        return now > maxAt ? now : maxAt + 1;
    }

    /// <summary>
    /// 记为「已提交下载」（作品粒度，记成 Pending）。
    /// 入队成功 ≠ 拿到文件，之后由 <see cref="Advance"/> 按任务结局转成已下载或撤销。
    /// </summary>
    public void MarkQueued(IReadOnlyDictionary<string, (List<string> TaskIds, string? Title, string? Author)> byAweme)
    {
        if (byAweme.Count == 0) return;
        lock (_gate)
        {
            EnsureLoaded();
            long? stamp = null;
            long TakeStamp() => stamp ??= NextStamp();
            var changed = false;

            foreach (var kv in byAweme)
            {
                var id = kv.Key;
                if (string.IsNullOrEmpty(id)) continue;
                _records.TryGetValue(id, out var old);
                var (taskIds, title, author) = kv.Value;

                if (old is null)
                {
                    _records[id] = new DouyinDownloadRecord
                    {
                        AwemeId = id,
                        At = TakeStamp(),
                        Title = title,
                        Author = author,
                        State = DouyinLedgerState.Pending,
                        TaskIds = taskIds,
                    };
                    changed = true;
                }
                else if (!old.IsDone && !SameTaskIds(old.TaskIds, taskIds))
                {
                    // 同一作品再次提交（失败后重试）—— 换成新任务 id，不并集：
                    // 旧的失败任务留着会让 Advance 把刚下好的作品又撤销
                    _records[id] = new DouyinDownloadRecord
                    {
                        AwemeId = id,
                        At = old.At,
                        Title = old.Title ?? title,
                        Author = old.Author ?? author,
                        State = DouyinLedgerState.Pending,
                        TaskIds = taskIds,
                    };
                    changed = true;
                }
            }

            if (!changed) return;
            Trim();
            Save();
        }
    }

    /// <summary>直接记为已下载（不给任务 id 时用）。已算已下载的不覆盖时间。</summary>
    public void MarkDone(IEnumerable<string> awemeIds, string? title = null, string? author = null)
    {
        lock (_gate)
        {
            EnsureLoaded();
            long? stamp = null;
            long TakeStamp() => stamp ??= NextStamp();
            var changed = false;
            foreach (var id in awemeIds)
            {
                if (string.IsNullOrEmpty(id)) continue;
                _records.TryGetValue(id, out var old);
                if (old is not null && old.IsDone) continue;
                _records[id] = new DouyinDownloadRecord
                {
                    AwemeId = id,
                    At = old?.At ?? TakeStamp(),
                    Title = old?.Title ?? title,
                    Author = old?.Author ?? author,
                };
                changed = true;
            }
            if (!changed) return;
            Trim();
            Save();
        }
    }

    /// <summary>
    /// 按任务的实际结局推进台账，返回是否变化。
    ///   · 任一任务 Failed → 撤掉这条记录（下次刷到同一作品能重试）；
    ///   · 查得到的任务全部 Complete → 转成 Done；
    ///   · 还有 Running → 保持在下；
    ///   · 全部 Unknown（任务被重试换掉/被删）→ 保持原状，不猜。
    /// </summary>
    public bool Advance(Func<string, DouyinTaskState> statusOf)
    {
        lock (_gate)
        {
            EnsureLoaded();
            var changed = false;
            foreach (var id in _records.Keys.ToList())
            {
                var r = _records[id];
                if (r.IsDone) continue;
                if (r.TaskIds.Count == 0) continue;

                var known = r.TaskIds.Select(statusOf)
                    .Where(s => s != DouyinTaskState.Unknown).ToList();
                if (known.Count == 0) continue;

                if (known.Any(s => s == DouyinTaskState.Failed))
                {
                    _records.Remove(id);
                    changed = true;
                    continue;
                }
                if (known.All(s => s == DouyinTaskState.Complete))
                {
                    _records[id] = new DouyinDownloadRecord
                    {
                        AwemeId = id,
                        At = NextStamp(),
                        Title = r.Title,
                        Author = r.Author,
                    };
                    changed = true;
                }
            }
            if (!changed) return false;
            Save();
            return true;
        }
    }

    public void Remove(string awemeId)
    {
        lock (_gate)
        {
            EnsureLoaded();
            if (_records.Remove(awemeId)) Save();
        }
    }

    /// <summary>「清除下载记录」。返回是否真的落盘（写盘失败时不能报「已清除」）。</summary>
    public bool Clear()
    {
        lock (_gate)
        {
            EnsureLoaded();
            if (_records.Count == 0) return true;
            _records.Clear();
            return Save();
        }
    }

    /// <summary>超出上限时丢最旧的（没有时间的当作最旧）。</summary>
    private void Trim()
    {
        if (_records.Count <= MaxRecords) return;
        var sorted = _records.Values.ToList();
        sorted.Sort((a, b) =>
        {
            if (a.At is null && b.At is null) return string.CompareOrdinal(a.AwemeId, b.AwemeId);
            if (a.At is null) return -1;
            if (b.At is null) return 1;
            return a.At.Value.CompareTo(b.At.Value);   // 最旧在前
        });
        var drop = sorted.Count - MaxRecords;
        for (var i = 0; i < drop; i++) _records.Remove(sorted[i].AwemeId);
    }

    private bool Save()
    {
        try
        {
            var dir = Path.GetDirectoryName(FilePath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            var items = new JsonObject();
            foreach (var e in _records.Values)
            {
                var o = new JsonObject();
                if (e.At is not null) o["t"] = e.At.Value;
                if (e.Title is not null) o["text"] = e.Title;
                if (e.Author is not null) o["user"] = e.Author;
                // Done 是缺省态，不写字段
                if (!e.IsDone) o["s"] = "pending";
                if (e.TaskIds.Count > 0)
                {
                    var arr = new JsonArray();
                    foreach (var t in e.TaskIds) arr.Add(t);
                    o["f"] = arr;
                }
                items[e.AwemeId] = o;
            }
            var payload = new JsonObject
            {
                ["version"] = FormatVersion,
                ["items"] = items,
            };

            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, payload.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(tmp, FilePath, overwrite: true);
            return true;
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[抖音台账] 写入失败：" + ex.Message);
            return false;
        }
    }

    private static bool SameTaskIds(List<string> a, List<string> b)
        => a.Count == b.Count && new HashSet<string>(a).SetEquals(b);
}
