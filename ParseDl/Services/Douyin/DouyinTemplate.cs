using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace ParseDl.Services.Douyin;

/// <summary>
/// 一个可用的模板变量（设置页「可用变量」表用）。
///
/// ParamExample / ParamDesc 对应 Flutter 版 TemplateVar.params 的第一个参数：
/// 前者是「参数=默认值」的写法（如 d=0），后者是中文说明（如「仅日期（0 或 1）」）。
/// 两个都空表示该变量不带参数。设置页的「参数格式」提示行与每行说明都由它们生成。
/// </summary>
public sealed record DouyinTemplateVar(
    string Name,
    string Desc,
    string ParamExample = "",
    string ParamDesc = "")
{
    /// <summary>插入模板时用的完整记号（含首尾百分号）。</summary>
    public string Token => "%" + Name + "%";
}

/// <summary>
/// 抖音侧的文件名 / 文件夹模板 —— 变量表与格式化规则逐条对齐 Flutter 版
/// lib/services/file_name_template.dart 的抖音段（19 个变量）。
///
/// 为什么独立一份而不复用 Services/FileNameTemplate.cs：那份是 X 侧变量
/// （%POST_ID% / %CONTENT% …），两个平台的变量表刻意不混（用户会在 X 设置里
/// 看到抖音术语）。这里只实现抖音变量 + 三个中性变量。
/// </summary>
public static class DouyinTemplate
{
    /// <summary>当前默认文件名模板。</summary>
    public const string DefaultFileNameTemplate =
        "%AUTHOR%_%CREATE_TIME,d=1%_%DESCRIPTION%%IMAGE_INDEX%%EXT%";

    /// <summary>3.6 之前的默认模板（只用于识别「用户从没改过」）。</summary>
    public const string LegacyFileNameTemplate = "%CREATE_TIME%_%DESCRIPTION%%EXT%";

    public const string CustomPresetId = "custom";

    public static readonly IReadOnlyList<DouyinTemplatePreset> Presets = new[]
    {
        new DouyinTemplatePreset("author", "按作者分文件夹（推荐）", "%AUTHOR%", DefaultFileNameTemplate),
        new DouyinTemplatePreset("author_date", "按「作者 / 日期」两级文件夹", "%AUTHOR%/%CREATE_TIME,d=1%", "%DESCRIPTION%%EXT%"),
        new DouyinTemplatePreset("flat", "全部平铺（不建子文件夹）", "", "%CREATE_TIME%_%AUTHOR%_%DESCRIPTION%%EXT%"),
        new DouyinTemplatePreset("aweme", "按作品 ID 分文件夹", "%AWEME_ID%", "%DESCRIPTION%%EXT%"),
    };

    /// <summary>
    /// 「可用变量」表 —— 顺序固定，与 Flutter 版 kDouyinTemplateVars 逐条一致
    /// （即 kAllTemplateVars 过滤 kDouyinVarNames 之后的顺序，共 20 个）。
    ///
    /// 术语只含抖音语义 + 三个中性变量（资源索引 / 媒体类型 / 扩展名），
    /// 不会出现推文、用户名这类 X 术语。
    /// </summary>
    public static readonly IReadOnlyList<DouyinTemplateVar> Vars = new[]
    {
        new DouyinTemplateVar("AUTHOR", "作者（@昵称）"),
        new DouyinTemplateVar("AUTHOR_ID", "作者 ID"),
        new DouyinTemplateVar("AUTHOR_UNIQUE_ID", "抖音号"),
        new DouyinTemplateVar("CREATE_TIME", "创建时间（YYYYMMDDHHmmss）", "d=0", "仅日期（0 或 1）"),
        new DouyinTemplateVar("DESCRIPTION", "作品描述", "t=25", "最大长度（1~120）"),
        new DouyinTemplateVar("IMAGE_INDEX", "图集序号（0 起，作品主视频不带）"),
        new DouyinTemplateVar("AWEME_ID", "作品 ID"),
        new DouyinTemplateVar("CUSTOM_TEXT", "自定义文本"),
        new DouyinTemplateVar("RESOLUTION", "分辨率（WxH）"),
        new DouyinTemplateVar("BITRATE", "比特率"),
        new DouyinTemplateVar("FPS", "帧率"),
        new DouyinTemplateVar("DURATION", "时长"),
        new DouyinTemplateVar("FILE_SIZE", "文件大小"),
        new DouyinTemplateVar("LIKE_COUNT", "点赞数"),
        new DouyinTemplateVar("COMMENT_COUNT", "评论数"),
        new DouyinTemplateVar("COLLECT_COUNT", "收藏数"),
        new DouyinTemplateVar("SHARE_COUNT", "分享数"),
        new DouyinTemplateVar("MEDIA_INDEX", "资源索引"),
        new DouyinTemplateVar("MEDIA_TYPE", "媒体类型"),
        new DouyinTemplateVar("EXT", "扩展名"),
    };

