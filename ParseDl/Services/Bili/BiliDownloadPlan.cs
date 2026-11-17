using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace ParseDl.Services.Bili;

/// <summary>
/// 一条分 P 选出来的两条流 —— 从 Flutter 版 lib/services/bili_download_plan.dart
/// 的 BiliStreamPair 移植。
///
/// 三条口径（照搬 Flutter 版踩出来的结论）：
///  * **上限不等于结果**：B 站按账号权限先裁一刀，所以「选了 1080P60 只拿到 1080P」
///    是正常结果，不是失败 —— 但必须通过 <see cref="VideoQn"/> 如实告诉界面；
///  * **先裁画质、再按编码偏好**：编码不该把清晰度换掉，所以排序键是
///    「档位号 → 编码偏好 → 码率」；
///  * **不碰 cookie 塞给下载器**：需要登录才能取的流这一期拿不到就不拿，
///    如实回一句可读原因（<see cref="Message"/>）。
/// </summary>
public sealed record BiliStreamPair
{
    /// <summary>选中的视频流；null 表示一条都没选上（原因看 Message）。</summary>
    public BiliStream? Video { get; init; }
    /// <summary>选中的音频流；durl 退化路径是 null（那个文件本身就带声音）。</summary>
    public BiliStream? Audio { get; init; }
    /// <summary>上层给进来的 base 名，原样回带。这一层不算模板。</summary>
    public string FinalBaseName { get; init; } = "";
    /// <summary>true = DASH（要下两条、要合并）；false = durl 退化路径（一条完整 mp4）。</summary>
    public bool IsDash { get; init; } = true;
    /// <summary>实际选中的画质档位号（qn），0 = 没选上。</summary>
    public int VideoQn { get; init; }
    /// <summary>实际选中的编码族（AVC / HEVC / AV1），认不出来为空串。</summary>
    public string VideoCodec { get; init; } = "";
    /// <summary>不可用时给用户看的一句话原因；可用时是 null。</summary>
    public string? Message { get; init; }

    /// <summary>能不能拿去入队。</summary>
    public bool Usable => Message is null && Video is not null && (!IsDash || Audio is not null);

    /// <summary>需不需要走合并。durl 退化路径拿到的是完整 mp4，合并那一步整段跳过。</summary>
    public bool NeedsMerge => Usable && IsDash && Audio is not null;
}

/// <summary>
/// 「一条分 P 到底下哪两条流」的决策层 —— **全部纯函数，不打网络、不读设置、不看 cookie**。
/// 从 Flutter 版 bili_download_plan.dart 移植（那份 401 行）。
///
/// 为什么单独一层：画质上限与编码偏好在 API 层里没有落点 —— API 只负责把响应摊平成
/// 有序列表，而下载要的是「这次就取这两条」。把这段判断分出来才能离线逐条钉住。
/// </summary>
public static class BiliDownloadPlan
{
    // ── 落名契约 ──────────────────────────────────────────
    //
    // **固定形状**：配对与重启重建都靠认这两个后缀。改这里等于改契约，
    // BiliMergePipeline 的配对扫描跟着一起变。

    /// <summary>视频流那条的临时名。</summary>
    public static string VideoStreamName(string outBase) => outBase + ".video.m4s";

    /// <summary>音频流那条的临时名。</summary>
    public static string AudioStreamName(string outBase) => outBase + ".audio.m4s";

    /// <summary>合并后的产物名 —— 扩展名跟着**容器**走（MKV 才装得下 ASS 字幕轨）。</summary>
    public static string MergedName(string outBase, BiliContainer container) =>
        outBase + "." + BiliConfig.IdOf(container);

    /// <summary>B 站 DASH 只有这几个形状。标题正文里的「冬.天」不会被误削。</summary>
    private static readonly string[] BiliTrailingExt = { ".m4s", ".mp4", ".mkv", ".m4a", ".aac", ".mp3", ".flac" };

    /// <summary>由模板渲染出来的完整文件名反推**不含扩展名**的 base 名。</summary>
    public static string BaseNameFromFileName(string fileName)
    {
        if (string.IsNullOrEmpty(fileName)) return "";
        var lower = fileName.ToLowerInvariant();
        foreach (var ext in BiliTrailingExt)
        {
            if (lower.EndsWith(ext, StringComparison.Ordinal))
                return fileName.Substring(0, fileName.Length - ext.Length);
        }
        return fileName;
    }

    // ── 选流 ─────────────────────────────────────────────

