import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/app_card.dart';

/// 风格系统的判据（单风格版）。
///
/// ### 2026-10-19 整体重写（用户裁定「你去把其他的删了」）
///
/// 旧版测的是「liquid / frosted / clay / winui 四套互不相同」。三套已删除，
/// 那些断言失去对象 —— 这不是放宽而是换锚：
///
///   旧判据                          新判据
///   四套取值两两不同        ->      只留 winui，逐字段锚定官方值
///   frosted 逐字等于 morrow ->      窗口底 #2C2C2C / #202020 层级
///   按风格换材质（分支）    ->      卡片不套模糊（官方禁止多层亚克力）
///   旧配置回退 frosted      ->      旧 id 回退 winui
///
/// 每条守卫型判据仍配负控制：把被守护的值改坏，它必须变红。
void main() {
  const dark = AppColors.dark;

  Future<void> pumpCard(
    WidgetTester tester, {
    Brightness brightness = Brightness.dark,
  }) async {
    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.of(AppStyle.winui, brightness),
        brightness: brightness,
        style: AppStyle.winui,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: AppCard(child: Text('x')))),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('AppSurface 令牌（单风格）', () {
    test('winui 是实心面：不模糊、不渐变、无内缘环、投影极轻', () {
      const s = AppSurface.winui;
      expect(s.blur, 0);
      expect(s.opacity, 1.0);
      expect(s.gradient, isFalse);
      expect(s.rim, isFalse);
      expect(s.radiusScale, 1.0);
      expect(s.shadowOpacity, lessThan(0.10));
      expect(s.shadowBlur, lessThanOrEqualTo(8));
    });

    test('负控制：模糊面的值确实与 winui 不同（证明上一条不是恒真）', () {
      const blurry = AppSurface(
        blur: 28,
        opacity: 0.60,
        radiusScale: 1.25,
        gradient: true,
        rim: true,
        shadowY: 12,
        shadowBlur: 34,
        shadowOpacity: 0.24,
      );
      expect(blurry.blur, isNot(AppSurface.winui.blur));
      expect(blurry.gradient, isNot(AppSurface.winui.gradient));
      expect(blurry.rim, isNot(AppSurface.winui.rim));
    });

    test('AppSurface.of 恒返回 winui', () {
      expect(AppSurface.of(AppStyle.winui), same(AppSurface.winui));
    });

    test('fromId：认 winui，旧三套 id 与坏值都回退 winui', () {
      expect(AppStyle.fromId('winui'), AppStyle.winui);
      for (final old in ['liquid', 'frosted', 'clay', null, 'nope']) {
        expect(AppStyle.fromId(old), AppStyle.winui,
            reason: '$old 必须迁移到 winui');
      }
    });
  });

  group('底色派生（单风格）', () {
    test('卡片用不透明底色，不是把半透明色 alpha 拉满', () {
      const s = AppSurface.winui;
      final card = s.resolveCardColor(dark.surfaceCard, dark.surfaceSolid);
      expect(card, dark.surfaceSolid);
      expect(card.a, 1.0);
    });

    test('负控制：半透明面走另一条分支（alpha < 1）', () {
      const translucent = AppSurface(
        blur: 18,
        opacity: 0.78,
        radiusScale: 1.0,
        gradient: false,
        rim: false,
        shadowY: 6,
        shadowBlur: 18,
        shadowOpacity: 0.12,
      );
      final card =
          translucent.resolveCardColor(dark.surfaceCard, dark.surfaceSolid);
      expect(card.a, lessThan(1.0));
    });

    test('浅色主题的投影比深色轻', () {
      const s = AppSurface.winui;
      expect(s.shadowAlphaFor(Brightness.light),
          lessThan(s.shadowAlphaFor(Brightness.dark)));
    });
  });

  group('AppCard 渲染（单风格）', () {
    testWidgets('卡片不套 BackdropFilter（官方禁止多层亚克力）', (tester) async {
      await pumpCard(tester);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('负控制：模糊面确实会挂 BackdropFilter', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: const SizedBox(width: 10, height: 10),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('卡片有 1px 边线且四边同色', (tester) async {
      await pumpCard(tester);
      final boxes = tester
          .widgetList<Container>(find.descendant(
            of: find.byType(AppCard),
            matching: find.byType(Container),
          ))
          .toList();
      BoxDecoration? deco;
      for (final b in boxes) {
        final d = b.decoration;
        if (d is BoxDecoration && d.border != null) {
          deco = d;
          break;
        }
      }
      expect(deco, isNotNull, reason: 'WinUI 卡片必须靠 1px 边线分层');
      expect((deco!.border as Border).isUniform, isTrue,
          reason: '非 uniform 边框会让子内容消失（历史缺陷）');
    });
  });

  group('S4 圆角分档表（单风格）', () {
    test('四档 = WinUI3 规范（容器 8 / 控件 4）', () {
      expect(AppStyle.winui.radiusOf(AppRadius.card), 8);
      expect(AppStyle.winui.radiusOf(AppRadius.hero2), 8);
      expect(AppStyle.winui.radiusOf(AppRadius.qi), 4);
      expect(AppStyle.winui.radiusOf(AppRadius.field), 4);
    });

    test('负控制：card 档不是改造前的硬编码 16', () {
      expect(AppStyle.winui.radiusOf(AppRadius.card), isNot(16));
    });
  });

  group('S4 边框 / 投影 / 悬停（单风格）', () {
    test('卡片边框取色板 line（单出处）', () {
      final b = AppStyle.winui.cardBorderOf(dark, Brightness.dark);
      expect(b.side, dark.line);
      expect(b.hasTopHighlight, isFalse);
      expect(b.toBorder().isUniform, isTrue);
    });

    test('投影只有一层且极淡', () {
      final shadows = AppStyle.winui.cardShadows(Brightness.dark);
      expect(shadows, hasLength(1));
      expect(shadows.first.blurRadius, lessThanOrEqualTo(4));
      expect(shadows.first.color.a, lessThan(0.15));
    });

    test('悬停底色随明暗分档，且都很淡', () {
      final l = AppStyle.winui.hoverColor(Brightness.light);
      final d = AppStyle.winui.hoverColor(Brightness.dark);
      expect(l, isNot(d));
      expect(l.a, lessThan(0.10));
      expect(d.a, lessThan(0.10));
    });
  });

  group('设置持久化与迁移（单风格）', () {
    test('往返编解码保留选择，默认 winui', () {
      final a = AppearanceSettings();
      expect(a.visualStyle, AppStyle.winui);
      expect(AppearanceSettings.fromJson(a.toJson()).visualStyle,
          AppStyle.winui);
    });

    test('旧配置没有 visualStyle 字段 → 读出 winui', () {
      expect(AppearanceSettings.fromJson(const {}).visualStyle,
          AppStyle.winui);
    });

    test('负控制：旧的三套 id 绝不会被当成独立风格读回', () {
      for (final old in ['liquid', 'frosted', 'clay']) {
        expect(AppearanceSettings.fromJson({'visualStyle': old}).visualStyle,
            AppStyle.winui,
            reason: '$old 已删除，必须迁移到 winui');
      }
    });

    test('坏值回退 winui，不崩', () {
      expect(AppearanceSettings.fromJson(const {'visualStyle': 'nope'}).visualStyle,
          AppStyle.winui);
    });
  });
}
