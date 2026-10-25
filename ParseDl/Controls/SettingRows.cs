using System;
using System.Collections.Generic;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace ParseDl.Controls;

/// <summary>
/// 设置项复用件 —— SectionCard / SettingRow / Expander 分组。
///
/// 与 UiKit 的关系：UiKit 是**页面级**构件（页头、标准卡片、键值行），
/// 这里只管**设置项**这一层的几何，所以单独一个文件、不改 UiKit。
///
/// 与 Flutter 版 lib/widgets/section_card.dart、switch_row.dart、
/// field_row.dart、collapsible_group.dart 对应。
///
/// ### 硬性约定（用户 2026-09-30）
/// 设置项的**开关必须与标题同行**，且水平距离 ≤24px，不许推到行尾 ——
/// 整行上千米宽时，开关推到行尾后视线得横穿整页才对上「这个开关是哪一项的」。
/// 所以本文件所有「同行控件」一律用 [InlineGap] = 8px 紧跟标题，
/// 需要右对齐的场景由调用方自己拼，本文件不提供 [GridLength.Auto + *] 的右推版。
/// </summary>
public static class SettingRows
{
    /// <summary>标题与其同行控件之间的水平间距。</summary>
    public const double InlineGap = 8;

    // ── 主题画刷 ────────────────────────────────────────────