    /// <summary>
    /// 从一次 playurl 的结果里挑出这次的视频流与音频流。
    ///
    /// 视频：① 按上限 qn 裁掉超上限的档 → ② 取剩下的里**实际最高**档
    /// → ③ 同档位内按编码偏好取 → ④ 还并列就比码率。
    ///
    /// 第 ② 步那个「裁完是空的」的分支必须存在：账号权限低于用户选的上限时，
    /// 上限本身筛不出任何流，硬要按上限判失败就等于「用户选了 8K 就什么都下不了」。
    ///
    /// 音频：取**码率最高**的那条。
    /// </summary>
    public static BiliStreamPair Plan(
        BiliPlayInfo r, BiliQuality quality, BiliCodec codec, string baseName = "")
    {
        // durl 退化路径：老稿件没有 dash，给的本来就是能直接播的完整 mp4。
        if (!r.IsDash)
        {
            var segments = r.Videos.Where(s => !string.IsNullOrEmpty(s.Url)).ToList();
            if (segments.Count == 0)
            {
                return new BiliStreamPair
                {
                    IsDash = false,
                    FinalBaseName = baseName,
                    Message = "这个稿件没给出可下载的完整文件（durl 为空）。" +
                              "更高画质通常需要登录或大会员凭据。",
                };
            }
            // 分段稿件要按顺序拼成一个 mp4，本期不做：只下第一段会拿到
            // 一个「能打开但只有前几分钟」的假成功 —— 比明确报错更坏。
            if (segments.Count > 1)
            {
                return new BiliStreamPair
                {
                    IsDash = false,
                    FinalBaseName = baseName,
                    Message = "这个稿件的老格式下载被切成 " + segments.Count + " 段，" +
                              "本期还不做分段拼接，直接下会拿到不完整的视频。",
                };
            }
            var s = segments[0];
            return new BiliStreamPair
            {
                Video = s,
                FinalBaseName = baseName,
                IsDash = false,
                VideoQn = s.QualityId,
                VideoCodec = s.Codec,
            };
        }

        var usable = r.Videos.Where(s => !string.IsNullOrEmpty(s.Url)).ToList();
        if (usable.Count == 0)
        {
            return new BiliStreamPair
            {
                FinalBaseName = baseName,
                Message = "没取到任何可用的视频流。这类稿件通常需要登录或大会员凭据。",
            };
        }

        var cap = BiliConfig.QnOf(quality);
        var inCap = usable.Where(s => s.QualityId <= cap).ToList();
        var pool = inCap.Count == 0 ? usable : inCap;

        var topQn = 0;
        foreach (var s in pool) if (s.QualityId > topQn) topQn = s.QualityId;
        var atQn = pool.Where(s => s.QualityId == topQn).ToList();

        // 同档位内的编码偏好排序。Auto 是「兼容性优先」：Windows 硬解覆盖面 AVC > HEVC > AV1；
        // 显式偏好排在自己那族之前，其余照兼容性顺序垫后 —— 这样「要 HEVC 但这档只有 AVC」时
        // 仍有流可下，而不是直接失败。
        var chosen = atQn
            .Select((s, i) => (Rank: CodecRank(codec, s.Codec), Idx: i, Stream: s))
            .OrderBy(t => t.Rank)
            .ThenByDescending(t => t.Stream.Bitrate)
            .ThenBy(t => t.Idx)
            .First().Stream;

        var audios = r.Audios.Where(s => !string.IsNullOrEmpty(s.Url)).ToList();
        if (audios.Count == 0)
        {
            // DASH 的视频流单独不是可播放文件：只下它等于下一个 0 秒的空壳。
            return new BiliStreamPair
            {
                Video = chosen,
                FinalBaseName = baseName,
                VideoQn = chosen.QualityId,
                VideoCodec = chosen.Codec,
                Message = "这个稿件的音频流需要登录或大会员凭据才能取到，" +
                          "而 DASH 的视频流单独不能播放，本期不支持只下一半。",
            };
        }
        // 取码率最高的那条：同一档位的镜像地址码率相同，不同档位之间码率单调，
        // 用码率当判据既不用查表，也不会因为 B 站新增音质档而漏排。
        var best = audios[0];
        foreach (var s in audios) if (s.Bitrate > best.Bitrate) best = s;

        return new BiliStreamPair
        {
            Video = chosen,
            Audio = best,
            FinalBaseName = baseName,
            IsDash = true,
            VideoQn = chosen.QualityId,
            VideoCodec = chosen.Codec,
        };
    }

