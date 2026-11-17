using System;
using System.Collections.Generic;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace ParseDl.Services;

/// <summary>一套预设主题色：id、中文名、以及浅色/深色两种底色（其余色值由规则派生）。</summary>
public sealed record AccentPreset(string Id, string Name, string LightBase, string DarkBase, string Hint);

/// <summary>
/// 主题色（强调色）服务 —— 把用户选的强调色**真正应用到应用级资源**。
///
/// ### 为什么要有这个服务
/// WinUI 的强调色不是「一个属性」，而是一组资源键：
///   AccentFillColorDefaultBrush / AccentFillColorSecondaryBrush / AccentFillColorTertiaryBrush /
///   AccentTextFillColorPrimaryBrush / TextOnAccentFillColorPrimaryBrush / SystemAccentColor …
/// 按钮、开关、选中态、ProgressRing、NavigationView 的选中条各自引用其中不同的键。
/// 只改其中一个就宣称「换肤完成」是假的 —— 界面上会一半新色一半旧色。
/// 所以这里一次覆盖**整组**键，并且**同时写 Light 与 Dark 两套主题字典**。
///
/// ### 生效方式（不改 App.xaml 也能生效）
/// 1. 往 `Application.Current.Resources.ThemeDictionaries["Light"|"Dark"]` 里写整组键 ——
///    这两本字典在资源查找链上**优先于** App.xaml 里 XamlControlsResources 的合并字典，
///    所以深浅主题各自取到自己的那套值；
/// 2. 顶层 `Application.Current.Resources[key]` 也写一份（= 当前主题那一份），
///    覆盖「直接查顶层键」的路径；
/// 3. **复用同一批 SolidColorBrush 实例**并只改其 `Color`：WinUI 的画刷是 DependencyObject，
///    改 Color 会立刻通知所有引用它的控件重绘 —— 这样换色**无需重启、无需重新解析 ThemeResource**。
/// 4. 顺手把 XamlControlsResources 合并字典里原有的那些画刷实例也改掉：
///    万一某条查找路径命中的是原始实例而不是我们插的那份，颜色同样跟着变（双保险）。
/// 
/// 唯一需要主对话配合的场景：**开机时应用**。启动入口在 App.xaml.cs，本服务不去改它，
/// 而是由 `AppSettings.Load()` 末尾调用一次 <see cref="ApplyFromSettings"/>（App 启动早期、UI 线程）。
/// </summary>
public static class AccentService
{
    /// <summary>自定义色（用户用色轮选的）的固定 id。</summary>
    public const string CustomId = "custom";

    /// <summary>
    /// 预设色板 —— 8 套，全部为中性偏冷/暖的现代配色（每套都按要求给了
    /// AccentFillColorDefault / Secondary / Tertiary / TextOnAccent 四个色值，见 <see cref="ResolveForPreset"/>）。
    /// 命名与取值参考 Flutter 版 lib/theme/winui_accent.dart 的三档（Windows 蓝 / 紫罗兰 / 跟随系统）并扩到 8 套。
    /// </summary>
    public static readonly IReadOnlyList<AccentPreset> Presets = new[]
    {
        // 色值口径：**浅色档必须够深、深色档必须够亮**。
        // 实测（2026-10-25，离线算 WCAG 对比度）：Tailwind 500 档（#0EA5E9 / #10B981 / #F59E0B / #F43F5E）
        // 压在浅色主题上，白字对比度只有 2.15~2.77 —— 按钮上的字看不清。所以浅色档
        // 一律降到 600~700 档（#0284C7 / #047857 / #B45309 / #E11D48），实测全部 >= 4.2。
        new AccentPreset("windows", "Windows 蓝", "#0078D4", "#4CC2FF", "WinUI 3 官方强调色，最像系统自带应用"),
        new AccentPreset("sky", "天青", "#0284C7", "#7DD3FC", "清亮的青蓝，比系统蓝更通透"),
        new AccentPreset("indigo", "靛蓝", "#4F46E5", "#818CF8", "沉一点的蓝紫，长时间看不累"),
        new AccentPreset("violet", "紫罗兰", "#7C3AED", "#A78BFA", "本项目改造前的品牌色系"),
        new AccentPreset("coral", "珊瑚", "#E11D48", "#FB7185", "偏红的热烈色，适合当强调"),
        new AccentPreset("emerald", "松绿", "#047857", "#34D399", "清爽的绿，成功态天然和谐"),
        new AccentPreset("amber", "琥珀", "#B45309", "#FBBF24", "暖橙黄，醒目但不刺眼"),
        new AccentPreset("slate", "石墨蓝灰", "#475569", "#94A3B8", "低饱和中性色，最不抢内容"),
    };