    public static Brush CardBackground =>
        (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"];

    public static Brush CardBorder =>
        (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"];

    public static Brush SubtleFill =>
        (Brush)Application.Current.Resources["ControlFillColorSecondaryBrush"];

    public static Brush AccentFill =>
        (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"];

    public static Brush MutedText =>
        (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];

    // ── SectionCard ─────────────────────────────────────────

    /// <summary>卡片：标题（+ 右侧一句说明）+ 内容。半透明底 + 1px 描边 + 8 圆角。</summary>
    public static Border Card(string title, string? trailing, UIElement content)
    {
        var stack = new StackPanel { Spacing = 12 };

        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
        });
        if (!string.IsNullOrEmpty(trailing))
        {
            var tail = new TextBlock
            {
                Text = trailing,
                FontSize = 12,
                Opacity = 0.6,
                TextWrapping = TextWrapping.Wrap,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
                MaxWidth = 420,
                TextAlignment = TextAlignment.Right,
            };
            Grid.SetColumn(tail, 1);
            head.Children.Add(tail);
        }
        stack.Children.Add(head);
        stack.Children.Add(content);

        return new Border
        {
            Background = CardBackground,
            BorderBrush = CardBorder,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(16),
            // **必须显式 Stretch**（2026-10-26 实测）：父级若依赖内容定宽（StackPanel），
            // 卡片会和父级互相等待，最终整列收缩到内容宽（实测 476px，可用宽 1300），
            // 看着既不居中也很空。显式 Stretch + 父级 Grid 才能真正铺满。
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Child = stack,
        };
    }

    // ── SettingRow ──────────────────────────────────────────

    /// <summary>标题 + 一句说明（纵向两行）。说明可省。</summary>
    public static StackPanel Header(string label, string? description)
    {
        var s = new StackPanel { Spacing = 2 };
        s.Children.Add(new TextBlock { Text = label, FontSize = 14, TextWrapping = TextWrapping.Wrap });
        if (!string.IsNullOrEmpty(description)) s.Children.Add(Description(description!));
        return s;
    }

    /// <summary>说明文字（12px、次级色、可换行）。</summary>
    public static TextBlock Description(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Opacity = 0.62,
        TextWrapping = TextWrapping.Wrap,
        LineHeight = 18,
    };

    /// <summary>
    /// 设置项：标题 + 说明 + **宽控件**（控件排在标题行下方、占满整行宽度）。
    /// 用于输入框 / 模板框 / 单选组这类放不进标题行的控件。
    /// </summary>
    public static StackPanel Row(string label, string? description, UIElement control)
    {
        var s = new StackPanel { Spacing = 8 };
        s.Children.Add(Header(label, description));
        s.Children.Add(control);
        return s;
    }

    /// <summary>
    /// 设置项：标题 + 说明 + **同行窄控件**（开关、下拉）。
    /// 控件紧跟标题、间距 [InlineGap]（8px），满足「≤24px、不推到行尾」的约定。
    /// </summary>
    public static StackPanel InlineRow(string label, string? description, UIElement control)
    {
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = InlineGap };
        head.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 14,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (control is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(control);

        var s = new StackPanel { Spacing = 4 };
        s.Children.Add(head);
        if (!string.IsNullOrEmpty(description)) s.Children.Add(Description(description!));
        return s;
    }

    /// <summary>开关项：开关与标题同行（间距 8px），改值即回调。</summary>
    public static UIElement Switch(string label, string? description, bool isOn, Action<bool> onChanged)
    {
        var toggle = new ToggleSwitch
        {
            IsOn = isOn,
            // 关掉 On/Off 文字：中文界面上「开/关」两个词组会把控件撑宽一倍，
            // 而这一栏的语义由标题给出，不需要控件自带文案。
            OnContent = "",
            OffContent = "",
            MinWidth = 0,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, label);
        toggle.Toggled += (_, _) => onChanged(toggle.IsOn);
        return InlineRow(label, description, toggle);
    }

    /// <summary>数字项：标题 + 说明 + 同行数字框。</summary>
    public static UIElement Number(string label, string? description, double value,
        double min, double max, Action<double> onChanged)
    {
        var box = new NumberBox
        {
            Value = value,
            Minimum = min,
            Maximum = max,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
            MinWidth = 150,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, label);
        box.ValueChanged += (_, e) => { if (!double.IsNaN(e.NewValue)) onChanged(e.NewValue); };
        return InlineRow(label, description, box);
    }

    /// <summary>分隔线（同一张卡里分节用）。</summary>
    public static Border Divider() => new()
    {
        Height = 1,
        Background = CardBorder,
        Margin = new Thickness(0, 4, 0, 4),
        HorizontalAlignment = HorizontalAlignment.Stretch,
    };

    // ── Expander 分组 ───────────────────────────────────────

    /// <summary>
    /// 可折叠分组 —— 标题一行 + 展开后的内容。
    /// 与 Flutter 版 collapsible_group.dart 对应；默认展开（设置页打开即见当前值）。
    /// </summary>
    public static Expander Group(string header, string? subtitle, UIElement content, bool isExpanded = true)
    {
        var body = new StackPanel { Spacing = 8, Padding = new Thickness(0, 12, 0, 4) };
        if (!string.IsNullOrEmpty(subtitle))
        {
            body.Children.Add(new TextBlock
            {
                Text = subtitle,
                FontSize = 12,
                Opacity = 0.62,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        body.Children.Add(content);

        return new Expander
        {
            Header = header,
            IsExpanded = isExpanded,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = body,
        };
    }

    // ── 分段单选（材质档、深浅） ────────────────────────────

    /// <summary>
    /// 分段单选组：一个横排的 RadioButton 组，返回 (容器, 设置选中项的回调)。
    /// </summary>
    public static (StackPanel Panel, Action<string> Select) Segments(
        IReadOnlyList<(string Id, string Label)> options, string selectedId, Action<string> onPick)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var radios = new List<(string Id, RadioButton Rb)>();
        var group = "seg-" + Guid.NewGuid().ToString("N");

        foreach (var (id, label) in options)
        {
            var rb = new RadioButton { Content = label, GroupName = group, Tag = id };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(rb, label);
            if (id == selectedId) rb.IsChecked = true;
            rb.Checked += (_, _) => onPick(id);
            radios.Add((id, rb));
            panel.Children.Add(rb);
        }

        void Select(string id)
        {
            foreach (var (rid, rb) in radios)
            {
                if (rid == id) rb.IsChecked = true;
            }
        }

        return (panel, Select);
    }
}
