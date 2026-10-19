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
  /// Dock 内的内容高度 = 图标格边长（照参照物 Top 形态条目 40 高）
  const iconSize = NavMetrics.iconBox;

  /// AppFloat padding：上下各 2（= 参照物条目 `margin: 2px 4px` 的垂直那一半）
  const padTop = 2.0;
  const padBottom = 2.0;

  /// 设计高度 = 上下边框 2 + padding 4 + 内容 40
  const expectedDockHeight = 2 + padTop + padBottom + iconSize; // 46

  /// 真机窗口的逻辑尺寸（`main.dart` 的 `WindowOptions.size` 1280×920，
  /// 客户区实测 1267×912）。Dock 在 Top 形态下条目变宽（图标格 40 + 条目
  /// 外边距 4+4），自然宽已超过测试默认的 800×600 视口 —— 那会触发
  /// `RenderFlex overflowed`，把「宽度只由常量决定」这条断言变成测不出。
  /// 这里显式按真机视口量，语义不变。
  const viewport = Size(1267, 912);

  Future<void> pumpDock(
    WidgetTester tester, {
    String route = 'home',
    bool taskRunning = false,
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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

  /// Dock 的自然宽度，**按导航数据算**而不是写死一个数。
  ///
  /// 组成：① 上下边框 2 + 左右 padding 16 ② Logo 28 ③ Logo 后那条分隔线 8
  /// （1px 线 + 左 3 右 4 边距，照参照物 `.win-nav-item-separator`）
  /// ④ 每个模块 = 单字徽标 22 + 5 + 每项 40（= 图标格 40，Dock 条目自身无外边距）
  /// + 组尾分隔线 8 ⑤ 全局项每项 40。
  /// ⑥ 置顶项（`kNavPrimary`）每项 40 + 它后面那条分隔线 8 —— 「总览」排在
  /// 三个模块之前，与模块尾一样跟一条竖向分隔线（见 `dock.dart` 的渲染顺序）。
  /// 写死数字的话，加第三个模块就得回来改一次；按数据算才是这条断言真正想说的
  /// 「宽度只由这些常量决定，没被气泡/指示条撑歪」。
  double dockNaturalWidth() {
    // 竖向分隔线总宽 = 1px 线 + 左 3 + 右 4（照参照物 `.win-nav-item-separator`）
    const double divider = 1 + 3 + 4;
    // 每个 Dock 条目 = 图标格 40 + 左右外边距 4+4（照参照物 `margin: 2px 4px`）
    const double item = NavMetrics.iconBox + 8;
    double w = 2 + 16 + 28 + divider;
    for (final _ in kNavPrimary) {
      w += item + divider;
    }
    for (final g in kNavGroups) {
      w += 22 + 5 + item * g.children.length + divider;
    }
    return w + item * kNavStandalone.length;
  }

  testWidgets('Dock 高度紧凑：气泡标签不再占用布局（曾 90px，现 54px）', (tester) async {
    await pumpDock(tester);

    final size = tester.getSize(find.byType(AppFloat));
    expect(
      size.height,
      expectedDockHeight,
      reason:
          'Dock 高度应为 46px（2 边框 + 2 上 + 40 内容 + 2 下）；'
          '若又变成 ~90px，说明悬停标签被放回了布局流里',
    );
    // 宽度只需容纳内容，不该被撑满屏幕（留出至少 20% 余量）
    expect(size.width, lessThan(viewport.width * 0.8));
    expect(size.width, closeTo(dockNaturalWidth(), 0.51),
        reason: '宽度必须正好等于导航常量拼出来的自然宽度（多出来的就是被撑歪了）');
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

  testWidgets('导航图标水平间距：同模块内恒为 48px，模块之间被分隔线拉开', (tester) async {
    await pumpDock(tester);

    final dxs = [for (final c in iconCenters(tester)) c.dx];
    expect(dxs.length, kNavItems.length);

    // 条目中心间距 = 图标格 40 + 两侧各 4 的条目外边距（参照物 Top 形态
    // `.win-nav-item { margin: 2px 4px }`，`WinNavigationView.vue:3237`）
    const gap = iconSize + 8;

    // 同一模块内部：相邻图标恒为 40px（这是「未被指示点/气泡撑歪」的原断言）
    //
    // 下标从 `kNavPrimary.length` 起 —— Dock 里置顶项（总览）平铺在三个模块
    // **之前**，若不跳过它，`dxs[0]` 就是总览、`dxs[1]` 是 X 组的第一个图标，
    // 两者之间隔着一条分隔线（76px），第一条断言会误报成「模块内间距不对」。
    var idx = kNavPrimary.length;
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

    // 置顶项与第一个模块之间也要有分隔线
    expect(
      dxs[kNavPrimary.length] - dxs[kNavPrimary.length - 1],
      greaterThan(gap),
      reason: '置顶项与第一个模块之间要有分隔线把它拉开',
    );

    // 模块之间 / 最后一个模块与全局项之间：隔着一条竖向分隔线，必须大于组内间距
    var offset = kNavPrimary.length;
    for (final g in kNavGroups) {
      offset += g.children.length;
      expect(
        dxs[offset] - dxs[offset - 1],
        greaterThan(gap),
        reason: '${g.label} 与后一组之间要有分隔线把它拉开',
      );
    }
    expect(
      dxs[dxs.length - kNavStandalone.length] -
          dxs[dxs.length - kNavStandalone.length - 1],
      greaterThan(gap),
      reason: '最后一个模块与全局项之间也要有分隔线',
    );
  });

  testWidgets('激活指示条不参与布局：切换激活项 Dock 高度不变', (tester) async {
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
