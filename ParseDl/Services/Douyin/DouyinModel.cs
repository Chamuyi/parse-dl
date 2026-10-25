using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace ParseDl.Services.Douyin;

/// <summary>一个媒体变体（一条视频的某个码率档、一档直链、一组图片镜像、或一条 BGM）。</summary>
public sealed class DouyinVariant
{
    public List<string> Urls { get; init; } = new();
    public DouyinVariantKind Kind { get; init; } = DouyinVariantKind.DefaultAddr;
    public int Width { get; init; }
    public int Height { get; init; }
    public double Fps { get; init; }
    public long Bitrate { get; init; }
    public long Size { get; init; }
    public string Format { get; init; } = "";
    public string Gear { get; init; } = "";
    public bool ByteVc1 { get; init; }

    /// <summary>可用 = 至少有一个地址。空变体一律丢弃，否则会产出必然失败的任务。</summary>
    public bool Usable => Urls.Any(u => !string.IsNullOrEmpty(u));

    public static DouyinVariant FromJson(JsonElement e)
    {
        var urls = StrList(e, "urls");
        return new DouyinVariant
        {
            Urls = urls,
            Kind = KindOf(Str(e, "kind")),
            Width = Int(e, "w"),
            Height = Int(e, "h"),
            Fps = Num(e, "fps"),
            Bitrate = (long)Num(e, "br"),
            Size = (long)Num(e, "size"),
            Format = Str(e, "format"),
            Gear = Str(e, "gear"),
            ByteVc1 = Bool(e, "bytevc1"),
        };
    }

    public static DouyinVariantKind KindOf(string id) => id switch
    {
        "bit_rate" => DouyinVariantKind.BitRate,
        "h264" => DouyinVariantKind.H264,
        "h265" => DouyinVariantKind.H265,
        "download" => DouyinVariantKind.Download,
        "image" => DouyinVariantKind.Image,
        "audio" => DouyinVariantKind.Audio,
        _ => DouyinVariantKind.DefaultAddr,
    };

    internal static string Str(JsonElement el, string name)
        => el.ValueKind == JsonValueKind.Object && el.TryGetProperty(name, out var v)
            && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";

    internal static int Int(JsonElement el, string name)
    {
        if (el.ValueKind != JsonValueKind.Object || !el.TryGetProperty(name, out var v)) return 0;
        if (v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i)) return i;
        if (v.ValueKind == JsonValueKind.String && int.TryParse(v.GetString(), out var p)) return p;
        return 0;
    }

    internal static double Num(JsonElement el, string name)
    {
        if (el.ValueKind != JsonValueKind.Object || !el.TryGetProperty(name, out var v)) return 0;
        if (v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d)) return d;
        if (v.ValueKind == JsonValueKind.String && double.TryParse(v.GetString(), out var p)) return p;
        return 0;
    }

    internal static bool Bool(JsonElement el, string name)
        => el.ValueKind == JsonValueKind.Object && el.TryGetProperty(name, out var v)
            && v.ValueKind == JsonValueKind.True;

    internal static List<string> StrList(JsonElement el, string name)
    {
        var outList = new List<string>();
        if (el.ValueKind != JsonValueKind.Object || !el.TryGetProperty(name, out var v)) return outList;
        if (v.ValueKind != JsonValueKind.Array) return outList;
        foreach (var x in v.EnumerateArray())
        {
            if (x.ValueKind != JsonValueKind.String) continue;
            var s = x.GetString();
            if (!string.IsNullOrEmpty(s) && !outList.Contains(s)) outList.Add(s!);
        }
        return outList;
    }
}

