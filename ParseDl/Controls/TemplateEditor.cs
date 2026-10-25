using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace ParseDl.Controls;

/// <summary>
/// 「可用变量」表里的一行元数据（设置页展示用）。
///
/// Name 不含百分号；ParamExample 是该变量第一个参数的示例写法（如 d=0），
/// ParamDesc 是它的中文说明（如「仅日期（0 或 1）」）。两个都空表示该变量不带参数。
/// </summary>
public sealed record TemplateVarInfo(
    string Name,
    string Desc,
    string ParamExample = "",
    string ParamDesc = "")
{
    /// <summary>插入模板时用的完整记号（含首尾百分号）。</summary>
    public string Token => "%" + Name + "%";
}

/// <summary>一个模板字段的构造参数。</summary>
public sealed class TemplateFieldOptions
{
    /// <summary>字段标签（如「文件夹模板」）。</summary>
    public string Label { get; set; } = "";

    /// <summary>输入框占位提示（如 %USER_SCREEN_NAME%）。</summary>
    public string Hint { get; set; } = "";

    /// <summary>「填入默认」写入的模板。</summary>
    public string DefaultTemplate { get; set; } = "";

    /// <summary>模板为空时「输出示例」那一行显示的说明。</summary>
    public string EmptyHint { get; set; } = "";

    /// <summary>实时输出示例的渲染函数（与真正下载用同一个模板引擎，避免预览与产出漂移）。</summary>
    public Func<string, string>? Preview { get; set; }

    /// <summary>字段是否可编辑（如「启用保存文件夹」关掉后的文件夹模板）。</summary>
    public bool Enabled { get; set; } = true;
}

/// <summary>某个模板字段的值变了。</summary>
public sealed class TemplateFieldValueChangedEventArgs : EventArgs
{
    public TemplateField Field { get; }
    public string Value { get; }

    public TemplateFieldValueChangedEventArgs(TemplateField field, string value)
    {
        Field = field;
        Value = value;
    }
}

/// <summary>
/// 一行模板字段：标签 + 「填入默认」 + 输入框 + 「输出示例」。
///
/// 与 Flutter 版 lib/widgets/template_row.dart 的 TemplateRow 逐件对应：
/// 标签（含「填入默认」）/ 输入框（等宽字体）/ 输出示例（等宽、可选文本）。
/// </summary>
public sealed class TemplateField : StackPanel
{
    private readonly TextBox _box;
    private readonly TextBlock _example;
    private readonly HyperlinkButton _useDefault;
    private readonly Func<string, string>? _preview;
    private readonly string _emptyHint;
    private bool _suppress;

