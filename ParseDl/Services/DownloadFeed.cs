using System;
using System.Collections.Generic;
using System.Linq;

namespace ParseDl.Services;

/// <summary>下载管理归属的模块。</summary>
public enum DownloadModuleKind
{
    X,
    Douyin,
    Bili,
}

/// <summary>
/// 下载管理里的一个状态 Tab。
/// <see cref="Status"/> 为 null 表示「全部」，不做状态过滤。
/// </summary>
public sealed class DownloadTabSpec
{
    public string Title { get; init; } = "";

    /// <summary>主状态。null = 不按状态过滤（旧「全部」Tab 用）。</summary>
    public AriaStatus? Status { get; init; }

    /// <summary>
    /// **额外归入本 Tab 的状态**（2026-10-28）。
    /// 用户要求「只要下载中 / 错误 / 已完成」三个 Tab，但等待中和已暂停的任务
    /// 不能就此消失 —— 它们都是「还没下完」，跟下载中放一起才符合直觉。
    /// </summary>
    public AriaStatus[] AlsoStatuses { get; init; } = Array.Empty<AriaStatus>();

    /// <summary>这条任务的状态是否落在本 Tab 里。</summary>
    public bool AcceptsStatus(AriaStatus s)
        => Status is null || s == Status || Array.IndexOf(AlsoStatuses, s) >= 0;
}

/// <summary>
/// 一套下载 feed —— 三个模块（X / 抖音 / B 站）各一份。
///
/// 为什么要有这层：以前 DownloadsPage 只认一个 `module` 字符串，靠
/// `i.Module == _module` 过滤，于是三个模块的下载管理长得一模一样，
/// 连「合并音视频」「清空历史台账」这种只属于某个模块 / 属于全局的按钮
/// 也长在了每一页上。把「这个模块有哪些 Tab、空态说什么、有没有合并入口、
/// 历史台账叫什么」收进 feed 之后，页面只剩渲染，加第四个模块只加一份 feed。
///
/// 判据拆成多条而不是一个 `IsXxx` 开关：X / 抖音 / B 站 在
/// 「有没有合并入口」「历史台账叫什么」「空态说什么」三件事上互不相关，
/// 用一个布尔同时表达三件事，加第三个模块时必然串味（Flutter 版为此留了
/// 一整段注释说明 `!isDouyin` 怎么碎的）。
/// </summary>
public sealed class DownloadFeed
{
    public DownloadModuleKind Kind { get; init; }

    /// <summary>页头副题（三个模块各一句）。</summary>
    public string Subtitle { get; init; } = "";

    /// <summary>
    /// 匹配 <see cref="DownloadItem.Module"/> 的键集合。
    /// B 站的音频轨单独记成「B 站（音频）」（dash 是分离流），
    /// 所以 B 站模式要认两个键，否则用户永远看不到音频任务下到哪了。
    /// </summary>
    public IReadOnlyList<string> ModuleKeys { get; init; } = Array.Empty<string>();

    /// <summary>队列为空时的引导语 —— 三个模块的入口页名不一样，各一份。</summary>
    public string EmptyHint { get; init; } = "";

    /// <summary>历史台账卡片标题。</summary>
    public string HistoryTitle { get; init; } = "";

    /// <summary>历史台账为空时的说明。</summary>
    public string HistoryEmptyHint { get; init; } = "暂无历史记录。任务完成后会自动记入台账。";

    /// <summary>
    /// 有没有「合并音视频」入口。
    /// **只有 B 站有**：它的 dash 格式把视频与音频分成两个文件下下来，
    /// 不合就是一个只有画面没声音的 mp4。X 与抖音拿到的是合流文件，画这个按钮
    /// 等于给用户一个点了会说「没有找到可合并的配对」的死按钮。
    /// </summary>
    public bool SupportsMerge { get; init; }

    /// <summary>本模块的 Tab 定义。</summary>
    public IReadOnlyList<DownloadTabSpec> Tabs { get; init; } = DefaultTabs;

    /// <summary>
    /// 六个状态 Tab：全部 / 下载中 / 等待中 / 已暂停 / 错误 / 已完成。
    ///
    /// **六个都要在界面上出现，计数为 0 也显示**：以前按「有任务才画」，
    /// 结果计数为 0 的 Tab 直接消失，用户看不出那是一排 Tab，
    /// 只看到一两个孤立按钮（「下载中」「错误」不可见就是这么来的）。
    /// </summary>
    public static readonly IReadOnlyList<DownloadTabSpec> DefaultTabs = new[]
    {
        // 等待中 / 已暂停 都归到「下载中」—— 它们都是「还没下完」，
        // 原项目也是把 waiting 与 active 一起放在同一个 Tab 里。
        new DownloadTabSpec
        {
            Title = "下载中",
            Status = AriaStatus.Active,
            AlsoStatuses = new[] { AriaStatus.Waiting, AriaStatus.Paused },
        },
        new DownloadTabSpec { Title = "错误", Status = AriaStatus.Error },
        new DownloadTabSpec { Title = "已完成", Status = AriaStatus.Complete },
    };

