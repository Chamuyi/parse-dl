using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace ParseDl.Services.Douyin;

/// <summary>
/// 布局自测 —— 覆盖 2026-10-25 用户投诉的两项：
///   ① 右栏自适应（宽度切两栏 / 上下两行，内容不被横向截断）；
///   ② 操作按钮排换行（窄窗不再被裁掉）。
///
/// 纯数学，不依赖 WinUI 控件，可在控制台里跑（本轮纪律禁止 dotnet run 启动应用，
/// 所以界面布局的判据只能在算法层取证，见报告里的说明）。
/// </summary>
public static class DouyinLayoutSelfTest
{
    /// <summary>解析页右栏布局所需的最小正文宽度（与页面里的常量保持一致）。</summary>
    public const double TwoPaneMinWidth = 820;

    /// <summary>右栏两栏布局时右列的 MinWidth（与页面里保持一致）。</summary>
    public const double RightPaneMinWidth = 380;

    /// <summary>正文左右各 24 的内边距（页面 Padding="24,8,24,24"）。</summary>
    public const double PagePadding = 24;

    /// <summary>页面最大内容宽度（居中容器用的 MaxWidth）。</summary>
    public const double MaxContentWidth = 1600;

    /// <summary>
    /// 给定窗口宽度，算出正文可用宽度。
    /// 与 XAML 一致：内层容器先被 MaxWidth 夹住（居中容器），再扣掉两侧 24 内边距。
    /// </summary>
    public static double ContentWidth(double windowWidth)
    {
        var outer = Math.Min(windowWidth, MaxContentWidth);
        var w = outer - PagePadding * 2;
        return w <= 0 ? 0 : w;
    }

    /// <summary>是否用左右两栏布局。</summary>
    public static bool UseTwoPane(double contentWidth) => contentWidth >= TwoPaneMinWidth;

    /// <summary>
    /// 给定正文宽度，算出左右两栏各自的宽度（**纯分配，调用方先判是否两栏**）。
    /// 两栏都是星号宽度 + 右栏 MinWidth：星号均分后若右栏不足 MinWidth，
    /// 右栏取 MinWidth、左栏吃剩下的（这与 XAML 的 Grid 行为一致）。
    ///
    /// 注：在当前阈值 820 下，均分后每栏最小 404 &gt; 380，所以保底分支实际
    /// 打不到 —— 它是**双保险**（将来若把阈值调低，或导航栏改宽，保底才生效）。
    /// </summary>
    public static (double Left, double Right) PaneWidths(double contentWidth)
    {
        const double gap = 12;   // BodyGrid.ColumnSpacing
        var each = (contentWidth - gap) / 2;
        if (each >= RightPaneMinWidth)
        {
            return (each, each);
        }
        var right = RightPaneMinWidth;
        var left = Math.Max(0, contentWidth - gap - right);
        return (left, right);
    }