/// <summary>
/// 一条可下载的媒体（= Flutter 版 models/media.dart 的 Media，抖音侧字段映射见
/// douyin_parser.dart 表：id→PostId、desc→Text、createTime→CreatedAt…）。
/// </summary>
public sealed class DouyinItem
{
    public string Id { get; set; } = "";
    public DouyinMediaType Type { get; set; } = DouyinMediaType.Video;
    public string Url { get; set; } = "";
    public List<string> AltUrls { get; set; } = new();
    public List<DouyinVariant> Variants { get; set; } = new();
    public DouyinVariant? Chosen { get; set; }
    public string PreviewUrl { get; set; } = "";
    public string PostId { get; set; } = "";
    public string? Text { get; set; }
    public DateTime? CreatedAt { get; set; }
    public string? UserId { get; set; }
    public string? UserName { get; set; }
    public string? AuthorUniqueId { get; set; }
    public List<string> Tags { get; set; } = new();
    public int MediaIndex { get; set; } = 1;
    public string Source { get; set; } = "douyin";
    public int Width { get; set; }
    public int Height { get; set; }
    public int DurationMs { get; set; }
    public int LikeCount { get; set; }
    public int CommentCount { get; set; }
    public int CollectCount { get; set; }
    public int ShareCount { get; set; }
    public int Episode { get; set; }
    public string? CustomText { get; set; }

    public bool IsVideo => Type == DouyinMediaType.Video;
    public bool IsImage => Type == DouyinMediaType.Image;

    /// <summary>候选地址（主地址 + 换源备用），去重且保持顺序。</summary>
    public List<string> DownloadCandidates
    {
        get
        {
            var outList = new List<string>();
            if (!string.IsNullOrEmpty(Url)) outList.Add(Url);
            foreach (var u in AltUrls)
                if (!string.IsNullOrEmpty(u) && !outList.Contains(u)) outList.Add(u);
            return outList;
        }
    }

    /// <summary>关键词筛选用：作品文本 + 作者名 + 标签 拼接。</summary>
    public string SearchText
    {
        get
        {
            var parts = new List<string>();
            if (!string.IsNullOrEmpty(Text)) parts.Add(Text!);
            if (!string.IsNullOrEmpty(UserName)) parts.Add(UserName!);
            if (!string.IsNullOrEmpty(AuthorUniqueId)) parts.Add(AuthorUniqueId!);
            parts.AddRange(Tags);
            return string.Join(" ", parts);
        }
    }

    public DouyinItem Clone() => new()
    {
        Id = Id, Type = Type, Url = Url,
        AltUrls = new List<string>(AltUrls),
        Variants = Variants,
        Chosen = Chosen,
        PreviewUrl = PreviewUrl, PostId = PostId, Text = Text, CreatedAt = CreatedAt,
        UserId = UserId, UserName = UserName, AuthorUniqueId = AuthorUniqueId,
        Tags = Tags, MediaIndex = MediaIndex, Source = Source,
        Width = Width, Height = Height, DurationMs = DurationMs,
        LikeCount = LikeCount, CommentCount = CommentCount,
        CollectCount = CollectCount, ShareCount = ShareCount,
        Episode = Episode, CustomText = CustomText,
    };
}

/// <summary>一条作品（拦截脚本 normalize() 压扁后的瘦对象）。</summary>
public sealed class DouyinPost
{
    public string Id { get; init; } = "";
    public string Kind { get; init; } = "";
    public string Desc { get; init; } = "";
    public DateTime? CreatedAt { get; init; }
    public int DurationMs { get; init; }
    public string Cover { get; init; } = "";
    public List<DouyinVariant> Videos { get; init; } = new();
    public List<(List<string> Urls, List<DouyinVariant> Live)> Images { get; init; } = new();
    public List<string> Tags { get; init; } = new();
    public List<string> MusicUrls { get; init; } = new();
    public string AuthorUid { get; init; } = "";
    public string AuthorName { get; init; } = "";
    public string AuthorId { get; init; } = "";
    public int Digg { get; init; }
    public int Comment { get; init; }
    public int Collect { get; init; }
    public int Share { get; init; }
    public int Episode { get; init; }
}

/// <summary>一次载荷解析的结果。</summary>
public sealed class DouyinPayloadResult
{
    public List<DouyinItem> Media { get; init; } = new();
    /// <summary>载荷里原始 aweme 条数（不含图集展开）。</summary>
    public int AwemeCount { get; init; }
    public static DouyinPayloadResult Empty => new();
}

