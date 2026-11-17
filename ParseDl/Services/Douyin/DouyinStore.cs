using System;
using System.Collections.Generic;
using System.Linq;

namespace ParseDl.Services.Douyin;

/// <summary>组装结果：可下载列表 + 两类跳过计数。</summary>
public sealed class DouyinAssembleResult
{
    public List<DouyinItem> Items { get; init; } = new();
    public int SkippedDownloaded { get; init; }
    public int SkippedDuration { get; init; }

    public static DouyinAssembleResult Empty => new();

    /// <summary>这批涉及的作品 id（下载完成后写台账用）。</summary>
    public HashSet<string> AwemeIds =>
        new(Items.Where(m => !string.IsNullOrEmpty(m.PostId)).Select(m => m.PostId));
}

/// <summary>一个页面（URL 归一化后的分组）的抓取结果。</summary>
public sealed class DouyinPageBucket
{
    public string Key { get; }
    public string Url { get; set; }
    /// <summary>「最近使用」的单调序号（越大越新）—— 用序号而不是时间戳，避免撞刻度。</summary>
    public int TouchSeq { get; set; }
    public List<DouyinItem> Items { get; } = new();
    public HashSet<string> Ids { get; } = new();
    public HashSet<string> Selected { get; } = new();
    public int Dropped { get; set; }

    public DouyinPageBucket(string key, string url)
    {
        Key = key;
        Url = url;
    }

    public int Count => Items.Count;
}

/// <summary>
/// 抖音页的抓取结果仓库 —— 对齐 Flutter 版 lib/services/douyin_store.dart。
///
/// 为什么提到 app 级单例而不是放在页面字段里：导航是「按路由重建页面」，
/// 切到「下载管理」再切回来页面会重新构造；结果放页面里用户刚捞到的一批就没了。
/// 按页面 key 分桶，界面只显示当前页那一桶，其它页留着可以切回去看。
///
/// 职责边界：这里只管「有哪些媒体 / 选了哪些 / 怎么筛」，不碰下载。
/// </summary>
public sealed class DouyinStore
{
    public static DouyinStore Instance { get; } = new();

    /// <summary>
    /// **不再有结果条数上限**（2026-10-31 用户明确要求「不要上限」）。
    ///
    /// 原来是 1000（移植自 Flutter 版 kMaxItems），Ingest 超过就从头部丢最旧的。
    /// 实测代价：收藏页 198 个作品 = 1666 条媒体，只能留住 1000 条，
    /// 界面直接显示「超出上限已丢弃 666 条」—— 用户根本下不全；
    /// 而且丢弃时会顺手 Selected.Remove，先全选再继续滚，前面选的会被悄悄取消。
    /// 列表本身是 GridView + ItemsWrapGrid（虚拟化，只构建可见项），
    /// 保留全部结果不会把控件全建出来。
    /// </summary>

    /// <summary>结果分组的页面数上限（超出时淘汰最久没用过的）。</summary>
    public const int MaxPages = 20;

    private readonly Dictionary<string, DouyinPageBucket> _buckets = new()
    {
        [DouyinUrl.HomeKey] = new DouyinPageBucket(DouyinUrl.HomeKey, DouyinUrl.HomeUrl),
    };
    private string _currentKey = DouyinUrl.HomeKey;
    private int _touchSeq;
    private string _lastUrl = DouyinUrl.HomeUrl;

    public DouyinLedger Ledger { get; } = new();

    /// <summary>结果变化时触发（页面订阅它重画列表）。</summary>
    public event Action? Changed;

    private void Notify() => Changed?.Invoke();

    private void Touch(DouyinPageBucket b) => b.TouchSeq = ++_touchSeq;

    private DouyinPageBucket Current
    {
        get
        {
            if (!_buckets.TryGetValue(_currentKey, out var b))
            {
                b = new DouyinPageBucket(_currentKey, _lastUrl);
                _buckets[_currentKey] = b;
            }
            return b;
        }
    }

    // ── 只读视图 ────────────────────────────────────────────

    private DouyinFilter _filter = new();
    public DouyinFilter Filter => _filter;

    public IReadOnlyList<DouyinItem> Items => Current.Items;
    public int Count => Current.Count;
    /// <summary>因为超出上限被丢弃的条数。</summary>
    public int Dropped => Current.Dropped;
    public bool Overflowed => Current.Dropped > 0;
    public bool HasFilter => !_filter.IsEmpty;

    /// <summary>通过筛选的媒体（列表与「下载全部」用的都是它）。</summary>
    public List<DouyinItem> VisibleItems => DouyinFilter.Apply(Current.Items, _filter, _filter.GroupByAweme);
    public int VisibleCount => VisibleItems.Count;