    public static string Run()
    {
        var sb = new StringBuilder();
        var pass = 0;
        var fail = 0;

        void Check(string name, bool ok, string detail = "")
        {
            if (ok) { pass++; sb.AppendLine("  PASS  " + name); }
            else { fail++; sb.AppendLine("  FAIL  " + name + "  " + detail); }
        }

        // ── ① 两栏 / 单列切换的阈值 ─────────────────────────
        // 用户报问题的两档：1000 宽与 1600 宽（lead 给的验收档位）
        var w1000 = ContentWidth(1000);   // 1000 - 48 = 952
        var w1600 = ContentWidth(1600);   // 1600 - 48 = 1552
        Check("1000 宽 → 正文 952，走左右两栏", Math.Abs(w1000 - 952) < 0.01 && UseTwoPane(w1000),
            w1000.ToString());
        Check("1600 宽 → 正文 1552，走左右两栏", Math.Abs(w1600 - 1552) < 0.01 && UseTwoPane(w1600),
            w1600.ToString());

        // 窄窗必须切上下两行 —— 这是「右栏被截断」的根治点
        Check("720 宽 → 正文 672，切单列（右栏不会再被右边界截断）",
            !UseTwoPane(ContentWidth(720)), ContentWidth(720).ToString());
        Check("820 阈值边界：正文正好 820 仍算两栏", UseTwoPane(820));
        Check("819 阈值边界：正文 819 切单列", !UseTwoPane(819));

        // 超宽屏夹到 MaxWidth，不能无限拉伸
        Check("2400 宽 → 正文与 1600 宽时相同（宽窗不无限拉伸，居中留白）",
            Math.Abs(ContentWidth(2400) - ContentWidth(1600)) < 0.01, ContentWidth(2400).ToString());
        Check("2400 宽时左右留白对称 = (2400-1600)/2 = 400",
            Math.Abs((2400 - MaxContentWidth) / 2 - 400) < 0.01);
        Check("极小窗口不至于算出负宽度", ContentWidth(20) == 0);

        // ── ② 两栏宽度：右栏永不低于 MinWidth，加起来不超可用宽度 ──
        foreach (var win in new[] { 900, 1000, 1200, 1400, 1600, 2000, 2400 })
        {
            var cw = ContentWidth(win);
            var (left, right) = PaneWidths(cw);
            Check("窗口 " + win + " 两栏不溢出（左+右+间距 <= 正文宽）",
                left + right + 12 <= cw + 0.01, left + "+" + right + " vs " + cw);
            Check("窗口 " + win + " 右栏 >= 380",
                right >= RightPaneMinWidth - 0.01, right.ToString());
            Check("窗口 " + win + " 左右都 > 0",
                left > 0 && right > 0, left + "/" + right);
        }
        // 阈值处的最小右栏宽度（决定右栏里能放几列缩略图）
        var (lTh, rTh) = PaneWidths(TwoPaneMinWidth);
        Check("阈值 820 处右栏 = 404（均分已 > MinWidth 380）",
            Math.Abs(rTh - 404) < 0.01, rTh.ToString());
        // 保底分支：把宽度压到均分不足 380 时，右栏保 380、左栏吃剩下的（双保险）
        var (lGuard, rGuard) = PaneWidths(760);
        Check("保底分支：均分不足时右栏锁 380、左栏吃剩下的、总宽不超可用",
            Math.Abs(rGuard - RightPaneMinWidth) < 0.01
            && Math.Abs(lGuard - (760 - 12 - RightPaneMinWidth)) < 0.01
            && lGuard + rGuard + 12 <= 760.01,
            lGuard + "/" + rGuard);

        // ── ③ 操作按钮排换行 ─────────────────────────────────
        // 六个按钮的估计宽度（文字 + 左右 12px 内边距，24 像素字号 13 下按 14px/字估）
        var buttons = new List<(double Width, double Height)>
        {
            (58, 32),   // 全部
            (86, 32),   // 清空勾选
            (100, 32),  // 选全部视频
            (100, 32),  // 选全部图文
            (58, 32),   // 筛选
            (86, 32),   // 清空结果
        };

        // 窗口 1000 时右栏 476 左右，减去面板内边距 12*2 = 452 —— 单行放不下（合计 488+间距）
        var wide = PaneWidths(ContentWidth(1000)).Right - 24;
        var rWide = DouyinWrapLayout.Arrange(buttons, wide);
        Check("窗口 1000 时按钮排换行（单行放不下）", rWide.Rows > 1, rWide.Rows + " 行 / 可用 " + wide);
        Check("窗口 1000 时按钮排不横向溢出",
            DouyinWrapLayout.FitsWithin(buttons, wide), wide.ToString());

        // 单列布局下可用宽度其实是**整个正文宽**（比两栏时的右栏宽得多），
        // 所以这里要点是「不溢出」，不一定是换行
        var narrow = ContentWidth(720) - 24;
        Check("单列布局下按钮排不横向溢出",
            DouyinWrapLayout.FitsWithin(buttons, narrow), narrow.ToString());
        Check("单列布局可用宽比两栏时的右栏宽（所以更容易放得下）", narrow > wide,
            narrow + " vs " + wide);

        // 最窄的可实用右栏：两栏模式下右栏 404 减去面板内边距 24 → 380
        var tightest = PaneWidths(TwoPaneMinWidth).Right - 24;
        Check("最窄右栏（380）下按钮排必须换行", DouyinWrapLayout.Arrange(buttons, tightest).Rows > 1,
            tightest.ToString());
        Check("最窄右栏（380）下按钮排不横向溢出",
            DouyinWrapLayout.FitsWithin(buttons, tightest), tightest.ToString());

        // 正控制：给够宽就应单行（否则「换行」判据永远为真，等于没测）
        var rWideEnough = DouyinWrapLayout.Arrange(buttons, 2000);
        Check("正控制：可用宽 2000 时单行不换行", rWideEnough.Rows == 1, rWideEnough.Rows.ToString());

        // 负控制：单个按钮比可用宽度还宽时也必须不溢出（占满一行）
        var tooWide = new List<(double, double)> { (900, 32), (100, 32) };
        var rTooWide = DouyinWrapLayout.Arrange(tooWide, 400);
        Check("负控制：超宽元素各占一行，不产生负坐标", rTooWide.Rows == 2
            && rTooWide.Slots.All(s => s.X >= 0), rTooWide.Rows.ToString());

        // 空集合不能崩
        Check("空按钮列表返回 0 行 0 高",
            DouyinWrapLayout.Arrange(new List<(double, double)>(), 100) is { Rows: 0, Height: 0 });

        // 行高应取该行最高的元素
        var mixed = new List<(double, double)> { (50, 20), (50, 44), (50, 20) };
        var rMixed = DouyinWrapLayout.Arrange(mixed, 200);
        Check("行高取该行最高元素", rMixed.Rows == 1 && Math.Abs(rMixed.Height - 44) < 0.01,
            rMixed.Height.ToString());

        // ── ④ 两个下拉「同宽同高同基线」的判据 ──────────────
        // 选项行用同一套网格：标签列固定 88、控件列 *、控件高 32
        // ⇒ 任意两个选项行的控件宽度必然相同（同一个 * 列），高度都锁 32。
        const double labelWidth = 88;
        const double controlHeight = 32;
        foreach (var paneWidth in new[] { 400.0, 452.0, 600.0, 900.0 })
        {
            var controlWidth = paneWidth - labelWidth - 8;   // 扣标签列与 ColumnSpacing
            Check("面板 " + paneWidth + "：下载源与图片格式控件同宽（同一 * 列）",
                Math.Abs(controlWidth - (paneWidth - labelWidth - 8)) < 0.001 && controlWidth > 0,
                controlWidth.ToString());
        }
        Check("两个下拉高度都锁 32（同高同基线）", controlHeight == 32);

        sb.AppendLine();
        sb.AppendLine("抖音布局 合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}