/// <summary>
/// 拦截载荷 → DouyinItem。对齐 Flutter 版 lib/services/douyin_parser.dart。
///
/// 兼容三种形态：{__pd:'douyin', items:[...]} / [...] / {...}。
/// 展开规则（对齐参照实现）：
///   · 视频 → 1 条视频媒体（候选含全部码率变体 + 指定编码字段 + BGM 变体）
///   · 图集 → 每张图 1 条图片媒体；实况图额外产出 1 条配对视频媒体，
///     两者 mediaIndex 相同 → 落盘后「前缀_1.jpg」+「前缀_1.mp4」天然配对
///   · 混合 → 两者都产出
/// BGM 不作为独立条目产出（由下载组装阶段按 mid 去重后追加）。
/// </summary>
public static class DouyinPayloadParser
{
    public static DouyinPayloadResult Parse(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return DouyinPayloadResult.Empty;

        var outList = new List<DouyinItem>();
        var ids = new HashSet<string>();
        var awemeCount = 0;

        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var items = new List<JsonElement>();

            if (root.ValueKind == JsonValueKind.Object)
            {
                if (root.TryGetProperty("__pd", out _))
                {
                    if (root.TryGetProperty("items", out var arr) && arr.ValueKind == JsonValueKind.Array)
                        items.AddRange(arr.EnumerateArray());
                }
                else if (root.TryGetProperty("id", out _))
                {
                    items.Add(root);
                }
            }
            else if (root.ValueKind == JsonValueKind.Array)
            {
                items.AddRange(root.EnumerateArray());
            }

            foreach (var raw in items)
            {
                if (raw.ValueKind != JsonValueKind.Object) continue;
                var post = ToPost(raw);
                if (post is null) continue;
                var media = ToItems(post);
                if (media.Count == 0) continue;
                awemeCount++;
                foreach (var m in media)
                    if (ids.Add(m.Id)) outList.Add(m);
            }
        }
        catch
        {
            // 载荷形状不对 → 返回已解析到的部分（空也算正常）
        }