    /// <summary>该模板匹配哪个预设（不匹配返回 custom）。</summary>
    public static string PresetIdOf(string dirTemplate, string fileTemplate)
    {
        foreach (var p in Presets)
            if (p.DirTemplate == dirTemplate && p.FileNameTemplate == fileTemplate) return p.Id;
        return CustomPresetId;
    }

    // ── 展开 ────────────────────────────────────────────────

    private const string SegmentMark = "\u0001";
    private const byte Pct = 0x25;

    /// <summary>
    /// 把模板里的 %VAR% 全部替换成实际值，并处理可选段 &lt;...&gt;。
    /// 未知变量原样保留（不静默吃掉，用户拼错能看出来）。
    /// </summary>
    public static string Expand(string template, DouyinItem item)
    {
        if (string.IsNullOrEmpty(template)) return "";

        var segments = new List<string>();
        // 先摘出成对的可选段：只扫模板，不扫注入结果
        var text = Regex.Replace(template, "<([^<>]*)>", m =>
        {
            var segBody = "";
            try { segBody = ExpandCore(m.Groups[1].Value, item, strict: true); }
            catch (OptionalSegmentEmpty) { segBody = ""; }
            segments.Add(segBody);
            return SegmentMark + (segments.Count - 1) + SegmentMark;
        });

        text = ExpandCore(text, item, strict: false);

        if (segments.Count > 0)
        {
            text = Regex.Replace(text, SegmentMark + "([0-9]+)" + SegmentMark,
                m => segments[int.Parse(m.Groups[1].Value)]);
        }
        return text;
    }

    private sealed class OptionalSegmentEmpty : Exception { }

    private static string ExpandCore(string tpl, DouyinItem item, bool strict)
    {
        var sb = new StringBuilder();
        var i = 0;
        while (i < tpl.Length)
        {
            var open = tpl.IndexOf((char)Pct, i);
            if (open < 0) { sb.Append(tpl, i, tpl.Length - i); break; }
            sb.Append(tpl, i, open - i);

            var close = tpl.IndexOf((char)Pct, open + 1);
            if (close < 0) { sb.Append(tpl, open, tpl.Length - open); break; }

            var body = tpl.Substring(open + 1, close - open - 1);
            var name = body;
            string? rawParams = null;
            var comma = body.IndexOf((char)44);
            if (comma >= 0)
            {
                name = body[..comma];
                rawParams = body[comma..];
            }

            var raw = Lookup(name, item, ParseParams(rawParams));
            if (raw is null)
            {
                sb.Append(tpl, open, close - open + 1);
            }
            else
            {
                if (strict && string.IsNullOrEmpty(raw)) throw new OptionalSegmentEmpty();
                sb.Append(raw);
            }
            i = close + 1;
        }
        return sb.ToString();
    }

    private static Dictionary<string, string> ParseParams(string? raw)
    {
        var d = new Dictionary<string, string>();
        if (string.IsNullOrEmpty(raw)) return d;
        foreach (var part in raw.TrimStart((char)44).Split((char)44))
        {
            var i = part.IndexOf((char)61);
            if (i <= 0) continue;
            d[part[..i]] = part[(i + 1)..];
        }
        return d;
    }

