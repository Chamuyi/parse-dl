using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace ParseDl.Services.Douyin;

/// <summary>
/// 从「视频插眼导出器」导出的 Markdown 名单里读出抖音目标。
///
/// ### 为什么需要这个（2026-10-27 用户需求）
/// 用户用别的工具导出的名单长这样（D:\导出目录\导出清单.md）：
///
/// <code>
/// # 插眼标签：示例标签
///
/// - 条数：45
/// - 导出时间：2026-10-26 01:40:33
///
/// | # | 作者 | 作者UID | 抖音号 | 主页链接 | 标题/简介 | 类型 | 插眼时间 | 视频时间 | 头像链接 |
/// |---:|---|---|---|---|---|---|---|---|---|
/// | 1 | 睡睡泽 | 71287470390 | Sszdawang | https://www.douyin.com/user/MS4wLjABAAAA... | 煮波随时... | home | ... |
/// </code>
///
/// 原来的 <see cref="DouyinAutoStore.ParseTargets"/> 是**一行一个链接**的设计，
/// 整行必须是链接本身。把这种表格行粘进去，<see cref="DouyinUrl.Normalize"/>
/// 会认为整行不合法 → 全部被拒。所以这里单独做一层：**先认表格，再取链接列**。
///
/// 不依赖列的顺序：用表头行找到「主页链接」所在列号，之后每行按列号取。
/// 表头缺失时退回「在行内找第一个 douyin.com/user 链接」的兜底策略。
/// </summary>
public static class DouyinRoster
{
    /// <summary>从一份 Markdown 名单文本里取出目标（一行一条的表格）。</summary>
    public static DouyinTargetParse Parse(string text, int maxTargets = DouyinAutoStore.MaxTargets)
    {
        var tasks = new List<DouyinAutoTask>();
        var rejected = new List<string>();
        var seen = new HashSet<string>();
        var truncated = 0;

        var linkCol = -1;      // 「主页链接」列的下标（0 基，按 split('|') 之后的顺序）
        var nameCol = -1;      // 「作者」列
        var seenHeader = false;

        foreach (var rawLine in (text ?? "").Split('\n'))
        {
            var line = rawLine.Trim().TrimEnd('\r');
            if (line.Length == 0) continue;

            // 表格行必须以 | 开头；**但也接受纯链接行**（2026-10-29 补）。
            //
            // 之前这里只有 `if (!line.StartsWith('|')) continue;` ——
            // 用户粘 5 行纯链接时**全部被忽略**，界面显示「识别 0 个目标」或只认出 1 个。
            // 页面提示里明明写着「一行一个目标：主页链接 / 视频链接 / 短链 / 作品 ID」，
            // 所以纯链接行必须认。
            if (!line.StartsWith('|'))
            {
                // 非表格行：先试着当纯链接 / 纯 ID 解析
                var bareUrl = DouyinUrl.Normalize(line);
                if (bareUrl is null)
                {
                    var mm = Regex.Match(line, @"https?://(?:www\.)?douyin\.com/(?:user|video)/[^\s|]+");
                    if (mm.Success) bareUrl = DouyinUrl.Normalize(mm.Value);
                }
                if (bareUrl is null) continue;   // 标题、条数、导出时间等，忽略

                if (!seen.Add(bareUrl)) continue;
            // **不再限制名单数量**（2026-10-30 用户要求「名单数量限制取消了，不要限制」）
                tasks.Add(new DouyinAutoTask(line, bareUrl));
                continue;
            }

            var cells = SplitCells(line);

            // 分隔行 |---:|---| 跳过
            if (cells.All(c => c.Length > 0 && c.All(ch => ch is '-' or ':'))) continue;

            if (!seenHeader)
            {
                // 第一行是表头：找出链接列与作者列
                for (var i = 0; i < cells.Count; i++)
                {
                    var h = cells[i];
                    if (linkCol < 0 && (h.Contains("主页链接") || h.Contains("链接") || h.Contains("主页")))
                        linkCol = i;
                    if (nameCol < 0 && h.Contains("作者"))
                        nameCol = i;
                }
                seenHeader = true;
                continue;   // 表头本身不是数据
            }

            string? url = null;
            if (linkCol >= 0 && linkCol < cells.Count)
                url = DouyinUrl.Normalize(cells[linkCol]);

            // 兜底：表头没认出来 / 链接列取值失败时，在整行里找第一个抖音链接
            if (url is null)
            {
                var m = Regex.Match(line, @"https?://(?:www\.)?douyin\.com/(?:user|video)/[^\s|]+");
                if (m.Success) url = m.Value;
            }

            if (url is null)
            {
                // 只有「看起来像数据行」的才回显（至少 3 个单元格），避免刷屏
                if (cells.Count >= 3) rejected.Add(line);
                continue;
            }

            if (!seen.Add(url)) continue;
            // **不再限制名单数量**（2026-10-30 用户要求「名单数量限制取消了，不要限制」）

            // 把作者名带上，后面按模板建文件夹时要用
            var author = nameCol >= 0 && nameCol < cells.Count ? cells[nameCol] : "";
            tasks.Add(new DouyinAutoTask(line, url) { Author = author });
        }

        return new DouyinTargetParse { Tasks = tasks, Rejected = rejected, Truncated = truncated };
    }

