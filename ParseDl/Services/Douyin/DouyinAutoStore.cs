using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ParseDl.Services.Douyin;

/// <summary>一个目标的状态机（顺序即推进顺序）。</summary>
public enum DouyinAutoStatus { Waiting, Opening, Collecting, Downloading, Done, Empty, Failed }

/// <summary>状态 ↔ 中文标签。</summary>
public static class DouyinAutoStatusText
{
    public static string Label(this DouyinAutoStatus s) => s switch
    {
        DouyinAutoStatus.Waiting => "等待",
        DouyinAutoStatus.Opening => "打开页面",
        DouyinAutoStatus.Collecting => "收集作品",
        DouyinAutoStatus.Downloading => "提交下载",
        DouyinAutoStatus.Done => "完成",
        DouyinAutoStatus.Empty => "没收集到",
        _ => "失败",
    };

    /// <summary>已经跑完了（不管成没成）—— 用于「已完成 N/M」的统计。</summary>
    public static bool IsSettled(this DouyinAutoStatus s)
        => s is DouyinAutoStatus.Done or DouyinAutoStatus.Empty or DouyinAutoStatus.Failed;

    /// <summary>算「成功」的两种：真下到了东西，或者确认这个页面本来就没有新东西。</summary>
    public static bool IsOk(this DouyinAutoStatus s)
        => s is DouyinAutoStatus.Done or DouyinAutoStatus.Empty;
}

/// <summary>一个待处理的目标（字段可变：跑批过程中原地更新）。</summary>
public sealed class DouyinAutoTask
{
    public DouyinAutoTask(string input, string url)
    {
        Input = input;
        Url = url;
    }

    /// <summary>用户写的原始那一行（可能夹着分享口令、表情、前后缀）。</summary>
    public string Input { get; }
    /// <summary>归一化后的地址（真正拿去打开的）。</summary>
    public string Url { get; }
    /// <summary>
    /// 列表里显示的短标签。
    ///
    /// **优先用作者名**（2026-10-31）。原来是构造时算好的只读属性，
    /// 而 TargetLabel 只能从 URL 路径抠段 → 用户看到的是「作者 · MS4wLjABAAAA…」（抖音用户 ID），
    /// 完全认不出是谁。而名单导入时其实已经读到了作者名（Author）。
    ///
    /// 必须是**计算属性**：Author 是构造之后才赋值的，写在构造器里会拿到空串。
    /// </summary>
    public string Label => string.IsNullOrWhiteSpace(Author)
        ? DouyinUrl.TargetLabel(Url)
        : "作者 · " + Author;

    /// <summary>
    /// 作者名（从「插眼导出器」的 Markdown 名单里读出来的）。
    /// 只用于**按模板建文件夹**时的替换；手动一行一个链接粘进来时是空串。
    /// </summary>
    public string Author { get; set; } = "";

    public DouyinAutoStatus Status { get; set; } = DouyinAutoStatus.Waiting;
    /// <summary>收集到的作品数（一个图集算一条）。</summary>
    public int AwemeCount { get; set; }
    /// <summary>收集到的媒体条数（图集展开后，一个图集可能是好几张图）。</summary>
    public int MediaCount { get; set; }
    /// <summary>确认提交给 aria2 的媒体条数。</summary>
    public int Queued { get; set; }
    /// <summary>被「已下载」台账跳过的作品数。</summary>
    public int SkippedDownloaded { get; set; }
    /// <summary>轮数用尽了还没判定到底 —— 这个号的作品可能没翻完。必须让界面说出来。</summary>
    public bool Incomplete { get; set; }
    public string? Error { get; set; }

    public void Reset()
    {
        Status = DouyinAutoStatus.Waiting;
        AwemeCount = 0;
        MediaCount = 0;
        Queued = 0;
        SkippedDownloaded = 0;
        Incomplete = false;
        Error = null;
    }

    public void Fail(string message)
    {
        Status = DouyinAutoStatus.Failed;
        Error = message;
    }

