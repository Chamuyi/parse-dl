import 'package:flutter/foundation.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;

import '../theme/window_material.dart';
import 'system_backdrop.dart';

/// 材质 → 原生窗口效果的映射。**遗留函数：运行时路径已不再经过它。**
///
/// ### ⚠️ 这不是当前生效的映射
///
/// 窗口材质的实际应用已经改由 [SystemBackdrop] → Windows App SDK 的
/// **合成控制器**（`MicaController` / `DesktopAcrylicController`）完成，
/// 生效的映射表是 [backdropTypeOf]。
///
/// 保留本函数的两个理由：
///   1. `test/window_effect_test.dart` 以它为判据锚点，签名与逐档映射
///      被钉死，删了会让那组判据失效；
///   2. `flutter_acrylic` 依赖本轮**暂不摘除**（摘它要连带改
///      `main.dart` 与 `test/window_effect_test.dart`，另开一轮），
///      所以这仍是「DWM 那条老路会得到什么」的对照表。
///
/// ### 为什么这里 `acrylicThin` 仍然映射到 `acrylic`（别改错地方）
///
/// 这是**旧通路的能力边界**，不是 bug：DWM 的 `SYSTEMBACKDROP_TYPE` 只有
/// 五档（自动 / 无 / Mica / 亚克力 / MicaAlt），**没有「细亚克力」**。
/// 新通路改用合成控制器，那里有 `DesktopAcrylicKind.Thin`，所以
/// [backdropTypeOf] 把细亚克力映射成 `'acrylic-thin'`。
///
/// **后来人注意**：看到「代码里写着 acrylicThin→acrylic，怎么细亚克力能
/// 工作」，不要来改这里 —— 要改的是 [backdropTypeOf]。改这里只会让
/// `test/window_effect_test.dart` 变红，而运行时毫无变化。
///
/// | 材质 | DWM 效果（旧通路，本函数） | 合成控制器（现通路，[backdropTypeOf]） |
/// |---|---|---|
/// | mica         | `mica`   | `mica` |
/// | mica-alt     | `tabbed` | `mica-alt` |
/// | acrylic      | `acrylic`| `acrylic` |
/// | acrylic-thin | `acrylic`| `acrylic-thin`（只有合成控制器有这一档） |
///
/// ### 历史：2026-10-15 加这条判据的原因
///
/// `dark` 参数曾被写成按材质猜（mica 与 mica-alt 判真），浅色+Mica 与
/// 深色+亚克力两种组合都传反 —— 而这件事**零测试覆盖**，错了很久没人发现。
acrylic.WindowEffect windowEffectOf(WindowMaterial material) =>
    switch (material) {
      WindowMaterial.mica => acrylic.WindowEffect.mica,
      WindowMaterial.micaAlt => acrylic.WindowEffect.tabbed,
      WindowMaterial.acrylic => acrylic.WindowEffect.acrylic,
      // 能力边界：DWM 没有「细亚克力」这个效果，只能落到普通亚克力。
      WindowMaterial.acrylicThin => acrylic.WindowEffect.acrylic,
    };

/// 把设置里的材质应用到原生窗口。
///
/// ### 2026-10-19：改走 [SystemBackdrop]（WinUI 3 合成控制器）
///
/// 旧实现走 `flutter_acrylic` → `DwmSetWindowAttribute`，亚克力档在真机上
/// 是死灰（实测三点全是 `(211,211,211)`），且细亚克力根本不存在。
/// 现在整条链路交给原生侧（`windows/` 下的插件），Flutter 只负责传参：
///
/// ```
/// applyWindowMaterial(material, dark: …, active: …)
///   └─ SystemBackdrop.apply → MethodChannel('parse_dl/system_backdrop')
///        └─ setBackdrop({type, dark, active}) → bool
/// ```
///
/// ### [dark] 必须传**应用当前的明暗**，不是按材质猜（2026-10-15 修）
///
/// 原来这里按「材质是不是 mica」推断明暗。`dark` 描述的是**窗口外观是
/// 深色还是浅色**（系统绘制的标题栏/边框），与选哪种材质无关。
///
/// ### [active] 窗口是否聚焦
///
/// 失焦压暗交给合成控制器自己处理（WinUI 的 `IsInputActive` 行为）。
/// 焦点变化时由调用方重调本函数，不必（也不该）在 Flutter 侧再叠灰纱 ——
/// 那层纱会把材质盖住（见 `widgets/background_layer.dart` 的应用条件）。
///
/// ### 失败不再抛异常
///
/// 旧实现「失败时把结果抛出去由界面提示用户」。现在 [SystemBackdrop] 把
/// 三类失败（非 Windows / `MissingPluginException` / `PlatformException`）
/// 统一折成 `false` —— 材质挂不上不能让界面崩。调用方读 `ok` 决定窗口底
/// 走透明还是不透明回退。
Future<MaterialApplyResult> applyWindowMaterial(
  WindowMaterial material, {
  required bool dark,
  bool active = true,
}) async {
  // 非 Windows 单独给一句准确的文案：这时不是「系统拒绝」，而是压根没有
  // 这套材质（Linux/macOS 上窗口由窗口管理器画）。
  if (!SystemBackdrop.isPlatformSupported) {
    return const MaterialApplyResult(
      ok: false,
      message: '窗口材质仅在 Windows 上可用',
    );
  }

  final applied = await SystemBackdrop.apply(
    material,
    dark: dark,
    active: active,
  );
  // 材质是否真的挂上只有原生侧知道，这一行把结论带到 stdout（debug 版
  // 可直接从控制台读到，不必靠像素反推）。
  debugPrint('[BACKDROP] ${material.id} applied=$applied');

  return MaterialApplyResult(
    ok: applied,
    message: applied
        ? '${material.label} 已应用'
        // 合成控制器没挂上：系统版本太低、关掉了「透明效果」、
        // 或原生插件没编进产物。具体原因在原生侧的 debugPrint 里。
        : '系统不支持该材质（${material.label}）',
  );
}

/// 材质应用结果
@immutable
class MaterialApplyResult {
  final bool ok;
  final String message;

  const MaterialApplyResult({required this.ok, required this.message});
}