    private static string? Lookup(string name, DouyinItem m, Dictionary<string, string> p)
    {
        switch (name.ToUpperInvariant())
        {
            case "AUTHOR":
                return "@" + (string.IsNullOrEmpty(m.UserName) ? "unknown_author" : m.UserName);
            case "AUTHOR_ID": return m.UserId ?? "";
            case "AUTHOR_UNIQUE_ID": return m.AuthorUniqueId ?? "";
            case "CREATE_TIME": return FormatCreateTime(m.CreatedAt, p.TryGetValue("d", out var dd) && dd == "1");
            case "DESCRIPTION": return Description(m, p);
            case "AWEME_ID": return m.PostId;
            case "CUSTOM_TEXT": return m.CustomText ?? "";
            case "IMAGE_INDEX": return IsMainVideo(m) ? "" : "_" + (m.MediaIndex - 1).ToString(CultureInfo.InvariantCulture);
            case "RESOLUTION": return ResolutionText(m);
            case "BITRATE":
                var br = m.Chosen?.Bitrate ?? 0;
                return br > 0 ? (br / 1000) + "Kbps" : "";
            case "FPS":
                var fps = m.Chosen?.Fps ?? 0;
                return fps > 0 ? FpsText(fps) : "";
            case "DURATION": return FormatDurationSeconds(m.DurationMs / 1000);
            case "FILE_SIZE":
                var size = m.Chosen?.Size ?? 0;
                return size > 0 ? FormatFileSize(size) : "";
            case "LIKE_COUNT": return FormatStatCount(m.LikeCount) + "点赞";
            case "COMMENT_COUNT": return FormatStatCount(m.CommentCount) + "评论";
            case "COLLECT_COUNT": return FormatStatCount(m.CollectCount) + "收藏";
            case "SHARE_COUNT": return FormatStatCount(m.ShareCount) + "分享";
            case "MEDIA_INDEX": return m.MediaIndex.ToString(CultureInfo.InvariantCulture);
            case "MEDIA_TYPE":
                return m.Type switch
                {
                    DouyinMediaType.Image => "image",
                    DouyinMediaType.Audio => "audio",
                    _ => "video",
                };
            case "EXT":
                var e = ExtensionFor(m);
                return e;
            default: return null;
        }
    }

    /// <summary>作品主视频 = 视频且 id 等于作品 id（实况图的配对视频带 v 后缀，不算）。</summary>
    public static bool IsMainVideo(DouyinItem m)
        => m.Type == DouyinMediaType.Video && m.Id == m.PostId;

    /// <summary>%DESCRIPTION%：空描述用作品 id 兜底；超长截断补 ...（按 UTF-16 码元截，与外部实现对口径）。</summary>
    private static string Description(DouyinItem m, Dictionary<string, string> p)
    {
        var text = m.Text ?? "";
        if (text.Length == 0) return m.PostId;
        var limit = 25;
        if (p.TryGetValue("t", out var ts) && int.TryParse(ts, out var parsed))
            limit = parsed < 1 ? 1 : (parsed > 120 ? 120 : parsed);
        return text.Length <= limit ? text : text[..limit] + "...";
    }

    public static string ResolutionText(DouyinItem m)
    {
        var c = m.Chosen;
        if (c is not null && c.Width > 0 && c.Height > 0) return c.Width + "x" + c.Height;
        return (m.Width > 0 && m.Height > 0) ? m.Width + "x" + m.Height : "";
    }

    /// <summary>扩展名（含点）：视频 mp4 / 音频 mp3 / 图片看链接后缀。</summary>
    public static string ExtensionFor(DouyinItem m)
    {
        if (m.Type == DouyinMediaType.Video) return ".mp4";
        if (m.Type == DouyinMediaType.Audio) return ".mp3";
        var url = m.Url;
        if (!string.IsNullOrEmpty(url))
        {
            var noQuery = url.Split('?')[0];
            var dot = noQuery.LastIndexOf('.');
            if (dot >= 0 && dot < noQuery.Length - 1)
            {
                var tail = noQuery[(dot + 1)..];
                if (tail.Length is >= 1 and <= 5 && tail.All(char.IsLetterOrDigit)) return "." + tail.ToLowerInvariant();
            }
        }
        return ".jpg";
    }

    public static string FormatCreateTime(DateTime? t, bool dateOnly)
    {
        if (t is null) return "";
        var date = t.Value.ToString("yyyyMMdd", CultureInfo.InvariantCulture);
        return dateOnly ? date : date + t.Value.ToString("HHmmss", CultureInfo.InvariantCulture);
    }

    /// <summary>0s / 45s / 1m30s / 1h2m3s（中间为 0 的位省略）。</summary>
    public static string FormatDurationSeconds(int seconds)
    {
        if (seconds <= 0) return "0s";
        if (seconds >= 3600)
        {
            var h = seconds / 3600;
            var m = (seconds % 3600) / 60;
            var s = seconds % 60;
            return h + "h" + (m > 0 ? m + "m" : "") + (s > 0 ? s + "s" : "");
        }
        if (seconds >= 60)
        {
            var m = seconds / 60;
            var s = seconds % 60;
            return m + "m" + (s > 0 ? s + "s" : "");
        }
        return seconds + "s";
    }

