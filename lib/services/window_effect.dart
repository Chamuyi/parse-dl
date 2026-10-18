import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;

import '../theme/window_material.dart';

/// 材质 → 原生窗口效果的映射。
///
/// **抽成公开纯函数是为了能测**：`applyWindowMaterial` 要走原生通道，
/// widget 测试里跑不了；而「哪种材质落到哪个效果」是纯查表，单独测它
/// 就能把映射钉住（`test/window_effect_test.dart`）。
///
/// 2026-10-15 加这条判据的原因：`dark` 参数曾被写成按材质猜
/// （`material == mica || material == micaAlt`），浅色+Mica 与深色+亚克力
/// 两种组合都传反 —— 而这件事**零测试覆盖**，所以错了很久没人发现。
acrylic.WindowEffect windowEffectOf(WindowMaterial material) =>
    // 2026-10-19：材质只剩 Mica 一档（官方给长驻窗口的唯一选择）。
    // 保留函数签名是为了让调用点与判据不用改。
    acrylic.WindowEffect.mica;

/// 把设置里的材质应用到原生窗口。
///
/// 说明：Windows 有一个**全局**的「透明效果」开关
/// （设置 → 个性化 → 颜色 → 透明效果）。关掉它之后，
/// 所有应用的 Mica / 亚克力都不会渲染 —— 这不受程序控制。
/// 所以这里失败时不做静默处理，而是把结果抛出去由界面提示用户。
///
/// 关于 Win11 24H2/25H2：社区反馈（window-vibrancy issue #183）
/// 显示 Mica 在较新的 Windows 上可能被改坏，而亚克力仍可用。
/// 若用户反馈「Mica 没效果」，优先建议改用亚克力。
///
/// ### [dark] 必须传**应用当前的明暗**，不是按材质猜（2026-10-15 修）
///
/// 原来这里写的是 `dark: material == mica || material == micaAlt` ——
/// 拿「材质类型」当「窗口明暗」用。`flutter_acrylic` 的 `dark` 参数描述的是
/// **窗口外观是深色还是浅色**（用于系统绘制的标题栏/边框），与选哪种材质
/// 无关。原写法在浅色模式下选 Mica 会传 `dark: true`、深色模式下选亚克力会
/// 传 `dark: false`，两处都反了。
///
/// ### 细亚克力与亚克力在原生层是同一个效果（能力边界，如实记录）
///
/// `flutter_acrylic` 只有三个效果：`acrylic` / `mica` / `tabbed`，
/// **没有「细亚克力」这一档**，所以 [WindowMaterial.acrylicThin] 只能落到
/// `acrylic`。两者在 [WindowMaterial] 里参数不同（seeThrough 0.62 / blur 1.6
/// 对 0.45 / 3.2），那是**应用内卡片材质**的差异；窗口背景这一层目前
/// 由系统统一绘制，程序无法区分得更细。真机对照时这两张截图会一模一样，
/// 是预期行为，不是没生效。
Future<MaterialApplyResult> applyWindowMaterial(
  WindowMaterial material, {
  required bool dark,
}) async {
  if (!Platform.isWindows) {
    return const MaterialApplyResult(
      ok: false,
      message: '窗口材质仅在 Windows 上可用',
    );
  }

  final effect = windowEffectOf(material);

  try {
    await acrylic.Window.setEffect(effect: effect, dark: dark);
    return MaterialApplyResult(
      ok: true,
      // 材质只剩 Mica 一档，「关闭材质」这个分支没有对象了。
      message: '${material.label} 已应用',
    );
  } catch (e) {
    debugPrint('应用窗口材质失败: $e');
    return MaterialApplyResult(
      ok: false,
      message: '系统拒绝了该材质（$e）',
    );
  }
}

/// 材质应用结果
@immutable
class MaterialApplyResult {
  final bool ok;
  final String message;

  const MaterialApplyResult({required this.ok, required this.message});
}
