import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/style_colors.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/theme/window_material.dart';
import 'package:parse_dl/widgets/background_layer.dart';

/// 背景层：窗口底在「材质可用 ⇒ 透明」与「材质不可用 ⇒ 不透明回退色」
/// 两档之间二选一。
///
/// ### ⚠️ 2026-10-16：材质判据从「比参数」改成「量渲染像素」
///
/// 此前这里用 widget 树描述串（`painter=${w.painter}` 走
/// `_BackdropPainter.toString()`）拼指纹，做「五种材质渲染出不同结果」的判据。
/// 而 `toString()` 恰好把材质参数写进了串里 —— 「材质参数不同 ⇒ 字符串不同 ⇒
/// 判据必绿」，与真实渲染无关：同一条判据在真机实测四档材质**逐像素平均差
/// 0.000** 时照样全绿。
///
/// ### ⚠️ 2026-10-19：窗口底改透明，本文件的两条旧判据语义反转
///
/// 旧判据是「纯色材质 → **不透明实色**」「自定义色调 → **tintFor 混合色**」。
/// 那是「应用自己铺窗口底」时代的口径。现在（用户裁定「照抄图吧」）窗口底
/// **必须透明**，否则 Flutter 画的不透明像素会把 DWM 画的材质整个盖住，
/// 四档材质在真机上就是四张一模一样的图 —— 那正是本轮要修的缺陷。
///
/// 所以两条判据按新语义重写：
///
/// | 旧口径 | 新口径 |
/// |---|---|
/// | 材质可用 ⇒ 底 = `solidFor` 实色 | 材质可用 ⇒ 底 = `Colors.transparent` |
/// | 自定义色调 ⇒ 底 = `tintFor`（85% 半透明） | 材质**不可用** ⇒ 底 = `fallbackTo(tintFor)`（强制不透明） |
///
/// 这不是放宽：旧判据断言「不透明」，新判据断言「透明」，两者互斥；
/// 而「材质不可用时必须不透明」这条判据仍然断言 alpha == 1.0，
/// 并且比旧版更严 —— 旧版根本没测过回退路径。
void main() {
  // ══════════════════════════════════════════════════════════
  // 为什么这里**没有**「四档材质窗口底两两可辨」的判据
  // ══════════════════════════════════════════════════════════
  //
  // 曾经这里有一条矩阵判据，遍历 `WindowMaterial.values` 两两比窗口底亮度。
  // 2026-10-19 恢复 4 档后复查发现它是**空跑**：
  //
  //     for (final style in [AppStyle.winui]) {
  //       if (style == AppStyle.winui) continue;   // ← 唯一元素被 continue
  //
  // 循环体一次都不执行 ⇒ 判据恒绿。恒绿与恒红一样没用，所以整段删除，
  // 不留一个永不执行的循环充数。
  //
  // 现在窗口底是透明的（材质由 DWM 画在窗口**后面**），widget 层**结构上
  // 不可能**量到四档材质的差异 —— 那本来就该由真机截图链路覆盖
  // （`material_matrix.ps1`）。四档回退色两两相同是**照抄参照物的结果**：
  // 参照物的 `FallbackColor` 只由主题色调派生、与材质档位无关。

  // ══════════════════════════════════════════════════════════
  // 一、材质可用：窗口底必须透明
  // ══════════════════════════════════════════════════════════

  testWidgets('材质可用 → 窗口底是 **transparent**（不再铺 solidFor 实色）',
      (tester) async {
    await pumpBackdrop(tester, WindowMaterial.mica, materialAvailable: true);
    final bottom = backdropBoxColors(tester).first;

    expect(bottom, Colors.transparent,
        reason: '材质可用时窗口底必须透明 —— 不透明像素会把 DWM 画的材质'
            '整个盖住，四档材质就变成四张一模一样的图');

    // 负控制：这正是被替换掉的旧实现（铺 solidFor 实色）。它必须**不等于**
    // 新期望，否则上面那条断言没有区分力。
    final legacy = StyleColors.winuiLight.colors.surfaceSolid;
    expect(legacy.a, 1.0,
        reason: '前提：旧口径铺的 solidFor 是全不透明的');
    expect(bottom, isNot(equals(legacy)),
        reason: '若窗口底仍等于 solidFor 实色，说明 opaqueShell 那层'
            '或背景层的实色底还在');
  });

  testWidgets('四档材质**都**铺透明底（没有哪一档漏掉）', (tester) async {
    for (final m in WindowMaterial.values) {
      await pumpBackdrop(tester, m, materialAvailable: true);
      expect(backdropBoxColors(tester).first, Colors.transparent,
          reason: '${m.id} 这一档没走透明底 —— 真机上它会盖住自己的材质');
    }
  });

  // ══════════════════════════════════════════════════════════
  // 二、材质不可用：回退到不透明的 fallbackTo 色
  // ══════════════════════════════════════════════════════════

  testWidgets('材质不可用 → 回退到 fallbackTo 的**不透明**实色', (tester) async {
    await pumpBackdrop(tester, WindowMaterial.mica, materialAvailable: false);
    final bottom = backdropBoxColors(tester).first;
    final themeBase = StyleColors.winuiLight.colors.surfaceSolid;

    expect(bottom, WindowMaterial.mica.fallbackTo(themeBase),
        reason: '回退色必须来自 WindowMaterial.fallbackTo()，不是另写一个色值');
    expect(bottom.a, 1.0,
        reason: '回退底必须不透明 —— 材质挂不上时若还透明，桌面会从窗口里'
            '透出来，正文压在花花绿绿的壁纸上没法读');

    // 负控制：把 available 反过来传，底必须变成透明 —— 证明这条判据
    // 真的在区分两档，而不是恒读同一个值。
    await pumpBackdrop(tester, WindowMaterial.mica, materialAvailable: true);
    expect(backdropBoxColors(tester).first, Colors.transparent);
  });

  testWidgets('四档材质的回退色**都**不透明（逐档断言，不是只测一档）',
      (tester) async {
    for (final m in WindowMaterial.values) {
      await pumpBackdrop(tester, m, materialAvailable: false);
      expect(backdropBoxColors(tester).first.a, 1.0,
          reason: '${m.id} 这一档的回退底不透明 —— 任何一档漏掉都会露桌面');
    }
  });

  // ══════════════════════════════════════════════════════════
  // 三、自定义色调：仍然走 tintFor，但按材质可用性决定透不透明
  // ══════════════════════════════════════════════════════════

  testWidgets('自定义色调 + 材质不可用 → fallbackTo(tintFor 混合色)，强制不透明',
      (tester) async {
    final appearance = AppearanceSettings(
      windowMaterial: WindowMaterial.mica,
      customTint: true,
      tintColor: '#FF0000',
    );
    await pumpBackdrop(
      tester,
      WindowMaterial.mica,
      materialAvailable: false,
      appearance: appearance,
      brightness: Brightness.light,
    );

    // tintFor 的输入只看 RGB（alpha 位不参与混合），所以这里传什么都不影响
    // 结果 —— 保留 0x59 这个写法是为了让「旧判据用的是什么」在 diff 里可追。
    final expected = WindowMaterial.mica.fallbackTo(
        AppColors.tintFor(const Color(0x59FF0000), Brightness.light));

    expect(backdropBoxColors(tester).first, expected,
        reason: '自定义色调分支必须同样接上「材质不可用 ⇒ 不透明回退」');

    // 负控制：tintFor 原样输出是 85% 半透明的，直接铺它会让桌面透上来 ——
    // 所以 fallbackTo 的强制不透明不是摆设。
    expect(AppColors.tintFor(const Color(0x59FF0000), Brightness.light).a,
        lessThan(1.0),
        reason: '前提：tintFor 输出本身半透明，否则「强制不透明」这一步'
            '没有可断言的效果');
  });

  testWidgets('自定义色调 + 材质可用 → 底透明（色调只在回退时可见）',
      (tester) async {
    final appearance = AppearanceSettings(
      windowMaterial: WindowMaterial.mica,
      customTint: true,
      tintColor: '#FF0000',
    );
    await pumpBackdrop(
      tester,
      WindowMaterial.mica,
      materialAvailable: true,
      appearance: appearance,
      brightness: Brightness.light,
    );
    expect(backdropBoxColors(tester).first, Colors.transparent,
        reason: '材质可用时窗口底必须透明 —— 自定义色调不该在窗口底'
            '再铺一层，那会把材质盖住（色调体现在失焦覆盖层与卡片上）');
  });
}