        return new DouyinPayloadResult { Media = outList, AwemeCount = awemeCount };
    }

    /// <summary>单条瘦对象 → DouyinPost。</summary>
    public static DouyinPost? ToPost(JsonElement j)
    {
        var id = DouyinVariant.Str(j, "id");
        if (string.IsNullOrEmpty(id)) return null;

        var images = new List<(List<string>, List<DouyinVariant>)>();
        if (j.TryGetProperty("images", out var imgs) && imgs.ValueKind == JsonValueKind.Array)
        {
            foreach (var e in imgs.EnumerateArray())
            {
                if (e.ValueKind != JsonValueKind.Object) continue;
                var urls = DouyinVariant.StrList(e, "urls");
                var live = Variants(e, "live");
                if (urls.Count == 0 && live.Count == 0) continue;
                images.Add((urls, live));
            }
        }

        return new DouyinPost
        {
            Id = id,
            Kind = DouyinVariant.Str(j, "kind"),
            Desc = DouyinVariant.Str(j, "desc"),
            CreatedAt = CreatedAt(j),
            DurationMs = DouyinVariant.Int(j, "durationMs"),
            Cover = DouyinVariant.Str(j, "cover"),
            Videos = Variants(j, "videos"),
            Images = images,
            Tags = DouyinVariant.StrList(j, "tags"),
            MusicUrls = DouyinVariant.StrList(j, "musicUrls"),
            AuthorUid = DouyinVariant.Str(j, "authorUid"),
            AuthorName = DouyinVariant.Str(j, "authorName"),
            AuthorId = DouyinVariant.Str(j, "authorId"),
            Digg = DouyinVariant.Int(j, "digg"),
            Comment = DouyinVariant.Int(j, "comment"),
            Collect = DouyinVariant.Int(j, "collect"),
            Share = DouyinVariant.Int(j, "share"),
            Episode = DouyinVariant.Int(j, "episode"),
        };
    }

    /// <summary>一条作品 → 若干媒体（图集按张展开，实况图多出配对视频）。</summary>
    public static List<DouyinItem> ToItems(DouyinPost p)
    {
        var outList = new List<DouyinItem>();
        var audio = p.MusicUrls.Count == 0
            ? null
            : new DouyinVariant { Urls = p.MusicUrls, Kind = DouyinVariantKind.Audio };

        DouyinItem Build(string mediaId, DouyinMediaType type, string url, int index,
            List<string> altUrls, List<DouyinVariant> variants, int width, int height, int dur)
            => new()
            {
                Id = mediaId,
                Type = type,
                Url = url,
                AltUrls = altUrls,
                PreviewUrl = type == DouyinMediaType.Image ? url : p.Cover,
                Width = width,
                Height = height,
                PostId = p.Id,
                Text = p.Desc,
                CreatedAt = p.CreatedAt,
                UserId = string.IsNullOrEmpty(p.AuthorUid) ? null : p.AuthorUid,
                UserName = string.IsNullOrEmpty(p.AuthorName) ? null : p.AuthorName,
                AuthorUniqueId = string.IsNullOrEmpty(p.AuthorId) ? null : p.AuthorId,
                Tags = p.Tags,
                MediaIndex = index,
                Source = "douyin",
                Variants = variants,
                DurationMs = dur,
                LikeCount = p.Digg,
                CommentCount = p.Comment,
                CollectCount = p.Collect,
                ShareCount = p.Share,
                Episode = p.Episode,
            };

        // ── 图集（含实况图的配对视频）─────────────────────────
        for (var i = 0; i < p.Images.Count; i++)
        {
            var (urls, live) = p.Images[i];
            if (urls.Count == 0) continue;

            var variants = new List<DouyinVariant>
            {
                new() { Urls = urls, Kind = DouyinVariantKind.Image },
            };
            if (audio is not null) variants.Add(audio);

            outList.Add(Build(p.Id + "_" + (i + 1), DouyinMediaType.Image, urls[0], i + 1,
                urls.Count > 1 ? urls.Skip(1).ToList() : new List<string>(),
                variants, 0, 0, 0));

            if (live.Count > 0)
            {
                var liveUrls = Flatten(live);
                if (liveUrls.Count > 0)
                {
                    var lv = new List<DouyinVariant>(live);
                    if (audio is not null) lv.Add(audio);
                    outList.Add(Build(p.Id + "_" + (i + 1) + "v", DouyinMediaType.Video,
                        liveUrls[0], i + 1,
                        liveUrls.Count > 1 ? liveUrls.Skip(1).ToList() : new List<string>(),
                        lv, live[0].Width, live[0].Height, 0));
                }
            }
        }

        // ── 视频 ─────────────────────────────────────────────
        var videoKinds = p.Videos
            .Where(v => v.Kind is DouyinVariantKind.BitRate or DouyinVariantKind.DefaultAddr)
            .ToList();

        if (videoKinds.Count > 0 && p.Kind != "images")
        {
            var allUrls = Flatten(p.Videos);
            if (allUrls.Count > 0)
            {
                var variants = new List<DouyinVariant>(p.Videos);
                if (audio is not null) variants.Add(audio);
                var first = videoKinds[0];
                outList.Add(Build(p.Id, DouyinMediaType.Video, allUrls[0],
                    p.Images.Count == 0 ? 1 : p.Images.Count + 1,
                    allUrls.Count > 1 ? allUrls.Skip(1).ToList() : new List<string>(),
                    variants, first.Width, first.Height, p.DurationMs));
            }
        }

        return outList;
    }

    /// <summary>把变体列表压平成一串去重地址（首个即首选）。</summary>
    public static List<string> Flatten(IEnumerable<DouyinVariant> variants)
    {
        var outList = new List<string>();
        foreach (var v in variants)
            foreach (var u in v.Urls)
                if (!string.IsNullOrEmpty(u) && !outList.Contains(u)) outList.Add(u);
        return outList;
    }

    private static List<DouyinVariant> Variants(JsonElement el, string name)
    {
        var outList = new List<DouyinVariant>();
        if (!el.TryGetProperty(name, out var arr) || arr.ValueKind != JsonValueKind.Array) return outList;
        foreach (var e in arr.EnumerateArray())
        {
            if (e.ValueKind != JsonValueKind.Object) continue;
            var v = DouyinVariant.FromJson(e);
            if (v.Usable) outList.Add(v);
        }
        return outList;
    }

    private static DateTime? CreatedAt(JsonElement j)
    {
        var sec = DouyinVariant.Int(j, "createTime");
        if (sec <= 0) return null;
        try
        {
            // 抖音的 create_time 是 Unix 秒（UTC），转本地时区再喂给 %CREATE_TIME%
            return DateTimeOffset.FromUnixTimeSeconds(sec).ToLocalTime().DateTime;
        }
        catch { return null; }
    }
}