    /// <summary>一行摘要，列表右侧显示。</summary>
    public string Summary => Status switch
    {
        DouyinAutoStatus.Waiting => "排队中",
        DouyinAutoStatus.Opening => "打开中…",
        DouyinAutoStatus.Collecting => "已抓到 " + AwemeCount + " 个作品",
        DouyinAutoStatus.Downloading => "提交 " + Queued + " / " + (MediaCount - SkippedDownloaded),
        DouyinAutoStatus.Done => BuildDoneSummary(),
        DouyinAutoStatus.Empty => SkippedDownloaded > 0
            ? "都是已下载的（跳过 " + SkippedDownloaded + " 个）"
            : "这个页面上没抓到作品",
        _ => Error ?? "失败",
    };

    private string BuildDoneSummary()
    {
        var parts = new List<string> { "下载 " + Queued + " 个" };
        if (SkippedDownloaded > 0) parts.Add("跳过 " + SkippedDownloaded + " 个已下载");
        if (Incomplete) parts.Add("轮数用尽，可能没翻完");
        return string.Join("，", parts);
    }
}

/// <summary>目标解析结果。</summary>
public sealed class DouyinTargetParse
{
    public List<DouyinAutoTask> Tasks { get; init; } = new();
    /// <summary>认不出来的原始行 —— 回显给用户，免得他以为写的东西生效了。</summary>
    public List<string> Rejected { get; init; } = new();
    public int Truncated { get; init; }
}

/// <summary>「自动下载」的状态（纯数据；执行循环在页面里，因为它要用 WebView）。</summary>
public sealed class DouyinAutoStore
{
    public static DouyinAutoStore Instance { get; } = new();

    /// <summary>
    /// **名单数量不再限制**（2026-10-30 用户要求：「名单数量限制取消了，不要限制」）。
    ///
    /// 原来这里是 200，超出部分会被静默丢弃（界面提示「超出上限丢弃 N 个」）。
    /// 保留这个常量只是为了不改方法签名，值取 int.MaxValue —— 实际等于不限制。
    /// </summary>
    public const int MaxTargets = int.MaxValue;
    /// <summary>「每个目标最多滚几轮」的档位（一轮 ≈ 700ms，一页约 17~20 条）。</summary>
    public static readonly int[] RoundChoices = { 5, 10, 15, 25, 40, 60, 100 };

    private string _rawText = "";

    /// <summary>
    /// 导入名单时的**文件名（不含扩展名）**，用作下载的顶层文件夹名。
    ///
    /// 用户 2026-10-29：「我导入文件下载的话，加一个功能，创建与文件名同名文件夹，
    /// 先那里面按照文件夹变量和文件名变量保存文件」——
    /// 即 downloads\&lt;名单文件名&gt;\&lt;文件夹模板&gt;\&lt;文件名模板&gt;。
    /// 空 = 不建这层（手贴名单、或用户关掉了这个开关）。
    /// </summary>
    public string ImportFolderName { get; private set; } = "";
    private DouyinTargetParse _parsed = new();

    public event Action? Changed;
    private void Notify() => Changed?.Invoke();

    public string RawText => _rawText;
    public List<DouyinAutoTask> Tasks => _parsed.Tasks;
    public List<string> Rejected => _parsed.Rejected;
    public int Truncated => _parsed.Truncated;
    public int Total => _parsed.Tasks.Count;
    public bool HasTargets => _parsed.Tasks.Count > 0;

    public bool Running { get; private set; }
    /// <summary>正在跑第几个（-1 = 还没开始）。</summary>
    public int CurrentIndex { get; private set; } = -1;
    public bool AutoDownload { get; private set; } = true;

    /// <summary>
    /// 是否在保存目录下**按导入的名单文件名建一层文件夹**（用户 2026-10-29 要求加开关）。
    ///
    /// 开（默认）：downloads\&lt;名单文件名&gt;\&lt;文件夹模板&gt;\&lt;文件名模板&gt;
    /// 关：downloads\&lt;文件夹模板&gt;\&lt;文件名模板&gt;（退回到没有这层时的行为）
    /// </summary>
    public bool FolderByName { get; private set; } = true;