    /// <summary>抓取结果按作品折叠后的列表（一行一个作品）。</summary>
    public List<DouyinAwemeGroup> AwemeGroups => DouyinAwemeGroup.GroupByAweme(VisibleItems);

    /// <summary>不受筛选影响的作品总数（界面据此说「隐藏了几个作品」）。</summary>
    public int AllAwemeGroupCount => DouyinAwemeGroup.GroupByAweme(Current.Items).Count;

    public (List<string> Authors, List<string> Tags) Facets => DouyinFilter.Facets(Current.Items);

    public HashSet<string> SelectedIds => Current.Selected;
    public int SelectedCount => Current.Selected.Count;

    public string LastUrl => _lastUrl;
    public string CurrentPageKey => _currentKey;

    public List<DouyinPageBucket> Pages
    {
        get
        {
            var list = _buckets.Values.ToList();
            list.Sort((a, b) => b.TouchSeq.CompareTo(a.TouchSeq));
            return list;
        }
    }

    public bool IsSelected(string id) => Current.Selected.Contains(id);

    /// <summary>这条媒体所属作品是否已下载（台账是作品粒度）。</summary>
    public bool IsDownloaded(DouyinItem m) => Ledger.Contains(m.PostId);

    public bool IsGroupDownloaded(DouyinAwemeGroup g) => Ledger.Contains(g.AwemeId);

    public DouyinSelection GroupSelectionOf(DouyinAwemeGroup g)
    {
        if (g.Items.Count == 0) return DouyinSelection.None;
        var hit = g.Items.Count(m => Current.Selected.Contains(m.Id));
        if (hit == 0) return DouyinSelection.None;
        return hit == g.Items.Count ? DouyinSelection.All : DouyinSelection.Some;
    }

    /// <summary>「全选」复选框该显示成什么：null = 半选。</summary>
    public bool? SelectionState
    {
        get
        {
            var vis = VisibleItems;
            if (vis.Count == 0) return false;
            var hit = vis.Count(m => Current.Selected.Contains(m.Id));
            if (hit == 0) return false;
            return hit == vis.Count ? true : null;
        }
    }

    // ── 写 ──────────────────────────────────────────────────

    public void SetFilter(DouyinFilter f)
    {
        _filter = f;
        PruneSelection();
        Notify();
    }

    public void ClearFilter() => SetFilter(new DouyinFilter());

    /// <summary>WebView 地址变化时调用：切到（或新建）该页面的结果分组。</summary>
    public void SetCurrentUrl(string url)
    {
        if (string.IsNullOrWhiteSpace(url)) return;
        _lastUrl = url;
        var key = DouyinUrl.PageKey(url);

        if (!_buckets.ContainsKey(key)) EvictPages(key);
        if (!_buckets.TryGetValue(key, out var b))
        {
            b = new DouyinPageBucket(key, url);
            _buckets[key] = b;
        }
        b.Url = url;
        Touch(b);

        if (key != _currentKey)
        {
            _currentKey = key;
            Notify();
        }
    }

    public void SelectPage(string key)
    {
        if (key == _currentKey || !_buckets.ContainsKey(key)) return;
        _currentKey = key;
        Touch(Current);
        Notify();
    }

    private void EvictPages(string keeping)
    {
        if (_buckets.Count < MaxPages) return;
        var victims = _buckets.Values
            .Where(b => b.Key != keeping && b.Key != _currentKey)
            .ToList();
        victims.Sort((a, b) => a.TouchSeq.CompareTo(b.TouchSeq));
        var excess = _buckets.Count - MaxPages + 1;
        foreach (var v in victims)
        {
            if (excess <= 0) break;
            _buckets.Remove(v.Key);
            excess--;
        }
    }

    public void Toggle(string id)
    {
        if (!Current.Selected.Remove(id)) Current.Selected.Add(id);
        Notify();
    }

    /// <summary>全选 / 全不选 —— 只作用于当前可见（筛选后）的条目。</summary>
    public void SetAllSelected(bool value)
    {
        if (value)
        {
            Current.Selected.Clear();
            foreach (var m in VisibleItems) Current.Selected.Add(m.Id);
        }
        else
        {
            Current.Selected.Clear();
        }
        Notify();
    }

    /// <summary>「选择全部视频」/「选择全部图文」。</summary>
    public void SelectAllOfType(bool video)
    {
        foreach (var m in VisibleItems)
            if (video ? m.Type == DouyinMediaType.Video : m.Type == DouyinMediaType.Image)
                Current.Selected.Add(m.Id);
        Notify();
    }

    public void ToggleGroup(DouyinAwemeGroup g)
    {
        if (GroupSelectionOf(g) == DouyinSelection.All)
        {
            foreach (var m in g.Items) Current.Selected.Remove(m.Id);
        }
        else
        {
            foreach (var m in g.Items) Current.Selected.Add(m.Id);
        }
        Notify();
    }

