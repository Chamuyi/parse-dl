using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using ParseDl.Services.X;

namespace ParseDl.Services;

/// <summary>自动执行里一行（一个用户 ID）的执行状态。</summary>
public enum AutoTaskStatus { Pending, Loading, Done, Fail }

/// <summary>自动执行任务表里的一行。</summary>
public sealed class AutoTaskItem
{
    public string Key { get; set; } = "";
    public string Id { get; set; } = "";
    public AutoTaskStatus Status { get; set; } = AutoTaskStatus.Pending;
    public string? Message { get; set; }
}

/// <summary>一条「历史名单」预设。</summary>
public sealed class AutoTaskPreset
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Content { get; set; } = "";
    public DateTime CreatedAt { get; set; } = DateTime.Now;

    /// <summary>有效行数（空行不算）。</summary>
    [JsonIgnore]
    public int LineCount => Content
        .Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.RemoveEmptyEntries)
        .Count(l => l.Trim().Length > 0);
}

/// <summary>名单解析结果。</summary>
public sealed record ParseResult(IReadOnlyList<string> Ids, int Skipped);

/// <summary>
/// 自动执行页的状态与跑批逻辑 —— 对齐 Flutter 版 lib/services/auto_task_store.dart。
///
/// 职责边界（与原项目一致）：这里只负责「逐个用户 ID → 加载用户 → 按下载配置筛选媒体 →
/// 入队下载」，**不做真实下载**（那是 DownloadStore / aria2 的事）。
/// 所以一行的状态会很快变成「已创建任务」，真正的下载进度到【下载管理】看。
///
/// 持久化：名单文本、执行设置、历史名单都落盘到 &lt;数据目录&gt;\autotask.json。
/// </summary>
public sealed class AutoTaskStore
{
    public static AutoTaskStore Instance { get; } = new();

    private const string ModuleName = "X 媒体";

    // ── 输入 ────────────────────────────────────────────────
    public string RawText { get; private set; } = "";
    public string FileName { get; private set; } = "";
    public int IntervalSec { get; private set; } = 3;
    public int TimeoutSec { get; private set; } = 120;
    public bool SkipOnError { get; private set; } = true;

    // ── 历史名单 ─────────────────────────────────────────────
    private readonly List<AutoTaskPreset> _presets = new();
    public IReadOnlyList<AutoTaskPreset> Presets => _presets;
    public string? ActivePresetId { get; private set; }

    // ── 执行态 ───────────────────────────────────────────────
    private readonly List<AutoTaskItem> _items = new();
    public IReadOnlyList<AutoTaskItem> Items => _items;
    public bool Running { get; private set; }
    public bool Paused { get; private set; }

    private bool _stopFlag;
    private bool _pauseFlag;

    /// <summary>状态有任何变化就触发（页面据此重绘，不靠轮询）。</summary>
    public event Action? Changed;

    private void Raise() => Changed?.Invoke();

    // ── 构造：读盘 ───────────────────────────────────────────

    private AutoTaskStore() { Load(); }

    private static string FilePath => Path.Combine(AppPaths.DataDir, "autotask.json");

    private sealed class Persisted
    {
        public string RawText { get; set; } = "";
        public string FileName { get; set; } = "";
        public int IntervalSec { get; set; } = 3;
        public int TimeoutSec { get; set; } = 120;
        public bool SkipOnError { get; set; } = true;
        public List<AutoTaskPreset> Presets { get; set; } = new();
    }

