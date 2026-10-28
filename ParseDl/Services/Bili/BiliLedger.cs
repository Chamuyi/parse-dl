using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ParseDl.Services.Bili;

/// <summary>台账里一条记录的状态。</summary>
public enum BiliLedgerState
{
    /// <summary>已提交但还没下完（防重复提交）。</summary>
    Pending,
    /// <summary>已下完。</summary>
    Done,
}

/// <summary>一条下载记录（分 P 粒度）。</summary>
public sealed class BiliDownloadRecord
{
    /// <summary>台账内部唯一主键（bvid+cid 的哈希）。</summary>
    public string HashId { get; set; } = "";
    /// <summary>可读键组，只用于展示与排查，判重不看它。</summary>
    public string Bvid { get; set; } = "";
    public long Cid { get; set; }
    /// <summary>下载时间（epoch ms）。</summary>
    public long At { get; set; }
    /// <summary>稿件标题。</summary>
    public string? Title { get; set; }
    /// <summary>UP 主。</summary>
    public string? Author { get; set; }
    public BiliLedgerState State { get; set; } = BiliLedgerState.Done;

    [JsonIgnore]
    public bool IsDone => State == BiliLedgerState.Done;

    /// <summary>历史列表里给人看的一行：BV1xx411c7mD · cid 123。</summary>
    [JsonIgnore]
    public string Label => string.IsNullOrEmpty(Bvid)
        ? HashId
        : (Cid > 0 ? Bvid + " · cid " + Cid : Bvid);
}

/// <summary>
/// B 站下载台账（移植自原项目 lib/services/bili_ledger.dart，28450 字节）。
///
/// ### 为什么必须有它
/// 设置里有「跳过已下载的分 P」这个开关，但 WinUI3 版**从来没有台账**，
/// 所以那个开关一直是个死开关（设置页的说明文字自己写着「台账未接时此项无实际效果」）。
/// 用户重复点下载会一遍遍重下同样的分 P。
///
/// ### 判重口径（与原项目一致）
/// 主键是 `bvid + cid` 的哈希，**pending 与 done 都算「已处理过」**：
/// 还在下的也算，否则用户手快再点一次就会重复提交同一个分 P。
/// 只想看「真的下完了」的调用方用 <see cref="IsDone"/> / <see cref="DoneCount"/>。
/// </summary>
public sealed class BiliLedger
{
    public static BiliLedger Instance { get; } = new();

    /// <summary>台账文件名（与抖音那份各自独立，格式互不相干）。</summary>
    public const string FileName = "bili_downloaded.json";

    /// <summary>落盘格式版本。</summary>
    public const int FormatVersion = 1;

    /// <summary>记录上限：超出丢最旧的。按分 P 记，条数比抖音更多，故取 20000。</summary>
    public const int MaxRecords = 20000;

    private readonly Dictionary<string, BiliDownloadRecord> _records = new();
    private bool _loaded;

    public event Action? Changed;

    private string FilePath => Path.Combine(AppPaths.DataDir, FileName);

    /// <summary>台账条目总数（含还在下载的）。</summary>
    public int Count { get { lock (_records) return _records.Count; } }

    /// <summary>**已下完**的分 P 数（界面「已下载 N 个」用它）。</summary>
    public int DoneCount { get { lock (_records) return _records.Values.Count(r => r.IsDone); } }

    public bool Loaded => _loaded;