    public void ClearSelection()
    {
        if (Current.Selected.Count == 0) return;
        Current.Selected.Clear();
        Notify();
    }

    private void PruneSelection()
    {
        if (Current.Selected.Count == 0) return;
        var visible = VisibleItems.Select(m => m.Id).ToHashSet();
        Current.Selected.RemoveWhere(id => !visible.Contains(id));
    }

    /// <summary>勾选了的媒体，保持列表顺序。</summary>
    public List<DouyinItem> SelectedMedia =>
        Current.Items.Where(m => Current.Selected.Contains(m.Id)).ToList();

    /// <summary>
    /// 把新解析出来的一批媒体并进仓库，返回真正新增的条数。
    /// 已存在的 id 直接丢弃 —— 抖音一个页面会反复拉同一批数据，不去重列表会瞬间爆掉。
    /// 顺序约定：追加到尾部，批内保持载荷顺序（= 页面上从上到下）。
    /// </summary>
    public int Ingest(IEnumerable<DouyinItem> incoming)
    {
        var fresh = new List<DouyinItem>();
        foreach (var m in incoming)
            if (Current.Ids.Add(m.Id)) fresh.Add(m);
        if (fresh.Count == 0) return 0;

        Current.Items.AddRange(fresh);
        Touch(Current);

        // 不再按 MaxItems 截断（2026-10-31 用户要求去掉上限）——全部保留。
        Notify();
        return fresh.Count;
    }

    /// <summary>清空结果（不动已下载台账，也不动已入队的下载任务）。</summary>
    public void Clear()
    {
        if (Current.Items.Count == 0 && Current.Selected.Count == 0) return;
        Current.Items.Clear();
        Current.Ids.Clear();
        Current.Selected.Clear();
        Current.Dropped = 0;
        Notify();
    }

    public void NotifyLedgerView() => Notify();

    // ── 下载组装 ─────────────────────────────────────────────

    /// <summary>把「当前选择」组装成可以直接交给 aria2 的媒体列表。</summary>
    public DouyinAssembleResult BuildDownloadList(DouyinConfig cfg)
    {
        var source = SelectedCount > 0 ? SelectedMedia : VisibleItems;
        return Assemble(source, cfg, IsDownloaded);
    }

    /// <summary>
    /// 组装（纯函数版）—— 「自动下载」也走这里，保证两个入口用同一套规则。
    ///
    /// 步骤：跳过已下载（作品粒度）→ 时长过滤（只作用于视频）→ 按设置解析下载源
    /// → 附带 BGM（仅图文作品，按地址在整批内去重）→ 按作品聚合排序。
    /// </summary>
    public static DouyinAssembleResult Assemble(
        IEnumerable<DouyinItem> source,
        DouyinConfig cfg,
        Func<DouyinItem, bool> isDownloaded)
    {
        var list = source.ToList();
        if (list.Count == 0) return DouyinAssembleResult.Empty;

        var skippedDownloaded = 0;
        var skippedDuration = 0;
        var kept = new List<DouyinItem>();

        foreach (var m in list)
        {
            if (cfg.SkipDownloaded && isDownloaded(m))
            {
                skippedDownloaded++;
                continue;
            }
            // 「附带实况图配对视频」关掉时，剔除实况图的那条配对视频
            var isLivePair = m.Type == DouyinMediaType.Video
                && m.Id != m.PostId && m.Id.EndsWith("v", StringComparison.Ordinal);
            if (!cfg.IncludeLivePhoto && isLivePair)
            {
                continue;
            }

            // 「下载配套图片」关掉时，剔除实况图的静态图。
            //
            // **图片与视频完全独立控制**（用户 2026-10-27 明确要求）：
            // 之前为了「合成必须有图」在这里强制保留图片（!LivePhotoAsMotionPhoto 才过滤），
            // 导致开关形同虚设 —— 只要开着合成，关掉本开关也不生效。
            // 现在：图片只按本开关走；合成阶段发现缺图就**跳过合成**并写日志，
            // 绝不因为「想合成」而偷偷下用户没要的图。
            if (!cfg.IncludeLiveImage && m.Type == DouyinMediaType.Image && m.Id != m.PostId)
            {
                // 只剔除「实况图的静态图」：存在配对视频才说明它是实况图；
                // 普通图集的静态图不受本开关影响（那是作品本体，不是"配套图"）。
                var hasPair = list.Any(x => x.Type == DouyinMediaType.Video
                    && x.Id == m.Id + "v");
                if (hasPair) continue;
            }
            // 时长范围只筛视频（参照实现的判据写在视频分支里，图片不受影响）
            if (cfg.TimeRangeEnabled && m.Type == DouyinMediaType.Video)
            {
                var sec = m.DurationMs / 1000.0;
                if (sec <= 0 || sec < cfg.TimeStartSec || sec > cfg.TimeEndSec)
                {
                    skippedDuration++;
                    continue;
                }
            }
            kept.Add(m);
        }

        if (cfg.GroupByAweme) kept.Sort(ByAwemeOrder(kept));

        var resolved = new List<DouyinItem>();
        foreach (var m in kept)
        {
            var r = DouyinSourceResolver.Resolve(m, cfg);
            // 解析后没有可用地址的条目直接丢掉（否则会产出必然失败的任务）
            if (r.DownloadCandidates.Count == 0) continue;
            if (!string.IsNullOrEmpty(cfg.CustomText))
            {
                r.CustomText = cfg.CustomText;
            }
            resolved.Add(r);
        }

        var withBgm = new List<DouyinItem>(resolved);
        if (cfg.IncludeBgm)
        {
            var seen = new HashSet<string>();
            // 按作品取一次 BGM：只在图文作品上追加，并按首个地址在整批内去重
            var imagePosts = new List<string>();
            foreach (var m in resolved)
                if (m.Type == DouyinMediaType.Image && !string.IsNullOrEmpty(m.PostId)
                    && !imagePosts.Contains(m.PostId)) imagePosts.Add(m.PostId);

            foreach (var postId in imagePosts)
            {
                var anchor = resolved.FirstOrDefault(m => m.PostId == postId && m.Type == DouyinMediaType.Image)
                    ?? resolved[0];
                var audio = anchor.Variants.FirstOrDefault(v => v.Kind == DouyinVariantKind.Audio && v.Usable);
                if (audio is null) continue;
                if (!seen.Add(audio.Urls[0])) continue;
                withBgm.Add(BuildBgmItem(anchor, audio, cfg.CustomText));
            }
        }

        return new DouyinAssembleResult
        {
            Items = withBgm,
            SkippedDownloaded = skippedDownloaded,
            SkippedDuration = skippedDuration,
        };
    }