    public DouyinAutoTask? Current =>
        CurrentIndex >= 0 && CurrentIndex < _parsed.Tasks.Count ? _parsed.Tasks[CurrentIndex] : null;

    public int SettledCount => _parsed.Tasks.Count(t => t.Status.IsSettled());
    public int FailedCount => _parsed.Tasks.Count(t => t.Status == DouyinAutoStatus.Failed);
    public int TotalAweme => _parsed.Tasks.Sum(t => t.AwemeCount);
    public int TotalQueued => _parsed.Tasks.Sum(t => t.Queued);
    public int TotalSkipped => _parsed.Tasks.Sum(t => t.SkippedDownloaded);
    public bool AllSettled => HasTargets && SettledCount == Total;

    // ── 持久化（任务队列）────────────────────────────────────

    public string FilePath => Path.Combine(AppPaths.DataDir, "douyin_auto_tasks.json");

    /// <summary>载入上次的名单与选项（切页面/重启都不丢）。</summary>
    public void Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return;
            var node = JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject;
            if (node is null) return;
            var text = node["rawText"]?.ToString() ?? "";
            if (node["autoDownload"] is JsonNode ad && bool.TryParse(ad.ToString(), out var b)) AutoDownload = b;
            if (node["importFolderName"] is JsonNode fn) ImportFolderName = SanitizeFolderName(fn.ToString());
            if (node["folderByName"] is JsonNode fb && bool.TryParse(fb.ToString(), out var fb2)) FolderByName = fb2;
            if (text.Length > 0) SetRawText(text, persist: false);
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[抖音自动] 读取名单失败：" + ex.Message);
        }
    }

    public void Save()
    {
        try
        {
            var dir = Path.GetDirectoryName(FilePath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var node = new JsonObject
            {
                ["rawText"] = _rawText,
                ["autoDownload"] = AutoDownload,
                ["importFolderName"] = ImportFolderName,
                ["folderByName"] = FolderByName,
            };
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[抖音自动] 保存名单失败：" + ex.Message);
        }
    }

    // ── 写 ──────────────────────────────────────────────────

    /// <summary>更新目标文本并重新解析。运行中不接受修改 —— 换掉列表会让下标错位。</summary>
    public void SetRawText(string v, bool persist = true)
    {
        if (Running || _rawText == v) return;
        _rawText = v;
        // **用户手贴名单（没有经过「导入名单」）→ 清掉上一次导入留下的文件夹名**（2026-10-30）
        // 实测：只粘一个链接，却沿用了上次导入的名单名，文件落进 downloads\收藏\ 里。
        // 「导入名单」那条路径会在 SetRawText 之后紧接着 SetImportFolderName(file.Name)，不受影响。
        if (persist && v.Trim().Length > 0) ImportFolderName = "";
        // **先认表格**（用户 2026-10-27：要能直接粘「插眼导出器」导出的 Markdown 名单）。
        // 名单里每行是 | 1 | 作者 | UID | ... | 主页链接 | ... |，整行不是链接，
        // 旧的「一行一个链接」解析会全部判非法。表格能认出来就走表格解析，
        // 认不出来再退回逐行链接解析（两种用法都保留）。
        _parsed = DouyinRoster.LooksLikeRoster(v)
            ? DouyinRoster.Parse(v, MaxTargets)
            : ParseTargets(v, MaxTargets);
        CurrentIndex = -1;
        if (persist) Save();
        Notify();
    }

    public void ClearText() => SetRawText("");

    /// <summary>
    /// 退出程序时清空目标名单与「按文件名建文件夹」那层名字（用户 2026-10-30 要求）。
    ///
    /// 不走 SetRawText / SetImportFolderName：它们都带 `if (Running) return` 或
    /// 变更判重，退出时正跑着就清不掉。这里直接改字段再落盘。
    /// </summary>
    public void ClearOnExit()
    {
        try
        {
            _rawText = "";
            _parsed = new DouyinTargetParse();
            ImportFolderName = "";
            CurrentIndex = -1;
            Save();
        }
        catch { }
    }

    /// <summary>设置「导入文件名」顶层文件夹（空串 = 不建这层）。</summary>
    /// <summary>开关「按文件名建文件夹」。</summary>
    public void SetFolderByName(bool v, bool persist = true)
    {
        if (FolderByName == v) return;
        FolderByName = v;
        if (persist) Save();
        Notify();
    }

    /// <summary>实际要用的顶层文件夹名（开关关掉时返回空 = 不建这层）。</summary>
    public string EffectiveRootFolder => FolderByName ? ImportFolderName : "";

    public void SetImportFolderName(string v, bool persist = true)
    {
        var name = SanitizeFolderName(v ?? "");
        if (ImportFolderName == name) return;
        ImportFolderName = name;
        if (persist) Save();
        Notify();
    }

    /// <summary>把文件名变成合法的单级目录名（去掉扩展名与非法字符）。</summary>
    public static string SanitizeFolderName(string fileName)
    {
        var s = (fileName ?? "").Trim();
        if (s.Length == 0) return "";
        // 去掉扩展名（.md / .txt / .markdown）
        var dot = s.LastIndexOf('.');
        if (dot > 0) s = s[..dot];
        foreach (var c in Path.GetInvalidFileNameChars()) s = s.Replace(c, '_');
        s = s.Trim().TrimEnd('.');
        return s.Length > 80 ? s[..80] : s;
    }

    public void SetAutoDownload(bool v, bool persist = true)
    {
        if (AutoDownload == v) return;
        AutoDownload = v;
        if (persist) Save();
        Notify();
    }

    /// <summary>开始跑批（列表为空时什么都不做）。</summary>
    public void Start()
    {
        if (Running || _parsed.Tasks.Count == 0) return;
        foreach (var t in _parsed.Tasks) t.Reset();
        CurrentIndex = 0;
        Running = true;
        Notify();
    }

    /// <summary>请求停止。当前这一轮会跑完（循环里会看到 Running == false 提前退出）。</summary>
    public void Stop()
    {
        if (!Running) return;
        Running = false;
        Notify();
    }

    public void Advance()
    {
        CurrentIndex++;
        Notify();
    }

    /// <summary>界面需要重画时调（跑批过程中每滚一轮都会调）。</summary>
    public void Refresh() => Notify();

    /// <summary>
    /// 从一段文本里解析出待处理的目标。**一行一个**。
    /// 支持的写法：作者主页 / 作品 / 短链 / 纯作品 ID / 分享口令（整段粘进来也能认）。
    /// 空行忽略；同一个地址只保留第一次出现的那个。
    /// </summary>
    public static DouyinTargetParse ParseTargets(string text, int maxTargets = MaxTargets)
    {
        var tasks = new List<DouyinAutoTask>();
        var rejected = new List<string>();
        var seen = new HashSet<string>();
        var truncated = 0;

        foreach (var line in (text ?? "").Split('\n'))
        {
            var raw = line.Trim().TrimEnd('\r');
            if (raw.Length == 0) continue;

            var url = DouyinUrl.Normalize(raw);
            if (url is null) { rejected.Add(raw); continue; }
            if (!seen.Add(url)) continue;
            // **不再限制名单数量**（2026-10-30 用户要求）
            tasks.Add(new DouyinAutoTask(raw, url));
        }

        return new DouyinTargetParse { Tasks = tasks, Rejected = rejected, Truncated = truncated };
    }
}

/// <summary>单个目标的收集器（跑批时每个目标一份干净的收集结果）。</summary>
public sealed class DouyinAutoCollector
{
    private readonly List<DouyinItem> _items = new();
    private readonly HashSet<string> _ids = new();
    private int _aweme;

    /// <summary>原始 aweme 条数（图集只算一条）。</summary>
    public int AwemeCount => _aweme;
    public int Count => _items.Count;
    public List<DouyinItem> Items => _items;

    public void NoteAweme(int n)
    {
        if (n > 0) _aweme += n;
    }

    /// <summary>并入一批媒体，返回真正新增的条数。</summary>
    public int Ingest(IEnumerable<DouyinItem> incoming)
    {
        var added = 0;
        foreach (var m in incoming)
            if (_ids.Add(m.Id)) { _items.Add(m); added++; }
        return added;
    }
}