    private void Load()
    {
        if (!File.Exists(FilePath)) return;

        try
        {
            var text = File.ReadAllText(FilePath);
            using var doc = JsonDocument.Parse(text);

            // 旧格式是 { "x": "名单文本" }（纯字符串字典）—— 直接反序列化成新结构会
            // 「成功但全默认」，名单静默消失。所以先看顶层有没有本结构才有的字段。
            var isNewFormat = doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.EnumerateObject().Any(pr => pr.Name == nameof(Persisted.RawText));

            if (isNewFormat)
            {
                var p = JsonSerializer.Deserialize<Persisted>(text);
                if (p is not null)
                {
                    RawText = p.RawText ?? "";
                    FileName = p.FileName ?? "";
                    IntervalSec = Math.Clamp(p.IntervalSec, 0, 600);
                    TimeoutSec = Math.Clamp(p.TimeoutSec, 10, 1800);
                    SkipOnError = p.SkipOnError;
                    _presets.Clear();
                    _presets.AddRange(p.Presets ?? new List<AutoTaskPreset>());
                    return;
                }
            }

            if (doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.TryGetProperty("x", out var legacy))
            {
                RawText = legacy.GetString() ?? "";
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine("[AutoTask] 读盘失败，使用默认值: " + ex.Message);
        }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(AppPaths.DataDir);
            var p = new Persisted
            {
                RawText = RawText,
                FileName = FileName,
                IntervalSec = IntervalSec,
                TimeoutSec = TimeoutSec,
                SkipOnError = SkipOnError,
                Presets = _presets.ToList(),
            };
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(p, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine("[AutoTask] 写盘失败: " + ex.Message);
        }
    }

    // ── 输入设置 ─────────────────────────────────────────────

    /// <summary>
    /// 改名单文本。**不落盘**（每次按键写文件没必要，原项目 rawText 本来也不持久化）；
    /// 由 <see cref="SaveInput"/> 在离开页面 / 开始执行时统一落盘。
    /// </summary>
    public void SetRawText(string v)
    {
        RawText = v ?? "";
        if (FileName.Length > 0) FileName = "";   // 手改内容后文件名不再是它的来源
        SaveThrottled();
        Raise();
    }

    /// <summary>把当前输入与执行设置落盘。</summary>
    public void SaveInput() => Save();

    /// <summary>
    /// 节流写盘：按键每 2 秒最多写一次（既不会每按一个字符都落盘，
    /// 也不会因为没触发「离开页面」就丢掉用户刚粘进去的名单）。
    /// </summary>
    private DateTime _lastSave = DateTime.MinValue;

    private void SaveThrottled()
    {
        var now = DateTime.Now;
        if ((now - _lastSave).TotalSeconds < 2) return;
        _lastSave = now;
        Save();
    }

    public void SetFileName(string v) { FileName = v ?? ""; Save(); Raise(); }

    public void SetIntervalSec(int v) { IntervalSec = Math.Clamp(v, 0, 600); Save(); Raise(); }

    public void SetTimeoutSec(int v) { TimeoutSec = Math.Clamp(v, 10, 1800); Save(); Raise(); }

    public void SetSkipOnError(bool v) { SkipOnError = v; Save(); Raise(); }

    public ParseResult Parsed => ParseIds(RawText);

    // ── 历史名单 ─────────────────────────────────────────────

    public (bool Ok, AutoTaskPreset? Entry) SaveAsPreset(string name)
    {
        if (RawText.Trim().Length == 0) return (false, null);
        var entry = new AutoTaskPreset
        {
            Id = DateTime.Now.Ticks.ToString(),
            Name = name.Trim().Length == 0 ? "名单 " + DateTime.Now.ToString("HH:mm") : name.Trim(),
            Content = RawText,
            CreatedAt = DateTime.Now,
        };
        _presets.Insert(0, entry);
        ActivePresetId = entry.Id;
        Save();
        Raise();
        return (true, entry);
    }

    public void LoadPreset(string id)
    {
        var e = _presets.FirstOrDefault(x => x.Id == id);
        if (e is null) return;
        RawText = e.Content;
        FileName = "";
        ActivePresetId = e.Id;
        Save();
        Raise();
    }

    public void DeletePreset(string id)
    {
        _presets.RemoveAll(x => x.Id == id);
        if (ActivePresetId == id) ActivePresetId = null;
        Save();
        Raise();
    }

    public void RenamePreset(string id, string newName)
    {
        var e = _presets.FirstOrDefault(x => x.Id == id);
        if (e is null || newName.Trim().Length == 0) return;
        e.Name = newName.Trim();
        Save();
        Raise();
    }

    // ── 执行 ────────────────────────────────────────────────

    /// <summary>是否已登录 X（账号分区的 auth_token + ct0 都在才算）。</summary>
    public static bool HasLogin =>
        new XHomeApi(AppSettings.Instance.ForModule("x").EffectiveCookie).HasLogin;

    /// <summary>开始跑批。返回错误文案；正常开始返回 null（执行在后台继续）。</summary>
    public async Task<string?> StartAsync()
    {
        var ids = Parsed.Ids;
        if (ids.Count == 0) return "请先选择名单文件或粘贴用户 ID";
        if (!HasLogin) return "请先登录 X 账号";

        _items.Clear();
        for (var i = 0; i < ids.Count; i++)
            _items.Add(new AutoTaskItem { Key = i + "-" + ids[i], Id = ids[i] });

        Running = true;
        Paused = false;
        _stopFlag = false;
        _pauseFlag = false;
        SaveInput();
        Raise();

        await Task.Yield();
        _ = RunLoopAsync(ids.ToList());
        return null;
    }

    public void TogglePause()
    {
        if (!Running) return;
        _pauseFlag = !_pauseFlag;
        Paused = _pauseFlag;
        Raise();
    }

    public void Stop()
    {
        if (!Running) return;
        _stopFlag = true;
        _pauseFlag = false;
        Paused = false;
        Raise();
    }

    /// <summary>清空任务表（运行中不允许，避免 UI 与状态错位）。</summary>
    public void ClearItems()
    {
        if (Running) return;
        _items.Clear();
        Raise();
    }

    private async Task RunLoopAsync(List<string> ids)
    {
        var settings = AppSettings.Instance.ForModule("x");
        var api = new XHomeApi(settings.EffectiveCookie);
        var filter = BuildFilter(settings);

        for (var i = 0; i < ids.Count; i++)
        {
            if (_stopFlag) break;

            while (_pauseFlag && !_stopFlag) await Task.Delay(300);
            if (_stopFlag) break;

            Patch(i, AutoTaskStatus.Loading, null);

            try
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(TimeoutSec));
                var user = await api.GetUserAsync(ids[i], cts.Token);
                if (string.IsNullOrEmpty(user.Id))
                    throw new InvalidOperationException("未获取到用户信息");

                var summary = await QueueUserAsync(api, user, filter, settings, cts.Token);
                Patch(i, AutoTaskStatus.Done, summary);
            }
            catch (OperationCanceledException)
            {
                Patch(i, AutoTaskStatus.Fail, "加载超时（" + TimeoutSec + "s）");
                if (!SkipOnError) break;
            }
            catch (Exception ex)
            {
                Patch(i, AutoTaskStatus.Fail, XHomeApi.MapError(ex));
                if (!SkipOnError) break;
            }

            if (i < ids.Count - 1 && !_stopFlag && IntervalSec > 0)
                await Task.Delay(TimeSpan.FromSeconds(IntervalSec));
        }

