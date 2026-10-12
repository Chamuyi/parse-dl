import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/l10n/app_locale.dart';
import 'package:parse_dl/l10n/l10n.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/window_material.dart';
import 'package:parse_dl/widgets/app_card.dart';
import 'package:parse_dl/widgets/style_picker.dart';

/// P1 风格系统的判据。
///
/// 分三层，各自独立可判错：
///   1. **令牌**（纯函数）：三套取值互不相同、且 frosted 逐字等于 morrow 的默认；
///   2. **渲染**（widget）：卡片真的按风格换材质 —— 结构上陶土不挂
///      `BackdropFilter`、液体玻璃画渐变面；
///   3. **持久化与迁移**：新字段往返、旧配置回退 frosted。
///
/// 每条"守卫型"判据都配了负控制：把被守护的值改坏，它必须变红。
void main() {
  const dark = AppColors.dark;
  const light = AppColors.light;

  /// 把 [card] 套上指定风格的 AppTheme 泵出来
  Future<void> pumpCard(
    WidgetTester tester,
    AppStyle style, {
    AppColors colors = dark,
    Brightness brightness = Brightness.dark,
    Widget? child,
  }) async {
    await tester.pumpWidget(
      AppTheme(
        colors: colors,
        brightness: brightness,
        style: style,
        child: MaterialApp(
          home: Scaffold(body: Center(child: child ?? const AppCard(child: Text('x')))),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ══════════════════════════════════════════════════════════
  group('AppSurface 令牌', () {
    test('三套风格的 blur / opacity / radiusScale 两两不同', () {
      final specs = {
        for (final s in AppStyle.values)
          (
            AppSurface.of(s).blur,
            AppSurface.of(s).opacity,
            AppSurface.of(s).radiusScale,
          ),
      };
      expect(
        specs.length,
        AppStyle.values.length,
        reason: '三个参数必须把三套风格区分开，否则「可切换风格」是假的',
      );
    });

    test('frosted 的取值就是 morrow 的默认值（blur 22 / opacity .76）', () {
      // 这条是**出处判据**：`tools/ui/_redesign/morrow/lib/appearance.dart`
      // 里 ComponentMaterial 的构造默认与 fromJson 兜底都是这两个数。
      // 谁把默认值改成别的，这条立刻红。
      expect(AppSurface.frosted.blur, 22);
      expect(AppSurface.frosted.opacity, 0.76);
      expect(AppSurface.frosted.radiusScale, 1.0);
      expect(AppSurface.frosted.gradient, isFalse);
      expect(AppSurface.frosted.rim, isFalse);
    });

    test('三套取值逐字段照预览稿实测表', () {
      // 照抄实施计划 P1-1 的那张表。任何一格被改，这里指名道姓地红。
      expect(AppSurface.liquid.blur, 5);
      expect(AppSurface.liquid.opacity, 0.62);
      expect(AppSurface.liquid.radiusScale, 1.25);
      expect(AppSurface.liquid.gradient, isTrue);
      expect(AppSurface.liquid.rim, isTrue);
      expect(AppSurface.liquid.shadowY, 10);
      expect(AppSurface.liquid.shadowBlur, 30);
      expect(AppSurface.liquid.shadowOpacity, 0.20);

      expect(AppSurface.frosted.shadowY, 8);
      expect(AppSurface.frosted.shadowBlur, 24);
      expect(AppSurface.frosted.shadowOpacity, 0.22);

      expect(AppSurface.clay.blur, 0);
      expect(AppSurface.clay.opacity, 1.0);
      expect(AppSurface.clay.radiusScale, 1.0);
      expect(AppSurface.clay.gradient, isFalse);
      expect(AppSurface.clay.rim, isFalse);
      expect(AppSurface.clay.shadowY, 12);
      expect(AppSurface.clay.shadowBlur, 28);
      expect(AppSurface.clay.shadowOpacity, 0.35);
    });

    test('只有陶土的 blur 是 0（「实心面不套模糊」的前提）', () {
      final solid = [
        for (final s in AppStyle.values)
          if (AppSurface.of(s).blur == 0) s,
      ];
      expect(solid, [AppStyle.clay]);
    });

    test('液体玻璃是唯一同时有渐变面与内缘亮环的', () {
      for (final s in AppStyle.values) {
        final surf = AppSurface.of(s);
        expect(
          surf.gradient,
          s == AppStyle.liquid,
          reason: '${s.id} 的 gradient 与「只有液体玻璃有渐变」不符',
        );
        expect(surf.rim, s == AppStyle.liquid);
      }
    });

    test('AppStyle.fromId 认 id、坏值回退 frosted', () {
      expect(AppStyle.fromId('liquid'), AppStyle.liquid);
      expect(AppStyle.fromId('clay'), AppStyle.clay);
      expect(AppStyle.fromId('frosted'), AppStyle.frosted);
      // 旧配置没有这个字段 → null；手工改坏 → 不认识的串。两者都必须回退。
      expect(AppStyle.fromId(null), AppStyle.frosted);
      expect(AppStyle.fromId(''), AppStyle.frosted);
      expect(AppStyle.fromId('neumorphism'), AppStyle.frosted);
    });
  });

  // ══════════════════════════════════════════════════════════
  group('底色派生', () {
    test('frosted 的卡片底色逐字节等于色板原值（不改设置观感不变）', () {
      for (final c in [dark, light]) {
        expect(
          AppSurface.frosted.resolveCardColor(c.surfaceCard, c.surfaceSolid),
          c.surfaceCard,
          reason: '默认风格必须原样透传色板色，否则不改设置的用户也会看出差别',
        );
      }
    });

    test('clay 用不透明底色，不是把半透明色的 alpha 拉满', () {
      // 把 `Color(0x0EFFFFFF)`（5.5% 白）的 alpha 拉满会得到一张纯白板 ——
      // 深色主题下直接瞎眼。所以实心风格必须换成 surfaceSolid。
      final got = AppSurface.clay.resolveCardColor(dark.surfaceCard, dark.surfaceSolid);
      expect(got, dark.surfaceSolid);
      expect(got.a, 1.0);
    });

    test('liquid 比 frosted 更透（同一色板下 alpha 更小）', () {
      final liq = AppSurface.liquid.resolveCardColor(dark.surfaceCard, dark.surfaceSolid);
      final fro = AppSurface.frosted.resolveCardColor(dark.surfaceCard, dark.surfaceSolid);
      expect(liq.a, lessThan(fro.a));
    });

    test('浅色主题的投影比深色主题轻', () {
      for (final s in AppStyle.values) {
        final surf = AppSurface.of(s);
        expect(
          surf.shadowAlphaFor(Brightness.light),
          lessThan(surf.shadowAlphaFor(Brightness.dark)),
          reason: '同一档黑影压在浅底上格外显眼，旧实现就是分两档的',
        );
      }
    });
  });

  // ══════════════════════════════════════════════════════════
  group('AppCard 按风格渲染', () {
    testWidgets('陶土风格不套 BackdropFilter（实心面不该有模糊）', (tester) async {
      await pumpCard(tester, AppStyle.clay);

      expect(find.byType(AppCard), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppCard),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
        reason: 'clay 的 blur 是 0，糊一层什么都看不出来，白付一次离屏合成',
      );
    });

    testWidgets('液体玻璃与磨砂都挂 BackdropFilter（负控制的反面）', (tester) async {
      for (final s in [AppStyle.liquid, AppStyle.frosted]) {
        await pumpCard(tester, s);
        expect(
          find.descendant(
            of: find.byType(AppCard),
            matching: find.byType(BackdropFilter),
          ),
          findsOneWidget,
          reason: '${s.id} 的 blur > 0，必须真的糊',
        );
      }
    });

    testWidgets('三套风格渲染出的模糊 sigma 两两不同', (tester) async {
      /// 从 ImageFilter 里抽出 sigma 值。
      ///
      /// **不整串比 `toString()`**：那是 Flutter 的内部格式
      /// （当前是 `ImageFilter.blur(22.0, 22.0, unspecified)`），
      /// 换个版本就可能变形状，判据会莫名变红。这里只正则抽数字。
      final rx = RegExp(r'([0-9]+(?:\.[0-9]+)?)');
      double sigmaOf(WidgetTester tester) {
        final f = tester
            .widget<BackdropFilter>(
              find.descendant(
                of: find.byType(AppCard),
                matching: find.byType(BackdropFilter),
              ),
            )
            .filter;
        final nums = rx
            .allMatches(f.toString())
            .map((m) => double.parse(m.group(1)!))
            .toList();
        expect(nums, isNotEmpty, reason: '没从 $f 里抽出任何数字');
        return nums.first;
      }

      final got = <AppStyle, double>{};
      for (final s in AppStyle.values) {
        await pumpCard(tester, s);
        if (AppSurface.of(s).blur > 0) got[s] = sigmaOf(tester);
      }

      expect(got.keys.toSet(), {AppStyle.liquid, AppStyle.frosted});
      expect(got[AppStyle.liquid], 5);
      expect(got[AppStyle.frosted], 22);
      expect(got[AppStyle.liquid], isNot(got[AppStyle.frosted]));
    });

    testWidgets('显式传 blur 时覆盖风格（老调用点的语义没被夺走）', (tester) async {
      await pumpCard(
        tester,
        AppStyle.clay,
        child: const AppCard(blur: 9, child: Text('x')),
      );
      // 陶土的风格值是 0，但显式传了 9 → 仍然要糊
      expect(
        find.descendant(
          of: find.byType(AppCard),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
        reason: '显式传的 blur 优先于风格默认，否则老调用点会被悄悄改掉',
      );
    });

    testWidgets('半径按 radiusScale 缩放：液体玻璃 > 磨砂 = 陶土', (tester) async {
      Future<double> radiusFor(AppStyle s) async {
        await pumpCard(tester, s);
        final box = tester.widget<Container>(
          find.descendant(
            of: find.byType(AppCard),
            matching: find.byType(Container),
          ),
        );
        final deco = box.decoration! as BoxDecoration;
        return deco.borderRadius!.resolve(TextDirection.ltr).topLeft.x;
      }

      final liq = await radiusFor(AppStyle.liquid);
      final fro = await radiusFor(AppStyle.frosted);
      final cla = await radiusFor(AppStyle.clay);

      // 默认 radius = 16
      expect(fro, 16);
      expect(cla, 16);
      expect(liq, 16 * 1.25);
      expect(liq, greaterThan(fro));
    });

    testWidgets('只有液体玻璃画渐变面', (tester) async {
      Future<Gradient?> gradientFor(AppStyle s) async {
        await pumpCard(tester, s);
        final box = tester.widget<Container>(
          find.descendant(
            of: find.byType(AppCard),
            matching: find.byType(Container),
          ),
        );
        return (box.decoration! as BoxDecoration).gradient;
      }

      expect(await gradientFor(AppStyle.liquid), isA<LinearGradient>());
      expect(await gradientFor(AppStyle.frosted), isNull);
      expect(await gradientFor(AppStyle.clay), isNull);
    });

    testWidgets('液体玻璃的内缘亮环比常规描边亮', (tester) async {
      Future<Color> borderFor(AppStyle s) async {
        await pumpCard(tester, s);
        final box = tester.widget<Container>(
          find.descendant(
            of: find.byType(AppCard),
            matching: find.byType(Container),
          ),
        );
        final deco = box.decoration! as BoxDecoration;
        return (deco.border! as Border).top.color;
      }

      expect(await borderFor(AppStyle.liquid), AppSurface.liquid.rimColor(Brightness.dark));
      expect(await borderFor(AppStyle.frosted), dark.line);
    });
  });

  // ══════════════════════════════════════════════════════════
  group('设置持久化与迁移', () {
    test('往返编解码保留选择', () {
      for (final s in AppStyle.values) {
        final a = AppearanceSettings(visualStyle: s);
        final round = AppearanceSettings.fromJson(a.toJson());
        expect(round.visualStyle, s, reason: '${s.id} 往返后丢了');
      }
      expect(
        AppearanceSettings(visualStyle: AppStyle.clay).toJson()['visualStyle'],
        'clay',
        reason: '落盘的是 id 字符串，不是枚举下标',
      );
    });

    test('默认是 frosted', () {
      expect(AppearanceSettings().visualStyle, AppStyle.frosted);
      expect(Settings().appearance.visualStyle, AppStyle.frosted);
    });

    test('旧配置没有 visualStyle 字段 → 读出 frosted', () {
      // 迁移判据：不是崩、也不是别的值
      final legacy = <String, dynamic>{
        'themeMode': 'dark',
        'windowMaterial': 'acrylic',
        'navLayout': 'sidebar',
        'locale': 'en',
        // 故意不写 visualStyle
      };
      final a = AppearanceSettings.fromJson(legacy);
      expect(a.visualStyle, AppStyle.frosted);
      // 同一次解码里其余字段照旧被读到，证明不是"整份退回默认"
      expect(a.themeMode, ThemeMode2.dark);
      expect(a.navLayout, NavLayout.sidebar);
      expect(a.locale, AppLocale.en);
    });

    test('负控制：旧配置绝不会读成 liquid / clay', () {
      final a = AppearanceSettings.fromJson(<String, dynamic>{});
      expect(a.visualStyle, isNot(AppStyle.liquid));
      expect(a.visualStyle, isNot(AppStyle.clay));
    });

    test('整份 Settings.decode：旧 json 缺字段也回退 frosted', () {
      const legacyJson = '{"state":{"appearance":{"themeMode":"light"}},'
          '"version":3}';
      final s = Settings.decode(legacyJson);
      expect(s.appearance.visualStyle, AppStyle.frosted);
      expect(s.appearance.themeMode, ThemeMode2.light);
    });

    test('坏值（不认识的 id）回退 frosted，不崩', () {
      final a = AppearanceSettings.fromJson(<String, dynamic>{
        'visualStyle': 'neumorphism',
      });
      expect(a.visualStyle, AppStyle.frosted);
    });
  });

  // ══════════════════════════════════════════════════════════
  group('StylePicker', () {
    Future<void> pumpPicker(
      WidgetTester tester, {
      required AppStyle value,
      ValueChanged<AppStyle>? onChanged,
    }) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        AppTheme(
          colors: dark,
          brightness: Brightness.dark,
          child: MaterialApp(
            home: Scaffold(
              body: StylePicker(value: value, onChanged: onChanged ?? (_) {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('三套风格各一张卡，标签都在', (tester) async {
      await pumpPicker(tester, value: AppStyle.frosted);

      for (final s in AppStyle.values) {
        expect(find.text(t(s.label)), findsOneWidget, reason: '缺「${s.label}」');
      }
    });

    testWidgets('选中态用 selectedDecoration：恰好一张卡被选中', (tester) async {
      await pumpPicker(tester, value: AppStyle.clay);

      final selected = find.byWidgetPredicate(
        (w) =>
            w is AnimatedContainer &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == dark.accentSoft,
      );
      expect(selected, findsOneWidget);
      // 选中那张是陶土
      expect(
        find.descendant(of: selected, matching: find.text(t('陶土柔和'))),
        findsOneWidget,
      );
    });

    testWidgets('点击卡片回调对应风格', (tester) async {
      AppStyle? picked;
      await pumpPicker(
        tester,
        value: AppStyle.frosted,
        onChanged: (s) => picked = s,
      );

      await tester.tap(find.text(t('液体玻璃')));
      await tester.pumpAndSettle();
      expect(picked, AppStyle.liquid);
    });

    testWidgets('缩略图把风格差异画出来：陶土那张没有模糊，另两张有', (tester) async {
      // 缩略图内部按风格决定挂不挂 BackdropFilter。三张图若长得一样，
      // 这里会是 3 个 —— 那这张预览就白画了。
      await pumpPicker(tester, value: AppStyle.frosted);

      expect(
        find.descendant(
          of: find.byType(StylePicker),
          matching: find.byType(BackdropFilter),
        ),
        findsNWidgets(2),
        reason: '只有 liquid(5) 与 frosted(22) 该糊背景，clay(0) 不该',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  group('英文对照', () {
    test('四条文案在英文档下有对照，且不是退回中文', () {
      applyLocaleSetting(AppLocale.en);
      addTearDown(() => applyLocaleSetting(AppLocale.system));

      expect(t('界面风格'), 'Interface style');
      expect(t('液体玻璃'), 'Liquid glass');
      expect(t('磨砂清晰'), 'Frosted');
      expect(t('陶土柔和'), 'Clay');
    });

    test('三套风格的 label / description 全都有英文（英文界面不夹中文）', () {
      applyLocaleSetting(AppLocale.en);
      addTearDown(() => applyLocaleSetting(AppLocale.system));

      final cjk = RegExp(r'[\u4e00-\u9fff]');
      for (final s in AppStyle.values) {
        expect(cjk.hasMatch(t(s.label)), isFalse, reason: '${s.id}.label 没翻');
        expect(
          cjk.hasMatch(t(s.description)),
          isFalse,
          reason: '${s.id}.description 没翻',
        );
      }
    });
  });
}
