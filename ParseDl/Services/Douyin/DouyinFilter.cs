using System;
using System.Collections.Generic;
using System.Linq;

namespace ParseDl.Services.Douyin;

/// <summary>
/// 抓取结果的筛选 —— 对齐 Flutter 版 lib/services/douyin_filter.dart（五个谓词串联）。
///
/// | 谓词 | 匹配范围 |
/// | 关键词 | desc + author.nickname + video_tag 拼接后的子串匹配 |
/// | 日期   | create_time 落在所选日期的整天区间内 |
/// | 作者   | uid ‖ authorId ‖ nickname 任一命中 |
/// | 标签   | 「任一」命中，或「全部」命中 |
/// | 时长   | video.duration（毫秒）落在 [最短, 最长] 内 |
///
/// 两个易混点：**日期筛的是发布时间，时长筛的是视频本身时长**；
/// 日期把用户选的「日」展开成整天的区间（这样选 9 月 14 日才能查到当天下午发的）。
/// </summary>
public sealed class DouyinFilter
{
    public string Keyword { get; set; } = "";
    public DateTime? DateStart { get; set; }
    public DateTime? DateEnd { get; set; }
    /// <summary>最近 N 天快捷键（与手动日期互斥：选了快捷键就覆盖 DateStart/DateEnd）。</summary>
    public DouyinDateRange QuickRange { get; set; } = DouyinDateRange.None;
    public HashSet<string> AuthorIds { get; set; } = new();
    public HashSet<string> Tags { get; set; } = new();
    public DouyinTagMode TagMode { get; set; } = DouyinTagMode.Any;
    public int? MinDurationSec { get; set; }
    public int? MaxDurationSec { get; set; }
    /// <summary>「按作品」—— 同一作品的多条媒体连续排列。</summary>
    public bool GroupByAweme { get; set; } = true;

    public bool IsEmpty =>
        string.IsNullOrWhiteSpace(Keyword)
        && DateStart is null && DateEnd is null
        && QuickRange == DouyinDateRange.None
        && AuthorIds.Count == 0 && Tags.Count == 0
        && MinDurationSec is null && MaxDurationSec is null;

    public static DateTime StartOfDay(DateTime d) => d.Date;
    public static DateTime EndOfDay(DateTime d) => d.Date.AddDays(1).AddTicks(-1);

    public bool Matches(DouyinItem m)
        => ByKeyword(m, Keyword)
        && ByDateRange(m, this)
        && ByAuthors(m, AuthorIds)
        && ByTags(m, Tags, TagMode)
        && ByDuration(m, MinDurationSec, MaxDurationSec);

    private static bool ByKeyword(DouyinItem m, string keyword)
    {
        var k = (keyword ?? "").Trim().ToLowerInvariant();
        if (k.Length == 0) return true;
        return m.SearchText.ToLowerInvariant().Contains(k);
    }

    /// <summary>没有发布时间的条目在启用日期筛选时被排除（否则用户会以为筛选没生效）。</summary>
    private static bool ByDateRange(DouyinItem m, DouyinFilter f)
    {
        DateTime? lo = f.DateStart, hi = f.DateEnd;
        var quick = f.QuickRange.Resolve(DateTime.Now);
        if (quick is not null) { lo = quick.Value.Start; hi = quick.Value.End; }
        if (lo is null && hi is null) return true;
        var t = m.CreatedAt;
        if (t is null) return false;
        if (lo is not null && t.Value < StartOfDay(lo.Value)) return false;
        if (hi is not null && t.Value > EndOfDay(hi.Value)) return false;
        return true;
    }

    private static bool ByAuthors(DouyinItem m, HashSet<string> authors)
    {
        if (authors.Count == 0) return true;
        foreach (var a in authors)
            if (a == m.UserId || a == m.AuthorUniqueId || a == m.UserName) return true;
        return false;
    }

    private static bool ByTags(DouyinItem m, HashSet<string> tags, DouyinTagMode mode)
    {
        if (tags.Count == 0) return true;
        var owned = new HashSet<string>(m.Tags);
        return mode == DouyinTagMode.All
            ? tags.All(owned.Contains)
            : tags.Any(owned.Contains);
    }

    /// <summary>没有时长的条目（图片）在启用时长筛选时被排除 —— 与参照实现一致。</summary>
    private static bool ByDuration(DouyinItem m, int? minSec, int? maxSec)
    {
        if (minSec is null && maxSec is null) return true;
        var ms = m.DurationMs;
        if (ms <= 0) return false;
        var sec = ms / 1000.0;
        if (minSec is not null && sec < minSec.Value) return false;
        if (maxSec is not null && sec > maxSec.Value) return false;
        return true;
    }

