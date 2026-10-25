using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace ParseDl.Services.Bili;

/// <summary>B 站模板可用变量的元数据（给设置页的变量面板用）。</summary>
public sealed record BiliTemplateVar(string Name, string Desc, string? Params = null);

/// <summary>
/// B 站命名模板引擎 —— 对齐 Flutter 版 lib/services/file_name_template.dart 的
/// B 站变量集（18 个）与语法。
///
/// 为什么**不复用** Services/FileNameTemplate：
/// 那套是照 X 的字段写的（%POST_ID% / %USER_SCREEN_NAME% / %MEDIA_INDEX%），
/// 拿它渲 B 站模板会让「设置页里写 %WORK_TITLE%、下载时却不认识」，
/// 而这类不一致正是用户说的「没按要求做」。这里实现 B 站自己的表与语义，
/// 两边各管各的。
///
/// 语法三条：
///  1. 变量写成 %NAME%（大小写不敏感）；
///  2. 参数写成 %CONTENT,t=32%（目前只用到 t=截断长度）；
///  3. 可选段写成 A&lt;-%NAME%-&gt;B —— 段内任一变量为空时，**整段**（含段内字面字符）丢弃。
///     单 P 稿件 %P% 取到 0 就是靠这条让 "P0-" 整段消失。
/// </summary>
public static class BiliTemplate
{
    /// <summary>B 站模板可用变量表（与原项目 kBiliTemplateVars 同一批名字）。</summary>
    public static readonly IReadOnlyList<BiliTemplateVar> Vars = new List<BiliTemplateVar>
    {
        new("WORK_TITLE", "作品标题"),
        new("PART_TITLE", "分P 标题"),
        new("P", "分P 号（单P 时为 0，配可选段使用）"),
        new("PART_TOTAL", "分P 总数"),
        new("BVID", "BV 号"),
        new("AVID", "AV 号"),
        new("CID", "CID"),
        new("UP_NAME", "UP 主昵称"),
        new("UP_MID", "UP 主 UID"),
        new("QUALITY", "实际拿到的画质"),
        new("CODEC", "实际拿到的编码"),
        new("CUSTOM_TEXT", "自定义文本（在设置里填）"),
        new("RESOLUTION", "分辨率，如 1920x1080"),
        new("DURATION", "时长，如 1m30s"),
        new("FILE_SIZE", "文件大小（入队时通常还没有，多为空）"),
        new("POST_TIME", "投稿时间", "d=1 仅日期"),
        new("POST_ID", "作品 ID（等同 BV 号）"),
        new("MEDIA_INDEX", "媒体序号（B 站恒为 1）"),
        new("USER_SCREEN_NAME", "UP 主昵称（同 UP_NAME）"),
        new("EXT", "扩展名（含点，如 .mp4）"),
    };

    /// <summary>一次渲染的输入。</summary>
    public sealed class Context
    {
        public string WorkTitle { get; init; } = "";
        public string PartTitle { get; init; } = "";
        /// <summary>分P 号（1 基）。单 P 稿件传 0，让可选段整段消失。</summary>
        public int Part { get; init; }
        public int PartTotal { get; init; }
        public string Bvid { get; init; } = "";
        public long Aid { get; init; }
        public long Cid { get; init; }
        public string UpName { get; init; } = "";
        public long UpMid { get; init; }
        public string Quality { get; init; } = "";
        public string Codec { get; init; } = "";
        public string CustomText { get; init; } = "";
        public int Width { get; init; }
        public int Height { get; init; }
        public int DurationSec { get; init; }
        public long SizeBytes { get; init; }
        public DateTime? PostTime { get; init; }
        /// <summary>扩展名（含点）。</summary>
        public string Ext { get; init; } = ".mp4";
    }

    /// <summary>渲染一个模板。空模板返回空串（调用方决定兜底）。</summary>
    public static string Render(string? template, Context ctx)
    {
        if (string.IsNullOrEmpty(template)) return "";
        var text = ExpandSegments(template!, ctx);
        return ExpandVars(text, ctx);
    }