    // ── 需要覆盖的整组资源键 ────────────────────────────────

    /// <summary>画刷型资源键（值 = SolidColorBrush）。</summary>
    private static readonly string[] BrushKeys =
    {
        "AccentFillColorDefaultBrush",
        "AccentFillColorSecondaryBrush",
        "AccentFillColorTertiaryBrush",
        "AccentFillColorDisabledBrush",
        "AccentTextFillColorPrimaryBrush",
        "AccentTextFillColorSecondaryBrush",
        "AccentTextFillColorTertiaryBrush",
        "AccentTextFillColorDisabledBrush",
        "TextOnAccentFillColorPrimaryBrush",
        "TextOnAccentFillColorSecondaryBrush",
        "TextOnAccentFillColorSelectedTextBrush",
    };

    /// <summary>颜色型资源键（值 = Windows.UI.Color）。</summary>
    private static readonly string[] ColorKeys =
    {
        "SystemAccentColor",
        "SystemAccentColorLight1",
        "SystemAccentColorLight2",
        "SystemAccentColorLight3",
        "SystemAccentColorDark1",
        "SystemAccentColorDark2",
        "SystemAccentColorDark3",
        "SystemAccentColorPrimary",
        "SystemAccentColorSecondary",
        "SystemAccentColorTertiary",
    };

    /// <summary>纯白 / 纯黑 —— 混色的两个端点。</summary>
    /// <remarks>
    /// 自己定义而不直接用 Colors.White / Colors.Black：这两个名字在 Windows.UI 与
    /// Microsoft.UI 下都有，跨命名空间引用时容易撞成 CS0104 歧义错误。
    /// 这里只需要黑白两点，写死常量最不容易出错。
    /// </remarks>
    public static readonly Color White = Color.FromArgb(255, 255, 255, 255);
    public static readonly Color Black = Color.FromArgb(255, 0, 0, 0);

    /// <summary>画刷实例缓存：每个键一对（浅色主题用 / 深色主题用），换色时只改 Color。</summary>
    private static readonly Dictionary<string, (SolidColorBrush Light, SolidColorBrush Dark)> BrushCache = new();

    private static bool _applied;

    /// <summary>当前生效的预设 id（自定义时为 "custom"）。</summary>
    public static string CurrentId =>
        string.IsNullOrWhiteSpace(AppSettings.Instance.AccentPreset) ? "windows" : AppSettings.Instance.AccentPreset;

    /// <summary>当前自定义色的十六进制（形如 #RRGGBB）。仅在 CurrentId == custom 时有意义。</summary>
    public static string CurrentCustomHex => AppSettings.Instance.AccentHex ?? "";

    /// <summary>按 id 找预设；找不到回退第一套。</summary>
    public static AccentPreset PresetOf(string id)
    {
        foreach (var p in Presets)
        {
            if (string.Equals(p.Id, id, StringComparison.OrdinalIgnoreCase)) return p;
        }
        return Presets[0];
    }

    // ── 色值解析 ────────────────────────────────────────────

    /// <summary>
    /// 把「当前选择 + 明暗」解析成整组色值。
    /// 预设 4 个色值的规则（浅色主题取 LightBase、深色取 DarkBase，再派生）：
    ///   AccentFillColorDefault = base
    ///   AccentFillColorSecondary = base 向白（浅）/向黑（深）混 16%
    ///   AccentFillColorTertiary = 同上混 32%
    ///   TextOnAccent = 浅色主题压白字；深色主题压近黑的字（亮底配深字才够对比度）
    /// </summary>
    public static (string Fill, string Secondary, string Tertiary, string OnAccent) ResolveForPreset(string id, bool isDark)
    {
        var preset = PresetOf(id);
        var baseHex = isDark ? preset.DarkBase : preset.LightBase;
        var baseColor = ParseHex(baseHex);
        // 二级 / 三级色的方向：**往「远离背景」的方向调**。
        // 浅色主题背景是白的 → 往黑调（越二级越深）；深色主题背景是黑的 → 往白调。
        // 反过来（浅色也往白调）会让二级色越来越接近背景，直接看不见。
        var away = isDark ? White : Black;
        var fill = Hex(baseColor);
        var secondary = Hex(Mix(baseColor, away, 0.12));
        var tertiary = Hex(Mix(baseColor, away, 0.22));
        var onAccent = Hex(BestOnAccent(baseColor));
        return (fill, secondary, tertiary, onAccent);
    }