    /// <summary>应用筛选并（可选）按作品聚合排序 —— 「按作品」不改动作品之间的相对顺序。</summary>
    public static List<DouyinItem> Apply(IEnumerable<DouyinItem> items, DouyinFilter f, bool group = true)
    {
        var kept = items.Where(f.Matches).ToList();
        if (!group || !f.GroupByAweme) return kept;

        // 用「首次出现顺序」建立作品次序，再按该次序稳定归组
        var order = new Dictionary<string, int>();
        foreach (var m in kept)
        {
            var key = string.IsNullOrEmpty(m.PostId) ? m.Id : m.PostId;
            if (!order.ContainsKey(key)) order[key] = order.Count;
        }
        var indexed = new List<(int Group, int Index, DouyinItem Item)>();
        for (var i = 0; i < kept.Count; i++)
        {
            var key = string.IsNullOrEmpty(kept[i].PostId) ? kept[i].Id : kept[i].PostId;
            indexed.Add((order[key], i, kept[i]));
        }
        indexed.Sort((a, b) => a.Group != b.Group ? a.Group.CompareTo(b.Group) : a.Index.CompareTo(b.Index));
        return indexed.Select(e => e.Item).ToList();
    }

    /// <summary>可选的作者 / 标签候选列表 —— 供筛选面板做多选。</summary>
    public static (List<string> Authors, List<string> Tags) Facets(IEnumerable<DouyinItem> items)
    {
        var authors = new HashSet<string>();
        var tags = new HashSet<string>();
        foreach (var m in items)
        {
            foreach (var a in new[] { m.UserName, m.AuthorUniqueId, m.UserId })
                if (!string.IsNullOrEmpty(a)) authors.Add(a!);
            foreach (var t in m.Tags) tags.Add(t);
        }
        var a2 = authors.ToList(); a2.Sort(StringComparer.Ordinal);
        var t2 = tags.ToList(); t2.Sort(StringComparer.Ordinal);
        return (a2, t2);
    }
}

/// <summary>一个作品（aweme）在界面上的勾选状态 —— 三态。</summary>
public enum DouyinSelection { None, Some, All }

/// <summary>一个作品在抓取结果里的一行（作品粒度视图模型）。</summary>
public sealed class DouyinAwemeGroup
{
    public string AwemeId { get; }
    public List<DouyinItem> Items { get; }

    public DouyinAwemeGroup(string awemeId, List<DouyinItem> items)
    {
        AwemeId = awemeId;
        Items = items;
    }

    public int Count => Items.Count;
    public DouyinItem Lead => Items[0];
    public string Title => string.IsNullOrEmpty(Lead.Text) ? AwemeId : Lead.Text!;
    public string CoverUrl => Lead.PreviewUrl;
    public IReadOnlyList<string> Tags => Lead.Tags;
    public int LikeCount => Lead.LikeCount;
    public int CommentCount => Lead.CommentCount;
    public int CollectCount => Lead.CollectCount;
    public int ShareCount => Lead.ShareCount;
    public DateTime? CreatedAt => Lead.CreatedAt;

    public int ImageCount => Items.Count(m => m.Type == DouyinMediaType.Image);

    /// <summary>实况图张数 —— 配对关系靠同一个 mediaIndex 表达。</summary>
    public int ImageLiveCount
    {
        get
        {
            var liveIndexes = new HashSet<int>(
                Items.Where(m => m.Type == DouyinMediaType.Video && m.Id != AwemeId).Select(m => m.MediaIndex));
            if (liveIndexes.Count == 0) return 0;
            return Items.Count(m => m.Type == DouyinMediaType.Image && liveIndexes.Contains(m.MediaIndex));
        }
    }

    /// <summary>主视频：id 就等于作品 id 的那条（实况图配对视频带 v 后缀，不算）。</summary>
    public DouyinItem? MainVideo
    {
        get
        {
            foreach (var m in Items)
                if (m.Type == DouyinMediaType.Video && m.Id == AwemeId) return m;
            return null;
        }
    }

    public bool HasMainVideo => MainVideo is not null;
    public bool HasLiveVideo => Items.Any(m => m.Type == DouyinMediaType.Video && m.Id != AwemeId);
    public int? DurationMs => MainVideo?.DurationMs;

    /// <summary>行上的类型标签，对齐参照实现列表里的「图文 / 视频」前缀。</summary>
    public string TypeLabel
    {
        get
        {
            var imgs = ImageCount;
            if (imgs > 0 && HasMainVideo) return "视频 + " + imgs + " 图";
            if (imgs > 0)
            {
                if (ImageLiveCount > 0) return "实况图文 " + ImageLiveCount + " 图";
                return imgs > 1 ? "图文 " + imgs + " 图" : "图文";
            }
            return "视频";
        }
    }

    /// <summary>把媒体粒度列表折成作品粒度，按各作品首条出现的先后排序。</summary>
    public static List<DouyinAwemeGroup> GroupByAweme(IEnumerable<DouyinItem> items)
    {
        var order = new List<string>();
        var buckets = new Dictionary<string, List<DouyinItem>>();
        foreach (var m in items)
        {
            var key = string.IsNullOrEmpty(m.PostId) ? m.Id : m.PostId;
            if (!buckets.TryGetValue(key, out var list))
            {
                list = new List<DouyinItem>();
                buckets[key] = list;
                order.Add(key);
            }
            list.Add(m);
        }
        return order.Select(id => new DouyinAwemeGroup(id, buckets[id])).ToList();
    }
}
