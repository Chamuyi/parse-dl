using System;
using System.Collections.Generic;
using System.Linq;

namespace ParseDl.Services.X;

/// <summary>
/// X 主页的状态机 —— 从 Flutter 版 lib/services/homepage_store.dart 移植。
///
/// 为什么单独一个类：分页与去重的规则不是 UI 的职责，而「什么时候算翻到底」
/// 这件事在 Flutter 版线上踩过坑（游标每页都在变，只看 cursor==null 停不下来）。
/// 抽出来才能离线自测，也避免状态散在页面代码里。
/// </summary>
public sealed class XHomeStore
{
    /// <summary>
    /// **进程级单例**（2026-10-28 改）：
    /// 原来每个 XHomePage 实例都 new 一个自己的 store，切到别的页面再回来，
    /// 页面被重新构造 → store 也是新的 → **已加载的作品、勾选状态全没了**，
    /// 用户得重新输入用户名重新加载。用户明确要求「从主页点到其他页面返回，
    /// 这页就被重置了，不能这样」。
    ///
    /// 改成单例后，状态在进程存活期间一直保留，与「自动执行」页的 AutoTaskStore 一致，
    /// 也符合原项目 Flutter 版的行为（HomepageStore 是全局单例）。
    /// </summary>
    public static XHomeStore Instance { get; } = new();

    /// <summary>连续几页解析不出媒体就认定到底（X 末尾之后每页只回一个还在变的游标）。</summary>
    public const int EmptyPageStopAfter = 2;

    private readonly List<XPost> _posts = new();
    private readonly HashSet<string> _selected = new();
    private int _emptyStreak;

    public XHomeUser? User { get; private set; }
    public IReadOnlyList<XPost> Posts => _posts;
    public string? NextCursor { get; private set; }
    public bool LoadingMore { get; set; }
    public bool HasLoadedOnce { get; private set; }

    public int TotalMedia => _posts.Sum(p => p.Media.Count);
    public IReadOnlyCollection<string> SelectedIds => _selected;
    public int SelectedCount => _selected.Count;

    /// <summary>
    /// 还能不能再拉一页。
    ///
    /// **首次加载前必须为 true**：若写成 NextCursor != null，就会出现
    /// 「UI 等 hasMore 才发起首次请求、而首次请求前它必然为 null」的死锁
    /// —— 表现是搜到用户后列表永远空白（Flutter 版原注释记的就是这个坑）。
    /// </summary>
    public bool HasMore => !HasLoadedOnce || NextCursor is not null;

    /// <summary>清空作品列表与选择（保留用户）。</summary>
    public void Clear()
    {
        _posts.Clear();
        _selected.Clear();
        NextCursor = null;
        _emptyStreak = 0;
        HasLoadedOnce = false;
    }

    /// <summary>换用户：先清状态再设用户。</summary>
    public void SetUser(XHomeUser user)
    {
        Clear();
        User = user;
    }

    /// <summary>追加一页。requestedCursor 是本次请求带出去的游标（判「原地打转」用）。</summary>
    public void Append(XTimelinePage page, string? requestedCursor)
    {
        var seen = new HashSet<string>(_posts.Select(p => p.Id));
        foreach (var p in page.Posts)
        {
            if (p.Media.Count == 0) continue;   // 纯文字推文没有可下载内容
            if (seen.Add(p.Id)) _posts.Add(p);
        }

        var more = PageHasMore(requestedCursor, page, _emptyStreak);
        _emptyStreak = page.Posts.Count == 0 ? _emptyStreak + 1 : 0;
        NextCursor = more ? page.NextCursor : null;
        HasLoadedOnce = true;
    }

    public bool IsSelected(string postId) => _selected.Contains(postId);

    public void Toggle(string postId)
    {
        if (!_selected.Remove(postId)) _selected.Add(postId);
    }

    public void ClearSelection() => _selected.Clear();

    public void SelectAll()
    {
        _selected.Clear();
        foreach (var p in _posts) _selected.Add(p.Id);
    }

    /// <summary>要下载的作品：有勾选就只下勾中的，没勾选就是全部（与 Flutter 版同口径）。</summary>
    public List<XPost> PostsForDownload()
        => _selected.Count == 0 ? _posts.ToList() : _posts.Where(p => _selected.Contains(p.Id)).ToList();

    /// <summary>
    /// 读完这一页之后还要不要继续翻页。
    ///
    /// 三条停止条件都要留（Flutter 版线上实测各覆盖一种情况）：
    ///   1. 服务端没给游标；
    ///   2. 游标与本次请求携带的完全相同 —— 服务端在原地打转；
    ///   3. 连续 EmptyPageStopAfter 页 0 条媒体 —— 已经到底
    ///      （游标每页都在变，光靠第 2 条拦不住）。
    ///
    /// emptyPagesBefore 传「这一页之前已连续空了几页」。
    /// </summary>
    public static bool PageHasMore(string? requestedCursor, XTimelinePage page, int emptyPagesBefore)
    {
        var next = page.NextCursor;
        if (string.IsNullOrEmpty(next)) return false;
        if (next == requestedCursor) return false;
        if (page.Posts.Count == 0 && emptyPagesBefore + 1 >= EmptyPageStopAfter) return false;
        return true;
    }
}