    /// <summary>同一作品排在一起，作品之间的相对顺序不变。</summary>
    private static Comparison<DouyinItem> ByAwemeOrder(List<DouyinItem> list)
    {
        var order = new Dictionary<string, int>();
        foreach (var m in list)
        {
            var key = string.IsNullOrEmpty(m.PostId) ? m.Id : m.PostId;
            if (!order.ContainsKey(key)) order[key] = order.Count;
        }
        var index = new Dictionary<string, int>();
        for (var i = 0; i < list.Count; i++) index[list[i].Id] = i;

        return (a, b) =>
        {
            var oa = order.TryGetValue(string.IsNullOrEmpty(a.PostId) ? a.Id : a.PostId, out var x) ? x : 0;
            var ob = order.TryGetValue(string.IsNullOrEmpty(b.PostId) ? b.Id : b.PostId, out var y) ? y : 0;
            if (oa != ob) return oa.CompareTo(ob);
            return (index.TryGetValue(a.Id, out var ia) ? ia : 0)
                .CompareTo(index.TryGetValue(b.Id, out var ib) ? ib : 0);
        };
    }

    /// <summary>由 BGM 变体派生一条可下载的音频媒体（复用原作品的全部元数据）。</summary>
    private static DouyinItem BuildBgmItem(DouyinItem anchor, DouyinVariant audio, string customText)
    {
        var postId = string.IsNullOrEmpty(anchor.PostId) ? anchor.Id : anchor.PostId;
        return new DouyinItem
        {
            Id = postId + "_bgm",
            Type = DouyinMediaType.Audio,
            Url = audio.Urls[0],
            AltUrls = audio.Urls.Count > 1 ? audio.Urls.Skip(1).ToList() : new List<string>(),
            Variants = new List<DouyinVariant> { audio },
            Chosen = audio,
            PostId = anchor.PostId,
            Text = anchor.Text,
            CreatedAt = anchor.CreatedAt,
            UserId = anchor.UserId,
            UserName = anchor.UserName,
            AuthorUniqueId = anchor.AuthorUniqueId,
            Tags = anchor.Tags,
            // 序号排在图片之后，避免与图片/视频抢同一个 %MEDIA_INDEX%
            MediaIndex = anchor.MediaIndex + 900,
            Source = "douyin",
            DurationMs = anchor.DurationMs,
            LikeCount = anchor.LikeCount,
            CommentCount = anchor.CommentCount,
            CollectCount = anchor.CollectCount,
            ShareCount = anchor.ShareCount,
            Episode = anchor.Episode,
            CustomText = string.IsNullOrEmpty(customText) ? null : customText,
        };
    }
}