    /// <summary>
    /// 编码偏好 → 排序序号（0 最优先）。
    ///
    /// 非偏好族仍然保留兼容性顺序（AVC > HEVC > AV1），偏好只在「有它」时赢。
    /// **显式偏好落空时不该判失败**：用户要 HEVC 而这一档只有 AVC 时，
    /// 拿到 AVC 是「按他选的清晰度、换个编码」，直接不下才是真的没道理。
    /// </summary>
    public static int CodecRank(BiliCodec prefer, string? actual)
    {
        if (string.IsNullOrEmpty(actual)) return 8; // 认不出编码的流排最后，但不至于判不可用
        var compat = actual switch
        {
            "AVC" => 1,
            "HEVC" => 2,
            "AV1" => 3,
            _ => 4,
        };
        if (prefer == BiliCodec.Auto) return compat;
        var want = prefer switch { BiliCodec.Avc => "AVC", BiliCodec.Hevc => "HEVC", BiliCodec.Av1 => "AV1", _ => "" };
        return want.Length > 0 && actual == want ? 0 : compat;
    }
}

/// <summary>选流决策自测 —— 纯离线，不联网。</summary>
public static class BiliDownloadPlanSelfTest
{
    private static BiliStream V(int qn, string codec, long bitrate, int idx) => new BiliStream
    {
        Url = "https://example.invalid/v" + qn + "-" + codec + "-" + idx,
        QualityId = qn,
        QualityLabel = BiliApi.QualityNames.TryGetValue(qn, out var l) ? l : ("Q" + qn),
        Codec = codec,
        Bitrate = bitrate,
    };

    private static BiliStream A(int id, long bitrate) => new BiliStream
    {
        Url = "https://example.invalid/a" + id,
        QualityId = id,
        QualityLabel = BiliApi.AudioNames.TryGetValue(id, out var l) ? l : ("A" + id),
        Bitrate = bitrate,
        IsAudio = true,
    };

    private static BiliPlayInfo Dash(IEnumerable<BiliStream> v, IEnumerable<BiliStream> a) =>
        new BiliPlayInfo { Cid = 1, IsDash = true, Videos = v.ToList(), Audios = a.ToList() };

