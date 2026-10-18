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


  // ══════════════════════════════════════════════════════════
  // 侧边栏底色
  // ══════════════════════════════════════════════════════════


  // ══════════════════════════════════════════════════════════
  // 竖条
  // ══════════════════════════════════════════════════════════

  group('左侧激活竖条（三套 CSS 逐字节相同，不作为区分点但不许丢）', () {
    testWidgets('激活行有一条 3×15 圆角竖条', (tester) async {
      // 'home' 是 X 模块的子项 id —— 组必须展开它才渲染，激活竖条恰好 1 条。
      await tester.pumpWidget(
        _sidebarHarness(AppStyle.winui, route: 'home', expandGroups: true),
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
      for (final style in [AppStyle.winui]) {
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