    /// <summary>按 | 切单元格并去空白。首尾的空壳（行首行尾的 |）去掉。</summary>
    private static List<string> SplitCells(string line)
    {
        var parts = line.Split('|').Select(p => p.Trim()).ToList();
        if (parts.Count > 0 && parts[0].Length == 0) parts.RemoveAt(0);
        if (parts.Count > 0 && parts[^1].Length == 0) parts.RemoveAt(parts.Count - 1);
        return parts;
    }

    /// <summary>这份文本看起来是不是「插眼导出器」的 Markdown 名单。</summary>
    public static bool LooksLikeRoster(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        return text.Contains("插眼标签") || text.Contains("主页链接")
               || Regex.IsMatch(text, @"^\|.*\|.*\|", RegexOptions.Multiline);
    }

    /// <summary>从文件读并解析。文件不存在/读失败时返回 null，由调用方决定怎么提示。</summary>
    public static DouyinTargetParse? ParseFile(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            return Parse(File.ReadAllText(path));
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// 离线自测：名单解析 + 模板建文件夹。用 --selftest 跑，结果写 selftest.txt。
    /// 不联网、不依赖真实名单文件（内置一段同结构的样本）。
    /// </summary>
    public static string SelfTest()
    {
        var sb = new System.Text.StringBuilder();
        var sample = string.Join("\n", new[]
        {
            "# 插眼标签：测试",
            "",
            "- 条数：3",
            "",
            "| # | 作者 | 作者UID | 抖音号 | 主页链接 | 标题/简介 | 类型 | 插眼时间 | 视频时间 | 头像链接 |",
            "|---:|---|---|---|---|---|---|---|---|---|",
            "| 1 | 张三 | 111 | abc | https://www.douyin.com/user/MS4wLjABAAAAxx1 | 简介一 | home | 2026-10-18 17:54:48 | x | y |",
            "| 2 | 李四 | 222 | def | https://www.douyin.com/user/MS4wLjABAAAAxx2 | | home | x | x | y |",
            "| 3 | 张三2 | 333 | ghi | https://www.douyin.com/user/MS4wLjABAAAAxx1 | 重复 | home | x | x | y |",
        });

        var parsed = Parse(sample);
        sb.AppendLine("[名单] 识别 " + parsed.Tasks.Count + " 个（应为 2，第 3 行与第 1 行链接重复应去重），拒绝 " + parsed.Rejected.Count + " 行");
        foreach (var tk in parsed.Tasks)
            sb.AppendLine("   " + tk.Author + " -> " + tk.Url);

        var looks = LooksLikeRoster(sample);
        sb.AppendLine("[名单] LooksLikeRoster = " + looks + "（应为 True）");

        // 模板：建文件夹开关
        var cfg = new DouyinConfig { AutoCreateFolder = true, AutoDirTemplate = "%AUTHOR%" };
        var item = new DouyinItem { Id = "741", Url = "https://x", Text = "t", UserName = "张三" };
        var (d1, f1) = DouyinTemplate.BuildTarget(item, cfg, auto: true);
        sb.AppendLine("[模板] 开=建文件夹 → " + d1 + "  |  " + f1);
        sb.AppendLine("      目录末尾应为 张三：" + (d1.EndsWith("张三") ? "OK" : "FAIL"));

        cfg.AutoCreateFolder = false;
        var (d2, f2) = DouyinTemplate.BuildTarget(item, cfg, auto: true);
        sb.AppendLine("[模板] 关=不建文件夹 → " + d2 + "  |  " + f2);
        sb.AppendLine("      目录不应含 张三：" + (!d2.Contains("张三") ? "OK" : "FAIL"));

        // 自动下载模板与设置页模板互不影响
        var cfg2 = new DouyinConfig
        {
            DirTemplate = "SETPAGE",
            AutoDirTemplate = "%AUTHOR%",
            FileNameTemplate = "setpage.ext",
            AutoFileNameTemplate = "%AUTHOR%-auto.ext",
        };
        var (d3, f3) = DouyinTemplate.BuildTarget(item, cfg2, auto: true);
        var (d4, f4) = DouyinTemplate.BuildTarget(item, cfg2, auto: false);
        sb.AppendLine("[隔离] auto  → " + d3 + " | " + f3);
        sb.AppendLine("[隔离] 设置页 → " + d4 + " | " + f4);
        sb.AppendLine("      auto 不该用 SETPAGE：" + (!d3.Contains("SETPAGE") ? "OK" : "FAIL"));
        sb.AppendLine("      设置页不该用 auto 模板：" + (d4.Contains("SETPAGE") ? "OK" : "FAIL"));

        return sb.ToString();
    }
}