    /// <summary>字节 → MB：大于 1MB 取整，否则保留一位小数。0 → 空串。</summary>
    public static string FormatFileSize(long bytes)
    {
        if (bytes <= 0) return "";
        var mb = bytes / 1048576.0;
        if (mb <= 0) return "";
        return mb > 1
            ? Math.Round(mb, MidpointRounding.AwayFromZero).ToString(CultureInfo.InvariantCulture) + "MB"
            : mb.ToString("0.0", CultureInfo.InvariantCulture) + "MB";
    }

    /// <summary>0 → "0"；超 9999999 → "9999999+"。</summary>
    public static string FormatStatCount(int n)
        => n <= 0 ? "0" : (n > 9999999 ? "9999999+" : n.ToString(CultureInfo.InvariantCulture));

    public static string FpsText(double fps)
        => fps == Math.Floor(fps)
            ? ((long)fps).ToString(CultureInfo.InvariantCulture) + "fps"
            : fps.ToString("0.##", CultureInfo.InvariantCulture) + "fps";

    // ── 组装出「目录 + 文件名」────────────────────────────────

    /// <summary>
    /// 按配置算出一条媒体该存到哪、叫什么。
    /// 目录 = 保存根目录（配置为空则用 aria2 默认目录）+ 文件夹模板展开后的子目录
    /// （enableSaveFolder 关掉时忽略文件夹模板）。
    /// </summary>
    public static (string Dir, string FileName) BuildTarget(DouyinItem item, DouyinConfig cfg)
        => BuildTarget(item, cfg, auto: false);

    /// <summary>
    /// 同 <see cref="BuildTarget(DouyinItem, DouyinConfig)"/>，但可以选择**自动下载模式**。
    ///
    /// 自动下载模式（2026-10-27 用户要求）与设置页那套分开：
    /// - 文件夹模板用 <see cref="DouyinConfig.EffectiveAutoDirTemplate"/>；
    /// - 文件名模板用 <see cref="DouyinConfig.EffectiveAutoFileNameTemplate"/>；
    /// - 是否建子目录看 <see cref="DouyinConfig.AutoCreateFolder"/>（独立开关，
    ///   不受设置页 EnableSaveFolder 影响）。
    /// 这样「设置里那套」不会误控自动下载。
    /// </summary>
    public static (string Dir, string FileName) BuildTarget(DouyinItem item, DouyinConfig cfg, bool auto)
    {
        var baseDir = !string.IsNullOrWhiteSpace(cfg.SaveDirBase)
            ? cfg.SaveDirBase!
            : Aria2Engine.DefaultDir();

        var useFolder = auto ? cfg.AutoCreateFolder : cfg.EnableSaveFolder;
        var dirTemplate = auto ? cfg.EffectiveAutoDirTemplate : cfg.DirTemplate;
        var nameTemplate = auto ? cfg.EffectiveAutoFileNameTemplate : cfg.FileNameTemplate;

        var dir = baseDir;
        if (useFolder && !string.IsNullOrWhiteSpace(dirTemplate))
        {
            var sub = Expand(dirTemplate, item);
            var segs = ParseDirSegments(sub);
            foreach (var s in segs) dir = System.IO.Path.Combine(dir, s);
        }

        var tpl = string.IsNullOrWhiteSpace(nameTemplate)
            ? DefaultFileNameTemplate
            : nameTemplate;
        var expanded = FileNameTemplate.DouyinFilenamify(Expand(tpl, item).Trim(), item.Id);
        if (string.IsNullOrWhiteSpace(expanded)) expanded = item.Id;
        return (dir, expanded);
    }

    /// <summary>把文件夹模板拆成路径段（丢弃 .. 防止跳出保存目录）。</summary>
    public static List<string> ParseDirSegments(string dirName)
    {
        var outList = new List<string>();
        foreach (var s in Regex.Split(dirName ?? "", "[\\\\/]+"))
        {
            var t = s.Trim();
            if (t.Length > 0 && t != "." && t != "..") outList.Add(t);
        }
        return outList;
    }
}
