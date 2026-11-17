using System;
using System.Text;

namespace ParseDl.Services;

/// <summary>
/// AccentService 的离线自测 —— 只测**纯逻辑**部分（色值解析、混色、预设完整性、
/// 对比度），不测资源注入：那需要 Application.Current，只能在真机里跑。
///
/// 为什么要这一套：强调色是「看起来对就行」的东西，最容易出的错是
/// 1) 预设少给一个色值 → 界面上某个控件取不到色；
/// 2) 十六进制解析放过非法输入 → 设置里存进一个坏色值，下次启动整页变黑；
/// 3) 混色方向搞反 → 深色主题上强调色越调越暗，对比度崩掉。
/// 这三类都能离线钉住。
/// </summary>
public static class AccentSelfTest
{
    public static string Run()
    {
        var sb = new StringBuilder();
        var pass = 0;
        var fail = 0;

        void Check(string name, bool ok)
        {
            if (ok) { pass++; sb.AppendLine("  PASS " + name); }
            else { fail++; sb.AppendLine("  FAIL " + name); }
        }

        // ① 预设完整性：至少 6 套，id 唯一，中文名非空，四个色值都能解析
        Check("预设数量 >= 6", AccentService.Presets.Count >= 6);
        var ids = new System.Collections.Generic.HashSet<string>();
        var allIdsUnique = true;
        var allNamesFilled = true;
        var allColorsParse = true;
        foreach (var p in AccentService.Presets)
        {
            if (!ids.Add(p.Id)) allIdsUnique = false;
            if (string.IsNullOrWhiteSpace(p.Name)) allNamesFilled = false;
            if (!AccentService.TryParseHex(p.LightBase, out _)) allColorsParse = false;
            if (!AccentService.TryParseHex(p.DarkBase, out _)) allColorsParse = false;

            // 每套在浅/深两种主题下都要能解析出 4 个色值
            foreach (var isDark in new[] { false, true })
            {
                var (f, s, t, o) = AccentService.ResolveForPreset(p.Id, isDark);
                if (!AccentService.TryParseHex(f, out _)) allColorsParse = false;
                if (!AccentService.TryParseHex(s, out _)) allColorsParse = false;
                if (!AccentService.TryParseHex(t, out _)) allColorsParse = false;
                if (!AccentService.TryParseHex(o, out _)) allColorsParse = false;
            }
        }
        Check("预设 id 唯一", allIdsUnique);
        Check("预设中文名齐全", allNamesFilled);
        Check("每套预设的 4 个色值在浅/深下都可解析", allColorsParse);

        // ② 十六进制解析：正例 + 负控制
        Check("#RRGGBB 解析", AccentService.TryParseHex("#0078D4", out var c1) && c1.R == 0x00 && c1.G == 0x78 && c1.B == 0xD4);
        Check("无 # 前缀也认", AccentService.TryParseHex("0078D4", out _));
        Check("小写也认", AccentService.TryParseHex("#abcdef", out _));
        Check("空串应失败", !AccentService.TryParseHex("", out _));
        Check("null 应失败", !AccentService.TryParseHex(null, out _));
        Check("5 位应失败", !AccentService.TryParseHex("#12345", out _));
        Check("7 位应失败", !AccentService.TryParseHex("#1234567", out _));
        Check("非十六进制字符应失败", !AccentService.TryParseHex("#GGGGGG", out _));
        Check("含中文应失败", !AccentService.TryParseHex("#红色", out _));

        // ③ 混色方向：往白混必须变亮，往黑混必须变暗
        AccentService.TryParseHex("#808080", out var mid);
        var toWhite = AccentService.Mix(mid, ColorOf(255, 255, 255), 0.5);
        var toBlack = AccentService.Mix(mid, ColorOf(0, 0, 0), 0.5);
        Check("往白混变亮", toWhite.R > mid.R && toWhite.G > mid.G && toWhite.B > mid.B);
        Check("往黑混变暗", toBlack.R < mid.R && toBlack.G < mid.G && toBlack.B < mid.B);
        Check("Mix t=0 原色", AccentService.Mix(mid, ColorOf(0, 0, 0), 0).R == mid.R);
        Check("Mix t=1 目标色", AccentService.Mix(mid, ColorOf(0, 0, 0), 1).R == 0);

        // ④ 深浅两套必须真的不同（否则「切深浅不变色」这个 bug 会静默存在）
        var differs = false;
        foreach (var p in AccentService.Presets)
        {
            var light = AccentService.ResolveForPreset(p.Id, false);
            var dark = AccentService.ResolveForPreset(p.Id, true);
            if (light.Fill != dark.Fill) differs = true;
        }
        Check("预设的浅/深底色不同", differs);

        // ⑤ 对比度：白字压浅色强调色、深字压深色强调色，都要 >= 3.0（大字号 AA 档）
        var allContrastOk = true;
        var worst = 99.0;
        foreach (var p in AccentService.Presets)
        {
            foreach (var isDark in new[] { false, true })
            {
                var (f, _, _, o) = AccentService.ResolveForPreset(p.Id, isDark);
                AccentService.TryParseHex(f, out var fill);
                AccentService.TryParseHex(o, out var onAccent);
                var ratio = AccentService.ContrastRatio(fill, onAccent);
                if (ratio < worst) worst = ratio;
                if (ratio < 4.0) allContrastOk = false;
            }
        }
        // 阈值 4.0：WCAG 正文 AA 是 4.5、大字号 AA 是 3.0。
        // 按钮文字通常 >14pt 粗体，3.0 就够，但留点余量取 4.0 ——
        // 第一版 Tailwind 500 档的浅色（#0EA5E9 / #10B981 / #F59E0B）实测只有 2.15~2.77，
        // 就是被这条判据挡下来才换成 600~700 档的。
        Check($"强调色与其前景色对比度均 >= 4.0（最差 {worst:F2}）", allContrastOk);

        // ⑥ 未知 id 要回退到第一套而不是崩
        Check("未知 id 回退首个预设", AccentService.PresetOf("不存在的id").Id == AccentService.Presets[0].Id);

        sb.AppendLine($"  ---- {pass} 通过 / {fail} 失败 ----");
        return sb.ToString();
    }

    private static Windows.UI.Color ColorOf(byte r, byte g, byte b) =>
        Windows.UI.Color.FromArgb(255, r, g, b);
}
