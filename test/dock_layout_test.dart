import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/app_card.dart';
import 'package:parse_dl/widgets/dock.dart';
import 'package:parse_dl/widgets/nav_items.dart';

/// Dock 布局回归测试。
///
/// 背景：Dock 曾出过两个 UI bug ——
///   1. Row 用了 `CrossAxisAlignment.end` → Logo(28) 与 36px 的图标格底部对齐，
///      而导航图标那列因下方带激活指示点更高，结果三者不在同一水平线上。
///   2. 悬停气泡标签放在图标上方的 Column 里，`AnimatedOpacity(opacity: 0)`
///      依然占 ~31px 布局高度 → Dock 被撑到 90px 高，顶部留一大块空白。
///
/// 这两个都不靠肉眼能稳定发现（改一次可能又改回去），所以固化成几何断言。
void main() {
  /// Dock 内的内容高度 = 图标方块 36px
  const iconSize = 36.0;

  /// AppFloat padding：top 6 + bottom 10
  const padTop = 6.0;
  const padBottom = 10.0;

  /// 设计高度 = 上下边框 2 + padding 16 + 内容 36
  const expectedDockHeight = 2 + padTop + padBottom + iconSize; // 54

  Future<void> pumpDock(
    WidgetTester tester, {
    String route = 'home',
    bool taskRunning = false,
  }) async {
    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Dock(
                currentRouteId: route,
                onSelect: (_) {},
                taskRunning: taskRunning,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Dock 高度紧凑：气泡标签不再占用布局（曾 90px，现 54px）', (tester) async {
    await pumpDock(tester);

    final size = tester.getSize(find.byType(AppFloat));
    expect(
      size.height,
      expectedDockHeight,
      reason:
          'Dock 高度应为 54px（2 边框 + 6 上 + 36 内容 + 10 下）；'
          '若又变成 ~90px，说明悬停标签被放回了布局流里',
    );
    // 宽度只需容纳内容，不该被撑满屏幕
    expect(size.width, lessThan(600));
  });

  testWidgets('Logo / 导航图标 垂直同心（曾用 end 对齐导致错位）', (tester) async {
    await pumpDock(tester);

    final logo = tester.getCenter(find.byType(Image));
    final homeIcon = tester.getCenter(find.byIcon(Icons.home_rounded));
    // 「关于」是最后一个导航项，拿它当右端参照点
    final lastIcon = tester.getCenter(find.byIcon(Icons.info_rounded));

    expect(
      (logo.dy - homeIcon.dy).abs(),
      lessThan(0.51),
      reason:
          'Logo(28px) 应与导航图标(36px) 同一条水平中线；'
          '偏差说明 Row 又变成 end 对齐了',
    );
    expect(
      (lastIcon.dy - homeIcon.dy).abs(),
      lessThan(0.51),
      reason: '导航图标之间也必须同一水平中线',
    );
    expect(
      (logo.dx - lastIcon.dx).abs(),
      greaterThan(100),
      reason: '顺带确认 Logo 与图标确实分处两端，而不是断言到了同一个 widget',
    );
  });

  /// 按渲染顺序取 Dock 内每个图标格的中心点。
  ///
  /// **不按图标名找**：两个模块各有一个「设置」，共用 `tune_rounded`，
  /// `find.byIcon` 会命中两个而 `tester.widget` 要求唯一。
  /// 从图标格内容取则天然一一对应，数量也自动跟着 kNavItems 走。
  List<Offset> iconCenters(WidgetTester tester) {
    final cells = find.descendant(
      of: find.byType(Dock),
      matching: find.byType(NavIconContent),
    );
    return [
      for (var i = 0; i < cells.evaluate().length; i++)
        tester.getCenter(cells.at(i)),
    ];
  }

  testWidgets('全部导航图标 互相垂直同心', (tester) async {
    await pumpDock(tester);

    final centers = iconCenters(tester);
    expect(centers.length, kNavItems.length);

    for (final c in centers) {
      expect((c.dy - centers.first.dy).abs(), lessThan(0.51));
    }
    // 图标中心应落在 Dock 内容区中部：Dock 顶 + 边框 + padding + 内容一半
    final dockTop = tester.getTopLeft(find.byType(AppFloat)).dy;
    expect(
      centers.first.dy,
      closeTo(dockTop + 1 + padTop + iconSize / 2, 0.51),
    );
  });

  testWidgets('导航图标水平间距：同模块内恒为 40px，模块之间被分隔线拉开', (tester) async {
    await pumpDock(tester);

    final dxs = [for (final c in iconCenters(tester)) c.dx];
    expect(dxs.length, kNavItems.length);

    // 图标方块 36 + 左右各 2 的外边距 = 40
    const gap = iconSize + 4;

    // 同一模块内部：相邻图标恒为 40px（这是「未被指示点/气泡撑歪」的原断言）
    var idx = 0;
    for (final g in kNavGroups) {
      for (var i = 1; i < g.children.length; i++) {
        expect(
          dxs[idx + i] - dxs[idx + i - 1],
          closeTo(gap, 0.51),
          reason: '${g.label} 内部的图标间距应恒为 40px',
        );
      }
      idx += g.children.length;
    }

    // 模块之间 / 模块与全局项之间：隔着一条竖向分隔线，必须大于组内间距
    final xCount = kNavGroups[0].children.length;
    final dyCount = kNavGroups[1].children.length;
    expect(
      dxs[xCount] - dxs[xCount - 1],
      greaterThan(gap),
      reason: 'X 下载与抖音解析下载之间要有分隔线',
    );
    expect(
      dxs[xCount + dyCount] - dxs[xCount + dyCount - 1],
      greaterThan(gap),
      reason: '两个模块与全局项之间也要有分隔线',
    );
  });

  testWidgets('激活指示点不参与布局：切换激活项 Dock 高度不变', (tester) async {
    await pumpDock(tester, route: 'home');
    final h1 = tester.getSize(find.byType(AppFloat)).height;

    await pumpDock(tester, route: 'settings');
    final h2 = tester.getSize(find.byType(AppFloat)).height;

    await pumpDock(tester, route: 'settings', taskRunning: true);
    final h3 = tester.getSize(find.byType(AppFloat)).height;

    expect(h1, h2);
    expect(h2, h3);
    expect(h1, expectedDockHeight);
  });

  testWidgets('鼠标悬停也不撑高 Dock（Tooltip 走 Overlay，不占布局）', (tester) async {
    await pumpDock(tester);
    final before = tester.getSize(find.byType(AppFloat)).height;

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.home_rounded)));
    // 超过 Tooltip 的 120ms waitDuration
    await tester.pump(const Duration(milliseconds: 200));

    final after = tester.getSize(find.byType(AppFloat)).height;
    expect(after, before, reason: '悬停气泡必须浮在 Dock 之上，不得撑高 Dock');
    expect(after, expectedDockHeight);
  });

  testWidgets('Dock 元素自左向右顺序：Logo → 模块图标 → 全局图标', (tester) async {
    await pumpDock(tester);

    final xs = <double>[
      tester.getCenter(find.byType(Image)).dx,
      tester.getCenter(find.byIcon(Icons.home_rounded)).dx,
      tester.getCenter(find.byIcon(Icons.info_rounded)).dx,
    ];
    for (var i = 1; i < xs.length; i++) {
      expect(
        xs[i],
        greaterThan(xs[i - 1]),
        reason: 'Dock 内元素顺序必须为 Logo → 导航图标（「关于」在最右）',
      );
    }
  });
}
