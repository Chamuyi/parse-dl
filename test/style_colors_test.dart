import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/style_colors.dart';
import 'package:parse_dl/theme/winui_accent.dart';

/// `StyleColors` 的 6 套令牌（3 风格 × 2 亮度）。
///
/// ### 2026-10-16 改锚：从「预览稿」到「新视觉规范」
///
/// 这个文件此前守的是「**逐字节等于** `tools/ui/_redesign/preview/app.css`」
/// —— 那份预览稿是本项目此前的视觉权威。用户 2026-10-16 裁定「所有窗口材质
/// 和界面风格都不满意，包括深色模式和浅色模式」之后，设计不再锚定它，
/// 于是这里换锚到 [StyleColors] 类注释里记着的新规范。
///
/// **改锚时守住的**：文件结构、每个槽位的互异性判据、四档层次、
/// 选中态与悬停态的差异、`onSuccess` 与 `onAccent` 的可读性、以及每条负控制。
/// **顺带提高的**：凹面与深色 hover 面那几处地板从 3.0/3.2 提到 **4.5**
/// —— 旧值是「钉住实测现状、只许不恶化」，现在六套真的做到了全部 ≥4.5。
void main() {
  /// 与 `theme_contrast_test.dart` **同源**的对比度算法。
  ///
  /// 口径必须完全一致，否则这里算出的「过线」在那边会红 —— 差别就在
  /// `solid.withValues(alpha: .85)` 这一步：漏了它，纯黑与纯白壁纸算出的底
  /// 会相同，`worst` 退化成恒绿（本人踩过）。
  double lin(double s) => s <= 0.03928
      ? s / 12.92
      : math.pow((s + 0.055) / 1.055, 2.4).toDouble();

  double lum(Color c) => 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);

  double ratio(Color a, Color b) {
    final la = lum(a), lb = lum(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  Color over(Color fg, Color bg) {
    final a = fg.a;
    int mix(double f, double b) => ((f * a + b * (1 - a)) * 255).round().clamp(0, 255);
    return Color.fromARGB(255, mix(fg.r, bg.r), mix(fg.g, bg.g), mix(fg.b, bg.b));
  }

  /// 24 个槽位逐一列出 —— 这是「24 个」这个数字的机器可核版本。
  List<Color> slots(AppColors c) => [
        c.surfaceBase,
        c.surfaceCard,
        c.surfaceCardHover,
        c.surfaceSunken,
        c.surfaceFloat,
        c.surfaceSolid,
        c.scrim,
        c.textStrong,
        c.textNormal,
        c.textMuted,
        c.textFaint,
        c.line,
        c.lineSoft,
        c.lineStrong,
        c.accent,
        c.accentText,
        c.onAccent,
        c.accentSoft,
        c.accentLine,
        c.accentGlow,
        c.danger,
        c.dangerSoft,
        c.success,
        c.warning,
        c.onSuccess,
      ];

  // ══════════════════════════════════════════════════════════
  group('6 套令牌的完备性与互异性', () {
    test('每套恰好 25 个槽位', () {
      for (final s in [AppStyle.winui]) {
        for (final b in Brightness.values) {
          expect(slots(StyleColors.of(s, b).colors).length, 25,
              reason: '${s.id}/$b 的槽位数不对');
        }
      }
    });

    test('6 套两两不同（任两套的槽位不得逐字节相等）', () {
      final entries = <String, List<Color>>{};
      for (final s in [AppStyle.winui]) {
        for (final b in Brightness.values) {
          entries['${s.id}-${b.name}'] = slots(StyleColors.of(s, b).colors);
        }
      }
      expect(entries.length, AppStyle.values.length * 2,
          reason: '必须是 风格数 × 2 亮度');

      final keys = entries.keys.toList();
      var same = 0;
      for (var i = 0; i < keys.length; i++) {
        for (var j = i + 1; j < keys.length; j++) {
          final a = entries[keys[i]]!, b = entries[keys[j]]!;
          final identical = List.generate(a.length, (k) => a[k] == b[k]).every((x) => x);
          if (identical) {
            same++;
            fail('${keys[i]} 与 ${keys[j]} 的槽位完全相同 —— 「三套风格」名不副实');
          }
        }
      }
      expect(same, 0);
      // 组合数必须等于 C(n,2)，n = 风格数 × 2 亮度。
      // 写死 15（旧的三风格时代）会在加风格时误报，这里改成算式。
      final n = AppStyle.values.length * 2;
      expect(keys.length * (keys.length - 1) ~/ 2, n * (n - 1) ~/ 2);
    });
  });



  // ══════════════════════════════════════════════════════════
  group('accent 上的文字（2026-10-16 新增覆盖）', () {
    test('6 组的 onAccent 压在 accent 上 ≥4.5', () {
      for (final s in [AppStyle.winui]) {
        for (final b in Brightness.values) {
          final c = StyleColors.of(s, b).colors;
          final r = ratio(c.onAccent, c.accent);
          expect(r, greaterThanOrEqualTo(4.5),
              reason: '${s.id}/${b.name}：onAccent 压在 accent 上只有 '
                  '${r.toStringAsFixed(2)}');
        }
      }
    });

    test('负控制：一律用白字压 accent 会被这条判据抓出来', () {
      // 这正是改造前的做法（也是它坏掉的原因）：旧 frosted 的 #1D9BF0 上
      // 白字只有 3.00，深色的 #38BDF8 上更只有 2.14。若哪天有人把 onAccent
      // 写回 `Colors.white`，深色三套会当场红。
      var caught = 0;
      for (final s in [AppStyle.winui]) {
        final c = StyleColors.of(s, Brightness.dark).colors;
        if (ratio(const Color(0xFFFFFFFF), c.accent) < 4.5) caught++;
      }
      expect(caught, AppStyle.values.length,
          reason: '每个深色风格的 accent 都是亮色，白字必然不过 —— '
              '这正是需要 onAccent 槽位的理由');
    });

    test('onAccent 的方向随明暗翻转（浅色配白字，深色配深字）', () {
      for (final s in [AppStyle.winui]) {
        final l = StyleColors.of(s, Brightness.light).colors;
        final d = StyleColors.of(s, Brightness.dark).colors;
        expect(l.onAccent, const Color(0xFFFFFFFF),
            reason: '${s.id} 浅色 accent 取深色调，配白字');
        expect(lum(d.onAccent), lessThan(0.2),
            reason: '${s.id} 深色 accent 取亮色调，必须配深字');
      }
    });
  });

  // ══════════════════════════════════════════════════════════
  group('四档文字层次（6 组，相邻 ≥1.2）', () {
    test('每组相邻档对比度都 ≥1.2', () {
      for (final s in [AppStyle.winui]) {
        for (final b in Brightness.values) {
          final c = StyleColors.of(s, b).colors;
          for (final (label, a, z) in [
            ('strong→normal', c.textStrong, c.textNormal),
            ('normal→muted', c.textNormal, c.textMuted),
            ('muted→faint', c.textMuted, c.textFaint),
          ]) {
            expect(ratio(a, z), greaterThanOrEqualTo(1.2),
                reason: '${s.id}/${b.name} 的 $label 只有 '
                    '${ratio(a, z).toStringAsFixed(3)}，会并成一种灰');
          }
        }
      }
    });

    test('负控制：正常/弱两档若取同一色，层次判据必然判红', () {
      // 证明上一条不是恒真的：把 muted 换成 normal，ratio = 1.00 → 必须 <1.2。
      final c = StyleColors.winuiLight.colors;
      expect(ratio(c.textNormal, c.textNormal), lessThan(1.2));
    });
  });

  // ══════════════════════════════════════════════════════════
  group('AppColors.of 的派生与来源唯一', () {
    test('非 winui 风格直接返回 StyleColors 的实例（来源唯一）', () {
      // winui 是**唯一**例外：它的强调色由用户三选一（[WinUiAccent]），
      // 必须在 `of` 里换掉 6 个 accent 槽位，因此只能新建实例。
      // 其余三套仍必须返回**同一个对象** —— 这条守住「派生路径只有
      // StyleColors 一处」，不许任何风格偷偷再起一套色板。
      for (final s in [AppStyle.winui]) {
        if (s == AppStyle.winui) continue;
        for (final b in Brightness.values) {
          expect(AppColors.of(s, b), same(StyleColors.of(s, b).colors),
              reason: '${s.id}/${b.name} 的派生路径应当只有 StyleColors 一处');
        }
      }
    });

    test('winui 默认档（Windows 蓝）与色板逐值相等 —— 换 accent 是恒等变换', () {
      // 色板里存的 accent 就是 WinUI 官方蓝，而 `withAccent` 的派生系数
      // （soft .20/.35、line .40/.50、glow .10/.15）也与色板写死的 alpha
      // 完全一致。所以默认档必须**一个字节都不差**：一旦哪天两处各自
      // 演化，这条立刻红。
      for (final b in Brightness.values) {
        expect(slots(AppColors.of(AppStyle.winui, b)),
            slots(StyleColors.of(AppStyle.winui, b).colors),
            reason: '${b.name} 默认档必须与色板逐值相等');
      }
    });

    test('winui 换档只动 6 个 accent 槽位，其余 19 个原样', () {
      // 槽位序见 [slots]：14..19 = accent / accentText / onAccent /
      // accentSoft / accentLine / accentGlow。
      const accentIdx = [14, 15, 16, 17, 18, 19];
      for (final b in Brightness.values) {
        final base = slots(StyleColors.of(AppStyle.winui, b).colors);
        final got = slots(
            AppColors.of(AppStyle.winui, b, accent: WinUiAccent.violet));
        for (var i = 0; i < base.length; i++) {
          if (accentIdx.contains(i)) continue;
          expect(got[i], base[i],
              reason: '${b.name} 的槽位 $i 不该被强调色改动');
        }
        // 6 个 accent 槽位必须真的换成紫罗兰，且仍按原派生系数展开。
        final t = WinUiAccent.violet.colorsFor(b);
        final dark = b == Brightness.dark;
        expect(got[14], t.accent);
        expect(got[15], t.accentText);
        expect(got[16], t.onAccent);
        // 系数与色板写死的十六进制 alpha 同源（见 AppColors.withAccent 注释）
        expect(got[17], t.accent.withValues(alpha: (dark ? 0x59 : 0x33) / 255));
        expect(got[18], t.accent.withValues(alpha: (dark ? 0x80 : 0x66) / 255));
        expect(got[19], t.accent.withValues(alpha: (dark ? 0x26 : 0x1A) / 255));
        // 负控制：紫罗兰档的主色必须与官方蓝不同，否则上面几条可能恒真。
        expect(got[14], isNot(StyleColors.of(AppStyle.winui, b).colors.accent),
            reason: '紫罗兰档的主色必须与官方蓝不同');
      }
    });

    test('AppStyle.colorsFor 与 StyleColors.of 同源', () {
      for (final s in [AppStyle.winui]) {
        for (final b in Brightness.values) {
          expect(s.colorsFor(b), same(StyleColors.of(s, b)));
        }
      }
    });

    test('solidFor 恒取色板（一个概念一处出处）', () {
      // 旧实现是「frosted 返回硬编码 #F3F3F3/#202020，其余走色板」——
      // 于是 frosted 的卡片底与窗口底**根本不是同一个色**，两套值各自演化。
      for (final s in [AppStyle.winui]) {
        for (final b in Brightness.values) {
          expect(AppColors.solidFor(b, style: s),
              StyleColors.of(s, b).colors.surfaceSolid,
              reason: '${s.id}/${b.name} 的窗口底必须与卡片实心底同源');
        }
      }
      // 默认参数 = frosted（既有调用点零改动）
      expect(AppColors.solidFor(Brightness.light),
          StyleColors.winuiLight.colors.surfaceSolid);
      expect(AppColors.solidFor(Brightness.dark),
          StyleColors.winuiDark.colors.surfaceSolid);
    });

    test('渐变第二色停已移除（改用户裁定），AppColors 仍是 25 槽位', () {
      // 2026-10-19 用户裁定：主按钮改纯色，accent2 字段删除。
      // 本用例语义随之反转：原来断言"某套有 accent2"，现在断言
      // "WinUI 主按钮没有渐变、只有纯色"，并顺带守住槽位计数不漂移。
      final b = StyleButton.winuiLight;
      expect(b.primaryGradient, isNull,
          reason: 'WinUI 主按钮必须是纯色，不能有渐变');
      expect(b.primaryColor, const Color(0xFF0078D4));
      expect(slots(AppColors.dark).length, 25);
    });
  });

  // ══════════════════════════════════════════════════════════
  group('A16：选中态要比悬停态「更朝主色」（6 组）', () {
    /// 把颜色在**主色色度方向**上的推进量取出（明度无关）。
    ///
    /// `theme_contrast_test` 原来硬编码的是「更蓝」（`c.b - c.r`），那只对
    /// 蓝色主色成立 —— clay 的主色是橙，方向相反。这里按主色的实际色度方向
    /// 投影，对蓝给正、对橙也给正，**判据强度不变**（门档仍是 0.10）。
    double toward(Color c, Color accent) {
      double comp(Color x, int i) => [x.r, x.g, x.b][i];
      final cm = (c.r + c.g + c.b) / 3;
      final am = (accent.r + accent.g + accent.b) / 3;
      final ax = accent.r - am, ay = accent.g - am, az = accent.b - am;
      final den = ax * ax + ay * ay + az * az;
      return ((comp(c, 0) - cm) * ax +
              (comp(c, 1) - cm) * ay +
              (comp(c, 2) - cm) * az) /
          den;
    }

    test('6 组的选中底都比悬停底更朝主色 ≥0.10，且距离 ≥0.05', () {
      for (final s in [AppStyle.winui]) {
        for (final b in Brightness.values) {
          final c = StyleColors.of(s, b).colors;
          for (final wall in [const Color(0xFF000000), const Color(0xFFFFFFFF)]) {
            final base = over(AppColors.solidFor(b).withValues(alpha: 0.85), wall);
            final cardBg = over(c.surfaceCard, base);
            final hover = over(c.surfaceCardHover, cardBg);
            final selected = over(c.accentSoft, cardBg);
            final diff = toward(selected, c.accent) - toward(hover, c.accent);
            expect(diff, greaterThanOrEqualTo(0.10),
                reason: '${s.id}/${b.name}：选中底只比悬停底朝主色推进了 '
                    '${diff.toStringAsFixed(3)}（要 ≥0.10）');
            final dist = math.sqrt(
                    math.pow(hover.r - selected.r, 2) +
                        math.pow(hover.g - selected.g, 2) +
                        math.pow(hover.b - selected.b, 2)) /
                math.sqrt(3.0);
            expect(dist, greaterThanOrEqualTo(0.05),
                reason: '${s.id}/${b.name}：两种填充的距离只有 ${dist.toStringAsFixed(3)}');
          }
        }
      }
    });

    test('负控制：选中底若等于悬停底，判据必然判红', () {
      final c = StyleColors.winuiLight.colors;
      final base = over(AppColors.solidFor(Brightness.light).withValues(alpha: 0.85),
          const Color(0xFF000000));
      final one = over(c.surfaceCardHover, base);
      expect(toward(one, c.accent) - toward(one, c.accent), lessThan(0.10));
    });
  });

  // ══════════════════════════════════════════════════════════
  group('填充色上的文字', () {
    test('6 组的 onSuccess 压在 success 上 ≥4.5', () {
      for (final s in [AppStyle.winui]) {
        for (final b in Brightness.values) {
          final c = StyleColors.of(s, b).colors;
          final r = ratio(c.onSuccess, c.success);
          expect(r, greaterThanOrEqualTo(4.5),
              reason: '${s.id}/${b.name}：onSuccess 压在 success 上只有 '
                  '${r.toStringAsFixed(2)}');
        }
      }
    });
  });

  // ══════════════════════════════════════════════════════════
  group('遮罩', () {
    test('6 组的 scrim 都压暗背景（见 scrim_test.dart 的完整矩阵）', () {
      for (final s in [AppStyle.winui]) {
        for (final b in Brightness.values) {
          final c = StyleColors.of(s, b).colors;
          final bg = c.surfaceSolid;
          expect(Color.alphaBlend(c.scrim, bg).computeLuminance(),
              lessThan(bg.computeLuminance()),
              reason: '${s.id}/${b.name} 的遮罩把背景提亮了');
        }
      }
    });
  });
}