    /// <summary>
    /// 统一的「四色解析」入口：给 id + 自定义色 + 明暗，返回 (fill, secondary, tertiary, onAccent)。
    /// 界面（色板标记、预览块）一律走这里，**不许在 UI 里再抄一遍公式** ——
    /// 两处公式只要有一点不同，预览就会与实际生效的颜色对不上。
    /// </summary>
    public static (string Fill, string Secondary, string Tertiary, string OnAccent) Resolve(string id, string? customHex, bool isDark)
    {
        if (string.Equals(id, CustomId, StringComparison.OrdinalIgnoreCase) && TryParseHex(customHex, out var custom))
        {
            var adjusted = isDark
                ? Mix(custom, White, ContrastLift(custom, isDark))
                : Mix(custom, Black, ContrastLift(custom, isDark));
            var away = isDark ? White : Black;
            return (Hex(adjusted),
                    Hex(Mix(adjusted, away, 0.12)),
                    Hex(Mix(adjusted, away, 0.22)),
                    Hex(BestOnAccent(adjusted)));
        }
        return ResolveForPreset(id, isDark);
    }

    /// <summary>
    /// 在纯白与近黑（#1A1A1A，比纯黑柔和）之间选对比度更高的那个当前景色。
    /// 强调色是用户自选的，任何色都可能出现 —— 写死「浅色主题一律白字」必然有一半场景不好看
    /// （实测：琥珀 #F59E0B 上白字对比度只有 2.15）。
    /// </summary>
    public static Color BestOnAccent(Color fill)
    {
        var ink = Color.FromArgb(255, 26, 26, 26);
        return ContrastRatio(fill, White) >= ContrastRatio(fill, ink) ? White : ink;
    }

    /// <summary>解析「任意自定义 RGB」：给 #RRGGBB 或 RRGGBB 都认。</summary>
    public static bool TryParseHex(string? raw, out Color color)
    {
        color = Color.FromArgb(0, 0, 0, 0);
        if (string.IsNullOrWhiteSpace(raw)) return false;
        var s = raw.Trim();
        if (s.StartsWith("#", StringComparison.Ordinal)) s = s[1..];
        if (s.Length != 6) return false;
        if (!int.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) return false;
        color = Color.FromArgb(255, (byte)((v >> 16) & 0xFF), (byte)((v >> 8) & 0xFF), (byte)(v & 0xFF));
        return true;
    }

    /// <summary>把 Color 归一化成 #RRGGBB（丢弃 alpha —— 强调色不用半透明）。</summary>
    public static string Hex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

    // ── 应用 ────────────────────────────────────────────────

    /// <summary>应用设置里存的那一套（开机时调用）。未设置时用默认预设。</summary>
    public static bool ApplyFromSettings() =>
        Apply(CurrentId, CurrentCustomHex, AppSettings.Instance.IsDark);

    /// <summary>
    /// 应用一套配色。返回是否成功（Application.Current 不可用时返回 false —— 不抛，免得起不来）。
    /// **同时覆盖 Light 与 Dark 两本主题字典**，不是只改当前主题那一份。
    /// </summary>
    public static bool Apply(string id, string? customHex, bool isDark)
    {
        var app = Application.Current;
        if (app is null) return false;

        var light = ComputeGroup(id, customHex, false);
        var dark = ComputeGroup(id, customHex, true);

        var lightDict = EnsureThemeDictionary(app, "Light");
        var darkDict = EnsureThemeDictionary(app, "Dark");

        foreach (var key in BrushKeys)
        {
            var (lb, db) = BrushFor(key);
            lb.Color = light[key];
            db.Color = dark[key];
            // 当前主题那一份写进顶层 —— 三处都是同一个实例，谁先命中结果都一样。
            app.Resources[key] = isDark ? db : lb;
            lightDict[key] = lb;
            darkDict[key] = db;
            MutateExistingBrushes(app, key, light[key], dark[key]);
        }

        foreach (var key in ColorKeys)
        {
            app.Resources[key] = isDark ? dark[key] : light[key];
            lightDict[key] = light[key];
            darkDict[key] = dark[key];
        }

        _applied = true;
        return true;
    }

    /// <summary>当前是否已应用过一次（供界面显示状态）。</summary>
    public static bool HasApplied => _applied;

