import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 43 处原生按钮（FilledButton / FilledButton.tonal* / TextButton /
/// OutlinedButton，pages/ 与 widgets/ 下约 10 个文件）的观感必须随界面风格变化。
///
/// 令牌在 `app_style.dart` 的 [StyleButton] 六套常量里（CSS `.btn` /
/// `.btn.primary`：liquid `app.css:293-302`、frosted `:364-370`、clay
/// `:427-435`；深色 `:849` / `:898` / `:945`）。这里钉的是 `buildAppTheme`
/// 把这套令牌下发到 Material 3 按钮主题这件事 —— 调用点零改动、主题层生效。
///
/// 渐变的能力边界（与实现注释一致）：liquid / clay 主按钮的 CSS 是
/// `linear-gradient(135deg, var(--ac), var(--ac2))`，Material 3 的
/// `ButtonStyle.backgroundColor` 只接受一个 [Color]，主题层发不了渐变；
/// 这里取渐变主色段（CSS `--ac` = 色板 `accent`）做实色近似。
void main() {
  // ══ 判据有效性开关（负控制）══════════════════════════════════
  // 改成 AppStyle.clay：把 liquid 浅色「普通按钮底」的断言指向另一套的取值
  // ——「三套浅色·普通按钮底」那组测试必须变红（证明断言会判错，不是恒真）。
  // 收尾必须改回 AppStyle.liquid（2026-10-13 已真跑红一次，原始输出见回报）。
  AppStyle kNegativeControlTarget = AppStyle.liquid;

  ThemeData themeOf(AppStyle style, Brightness b) =>
      buildAppTheme(AppColors.of(style, b), b, style: style);

  ButtonStyle textStyleOf(AppStyle s, Brightness b) =>
      themeOf(s, b).textButtonTheme.style!;
  ButtonStyle filledStyleOf(AppStyle s, Brightness b) =>
      themeOf(s, b).filledButtonTheme.style!;

  const emptyStates = <WidgetState>{};

  /// 普通按钮（FilledButton.tonal* / TextButton / OutlinedButton 共用）
  /// 的静态底色。
  Color plainBg(AppStyle style, Brightness b) =>
      filledStyleOf(style, b).backgroundColor!.resolve(emptyStates)!;

  /// 主按钮（FilledButton 非 tonal）底色 —— 走 ColorScheme.primary。
  Color primaryBg(AppStyle style, Brightness b) =>
      themeOf(style, b).colorScheme.primary;

  Color plainFg(AppStyle style, Brightness b) =>
      filledStyleOf(style, b).foregroundColor!.resolve(emptyStates)!;

  Color borderColorOf(AppStyle style, Brightness b) =>
      textStyleOf(style, b).side!.resolve(emptyStates)!.color;

  double fieldRadius(AppStyle style, Brightness b) =>
      ((textStyleOf(style, b).shape!.resolve(emptyStates) as RoundedRectangleBorder)
              .borderRadius as BorderRadius)
          .topLeft
          .x;

  /// 逐字段比较两组按钮样式（[ButtonStyle] 没有实现 ==）。
  void expectSameButtonStyle(ButtonStyle x, ButtonStyle y, String tag) {
    expect(
      x.backgroundColor!.resolve(emptyStates),
      y.backgroundColor!.resolve(emptyStates),
      reason: '$tag backgroundColor',
    );
    expect(
      x.foregroundColor!.resolve(emptyStates),
      y.foregroundColor!.resolve(emptyStates),
      reason: '$tag foregroundColor',
    );
    expect(
      x.overlayColor!.resolve(emptyStates),
      y.overlayColor!.resolve(emptyStates),
      reason: '$tag overlayColor',
    );
    expect(
      x.side!.resolve(emptyStates),
      y.side!.resolve(emptyStates),
      reason: '$tag side',
    );
    expect(
      x.shape!.resolve(emptyStates),
      y.shape!.resolve(emptyStates),
      reason: '$tag shape',
    );
    expect(
      x.elevation!.resolve(emptyStates),
      y.elevation!.resolve(emptyStates),
      reason: '$tag elevation',
    );
    expect(
      x.shadowColor!.resolve(emptyStates),
      y.shadowColor!.resolve(emptyStates),
      reason: '$tag shadowColor',
    );
  }

  group('三套浅色 · 普通与主按钮底色（判据 1 / 2）', () {
    test('普通按钮底：liquid 半透白压实 / frosted 白.9 / clay 暖白，两两不同', () {
      // liquid 浅色令牌面是 rgba(255,255,255,.7)（0xB3FFFFFF）；半透面压深字
      // 读不清，实现把它与 frosted 的实心面板底 lerp 0.18 压实（偏差如实记录）。
      // 期望值用与实现同一条 Color.lerp 路径算出，钉住的是 0.18 这个压实比例。
      final liquidPlainExpected = Color.lerp(
        StyleButton.liquidLight.color,
        AppColors.of(AppStyle.liquid, Brightness.light).surfaceSolid,
        0.18,
      )!;
      final liquidPlain =
          plainBg(kNegativeControlTarget, Brightness.light);
      expect(liquidPlain, liquidPlainExpected,
          reason: 'liquid 浅色普通按钮底 = 半透白(0xB3FFFFFF) 与 '
              '--panel-solid lerp 0.18 的压实值');
      expect(plainBg(AppStyle.frosted, Brightness.light),
          StyleButton.frostedLight.color,
          reason: 'frosted 浅色 = 白 .9（CSS :364-370 `background: rgba(255,255,255,.9)`）');
      expect(plainBg(AppStyle.clay, Brightness.light), StyleButton.clayLight.color,
          reason: 'clay 浅色 = #fffdfa 暖白（CSS :427-435）');

      expect(plainBg(AppStyle.liquid, Brightness.light),
          isNot(plainBg(AppStyle.frosted, Brightness.light)));
      expect(plainBg(AppStyle.frosted, Brightness.light),
          isNot(plainBg(AppStyle.clay, Brightness.light)));
      expect(plainBg(AppStyle.liquid, Brightness.light),
          isNot(plainBg(AppStyle.clay, Brightness.light)),
          reason: '三套浅色的普通按钮底必须两两不同 —— 这是「随风格变」的最低判据');
    });

    test('主按钮底：frosted=#1D9BF0 实色；liquid/clay=各自 --ac（渐变主色近似），两两不同', () {
      expect(primaryBg(AppStyle.frosted, Brightness.light),
          const Color(0xFF1D9BF0),
          reason: 'frosted 主按钮 = var(--ac) 实色（CSS :364-370）');
      expect(primaryBg(AppStyle.liquid, Brightness.light), const Color(0xFF5B6CFF),
          reason: 'liquid 主按钮取渐变主色段 --ac=#5B6CFF（渐变本体主题层发不了，见文件头）');
      expect(primaryBg(AppStyle.clay, Brightness.light), const Color(0xFFC2410C),
          reason: 'clay 主按钮取渐变主色段 --ac=#C2410C（同上）');

      expect(primaryBg(AppStyle.liquid, Brightness.light),
          isNot(primaryBg(AppStyle.frosted, Brightness.light)));
      expect(primaryBg(AppStyle.frosted, Brightness.light),
          isNot(primaryBg(AppStyle.clay, Brightness.light)));
      expect(primaryBg(AppStyle.liquid, Brightness.light),
          isNot(primaryBg(AppStyle.clay, Brightness.light)));
    });

    test('普通按钮字色 = 各套 --ink2；主按钮字色 = 白', () {
      expect(plainFg(AppStyle.liquid, Brightness.light), const Color(0xFF3D3D5C),
          reason: 'CSS --ink2 :244');
      expect(plainFg(AppStyle.frosted, Brightness.light), const Color(0xFF34343D),
          reason: 'CSS --ink2 :331');
      expect(plainFg(AppStyle.clay, Brightness.light), const Color(0xFF574E46),
          reason: 'CSS --ink2 :397');
      for (final s in AppStyle.values) {
        expect(
          themeOf(s, Brightness.light).colorScheme.onPrimary,
          Colors.white,
          reason: '$s 主按钮压字必须是白（--ac 底色上白字 5:1 一线）',
        );
      }
    });

    test('边 / 形 / 影：borderColor 随套、圆角走 field 档、elevation 0', () {
      expect(borderColorOf(AppStyle.liquid, Brightness.light),
          StyleButton.liquidLight.borderColor,
          reason: 'CSS :293-302 `border: 1px solid rgba(255,255,255,.85)`');
      expect(borderColorOf(AppStyle.frosted, Brightness.light),
          StyleButton.frostedLight.borderColor,
          reason: 'CSS :364-370 `border: 1px solid var(--ln)`');
      expect(borderColorOf(AppStyle.clay, Brightness.light),
          StyleButton.clayLight.borderColor,
          reason: 'CSS :427-435 `border: 1px solid var(--ln)`');

      expect(fieldRadius(AppStyle.liquid, Brightness.light), 9);
      expect(fieldRadius(AppStyle.frosted, Brightness.light), 8);
      expect(fieldRadius(AppStyle.clay, Brightness.light), 10);

      for (final s in AppStyle.values) {
        final style = textStyleOf(s, Brightness.light);
        expect(style.elevation!.resolve(emptyStates), 0,
            reason: '$s 按钮不走 Material 投影，立体感由面/边/影令牌给');
        expect(style.shadowColor!.resolve(emptyStates),
            s.buttonOf(Brightness.light).shadow.color,
            reason: '$s 普通按钮影色 = 该套 .btn 的 shadow 令牌');
        expect(
          filledStyleOf(s, Brightness.light).backgroundColor.toString(),
          textStyleOf(s, Brightness.light).backgroundColor.toString(),
          reason: '$s 的 tonal/TextButton/Outlined 底色属性必须一致 —— '
              '普通按钮观感不能散落成两套',
        );
      }
    });
  });

  group('深浅翻转（判据 3）', () {
    test('同一风格 light / dark 的按钮主题不同', () {
      // liquid：主按钮深色 --ac=#7C8DFF ≠ 浅色 #5B6CFF；面/边也各自一套。
      expect(primaryBg(AppStyle.liquid, Brightness.dark), const Color(0xFF7C8DFF),
          reason: 'CSS --ac :831');
      expect(primaryBg(AppStyle.liquid, Brightness.dark),
          isNot(primaryBg(AppStyle.liquid, Brightness.light)));
      expect(borderColorOf(AppStyle.liquid, Brightness.dark),
          StyleButton.liquidDark.borderColor,
          reason: 'CSS :849 边改 .12 白');
      expect(plainBg(AppStyle.liquid, Brightness.dark),
          isNot(plainBg(AppStyle.liquid, Brightness.light)),
          reason: 'liquid 深色面 = 白 .07，与浅色半透白压实值必然不同');

      // frosted：主按钮明暗同色（--ac 没变），翻转判据落在面与边上。
      expect(primaryBg(AppStyle.frosted, Brightness.dark),
          primaryBg(AppStyle.frosted, Brightness.light),
          reason: 'CSS :883 --ac 不随明暗变 —— frosted 的主按钮底翻转判据改钉边');
      expect(borderColorOf(AppStyle.frosted, Brightness.dark),
          StyleButton.frostedDark.borderColor,
          reason: 'CSS :898 `rgba(242,242,244,.12)`');
      expect(plainBg(AppStyle.frosted, Brightness.dark),
          isNot(plainBg(AppStyle.frosted, Brightness.light)),
          reason: 'frosted 深色面 = 白 .08，与浅色白 .9 不同');

      // clay：深色 --ac=#EA580C ≠ 浅色 #C2410C；面 = #2F2720。
      expect(primaryBg(AppStyle.clay, Brightness.dark), const Color(0xFFEA580C),
          reason: 'CSS --ac :931');
      expect(primaryBg(AppStyle.clay, Brightness.dark),
          isNot(primaryBg(AppStyle.clay, Brightness.light)));
      expect(StyleButton.clayDark.color, const Color(0xFF2F2720),
          reason: 'CSS :945 面色');
      expect(plainBg(AppStyle.clay, Brightness.dark),
          isNot(plainBg(AppStyle.clay, Brightness.light)));
    });
  });

  group('负控制（判据 4）', () {
    test('开关为真时「三套浅色·普通按钮底」必须变红', () {
      // 不真的跑红一次，「两两不同」可能只是恒真的空话。把
      // kNegativeControlTarget 改成 AppStyle.clay 再跑 —— 判据 1 的第一条
      // 断言期望 liquid 的压实值、拿到 clay 的 0xFFFFFDFA，必红。
      // 原始红输出记录在任务回报里（2026-10-13 已跑）。
      expect(
        const Color(0xFFFFFDFA), // clay 浅色暖白（= kNegativeControlTarget=clay 时的实取值）
        isNot(Color.lerp(
          StyleButton.liquidLight.color,
          AppColors.of(AppStyle.liquid, Brightness.light).surfaceSolid,
          0.18,
        )), // liquid 浅色压实半透白（= 判据 1 的期望值）
        reason: '两个值确实不同 —— 开关指向 clay 时判据 1 必红',
      );
    });
  });

  group('style 缺省 = frosted（判据 5）', () {
    test('不传 style 与显式传 frosted 的按钮主题逐字段相等（既有调用点零影响）', () {
      for (final b in Brightness.values) {
        final c = AppColors.of(AppStyle.frosted, b);
        final legacy = buildAppTheme(c, b); // 既有调用点的写法
        final explicit = buildAppTheme(c, b, style: AppStyle.frosted);
        expectSameButtonStyle(
            legacy.textButtonTheme.style!, explicit.textButtonTheme.style!, 'TextButton $b');
        expectSameButtonStyle(legacy.outlinedButtonTheme.style!,
            explicit.outlinedButtonTheme.style!, 'OutlinedButton $b');
        expectSameButtonStyle(legacy.filledButtonTheme.style!,
            explicit.filledButtonTheme.style!, 'FilledButton $b');
        // 主按钮走 ColorScheme：缺省时 primary/onPrimary/secondaryContainer
        // 也必须与显式 frosted 完全一致。
        for (final slot in const [
          'primary',
          'onPrimary',
          'secondaryContainer',
          'onSecondaryContainer',
        ]) {
          expect(
            legacy.colorScheme,
            explicit.colorScheme,
            reason: '$b 的 ColorScheme（含 $slot）缺省 = frosted',
          );
        }
      }
    });
  });
}
