using System;
using System.Collections.Generic;
using System.Linq;

namespace ParseDl.Services.Douyin;

/// <summary>
/// 下载源解析 —— 对齐 Flutter 版 lib/services/douyin_source.dart。
///
/// 视频变体综合得分 = 分辨率分量 × w1 + 帧率分量 × w2 + 码率分量 × w3：
///   · 分辨率：以 100 万像素为基准开平方，1 倍基准得 50 分，封顶 100；
///   · 帧率：分段线性（≤24 每帧 2 分；24~60 每帧 +1.4；&gt;60 每帧 +0.1）；
///   · 码率：先按 √(宽×高) 归一化再折算，「小图配高码率」不会被误判成高质量。
///
/// 三个既定口径（都有测试钉着）：
///   1. auto 档权重是 0.4/0.2/0.4，不是 0.7/0.2/0.1 —— 只看三个专项档会漏掉它；
///   2. 评分前置检查「宽/高/帧率/码率 四项任一 ≤ 0 → 判 0 分」对 auto 也生效；
///   3. 评分候选集只从 bit_rate[] 里取，且只保留 mp4；指定 H.264/H.265 走另一个字段。
/// </summary>
public static class DouyinSourceResolver
{
    public static double ResolutionScore(int width, int height)
    {
        if (width <= 0 || height <= 0) return 0;
        return Cap(Math.Sqrt(width * (double)height / 1000000.0) * 50);
    }

    public static double FpsScore(double fps)
    {
        if (fps <= 0) return 0;
        if (fps <= 24) return fps * 2;
        if (fps <= 60) return 48 + (fps - 24) * 1.4;
        return Cap(98 + (fps - 60) * 0.1);
    }

    public static double BitrateScore(long bitrate, int width, int height)
    {
        if (bitrate <= 0 || width <= 0 || height <= 0) return 0;
        var scale = Math.Sqrt(width * (double)height) * 0.15;
        if (scale <= 0) return 0;
        return Cap(bitrate / 1000.0 / scale * 60);
    }

    private static double Cap(double v) => v > 100 ? 100 : v;

    /// <summary>各档权重，顺序固定为（分辨率, 帧率, 码率）。auto 是 0.4/0.2/0.4。</summary>
    public static (double Res, double Fps, double Bit) Weights(DouyinQualityMode m) => m switch
    {
        DouyinQualityMode.Resolution => (0.7, 0.1, 0.2),
        DouyinQualityMode.Fps => (0.2, 0.7, 0.1),
        DouyinQualityMode.Bitrate => (0.2, 0.1, 0.7),
        _ => (0.4, 0.2, 0.4),
    };

    /// <summary>单个变体的综合得分；四项任一为 0 就返回 0。</summary>
    public static double VariantScore(DouyinVariant v, DouyinQualityMode mode)
    {
        if (v.Width <= 0 || v.Height <= 0 || v.Fps <= 0 || v.Bitrate <= 0) return 0;
        var (wRes, wFps, wBit) = Weights(mode);
        return Math.Round(
            wRes * ResolutionScore(v.Width, v.Height)
            + wFps * FpsScore(v.Fps)
            + wBit * BitrateScore(v.Bitrate, v.Width, v.Height), 1, MidpointRounding.AwayFromZero);
    }

    /// <summary>
    /// 候选集过滤 + 按得分降序（稳定排序：得分相同保持原顺序）。
    /// 过滤链：去不可用 → 只要 mp4 → (可选)非 low 档 → (可选)非 ByteVC1。
    /// </summary>
    public static List<DouyinVariant> RankVideoVariants(
        IEnumerable<DouyinVariant> variants,
        DouyinQualityMode mode = DouyinQualityMode.Auto,
        bool filterLowQuality = false,
        bool filterByteVc1 = false)
    {
        var indexed = new List<(int Index, DouyinVariant V)>();
        var i = 0;
        foreach (var v in variants)
        {
            var idx = i++;
            if (!v.Usable) continue;
            if (!string.Equals(v.Format, "mp4", StringComparison.OrdinalIgnoreCase)) continue;
            if (filterLowQuality && v.Gear.ToLowerInvariant().Contains("low")) continue;
            if (filterByteVc1 && v.ByteVc1) continue;
            indexed.Add((idx, v));
        }
        indexed.Sort((a, b) =>
        {
            var sa = VariantScore(a.V, mode);
            var sb = VariantScore(b.V, mode);
            if (sa != sb) return sb.CompareTo(sa);
            return a.Index.CompareTo(b.Index);
        });
        return indexed.Select(e => e.V).ToList();
    }