// ════════════════════════════════════════════════════════════
// 工具
// ════════════════════════════════════════════════════════════

/// 背景层的抓图锚点。
final _kBoundaryKey = UniqueKey();

/// 抓出背景层里所有 `ColoredBox` 的颜色，**按绘制顺序**（先底后覆盖层）。
///
/// 只扫 `BackgroundLayer` 子树，不会撞到外层的装饰性 `ColoredBox`。
List<Color> backdropBoxColors(WidgetTester tester) {
  final out = <Color>[];
  void visit(Element e) {
    final w = e.widget;
    if (w is ColoredBox) out.add(w.color);
    e.visitChildren(visit);
  }

  visit(find.byType(BackgroundLayer).evaluate().single);
  return out;
}

/// 把背景层挂进 AppTheme，外层包一个 `RepaintBoundary`。
Future<void> pumpBackdrop(
  WidgetTester tester,
  WindowMaterial material, {
  AppStyle style = AppStyle.winui,
  Brightness brightness = Brightness.light,
  bool materialAvailable = true,
  AppearanceSettings? appearance,
}) async {
  final available = ValueNotifier<bool>(materialAvailable);
  final focus = ValueNotifier<bool>(true);
  addTearDown(available.dispose);
  addTearDown(focus.dispose);

  await tester.pumpWidget(
    AppTheme(
      colors: AppColors.of(style, brightness),
      brightness: brightness,
      style: style,
      child: MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: _kBoundaryKey,
            child: BackgroundLayer(
              appearance:
                  appearance ?? AppearanceSettings(windowMaterial: material),
              brightness: brightness,
              focus: focus,
              materialAvailable: available,
            ),
          ),
        ),
      ),
    ),
  );
  // 背景层是静态的，一帧就够 —— 不用 pumpAndSettle（它在有挂起 future 时
  // 会一直等到 10 分钟超时，把失败原因埋在一堆无关堆栈里）。
  await tester.pump();
}
