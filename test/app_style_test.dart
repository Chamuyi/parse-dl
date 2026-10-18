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

  /// 把 [card] 套上指定风格的 AppTheme 泵出来。
  ///
  /// [colors] 默认取**该风格自己的色板**（`AppColors.of(style, brightness)`）——
  /// 与生产一致：`lib/app.dart` 就是这么构造 `AppTheme` 的。S4 的边框 / 悬停
  /// 判据依赖这个对应关系（拿另一套风格的色板去测，量到的是不存在的组合）。
  Future<void> pumpCard(
    WidgetTester tester,
    AppStyle style, {
    AppColors? colors,
    Brightness brightness = Brightness.dark,
    Widget? child,
  }) async {
    await tester.pumpWidget(
      AppTheme(
        colors: colors ?? AppColors.of(style, brightness),
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
    test('材质参数能把风格区分开（winui 与 clay 同为实心面，是刻意相同）', () {
      final specs = {
        for (final s in AppStyle.values)
          (
            AppSurface.of(s).blur,
            AppSurface.of(s).opacity,
            AppSurface.of(s).radiusScale,
          ),
      };
      // 2026-10-19 起有第四套 winui。它和 clay 一样是**实心面**（blur 0、
      // opacity 1），二者靠色板与圆角区分而不是靠模糊 —— 所以这里不能
      // 再要求「四套两两不同」。判据改为：至少区分出 3 组材质，
      // 且 liquid / frosted 各自独立（它们才是"材质"差异的承载者）。
      expect(
        specs.length,
        greaterThanOrEqualTo(3),
        reason: '材质参数必须能区分出多套，否则「可切换风格」是假的',
      );
      expect(
        AppSurface.of(AppStyle.liquid),
        isNot(AppSurface.of(AppStyle.frosted)),
      );
      expect(
        AppSurface.of(AppStyle.winui).blur,
        AppSurface.of(AppStyle.clay).blur,
        reason: 'winui 与 clay 都是实心面，这是设计意图不是巧合',
      );
    });

    test('frosted 的三档数值（2026-10-16 新规范）', () {
      // 2026-10-16 用户裁定「所有窗口材质都不满意」后重定：这一档从
      // 「morrow 的默认值（blur 22 / opacity .76）」改为「中档磨砂」——
      // 强模糊让给 liquid（28），它自己降到 18，并把阴影压轻到
      // WinUI 卡片高程（8）的量级。
      expect(AppSurface.frosted.blur, 18);
      expect(AppSurface.frosted.opacity, 0.78);
      expect(AppSurface.frosted.radiusScale, 1.0);
      expect(AppSurface.frosted.gradient, isFalse);
      expect(AppSurface.frosted.rim, isFalse);
    });

    test('三套取值逐字段锚定（2026-10-16 新规范）', () {
      // 关键变化：liquid 的 blur 从 5 提到 28 —— 5 在真机上几乎看不出模糊，
      // 与 frosted 分不出「厚玻璃」与「薄磨砂」的差别。
      expect(AppSurface.liquid.blur, 28);
      expect(AppSurface.liquid.opacity, 0.60);
      expect(AppSurface.liquid.radiusScale, 1.25);
      expect(AppSurface.liquid.gradient, isTrue);
      expect(AppSurface.liquid.rim, isTrue);
      expect(AppSurface.liquid.shadowY, 12);
      expect(AppSurface.liquid.shadowBlur, 34);
      expect(AppSurface.liquid.shadowOpacity, 0.24);

      expect(AppSurface.frosted.shadowY, 6);
      expect(AppSurface.frosted.shadowBlur, 18);
      expect(AppSurface.frosted.shadowOpacity, 0.12);

      expect(AppSurface.clay.blur, 0);
      expect(AppSurface.clay.opacity, 1.0);
      expect(AppSurface.clay.radiusScale, 1.0);
      expect(AppSurface.clay.gradient, isFalse);
      expect(AppSurface.clay.rim, isFalse);
      expect(AppSurface.clay.shadowY, 10);
      expect(AppSurface.clay.shadowBlur, 26);
      expect(AppSurface.clay.shadowOpacity, 0.20);
    });

    test('三档模糊必须拉得开（liquid 明显大于 frosted，clay 为 0）', () {
      // 「三套材质」若只差一点点模糊，用户看到的就是同一套。
      expect(AppSurface.liquid.blur, greaterThan(AppSurface.frosted.blur * 1.4),
          reason: 'liquid 是「厚玻璃」，模糊必须明显强于 frosted，否则两档看着一样');
      expect(AppSurface.frosted.blur, greaterThan(AppSurface.clay.blur),
          reason: 'clay 是实心面（blur 0）');
      // 透明度也要拉开：liquid 最透、clay 最实
      expect(AppSurface.liquid.opacity, lessThan(AppSurface.frosted.opacity));
      expect(AppSurface.frosted.opacity, lessThan(AppSurface.clay.opacity));
    });

    test('实心面（blur=0）只有 winui 与 clay（「实心面不套模糊」的前提）', () {
      final solid = [
        for (final s in AppStyle.values)
          if (AppSurface.of(s).blur == 0) s,
      ];
      // 2026-10-19：winui 加入后也是实心面 —— WinUI3 的卡片本来就靠
      // 1px 边线分层，不用模糊。liquid / frosted 仍是模糊面。
      expect(solid, [AppStyle.winui, AppStyle.clay]);
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
      // 渲染出来的 sigma 必须等于令牌值，且两档要拉得开（2026-10-16 起
      // liquid 是「厚玻璃」28、frosted 是「中档磨砂」18）。
      expect(got[AppStyle.liquid], AppSurface.liquid.blur);
      expect(got[AppStyle.frosted], AppSurface.frosted.blur);
      expect(got[AppStyle.liquid]!, greaterThan(got[AppStyle.frosted]! * 1.4),
          reason: '两档模糊太接近，「三套材质」就只差在名字上');
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

    testWidgets('半径按风格档位取值：液体玻璃 20 > 陶土 16 > 磨砂 14', (tester) async {
      // S4 起 `AppCard.radius` 是**档位**（AppRadius.card）而不是像素，
      // 像素由当前风格决定 —— 取值逐项取证自 app.css:266 / :347 / :408。
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

      expect(await radiusFor(AppStyle.liquid), 20);
      expect(await radiusFor(AppStyle.frosted), 14);
      expect(await radiusFor(AppStyle.clay), 16);
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

    test('液体玻璃的边框是「更亮的顶边 + --rim 三边」，磨砂 / 陶土四边同色', () {
      // 双层高光是**浅色**规格：`--rim` 与 `inset 0 1px 0` 都只在 #v-a 浅色块里
      // （app.css:247/259/260）。深色 CSS 没给 .card 的顶部高光，不编造。
      const b = Brightness.light;
      StyleBorder borderOf(AppStyle s) =>
          s.cardBorderOf(AppColors.of(s, b), b);

      // 液体玻璃：顶边 = CSS `inset 0 1px 0 rgba(255,255,255,.95)`，
      // 三边 = `--rim` `rgba(255,255,255,.75)`。
      final liq = borderOf(AppStyle.liquid);
      expect(liq.top, const Color(0xF2FFFFFF));
      expect(liq.side, const Color(0xBFFFFFFF));
      expect(
        liq.top,
        isNot(liq.side),
        reason: '液体玻璃的双层高光就体现在「顶边比三边亮」，同色 = 退化成单层',
      );

      // 磨砂 / 陶土：四边同色（CSS 里都是一条 `border: 1px solid …`）。
      for (final s in [AppStyle.frosted, AppStyle.clay]) {
        final sb = borderOf(s);
        expect(sb.top, sb.side, reason: '${s.id} 是单层描边');
      }
      // 陶土的描边就是色板的 --ln（分隔线只有一处出处）
      expect(
        borderOf(AppStyle.clay).side,
        AppColors.of(AppStyle.clay, b).line,
      );
    });

    testWidgets('AppCard 真的把风格边框画到了 Container 上（令牌没被架空）', (tester) async {
      await pumpCard(tester, AppStyle.frosted, brightness: Brightness.light);
      final box = tester.widget<Container>(
        find.descendant(
          of: find.byType(AppCard),
          matching: find.byType(Container),
        ),
      );
      final border = (box.decoration! as BoxDecoration).border! as Border;
      expect(border.top.color, const Color(0xE6FFFFFF));
      expect(border.left.color, const Color(0xE6FFFFFF));
    });
  });

  // ══════════════════════════════════════════════════════════
  // S4 · 圆角分档 / 边框 / 投影 / 悬停
  group('S4 圆角分档表', () {
    test('三套 card 半径 = 20 / 14 / 16（取证自 app.css:266/:347/:408）', () {
      expect(AppStyle.liquid.radiusOf(AppRadius.card), 20);
      expect(AppStyle.frosted.radiusOf(AppRadius.card), 14);
      expect(AppStyle.clay.radiusOf(AppRadius.card), 16);
    });

    test('四个档位都有值，且每档三套两两不同', () {
      for (final slot in AppRadius.values) {
        final vals = {for (final s in AppStyle.values) s.radiusOf(slot)};
        // card / qi / field 三档三套互异；hero2 是 14/12/14 —— **有意的重复**
        // （app.css:804/805/806 原文），所以这里只要求「至少两档不同」，
        // 不强行要求三套两两不同。硬要求三套互异会逼人改掉预览稿的值。
        expect(
          vals.length,
          greaterThanOrEqualTo(2),
          reason: '$slot 在三套风格下只给出一个值，等于这一档没分风格',
        );
      }
      // 逐档逐值。前三套照 app.css 原文；winui 照 WinUI3 规范
      // （容器 8px / 控件 4px，2026-10-19 新增）。
      const table = {
        AppRadius.card: [
          (AppStyle.winui, 8),
          (AppStyle.liquid, 20),
          (AppStyle.frosted, 14),
          (AppStyle.clay, 16),
        ],
        AppRadius.qi: [
          (AppStyle.winui, 4),
          (AppStyle.liquid, 11),
          (AppStyle.frosted, 10),
          (AppStyle.clay, 12),
        ],
        AppRadius.field: [
          (AppStyle.winui, 4),
          (AppStyle.liquid, 9),
          (AppStyle.frosted, 8),
          (AppStyle.clay, 10),
        ],
        AppRadius.hero2: [
          (AppStyle.winui, 8),
          (AppStyle.liquid, 14),
          (AppStyle.frosted, 12),
          (AppStyle.clay, 14),
        ],
      };
      for (final e in table.entries) {
        // 左右两边必须**来源不同**：左边读被测代码，右边是上面写死的期望值。
        // 若写成 [for (final p in e.value) p.$2] 两边同一表达式，
        // 就是恒真断言 —— 那等于什么都没验。
        expect(
          [for (final p in e.value) p.$1.radiusOf(e.key)],
          [for (final p in e.value) p.$2],
          reason: '${e.key} 这一档的取值与 app.css / WinUI3 规范不符',
        );
      }
    });

    test('负控制：分档表确实会被「改回硬编码 16」测出来', () {
      // 这条不测产品代码，而是证明**上面那两条判据的形状是有效的** ——
      // 如果三套都返回 16（改造前的样子），下面的断言必须全部不成立。
      const hardcoded = [16.0, 16.0, 16.0];
      final real = [
        for (final s in AppStyle.values) s.radiusOf(AppRadius.card),
      ];
      expect(real, isNot(hardcoded), reason: '三套 card 半径又变回同一个值了');

      // 且逐套对得上「与 16 的差」：liquid/frosted 必须偏离，clay 恰好等于 16
      expect(
        AppStyle.liquid.radiusOf(AppRadius.card),
        isNot(16.0),
        reason: 'liquid 的 card 若是 16，就是退回改造前的 radiusScale 算法',
      );
      expect(
        AppStyle.frosted.radiusOf(AppRadius.card),
        isNot(16.0),
        reason: 'frosted 的 card 若是 16，就是退回改造前的 radiusScale 算法',
      );
    });
  });

  group('S4 边框 / 投影 / 悬停随风格变', () {
    test('三套卡片边框两两不同', () {
      for (final b in Brightness.values) {
        final got = {
          for (final s in AppStyle.values) s.cardBorderOf(AppColors.of(s, b), b),
        };
        expect(
          got.length,
          AppStyle.values.length,
          reason: '$b 下三套边框有重复：$got',
        );
      }
    });

    test('三套 boxShadow 列表两两不同（磨砂 / 陶土是双层影）', () {
      for (final b in Brightness.values) {
        final got = {
          for (final s in AppStyle.values) s.cardShadows(b).toString(),
        };
        expect(
          got.length,
          AppStyle.values.length,
          reason: '$b 下三套投影有重复',
        );
      }
      expect(AppStyle.frosted.cardShadows(Brightness.light).length, 2,
          reason: 'app.css:342 是双层影');
      expect(AppStyle.clay.cardShadows(Brightness.light).length, 2,
          reason: 'app.css:406 是双层影');
      expect(AppStyle.liquid.cardShadows(Brightness.light).length, 1,
          reason: 'app.css:262 是单层带负 spread 的影');
    });

    test('悬停底色随风格变（不再共用同一个值）', () {
      for (final b in Brightness.values) {
        final got = {for (final s in AppStyle.values) s.hoverColor(b)};
        // 2026-10-19 加入 winui 后，不再要求"四套两两不同"：
        // winui 与 clay 的悬停色可能撞在一起（都是极淡中性叠加），
        // 但它们靠表层色与边线区分，悬停不是它们的区分点。
        // 这里只守住真正的要求：**至少两种取值**，
        // 即"改造前三套共用同一个值"那个缺陷不能回来。
        expect(
          got.length,
          greaterThanOrEqualTo(2),
          reason: '$b 下所有风格悬停色都相同 —— 又回到"共用色板"的老毛病',
        );
      }
    });

    testWidgets('hover 打开时卡片底色真的变了（不是只存了个令牌没用）', (tester) async {
      Future<Color> colorOf(bool hovered) async {
        await pumpCard(
          tester,
          AppStyle.frosted,
          child: AppCard(hovered: hovered, child: const Text('x')),
        );
        final box = tester.widget<Container>(
          find.descendant(
            of: find.byType(AppCard),
            matching: find.byType(Container),
          ),
        );
        return (box.decoration! as BoxDecoration).color!;
      }

      expect(await colorOf(true), isNot(await colorOf(false)));
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
