using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ParseDl.Services.Bili;

/// <summary>画质上限 —— 与 B 站 qn 取值对齐，实际拿到哪档由账号权限决定。</summary>
public enum BiliQuality
{
    Highest = 0,
    Q8K,
    Q4K,
    Q1080P60,
    Q1080P,
    Q720P,
    Q480P,
    Q360P,
}

/// <summary>编码偏好。同画质常同时给 AVC / HEVC / AV1，选哪条影响能否合并与兼容性，不影响清晰度。</summary>
public enum BiliCodec
{
    Auto = 0,
    Avc,
    Hevc,
    Av1,
}

/// <summary>合并产物容器。MKV 相对 MP4 的唯一硬优势是装得下 ASS 字幕轨。</summary>
public enum BiliContainer
{
    Mp4 = 0,
    Mkv,
}

/// <summary>弹幕落盘格式。只有 ASS 能作为字幕轨内封进 MKV。</summary>
public enum BiliDanmakuFormat
{
    Ass = 0,
    Xml,
    Json,
}

/// <summary>字幕落盘格式。同样只有 ASS 谈得上内封。</summary>
public enum BiliSubtitleFormat
{
    Srt = 0,
    Ass,
    Txt,
}

/// <summary>封面格式 —— 走 B 站图床的后缀缩放语法（@.jpg 之类），不本地转码。</summary>
public enum BiliCoverFormat
{
    Jpg = 0,
    Png,
    Webp,
    Avif,
}

/// <summary>元数据格式。nfo 给媒体库读，json 是原样存一份解析结果。</summary>
public enum BiliMetadataFormat
{
    Json = 0,
    Nfo,
}

/// <summary>弹幕轨与字幕轨撞在一起时谁排前面。</summary>
public enum BiliTrackPriority
{
    DanmakuFirst = 0,
    SubtitleFirst,
}

