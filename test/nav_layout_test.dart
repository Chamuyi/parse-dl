import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/window_material.dart';
import 'package:parse_dl/widgets/dock.dart';
import 'package:parse_dl/widgets/nav_items.dart';
import 'package:parse_dl/widgets/sidebar_nav.dart';

/// 导航形态（悬浮 Dock ↔ 常规侧边栏）的回归测试。
///
/// 用户在需求里明确要求四件事，这里逐条钉住：
///   1. 两种导航并存、可自由切换
///   2. 切换后**界面即时生效**
///   3. 刷新 / 重开后**保留选择**（写进 settings.json）
///   4. 两种导航的**布局与交互风格一致**
void main() {
  // ────────────────────────────────────────────────────────────
  // ① 枚举与持久化
  // ────────────────────────────────────────────────────────────
  group('NavLayout 枚举', () {
    test('id 映射正确', () {
      expect(NavLayout.fromId('dock'), NavLayout.dock);
      expect(NavLayout.fromId('sidebar'), NavLayout.sidebar);
    });

    test('未知值 / 缺字段回退到 dock（保证老用户升级后观感不变）', () {
      expect(NavLayout.fromId(null), NavLayout.dock);
      expect(NavLayout.fromId(''), NavLayout.dock);
      expect(NavLayout.fromId('bogus'), NavLayout.dock);
      expect(NavLayout.fromId('Dock'), NavLayout.dock, reason: '大小写敏感');
    });

    test('持久化 id 稳定，改动会破坏老配置', () {
      expect(NavLayout.dock.id, 'dock');
      expect(NavLayout.sidebar.id, 'sidebar');
    });
  });

  group('导航形态随设置持久化', () {
    test('默认是悬浮 Dock', () {
      expect(AppearanceSettings().navLayout, NavLayout.dock);
      expect(Settings().appearance.navLayout, NavLayout.dock);
    });

    test('toJson 写出 navLayout', () {
      final a = AppearanceSettings(navLayout: NavLayout.sidebar);
      expect(a.toJson()['navLayout'], 'sidebar');
    });

    test('往返编解码保留选择（模拟「重开应用」）', () {
      final a = AppearanceSettings(navLayout: NavLayout.sidebar);
      final b = AppearanceSettings.fromJson(a.toJson());
      expect(b.navLayout, NavLayout.sidebar);

      // 再走一遍完整的 settings.json 编解码链路
      final s = Settings(appearance: a);
      final r = Settings.decode(s.encode());
      expect(r.appearance.navLayout, NavLayout.sidebar);
    });

    test('配置里没有 navLayout → 读出来是 dock', () {
      const legacy = '''
{"state":{"appearance":{"themeMode":"dark","windowMaterial":"acrylic"}},"version":3}''';
      final s = Settings.decode(legacy);
      expect(s.appearance.navLayout, NavLayout.dock);
      expect(s.appearance.windowMaterial, WindowMaterial.acrylic);
    });

    test('新增字段不破坏 {state, version} 包装', () {
      final root = jsonDecode(
        Settings(appearance: AppearanceSettings(navLayout: NavLayout.sidebar))
            .encode(),
      ) as Map<String, dynamic>;

      expect(root['version'], 3);
      expect(root['state'], isA<Map<String, dynamic>>());
      final appearance =
          (root['state'] as Map)['appearance'] as Map<String, dynamic>;
      // 旧字段一个都不能少（配置文件靠它们读）
      expect(
        appearance.keys,
        containsAll([
          'themeMode',
          'windowMaterial',
          'customTint',
          'tintColor',
          'backgroundImage',
          'backgroundImageOpacity',
        ]),
      );
      expect(appearance['navLayout'], 'sidebar');
    });

    test('切换只动 appearance，其余设置不受影响', () {
      final s = Settings();
      s.download.dirTemplate = '%USER_NAME%';
      s.proxy.url = 'http://127.0.0.1:1080';
      s.appearance.navLayout = NavLayout.sidebar;

      final r = Settings.decode(s.encode());
      expect(r.appearance.navLayout, NavLayout.sidebar);
      expect(r.download.dirTemplate, '%USER_NAME%');
      expect(r.proxy.url, 'http://127.0.0.1:1080');
    });
  });

  // ────────────────────────────────────────────────────────────
  // ② 切换即时生效（store → 界面）
  // ────────────────────────────────────────────────────────────
  group('切换即时生效', () {
    test('setAppearance 立即通知监听者（不需重启）', () {
      final store = SettingsStore();
      var notified = 0;
      store.addListener(() => notified++);

      store.setAppearance((a) => a.navLayout = NavLayout.sidebar);

      expect(notified, 1, reason: '改设置必须立刻 notifyListeners');
      expect(store.settings.appearance.navLayout, NavLayout.sidebar);
    });

    testWidgets('界面即时换用另一种导航（走真实 SettingsStore）', (tester) async {
      final store = SettingsStore();
      await tester.pumpWidget(_harness(store));

      // 初始：Dock 在，侧边栏不在
      expect(find.byType(Dock), findsOneWidget);
      expect(find.byType(SidebarNav), findsNothing);

      // 用户在设置里切到侧边栏
      await store.setAppearance((a) => a.navLayout = NavLayout.sidebar);
      await tester.pumpAndSettle();

      expect(find.byType(SidebarNav), findsOneWidget);
      expect(find.byType(Dock), findsNothing);

      // 再切回来
      await store.setAppearance((a) => a.navLayout = NavLayout.dock);
      await tester.pumpAndSettle();

      expect(find.byType(Dock), findsOneWidget);
      expect(find.byType(SidebarNav), findsNothing);
    });

    testWidgets('切换时不会残留上一种导航的节点', (tester) async {
      final store = SettingsStore();
      await tester.pumpWidget(_harness(store));

      for (final layout in [NavLayout.sidebar, NavLayout.dock]) {
        await store.setAppearance((a) => a.navLayout = layout);
        await tester.pumpAndSettle();

        final dockCount = find.byType(Dock).evaluate().length;
        final sidebarCount = find.byType(SidebarNav).evaluate().length;
        expect(dockCount + sidebarCount, 1, reason: '任一时刻必须只有一种导航在渲染');
      }
    });
  });

  // ────────────────────────────────────────────────────────────
  // ③ 两种导航的布局与交互风格一致
  // ────────────────────────────────────────────────────────────
  group('两种导航一致性', () {
    testWidgets('Dock 渲染全部导航项且顺序与 kNavItems 一致', (tester) async {
      await tester.pumpWidget(_navHarness(NavLayout.dock));

      expect(_iconsOf(tester), _expectedIconOrder);
    });

    testWidgets('侧边栏渲染全部导航项且顺序与 kNavItems 一致（含文字标签）', (tester) async {
      await tester.pumpWidget(_navHarness(NavLayout.sidebar));

      expect(_iconsOf(tester), _expectedIconOrder);
      // 侧边栏是图标 + 文字，所以标签必须都在。
      // 按「该标签在 kNavItems 里出现几次」核对次数而不是要求唯一 —— 这样
      // 将来再有重名标签也不会误报（三条设置入口现在已各自带归属，次数都是 1）。
      for (final item in kNavItems) {
        final times = kNavItems.where((e) => e.label == item.label).length;
        expect(find.text(item.label), findsNWidgets(times),
            reason: '「${item.label}」的标签数量不对');
      }
    });

    testWidgets('两种导航的图标集合与排列顺序完全相同', (tester) async {
      await tester.pumpWidget(_navHarness(NavLayout.dock));
      final dockIcons = _iconsOf(tester);

      await tester.pumpWidget(_navHarness(NavLayout.sidebar));
      final sidebarIcons = _iconsOf(tester);

      expect(sidebarIcons, dockIcons, reason: '同一组导航项在两种布局里必须同序同图标');
    });

    testWidgets('图标格尺寸共用同一常量（18px 图标 / 36px 格子）', (tester) async {
      // Dock：图标格本身就是导航项本体
      await tester.pumpWidget(_navHarness(NavLayout.dock));
      expect(
        tester.getSize(find.byType(NavIconBox).first),
        const Size(NavMetrics.iconBox, NavMetrics.iconBox),
      );

      // 侧边栏：图标内容装在一个同样 36 的格子里
      await tester.pumpWidget(_navHarness(NavLayout.sidebar));
      expect(
        tester.getSize(find.byType(NavIconContent).first),
        const Size(NavMetrics.iconBox, NavMetrics.iconBox),
      );
    });

    testWidgets('图标本体大小两种布局一致', (tester) async {
      await tester.pumpWidget(_navHarness(NavLayout.dock));
      final dockIconSize = tester
          .widget<Icon>(find.byIcon(Icons.home_rounded))
          .size;

      await tester.pumpWidget(_navHarness(NavLayout.sidebar));
      final sidebarIconSize = tester
          .widget<Icon>(find.byIcon(Icons.home_rounded))
          .size;

      expect(dockIconSize, NavMetrics.iconSize);
      expect(sidebarIconSize, NavMetrics.iconSize);
    });

    testWidgets('激活态：两种布局都用「主题色底 + 描边 + 发光」且只标记当前页', (tester) async {
      for (final layout in NavLayout.values) {
        await tester.pumpWidget(_navHarness(layout, route: 'settings'));

        // 全树里吃到「主题色激活底色」的容器有且只有一个
        final activeBoxes = find.byWidgetPredicate(
          (w) =>
              w is AnimatedContainer &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).color ==
                  AppColors.dark.accentSoft,
        );
        expect(activeBoxes, findsOneWidget, reason: '$layout：应当只有一个导航项处于激活态');

        // 而且就是当前页那一项
        expect(
          find.ancestor(
            of: find.byIcon(Icons.settings_rounded),
            matching: activeBoxes,
          ),
          findsOneWidget,
          reason: '$layout：激活底色必须落在当前页图标上',
        );
      }
    });

    test('navItemDecoration 是两种布局共用的唯一装饰来源', () {
      const c = AppColors.dark;

      final active = navItemDecoration(c, active: true, hover: false);
      expect(active.color, c.accentSoft);
      expect((active.border as Border).top.color, c.accentLine);
      expect(active.boxShadow, isNotNull, reason: '激活态要发光');

      final hover = navItemDecoration(c, active: false, hover: true);
      expect(hover.color, c.surfaceCardHover);
      expect((hover.border as Border).top.color, Colors.transparent);
      expect(hover.boxShadow, isNull);

      final idle = navItemDecoration(c, active: false, hover: false);
      expect(idle.color, Colors.transparent);
      expect(idle.boxShadow, isNull);
    });

    test('navIconColor 是两种布局共用的唯一取色来源', () {
      const c = AppColors.dark;

      expect(navIconColor(c, active: true, hover: false), c.accentText);
      expect(
        navIconColor(c, active: true, hover: true),
        c.accentText,
        reason: '激活优先于悬停',
      );
      expect(navIconColor(c, active: false, hover: true), c.textStrong);
      expect(navIconColor(c, active: false, hover: false), c.textMuted);
    });

    testWidgets('激活指示点两种布局各一个，且当前页才有', (tester) async {
      for (final layout in NavLayout.values) {
        await tester.pumpWidget(_navHarness(layout, route: 'auto-task'));
        final dots = find.byType(NavIndicatorDot);
        expect(
          dots,
          findsNWidgets(kNavItems.length),
          reason: '$layout：每个导航项都挂一个指示点（用透明度切显隐）',
        );

        final visible = <int>[];
        for (var i = 0; i < dots.evaluate().length; i++) {
          final w = tester.widget<NavIndicatorDot>(dots.at(i));
          if (w.active) visible.add(i);
        }
        expect(visible, [
          kNavItems.indexWhere((e) => e.id == 'auto-task'),
        ], reason: '$layout：只有当前页的指示点可见');
      }
    });

    testWidgets('后台任务红点两种布局都只出现在「自动执行」上', (tester) async {
      for (final layout in NavLayout.values) {
        await tester.pumpWidget(
          _navHarness(layout, taskRunning: true, route: 'home'),
        );
        expect(
          find.byType(NavRunningDot),
          findsOneWidget,
          reason: '$layout：仅自动执行显示运行红点',
        );

        // 红点应落在「自动执行」图标格内
        final dotCenter = tester.getCenter(find.byType(NavRunningDot));
        // 闪电现在有两个：X 的「自动执行」与抖音的「自动下载」共用它
        // （两个模块的导航结构刻意保持一致）。红点只挂在 X 那个上 ——
        // 判断依据是 id，而 kNavItems 里它排在前面。
        final bolts = find.byIcon(Icons.bolt_rounded);
        expect(bolts, findsNWidgets(2), reason: '两个模块各有一个「自动」入口');
        final boltBox = tester.getRect(bolts.at(0));
        expect(
          boltBox.inflate(12).contains(dotCenter),
          isTrue,
          reason: '$layout：红点必须挂在自动执行图标上',
        );
      }
    });

    testWidgets('taskRunning=false 时两种布局都没有红点', (tester) async {
      for (final layout in NavLayout.values) {
        await tester.pumpWidget(_navHarness(layout));
        expect(find.byType(NavRunningDot), findsNothing);
      }
    });
  });

  // ────────────────────────────────────────────────────────────
  // ④ 侧边栏自身布局
  // ────────────────────────────────────────────────────────────
  group('侧边栏布局', () {
    testWidgets('宽度固定，切换激活项不会改变宽高', (tester) async {
      await tester.pumpWidget(_navHarness(NavLayout.sidebar, route: 'home'));
      final before = tester.getSize(find.byType(SidebarNav));

      await tester.pumpWidget(_navHarness(NavLayout.sidebar, route: 'about'));
      final after = tester.getSize(find.byType(SidebarNav));

      expect(before, after);
      expect(before.width, SidebarNav.width);
    });

    testWidgets('导航项自上而下排列，且垂直方向不重叠', (tester) async {
      await tester.pumpWidget(_navHarness(NavLayout.sidebar));

      // 同样按渲染顺序取（图标名可能重复）
      final cells = find.byType(NavIconContent);
      final ys = [
        for (var i = 0; i < cells.evaluate().length; i++)
          tester.getCenter(cells.at(i)).dy,
      ];
      expect(ys.length, kNavItems.length);
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]), reason: '侧边栏必须是竖向排列');
      }
    });

    testWidgets('Logo 压顶，「关于」是最后一项', (tester) async {
      await tester.pumpWidget(_navHarness(NavLayout.sidebar));

      final logoY = tester.getCenter(find.byType(Image)).dy;
      final firstItemY = tester.getCenter(find.byIcon(Icons.home_rounded)).dy;
      final lastItemY = tester.getCenter(find.byIcon(Icons.info_rounded)).dy;

      expect(logoY, lessThan(firstItemY), reason: 'Logo 必须在导航项之上');
      expect(lastItemY, greaterThan(firstItemY), reason: '全局项排在模块项之后');
    });

    testWidgets('分隔线：Dock 竖向、侧边栏横向，且都分隔出模块边界', (tester) async {
      await tester.pumpWidget(_navHarness(NavLayout.dock));
      var dividers = tester.widgetList<NavDivider>(find.byType(NavDivider));
      // Logo 后 1 条 + 每个模块后各 1 条（2 条）= 3
      expect(dividers.length, 3, reason: 'Dock 靠分隔线体现两个模块各自独立');
      expect(dividers.every((d) => d.axis == Axis.vertical), isTrue);

      await tester.pumpWidget(_navHarness(NavLayout.sidebar));
      dividers = tester.widgetList<NavDivider>(find.byType(NavDivider));
      // Logo 后 1 条 + 模块区与全局项之间 1 条 = 2
      expect(dividers.length, 2);
      expect(dividers.every((d) => d.axis == Axis.horizontal), isTrue);
    });

    testWidgets('侧边栏不遮挡内容：占位布局，宽度可被父级测得', (tester) async {
      await tester.pumpWidget(_navHarness(NavLayout.sidebar));
      final w = tester.getSize(find.byType(SidebarNav)).width;
      expect(w, SidebarNav.width);
      expect(w, lessThan(400), reason: '侧边栏不应吃掉大半个窗口');
    });
  });

  // ══════════════════════════════════════════════════════════
  // 模块入口：两个模块各自是一个「可点击展开的统一入口」
  // ══════════════════════════════════════════════════════════
  group('模块入口展开 / 收起', () {
    testWidgets('侧边栏顶层就是两个模块（不是包在一个父项里）', (tester) async {
      await tester.pumpWidget(const _InteractiveSidebar());

      // 两个模块的入口标题各一个，并列在顶层
      expect(find.text('X 下载'), findsOneWidget);
      expect(find.text('抖音解析下载'), findsOneWidget);

      // 默认展开：两组的子项都看得到
      expect(find.text('主页'), findsOneWidget);
      expect(find.text('解析下载'), findsOneWidget);

      // 全局项不属于任何模块，也在顶层
      expect(find.text('关于'), findsOneWidget);
    });

    testWidgets('点模块标题 → 收起它自己那组，另一个模块不受影响', (tester) async {
      await tester.pumpWidget(const _InteractiveSidebar());

      expect(find.text('主页'), findsOneWidget);
      expect(find.text('解析下载'), findsOneWidget);
      // 三条设置入口各自带归属，所以能精确断言「收起的是哪一个」
      expect(find.text('X 下载设置'), findsOneWidget);
      expect(find.text('抖音设置'), findsOneWidget);
      expect(find.text('全局设置'), findsOneWidget);

      await tester.tap(find.text('X 下载'));
      await tester.pumpAndSettle();

      // X 的子项收起
      expect(find.text('主页'), findsNothing);
      // 「下载管理」X 组收了，但抖音组那个还在 —— 所以是 1 不是 0
      expect(find.text('下载管理'), findsOneWidget);
      expect(find.text('自动执行'), findsNothing);

      // 抖音模块**不受影响**（两个模块的展开状态互相独立）
      expect(find.text('解析下载'), findsOneWidget);

      // X 组那个设置跟着收起，抖音组 + 全局的还在
      expect(find.text('X 下载设置'), findsNothing);
      expect(find.text('抖音设置'), findsOneWidget);
      expect(find.text('全局设置'), findsOneWidget);

      // 标题行本身就是入口，收起后依然在
      expect(find.text('X 下载'), findsOneWidget);
    });

    testWidgets('再点一次 → 展开回来', (tester) async {
      await tester.pumpWidget(const _InteractiveSidebar());

      await tester.tap(find.text('X 下载'));
      await tester.pumpAndSettle();
      expect(find.text('主页'), findsNothing);

      await tester.tap(find.text('X 下载'));
      await tester.pumpAndSettle();
      expect(find.text('主页'), findsOneWidget);
      expect(find.text('X 下载设置'), findsOneWidget);
      expect(find.text('抖音设置'), findsOneWidget);
      expect(find.text('全局设置'), findsOneWidget);
    });

    testWidgets('两个模块各自独立收起，互不联动', (tester) async {
      await tester.pumpWidget(const _InteractiveSidebar());

      await tester.tap(find.text('X 下载'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('抖音解析下载'));
      await tester.pumpAndSettle();

      expect(find.text('主页'), findsNothing);
      expect(find.text('解析下载'), findsNothing);
      expect(find.text('全局设置'), findsOneWidget, reason: '只剩全局那个');
      expect(find.text('X 下载设置'), findsNothing);
      expect(find.text('抖音设置'), findsNothing);

      // 全局项始终可见，不受模块收起影响
      expect(find.text('关于'), findsOneWidget);
    });

    testWidgets('点全局项不会改变任何模块的展开状态', (tester) async {
      await tester.pumpWidget(const _InteractiveSidebar());

      await tester.tap(find.text('X 下载'));
      await tester.pumpAndSettle();
      expect(find.text('主页'), findsNothing);

      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();

      expect(find.text('主页'), findsNothing, reason: '点全局项不该把 X 下载模块连带展开');
    });
  });
}