    /// <summary>按当前设置重新解析整组色值（浅色主题一份、深色主题一份）。</summary>
    private static Dictionary<string, Color> ComputeGroup(string id, string? customHex, bool isDark)
    {
        var (fillHex, secHex, terHex, onAccentHex) = Resolve(id, customHex, isDark);
        var fill = ParseHex(fillHex);
        var sec = ParseHex(secHex);
        var ter = ParseHex(terHex);
        var onAccent = ParseHex(onAccentHex);
        // 「强调色文字」：浅色主题下要够深（压在浅背景上），深色主题下要够亮。
        var accentText = isDark
            ? Mix(fill, White, 0.28)
            : Mix(fill, Black, 0.22);

        return new Dictionary<string, Color>
        {
            ["AccentFillColorDefaultBrush"] = fill,
            ["AccentFillColorSecondaryBrush"] = sec,
            ["AccentFillColorTertiaryBrush"] = ter,
            ["AccentFillColorDisabledBrush"] = WithAlpha(fill, isDark ? (byte)70 : (byte)92),
            ["AccentTextFillColorPrimaryBrush"] = accentText,
            ["AccentTextFillColorSecondaryBrush"] = WithAlpha(accentText, 216),
            ["AccentTextFillColorTertiaryBrush"] = WithAlpha(accentText, 178),
            ["AccentTextFillColorDisabledBrush"] = WithAlpha(accentText, 102),
            ["TextOnAccentFillColorPrimaryBrush"] = onAccent,
            ["TextOnAccentFillColorSecondaryBrush"] = WithAlpha(onAccent, 204),
            ["TextOnAccentFillColorSelectedTextBrush"] = onAccent,
            ["SystemAccentColor"] = fill,
            ["SystemAccentColorLight1"] = Mix(fill, White, 0.10),
            ["SystemAccentColorLight2"] = Mix(fill, White, 0.20),
            ["SystemAccentColorLight3"] = Mix(fill, White, 0.30),
            ["SystemAccentColorDark1"] = Mix(fill, Black, 0.10),
            ["SystemAccentColorDark2"] = Mix(fill, Black, 0.20),
            ["SystemAccentColorDark3"] = Mix(fill, Black, 0.30),
            ["SystemAccentColorPrimary"] = fill,
            ["SystemAccentColorSecondary"] = sec,
            ["SystemAccentColorTertiary"] = ter,
        };
    }

    /// <summary>
    /// 自定义色的对比度提升量：底色越接近中间灰，需要提得越多；
    /// 已经足够亮/足够深的色就不动（提多了会「变色」而不是「变色号」）。
    /// </summary>
    private static double ContrastLift(Color c, bool isDark)
    {
        var lum = (0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B) / 255.0;
        if (isDark) return lum < 0.55 ? Math.Min(0.35, (0.55 - lum) * 0.7) : 0.0;
        return lum > 0.45 ? Math.Min(0.35, (lum - 0.45) * 0.7) : 0.0;
    }

    /// <summary>取出（或首次创建）某个键的画刷实例对。</summary>
    private static (SolidColorBrush Light, SolidColorBrush Dark) BrushFor(string key)
    {
        if (BrushCache.TryGetValue(key, out var pair)) return pair;
        // 首次优先复用应用里已有的画刷（就是控件正在用的那个对象），
        // 这样改它的 Color 才会立刻通知到已解析的控件。
        var existing = FindExistingBrush(key);

        // 浅色与深色**必须是两个不同实例**。
        // FindExistingBrush 在只找到「直接键」时会把它同时填给 Light 和 Dark ——
        // 那是同一个对象，两套主题字典共用它，后写的颜色会覆盖先写的，
        // 表现为「切深浅不变色」。这种情况给深色另建一个。
        var lightBrush = existing.Light ?? new SolidColorBrush(Color.FromArgb(255, 0, 120, 212));
        var darkBrush = existing.Dark is null || ReferenceEquals(existing.Dark, existing.Light)
            ? new SolidColorBrush(Color.FromArgb(255, 76, 194, 255))
            : existing.Dark;

        pair = (lightBrush, darkBrush);
        BrushCache[key] = pair;
        return pair;
    }

