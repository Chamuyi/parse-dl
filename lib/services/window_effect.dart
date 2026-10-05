import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;

import '../theme/window_material.dart';

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
Future<MaterialApplyResult> applyWindowMaterial(
  WindowMaterial material,
) async {
  if (!Platform.isWindows) {
    return const MaterialApplyResult(
      ok: false,
      message: '窗口材质仅在 Windows 上可用',
    );
  }

  final effect = switch (material) {
    WindowMaterial.mica => acrylic.WindowEffect.mica,
    WindowMaterial.micaAlt => acrylic.WindowEffect.tabbed,
    WindowMaterial.acrylic => acrylic.WindowEffect.acrylic,
    WindowMaterial.acrylicThin => acrylic.WindowEffect.acrylic,
    WindowMaterial.none => acrylic.WindowEffect.disabled,
  };

  try {
    await acrylic.Window.setEffect(
      effect: effect,
      dark: material == WindowMaterial.mica ||
          material == WindowMaterial.micaAlt,
    );
    return MaterialApplyResult(
      ok: true,
      message: material == WindowMaterial.none
          ? '已关闭窗口材质'
          : '${material.label} 已应用',
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