/// <summary>
/// B 站下载配置 —— 从 Flutter 版 lib/models/bili_config.dart 移植。
///
/// 落盘位置刻意**独立**于全局 settings.json（userdata\bili_settings.json）：
/// B 站这一族选项比其它模块多得多（画质 / 编码 / 容器 / 五类附加文件 / 轨序），
/// 塞进共享字典里会让并行的其它模块每加一个字段就互相冲一次写盘。
///
/// ⚠️ **与 Flutter 版的一处有意偏差**：Flutter 版刻意不落盘 cookie（登录态只活在
/// WebView2 会话里），本版把 cookie 写进这个文件 —— 因为 WinUI 版还没有常驻
/// WebView2 会话，登录态目前只能靠这份文件跨页共享。这条偏差在任务报告里如实
/// 列出，是已知的待收口项（要么接 WebView2 会话，要么改加密存储）。
/// </summary>
public sealed class BiliConfig
{
    public static BiliConfig Instance { get; } = new();

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new JsonStringEnumConverter() },
    };

    // ── 取流 ────────────────────────────────────────────
    /// <summary>画质**上限**（不是档位）：B 站按账号权限在 support_formats 里裁掉拿不到的档。</summary>
    public BiliQuality Quality { get; set; } = BiliQuality.Highest;
    /// <summary>编码偏好。Auto = 兼容性优先（AVC > HEVC > AV1）。</summary>
    public BiliCodec Codec { get; set; } = BiliCodec.Auto;
    /// <summary>音轨上限。0 = 最高可用。</summary>
    public int AudioQualityId { get; set; }
    /// <summary>只取音轨（适合听歌）。</summary>
    public bool AudioOnly { get; set; }

    // ── 合并 ────────────────────────────────────────────
    /// <summary>下载完成后**自动**合并（对齐 Flutter 版 mergeAfterDownload）。</summary>
    public bool MergeAfterDownload { get; set; } = true;
    /// <summary>合并成功后删掉两条原始流。</summary>
    public bool DeleteStreamsAfterMerge { get; set; } = true;
    /// <summary>产物容器。</summary>
    public BiliContainer Container { get; set; } = BiliContainer.Mp4;

    // ── 附加文件 ────────────────────────────────────────
    public bool SaveDanmaku { get; set; } = true;
    public BiliDanmakuFormat DanmakuFormat { get; set; } = BiliDanmakuFormat.Xml;
    public bool SaveSubtitle { get; set; }
    public BiliSubtitleFormat SubtitleFormat { get; set; } = BiliSubtitleFormat.Srt;
    public bool SaveCover { get; set; }
    public BiliCoverFormat CoverFormat { get; set; } = BiliCoverFormat.Jpg;
    public bool SaveChapter { get; set; }
    public bool SaveMetadata { get; set; }
    public BiliMetadataFormat MetadataFormat { get; set; } = BiliMetadataFormat.Json;
    public BiliTrackPriority TrackPriority { get; set; } = BiliTrackPriority.SubtitleFirst;

    // ── 保存与命名 ──────────────────────────────────────
    public string SaveDir { get; set; } = "";
    /// <summary>命名模板。空 = 用 B 站默认（标题-BV号）。</summary>
    public string FileNameTemplate { get; set; } = "";
    public bool SkipDownloaded { get; set; } = true;
    public int RequestIntervalMs { get; set; } = 800;
    public int MaxConcurrent { get; set; } = 4;

    // ── 登录态 ──────────────────────────────────────────
    /// <summary>SESSDATA 等登录 cookie。空 = 未登录（只能取 480P）。</summary>
    public string Cookie { get; set; } = "";

    [JsonIgnore]
    public bool IsLoggedIn => !string.IsNullOrWhiteSpace(Cookie);

    [JsonIgnore]
    public string FilePath => Path.Combine(AppPaths.DataDir, "bili_settings.json");

    private void CopyFrom(BiliConfig o)
    {
        Quality = o.Quality;
        Codec = o.Codec;
        AudioQualityId = o.AudioQualityId;
        AudioOnly = o.AudioOnly;
        MergeAfterDownload = o.MergeAfterDownload;
        DeleteStreamsAfterMerge = o.DeleteStreamsAfterMerge;
        Container = o.Container;
        SaveDanmaku = o.SaveDanmaku;
        DanmakuFormat = o.DanmakuFormat;
        SaveSubtitle = o.SaveSubtitle;
        SubtitleFormat = o.SubtitleFormat;
        SaveCover = o.SaveCover;
        CoverFormat = o.CoverFormat;
        SaveChapter = o.SaveChapter;
        SaveMetadata = o.SaveMetadata;
        MetadataFormat = o.MetadataFormat;
        TrackPriority = o.TrackPriority;
        SaveDir = o.SaveDir;
        FileNameTemplate = o.FileNameTemplate;
        SkipDownloaded = o.SkipDownloaded;
        RequestIntervalMs = o.RequestIntervalMs;
        MaxConcurrent = o.MaxConcurrent;
        Cookie = o.Cookie;
    }

    public void Load()
    {
        try
        {
            var path = FilePath;
            if (!File.Exists(path)) return;
            var json = File.ReadAllText(path);
            var loaded = JsonSerializer.Deserialize<BiliConfig>(json, JsonOpts);
            if (loaded is not null) CopyFrom(loaded);
        }
        catch (Exception ex)
        {
            // 坏文件留证据，不静默吞掉
            try { File.Copy(FilePath, FilePath + ".bad", overwrite: true); } catch { }
            Aria2Engine.Log("[BiliConfig] 读取失败，使用默认值：" + ex.Message);
        }
    }

    /// <summary>原子写盘（先 .tmp 再替换）。</summary>
    public void Save()
    {
        try
        {
            var path = FilePath;
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, JsonOpts));
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[BiliConfig] 保存失败：" + ex.Message);
        }
    }

    /// <summary>实际保存目录：模块设置留空则落全局默认目录。</summary>
    public string ResolvedSaveDir =>
        string.IsNullOrWhiteSpace(SaveDir) ? Aria2Engine.DefaultDir() : SaveDir;

    // ── 档位 ↔ id 的映射（qnn 表与 B 站一致）─────────────
    public static int QnOf(BiliQuality q) => q switch
    {
        BiliQuality.Q8K => 127,
        BiliQuality.Q4K => 120,
        BiliQuality.Q1080P60 => 116,
        BiliQuality.Q1080P => 80,
        BiliQuality.Q720P => 64,
        BiliQuality.Q480P => 32,
        BiliQuality.Q360P => 16,
        _ => 127, // Highest
    };

    public static string LabelOf(BiliQuality q) => q switch
    {
        BiliQuality.Q8K => "8K",
        BiliQuality.Q4K => "4K",
        BiliQuality.Q1080P60 => "1080P 60帧",
        BiliQuality.Q1080P => "1080P",
        BiliQuality.Q720P => "720P",
        BiliQuality.Q480P => "480P",
        BiliQuality.Q360P => "360P",
        _ => "最高可用",
    };

    public static string IdOf(BiliContainer c) => c == BiliContainer.Mkv ? "mkv" : "mp4";
}

/// <summary>B 站配置自测 —— 纯离线。</summary>
public static class BiliConfigSelfTest
{
    public static string Run()
    {
        var sb = new StringBuilder();
        var pass = 0; var fail = 0;
        void Check(string name, bool ok, string detail = "")
        {
            if (ok) { pass++; sb.AppendLine("  PASS  " + name); }
            else { fail++; sb.AppendLine("  FAIL  " + name + (detail.Length > 0 ? "  " + detail : "")); }
        }

        Check("Highest → qn 127", BiliConfig.QnOf(BiliQuality.Highest) == 127);
        Check("1080P60 → qn 116", BiliConfig.QnOf(BiliQuality.Q1080P60) == 116);
        Check("1080P → qn 80", BiliConfig.QnOf(BiliQuality.Q1080P) == 80);
        Check("720P → qn 64", BiliConfig.QnOf(BiliQuality.Q720P) == 64);
        Check("480P → qn 32", BiliConfig.QnOf(BiliQuality.Q480P) == 32);
        Check("360P → qn 16", BiliConfig.QnOf(BiliQuality.Q360P) == 16);
        Check("容器扩展名 mp4", BiliConfig.IdOf(BiliContainer.Mp4) == "mp4");
        Check("容器扩展名 mkv", BiliConfig.IdOf(BiliContainer.Mkv) == "mkv");

        sb.AppendLine();
        sb.AppendLine("BiliConfig 合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}