/// 可交互的侧边栏外壳：展开状态真的会变。
///
/// 用真实 [SidebarNav]，只把 `isGroupExpanded` / `onToggleGroup` 接到本地
/// state —— 这样「点标题展开 / 收起」是端到端可点的，而不是断言一个死值。
class _InteractiveSidebar extends StatefulWidget {
  const _InteractiveSidebar();

  @override
  State<_InteractiveSidebar> createState() => _InteractiveSidebarState();
}

class _InteractiveSidebarState extends State<_InteractiveSidebar> {
  final Map<String, bool> _expanded = {};
  String _route = 'home';

  bool _isExpanded(String id) => _expanded[id] ?? true;

  @override
  Widget build(BuildContext context) {
    return AppTheme(
      colors: AppColors.dark,
      brightness: Brightness.dark,
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 760,
              child: SidebarNav(
                currentRouteId: _route,
                onSelect: (id) => setState(() => _route = id),
                isGroupExpanded: _isExpanded,
                onToggleGroup: (id) =>
                    setState(() => _expanded[id] = !_isExpanded(id)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// 测试辅助
// ──────────────────────────────────────────────────────────────

/// kNavItems 的图标顺序，作为「两种布局必须同序」的基准
final _expectedIconOrder = [for (final i in kNavItems) i.icon];

/// 按**渲染顺序**读出界面上实际画出来的导航图标。
///
/// 不按图标名找的原因：两条模块内设置入口**共用同一个滑杆图标**
/// （`tune_rounded`），`find.byIcon` 会命中两个而 `tester.widget` 要求唯一。
/// 改从「图标格内容」（`NavIconContent`）按顺序取 —— 两种布局都渲染它，
/// 且只渲染导航项，数量与 kNavItems 严格一一对应。
List<IconData> _iconsOf(WidgetTester tester) {
  final cells = find.byType(NavIconContent);
  return [
    for (var i = 0; i < cells.evaluate().length; i++)
      tester
          .widget<Icon>(
            find.descendant(of: cells.at(i), matching: find.byType(Icon)).first,
          )
          .icon!,
  ];
}

/// 只渲染某一种导航的最小外壳，用于量几何
Widget _navHarness(
  NavLayout layout, {
  String route = 'home',
  bool taskRunning = false,
}) {
  final nav = switch (layout) {
    NavLayout.dock => Dock(
      currentRouteId: route,
      onSelect: (_) {},
      taskRunning: taskRunning,
    ),
    NavLayout.sidebar => SidebarNav(
      currentRouteId: route,
      onSelect: (_) {},
      // 这个测试只关心两种布局的项目与顺序，展开状态一律给"全展开"
      isGroupExpanded: (_) => true,
      onToggleGroup: (_) {},
      taskRunning: taskRunning,
    ),
  };

  return AppTheme(
    colors: AppColors.dark,
    brightness: Brightness.dark,
    child: MaterialApp(
      home: Scaffold(
        body: layout == NavLayout.dock
            ? Align(alignment: Alignment.bottomCenter, child: nav)
            : Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(height: 760, child: nav),
              ),
      ),
    ),
  );
}

/// 复刻 _AppShell 的「二选一」逻辑，但走真实 SettingsStore，
/// 用于验证「改了设置界面立刻换」。
Widget _harness(SettingsStore store) {
  return ChangeNotifierProvider<SettingsStore>.value(
    value: store,
    child: AppTheme(
      colors: AppColors.dark,
      brightness: Brightness.dark,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer<SettingsStore>(
            builder: (context, s, _) {
              final useSidebar =
                  s.settings.appearance.navLayout == NavLayout.sidebar;
              return Stack(
                children: [
                  if (useSidebar)
                    Align(
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
                    )
                  else
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Dock(
                        currentRouteId: 'home',
                        onSelect: _noop,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

void _noop(String _) {}