    /// <summary>这条任务是否属于本模块。</summary>
    public bool Matches(DownloadItem item) =>
        item is not null && ModuleKeys.Contains(item.Module);

    /// <summary>这条任务在给定 Tab 下是否可见（模块 + 状态双过滤）。</summary>
    public bool Accepts(DownloadItem item, DownloadTabSpec tab) =>
        Matches(item) && tab.AcceptsStatus(item.Status);

    /// <summary>取本模块在给定 Tab 下的任务（保持队列原顺序：新的在前）。</summary>
    public List<DownloadItem> ItemsFor(DownloadTabSpec tab) =>
        DownloadStore.Instance.Items.Where(i => Accepts(i, tab)).ToList();

    /// <summary>取本模块的全部任务（不分状态）。</summary>
    public List<DownloadItem> AllItems() =>
        DownloadStore.Instance.Items.Where(Matches).ToList();

    /// <summary>取本模块在给定状态下的任务数（给 Tab 计数用）。</summary>
    public int CountFor(DownloadTabSpec tab) =>
        DownloadStore.Instance.Items.Count(i => Accepts(i, tab));

    /// <summary>
    /// 本模块的历史台账（最近在前）。
    /// B 站要把「B 站」与「B 站（音频）」两条键合并后再按时间倒序 ——
    /// 分开取再拼接会让音频轨全挤在末尾，看起来像另一段时间的记录。
    /// </summary>
    public List<DownloadLedger.LedgerEntry> History(int limit = 60)
    {
        if (ModuleKeys.Count == 0) return new List<DownloadLedger.LedgerEntry>();
        var merged = new List<DownloadLedger.LedgerEntry>();
        foreach (var key in ModuleKeys)
            merged.AddRange(DownloadLedger.Instance.Query(key, limit));
        return merged
            .OrderByDescending(e => e.FinishedAt, StringComparer.Ordinal)
            .Take(limit)
            .ToList();
    }

    /// <summary>按模块枚举取 feed。</summary>
    public static DownloadFeed For(DownloadModuleKind kind) => kind switch
    {
        DownloadModuleKind.Douyin => Douyin,
        DownloadModuleKind.Bili => Bili,
        _ => X,
    };

    /// <summary>
    /// 从导航参数解析 feed。兼容三种写法：
    /// 老路由传的中文模块名（「X 媒体」/「抖音」/「B 站」）、
    /// 新路由传的短键（"x" / "douyin" / "bili"）、以及枚举本身。
    /// 认不出来一律落到 X —— 宁可显示 X 的页面，也不要空白页。
    /// </summary>
    public static DownloadFeed FromParameter(object? parameter)
    {
        switch (parameter)
        {
            case DownloadModuleKind kind:
                return For(kind);
            case DownloadFeed feed:
                return feed;
            case string s:
                var v = (s ?? "").Trim();
                if (v.Length == 0) return X;
                if (v.Equals("douyin", StringComparison.OrdinalIgnoreCase) ||
                    v.Equals("抖音", StringComparison.Ordinal)) return Douyin;
                if (v.Equals("bili", StringComparison.OrdinalIgnoreCase) ||
                    v.StartsWith("B 站", StringComparison.Ordinal) ||
                    v.StartsWith("B站", StringComparison.Ordinal)) return Bili;
                return X;
            default:
                return X;
        }
    }

    /// <summary>X 下载：合流文件、无合并入口。</summary>
    public static readonly DownloadFeed X = new()
    {
        Kind = DownloadModuleKind.X,
        Subtitle = "X 媒体",
        ModuleKeys = new[] { "X 媒体" },
        EmptyHint = "在主页或自动执行页选择媒体后，任务会出现在这里。",
        HistoryTitle = "下载历史（X 媒体）",
        HistoryEmptyHint = "暂无历史记录。X 的媒体任务完成后会自动记入台账。",
        SupportsMerge = false,
    };

    /// <summary>抖音：合流文件、无合并入口。</summary>
    public static readonly DownloadFeed Douyin = new()
    {
        Kind = DownloadModuleKind.Douyin,
        Subtitle = "抖音",
        ModuleKeys = new[] { "抖音" },
        EmptyHint = "在解析下载页或自动下载页勾选作品后，任务会出现在这里。",
        HistoryTitle = "下载历史（抖音）",
        HistoryEmptyHint = "暂无历史记录。抖音的作品下载完成后会自动记入台账。",
        SupportsMerge = false,
    };

    /// <summary>B 站：dash 分离流，下完要合并；音频轨单独一个 module 键。</summary>
    public static readonly DownloadFeed Bili = new()
    {
        Kind = DownloadModuleKind.Bili,
        Subtitle = "B 站",
        ModuleKeys = new[] { "B 站", "B 站（音频）" },
        EmptyHint = "在 B 站解析下载页勾选分P后，任务会出现在这里。",
        HistoryTitle = "下载历史（B 站）",
        HistoryEmptyHint = "暂无历史记录。B 站的分P下载完成后会自动记入台账。",
        SupportsMerge = true,
    };
}