    /// <summary>
    /// 处理可选段。**从内向外**逐层剥：段内先渲染好，再按「有没有取到值」决定整段去留。
    /// 之所以要按层而不是一次扫完：模板里可能嵌套多层段（原项目允许），
    /// 一次扫完会把最内层之外的内容也一起吃掉。
    /// </summary>
    private static string ExpandSegments(string template, Context ctx)
    {
        var result = template;
        // 最多剥 8 层，防止写错尖括号时死循环
        for (var depth = 0; depth < 8; depth++)
        {
            var open = result.LastIndexOf('<');
            if (open < 0) break;
            var close = result.IndexOf('>', open + 1);
            if (close < 0) break;
            var inner = result.Substring(open + 1, close - open - 1);
            var rendered = ExpandVars(inner, ctx);
            // 判据是「**段内的变量**是否全都取不到值」，不是「渲染结果是否为空」——
            // 段里本来就有字面字符（<P%P%-> 里的 P 和 -），渲染结果永远不为空，
            // 按渲染结果判会让单 P 落出「标题-P-1080P.mp4」（第一版就是这么错的）。
            var varCount = 0;
            var nonEmptyCount = 0;
            foreach (var tok in ExtractVarTokens(inner))
            {
                varCount++;
                if (ValueOf(tok, ctx).Trim().Length > 0) nonEmptyCount++;
            }
            // 段内没有变量 → 纯字面，原样保留；有变量且全空 → 整段丢弃
            var keep = varCount == 0 || nonEmptyCount > 0;
            result = result.Substring(0, open) + (keep ? rendered : "") + result.Substring(close + 1);
        }
        return result;
    }

    /// <summary>把一段文本里的变量名（不含 %）逐个抽出来。</summary>
    private static List<string> ExtractVarTokens(string text)
    {
        var list = new List<string>();
        var i = 0;
        while (i < text.Length)
        {
            var open = text.IndexOf('%', i);
            if (open < 0) break;
            var close = text.IndexOf('%', open + 1);
            if (close < 0) break;
            list.Add(text.Substring(open + 1, close - open - 1));
            i = close + 1;
        }
        return list;
    }

    private static string ExpandVars(string text, Context ctx)
    {
        var sb = new StringBuilder(text.Length);
        var i = 0;
        while (i < text.Length)
        {
            var open = text.IndexOf('%', i);
            if (open < 0) { sb.Append(text, i, text.Length - i); break; }
            // 找配对的收尾百分号：**中间不允许再有百分号**，否则 "%A%%B%" 会被当成一个变量
            var close = text.IndexOf('%', open + 1);
            if (close < 0) { sb.Append(text, i, text.Length - i); break; }

            sb.Append(text, i, open - i);
            var token = text.Substring(open + 1, close - open - 1);
            sb.Append(ValueOf(token, ctx));
            i = close + 1;
        }
        return sb.ToString();
    }

    /// <summary>单个变量取值；认不出来的变量**原样保留**（便于用户发现自己写错了名字）。</summary>
    public static string ValueOf(string token, Context ctx)
    {
        var raw = token.Trim();
        var param = "";
        var comma = raw.IndexOf(',');
        if (comma >= 0)
        {
            param = raw.Substring(comma + 1).Trim();
            raw = raw.Substring(0, comma).Trim();
        }
        var name = raw.ToUpperInvariant();

        switch (name)
        {
            case "WORK_TITLE": return ctx.WorkTitle;
            case "PART_TITLE": return ctx.PartTitle;
            // **单 P 稿件回空串**（不是 "0"）：可选段的判据是「段内渲染完是否为空」，
            // 回 "0" 会让 "P0" 整段留下来 —— 这是 Flutter 版「%P% 取到 0 → 整段消失」
            // 那句话的真正含义，第一版实现按字面回 "0" 踩了自测（P0-1080P.mp4）。
            case "P": return ctx.Part > 0 ? ctx.Part.ToString() : "";
            case "PART_TOTAL": return ctx.PartTotal > 1 ? ctx.PartTotal.ToString() : "";
            case "BVID": return ctx.Bvid;
            case "AVID": return ctx.Aid > 0 ? ctx.Aid.ToString() : "";
            case "CID": return ctx.Cid > 0 ? ctx.Cid.ToString() : "";
            case "UP_NAME":
            case "USER_SCREEN_NAME": return ctx.UpName;
            case "UP_MID": return ctx.UpMid > 0 ? ctx.UpMid.ToString() : "";
            case "QUALITY": return ctx.Quality;
            case "CODEC": return ctx.Codec;
            case "CUSTOM_TEXT": return ApplyTruncate(ctx.CustomText, param);
            case "RESOLUTION":
                return ctx.Width > 0 && ctx.Height > 0 ? ctx.Width + "x" + ctx.Height : "";
            case "DURATION": return DurationText(ctx.DurationSec);
            case "FILE_SIZE":
                return ctx.SizeBytes > 0 ? FormatSize(ctx.SizeBytes) : "";
            case "POST_ID": return ctx.Bvid.Length > 0 ? ctx.Bvid : (ctx.Aid > 0 ? "av" + ctx.Aid : "");
            case "POST_TIME": return PostTimeText(ctx.PostTime, param);
            case "MEDIA_INDEX": return "1";
            case "EXT": return ctx.Ext.StartsWith(".") ? ctx.Ext : ("." + ctx.Ext);
            default: return "%" + token + "%";
        }
    }