        Running = false;
        Paused = false;
        _pauseFlag = false;
        Raise();
    }

    /// <summary>下载配置快照（页面改动只影响之后开始的任务，与 Flutter 版一致）。</summary>
    private sealed class FilterSnapshot
    {
        public HashSet<string> MediaTypes { get; init; } = new();
        public DateTime? From { get; init; }
        public DateTime? To { get; init; }
    }

    private static FilterSnapshot BuildFilter(ModuleSettings s)
    {
        var types = (s.MediaTypeFilter ?? "")
            .Split((char)44, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim().ToLowerInvariant())
            .Where(x => x.Length > 0)
            .ToHashSet();

        DateTime? from = null, to = null;
        if (s.TimeRangeEnabled)
        {
            if (DateTime.TryParse(s.DateFrom, out var f)) from = f.Date;
            if (DateTime.TryParse(s.DateTo, out var t)) to = t.Date.AddDays(1).AddSeconds(-1);
        }
        return new FilterSnapshot { MediaTypes = types, From = from, To = to };
    }

    /// <summary>把一个用户的作品按下载配置筛出来并入队，返回一行摘要。</summary>
    private static async Task<string> QueueUserAsync(
        XHomeApi api, XHomeUser user, FilterSnapshot filter, ModuleSettings settings, CancellationToken ct)
    {
        // 下载源：media 源只拉一页（快）；tweets 源多翻几页（能到更早，慢）。
        // 两种源当前都走 UserMedia 接口 —— 帖子源专用 timeline 端点尚未接入，
        // 差别只体现在翻页深度上（这一点在页面「下载源」说明里如实标注）。
        var maxPages = settings.Source == "tweets" ? 5 : 1;

        var posts = new List<XPost>();
        string? cursor = null;
        for (var page = 0; page < maxPages; page++)
        {
            var p = await api.GetMediasAsync(user.Id!, cursor, 20, ct);
            posts.AddRange(p.Posts);
            cursor = p.NextCursor;
            if (string.IsNullOrEmpty(cursor)) break;

            var oldest = p.Posts.Where(x => x.CreatedAt is not null)
                .Select(x => x.CreatedAt!.Value).DefaultIfEmpty(DateTime.MinValue).Min();
            if (filter.From is not null && oldest != DateTime.MinValue && oldest <= filter.From) break;
        }

        // **每个作品单独算目录**（2026-10-29 修）。
        //
        // 原来这里是：var dir = string.IsNullOrWhiteSpace(settings.SaveDir) ? null : settings.SaveDir;
        // 也就是整批共用一个目录，DirTemplate 根本没被使用 ——
        // 表现就是 X 下载不在 downloads 下建 @用户名 子目录，文件全平铺在根目录。
        // 而 XNaming.DirFor 早就实现了（解析模板 + 建多级目录），只是这里没调用。
        var downloaded = settings.SkipDownloaded ? BuildDownloadedSet() : new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        int queued = 0, skipped = 0, filtered = 0, failed = 0;

        foreach (var post in posts)
        {
            for (var i = 0; i < post.Media.Count; i++)
            {
                var m = post.Media[i];
                if (filter.MediaTypes.Count > 0 && !filter.MediaTypes.Contains(m.Type)) { filtered++; continue; }
                if (filter.From is not null && post.CreatedAt is not null && post.CreatedAt.Value < filter.From) { filtered++; continue; }
                if (filter.To is not null && post.CreatedAt is not null && post.CreatedAt.Value > filter.To) { filtered++; continue; }
                if (downloaded.Contains(m.Url)) { skipped++; continue; }

                var name = NameFor(post, i);
                var dir = ParseDl.Services.X.XNaming.DirFor(post, i);
                var (ok, _) = await DownloadStore.Instance.AddAsync(m.Url, ModuleName, dir, name);
                if (ok) { queued++; downloaded.Add(m.Url); }
                else failed++;
            }
        }

        var parts = new List<string> { "已加入 " + queued + " 个" };
        if (skipped > 0) parts.Add("跳过 " + skipped + " 个已下载");
        if (filtered > 0) parts.Add("过滤 " + filtered + " 个");
        if (failed > 0) parts.Add(failed + " 个失败");
        return string.Join("，", parts);
    }

    /// <summary>
    /// 已下载集合：台账里「已完成」的 URL + 当前队列里的 URL
    /// （与 XHomePage.BuildDownloadedSet 同一口径）。
    /// </summary>
    private static HashSet<string> BuildDownloadedSet()
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var e in DownloadLedger.Instance.Query(ModuleName, 2000))
                if (e.Status == "已完成" && !string.IsNullOrEmpty(e.Url)) set.Add(e.Url);
        }
        catch { }
        try
        {
            foreach (var it in DownloadStore.Instance.Items)
                if (!string.IsNullOrEmpty(it.Url)) set.Add(it.Url);
        }
        catch { }
        return set;
    }

    /// <summary>文件名生成 —— 与 XHomePage.XNameFor 同一实现（X 下载设置里的模板）。</summary>
    private static string NameFor(XPost p, int mediaIndex)
    {
        var m = p.Media[mediaIndex];
        var settings = AppSettings.Instance.ForModule("x");
        var tpl = string.IsNullOrWhiteSpace(settings.FileNameTemplate)
            ? "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%"
            : settings.FileNameTemplate;

        var ext = m.Type is "video" or "gif" ? "mp4" : "jpg";
        var ctx = new TemplateContext
        {
            PostId = p.Id,
            PostTime = p.CreatedAt,
            UserId = p.UserId,
            UserName = p.UserName,
            UserScreenName = p.UserScreenName,
            MediaId = m.Id,
            MediaIndex = mediaIndex + 1,
            MediaCount = p.Media.Count,
            MediaWidth = m.Width,
            MediaHeight = m.Height,
            MediaType = m.Type,
            Extension = ext,
            Content = p.Text,
        };

        var name = FileNameTemplate.UnicodeFilenamify(FileNameTemplate.Resolve(tpl, ctx));
        if (string.IsNullOrWhiteSpace(name)) name = p.Id + "_" + (mediaIndex + 1);
        var dotExt = "." + ext;
        if (!name.EndsWith(dotExt, StringComparison.OrdinalIgnoreCase)) name += dotExt;
        return name;
    }

    private void Patch(int index, AutoTaskStatus status, string? message)
    {
        if (index < 0 || index >= _items.Count) return;
        _items[index].Status = status;
        _items[index].Message = message;
        Raise();
    }

    // ── 名单解析（与 Flutter 版 parseIds 逐条一致）─────────────

    /// <summary>
    /// 兼容：纯 ID / @ID / 主页链接 / 带行号；忽略空行与 # 注释；自动去重（不区分大小写）。
    /// </summary>
    public static ParseResult ParseIds(string? text)
    {
        var ids = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var skipped = 0;

        var cleaned = (text ?? "").TrimStart('﻿');
        foreach (var rawLine in cleaned.Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.None))
        {
            var s = rawLine.Trim();
            if (s.Length == 0 || s.StartsWith("#")) continue;

            s = Regex.Replace(s, @"^\d+[\.\u3001)\]]\s*", "");
            s = Regex.Replace(s, @"^https?://(?:www\.)?(?:x|twitter)\.com/", "", RegexOptions.IgnoreCase);
            s = s.Split('?')[0].Split('#')[0];
            s = Regex.Replace(s, @"/+$", "");
            s = s.Split('/')[0];
            s = Regex.Replace(s, "^@", "").Trim();

            if (!Regex.IsMatch(s, "^[A-Za-z0-9_]{1,25}$")) { skipped++; continue; }
            if (!seen.Add(s)) continue;
            ids.Add(s);
        }

        return new ParseResult(ids, skipped);
    }
}
