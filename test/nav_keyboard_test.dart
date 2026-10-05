import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/nav_items.dart';
import 'package:parse_dl/widgets/sidebar_nav.dart';

/// 导航区的键盘可达性与焦点可见性。
///
/// 起因是 2026-09-30 的真机取证：在主页连按 14 次 Tab，画面一个像素都没动。
/// 用 widget 测试读 `FocusManager` 才分得清是"焦点没动"还是"动了看不见"——
/// 结论是两条都中：**侧边栏/Dock 的行压根不是可聚焦节点**（MouseRegion +
/// GestureDetector 组合对键盘完全隐形），所以纯键盘用户连页面都切不了。
void main() {
  const c = AppColors.dark;

  Future<void> pumpNav(WidgetTester tester,
      {required void Function(String id) onSelect}) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppTheme(
      colors: AppColors.dark,
      brightness: Brightness.dark,
      child: MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SidebarNav(
                currentRouteId: 'home',
                onSelect: onSelect,
                isGroupExpanded: (_) => true,
                onToggleGroup: (_) {},
              ),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// 连按 Tab，直到焦点落在某个 debugLabel 上（走 40 步还没到就算失败）
  Future<bool> tabUntil(WidgetTester tester, bool Function(String? label) hit) async {
    for (var i = 0; i < 40; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      if (hit(FocusManager.instance.primaryFocus?.debugLabel)) return true;
    }
    return false;
  }

  testWidgets('Tab 能走进导航区（每个功能页一行）', (tester) async {
    await pumpNav(tester, onSelect: (_) {});
    final reached = await tabUntil(tester, (l) => l == 'nav:download-management');
    expect(
      reached,
      isTrue,
      reason: '按遍 Tab 也没走到 nav:download-management —— 导航区对键盘不可见',
    );
  });

  testWidgets('走到导航项后按 Enter 能真的切页', (tester) async {
    final picked = <String>[];
    await pumpNav(tester, onSelect: picked.add);
    expect(
      await tabUntil(tester, (l) => l == 'nav:download-management'),
      isTrue,
      reason: '先要能走到那一行',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(picked, ['download-management']);
  });

  testWidgets('模块标题行也可达，Space 同样能展开/收起', (tester) async {
    final toggled = <String>[];
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppTheme(
      colors: AppColors.dark,
      brightness: Brightness.dark,
      child: MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SidebarNav(
                currentRouteId: 'home',
                onSelect: (_) {},
                isGroupExpanded: (_) => true,
                onToggleGroup: toggled.add,
              ),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(
      await tabUntil(tester, (l) => l == 'nav-group:douyin'),
      isTrue,
      reason: '分组标题行也要能用键盘到达',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(toggled, ['douyin']);
  });

  test('焦点框画得出来：描边非透明，且压在卡片上够 3:1', () {
    final d = navItemDecoration(c, active: false, hover: false, focused: true);
    final border = (d.border! as Border).top;
    expect(border.color, isNot(Colors.transparent), reason: '焦点框不能是透明的');

    // 焦点框要压在两种壁纸极端下都看得清 —— 与 theme_contrast_test 同一套合成算法
    Color over(Color fg, Color bg) {
      final a = fg.a;
      int mix(double f, double b) =>
          ((f * a + b * (1 - a)) * 255).round().clamp(0, 255);
      return Color.fromARGB(255, mix(fg.r, bg.r), mix(fg.g, bg.g), mix(fg.b, bg.b));
    }

    double lin(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    double lum(Color col) =>
        0.2126 * lin(col.r) + 0.7152 * lin(col.g) + 0.0722 * lin(col.b);

    for (final wall in [const Color(0xFF000000), const Color(0xFFFFFFFF)]) {
      final base = over(AppColors.solidFor(Brightness.dark).withValues(alpha: 0.85), wall);
      final cardBg = over(c.surfaceCard, base);
      final li = lum(border.color);
      final lb = lum(cardBg);
      final r = (li > lb ? li : lb) + 0.05;
      final ratio = r / ((li > lb ? lb : li) + 0.05);
      expect(ratio, greaterThanOrEqualTo(3.0),
          reason: '焦点框对卡片底只有 ${ratio.toStringAsFixed(2)}（WCAG 非文本要 3:1）');
    }
  });

  test('焦点态与悬停态、选中态两两不同形', () {
    final idle = navItemDecoration(c, active: false, hover: false);
    final hover = navItemDecoration(c, active: false, hover: true);
    final focused = navItemDecoration(c, active: false, hover: false, focused: true);
    final selected = navItemDecoration(c, active: true, hover: false);

    Color fillOf(Decoration d) => (d as BoxDecoration).color!;
    // 悬停必须与静止不同，否则"鼠标在这儿"这件事没有任何反馈
    expect(fillOf(hover), isNot(fillOf(idle)));
    // 焦点必须有描边，而静止/悬停是透明描边（宽度恒 1px，避免文字跳格）
    expect((focused.border! as Border).top.color,
        isNot((idle.border! as Border).top.color));
    // 选中与悬停不能同形：这是 2026-09-30 那条旧账（"都是深底胶囊，只差一圈描边"）
    final ls = selected.boxShadow!.first.color.a;
    expect(ls, greaterThan(0), reason: '选中态要有柔光，否则与悬停只差一圈边');
  });
}
