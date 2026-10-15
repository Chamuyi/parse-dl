import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/nav_items.dart';
import 'package:parse_dl/widgets/sidebar_nav.dart';

/// S5 验收：导航激活态 / 侧边栏底色 / 按钮令牌随风格变化。
///
/// 层级一（令牌层，纯 Dart）：三套激活态两两不同、侧边栏底色两两不同、
/// 按钮令牌两两不同；
/// 层级二（widget 层）：侧边栏在三种风格下渲染出**不同的底色 DecoratedBox**，
/// 且激活行的竖条（3×15px）始终存在（三套 CSS 逐字节相同的那条）。
void main() {
  // ══════════════════════════════════════════════════════════
  // 激活态
  // ══════════════════════════════════════════════════════════

  group('导航激活态三套两两不同', () {
    test('浅色下三套逐字段不同', () {
      const c = AppColors.light;
      final d = <AppStyle, BoxDecoration>{
        for (final s in AppStyle.values)
          s: navItemDecoration(c, active: true, hover: false, style: s),
      };
      expect(d[AppStyle.liquid], isNot(d[AppStyle.frosted]));
      expect(d[AppStyle.liquid], isNot(d[AppStyle.clay]));
      expect(d[AppStyle.frosted], isNot(d[AppStyle.clay]));
    });

    test('深色下三套逐字段不同', () {
      const c = AppColors.dark;
      final d = <AppStyle, BoxDecoration>{
        for (final s in AppStyle.values)
          s: navItemDecoration(c, active: true, hover: false, style: s),
      };
      expect(d[AppStyle.liquid], isNot(d[AppStyle.frosted]));
      expect(d[AppStyle.liquid], isNot(d[AppStyle.clay]));
      expect(d[AppStyle.frosted], isNot(d[AppStyle.clay]));
    });

    test('frosted 分支继续走 selectedDecoration（CSS :356-357 纯色12%+内描边）', () {
      const c = AppColors.dark;
      final nav = navItemDecoration(c, active: true, hover: false,
          style: AppStyle.frosted);
      // selectedDecoration 的现值 = accentSoft 底 + accentLine 描边 + 柔光
      expect(nav.color, c.accentSoft);
      expect((nav.border as Border).top.color, c.accentLine);
      expect(nav.boxShadow, isNotNull, reason: 'frosted 保留旧画法的柔光');
    });

    test('liquid 激活态 = 渐变 + 外发光（CSS :284-286）', () {
      const c = AppColors.dark;
      final nav = navItemDecoration(c, active: true, hover: false,
          style: AppStyle.liquid, brightness: Brightness.light);
      expect(nav.gradient, isNotNull, reason: 'liquid 底是 135° 线性渐变');
      expect(nav.color, isNull);
      final glow = nav.boxShadow!;
      expect(glow, hasLength(1));
      expect(glow.first.blurRadius, 14);
      expect(glow.first.offset, const Offset(0, 4));
      expect(glow.first.spreadRadius, -8);
      expect(glow.first.color, const Color(0xFF5B6CFF), reason: 'var(--ac) 浅色');
    });

    test('clay 激活态 = 纯色 10% + 仅内描边、无外发光（CSS :418-420）', () {
      const c = AppColors.dark;
      final nav = navItemDecoration(c, active: true, hover: false,
          style: AppStyle.clay, brightness: Brightness.light);
      expect(nav.gradient, isNull);
      expect(nav.color, const Color(0x1AC2410C));
      expect(nav.boxShadow, isNull, reason: 'clay 无外发光');
      expect((nav.border as Border).top.color, const Color(0x42C2410C));
    });
  });

  // ══════════════════════════════════════════════════════════
  // 侧边栏底色
  // ══════════════════════════════════════════════════════════

  group('侧边栏底色三套两两不同', () {
    test('令牌层：六套（3 风格 × 2 亮度）互不相同', () {
      final tokens = <String, StyleSidebar>{
        for (final s in AppStyle.values)
          for (final b in Brightness.values) '${s.id}-${b.name}': s.sidebarOf(b),
      };
      expect(tokens, hasLength(6));
      final seen = <StyleSidebar>[];
      for (final entry in tokens.entries) {
        for (final prev in seen) {
          expect(entry.value == prev, isFalse,
              reason: '${entry.key} 与另一套侧边栏底色相同 —— 风格区分失效');
        }
        seen.add(entry.value);
      }
    });

    test('令牌值 = CSS 原文（:255/:841/:336/:888/:402/:935）', () {
      expect(StyleSidebar.liquidLight.color, Colors.transparent);
      expect(StyleSidebar.liquidLight.borderRight, isFalse);
      expect(StyleSidebar.liquidDark.borderRight, isFalse);
      expect(StyleSidebar.frostedLight.color, const Color(0x8CFFFFFF));
      expect(StyleSidebar.frostedDark.color, const Color(0x0DFFFFFF));
      expect(StyleSidebar.clayLight.color, const Color(0xFFF3ECE4));
      expect(StyleSidebar.clayDark.color, const Color(0xFF2A231D));
      expect(StyleSidebar.frostedLight.borderRight, isTrue);
      expect(StyleSidebar.clayDark.borderRight, isTrue);
    });

    testWidgets('widget 层：三套风格渲染出不同的侧边栏底色 DecoratedBox',
        (tester) async {
      Color? sidebarColorOf(AppStyle style) {
        late Color? found;
        tester.element(find.byType(SidebarNav));
        final boxes = tester.widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(SidebarNav),
            matching: find.byType(DecoratedBox),
          ),
        ).toList();
        // 侧边栏根部的那个 DecoratedBox 是第一个（SizedBox 直接子节点）
        final root = boxes.first.decoration as BoxDecoration;
        found = root.color;
        return found;
      }

      final colors = <AppStyle, Color?>{};
      for (final style in AppStyle.values) {
        await tester.pumpWidget(
          _sidebarHarness(style),
        );
        colors[style] = sidebarColorOf(style);
      }
      // 三套两两不同（liquid 是渐变 → color 为 null，与两个实色天然不同）
      expect(colors[AppStyle.liquid], isNull, reason: 'liquid .side 是渐变');
      expect(colors[AppStyle.frosted], isNotNull);
      expect(colors[AppStyle.clay], isNotNull);
      expect(colors[AppStyle.frosted], isNot(colors[AppStyle.clay]));
    });
  });

  // ══════════════════════════════════════════════════════════
  // 竖条
  // ══════════════════════════════════════════════════════════

  group('左侧激活竖条（三套 CSS 逐字节相同，不作为区分点但不许丢）', () {
    testWidgets('激活行有一条 3×15 圆角竖条', (tester) async {
      // 'home' 是 X 模块的子项 id —— 组必须展开它才渲染，激活竖条恰好 1 条。
      await tester.pumpWidget(
        _sidebarHarness(AppStyle.frosted, route: 'home', expandGroups: true),
      );
      await tester.pumpAndSettle();

      final bars = tester
          .widgetList<NavActiveBar>(find.byType(NavActiveBar))
          .toList();
      expect(bars, isNotEmpty, reason: '侧边栏必须渲染竖条');
      final activeBars = bars.where((b) => b.active).toList();
      expect(
        activeBars,
        hasLength(1),
        reason: '当前页（home）恰好一条激活竖条，实际 ${bars.length} 条中 '
            '${activeBars.length} 条激活',
      );
    });

    testWidgets('三套风格下激活竖条都渲染', (tester) async {
      for (final style in AppStyle.values) {
        await tester.pumpWidget(
          _sidebarHarness(style, route: 'dashboard', expandGroups: false),
        );
        await tester.pumpAndSettle();
        // 'dashboard'（总览）是置顶项，组收起也渲染；激活竖条恰好 1 条。
        final bars = tester
            .widgetList<NavActiveBar>(find.byType(NavActiveBar))
            .toList();
        expect(bars, isNotEmpty, reason: '$style：侧边栏必须渲染竖条');
        expect(
          bars.where((b) => b.active),
          hasLength(1),
          reason: '$style：当前页恰好一条激活竖条',
        );
      }
    });
  });

  // ══════════════════════════════════════════════════════════
  // 按钮令牌
  // ══════════════════════════════════════════════════════════

  group('按钮令牌三套两两不同', () {
    test('六套（3 风格 × 2 亮度）互不相同', () {
      final tokens = <String, StyleButton>{
        for (final s in AppStyle.values)
          for (final b in Brightness.values) '${s.id}-${b.name}': s.buttonOf(b),
      };
      expect(tokens, hasLength(6));
      final seen = <StyleButton>[];
      for (final entry in tokens.entries) {
        for (final prev in seen) {
          expect(entry.value == prev, isFalse,
              reason: '${entry.key} 与另一套按钮令牌相同 —— 风格区分失效');
        }
        seen.add(entry.value);
      }
    });

    test('取值锚点（面 / 主按钮 / 主按钮影）—— 2026-10-16 新规范', () {
      // frosted 主按钮 = 实色 accent（Windows Fluent 强调色），无渐变
      expect(StyleButton.frostedLight.primaryColor, const Color(0xFF0F6CBD));
      expect(StyleButton.frostedLight.primaryGradient, isNull);
      // liquid / clay 主按钮 = 渐变 accent→accent2
      expect(StyleButton.liquidLight.primaryGradient, isNotNull);
      expect(StyleButton.clayLight.primaryGradient, isNotNull);
      // 三套普通按钮面：liquid/frosted 取 WinUI `ControlFillColorDefault`
      // 的 70.2% 白，clay 是暖白实色
      expect(StyleButton.liquidLight.color, const Color(0xB3FFFFFF));
      expect(StyleButton.frostedLight.color, const Color(0xB3FFFFFF));
      expect(StyleButton.clayLight.color, const Color(0xFFFFFDFA));
      // liquid 主按钮影几何（沿用原稿的柔和大影）
      final ps = StyleButton.liquidLight.primaryShadow;
      expect(ps.offset, const Offset(0, 10));
      expect(ps.blurRadius, 26);
      expect(ps.spreadRadius, -10);
    });
  });
}

/// 只渲染侧边栏的最小外壳。
Widget _sidebarHarness(AppStyle style, {String route = 'home', bool expandGroups = false}) {
  return AppTheme(
    colors: AppColors.of(style, Brightness.light),
    brightness: Brightness.light,
    style: style,
    child: MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            height: 760,
            child: SidebarNav(
              currentRouteId: route,
              onSelect: (_) {},
              isGroupExpanded: (_) => expandGroups,
              onToggleGroup: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}