    private static string ApplyTruncate(string value, string param)
    {
        // 参数形如 "t=32"
        foreach (var part in param.Split(','))
        {
            var kv = part.Split('=');
            if (kv.Length != 2) continue;
            if (!kv[0].Trim().Equals("t", StringComparison.OrdinalIgnoreCase)) continue;
            if (!int.TryParse(kv[1].Trim(), out var n) || n <= 0) continue;
            return value.Length <= n ? value : value.Substring(0, n);
        }
        return value;
    }

    /// <summary>
    /// 投稿时间。**时分秒之间用连字符而不是冒号** —— 冒号是 Windows 文件名非法字符。
    /// d=1 时只要日期。
    /// </summary>
    public static string PostTimeText(DateTime? t, string param)
    {
        if (t is not DateTime dt) return "";
        var date = dt.Year.ToString("D4") + "-" + dt.Month.ToString("D2") + "-" + dt.Day.ToString("D2");
        if (param.Contains("d=1")) return date;
        return date + " " + dt.Hour.ToString("D2") + "-" + dt.Minute.ToString("D2") +
               "-" + dt.Second.ToString("D2");
    }

    /// <summary>时长：0s / 45s / 1m30s / 1h2m3s，中间为 0 的位省略（2m0s 写 2m）。</summary>
    public static string DurationText(int sec)
    {
        if (sec <= 0) return "";
        var h = sec / 3600;
        var m = sec % 3600 / 60;
        var s = sec % 60;
        var sb = new StringBuilder();
        if (h > 0) sb.Append(h).Append('h');
        if (m > 0) sb.Append(m).Append('m');
        if (s > 0) sb.Append(s).Append('s');
        return sb.Length == 0 ? "" : sb.ToString();
    }

    private static string FormatSize(long bytes)
    {
        string[] units = { "B", "KB", "MB", "GB" };
        double v = bytes;
        var i = 0;
        while (v >= 1024 && i < units.Length - 1) { v /= 1024; i++; }
        return v.ToString("0.#") + units[i];
    }

    /// <summary>
    /// 把渲染出来的名字净化成合法文件名（去掉 Windows 非法字符、收尾去点与空格）。
    /// 与 Services/FileNameTemplate.UnicodeFilenamify 同一口径，但独立实现，
    /// 免得 B 站这条链路被 X 那边的规则变化牵连。
    /// </summary>
    public static string Sanitize(string name)
    {
        if (string.IsNullOrEmpty(name)) return "";
        var invalid = new HashSet<char> { '<', '>', ':', '"', '/', '\\', '|', '?', '*' };
        var sb = new StringBuilder(name.Length);
        foreach (var ch in name)
        {
            if (invalid.Contains(ch) || ch < (char)32) continue;
            sb.Append(ch);
        }
        var s = sb.ToString().Trim().TrimEnd('.');
        // 全空白或只剩点号时回空串，由调用方兜底
        return s.Length == 0 ? "" : s;
    }
}