    /// <summary>算主键。bvid 与 cid 任一为空时退回可用部分，保证稳定。</summary>
    public static string HashOf(string bvid, long cid)
    {
        var raw = (bvid ?? "").Trim().ToLowerInvariant() + "|" + cid;
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(raw));
        return Convert.ToHexString(bytes).ToLowerInvariant()[..32];
    }

    /// <summary>这条键组在不在台账里（pending 与 done 都算）。</summary>
    public bool Contains(string bvid, long cid)
    {
        var h = HashOf(bvid, cid);
        lock (_records) return _records.ContainsKey(h);
    }

    /// <summary>这条键组是不是已经下完了。</summary>
    public bool IsDone(string bvid, long cid)
    {
        var h = HashOf(bvid, cid);
        lock (_records) return _records.TryGetValue(h, out var r) && r.IsDone;
    }

    /// <summary>全部记录（按时间倒序，给历史列表用）。</summary>
    public List<BiliDownloadRecord> All()
    {
        lock (_records) return _records.Values.OrderByDescending(r => r.At).ToList();
    }

    // ── 读写 ────────────────────────────────────────────────

    public void Load()
    {
        if (_loaded) return;
        _loaded = true;
        try
        {
            if (!File.Exists(FilePath)) return;
            var json = File.ReadAllText(FilePath);
            var doc = JsonSerializer.Deserialize<LedgerFile>(json);
            if (doc?.Records is null) return;
            lock (_records)
            {
                foreach (var r in doc.Records)
                {
                    if (string.IsNullOrEmpty(r.HashId)) continue;
                    _records[r.HashId] = r;
                }
            }
        }
        catch (Exception ex)
        {
            // 台账坏了不能让程序起不来：记一行日志，从空台账继续
            Aria2Engine.Log("[BiliLedger] 读取失败，从空台账继续：" + ex.Message);
        }
    }

    /// <summary>标记一条为「已提交」（防重复提交）。</summary>
    public void MarkPending(string bvid, long cid, string? title, string? author)
        => Upsert(bvid, cid, title, author, BiliLedgerState.Pending);

    /// <summary>标记一条为「已下完」。</summary>
    public void MarkDone(string bvid, long cid, string? title, string? author)
        => Upsert(bvid, cid, title, author, BiliLedgerState.Done);

    private void Upsert(string bvid, long cid, string? title, string? author, BiliLedgerState state)
    {
        var h = HashOf(bvid, cid);
        lock (_records)
        {
            if (_records.TryGetValue(h, out var exist))
            {
                // 已经是 done 的不要退回 pending（重下同一分 P 不该让状态倒退）
                if (exist.IsDone && state == BiliLedgerState.Pending) return;
                exist.State = state;
                exist.At = DateTimeOffset.Now.ToUnixTimeMilliseconds();
                if (!string.IsNullOrEmpty(title)) exist.Title = title;
                if (!string.IsNullOrEmpty(author)) exist.Author = author;
            }
            else
            {
                _records[h] = new BiliDownloadRecord
                {
                    HashId = h,
                    Bvid = (bvid ?? "").Trim(),
                    Cid = cid,
                    At = DateTimeOffset.Now.ToUnixTimeMilliseconds(),
                    Title = title,
                    Author = author,
                    State = state,
                };
                Trim();
            }
        }
        Save();
        try { Changed?.Invoke(); } catch { }
    }

    /// <summary>超出上限时丢最旧的。</summary>
    private void Trim()
    {
        if (_records.Count <= MaxRecords) return;
        var drop = _records.Values.OrderBy(r => r.At).Take(_records.Count - MaxRecords).ToList();
        foreach (var d in drop) _records.Remove(d.HashId);
    }

    /// <summary>清空台账（设置页「清空下载历史」用）。</summary>
    public void Clear()
    {
        lock (_records) _records.Clear();
        Save();
        try { Changed?.Invoke(); } catch { }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(AppPaths.DataDir);
            LedgerFile doc;
            lock (_records)
            {
                doc = new LedgerFile
                {
                    Version = FormatVersion,
                    Records = _records.Values.OrderBy(r => r.At).ToList(),
                };
            }
            var json = JsonSerializer.Serialize(doc, new JsonSerializerOptions
            {
                WriteIndented = false,
                Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            });
            File.WriteAllText(FilePath, json);
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[BiliLedger] 保存失败：" + ex.Message);
        }
    }

    private sealed class LedgerFile
    {
        public int Version { get; set; } = FormatVersion;
        public List<BiliDownloadRecord> Records { get; set; } = new();
    }
}
