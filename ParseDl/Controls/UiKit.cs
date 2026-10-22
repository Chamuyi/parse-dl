using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace ParseDl.Controls;

/// <summary>
/// 页面通用构件 —— 与 Flutter 版 lib/widgets/page_header.dart、app_card.dart 对应。
///
/// 存在的意义：Flutter 版每个页面都重复写页头 + 卡片外壳，迁到 XAML 后如果
/// 也逐页复制，样式一改就要改十几处。这里抽成静态工厂，页面只提供内容。
/// </summary>
public static class UiKit
{
    /// <summary>卡片背景（官方半透明令牌，不能自己合成成不透明）。</summary>
    public static Brush CardBackground =>
        (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"];

    /// <summary>卡片描边。</summary>
    public static Brush CardBorder =>
        (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"];

    /// <summary>次级填充（图标块、输入框底色）。</summary>
    public static Brush SubtleFill =>
        (Brush)Application.Current.Resources["ControlFillColorSecondaryBrush"];

    /// <summary>强调色。</summary>
    public static Brush AccentFill =>
        (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"];

    /// <summary>强调色上的文字色。</summary>
    public static Brush OnAccentText =>
        (Brush)Application.Current.Resources["TextOnAccentFillColorPrimaryBrush"];

    /// <summary>
    /// 页头：48×48 强调色图标块 + 28px 标题 + 14px 副题（纵向两行）。
    /// 几何与 Flutter 版 PageHeader 一致（照抄图吧的页头画法）。
    /// </summary>
    public static Grid PageHeader(string title, string subtitle, string glyph)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var iconBox = new Border
        {
            Width = 48,
            Height = 48,
            CornerRadius = new CornerRadius(8),
            Background = AccentFill,
            VerticalAlignment = VerticalAlignment.Top,
            Child = new FontIcon
            {
                Glyph = glyph,
                FontSize = 22,
                Foreground = OnAccentText,
            },
        };
        Grid.SetColumn(iconBox, 0);
        grid.Children.Add(iconBox);

        var texts = new StackPanel
        {
            Margin = new Thickness(16, 0, 0, 0),
            Spacing = 2,
        };
        texts.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 28,
            FontWeight = FontWeights.SemiBold,
        });
        texts.Children.Add(new TextBlock
        {
            Text = subtitle,
            FontSize = 14,
            Opacity = 0.7,
        });
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);

        return grid;
    }

    /// <summary>标准卡片：半透明底 + 1px 描边 + 8 圆角 + 16 内边距。</summary>
    public static Border Card(UIElement content, double padding = 16)
    {
        return new Border
        {
            Background = CardBackground,
            BorderBrush = CardBorder,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(padding),
            Child = content,
        };
    }

    /// <summary>带标题的卡片（Flutter 版 SectionCard 对应物）。</summary>
    public static Border SectionCard(string title, UIElement content, string? trailing = null)
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
            var t = new TextBlock
            {
                Text = trailing,
                FontSize = 12,
                Opacity = 0.6,
                HorizontalAlignment = HorizontalAlignment.Right,
            };
            Grid.SetColumn(t, 1);
            head.Children.Add(t);
        }
        stack.Children.Add(head);
        stack.Children.Add(content);

        return Card(stack);
    }

    /// <summary>键值行：左标签 + 右值（Flutter 版 _InfoRow 对应物）。</summary>
    public static Grid InfoRow(string label, string value, bool selectable = false)
    {
        var grid = new Grid { Margin = new Thickness(0, 3, 0, 3) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        grid.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 13,
            Opacity = 0.7,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var val = new TextBlock
        {
            Text = value,
            FontSize = 13,
            HorizontalAlignment = HorizontalAlignment.Right,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = selectable,
        };
        Grid.SetColumn(val, 1);
        grid.Children.Add(val);

        return grid;
    }

    /// <summary>状态徽标（圆点 + 文字）。</summary>
    public static Border Pill(string text, string glyph, Brush dotBrush)
    {
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        stack.Children.Add(new Ellipse
        {
            Width = 8,
            Height = 8,
            Fill = dotBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });
        stack.Children.Add(new TextBlock { Text = text, FontSize = 12 });

        return new Border
        {
            Background = SubtleFill,
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(10, 4, 10, 4),
            Child = stack,
        };
    }
}