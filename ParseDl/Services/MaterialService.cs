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

            switch (kind)
            {
                case MaterialKind.Mica:
                case MaterialKind.MicaAlt:
                    if (!MicaController.IsSupported()) return false;
                    _mica = new MicaController
                    {
                        Kind = kind == MaterialKind.MicaAlt ? MicaKind.BaseAlt : MicaKind.Base,
                    };
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

    private void Detach()
    {
        try { _mica?.RemoveAllSystemBackdropTargets(); } catch { }
        _mica = null;
        try { _acrylic?.RemoveAllSystemBackdropTargets(); } catch { }
        _acrylic = null;
        _config = null;
    }
}
