using System;
using Windows.Foundation;
using Microsoft.UI.Xaml.Controls;
using ParseDl.Services.Douyin;

namespace ParseDl.Pages;

/// <summary>
/// 极简换行面板 —— 子元素从左到右排，放不下就换到下一行。
///
/// 为什么自己写一个：WinUI 3 的公共控件里没有 WrapPanel（VariableSizedWrapGrid
/// 只能按固定格子尺寸铺，ItemsRepeater 要配 UniformGridLayout 且面向虚拟化列表）。
/// 抖音解析页那排「全部 / 清空勾选 / 选全部视频 / 选全部图文 / 筛选 / 清空结果」
/// 在窗口变窄时必须换行 —— 原来用单行 Grid，右侧直接被窗口边界裁掉
/// （用户 2026-10-25 报的「右边内容被截断」）。
///
/// 布局数学在 Services/Douyin/DouyinWrapLayout.cs（纯函数，有离线自测）。
/// </summary>
public sealed class DouyinWrapPanel : Panel
{
    /// <summary>行间距（像素）。</summary>
    public double RowGap { get; set; } = 6;

    /// <summary>列间距（像素）。</summary>
    public double ColumnGap { get; set; } = 6;

    private DouyinWrapLayoutResult Measure(double availableWidth)
    {
        var items = new (double, double)[Children.Count];
        for (var i = 0; i < Children.Count; i++)
        {
            var c = Children[i];
            c.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            items[i] = (c.DesiredSize.Width, c.DesiredSize.Height);
        }
        return DouyinWrapLayout.Arrange(items, availableWidth, RowGap, ColumnGap);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var r = Measure(availableSize.Width);
        return new Size(r.Width, r.Height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var r = Measure(finalSize.Width);
        for (var i = 0; i < Children.Count; i++)
        {
            var s = r.Slots[i];
            Children[i].Arrange(new Rect(s.X, s.Y, s.Width, s.Height));
        }
        return new Size(r.Width, r.Height);
    }
}