    internal TemplateField(TemplateFieldOptions options, string initialValue)
    {
        Spacing = 6;
        HorizontalAlignment = HorizontalAlignment.Stretch;

        Label = options.Label;
        DefaultTemplate = options.DefaultTemplate;
        _emptyHint = options.EmptyHint;
        _preview = options.Preview;

        // 标签行：左标签、右「填入默认」（对齐 template_row 的 label + 小按钮）
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(new TextBlock
        {
            Text = options.Label,
            FontSize = 14,
            VerticalAlignment = VerticalAlignment.Center,
        });

        _useDefault = new HyperlinkButton
        {
            Content = "填入默认",
            FontSize = 12,
            Padding = new Thickness(6, 0, 6, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(_useDefault, options.Label + "：填入默认模板");
        _useDefault.Click += (_, _) => SetValue(DefaultTemplate);
        Grid.SetColumn(_useDefault, 1);
        head.Children.Add(_useDefault);
        Children.Add(head);

        _box = new TextBox
        {
            Text = initialValue ?? "",
            PlaceholderText = options.Hint,
            FontFamily = new FontFamily("Consolas"),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(_box, options.Label);
        _box.TextChanged += (_, _) =>
        {
            RefreshExample();
            if (!_suppress) ValueChanged?.Invoke(this, new TemplateFieldValueChangedEventArgs(this, Value));
        };
        Children.Add(_box);

        _example = new TextBlock
        {
            FontSize = 11.5,
            Opacity = 0.75,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        Children.Add(_example);

        if (!options.Enabled) SetEnabled(false);
        RefreshExample();
    }

    /// <summary>字段标签。</summary>
    public string Label { get; }

    /// <summary>「填入默认」写入的模板。</summary>
    public string DefaultTemplate { get; }

    /// <summary>字段内的输入框（供页面接管焦点或读取选择区）。</summary>
    public TextBox Input => _box;

    /// <summary>当前模板文本。</summary>
    public string Value => _box.Text ?? "";

    /// <summary>输入框当前是否可编辑。</summary>
    public bool IsInputEnabled => _box.IsEnabled;

    /// <summary>值变化（用户键入、粘贴、程序 SetValue、点「填入默认」都算）。</summary>
    public event EventHandler<TemplateFieldValueChangedEventArgs>? ValueChanged;

    /// <summary>写入模板并触发 ValueChanged（值相同则只刷新示例）。</summary>
    public void SetValue(string value)
    {
        value ??= "";
        if ((_box.Text ?? "") == value)
        {
            RefreshExample();
            return;
        }

        _suppress = true;
        _box.Text = value;
        _suppress = false;

        RefreshExample();
        ValueChanged?.Invoke(this, new TemplateFieldValueChangedEventArgs(this, value));
    }

    /// <summary>启用 / 禁用本行（禁用时整体降透明度，与 Flutter 版 0.45 同口径）。</summary>
    public void SetEnabled(bool enabled)
    {
        _box.IsEnabled = enabled;
        _useDefault.IsEnabled = enabled;
        Opacity = enabled ? 1.0 : 0.45;
    }

    /// <summary>把变量插到本字段输入框的光标处（有选区则替换选区）。</summary>
    public void InsertAtCaret(string token)
    {
        var text = _box.Text ?? "";
        var start = _box.SelectionStart;
        if (start < 0 || start > text.Length) start = text.Length;
        var length = _box.SelectionLength;
        if (length < 0 || start + length > text.Length) length = 0;

        _box.Text = text.Remove(start, length).Insert(start, token);

        // 先聚焦再定光标：WinUI 里焦点变化会把选择区复位，顺序反了光标会跑回开头。
        _box.Focus(FocusState.Programmatic);
        _box.SelectionStart = start + token.Length;
        _box.SelectionLength = 0;
    }

    /// <summary>重算「输出示例」那一行。</summary>
    internal void RefreshExample()
    {
        var text = _box.Text ?? "";
        if (string.IsNullOrWhiteSpace(text))
        {
            _example.Text = "输出示例：" + _emptyHint;
            _example.Opacity = 0.5;
            return;
        }

        string rendered;
        try
        {
            rendered = _preview is null ? text : _preview(text);
        }
        catch (Exception ex)
        {
            rendered = "（渲染失败：" + ex.Message + "）";
        }

        _example.Text = "输出示例：" + (string.IsNullOrWhiteSpace(rendered) ? _emptyHint : rendered);
        _example.Opacity = 0.85;
    }
}

/// <summary>
/// 模板编辑控件 —— 一组模板字段（文件夹模板 / 文件名模板）加一份「可用变量」可展开面板。
///
/// ### 为什么做成一个控件（对齐 Flutter 版 lib/widgets/template_row.dart）
/// 原项目把「变量表 + 输入框 + 输出示例」打包成一件事：点某个变量的「插入」，
/// 就把它插进当前正在编辑的那个模板框。WinUI3 旧实现把变量表挂在两张模板框
/// 下面、插入却写死文件名模板（用户 2026-10-25 的原话：「变量插入只会插入到
/// 文件名里面」）—— 本控件就是修这件事：
///
///   1. 变量面板是【一份】，字段可以有多个（文件夹模板 + 文件名模板）；
///   2. 点「插入」时按【最后获得焦点的那个模板框】决定插入目标（_lastFocused），
///      没有聚焦过则回退到第一个可编辑字段；
///   3. 焦点不能用 FocusManager 现查 —— 点「插入」按钮时输入框已经失焦，
///      所以必须在 TextBox.GotFocus 里记录最后聚焦的模板框。
///
/// ### 三个模块共用
/// 变量表由页面传入（X 传本平台那份、抖音传抖音那份），控件本身不写死任何
/// 平台术语 —— 设置页只有「一份实现」，三处长得一样、行为也一样。
/// </summary>
public sealed class TemplateEditor : UserControl
{
    private readonly StackPanel _root;
    private readonly List<TemplateField> _fields = new();
    private readonly IReadOnlyList<TemplateVarInfo> _vars;
    private readonly string? _variableHint;
    private TemplateField? _lastFocused;

    public TemplateEditor(IReadOnlyList<TemplateVarInfo> variables, string? variableHint = null)
    {
        _vars = variables ?? Array.Empty<TemplateVarInfo>();
        _variableHint = variableHint;

        HorizontalAlignment = HorizontalAlignment.Stretch;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalAlignment = VerticalAlignment.Top;
        VerticalContentAlignment = VerticalAlignment.Top;

        _root = new StackPanel { Spacing = 16, HorizontalAlignment = HorizontalAlignment.Stretch };

        // 变量面板与「恢复默认模板」固定在末尾；AddField 时把字段插到它们之前。
        var tail = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Stretch };
        tail.Children.Add(BuildVariablePanel());
        tail.Children.Add(BuildRestoreRow());
        _root.Children.Add(tail);

        Content = _root;
    }

    /// <summary>已添加的字段（按添加顺序）。</summary>
    public IReadOnlyList<TemplateField> Fields => _fields;

    /// <summary>任一字段的值发生变化。</summary>
    public event EventHandler<TemplateFieldValueChangedEventArgs>? FieldChanged;

    /// <summary>添加一个模板字段（文件夹模板 / 文件名模板），返回它的句柄。</summary>
    public TemplateField AddField(TemplateFieldOptions options, string initialValue)
    {
        var field = new TemplateField(options, initialValue);
        field.Input.GotFocus += (_, _) => _lastFocused = field;
        field.ValueChanged += (_, e) => FieldChanged?.Invoke(this, e);

        _fields.Add(field);
        // 插到末尾的变量面板之前，保证字段永远排在面板上方
        _root.Children.Insert(_root.Children.Count - 1, field);
        return field;
    }

    /// <summary>
    /// 把变量插到最后获得焦点的那个模板框的光标处；没有被聚焦过的框时
    /// 回退到第一个可编辑字段（两个都禁用时什么都不做）。
    /// </summary>
    public void InsertToken(string token)
    {
        var target = _lastFocused;
        if (target is null || !target.IsInputEnabled)
            target = _fields.FirstOrDefault(f => f.IsInputEnabled);
        if (target is null) return;

        target.InsertAtCaret(token);
        _lastFocused = target;
    }

    /// <summary>所有字段恢复各自默认模板。</summary>
    public void RestoreDefaults()
    {
        foreach (var field in _fields) field.SetValue(field.DefaultTemplate);
    }

    /// <summary>重算所有字段的输出示例。</summary>
    public void RefreshAll()
    {
        foreach (var field in _fields) field.RefreshExample();
    }

    // ── 变量面板 ────────────────────────────────────────────

    private UIElement BuildVariablePanel()
    {
        var head = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        head.Children.Add(new FontIcon
        {
            Glyph = "\uE943",
            FontSize = 14,
            VerticalAlignment = VerticalAlignment.Center,
        });
        head.Children.Add(new TextBlock
        {
            Text = "可用变量",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        head.Children.Add(new TextBlock
        {
            Text = "共 " + _vars.Count + " 个，点击「插入」插到当前正在编辑的模板框",
            FontSize = 11.5,
            Opacity = 0.6,
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
        });

        var body = new StackPanel
        {
            Spacing = 8,
            Padding = new Thickness(0, 8, 0, 6),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };

        body.Children.Add(new TextBlock
        {
            Text = "用百分号包住变量名，如 %USER_SCREEN_NAME%。尖括号包住的是可选段："
                 + "段内变量为空时整段（含字面字符）丢弃。",
            FontSize = 11.5,
            Opacity = 0.62,
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 18,
        });

        var list = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var v in _vars) list.Children.Add(BuildVarRow(v));
        body.Children.Add(list);

        var paramHint = BuildParamHint();
        if (paramHint.Length > 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = paramHint,
                FontSize = 11.5,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
                LineHeight = 18,
            });
        }

        if (!string.IsNullOrEmpty(_variableHint))
        {
            body.Children.Add(new TextBlock
            {
                Text = _variableHint,
                FontSize = 11.5,
                Opacity = 0.62,
                TextWrapping = TextWrapping.Wrap,
                LineHeight = 18,
            });
        }

        return new Expander
        {
            Header = head,
            IsExpanded = true,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = body,
        };
    }

    private UIElement BuildVarRow(TemplateVarInfo v)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(210) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        row.Children.Add(new TextBlock
        {
            Text = v.Token,
            FontSize = 12,
            FontFamily = new FontFamily("Consolas"),
            VerticalAlignment = VerticalAlignment.Center,
        });

        var descText = v.Desc;
        if (!string.IsNullOrEmpty(v.ParamExample))
        {
            descText += "（参数 " + v.ParamExample
                        + (string.IsNullOrEmpty(v.ParamDesc) ? "" : "：" + v.ParamDesc) + "）";
        }

        var desc = new TextBlock
        {
            Text = descText,
            FontSize = 12,
            Opacity = 0.62,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(desc, 1);
        row.Children.Add(desc);

        var insert = new Button
        {
            Content = "插入",
            FontSize = 12,
            Padding = new Thickness(10, 2, 10, 2),
        };
        AutomationProperties.SetName(insert, "插入变量 " + v.Name);
        insert.Click += (_, _) => InsertToken(v.Token);
        Grid.SetColumn(insert, 2);
        row.Children.Add(insert);

        return row;
    }

    /// <summary>
    /// 「参数格式」提示行 —— 例子从本平台变量表里挑第一个带参数的变量生成，
    /// 所以 X 设置里举的是 X 的例子、抖音设置里举的是抖音的例子，不写死变量名。
    /// </summary>
    private string BuildParamHint()
    {
        var withParams = _vars.FirstOrDefault(v => !string.IsNullOrEmpty(v.ParamExample));
        if (withParams is null) return "参数格式：%VARIABLE,a=1,b=2%。";

        var desc = string.IsNullOrEmpty(withParams.ParamDesc) ? "" : "（" + withParams.ParamDesc + "）";
        return "参数格式：%VARIABLE,a=1,b=2%，如 %" + withParams.Name + ","
               + withParams.ParamExample + "%" + desc + "。";
    }

    private UIElement BuildRestoreRow()
    {
        var restore = new Button { Content = "恢复默认模板", FontSize = 12 };
        AutomationProperties.SetName(restore, "恢复默认模板");
        restore.Click += (_, _) => RestoreDefaults();
        return restore;
    }
}