    /// <summary>
    /// 按配置挑出这条媒体该用哪些地址下载，返回「已解析」的副本。
    ///
    /// | source                     | 取哪个字段                              |
    /// | defaultAddr / h264 / h265  | 对应 kind 的变体，不评分                |
    /// | qualityFirst               | bit_rate[] 评分第一名，排除 ByteVC1     |
    /// | qualityFirstBytevc1        | bit_rate[] 评分第一名，不排除 ByteVC1   |
    /// | audioOnly                  | 该作品的 BGM（不是抽音轨）              |
    /// </summary>
    public static DouyinItem Resolve(DouyinItem m, DouyinConfig cfg)
    {
        if (m.Source != "douyin") return m;
        if (m.IsImage) return ResolveImage(m, cfg);

        if (m.Type == DouyinMediaType.Audio)
            return Apply(m, UrlsOfKind(m, DouyinVariantKind.Audio), null);

        // ── 视频 ────────────────────────────────────────────
        if (cfg.Source == DouyinSource.AudioOnly)
        {
            var audio = UrlsOfKind(m, DouyinVariantKind.Audio);
            if (audio.Count > 0)
            {
                var copy = m.Clone();
                copy.Type = DouyinMediaType.Audio;
                return Apply(copy, audio, FirstVariantOfKind(m, DouyinVariantKind.Audio));
            }
            // 没有 BGM 可换时保留视频 —— 换成音频列表会拿到空数组、条目必然失败
        }

        var kind = cfg.Source switch
        {
            DouyinSource.H264 => DouyinVariantKind.H264,
            DouyinSource.H265 => DouyinVariantKind.H265,
            DouyinSource.QualityFirst or DouyinSource.QualityFirstBytevc1 => DouyinVariantKind.BitRate,
            _ => DouyinVariantKind.DefaultAddr,
        };
        var byKind = UrlsOfKind(m, kind);

        if (cfg.Source.NeedsQualityMode())
        {
            var ranked = RankVideoVariants(m.Variants,
                cfg.QualityMode,
                cfg.FilterLowQuality,
                // 「兼容性+质量优先」强制排除 ByteVC1；用户手动勾选也排除
                cfg.Source == DouyinSource.QualityFirst || cfg.FilterByteVc1);
            if (ranked.Count > 0) return Apply(m, ranked[0].Urls, ranked[0]);
            // 评分候选为空（缺 bit_rate）时退回该档位的直接字段，再退回已有候选
            if (byKind.Count > 0) return Apply(m, byKind, null);
            return m;
        }

        if (byKind.Count > 0) return Apply(m, byKind, FirstVariantOfKind(m, KindOf(cfg.Source)));

        // 指定字段缺失（如没有 play_addr_h264）时不产出空任务：退回已有候选地址。
        //
        // **但必须排除音频地址**（2026-10-30）：m.DownloadCandidates 是 Url + AltUrls，
        // 而早期版本会把 BGM 音频混进视频条目的候选里，退回时就会拿音频当视频下，
        // 落盘却按 Video 规则给 .mp4 扩展名 —— 实测该文件头是 ID3（MP3）。
        // 这里做一道保险：只用 Variants 里确实是视频的地址，兜不住就返回原条目。
        var videoOnly = m.Variants
            .Where(v => v.Usable && v.Kind is DouyinVariantKind.BitRate
                or DouyinVariantKind.DefaultAddr or DouyinVariantKind.H264
                or DouyinVariantKind.H265 or DouyinVariantKind.Download)
            .SelectMany(v => v.Urls)
            .Distinct()
            .ToList();
        if (videoOnly.Count > 0) return Apply(m, videoOnly, m.Chosen);
        return Apply(m, m.DownloadCandidates, m.Chosen);
    }

    /// <summary>图文：按图片格式偏好重排镜像顺序（不动 URL 本身）。</summary>
    private static DouyinItem ResolveImage(DouyinItem m, DouyinConfig cfg)
    {
        var urls = m.DownloadCandidates;
        if (urls.Count == 0) return m;

        if (cfg.ImageFormat == DouyinImageFormat.JpgFirst)
        {
            var stable = new List<(int Index, string Url)>();
            for (var i = 0; i < urls.Count; i++) stable.Add((i, urls[i]));
            stable.Sort((a, b) =>
            {
                var wa = IsWebp(a.Url) ? 1 : 0;
                var wb = IsWebp(b.Url) ? 1 : 0;
                if (wa != wb) return wa.CompareTo(wb);
                return a.Index.CompareTo(b.Index);
            });
            urls = stable.Select(e => e.Url).ToList();
        }

        var copy = Apply(m, urls, m.Variants.Count == 0 ? null : m.Variants[0]);
        return copy;
    }

    private static bool IsWebp(string url)
        => url.Split('?')[0].ToLowerInvariant().EndsWith(".webp");

    private static List<string> UrlsOfKind(DouyinItem m, DouyinVariantKind kind)
    {
        var outList = new List<string>();
        foreach (var v in m.Variants)
        {
            if (v.Kind != kind) continue;
            foreach (var u in v.Urls)
                if (!string.IsNullOrEmpty(u) && !outList.Contains(u)) outList.Add(u);
        }
        return outList;
    }

    private static DouyinVariant? FirstVariantOfKind(DouyinItem m, DouyinVariantKind kind)
    {
        foreach (var v in m.Variants)
            if (v.Kind == kind && v.Usable) return v;
        return null;
    }

    private static DouyinVariantKind KindOf(DouyinSource s) => s switch
    {
        DouyinSource.H264 => DouyinVariantKind.H264,
        DouyinSource.H265 => DouyinVariantKind.H265,
        _ => DouyinVariantKind.DefaultAddr,
    };

    /// <summary>把挑好的地址写回媒体：首个当主地址，其余当换源备用。</summary>
    private static DouyinItem Apply(DouyinItem m, List<string> urls, DouyinVariant? chosen)
    {
        var clean = new List<string>();
        foreach (var u in urls)
            if (!string.IsNullOrEmpty(u) && !clean.Contains(u)) clean.Add(u);
        if (clean.Count == 0) return m;

        var copy = m.Clone();
        copy.Url = clean[0];
        copy.AltUrls = clean.Count > 1 ? clean.Skip(1).ToList() : new List<string>();
        copy.Chosen = chosen;
        return copy;
    }
}
