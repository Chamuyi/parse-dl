import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_style.dart';
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
  // 视口按**真机逻辑尺寸**（`main.dart` 的 1280×920 → 客户区实测 1267×912）。
  // Dock 改走参照物 Top 形态后条目变宽（图标格 40 + 条目外边距 4+4），
  // 自然宽约 911 —— 测试默认的 800×600 会 `RenderFlex overflowed`，
  // 把「两种导航同序」这条断言变成测不出来。语义不变，只是换了量尺。
  final view =
      TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
  view.physicalSize = const Size(1267, 912);
  view.devicePixelRatio = 1.0;

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
      // 2026-10-19：材质恢复 4 档后，配置里存的 "acrylic" 是**有效档位**，
      // 必须原样保留 —— 原来这里断言它落到 mica，测的是「已删除档位回退」，
      // 而亚克力档恢复后那个语义就不存在了。
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
      // **负控制（内建）**：图标名会重复（两个「下载管理」共用 download_rounded），
      // 只比图标等于没比顺序。所以下面那条按 **id** 比 —— id 全局唯一。
    });

    // ★ 既有约束的守护判据：**两种导航形态展示完全相同的页面与顺序**。
    //
    // 与上面那条的分工：上面比「图标」，两个模块的「下载管理」共用同一个
    // `download_rounded`、三条「设置」共用 `tune_rounded`，图标序列相等**不能**
    // 推出页面序列相等（把两个模块的子项对调，图标序列照样相同）。这条按
    // `NavItem.id`（全局唯一）比，才真正钉住「页面与顺序」。
    testWidgets('两种导航形态展示完全相同的页面与顺序（按 id，非按图标）', (tester) async {
      final expectedIds = [for (final i in kNavItems) i.id];

      await tester.pumpWidget(_navHarness(NavLayout.dock));
      final dockIds = _idsOf(tester);
      expect(dockIds, expectedIds, reason: 'Dock 的页面 id 序列必须严格等于 kNavItems');

      await tester.pumpWidget(_navHarness(NavLayout.sidebar));
      final sidebarIds = _idsOf(tester);
      expect(sidebarIds, expectedIds, reason: '侧边栏的页面 id 序列必须严格等于 kNavItems');

      expect(sidebarIds, dockIds,
          reason: '两种导航形态必须展示完全相同的页面与顺序（既有约束）');

      // 负控制：id 序列必须真的**互不相同地**一一对应 —— 若 id 有重复，
      // 上面的「相等」会在实现把两个页面互换时仍然成立。
      expect(expectedIds.toSet(), hasLength(expectedIds.length),
          reason: '负控制：kNavItems 的 id 必须唯一，否则顺序断言恒真');
    });

    testWidgets('图标格尺寸：Dock 40 方格（Top 形态）/ 侧边栏原生 16', (tester) async {
      // **2026-10-19 用户裁定放开「两种布局共用同一图标格常量」**。
      // 原因：参照物 tubatool 用的是原生 `NavigationViewItem`，条目形态是
      // 「16px 图标 + 12 间距 + 文字、行高 40、圆角 4」；Dock 是自绘的悬浮
      // 方块（36px 格）。两者本来就是两套形态，硬绑成同一个常量会让
      // 侧边栏永远做不成 WinUI 的样子。
      //
      // 仍然保留的约束：**同一布局内部必须一致**（下面逐项量）。

      // Dock：图标格本身就是导航项本体。**钉字面量 40**，不写 NavMetrics.iconBox
      // —— 用常量自比会恒真（负控制实测：把 iconBox 改回 36 判据照样绿），
      // 而这里要守的正是「照参照物 Top 形态条目 40 高」这条事实。
      await tester.pumpWidget(_navHarness(NavLayout.dock));
      expect(
        tester.getSize(find.byType(NavIconBox).first),
        const Size(40, 40),
        reason: 'Dock 条目 = 参照物 `.win-nav-item` 的 height: 40px',
      );

      // 侧边栏：原生条目，图标格 16×16
      await tester.pumpWidget(_navHarness(NavLayout.sidebar));
      expect(
        tester.getSize(find.byType(NavIconContent).first),
        const Size(NavMetrics.sidebarIconSize, NavMetrics.sidebarIconSize),
      );
    });

    testWidgets('图标本体大小：Dock 16（Top 形态）/ 侧边栏原生 16', (tester) async {
      // 同 ① 的理由：两套形态各用各的常量，但各自必须钉死。
      await tester.pumpWidget(_navHarness(NavLayout.dock));
      final dockIconSize = tester
          .widget<Icon>(find.byIcon(Icons.home_rounded))
          .size;

      await tester.pumpWidget(_navHarness(NavLayout.sidebar));
      final sidebarIconSize = tester
          .widget<Icon>(find.byIcon(Icons.home_rounded))
          .size;

      // 同样钉字面量：两套形态各自照参照物的 16（Dock = Top 形态条目图标
      // `width: 16px; font-size: 16px`，侧边栏 = Left 形态条目图标 16）。
      expect(dockIconSize, 16);
      expect(sidebarIconSize, 16);
    });

    testWidgets('激活标记：两种形态各一套，且都只标记当前页', (tester) async {
      // **2026-10-19 T4b 语义反转（形态差异，非判据放宽）**：
      // 原先断言「两种布局都用主题色底」，那是 Dock 还是自绘方块的年代。
      // 现在两套形态分别照抄参照物的两个 PaneDisplayMode：
      //   * Dock = Top 形态 → 选中**无底色**，标记是贴条目底边的 3px 横条
      //     （`WinNavigationView.vue:3337-3340` + `:3219-3224`）；
      //   * 侧边栏 = Left 形态 → 选中**有** `SubtleFillColorSecondary` 底色，
      //     标记是贴左缘的 3×16 竖条（`:3071-3073` + `:3207-3213`）。
      // 仍然钉死的是：**同一时刻恰好只有一个激活标记，且必须落在当前页上**。
      for (final layout in NavLayout.values) {
        await tester.pumpWidget(_navHarness(layout, route: 'settings'));

        final isDock = layout == NavLayout.dock;

        // ① 选中底色：只有侧边栏（Left 形态）才有，且恰好一处
        final activeBoxes = find.byWidgetPredicate(
          (w) =>
              w is AnimatedContainer &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).color ==
                  StyleNavActive.winuiDark.color,
        );
        expect(activeBoxes, isDock ? findsNothing : findsOneWidget,
            reason: isDock
                ? 'Dock（Top 形态）：选中项 background: transparent，不得有选中底色'
                : '侧边栏（Left 形态）：恰好一个导航项带选中底色');

        if (!isDock) {
          expect(
            find.ancestor(
              of: find.byIcon(Icons.settings_rounded),
              matching: activeBoxes,
            ),
            findsOneWidget,
            reason: '侧边栏：选中底色必须落在当前页图标上',
          );
        }

        // ② 指示物：恰好一个激活，且落在当前页上
        final marker = isDock ? NavIndicatorBar : NavIndicatorDot;
        final markers = find.byType(marker);
        expect(markers, findsNWidgets(kNavItems.length),
            reason: '$layout：每个导航项都挂一个指示物（用透明度切显隐）');

        final visible = <int>[];
        for (var i = 0; i < markers.evaluate().length; i++) {
          final w = tester.widget(markers.at(i));
          if ((w as dynamic).active as bool) visible.add(i);
        }
        expect(visible, [kNavItems.indexWhere((e) => e.id == 'settings')],
            reason: '$layout：只有当前页的指示物可见');

        // ③ 指示物必须**落在当前页那一个条目上**（不是邻居）。
        //    指示物与图标格是 Stack 里的兄弟节点（不是祖先链），所以按
        //    几何量：Dock 的横条中心 x、侧边栏的竖条中心 y 必须与当前页
        //    图标格中心对齐（同一条对齐轴上）。
        final activeMarker = find.byWidgetPredicate(
          (w) => w.runtimeType == marker && (w as dynamic).active as bool,
        );
        expect(activeMarker, findsOneWidget);
        final cells = find.byType(NavIconContent);
        final currentIndex = kNavItems.indexWhere((e) => e.id == 'settings');
        final cellCenter = tester.getCenter(cells.at(currentIndex));
        final markerCenter = tester.getCenter(activeMarker);
        final aligned = isDock
            ? (markerCenter.dx - cellCenter.dx).abs()
            : (markerCenter.dy - cellCenter.dy).abs();
        expect(aligned, lessThan(0.51),
            reason: '$layout：激活指示物必须与当前页条目对齐（横条对 x、竖条对 y）');
        // 负控制：它不该同时与**别的**条目也对齐，否则上面这条可能恒真
        final otherIndex = currentIndex == 0 ? 1 : 0;
        final otherCenter = tester.getCenter(cells.at(otherIndex));
        final otherDelta = isDock
            ? (markerCenter.dx - otherCenter.dx).abs()
            : (markerCenter.dy - otherCenter.dy).abs();
        expect(otherDelta, greaterThan(10),
            reason: '$layout：指示物不能落在别的条目上（否则对齐断言测不出错位）');
      }
    });

    test('navItemDecoration 是两种布局共用的唯一装饰来源', () {
      const c = AppColors.dark;

      // 2026-10-19：只剩 WinUI 一套风格，激活态改锚到 `navActiveOf` 令牌 ——
      // WinUI3 的 NavigationView 选中项是**极淡强调底 + 无描边 + 无外发光**
      // （描边与发光是玻璃系的语言）。判据语义没放宽：仍然断言「底色来自
      // 强调色令牌」，并由下面那条 widget 判据守住「只有当前页带它」。
      final active = navItemDecoration(c, active: true);
      // 默认 brightness 是浅色档（navItemDecoration 的默认参数），
      // 所以取 winuiLight 的底色 —— 这条同时守住「默认档就是官方蓝的淡底」。
      expect(active.color, StyleNavActive.winuiLight.color,
          reason: '激活底色必须来自 navActiveOf 令牌');
      expect(active.gradient, isNull, reason: 'WinUI 无渐变');
      expect(active.boxShadow, isNull, reason: 'WinUI 无外发光');

      // **语义反转**（2026-10-17 用户裁定删除悬停遮罩）：非激活项**恒为透明底**。
      // 原先这里断言「悬停底色 = c.surfaceCardHover」，现改为静止与任何状态都不带
      // 底色 —— 被删掉的效果不许以任何形式回流（该效果在真机上表现为两个圆角块
      // 同时闪现后消失，根因在渲染层未定位）。悬停反馈改由 navIconColor 承担。
      final idle = navItemDecoration(c, active: false);
      expect(idle.color, Colors.transparent, reason: '静止态不该有底色');
      expect(idle.boxShadow, isNull);
      expect((idle.border as Border).top.color, Colors.transparent,
          reason: '静止态是透明描边（宽度恒 1px，避免文字跳格）');
    });

    test('激活态符合 WinUI3（极淡强调底 / 无渐变 / 无外发光）', () {
      const c = AppColors.dark;

      // 2026-10-19：三套玻璃风格已删除，原先「三套互不相同」的比较失去对象。
      // 换锚为「winui 的激活态必须符合官方 NavigationView」：
      // 极淡强调底 + 无渐变 + 无外发光（指示靠左侧竖条）。
      final light = navItemDecoration(c,
          active: true, style: AppStyle.winui, brightness: Brightness.light);
      final dark = navItemDecoration(c,
          active: true, style: AppStyle.winui, brightness: Brightness.dark);

      expect(light.color, StyleNavActive.winuiLight.color);
      expect(dark.color, StyleNavActive.winuiDark.color);
      expect(light.gradient, isNull, reason: 'WinUI 无渐变');
      expect(dark.gradient, isNull, reason: 'WinUI 无渐变');
      expect(light.boxShadow, isNull, reason: 'WinUI 无外发光');
      expect(dark.boxShadow, isNull, reason: 'WinUI 无外发光');
      // 负控制：深浅两档必须真的不同，否则上面两条可能恒真
      expect(light.color, isNot(dark.color));

      // 深浅两档逐字段不同（负控制：证明上面的断言不是在比同一个值）
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
      // **2026-10-19 用户裁定**：未选中项改用主文本色（`textStrong`）。
      // 原先是 `textMuted`，在深色窗口材质上侧边栏文字暗到几乎读不出来
      // （真机截图里整列像被抹掉）。WinUI `NavigationViewItem` 未选中态
      // 本来就是主文本色，选中态才换强调色 —— 这里照抄它。
      expect(navIconColor(c, active: false, hover: false), c.textStrong);
    });

    testWidgets('两种形态的指示物几何各自照参照物（横条 3×2 / 竖条 3×16）', (tester) async {
      // Dock = Top 形态：贴条目底边 4px 的**横条**，高 3、圆角 2
      // （`WinNavigationView.vue:3195-3198` + `:3219-3224`）。
      await tester.pumpWidget(_navHarness(NavLayout.dock, route: 'auto-task'));
      final bars = find.byType(NavIndicatorBar);
      expect(bars, findsNWidgets(kNavItems.length));
      final activeBar = tester.getSize(
        find.byWidgetPredicate(
          (w) => w is NavIndicatorBar && w.active,
        ),
      );
      expect(activeBar.height, 3, reason: '横条高 3（NavMetrics.barHeight）');
      expect(activeBar.width, 40,
          reason: '横条宽 = 条目宽 40（参照物里 indicator 宽度随条目）');

      // **贴底位置**：`.win-nav-top-bar .win-nav-indicator { bottom: 4px }`
      // （`WinNavigationView.vue:3219-3224`）。只钉尺寸的话，把 bottom 改成 0
      // 判据照样绿（负控制实测过），所以必须量「横条底边距条目底边 4px」。
      final barRect = tester.getRect(
        find.byWidgetPredicate((w) => w is NavIndicatorBar && w.active),
      );
      final cellRect = tester.getRect(find.byType(NavIconBox).first);
      expect(
        cellRect.bottom - barRect.bottom,
        closeTo(4, 0.51),
        reason: '横条必须贴条目底边内侧 4px（参照物 bottom: 4px）',
      );
      // 负控制（内建）：横条不能沉到条目之外，也不能悬在中间
      expect(barRect.top, greaterThan(cellRect.top + 30),
          reason: '横条必须在条目下半部（否则上面那条位置断言测不出偏移）');

      // 侧边栏 = Left 形态：贴左缘的**竖条**，宽 3、高 16、圆角 1.5
      // （`:3207-3213`）。
      await tester.pumpWidget(_navHarness(NavLayout.sidebar, route: 'auto-task'));
      final sideBar = tester.getSize(
        find.byWidgetPredicate((w) => w is NavActiveBar && w.active),
      );
      expect(sideBar.width, 3);
      expect(sideBar.height, 16, reason: '侧边栏竖条高 16');
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
      // Logo 后 1 条 + 置顶项后 1 条 + 每个模块后各 1 条 —— 三个模块就是 5 条
      expect(dividers.length, 2 + kNavGroups.length,
          reason: 'Dock 靠分隔线体现每个模块各自独立（置顶项与模块之间也有一条）');
      expect(dividers.every((d) => d.axis == Axis.vertical), isTrue);

      await tester.pumpWidget(_navHarness(NavLayout.sidebar));
      dividers = tester.widgetList<NavDivider>(find.byType(NavDivider));
      // Logo 后 1 条 + 置顶项与模块区之间 1 条 + 模块区与全局项之间 1 条 = 3
      // （侧边栏靠**标题行**分模块，不再逐组加线；置顶项没有标题行，
      //   所以它与三个模块之间需要一条线把「总览」和模块入口分开）
      expect(dividers.length, 3);
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
  // 模块入口：三个模块各自是一个「可点击展开的统一入口」
  // ══════════════════════════════════════════════════════════
  group('模块入口展开 / 收起', () {
    testWidgets('侧边栏顶层就是三个模块（不是包在一个父项里）', (tester) async {
      await tester.pumpWidget(const _InteractiveSidebar());

      // 三个模块的入口标题各一个，并列在顶层
      expect(find.text('X 下载'), findsOneWidget);
      expect(find.text('抖音解析下载'), findsOneWidget);
      expect(find.text('B 站下载'), findsOneWidget);

      // 默认展开：三组的子项都看得到
      expect(find.text('主页'), findsOneWidget);
      // 「解析下载」抖音与 B 站各一行（两个模块的那一行本来就同名）
      expect(find.text('解析下载'), findsNWidgets(labelCount('解析下载')));

      // 全局项不属于任何模块，也在顶层
      expect(find.text('关于'), findsOneWidget);
    });

    testWidgets('点模块标题 → 收起它自己那组，另外两个模块不受影响', (tester) async {
      await tester.pumpWidget(const _InteractiveSidebar());

      expect(find.text('主页'), findsOneWidget);
      expect(find.text('解析下载'), findsNWidgets(labelCount('解析下载')));
      // 三条设置入口各自带归属，所以能精确断言「收起的是哪一个」
      expect(find.text('X 下载设置'), findsOneWidget);
      expect(find.text('抖音设置'), findsOneWidget);
      expect(find.text('B 站设置'), findsOneWidget);
      expect(find.text('全局设置'), findsOneWidget);

      await tester.tap(find.text('X 下载'));
      await tester.pumpAndSettle();

      // X 的子项收起
      expect(find.text('主页'), findsNothing);
      expect(find.text('自动执行'), findsNothing);
      // 「下载管理」X 组收了，另外两组那个还在
      expect(find.text('下载管理'), findsNWidgets(labelCount('下载管理', collapsed: {'x'})));
      // 「解析下载」收了抖音那一条之后剩下的条数（每个模块独立算）
      expect(
        find.text('解析下载'),
        findsNWidgets(labelCount('解析下载', collapsed: {'x'})),
      );

      // 抖音 + B 站两个模块**不受影响**（三个模块的展开状态互相独立）
      expect(find.text('X 下载设置'), findsNothing);
      expect(find.text('抖音设置'), findsOneWidget);
      expect(find.text('B 站设置'), findsOneWidget);
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
      expect(find.text('B 站设置'), findsOneWidget);
      expect(find.text('全局设置'), findsOneWidget);
    });

    testWidgets('三个模块各自独立收起，互不联动', (tester) async {
      await tester.pumpWidget(const _InteractiveSidebar());

      await tester.tap(find.text('X 下载'));
      await tester.pumpAndSettle();
      // 收了第一个模块，另两个还在 —— 这一步是「不联动」的直接证据
      expect(find.text('解析下载'), findsNWidgets(labelCount('解析下载', collapsed: {'x'})));

      await tester.tap(find.text('抖音解析下载'));
      await tester.pumpAndSettle();
      expect(find.text('解析下载'), findsNWidgets(labelCount('解析下载', collapsed: {'x', 'douyin'})));
      expect(find.text('B 站设置'), findsOneWidget, reason: 'B 站那组还没收，设置项还在');

      await tester.tap(find.text('B 站下载'));
      await tester.pumpAndSettle();

      expect(find.text('主页'), findsNothing);
      expect(find.text('解析下载'), findsNothing);
      expect(find.text('下载管理'), findsNothing);
      expect(find.text('全局设置'), findsOneWidget, reason: '只剩全局那个');
      expect(find.text('X 下载设置'), findsNothing);
      expect(find.text('抖音设置'), findsNothing);
      expect(find.text('B 站设置'), findsNothing);

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

/// 某个标签在侧边栏里**应当**出现几次（按 [collapsed] 之外的模块数据算）。
///
/// 「解析下载」「下载管理」这几个标签是跨模块同名的（每个模块都有自己那一行），
/// 写死 1 会在加第三个模块时误报，写死 2 又会在收起某组时误报 —— 所以按数据算。
/// `kNavPrimary`（置顶的「总览」）没有展开态，恒显示一行，所以无条件计入。
int labelCount(String label, {Set<String> collapsed = const {}}) {
  var n = 0;
  for (final p in kNavPrimary) {
    if (p.label == label) n++;
  }
  for (final g in kNavGroups) {
    if (g.label == label) n++;
    if (collapsed.contains(g.id)) continue;
    for (final c in g.children) {
      if (c.label == label) n++;
    }
  }
  for (final s in kNavStandalone) {
    if (s.label == label) n++;
  }
  return n;
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

/// 按**渲染顺序**读出界面上实际画出来的页面 id。
///
/// 与 [_iconsOf] 的区别：图标会重复（同一图形被多个页面共用），
/// id 唯一 —— 只有它能把「页面与顺序」真正钉住。
List<String> _idsOf(WidgetTester tester) {
  final cells = find.byType(NavIconContent);
  return [
    for (var i = 0; i < cells.evaluate().length; i++)
      tester.widget<NavIconContent>(cells.at(i)).item.id,
  ];
}

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