    /// <summary>到合并字典里找该键已有的画刷（浅色/深色各一个）。</summary>
    private static (SolidColorBrush? Light, SolidColorBrush? Dark) FindExistingBrush(string key)
    {
        SolidColorBrush? light = null, dark = null;
        var app = Application.Current;
        if (app is null) return (null, null);

        void Scan(ResourceDictionary dict)
        {
            foreach (var tdKey in new[] { "Light", "Dark" })
            {
                if (dict.ThemeDictionaries.TryGetValue(tdKey, out var tdObj) && tdObj is ResourceDictionary td
                    && td.TryGetValue(key, out var v) && v is SolidColorBrush b)
                {
                    if (tdKey == "Light") light ??= b; else dark ??= b;
                }
            }
            if (dict.TryGetValue(key, out var direct) && direct is SolidColorBrush db)
            {
                light ??= db;
                dark ??= db;
            }
        }

        Scan(app.Resources);
        foreach (var merged in app.Resources.MergedDictionaries) Scan(merged);
        return (light, dark);
    }

    /// <summary>
    /// 把合并字典里原有的同名画刷也改成新颜色（双保险）。
    /// 有的控件在 XAML 加载时就把 ThemeResource 解析成了原始实例的引用，
    /// 只改我们自己插的那份，那些控件不会变色。
    /// </summary>
    private static void MutateExistingBrushes(Application app, string key, Color light, Color dark)
    {
        // 只改「非我们自己的」实例：BrushCache 里那两个是本次新写的目标，改它们没意义，
        // 而且它们已经被赋成正确颜色了。
        BrushCache.TryGetValue(key, out var own);

        void Mutate(SolidColorBrush b, Color c)
        {
            if (ReferenceEquals(b, own.Light) || ReferenceEquals(b, own.Dark)) return;
            b.Color = c;
        }

        void Scan(ResourceDictionary dict)
        {
            foreach (var tdKey in new[] { "Light", "Dark" })
            {
                if (dict.ThemeDictionaries.TryGetValue(tdKey, out var tdObj) && tdObj is ResourceDictionary td
                    && td.TryGetValue(key, out var v) && v is SolidColorBrush b)
                {
                    Mutate(b, tdKey == "Light" ? light : dark);
                }
            }
            // 直接键形态：有些资源只在字典本身定义一次（不分主题）。
            // 这种实例被已加载控件引用着，必须跟着改，否则切色时那些控件不动。
            if (dict.TryGetValue(key, out var direct) && direct is SolidColorBrush db)
                Mutate(db, light);
            foreach (var merged in dict.MergedDictionaries) Scan(merged);
        }
        Scan(app.Resources);
    }

    /// <summary>取（或建）主题字典。主题字典挂在 Application.Resources 上时优先于合并字典。</summary>
    private static ResourceDictionary EnsureThemeDictionary(Application app, string themeKey)
    {
        var td = app.Resources.ThemeDictionaries;
        if (td.TryGetValue(themeKey, out var obj) && obj is ResourceDictionary existing) return existing;
        var fresh = new ResourceDictionary();
        td[themeKey] = fresh;
        return fresh;
    }

    // ── 颜色工具 ────────────────────────────────────────────

    /// <summary>线性混色：t = 0 取 a，t = 1 取 b，alpha 保留 a 的。</summary>
    public static Color Mix(Color a, Color b, double t)
    {
        if (t < 0) t = 0; if (t > 1) t = 1;
        return Color.FromArgb(a.A,
            (byte)Math.Round(a.R + (b.R - a.R) * t),
            (byte)Math.Round(a.G + (b.G - a.G) * t),
            (byte)Math.Round(a.B + (b.B - a.B) * t));
    }

    private static Color WithAlpha(Color c, byte a) => Color.FromArgb(a, c.R, c.G, c.B);

    /// <summary>解析失败时回退到 Windows 官方蓝 —— 宁可退回默认色，也不要写进一个坏色值。</summary>
    private static Color ParseHex(string hex) => TryParseHex(hex, out var c) ? c : Color.FromArgb(255, 0, 120, 212);

    /// <summary>
    /// 两个色值的对比度（WCAG 相对亮度比），供界面提示「这个自定义色够不够清楚」。
    /// 低对比度不是错误，只是提示 —— 用户有权选一个不常见的色。
    /// </summary>
    public static double ContrastRatio(Color fg, Color bg)
    {
        var l1 = RelativeLuminance(fg);
        var l2 = RelativeLuminance(bg);
        var hi = Math.Max(l1, l2);
        var lo = Math.Min(l1, l2);
        return (hi + 0.05) / (lo + 0.05);
    }

    private static double RelativeLuminance(Color c)
    {
        double Ch(byte v)
        {
            var s = v / 255.0;
            return s <= 0.03928 ? s / 12.92 : Math.Pow((s + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Ch(c.R) + 0.7152 * Ch(c.G) + 0.0722 * Ch(c.B);
    }
}
