import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../theme/window_material.dart';

/// 契约里「关闭材质」这一档 —— 窗口不留任何系统材质，由 Flutter 铺不透明底。
///
/// 本枚举 [WindowMaterial] 目前没有对应项（配置里的旧 id `none` 已在
/// [WindowMaterial.fromId] 里回退到 mica），但**契约里有这一档**，原生侧
/// 认它。保留常量是为了：① 映射函数能表达「不指定材质」；
/// ② 判据能断言四档材质**都不会**误产出 `none`。
const String kBackdropNone = 'none';

/// [WindowMaterial] → 契约里的 `type` 字符串。**纯函数**，不碰平台通道，
/// 因此可以脱离 widget 树直接单测（`test/system_backdrop_test.dart`）。
///
/// 传入 `null` 表示「不指定材质」，落到 [kBackdropNone]。
///
/// ### 为什么不用 `material.id`
///
/// 两者现在恰好逐字相同（`mica` / `mica-alt` / `acrylic` / `acrylic-thin`），
/// 但它们是**两层不同的东西**：[WindowMaterial.id] 是 `settings.json` 的
/// 持久化标识（改它会读不回用户配置），而这里的 `type` 是与原生侧冻结的
/// 通道契约（改它原生侧就认不出）。写显式 switch 把两者解耦 ——
/// 哪天任何一边要变，都不会静默把另一边带歪。
String backdropTypeOf(WindowMaterial? material) => material == null
    ? kBackdropNone
    : switch (material) {
        WindowMaterial.mica => 'mica',
        WindowMaterial.micaAlt => 'mica-alt',
        WindowMaterial.acrylic => 'acrylic',
        WindowMaterial.acrylicThin => 'acrylic-thin',
      };

/// 把材质与主题交给 Windows App SDK 的**合成控制器**
/// （`MicaController` / `DesktopAcrylicController`）。
///
/// ### 为什么不再用 `flutter_acrylic`
///
/// 它走 `DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE)`，原生只有五档
/// （自动 / 无 / Mica / 亚克力 / MicaAlt），**没有「细亚克力」** ——
/// 真机上亚克力与细亚克力两档像素完全相同（实测差 0）。
///
/// 参照物 `tubatool/TubaWinUi3.WinUI3/Services/BackdropService.cs:144-181`
/// 用的是 WinUI 3 的 `MicaController` / `DesktopAcrylicController`，
/// 能设 `DesktopAcrylicKind.Thin`。材质由合成控制器画在窗口后面，
/// 有层次、能设 Thin —— 这是 DWM 属性那条路给不了的。
///
/// ### 契约（与 `windows/` 下的原生实现一致，**冻结**）
///
/// | 项 | 值 |
/// |---|---|
/// | 通道 | `parse_dl/system_backdrop` |
/// | 方法 | `setBackdrop` |
/// | 参数 | `{"type": String, "dark": bool, "active": bool}` |
/// | 返回 | `bool`（true = 已应用，false = 系统不支持） |
///
/// [dark] 是**系统主题**（不是材质类型）；[active] 是窗口是否聚焦 ——
/// 失焦压暗交给合成控制器自己处理，Flutter 侧不再叠灰纱
/// （见 `widgets/background_layer.dart` 的应用条件）。
///
/// ### 容错：任何失败都返回 false，**绝不抛异常**
///
/// 这是项目既有约定：材质挂不上不能让界面崩。三种失败路径：
///   - 非 Windows 平台 → false（不碰通道）；
///   - 原生侧没注册通道（`MissingPluginException`，例如原生插件还没编进去）
///     → false；
///   - 原生侧明确报错（`PlatformException`）→ false。
///
/// 返回 false 时调用方（`applyWindowMaterial` → `windowMaterialAvailable`）
/// 会把窗口底切成**不透明回退色**，界面照常可用，只是没有材质。
class SystemBackdrop {
  SystemBackdrop._();

  /// 通道名。与原生侧逐字一致，冻结。
  static const MethodChannel _ch = MethodChannel('parse_dl/system_backdrop');

  /// 方法名。与原生侧逐字一致，冻结。
  static const String _method = 'setBackdrop';

  /// 平台判定。抽成**可替换的探针**只为判据能在任意主机上跑 ——
  /// 若写死 `Platform.isWindows`，「非 Windows 一律返回 false」这条判据
  /// 在非 Windows 机器上会恒绿（永远测不出实现被改坏）。
  ///
  /// 判据里替换它、并在 `addTearDown` 里还原（见
  /// `test/system_backdrop_test.dart`）。
  @visibleForTesting
  static bool Function() platformProbe = () => Platform.isWindows;

  /// 当前平台是否支持这套材质。`applyWindowMaterial` 也读它，
  /// 这样「是否 Windows」在全项目只有**一个**出处，判据换探针能一次覆盖两处。
  static bool get isPlatformSupported => platformProbe();

  /// 把材质与主题交给原生合成控制器。
  ///
  /// 返回 false = 该系统不支持（调用方走不透明回退底）。
  static Future<bool> apply(
    WindowMaterial material, {
    required bool dark,
    required bool active,
  }) async {
    if (!isPlatformSupported) return false;

    try {
      final applied = await _ch.invokeMethod<bool>(_method, <String, Object?>{
        'type': backdropTypeOf(material),
        'dark': dark,
        'active': active,
      });
      // 原生侧没返回值（老版本插件 / 通道被替换）按「没应用上」处理：
      // 猜成 true 会让窗口底保持透明，桌面从窗口里透出来。
      return applied ?? false;
    } on MissingPluginException {
      // 原生插件还没编进产物（或跑在测试环境里）—— 静默降级。
      debugPrint('窗口材质通道不可用（MissingPluginException），走不透明回退底');
      return false;
    } on PlatformException catch (e) {
      debugPrint('应用窗口材质失败: ${e.code} ${e.message}');
      return false;
    }
  }
}