/// <summary>B 站模板引擎自测 —— 纯离线。</summary>
public static class BiliTemplateSelfTest
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

        var single = new BiliTemplate.Context
        {
            WorkTitle = "怪东西分享9.0", PartTitle = "原始文件名_3840x2160_V04", Part = 0, PartTotal = 1,
            Bvid = "BV1gHps6yEHL", Aid = 123, Cid = 456, UpName = "影视飓风", UpMid = 946974,
            Quality = "1080P", Codec = "AVC", Ext = ".mp4",
            PostTime = new DateTime(2026, 10, 9, 12, 34, 56),
        };
        var multi = new BiliTemplate.Context
        {
            WorkTitle = "怪东西分享9.0", PartTitle = "第03集", Part = 3, PartTotal = 12,
            Bvid = "BV1gHps6yEHL", Quality = "1080P60", Codec = "HEVC", Ext = ".mkv",
        };

        Check("默认模板单P（可选段整段消失，不出现 P0）",
            BiliTemplate.Render("%WORK_TITLE%<-P%P%>-%QUALITY%%EXT%", single) == "怪东西分享9.0-1080P.mp4",
            BiliTemplate.Render("%WORK_TITLE%<-P%P%>-%QUALITY%%EXT%", single));
        Check("默认模板多P（P 号带进去）",
            BiliTemplate.Render("%WORK_TITLE%<-P%P%>-%QUALITY%%EXT%", multi) == "怪东西分享9.0-P3-1080P60.mkv",
            BiliTemplate.Render("%WORK_TITLE%<-P%P%>-%QUALITY%%EXT%", multi));
        Check("文件夹模板 %WORK_TITLE%",
            BiliTemplate.Render("%WORK_TITLE%", single) == "怪东西分享9.0");
        Check("UP/WORK 两级",
            BiliTemplate.Render("%UP_NAME%/%WORK_TITLE%", single) == "影视飓风/怪东西分享9.0");
        Check("PART_TITLE", BiliTemplate.Render("%PART_TITLE%", single) == "原始文件名_3840x2160_V04");
        Check("BVID 与 UP_MID", BiliTemplate.Render("%BVID%-%UP_MID%", single) == "BV1gHps6yEHL-946974");
        Check("POST_TIME 默认带时分秒（用连字符，不含冒号）",
            BiliTemplate.Render("%POST_TIME%", single) == "2026-10-09 12-34-56",
            BiliTemplate.Render("%POST_TIME%", single));
        Check("POST_TIME,d=1 只日期", BiliTemplate.Render("%POST_TIME,d=1%", single) == "2026-10-09");
        Check("时长格式", BiliTemplate.DurationText(5430) == "1h30m30s", BiliTemplate.DurationText(5430));
        Check("时长 2m0s 省略零位", BiliTemplate.DurationText(120) == "2m", BiliTemplate.DurationText(120));
        Check("时长为 0 回空串", BiliTemplate.DurationText(0) == "");
        Check("分辨率", BiliTemplate.Render("%RESOLUTION%", new BiliTemplate.Context { Width = 1920, Height = 1080 }) == "1920x1080");
        Check("CUSTOM_TEXT 截断 t=4",
            BiliTemplate.Render("%CUSTOM_TEXT,t=4%", new BiliTemplate.Context { CustomText = "一二三四五六" }) == "一二三四",
            BiliTemplate.Render("%CUSTOM_TEXT,t=4%", new BiliTemplate.Context { CustomText = "一二三四五六" }));
        Check("认不出的变量原样保留",
            BiliTemplate.Render("%NOT_A_VAR%", single) == "%NOT_A_VAR%");
        Check("连续两个变量不粘连",
            BiliTemplate.Render("%QUALITY%%CODEC%", single) == "1080PAVC",
            BiliTemplate.Render("%QUALITY%%CODEC%", single));
        Check("名字里的非法字符被净化",
            BiliTemplate.Sanitize("a<b>c:d\"e/f\\g|h?i*j") == "abcdefghij",
            BiliTemplate.Sanitize("a<b>c:d\"e/f\\g|h?i*j"));
        Check("结尾的点被去掉（Windows 不允许）", BiliTemplate.Sanitize("标题...") == "标题");
        Check("EXT 自动补点", BiliTemplate.Render("%EXT%", new BiliTemplate.Context { Ext = "mp4" }) == ".mp4");
        Check("变量表含 20 项且都有说明",
            BiliTemplate.Vars.Count >= 18 && BiliTemplate.Vars.All(v => v.Desc.Length > 0),
            BiliTemplate.Vars.Count.ToString());

        sb.AppendLine();
        sb.AppendLine("BiliTemplate 合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}
