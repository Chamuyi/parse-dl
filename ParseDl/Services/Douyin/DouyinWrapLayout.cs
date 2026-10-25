using System;
using System.Collections.Generic;

namespace ParseDl.Services.Douyin;

/// <summary>换行布局里一个元素的位置与尺寸。</summary>
public readonly record struct DouyinWrapSlot(double X, double Y, double Width, double Height);

/// <summary>换行布局的度量结果。</summary>
public readonly record struct DouyinWrapLayoutResult(
    List<DouyinWrapSlot> Slots, double Width, double Height, int Rows);

/// <summary>
/// 「放不下就换行」的纯布局算法 —— 从页面里的 DouyinWrapPanel 抽出来，
/// 这样它可以被离线自测覆盖（面板本身依赖 WinUI 类型，跑不了单测）。
///
/// 为什么需要它：抖音解析页那排「全部 / 清空勾选 / 选全部视频 / 选全部图文 /
/// 筛选 / 清空结果」在窗口变窄时**必须换行**。原来用单行 Grid，
/// 右侧按钮直接被窗口右边界裁掉（用户 2026-10-25 报的「右边内容被截断」）。
/// </summary>
public static class DouyinWrapLayout
{
    /// <summary>
    /// 按可用宽度把若干定宽元素排成多行。
    /// 与 WinUI 面板同一套规则：元素间留 ColumnGap，换行时留 RowGap。
    /// </summary>
    public static DouyinWrapLayoutResult Arrange(
        IReadOnlyList<(double Width, double Height)> items,
        double maxWidth,
        double rowGap = 6,
        double columnGap = 6)
    {
        var slots = new List<DouyinWrapSlot>();
        double x = 0, y = 0, rowHeight = 0, maxUsed = 0;
        var rows = items.Count == 0 ? 0 : 1;

        foreach (var it in items)
        {
            if (x > 0 && x + it.Width > maxWidth)
            {
                // 换行
                y += rowHeight + rowGap;
                x = 0;
                rowHeight = 0;
                rows++;
            }

            slots.Add(new DouyinWrapSlot(x, y, it.Width, it.Height));
            x += it.Width + columnGap;
            maxUsed = Math.Max(maxUsed, x - columnGap);
            rowHeight = Math.Max(rowHeight, it.Height);
        }

        var width = double.IsInfinity(maxWidth) ? maxUsed : Math.Min(maxUsed, maxWidth);
        return new DouyinWrapLayoutResult(slots, width, y + rowHeight, rows);
    }

    /// <summary>单行放不下、必须换行 —— 判据用（界面上「是否被截断」的等价条件）。</summary>
    public static bool NeedsWrap(IReadOnlyList<(double Width, double Height)> items,
        double maxWidth, double columnGap = 6)
        => Arrange(items, maxWidth, 0, columnGap).Rows > 1;

    /// <summary>所有元素的最右边界是否都不超过可用宽度（= 不会被横向截断）。</summary>
    public static bool FitsWithin(IReadOnlyList<(double Width, double Height)> items,
        double maxWidth, double columnGap = 6)
        => Arrange(items, maxWidth, 0, columnGap).Slots
            .TrueForAll(s => s.X + s.Width <= maxWidth + 0.001);
}
