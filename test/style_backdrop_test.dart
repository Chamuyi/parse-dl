import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/style_backdrop.dart';
import 'package:parse_dl/theme/style_colors.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/theme/window_material.dart';
import 'package:parse_dl/widgets/background_layer.dart';

/// S3 验收：背景层按风格出不同底。
///
/// 层数判据是任务书钉死的：liquid = 3（三层 radial）+ 1（线性），
/// frosted = 1、clay = 1（单层线性）。负控制证明「切风格后背景 widget 树不同」
/// 不是恒真 —— 改坏会红。
void main() {
  // ══════════════════════════════════════════════════════════
  // 令牌层：层数与两两不同
  // ══════════════════════════════════════════════════════════

  group('StyleBackdrop 层数', () {
    test('liquid 浅色 = 3 层 radial + 1 层线性（CSS :248-252）', () {
      final b = StyleBackdrop.of(AppStyle.liquid, Brightness.light);
      expect(b.glowCount, 3, reason: '液体玻璃浅色要有三层 radial 光晕');
      expect(b.linear.stops.length, 1 + 2, reason: '线性渐变至少两停');
      // 三层光晕的颜色 = CSS 原文 #cfe0ff / #ffd9ec / #d6fff0
      expect(b.glows[0].color, const Color(0x59CFE0FF));
      expect(b.glows[1].color, const Color(0x59FFD9EC));
      expect(b.glows[2].color, const Color(0x59D6FFF0));
      expect(b.linear.stops[0], const Color(0x59F7F8FE));
      expect(b.linear.stops.last, const Color(0x59F6F4F2));
    });

    test('liquid 深色 = 3 层 radial + 1 层线性（CSS :834-838）', () {
      final b = StyleBackdrop.of(AppStyle.liquid, Brightness.dark);
      expect(b.glowCount, 3);
      expect(b.glows[0].color, const Color(0x592A2545));
      expect(b.glows[1].color, const Color(0x593A2438));
      expect(b.glows[2].color, const Color(0x591F3A38));
      expect(b.linear.stops[0], const Color(0x5914131C));
      expect(b.linear.stops[1], const Color(0x59181722));
      expect(b.linear.stops.last, const Color(0x5916151F));
    });

    test('frosted = 1 层（单层线性，无光晕）（CSS :332 / :885）', () {
      for (final brightness in Brightness.values) {
        final b = StyleBackdrop.of(AppStyle.frosted, brightness);
        expect(b.glowCount, 0, reason: 'frosted 没有 radial 光晕');
        expect(b.linear.stops, hasLength(3));
      }
      expect(StyleBackdrop.frostedLight.linear.stops,
          const [Color(0x59EEF1F6), Color(0x59E8ECF3), Color(0x59F0EEF3)]);
      expect(StyleBackdrop.frostedDark.linear.stops,
          const [Color(0x5917171A), Color(0x591B1B1F), Color(0x59191820)]);
    });

    test('clay = 1 层（单层线性，无光晕）（CSS :399 / :932）', () {
      for (final brightness in Brightness.values) {
        final b = StyleBackdrop.of(AppStyle.clay, brightness);
        expect(b.glowCount, 0, reason: 'clay 没有 radial 光晕');
        expect(b.linear.stops, hasLength(3));
      }
      expect(StyleBackdrop.clayLight.linear.stops,
          const [Color(0x59FAF6F1), Color(0x59F5EFE8), Color(0x59F8F4EF)]);
      expect(StyleBackdrop.clayDark.linear.stops,
          const [Color(0x591F1A16), Color(0x59241E19), Color(0x59221D19)]);
    });

    test('六套背景两两不同（同亮度下三风格不同；同风格下两亮度不同）', () {
      final tokens = <String, StyleBackdrop>{
        for (final s in AppStyle.values)
          for (final b in Brightness.values) '${s.id}-${b.name}': StyleBackdrop.of(s, b),
      };
      expect(tokens, hasLength(6));
      final seen = <StyleBackdrop>[];
      for (final entry in tokens.entries) {
        for (final prev in seen) {
          expect(
            entry.value == prev,
            isFalse,
            reason: '${entry.key} 与另一套背景完全相同 —— 风格区分失效',
          );
        }
        seen.add(entry.value);
      }
    });

    test('六套背景都必须**半透明** —— 否则窗口材质被整片盖死', () {
      // 2026-10-16 真机实测到的缺陷：这一层原本每个色停都是 `0xFF`，
      // 绘制器又铺满整窗，于是 mica / 亚克力 / 纯色三种材质渲染出来
      // 逐像素完全相同（平均差 0.00）——「窗口材质」这个设置项等于没有效果。
      //
      // 判据：任何一个色停都不能是 alpha=255；且整体要留出足够透光率
      // （<0.5），否则材质只剩几个亮度级、肉眼看不出来。
      for (final s in AppStyle.values) {
        for (final b in Brightness.values) {
          final bd = StyleBackdrop.of(s, b);
          final all = <Color>[
            for (final g in bd.glows) g.color,
            ...bd.linear.stops,
          ];
          expect(all, isNotEmpty);
          for (final c in all) {
            expect(c.a, lessThan(0.5),
                reason: '${s.id}/${b.name} 有不透明色停（alpha=${c.a}）—— '
                    '窗口材质会被它盖住，三种材质渲染结果将完全相同');
          }
        }
      }
    });

    test('负控制：把色停改成不透明会被上面那条判据抓住', () {
      // 复现改造前的写法（0xFF），证明上一条不是恒真。
      const opaqueStop = Color(0xFFF7F8FE);
      expect(opaqueStop.a, greaterThanOrEqualTo(0.5),
          reason: '不透明的色停必须被判为不合规');
    });
  });

  // ══════════════════════════════════════════════════════════
  // widget 层：负控制 —— 切风格后背景 widget 树必须不同
  // ══════════════════════════════════════════════════════════

  /// 风格背景绘制器的 Finder：按 painter 运行时类型（`_BackdropPainter` 是
  /// background_layer.dart 的私有类，测试侧用类型名匹配，避开 Material 自带的
  /// Scrollbar 等 CustomPaint）。
  Finder backdropPaint() => find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter.toString().startsWith('_BackdropPainter'),
      );
  /// 渲染 BackgroundLayer 并返回其底层子 widget 树的描述串。
  /// 只取背景层分支（CustomPaint / ColoredBox），不含背景图。
  Future<String> dumpBackdrop(WidgetTester tester, AppStyle style) async {
    final appearance = AppearanceSettings(
      windowMaterial: WindowMaterial.mica,
    );
    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.of(style, Brightness.light),
        brightness: Brightness.light,
        style: style,
        child: MaterialApp(
          home: Scaffold(
            body: BackgroundLayer(appearance: appearance, brightness: Brightness.light),
          ),
        ),
      ),
    );
    final element = tester.element(find.byType(BackgroundLayer));
    // 用 widget 树描述做指纹：类型 + 关键字段（颜色 / painter）
    void walk(Element el, StringBuffer sb) {
      final w = el.widget;
      sb.writeln(w.runtimeType);
      if (w is ColoredBox) sb.writeln('  color=${w.color}');
      if (w is CustomPaint) sb.writeln('  painter=${w.painter}');
      el.visitChildren((c) => walk(c, sb));
    }

    final sb = StringBuffer();
    walk(element, sb);
    final dump = sb.toString();
    expect(dump, contains('_BackdropPainter'), reason: 'Mica 路径必须走风格背景绘制器');
    return dump;
  }

  testWidgets('负控制：切换风格后背景 widget 树不同（三套互异）', (tester) async {
    final dumps = <String, String>{
      for (final s in AppStyle.values) s.id: await dumpBackdrop(tester, s),
    };
    // 三套两两不同 —— 若 BackgroundLayer 退化成不读风格（回归），这里必红。
    expect(dumps['liquid'], isNot(dumps['frosted']));
    expect(dumps['liquid'], isNot(dumps['clay']));
    expect(dumps['frosted'], isNot(dumps['clay']));
  });

  // ══════════════════════════════════════════════════════════
  // 既有三条路径仍工作
  // ══════════════════════════════════════════════════════════

  testWidgets('纯色材质 → 不透明实色（不走风格绘制器）', (tester) async {
    final appearance = AppearanceSettings(windowMaterial: WindowMaterial.none);
    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.of(AppStyle.liquid, Brightness.light),
        brightness: Brightness.light,
        style: AppStyle.liquid,
        child: MaterialApp(
          home: Scaffold(
            body: BackgroundLayer(appearance: appearance, brightness: Brightness.light),
          ),
        ),
      ),
    );
    // 底色 = 该风格色板的 surfaceSolid（2026-10-16 起 solidFor 不再分叉，
    // 按风格取 —— liquid 浅色是 #FAFAFF 的冷紫调，不是旧的通用灰 #F3F3F3），
    // 且无风格绘制器
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is ColoredBox &&
            w.color == StyleColors.liquidLight.colors.surfaceSolid,
      ),
      findsOneWidget,
    );
    expect(backdropPaint(), findsNothing,
        reason: '纯色材质不该画风格渐变');
  });

  testWidgets('自定义色调 → tintFor 混合色（不走风格绘制器）', (tester) async {
    final appearance = AppearanceSettings(
      windowMaterial: WindowMaterial.mica,
      customTint: true,
      tintColor: '#FF0000',
    );
    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.of(AppStyle.liquid, Brightness.light),
        brightness: Brightness.light,
        style: AppStyle.liquid,
        child: MaterialApp(
          home: Scaffold(
            body: BackgroundLayer(appearance: appearance, brightness: Brightness.light),
          ),
        ),
      ),
    );
    final expected = AppColors.tintFor(const Color(0x59FF0000), Brightness.light);
    expect(
      find.byWidgetPredicate((w) => w is ColoredBox && w.color == expected),
      findsOneWidget,
    );
    expect(backdropPaint(), findsNothing);
  });

  testWidgets('Mica 路径永远铺一层底（绘制器 + 85% 调色层都在）', (tester) async {
    final appearance = AppearanceSettings(windowMaterial: WindowMaterial.mica);
    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.of(AppStyle.frosted, Brightness.dark),
        brightness: Brightness.dark,
        style: AppStyle.frosted,
        child: MaterialApp(
          home: Scaffold(
            body: BackgroundLayer(appearance: appearance, brightness: Brightness.dark),
          ),
        ),
      ),
    );
    // 85% 调色层 = 该风格色板的 surfaceSolid at 85%（2026-10-16 起按风格取，
    // 不再恒用 frosted 的 #202020）
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is ColoredBox &&
            w.color ==
                StyleColors.frostedDark.colors.surfaceSolid
                    .withValues(alpha: 0.85),
      ),
      findsOneWidget,
      reason: 'Mica 没生效时这层保证界面可见（黑窗 bug 的守门判据）',
    );
    expect(backdropPaint(), findsOneWidget);
  });
}
