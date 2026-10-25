using System;
using System.Collections.Generic;
using System.Linq;

namespace ParseDl.Services.Douyin;

/// <summary>抖音的下载源 —— 对齐 Flutter 版 lib/models/douyin_config.dart 的 6 个档位。</summary>
public enum DouyinSource
{
    /// <summary>默认播放地址（video.play_addr）</summary>
    DefaultAddr,
    /// <summary>指定 H.264</summary>
    H264,
    /// <summary>指定 H.265</summary>
    H265,
    /// <summary>兼容性+质量优先（排除 ByteVC1）</summary>
    QualityFirst,
    /// <summary>最高质量优先（含 ByteVC1）</summary>
    QualityFirstBytevc1,
    /// <summary>仅音频 —— 取该作品的 BGM，不是从视频里抽音轨</summary>
    AudioOnly,
}

/// <summary>质量优先策略四档。</summary>
public enum DouyinQualityMode { Auto, Resolution, Bitrate, Fps }

/// <summary>图文作品的图片格式偏好。</summary>
public enum DouyinImageFormat { Keep, JpgFirst }

/// <summary>媒体类型。</summary>
public enum DouyinMediaType { Video, Image, Audio }

/// <summary>媒体变体的来源类别（对应 Flutter 版 VariantKind）。</summary>
public enum DouyinVariantKind
{
    /// <summary>bit_rate[] 里的码率变体（参与质量评分）</summary>
    BitRate,
    /// <summary>video.play_addr</summary>
    DefaultAddr,
    /// <summary>video.play_addr_h264</summary>
    H264,
    /// <summary>video.play_addr_265</summary>
    H265,
    /// <summary>video.download_addr</summary>
    Download,
    /// <summary>图集镜像</summary>
    Image,
    /// <summary>BGM</summary>
    Audio,
}

/// <summary>标签匹配模式。</summary>
public enum DouyinTagMode { Any, All }

/// <summary>日期快捷范围（下拉里那几项）。</summary>
public enum DouyinDateRange { None, Last7, Last30, Last90, Last180, Last365 }

/// <summary>枚举 ↔ 持久化字符串 / 中文标签的对照表。</summary>
public static class DouyinEnumText
{
    public static string Id(this DouyinSource s) => s switch
    {
        DouyinSource.DefaultAddr => "default",
        DouyinSource.H264 => "h264",
        DouyinSource.H265 => "h265",
        DouyinSource.QualityFirst => "quality_first",
        DouyinSource.QualityFirstBytevc1 => "quality_first_bytevc1",
        _ => "audio_only",
    };

    public static string Label(this DouyinSource s) => s switch
    {
        DouyinSource.DefaultAddr => "视频（默认）",
        DouyinSource.H264 => "下载地址 (H.264)",
        DouyinSource.H265 => "下载地址 (H.265)",
        DouyinSource.QualityFirst => "下载地址 (兼容性+质量优先) (H.265/H.264)",
        DouyinSource.QualityFirstBytevc1 => "下载地址 (最高质量优先) (ByteVC1/H.265/H.264)",
        _ => "下载地址（仅音频）",
    };

    /// <summary>只有「质量优先」两档才显示「质量优先策略」下拉。</summary>
    public static bool NeedsQualityMode(this DouyinSource s)
        => s is DouyinSource.QualityFirst or DouyinSource.QualityFirstBytevc1;

    public static DouyinSource SourceFromId(string? id) => id switch
    {
        "h264" => DouyinSource.H264,
        "h265" => DouyinSource.H265,
        "quality_first" => DouyinSource.QualityFirst,
        "quality_first_bytevc1" => DouyinSource.QualityFirstBytevc1,
        "audio_only" => DouyinSource.AudioOnly,
        _ => DouyinSource.DefaultAddr,
    };

    public static string Id(this DouyinQualityMode m) => m switch
    {
        DouyinQualityMode.Auto => "auto",
        DouyinQualityMode.Resolution => "resolution",
        DouyinQualityMode.Bitrate => "bitrate",
        _ => "fps",
    };

    public static string Label(this DouyinQualityMode m) => m switch
    {
        DouyinQualityMode.Auto => "自动（推荐）",
        DouyinQualityMode.Resolution => "分辨率优先",
        DouyinQualityMode.Bitrate => "比特率优先",
        _ => "帧率优先",
    };

    public static DouyinQualityMode QualityModeFromId(string? id) => id switch
    {
        "resolution" => DouyinQualityMode.Resolution,
        "bitrate" => DouyinQualityMode.Bitrate,
        "fps" => DouyinQualityMode.Fps,
        _ => DouyinQualityMode.Auto,
    };

    public static string Id(this DouyinImageFormat f)
        => f == DouyinImageFormat.JpgFirst ? "jpg" : "webp";

    public static string Label(this DouyinImageFormat f)
        => f == DouyinImageFormat.JpgFirst ? "其它格式优先（jpg）" : "默认（webp）";

    public static DouyinImageFormat ImageFormatFromId(string? id)
        => id == "jpg" ? DouyinImageFormat.JpgFirst : DouyinImageFormat.Keep;

    public static string Id(this DouyinDateRange r) => r switch
    {
        DouyinDateRange.Last7 => "7",
        DouyinDateRange.Last30 => "30",
        DouyinDateRange.Last90 => "90",
        DouyinDateRange.Last180 => "180",
        DouyinDateRange.Last365 => "365",
        _ => "",
    };

    public static string Label(this DouyinDateRange r) => r switch
    {
        DouyinDateRange.Last7 => "最近7天",
        DouyinDateRange.Last30 => "最近30天",
        DouyinDateRange.Last90 => "最近90天",
        DouyinDateRange.Last180 => "最近半年",
        DouyinDateRange.Last365 => "最近一年",
        _ => "不限",
    };

    public static DouyinDateRange DateRangeFromId(string? id) => id switch
    {
        "7" => DouyinDateRange.Last7,
        "30" => DouyinDateRange.Last30,
        "90" => DouyinDateRange.Last90,
        "180" => DouyinDateRange.Last180,
        "365" => DouyinDateRange.Last365,
        _ => DouyinDateRange.None,
    };

    /// <summary>该范围对应的起止时刻（含今天）；<see cref="DouyinDateRange.None"/> 返回 null。</summary>
    public static (DateTime Start, DateTime End)? Resolve(this DouyinDateRange r, DateTime now)
    {
        if (r == DouyinDateRange.None) return null;
        if (!int.TryParse(r.Id(), out var days) || days <= 0) return null;
        var start = now.Date.AddDays(-(days - 1));
        var end = now.Date.AddDays(1).AddTicks(-1);
        return (start, end);
    }

    public static string Label(this DouyinTagMode m) => m == DouyinTagMode.All ? "全部" : "任一";
}
