import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/l10n/app_locale.dart';
import 'package:parse_dl/l10n/l10n.dart';
import 'package:parse_dl/pages/settings_page.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/window_material.dart';
import 'package:parse_dl/widgets/material_picker.dart';
import 'package:parse_dl/widgets/nav_items.dart';

/// 外观分区的四条界面回归（2026-09-30 弹层实拍挑出来的）。
///
/// 1. 五种材质的缩略图**必须互不相同** —— 以前五张图画得一模一样，
///    「细微材质差别」只能靠读文字；
/// 2. 「自定义色调」的开关紧跟标题 —— 以前推到约 1100px 外的行尾，
///    和下一行的说明文字两端分离；
/// 3. 界面语言三项是**一组**分段控件 —— 以前像三个独立按钮；
/// 4. 选中态只有一套画法 —— 以前分段控件用高饱和主色整块铺底配白字，
///    导航与材质卡片用低饱和主色底配主色描边。
///
/// 外加一条顺带修到的漏翻：分区展开后头部的「收起」没走 `t()`。
void main() {
  const c = AppColors.dark;

  /// 泵出全局设置页并展开「外观」分区。[locale] 非空时按该语言渲染。
  Future<void> pumpAppearance(
    WidgetTester tester, {
    AppLocale? locale,
  }) async {
    if (locale != null) {
      applyLocaleSetting(locale);
      addTearDown(() => applyLocaleSetting(AppLocale.system));
    }
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    AppPrefs.setMockInitialValues({});
    final appState = await AppState.restore();
    final settings = SettingsStore();

    await tester.pumpWidget(
      AppTheme(
        colors: c,
        brightness: Brightness.dark,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: appState),
            ChangeNotifierProvider<SettingsStore>.value(value: settings),
            ChangeNotifierProvider<DownloadStore>(create: (_) => DownloadStore()),
            ChangeNotifierProvider<DouyinStore>(create: (_) => DouyinStore()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SettingsPage(
                brightness: Brightness.dark,
                onMaterialChanged: (_) async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 分区标题本身也要跟着语言走，否则英文档找不到点击目标
    await tester.tap(find.text(t('外观')));
    await tester.pumpAndSettle();
  }

  /// 外观分区内容子树
  final appearanceSection = find.byKey(
    const ValueKey('collapsible-content-section.appearance'),
  );

  /// 找到把 [label] 框住的那个分段控件底框（surfaceSunken + 描边）
  Finder trayOf(String label) => find.ancestor(
    of: find.descendant(of: appearanceSection, matching: find.text(label)),
    matching: find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).color == c.surfaceSunken,
    ),
  );

  /// 底框里那几个选项胶囊（按横向位置排好）
  List<Rect> segmentRects(WidgetTester tester, Finder tray) {
    final boxes = find.descendant(
      of: tray,
      matching: find.byType(AnimatedContainer),
    );
    final n = tester.widgetList(boxes).length;
    final rects = [for (var i = 0; i < n; i++) tester.getRect(boxes.at(i))]
      ..sort((a, b) => a.left.compareTo(b.left));
    return rects;
  }

  // ══════════════════════════════════════════════════════════
  group('材质缩略图', () {
    test('五种材质的缩略图参数两两不同', () {
      final specs = {
        for (final m in WindowMaterial.values)
          (m.seeThrough, m.blur, m.layered),
      };
      expect(
        specs.length,
        WindowMaterial.values.length,
        reason: '透出度/磨砂/分层三个参数必须把五种材质区分开，'
            '否则缩略图又会画成一张脸',
      );
      expect(
        WindowMaterial.none.seeThrough,
        0,
        reason: '纯色就是完全不透，若还透出壁纸就跟云母没区别了',
      );
      expect(
        WindowMaterial.acrylicThin.seeThrough,
        greaterThan(WindowMaterial.acrylic.seeThrough),
        reason: '细亚克力比亚克力更透亮',
      );
    });

    testWidgets('五张缩略图渲染出来确实不一样：磨砂只出现在两种亚克力上',
        (tester) async {
      await pumpAppearance(tester);

      // 缩略图按材质分别画：只有亚克力系才挂 BackdropFilter。
      // 五张图若长得一样（以前的画法），这里会是 0 个。
      expect(
        find.descendant(
          of: find.byType(MaterialPicker),
          matching: find.byType(BackdropFilter),
        ),
        findsNWidgets(2),
      );
      expect(
        find.byType(MaterialPicker),
        findsOneWidget,
        reason: '材质选择器得在外观分区里',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  group('自定义色调', () {
    testWidgets('开关紧跟标题，说明文字在标题正下方', (tester) async {
      await pumpAppearance(tester);

      final title = tester.getRect(
        find.descendant(of: appearanceSection, matching: find.text('自定义色调')),
      );
      final sw = tester.getRect(
        find.descendant(
          of: appearanceSection,
          matching: find.byType(Switch),
        ),
      );
      final desc = tester.getRect(
        find.descendant(
          of: appearanceSection,
          matching: find.textContaining('让材质效果更明显'),
        ),
      );

      expect(
        sw.left - title.right,
        lessThan(24),
        reason: '开关要和标题相邻；以前用 Spacer 推到行尾，隔了约 1100px',
      );
      expect(
        sw.top >= title.top - 16 && sw.bottom <= title.bottom + 16,
        isTrue,
        reason: '开关仍和标题同一行',
      );
      expect(desc.top, greaterThanOrEqualTo(title.bottom),
          reason: '说明文字紧跟标题行下方，左对齐');
      expect(desc.left, lessThanOrEqualTo(title.left + 1));
    });
  });

  // ══════════════════════════════════════════════════════════
  group('分段控件', () {
    testWidgets('界面语言三项被同一个描边底框框成一组', (tester) async {
      await pumpAppearance(tester);

      final tray = trayOf('English');
      expect(tray, findsOneWidget, reason: 'English 只该被一个底框框住');
      final box = tester.widget<Container>(tray);
      expect(
        ((box.decoration! as BoxDecoration).border! as Border).top.color,
        c.lineStrong,
        reason: '底框要有一圈看得见的描边，否则三项还是像三个散按钮',
      );
      for (final label in ['跟随系统', '简体中文', 'English']) {
        expect(
          find.descendant(of: tray, matching: find.text(label)),
          findsOneWidget,
          reason: '$label 应当在界面语言这一个底框里',
        );
      }
    });

    testWidgets('段与段相邻，中间只留一道分隔线', (tester) async {
      await pumpAppearance(tester);

      final rects = segmentRects(tester, trayOf('English'));
      expect(rects.length, 3);
      var gaps = 0.0;
      for (var i = 1; i < rects.length; i++) {
        final gap = rects[i].left - rects[i - 1].right;
        expect(gap, lessThanOrEqualTo(1),
            reason: '分段之间只允许 1px 分隔线，不能各画各的胶囊');
        gaps += gap;
      }
      // 三档里有一档被选中：紧挨它的两道分隔线不画，所以只剩一道
      expect(gaps, 1, reason: '三项一组、选中其一 → 恰好一道分隔线');
    });

    testWidgets('主题模式三项同样是一组（同一个分段控件实现）', (tester) async {
      await pumpAppearance(tester);

      final tray = trayOf('浅色');
      expect(tray, findsOneWidget);
      for (final label in ['浅色', '深色', '跟随系统']) {
        expect(
          find.descendant(of: tray, matching: find.text(label)),
          findsOneWidget,
        );
      }
    });
  });

  // ══════════════════════════════════════════════════════════
  group('选中态一套画法', () {
    test('导航激活态就是主题里的选中态', () {
      final sel = selectedDecoration(c);
      final nav = navItemDecoration(c, active: true, hover: false);
      expect(nav.color, sel.color);
      expect(
        (nav.border! as Border).top.color,
        (sel.border! as Border).top.color,
      );
      expect(nav.boxShadow, sel.boxShadow);
    });

    // 上面那条只比"画出来等不等"——把 navItemDecoration 改回自己内联一套同色的
    // 装饰，它照样绿（值相等）。所以再加一条源码层检查：选中底色必须真的
    // 从 selectedDecoration 那一个定义里来，不许有文件自己再写一遍 accentSoft。
    test('选中底色只有 selectedDecoration 一个出处，没被就地重写', () {
      String src(String rel) => File(rel).readAsStringSync();

      for (final f in [
        'lib/widgets/nav_items.dart',
        'lib/widgets/material_picker.dart',
        'lib/widgets/nav_layout_picker.dart',
      ]) {
        expect(src(f), contains('selectedDecoration('), reason: '$f 的选中态要走那一个定义');
        expect(
          src(f),
          isNot(contains('c.accentSoft')),
          reason: '$f 又自己写了一遍选中底色 → 选中态开始分叉',
        );
      }
      expect(
        src('lib/pages/settings_page.dart'),
        contains('selectedDecoration('),
        reason: '分段控件的选中态也走同一个定义',
      );
    });

    testWidgets('设置页里不再有用高饱和主色整块铺底的选中态', (tester) async {
      await pumpAppearance(tester);

      expect(
        find.descendant(
          of: appearanceSection,
          matching: find.byWidgetPredicate(
            (w) =>
                w is AnimatedContainer &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).color == c.accent,
          ),
        ),
        findsNothing,
        reason: '选中态只允许 selectedDecoration 那一种画法',
      );
      // 而低饱和那一套确实落在语言分段控件的选中段上
      expect(
        find.descendant(
          of: trayOf('English'),
          matching: find.byWidgetPredicate(
            (w) =>
                w is AnimatedContainer &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).color == c.accentSoft,
          ),
        ),
        findsOneWidget,
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  group('分区头部的展开/收起提示', () {
    // 这条不是"漏翻表"问题：'收起' 在 strings_en 里一直有（抖音页的 tooltip 在用），
    // 漏的是 collapsible_group 渲染时根本没走 t()，所以英文界面下展开态夹中文。
    // 现有的「源码里每条 t(…) 都有英文对照」那条覆盖面测试抓不到它 —— 它压根没进 t()。
    testWidgets('英文界面下展开态显示 Collapse，不留裸「收起」', (tester) async {
      await pumpAppearance(tester, locale: AppLocale.en);

      expect(
        find.text('Collapse'),
        findsOneWidget,
        reason: '只有「外观」分区是展开的，收起提示该出现一次',
      );
      expect(
        find.text('收起'),
        findsNothing,
        reason: '展开态夹中文 = 这处没走 t()',
      );
      expect(find.text('Show settings'), findsNWidgets(3),
          reason: '另外三个分区的收起态提示本来就是翻好的');
    });
  });
}
