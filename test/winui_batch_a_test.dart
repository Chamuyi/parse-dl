import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/fluent_icon_tile.dart';
import 'package:parse_dl/widgets/nav_items.dart';
import 'package:parse_dl/widgets/page_header.dart';
import 'package:parse_dl/widgets/sidebar_nav.dart';
import 'package:parse_dl/widgets/status_badge.dart';

/// 批次 A（2026-10-19）的**取值判据** —— 钉住 9 条「对齐图吧细项」的最终值。
///
/// 逐条出处见 `F:\samples\_verify\ui_align_batch_a.md`；参照物是
/// `F:\samples\_verify\tubatool`（C# + WinUI 3）与同仓 `website-winui3/` 的
/// `WinNavigationView.vue`（那份 CSS 就是原生 `NavigationView` 的规格）。
///
/// 与各原文件里判据的分工：这里只钉**数值与渲染结果**，不重复语义。A3/A9
/// 的令牌值在 `winui_shape_test.dart` 里（那里已有负控制），这里补「组件真的
/// 落了盘」。每条都做过「把值改回旧值 → 判据实测变红 → 改回」的负控制，
/// 判红输出片段记录在批次 A 的交付说明里。
void main() {
  /// 最小可渲染环境。深色是默认档（与 `preview_components_test` 同口径）。
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppTheme(
        colors: brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light,
        brightness: brightness,
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pump();
  }

  /// 只渲染侧边栏的最小外壳（模块全展开），与 `nav_layout_test` 的 harness 同源。
  Widget sidebar() => AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: 760,
                child: SidebarNav(
                  currentRouteId: 'home',
                  onSelect: (_) {},
                  isGroupExpanded: (_) => true,
                  onToggleGroup: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

  /// 某个导航项的图标格（两种布局都渲染它，且只渲染导航项）。
  Finder iconContentOf(String itemId) =>
      find.byWidgetPredicate((w) => w is NavIconContent && w.item.id == itemId);

  /// 条目行本体（侧边栏的条目行是 `AnimatedContainer`，只有它一个）。
  Finder rowOf(String label) => find
      .ancestor(of: find.text(label), matching: find.byType(AnimatedContainer))
      .first;

  /// 缩进条目 = 各模块的 children；顶层条目 = kNavPrimary / kNavStandalone。
  final childIds = <String>{
    for (final g in kNavGroups)
      for (final c in g.children) c.id,
  };

  // ══════════════════════════════════════════════════════════
  // A1 · 图标块底色 = 官方 SubtleFillColorSecondary
  // ══════════════════════════════════════════════════════════
  group('A1 图标块底色', () {
    Color tileColor(WidgetTester tester) {
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(FluentIconTile),
              matching: find.byType(Container),
            )
            .first,
      );
      return (box.decoration! as BoxDecoration).color!;
    }

    test('令牌取自官方色表：深 0x0FFFFFFF / 浅 0x09000000', () {
      // 出处：`Styles/SettingsStyles.xaml:15` 的 SubtleFillColorSecondaryBrush；
      // 官方值 `color_resources.dart:211`（深）/ `:298`（浅）。
      expect(AppStyle.winui.subtleFillOf(Brightness.dark).color,
          const Color(0x0FFFFFFF));
      expect(AppStyle.winui.subtleFillOf(Brightness.light).color,
          const Color(0x09000000));
      // 负控制：两档必须真的不同，否则「按亮度取档」这件事测不出来
      expect(
        AppStyle.winui.subtleFillOf(Brightness.dark).color,
        isNot(AppStyle.winui.subtleFillOf(Brightness.light).color),
      );
      // 负控制：旧值 lineSoft（= 官方 subtleFillColorTertiary）必须与现值不同
      expect(AppStyle.winui.subtleFillOf(Brightness.dark).color,
          isNot(const Color(0x0AFFFFFF)));
      expect(AppStyle.winui.subtleFillOf(Brightness.light).color,
          isNot(const Color(0x06000000)));
    });

    testWidgets('组件真的落了盘：深 6% 白 / 浅 3.5% 黑', (tester) async {
      await pump(tester, const FluentIconTile(icon: Icon(Icons.home_rounded)));
      expect(tileColor(tester), const Color(0x0FFFFFFF));
      expect(tileColor(tester), isNot(const Color(0x0AFFFFFF)));

      await pump(
        tester,
        const FluentIconTile(icon: Icon(Icons.home_rounded)),
        brightness: Brightness.light,
      );
      expect(tileColor(tester), const Color(0x09000000));
      expect(tileColor(tester), isNot(const Color(0x06000000)));
    });
  });

  // ══════════════════════════════════════════════════════════
  // A2 · 页头图标块：透明底 / 图标 20 / 前景 AccentTextFillColorPrimary
  // ══════════════════════════════════════════════════════════
  group('A2 页头图标块', () {
    Icon headerIcon(WidgetTester tester) => tester.widget<Icon>(
          find
              .descendant(
                of: find.byType(PageHeader),
                matching: find.byType(Icon),
              )
              .first,
        );

    testWidgets('图标 20 + 前景 accentText（参照物 FontSize=20 / AccentTextFillColorPrimary）',
        (tester) async {
      await pump(
        tester,
        const PageHeader(title: '设置', icon: Icons.settings_rounded),
      );
      final icon = headerIcon(tester);
      expect(icon.size, 20);
      expect(icon.color, AppColors.dark.accentText);
      // 负控制：旧画法是 24px + 按 accentSoft 亮度在 accent / textStrong 之间二选一
      expect(icon.size, isNot(24));
      expect(icon.color, isNot(AppColors.dark.accent));
      expect(icon.color, isNot(AppColors.dark.textStrong));
    });

    testWidgets('底色全透明（SubtleFillColorTransparent = 0x00FFFFFF）', (tester) async {
      await pump(
        tester,
        const PageHeader(title: '设置', icon: Icons.settings_rounded),
      );
      final tile = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(PageHeader),
              matching: find.byType(Container),
            )
            .first,
      );
      expect((tile.decoration! as BoxDecoration).color, Colors.transparent);
      // 负控制：旧值 textMuted@6% 必须与之不同
      expect(
        (tile.decoration! as BoxDecoration).color,
        isNot(AppColors.dark.textMuted.withValues(alpha: 0.06)),
      );
    });

    testWidgets('浅色档同样走 accentText 槽位', (tester) async {
      await pump(
        tester,
        const PageHeader(title: '设置', icon: Icons.settings_rounded),
        brightness: Brightness.light,
      );
      expect(headerIcon(tester).color, AppColors.light.accentText);
    });
  });

  // ══════════════════════════════════════════════════════════
  // A3 · 状态徽章形态（StatusPillStyle：圆角 12 + padding 8,3）
  // ══════════════════════════════════════════════════════════
  group('A3 状态徽章形态', () {
    testWidgets('渲染结果：圆角 12 / 内边距 8,3', (tester) async {
      await pump(
        tester,
        const StatusBadge(kind: StatusKind.wait, text: '待处理'),
      );
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(StatusBadge),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(box.padding,
          const EdgeInsets.symmetric(horizontal: 8, vertical: 3));
      final radius =
          ((box.decoration! as BoxDecoration).borderRadius! as BorderRadius)
              .topLeft
              .x;
      expect(radius, 12, reason: 'PillCornerRadiusToken（FluentTokens.xaml:52）');
      // 负控制：旧值 4 / 7 / 2 必须与现值不同
      expect(radius, isNot(4));
      expect(box.padding,
          isNot(const EdgeInsets.symmetric(horizontal: 7, vertical: 2)));
    });
  });

  // ══════════════════════════════════════════════════════════
  // A4/A5/A6 · 侧边栏字号 14 · 内边距 16/12 · 子项缩进 44
  // ══════════════════════════════════════════════════════════
  group('A4/A5/A6 侧边栏字号与内边距', () {
    testWidgets('字号 14：标题行与条目行同档', (tester) async {
      await tester.pumpWidget(sidebar());
      await tester.pump();
      final header = kNavGroups.first;
      final child = header.children.first;
      expect(
        tester.widget<Text>(find.text(header.label)).style!.fontSize,
        14,
        reason: '.win-nav-item-header font-size: 14px（vue:3140）',
      );
      expect(
        tester.widget<Text>(find.text(child.label)).style!.fontSize,
        14,
        reason: '旧值 13.5 不在参照物里，也不在字号棘轮的 18 档语义内',
      );
    });

    testWidgets('内边距：标题行右 16（vue:3136）/ 条目行右 12（vue:3048）',
        (tester) async {
      await tester.pumpWidget(sidebar());
      await tester.pump();
      final header = kNavGroups.first;
      final headerBox = tester.widget<Container>(
        find
            .ancestor(
              of: find.text(header.label),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(headerBox.padding, const EdgeInsets.only(left: 16, right: 16));

      final childRow =
          tester.widget<AnimatedContainer>(rowOf(header.children.first.label));
      expect(
        childRow.padding,
        const EdgeInsets.only(left: 44, right: 12),
        reason: '子项缩进 44（vue:3424）+ 行右 12',
      );

      final topRow =
          tester.widget<AnimatedContainer>(rowOf(kNavPrimary.first.label));
      expect(
        topRow.padding,
        const EdgeInsets.only(left: 16, right: 12),
        reason: '顶层条目左 16（vue:3136 的 0 16px）',
      );
    });

    testWidgets('缩进几何：子项 44 / 顶层 16（各 +1px 透明描边内缩）',
        (tester) async {
      await tester.pumpWidget(sidebar());
      await tester.pump();
      final header = kNavGroups.first;
      final child = header.children.first;

      // 行装饰里有一条 **1px 透明描边**（`navItemDecoration`；宽度恒 1px 是
      // 为了让状态切换时不跳格）。`Container` 会把描边算进内容内缩，所以
      // 参照物 CSS 的 44/16 落到屏幕上各多 1px —— 这里如实量出来，
      // 不把 44 写成 43 去凑数。
      const borderInset = 1.0;
      final childOffset = tester.getRect(iconContentOf(child.id)).left -
          tester.getRect(rowOf(child.label)).left;
      final topOffset = tester.getRect(iconContentOf(kNavPrimary.first.id)).left -
          tester.getRect(rowOf(kNavPrimary.first.label)).left;

      expect(childOffset, closeTo(44 + borderInset, 0.01),
          reason: '子项左缩进 44（vue:3424）');
      expect(topOffset, closeTo(16 + borderInset, 0.01),
          reason: '顶层左缩进 16（vue:3136）');
      // 两档之差是**纯缩进量**（描边两侧都吃 1px，相减抵消）。这条同时是
      // 上面两条的负控制：若两处被写成同一个值，这里必然不是 28。
      expect(childOffset - topOffset, closeTo(28, 0.01));
    });
  });

  // ══════════════════════════════════════════════════════════
  // A7 · 删圆点 · 竖条 left 4（子项 36）
  // ══════════════════════════════════════════════════════════
  group('A7 激活标记', () {
    testWidgets('竖条位置：顶层 left 4 / 子项 left 36（vue:3207-3217）', (tester) async {
      await tester.pumpWidget(sidebar());
      await tester.pump();
      final bars = find.byType(NavActiveBar);
      final rows = find.byType(AnimatedContainer);
      final cells = find.byType(NavIconContent);
      expect(bars, findsNWidgets(kNavItems.length),
          reason: '每个条目恰好一条竖条');
      expect(rows, findsNWidgets(kNavItems.length));
      expect(cells, findsNWidgets(kNavItems.length));
      for (var i = 0; i < kNavItems.length; i++) {
        final id = tester.widget<NavIconContent>(cells.at(i)).item.id;
        final expected = childIds.contains(id) ? 36.0 : 4.0;
        expect(
          tester.getRect(bars.at(i)).left - tester.getRect(rows.at(i)).left,
          closeTo(expected, 0.01),
          reason: '条目 $id 的竖条左偏 $expected',
        );
      }
    });

    test('侧边栏不再画圆点（参照物左栏只有一个 indicator）', () {
      final source = File('lib/widgets/sidebar_nav.dart').readAsStringSync();
      final items = File('lib/widgets/nav_items.dart').readAsStringSync();
      expect(source.contains('NavIndicatorDot'), isFalse);
      expect(items.contains('NavIndicatorDot'), isFalse);
      // 正控制：同一读法在**确实存在**的名字上必须为真 —— 否则上面的
      // isFalse 可能只是「文件读空 / 路径写错」造成的恒真。
      expect(source.contains('NavActiveBar'), isTrue);
      expect(items.contains('class NavActiveBar'), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════
  // A8 · 侧栏分隔线外边距 上 3 下 4
  // ══════════════════════════════════════════════════════════
  group('A8 分隔线外边距', () {
    testWidgets('默认外边距：横向 上3 下4 / 竖向 4,4', (tester) async {
      await pump(tester, const NavDivider(axis: Axis.horizontal));
      final hBox = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(NavDivider),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(hBox.margin, const EdgeInsets.only(top: 3, bottom: 4));
      // 负控制：旧值 6/6 必须与现值不同
      expect(hBox.margin, isNot(const EdgeInsets.symmetric(vertical: 6)));

      await pump(tester, const NavDivider(axis: Axis.vertical));
      final vBox = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(NavDivider),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(vBox.margin, const EdgeInsets.symmetric(horizontal: 4));
    });

    testWidgets('真实侧边栏里每条分隔线都走 上3 下4', (tester) async {
      await tester.pumpWidget(sidebar());
      await tester.pump();
      final boxes = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(NavDivider),
          matching: find.byType(Container),
        ),
      );
      expect(boxes, isNotEmpty, reason: '侧栏有分隔线（Logo 后 / 模块之间）');
      for (final b in boxes) {
        expect(b.margin, const EdgeInsets.only(top: 3, bottom: 4));
      }
    });
  });
}