import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 「细亚克力」的真实实现 —— 补上 DWM 枚举里没有的第四档。
///
/// ### 为什么必须自己写
///
/// 四档材质里 `acrylic` 与 `acrylicThin` 在 `flutter_acrylic` 里落到同一个
/// `WindowEffect.acrylic`，因为它只调 `DwmSetWindowAttribute` 的
/// `SYSTEMBACKDROP_TYPE`，而那个枚举**最多只有 5 个值**（自动/无/Mica/
/// Acrylic/MicaAlt），**没有第五档可以放「细亚克力」**。
/// 参照物能做到，是因为它持有 `DesktopAcrylicController` 并把 Kind 设成
/// `DesktopAcrylicKind.Thin` —— 那是 Windows App SDK 的合成器对象，
/// 不是 DWM 的一个属性值；本机缺那套构建链（MSBuild 的 AppxPackage 任务
/// 不完整，编不了 WindowsAppSDK 的 C# / C++ 工程）。
///
/// ### 走 Win10 那条路
///
/// `user32!SetWindowCompositionAttribute` + `ACCENT_ENABLE_ACRYLICBLURBEHIND`。
/// 它的着色参数是 **AABBGGRR**，alpha 直接控制通透度：
/// 普通亚克力约 0xB3，细亚克力调到 0x60 —— 更亮更透，与参照物 `Thin` 一致。
/// 这是**真实的原生模糊**，不是叠一层半透明色块。
///
/// ### 失败静默
///
/// 这是未公开导出，个别系统版本可能没有。拿不到就返回 false，
/// 调用方回退普通亚克力 —— 材质细节不能把界面搞崩。
class Win32Acrylic {
  Win32Acrylic._();

  static final Win32Acrylic instance = Win32Acrylic._();

  static const int _wcaAccentPolicy = 19;
  static const int _accentEnableAcrylicBlurBehind = 4;
  static const int _accentDisabled = 0;

  /// Flutter Windows runner 的顶层窗口类名
  /// （`windows/runner/win32_window.cpp` 的 `kWindowClassName`）。
  static const String _windowClass = 'FLUTTER_RUNNER_WIN32_WINDOW';

  bool _loaded = false;
  int Function(int, Pointer<_WinCompAttrData>)? _setAttr;

  bool get _ok {
    if (_loaded) return _setAttr != null;
    _loaded = true;
    if (!Platform.isWindows) return false;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      _setAttr = user32.lookupFunction<
          IntPtr Function(IntPtr, Pointer<_WinCompAttrData>),
          int Function(int, Pointer<_WinCompAttrData>)>(
        'SetWindowCompositionAttribute',
      );
    } catch (_) {
      _setAttr = null;
    }
    return _setAttr != null;
  }

  int _flutterHwnd() {
    try {
      final cls = _windowClass.toNativeUtf16();
      final h = FindWindow(cls, nullptr);
      calloc.free(cls);
      return h;
    } catch (_) {
      return 0;
    }
  }

  bool _applyPolicy(int accentState, int gradientColor) {
    final setAttr = _setAttr;
    if (setAttr == null) return false;
    final hwnd = _flutterHwnd();
    if (hwnd == 0) return false;

    final policy = calloc<_AccentPolicy>();
    final data = calloc<_WinCompAttrData>();
    try {
      policy.ref
        ..accentState = accentState
        ..accentFlags = 2
        ..gradientColor = gradientColor
        ..animationId = 0;
      data.ref
        ..attrib = _wcaAccentPolicy
        ..pvData = policy.cast<Void>()
        ..cbData = sizeOf<_AccentPolicy>();
      return setAttr(hwnd, data) != 0;
    } finally {
      calloc.free(policy);
      calloc.free(data);
    }
  }

  /// 设成亚克力模糊。[thin] 为真时用更低的不透明度（细亚克力）。
  ///
  /// [dark] 决定着色偏黑还是偏白 —— 与 WinUI 的 tint 语义一致。
  bool apply({required bool thin, required bool dark}) {
    if (!_ok) return false;
    final alpha = thin ? 0x60 : 0xB3;
    // AABBGGRR：深色用近黑底、浅色用近白底。
    final bgr = dark ? 0x00101010 : 0x00F0F0F0;
    return _applyPolicy(
      _accentEnableAcrylicBlurBehind,
      ((alpha & 0xFF) << 24) | bgr,
    );
  }

  /// 清掉模糊。切回 DWM 材质前必须调，否则两层会叠。
  bool clear() {
    if (!_ok) return false;
    return _applyPolicy(_accentDisabled, 0);
  }
}

final class _AccentPolicy extends Struct {
  @Int32()
  external int accentState;

  @Int32()
  external int accentFlags;

  @Uint32()
  external int gradientColor;

  @Int32()
  external int animationId;
}

final class _WinCompAttrData extends Struct {
  @Uint32()
  external int attrib;

  external Pointer<Void> pvData;

  @UintPtr()
  external int cbData;
}