    public static string Run()
    {
        var sb = new StringBuilder();
        var pass = 0; var fail = 0;
        void Check(string name, bool ok, string detail = "")
        {
            if (ok) { pass++; sb.AppendLine("  PASS  " + name); }
            else { fail++; sb.AppendLine("  FAIL  " + name + (detail.Length > 0 ? "  " + detail : "")); }
        }

        var audio = A(30280, 320000);

        // ① 上限裁剪：1080P 上限 + 8K/1080P/720P 三档 → 取 1080P
        var r1 = BiliDownloadPlan.Plan(
            Dash(new[] { V(127, "AVC", 9000, 0), V(80, "AVC", 3000, 1), V(64, "AVC", 1500, 2) },
                 new[] { audio }),
            BiliQuality.Q1080P, BiliCodec.Auto);
        Check("上限 1080P 取到 1080P", r1.VideoQn == 80, "got " + r1.VideoQn);
        Check("上限裁剪后仍要合并", r1.NeedsMerge);
        Check("无失败消息", r1.Message is null, r1.Message ?? "");

        // ② 上限裁完是空的 → 退回实际最高（不是失败）
        var r2 = BiliDownloadPlan.Plan(
            Dash(new[] { V(32, "AVC", 500, 0) }, new[] { audio }),
            BiliQuality.Q1080P60, BiliCodec.Auto);
        Check("裁空后退化到实际最高档", r2.Usable && r2.VideoQn == 32, "qn=" + r2.VideoQn);

        // ③ 编码偏好：同档有 AVC/HEVC/AV1 时，要 HEVC 就拿 HEVC
        var r3 = BiliDownloadPlan.Plan(
            Dash(new[] { V(80, "AVC", 3000, 0), V(80, "HEVC", 2000, 1), V(80, "AV1", 1200, 2) },
                 new[] { audio }),
            BiliQuality.Highest, BiliCodec.Hevc);
        Check("偏好 HEVC 拿到 HEVC", r3.VideoCodec == "HEVC", r3.VideoCodec);

        // ④ Auto = 兼容性优先 = 先 AVC
        var r4 = BiliDownloadPlan.Plan(
            Dash(new[] { V(80, "AV1", 5000, 0), V(80, "AVC", 3000, 1) }, new[] { audio }),
            BiliQuality.Highest, BiliCodec.Auto);
        Check("Auto 优先 AVC（不是最高码率）", r4.VideoCodec == "AVC", r4.VideoCodec);

        // ⑤ 偏好落空时降级而非失败
        var r5 = BiliDownloadPlan.Plan(
            Dash(new[] { V(80, "AVC", 3000, 0) }, new[] { audio }),
            BiliQuality.Highest, BiliCodec.Av1);
        Check("偏好 AV1 落空退回 AVC 且可用", r5.Usable && r5.VideoCodec == "AVC", r5.VideoCodec);

        // ⑥ 同编码同档位时比码率
        var r6 = BiliDownloadPlan.Plan(
            Dash(new[] { V(80, "AVC", 2000, 0), V(80, "AVC", 4000, 1) }, new[] { audio }),
            BiliQuality.Highest, BiliCodec.Auto);
        Check("同编码比码率取高", r6.Video is not null && r6.Video.Bitrate == 4000, r6.Video?.Bitrate.ToString() ?? "");

        // ⑦ 音频取码率最高（不是 id 最大也不是列表第一条）
        var r7 = BiliDownloadPlan.Plan(
            Dash(new[] { V(80, "AVC", 3000, 0) },
                 new[] { A(30216, 64000), A(30280, 320000), A(30232, 132000) }),
            BiliQuality.Highest, BiliCodec.Auto);
        Check("音频取码率最高", r7.Audio?.QualityId == 30280, r7.Audio?.QualityId.ToString() ?? "");

        // ⑧ 没有音频流 → 明确报不可用（不能下一个 0 秒空壳）
        var r8 = BiliDownloadPlan.Plan(
            Dash(new[] { V(80, "AVC", 3000, 0) }, Array.Empty<BiliStream>()),
            BiliQuality.Highest, BiliCodec.Auto);
        Check("无音频流时判不可用", !r8.Usable && r8.Message is not null, r8.Message ?? "");

        // ⑨ 没有任何视频流
        var r9 = BiliDownloadPlan.Plan(
            new BiliPlayInfo { Cid = 1, IsDash = true },
            BiliQuality.Highest, BiliCodec.Auto);
        Check("无视频流时判不可用", !r9.Usable && r9.Message is not null);

        // ⑩ durl 退化路径：单段完整 mp4，不需要合并
        var r10 = BiliDownloadPlan.Plan(
            new BiliPlayInfo
            {
                Cid = 1,
                IsDash = false,
                Videos = new[] { new BiliStream { Url = "https://example.invalid/durl", QualityId = 32, QualityLabel = "原始" } },
            },
            BiliQuality.Highest, BiliCodec.Auto);
        Check("durl 单段可用且不需要合并", r10.Usable && !r10.NeedsMerge);

        // ⑪ durl 多段 → 明确报「不做分段拼接」
        var r11 = BiliDownloadPlan.Plan(
            new BiliPlayInfo
            {
                Cid = 1,
                IsDash = false,
                Videos = new[]
                {
                    new BiliStream { Url = "https://example.invalid/d1" },
                    new BiliStream { Url = "https://example.invalid/d2" },
                },
            },
            BiliQuality.Highest, BiliCodec.Auto);
        Check("durl 多段报不可用", !r11.Usable && (r11.Message?.Contains("段") ?? false));

        // ⑫ 落名契约
        Check("视频流名", BiliDownloadPlan.VideoStreamName("冬天-1080P") == "冬天-1080P.video.m4s");
        Check("音频流名", BiliDownloadPlan.AudioStreamName("冬天-1080P") == "冬天-1080P.audio.m4s");
        Check("mp4 产物名", BiliDownloadPlan.MergedName("冬天-1080P", BiliContainer.Mp4) == "冬天-1080P.mp4");
        Check("mkv 产物名", BiliDownloadPlan.MergedName("冬天-1080P", BiliContainer.Mkv) == "冬天-1080P.mkv");
        Check("反推 base 名", BiliDownloadPlan.BaseNameFromFileName("冬天-1080P.m4s") == "冬天-1080P");
        Check("反推 base 名（标题里带点不误削）",
            BiliDownloadPlan.BaseNameFromFileName("冬.天.mp4") == "冬.天",
            BiliDownloadPlan.BaseNameFromFileName("冬.天.mp4"));
        Check("反推 base 名（无扩展名原样）", BiliDownloadPlan.BaseNameFromFileName("冬天") == "冬天");

        sb.AppendLine();
        sb.AppendLine("BiliDownloadPlan 合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}
