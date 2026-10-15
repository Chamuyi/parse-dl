import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/style_colors.dart';

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

  /// 该套色板下，文字压在某面（card / hover / sunken / float）上的**最坏**对比度。
  double worst(AppStyle style, Brightness b, Color ink, Color Function(AppColors) face) {
    final c = AppColors.of(style, b);
    // **必须传风格**：`solidFor` 自 2026-10-16 起按风格取底色，不传就退回
    // frosted —— 另外两套的底会被算错，判据与生产脱节。
    final solid = AppColors.solidFor(b, style: style).withValues(alpha: 0.85);
    var min = double.infinity;
    for (final wall in [const Color(0xFF000000), const Color(0xFFFFFFFF)]) {
      final r = ratio(ink, over(face(c), over(solid, wall)));
      if (r < min) min = r;
    }
    return min;
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
      for (final s in AppStyle.values) {
        for (final b in Brightness.values) {
          expect(slots(StyleColors.of(s, b).colors).length, 25,
              reason: '${s.id}/$b 的槽位数不对');
        }
      }
    });

    test('6 套两两不同（任两套的槽位不得逐字节相等）', () {
      final entries = <String, List<Color>>{};
      for (final s in AppStyle.values) {
        for (final b in Brightness.values) {
          entries['${s.id}-${b.name}'] = slots(StyleColors.of(s, b).colors);
        }
      }
      expect(entries.length, 6, reason: '必须是 3 风格 × 2 亮度');

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
      // 6 套 = C(6,2) = 15 组两两比较
      expect(keys.length * (keys.length - 1) ~/ 2, 15);
    });

    test('负控制：相邻两套必须查得出来不同（证明上面的比较真的在比）', () {
      // 取 liquid-dark 与 frosted-dark —— 两者都是深色、都偏冷，只差色相。
      final a = slots(StyleColors.liquidDark.colors);
      final b = slots(StyleColors.frostedDark.colors);
      final diffCount = List.generate(a.length, (k) => a[k] != b[k]).where((x) => x).length;
      expect(diffCount, greaterThan(0),
          reason: '两套完全一样，上面的互异性判据就是恒真的');
    });
  });

  // ══════════════════════════════════════════════════════════
  group('浅色三套 = 新视觉规范（2026-10-16）', () {
    test('liquid-light：中性色带冷紫色相，accent 配白字', () {
      final c = StyleColors.liquidLight.colors;
      expect(c.surfaceSolid, const Color(0xFFF4F2FF));
      expect(c.textStrong, const Color(0xFF18181B));
      expect(c.textNormal, const Color(0xFF3F3F46));
      expect(c.accent, const Color(0xFF4F46E5));
      expect(StyleColors.liquidLight.accent2, const Color(0xFF7C3AED));
      // 冷紫：蓝通道 ≥ 绿通道 ≥ 红通道（不是纯灰）
      expect(c.surfaceSolid.b, greaterThan(c.surfaceSolid.r),
          reason: 'liquid 的中性色必须带色相，纯灰就是"没设计过"的样子');
    });

    test('frosted-light：中性色是冷蓝灰，accent = Windows Fluent 标准强调色', () {
      final c = StyleColors.frostedLight.colors;
      expect(c.surfaceSolid, const Color(0xFFF8FAFC));
      expect(c.textStrong, const Color(0xFF0F172A));
      expect(c.textNormal, const Color(0xFF334155));
      // #0F6CBD 是 Windows 11 Fluent 自己的强调色；选它是为了原生观感，
      // 不是随手挑的蓝（旧值 #1D9BF0 上白字只有 3.00，主按钮一直不可读）。
      expect(c.accent, const Color(0xFF0F6CBD));
      expect(c.surfaceSolid.b, greaterThan(c.surfaceSolid.r));
    });

    test('clay-light：中性色是暖石，accent 是陶土橙', () {
      final c = StyleColors.clayLight.colors;
      expect(c.surfaceSolid, const Color(0xFFFBF7EE));
      expect(c.textStrong, const Color(0xFF1C1917));
      expect(c.accent, const Color(0xFFC2410C));
      expect(StyleColors.clayLight.accent2, const Color(0xFFEA580C));
      // 暖：红通道 ≥ 绿通道 ≥ 蓝通道
      expect(c.surfaceSolid.r, greaterThan(c.surfaceSolid.b),
          reason: 'clay 的中性色应当偏暖');
    });

    test('三套中性色的色相方向两两不同（这是"三套风格"的关键区分）', () {
      final solids = {
        for (final s in AppStyle.values)
          s.id: StyleColors.of(s, Brightness.light).colors.surfaceSolid
      };
      // liquid 紫（蓝-红差最大）、frosted 蓝灰（蓝-红差小）、clay 暖（蓝-红为负）
      final lq = solids['liquid']!.b - solids['liquid']!.r;
      final fr = solids['frosted']!.b - solids['frosted']!.r;
      final cl = solids['clay']!.b - solids['clay']!.r;
      expect(lq, greaterThan(fr), reason: 'liquid 应当比 frosted 更偏紫');
      expect(cl, lessThan(0), reason: 'clay 应当偏暖（蓝 < 红）');
      expect(solids.values.map((c) => c.toARGB32()).toSet().length, 3,
          reason: '三套底色两两不同');
    });

    test('线色三档同色相，且 soft < line < strong', () {
      for (final s in AppStyle.values) {
        final c = StyleColors.of(s, Brightness.light).colors;
        expect((c.lineSoft.r, c.lineSoft.g, c.lineSoft.b), (c.line.r, c.line.g, c.line.b),
            reason: '${s.id} 的三档线色必须同色相（只有 alpha 不同）');
        expect((c.lineStrong.r, c.lineStrong.g, c.lineStrong.b),
            (c.line.r, c.line.g, c.line.b));
        expect(c.lineSoft.a, lessThan(c.line.a));
        expect(c.lineStrong.a, greaterThan(c.line.a));
      }
    });

    test('浅色三套的四档文字在最不利的面上仍 ≥4.5', () {
      for (final s in AppStyle.values) {
        final c = StyleColors.of(s, Brightness.light).colors;
        for (final (name, ink, face) in <(String, Color, Color Function(AppColors))>[
          ('card.faint', c.textFaint, (x) => x.surfaceCard),
          ('float.faint', c.textFaint, (x) => x.surfaceFloat),
          ('sunken.faint', c.textFaint, (x) => x.surfaceSunken),
          ('sunken.muted', c.textMuted, (x) => x.surfaceSunken),
          ('sunken.danger', c.danger, (x) => x.surfaceSunken),
          ('sunken.success', c.success, (x) => x.surfaceSunken),
          ('sunken.warning', c.warning, (x) => x.surfaceSunken),
          ('sunken.accentText', c.accentText, (x) => x.surfaceSunken),
        ]) {
          // 旧地板：sunken.faint 3.2 / sunken.danger 2.6 ……
          // 现在一律 4.5。这是本次重做在可读性上的实质提升，不是放宽。
          expect(worst(s, Brightness.light, ink, face), greaterThanOrEqualTo(4.5),
              reason: '${s.id} 浅色 $name 破 4.5 地板');
        }
      }
    });
  });

  // ══════════════════════════════════════════════════════════
  group('深色三套 = 新视觉规范（2026-10-16）', () {
    test('liquid-dark：冷紫黑底 + 亮紫 accent 配深字', () {
      final c = StyleColors.liquidDark.colors;
      expect(c.surfaceSolid, const Color(0xFF141420));
      expect(c.textStrong, Color(0xFFFFFFFF));
      expect(c.textFaint, const Color(0xFF9090AE));
      expect(c.accent, const Color(0xFF818CF8));
      expect(c.onAccent, const Color(0xFF12122B));
      expect(StyleColors.liquidDark.accent2, const Color(0xFFA78BFA));
    });

    test('frosted-dark：冷蓝黑底 + 亮蓝 accent 配深字', () {
      final c = StyleColors.frostedDark.colors;
      expect(c.surfaceSolid, const Color(0xFF14171E));
      expect(c.textNormal, const Color(0xFFDFE6EE));
      expect(c.textFaint, const Color(0xFF93A3B8));
      expect(c.accent, const Color(0xFF38BDF8));
      expect(c.onAccent, const Color(0xFF0B1220));
    });

    test('clay-dark：暖黑底 + 亮橙 accent 配深字', () {
      final c = StyleColors.clayDark.colors;
      expect(c.surfaceSolid, const Color(0xFF15120E));
      expect(c.textFaint, const Color(0xFFA3978B));
      expect(c.accent, const Color(0xFFFB923C));
      expect(c.onAccent, const Color(0xFF1C130B));
      expect(StyleColors.clayDark.accent2, const Color(0xFFFDBA74));
    });

    test('深色面料的不透明度足够高（否则壁纸会拖垮对比度）', () {
      for (final s in AppStyle.values) {
        final c = StyleColors.of(s, Brightness.dark).colors;
        // 旧卡片是**白 6.5%**（≈几乎全透），纯白壁纸下卡片底能到 #4C4C4C；
        // 现在一律 ≥88% 不透明，底层漂移被压掉一个数量级。
        expect(c.surfaceCard.a, greaterThanOrEqualTo(0.88),
            reason: '${s.id} 深色卡片太透，对比度会随壁纸漂移');
        expect(c.surfaceCardHover.a, greaterThanOrEqualTo(0.88));
        expect(c.surfaceSunken.a, greaterThanOrEqualTo(0.88));
        // 线色三档仍是 12% / 7% / 18%（这条与旧规范一致，保留）
        expect(c.line.a, closeTo(0x1F / 255, 0.002), reason: '${s.id} line 12%');
        expect(c.lineSoft.a, closeTo(0x12 / 255, 0.002), reason: '${s.id} lineSoft 7%');
        expect(c.lineStrong.a, closeTo(0x2E / 255, 0.002), reason: '${s.id} lineStrong 18%');
      }
    });

    test('深色三套的四档文字在最不利的面上仍 ≥4.5', () {
      for (final s in AppStyle.values) {
        final c = StyleColors.of(s, Brightness.dark).colors;
        for (final (name, ink, face) in <(String, Color, Color Function(AppColors))>[
          ('hover.faint', c.textFaint, (x) => x.surfaceCardHover),
          ('float.faint', c.textFaint, (x) => x.surfaceFloat),
          ('card.faint', c.textFaint, (x) => x.surfaceCard),
          ('card.danger', c.danger, (x) => x.surfaceCard),
          ('card.accentText', c.accentText, (x) => x.surfaceCard),
          ('float.accentText', c.accentText, (x) => x.surfaceFloat),
        ]) {
          // 旧地板：hover.faint 3.0 / card.danger 3.0 / card.accentText 4.0 ……
          expect(worst(s, Brightness.dark, ink, face), greaterThanOrEqualTo(4.5),
              reason: '${s.id} 深色 $name 破 4.5 地板');
        }
      }
    });

    test('深色三套的 surfaceSolid 色相两两不同（不是中性灰）', () {
      final liq = StyleColors.liquidDark.colors.surfaceSolid;
      final cla = StyleColors.clayDark.colors.surfaceSolid;
      expect(liq.b, greaterThan(liq.r), reason: 'liquid 深底应当偏蓝紫');
      expect(cla.r, greaterThan(cla.b), reason: 'clay 深底应当偏暖');
      final solids = {
        for (final s in AppStyle.values)
          StyleColors.of(s, Brightness.dark).colors.surfaceSolid
      };
      expect(solids.length, 3);
    });
  });

  // ══════════════════════════════════════════════════════════
  group('accent 上的文字（2026-10-16 新增覆盖）', () {
    test('6 组的 onAccent 压在 accent 上 ≥4.5', () {
      for (final s in AppStyle.values) {
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
      for (final s in AppStyle.values) {
        final c = StyleColors.of(s, Brightness.dark).colors;
        if (ratio(const Color(0xFFFFFFFF), c.accent) < 4.5) caught++;
      }
      expect(caught, 3,
          reason: '三个深色风格的 accent 都是亮色，白字必然不过 —— '
              '这正是需要 onAccent 槽位的理由');
    });

    test('onAccent 的方向随明暗翻转（浅色配白字，深色配深字）', () {
      for (final s in AppStyle.values) {
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
      for (final s in AppStyle.values) {
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
      final c = StyleColors.liquidLight.colors;
      expect(ratio(c.textNormal, c.textNormal), lessThan(1.2));
    });
  });

  // ══════════════════════════════════════════════════════════
  group('AppColors.of 的派生与来源唯一', () {
    test('of(frosted, ·) 与 StyleColors 同源', () {
      expect(identical(AppColors.of(AppStyle.frosted, Brightness.light),
              StyleColors.frostedLight.colors),
          isTrue);
      expect(identical(AppColors.of(AppStyle.frosted, Brightness.dark),
              StyleColors.frostedDark.colors),
          isTrue);
    });

    test('6 组都有值，且都来自 StyleColors 一处', () {
      for (final s in AppStyle.values) {
        for (final b in Brightness.values) {
          expect(AppColors.of(s, b), same(StyleColors.of(s, b).colors),
              reason: '${s.id}/${b.name} 的派生路径应当只有 StyleColors 一处');
        }
      }
    });

    test('AppStyle.colorsFor 与 StyleColors.of 同源', () {
      for (final s in AppStyle.values) {
        for (final b in Brightness.values) {
          expect(s.colorsFor(b), same(StyleColors.of(s, b)));
        }
      }
    });

    test('solidFor 恒取色板（一个概念一处出处）', () {
      // 旧实现是「frosted 返回硬编码 #F3F3F3/#202020，其余走色板」——
      // 于是 frosted 的卡片底与窗口底**根本不是同一个色**，两套值各自演化。
      for (final s in AppStyle.values) {
        for (final b in Brightness.values) {
          expect(AppColors.solidFor(b, style: s),
              StyleColors.of(s, b).colors.surfaceSolid,
              reason: '${s.id}/${b.name} 的窗口底必须与卡片实心底同源');
        }
      }
      // 默认参数 = frosted（既有调用点零改动）
      expect(AppColors.solidFor(Brightness.light),
          StyleColors.frostedLight.colors.surfaceSolid);
      expect(AppColors.solidFor(Brightness.dark),
          StyleColors.frostedDark.colors.surfaceSolid);
    });

    test('accent2 只在 StyleColors 上，AppColors 仍是 25 槽位', () {
      expect(StyleColors.liquidLight.accent2, const Color(0xFF7C3AED));
      expect(StyleColors.clayDark.accent2, const Color(0xFFFDBA74));
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
      for (final s in AppStyle.values) {
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
      final c = StyleColors.clayLight.colors;
      final base = over(AppColors.solidFor(Brightness.light).withValues(alpha: 0.85),
          const Color(0xFF000000));
      final one = over(c.surfaceCardHover, base);
      expect(toward(one, c.accent) - toward(one, c.accent), lessThan(0.10));
    });
  });

  // ══════════════════════════════════════════════════════════
  group('填充色上的文字', () {
    test('6 组的 onSuccess 压在 success 上 ≥4.5', () {
      for (final s in AppStyle.values) {
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
      for (final s in AppStyle.values) {
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
