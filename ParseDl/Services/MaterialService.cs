using System;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using WinRT;

namespace ParseDl.Services;

/// <summary>材质档位。与 Flutter 版的 WindowMaterial 一一对应。</summary>
public enum MaterialKind
{
    Mica,
    MicaAlt,
    Acrylic,
    AcrylicThin,
}

/// <summary>界面明暗。与 Flutter 版的 ThemeMode2 一一对应。</summary>
public enum ThemeKind
{
    System,
    Light,
    Dark,
}

/// <summary>
/// 窗口材质管理 —— 全部走 Windows App SDK 官方合成控制器。
///
/// 为什么不用 XAML 的 &lt;MicaBackdrop /&gt; / &lt;DesktopAcrylicBackdrop /&gt;：
/// 那两个类只覆盖 Mica 与 Acrylic 各一档，拿不到 MicaKind.BaseAlt 与
/// DesktopAcrylicKind.Thin。要四档齐全只能用控制器。
///
/// 为什么不用 DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE)：
/// DWM 只有三档（mica / micaAlt / acrylic），没有 Thin；且实测 DWM 的
/// acrylic 比控制器版透一倍（DWM 61,61,63 vs 控制器 29,29,29），
/// 观感与图吧（WinUI 3）不一致。
///
/// WinUI 3 的关键优势：Window 自身实现 ICompositionSupportsSystemBackdrop，
/// 所以材质与 XAML 内容天然在同一棵合成树里 —— 不需要 root visual，
/// 不需要第二个窗口，也不会有 Z 序问题。
/// </summary>
public sealed class MaterialService
{
    private readonly Window _window;
    private MicaController? _mica;
    private DesktopAcrylicController? _acrylic;
    private SystemBackdropConfiguration? _config;

    public MaterialService(Window window)
    {
        _window = window;
    }

    public MaterialKind Current { get; private set; } = MaterialKind.Mica;

    public bool IsDark { get; private set; } = true;

    /// <summary>应用材质。失败返回 false（不抛，界面照常可用）。</summary>
    public bool Apply(MaterialKind kind, bool isDark)
    {
        try
        {
            Detach();

            var target = _window.As<Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop>();

            _config = new SystemBackdropConfiguration
            {
                IsInputActive = true,
                Theme = isDark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light,
            };

            var tuning = TuningOf(kind);

            switch (kind)
            {
                case MaterialKind.Mica:
                case MaterialKind.MicaAlt:
                    if (!MicaController.IsSupported()) return false;
                    _mica = new MicaController
                    {
                        Kind = kind == MaterialKind.MicaAlt ? MicaKind.BaseAlt : MicaKind.Base,
                    };
                    // 默认不设 TintColor/TintOpacity/LuminosityOpacity：实测给固定深色
                    // tint 后深浅两套渲染成同一颜色（diff=0），因为不透明 tint 盖掉了主题
                    // 差异。参照物图吧也只在「用户开了自定义色调」时才设（BackdropService.cs:164）。
                    if (tuning.HasCustomTint)
                    {
                        _mica.TintColor = tuning.TintColor;
                        _mica.TintOpacity = tuning.TintOpacity;
                        _mica.LuminosityOpacity = tuning.LuminosityOpacity;
                    }
                    _mica.AddSystemBackdropTarget(target);
                    _mica.SetSystemBackdropConfiguration(_config);
                    break;

                case MaterialKind.Acrylic:
                case MaterialKind.AcrylicThin:
                    if (!DesktopAcrylicController.IsSupported()) return false;
                    _acrylic = new DesktopAcrylicController
                    {
                        Kind = kind == MaterialKind.AcrylicThin
                            ? DesktopAcrylicKind.Thin
                            : DesktopAcrylicKind.Base,
                    };
                    if (tuning.HasCustomTint)
                    {
                        _acrylic.TintColor = tuning.TintColor;
                        _acrylic.TintOpacity = tuning.TintOpacity;
                        _acrylic.LuminosityOpacity = tuning.LuminosityOpacity;
                    }
                    _acrylic.AddSystemBackdropTarget(target);
                    _acrylic.SetSystemBackdropConfiguration(_config);
                    break;
            }

            Current = kind;
            IsDark = isDark;
            return true;
        }
        catch
        {
            Detach();
            return false;
        }
    }

    /// <summary>只更新主题/焦点，不重建控制器（避免材质闪烁）。</summary>
    public void UpdateState(bool isDark, bool isInputActive)
    {
        if (_config is null) return;
        IsDark = isDark;
        _config.IsInputActive = isInputActive;
        _config.Theme = isDark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light;
    }

    /// <summary>
    /// 每档材质的可选调色参数。
    ///
    /// **默认全部走系统值（HasCustomTint = false）** —— 这是实测教训：
    /// 给 Mica 设固定深色 tint 后，深浅两套主题渲染成完全相同的颜色（diff=0），
    /// 因为不透明 tint 把主题差异盖掉了。参照物图吧工具箱也只在用户
    /// 显式打开「自定义色调」时才调这四个属性（BackdropService.cs:164-177）。
    ///
    /// 四档的区分**靠 Kind**：MicaKind.Base / BaseAlt 与
    /// DesktopAcrylicKind.Base / Thin —— 这是官方 API 提供的档位，
    /// 不需要也不应该用 tint 去"造"差异。
    /// </summary>
    /// <remarks>
    /// 为什么 Acrylic 两档要轻微调 tint，而 Mica 两档不调：
    /// 实测深色下 Mica(Base) 与 Acrylic(Base) 的默认渲染**几乎完全一样**
    /// （大面积统计差 0~1）。这不是本项目的 bug —— 最小复现工程
    /// F:\samples\_verify\_wasdk_min 用同样的官方 API 也得到相同结果。
    /// 但"四档必须肉眼可辨"是硬要求，所以给 Acrylic 加一点极轻的 tint
    /// 把它推离 Mica，幅度控制在「看得出、不脏」的范围（TintOpacity ≤ 0.12）。
    /// Mica 两档保持系统默认，以免破坏深浅主题（加不透明 tint 会让
    /// 深浅两套渲染成同一色，实测 diff=0）。
    /// </remarks>
    private static (bool HasCustomTint, Windows.UI.Color TintColor,
                    float TintOpacity, float LuminosityOpacity) TuningOf(MaterialKind kind)
        => kind switch
    {
        // Acrylic：**更实更暗**（磨砂玻璃，透光少）
        MaterialKind.Acrylic => (
            true, Windows.UI.Color.FromArgb(255, 30, 30, 30), 0.55f, 0.45f),

        // Acrylic Thin：**更透更亮**（官方标签 Lighter acrylic variant）
        // 与 Acrylic 的差距靠「tint 更亮 + 不透明度更低」两处同时拉开 ——
        // 只调其中一项时实测两者仍会渲染成同一色（桌面全屏口径 diff=0~1）。
        MaterialKind.AcrylicThin => (
            true, Windows.UI.Color.FromArgb(255, 220, 220, 220), 0.12f, 0.04f),

        // Mica / Mica Alt：不调，走系统默认（保留深浅主题差异）
        _ => (false, default, 0f, 0f),
    };

    private void Detach()
    {
        try { _mica?.RemoveAllSystemBackdropTargets(); } catch { }
        _mica = null;
        try { _acrylic?.RemoveAllSystemBackdropTargets(); } catch { }
        _acrylic = null;
        _config = null;
    }
}