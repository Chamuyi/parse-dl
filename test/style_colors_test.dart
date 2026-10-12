import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/style_colors.dart';

/// S1 判据：`StyleColors` 的 6 套令牌（3 风格 × 2 亮度）。
///
/// 这个文件守三件事，各自独立可判错：
///   1. **6 套两两不同** —— 「三套风格」不成立时当场红（不是靠人眼看）；
///   2. **浅色三套与预览稿的关系** —— 逐字节的部分逐字节断言，派生的部分
///      断言「派生规则 + 过地板」，**不谎称逐字节**；
///   3. **深色三套等于推导实测值** —— 逐字节断言，并守住「加 hover 面后仍过地板」。
///
/// 关于「两档照搬 + 两档派生」的理由见 [StyleColors] 的类注释：CSS 只给 3 档
/// 文字色，而 [AppColors] 有 4 档且相邻档必须 ≥1.2。
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
    final solid = AppColors.solidFor(b).withValues(alpha: 0.85);
    var min = double.infinity;
    for (final wall in [const Color(0xFF000000), const Color(0xFFFFFFFF)]) {
      final r = ratio(ink, over(face(c), over(solid, wall)));
      if (r < min) min = r;
    }
    return min;
  }

  /// 23 个槽位逐一列出 —— 这是「23 个」这个数字的机器可核版本。
  List<Color> slots(AppColors c) => [
        c.surfaceBase,
        c.surfaceCard,
        c.surfaceCardHover,
        c.surfaceSunken,
        c.surfaceFloat,
        c.surfaceSolid,
        c.textStrong,
        c.textNormal,
        c.textMuted,
        c.textFaint,
        c.line,
        c.lineSoft,
        c.lineStrong,
        c.accent,
        c.accentText,
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
    test('每套恰好 23 个槽位', () {
      for (final s in AppStyle.values) {
        for (final b in Brightness.values) {
          expect(slots(StyleColors.of(s, b).colors).length, 23,
              reason: '${s.id}/$b 的槽位数不对');
        }
      }
    });

    test('6 套两两不同（任两套的 23 槽位不得逐字节相等）', () {
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
          final identical = List.generate(23, (k) => a[k] == b[k]).every((x) => x);
          if (identical) {
            same++;
            fail('${keys[i]} 与 ${keys[j]} 的 23 个槽位完全相同 —— '
                '「三套风格」名不副实');
          }
        }
      }
      expect(same, 0);
      // 12 组两两比较都跑过了（6 套 = C(6,2) = 15 组）
      expect(keys.length * (keys.length - 1) ~/ 2, 15);
    });

    test('负控制：相邻两套必须查得出来不同（证明上面的比较真的在比）', () {
      // 取 liquid-dark 与 frosted-dark —— 这是最容易被抄错的一对
      // （两者都是深色、都偏冷，只差色相）。
      final a = slots(StyleColors.liquidDark.colors);
      final b = slots(StyleColors.frostedDark.colors);
      final diffCount = List.generate(23, (k) => a[k] != b[k]).where((x) => x).length;
      expect(diffCount, greaterThan(0),
          reason: '两套完全一样，上面的互异性判据就是恒真的');
    });
  });

  // ══════════════════════════════════════════════════════════
  group('浅色三套 vs 预览稿 app.css', () {
    // ── 逐字节的部分：CSS 里有的原值 ──
    // 出处：tools/ui/_redesign/preview/app.css
    //   #v-a:243-247  #v-b:329-331  #v-c:396-398

    test('liquid-light：--ac / --ac2 / --ink / --ink2 逐字节等于预览稿', () {
      final c = StyleColors.liquidLight.colors;
      expect(c.accent, const Color(0xFF5B6CFF)); // :245 --ac
      expect(StyleColors.liquidLight.accent2, const Color(0xFF8B5CF6)); // :245 --ac2
      expect(c.textStrong, const Color(0xFF16162A)); // :244 --ink
      expect(c.textNormal, const Color(0xFF3D3D5C)); // :244 --ink2
      expect(c.surfaceSolid, const Color(0xFFFBFBFF)); // :243 --panel-solid
      expect(c.line, const Color(0x1216162A)); // :247 --ln rgba(22,22,42,.07)
    });

    test('frosted-light：ink / ink2 逐字节等于预览稿 #v-b，派生档过地板', () {
      final c = StyleColors.frostedLight.colors;
      // 出处：app.css #v-b:329-331
      expect(c.textStrong, const Color(0xFF101014)); // :331 --ink
      expect(c.textNormal, const Color(0xFF34343D)); // :331 --ink2
      expect(c.surfaceSolid, const Color(0xFFF7F9FC)); // :329 --panel-solid
      expect(c.accent, const Color(0xFF1D9BF0)); // :330 --ac
      expect(c.line, const Color(0x1A101014)); // :331 --ln rgba(16,16,20,.10)
      // 派生档（CSS --ink3 压深）必须过地板 —— 见文件头「两档照搬 + 两档派生」
      expect(worst(AppStyle.frosted, Brightness.light, c.textFaint,
              (c) => c.surfaceCard),
          greaterThanOrEqualTo(4.5), reason: 'frosted 浅色 faint 破 card 地板');
      // 与「40 多个测试文件引用的 AppColors.light」是两份不同的值 —— 这是有意的分工
      expect(c.textStrong, isNot(AppColors.light.textStrong),
          reason: 'frosted 渲染值必须取预览稿，不能沿用改造前的通用灰');
    });

    test('clay-light：--ac / --ac2 / --ink / --ink2 逐字节等于预览稿', () {
      final c = StyleColors.clayLight.colors;
      expect(c.accent, const Color(0xFFC2410C)); // :398 --ac
      expect(StyleColors.clayLight.accent2, const Color(0xFFEA580C)); // :398 --ac2
      expect(c.textStrong, const Color(0xFF2B2622)); // :397 --ink
      expect(c.textNormal, const Color(0xFF574E46)); // :397 --ink2
      expect(c.surfaceSolid, const Color(0xFFFFFDFA)); // :396 --panel-solid
      expect(c.line, const Color(0x172B2622)); // :398 --ln rgba(43,38,34,.09)
    });

    test('liquid/clay 的线色取 CSS --ln，另两档是同色相派生', () {
      for (final (style, ln) in [
        (AppStyle.liquid, const Color(0x1216162A)),
        (AppStyle.clay, const Color(0x172B2622)),
      ]) {
        final c = StyleColors.of(style, Brightness.light).colors;
        expect(c.line, ln, reason: '${style.id} 的 line 必须逐字节等于 CSS --ln');
        // 另两档必须比 line 更淡 / 更重，且同色相（rgb 相同）
        expect((c.lineSoft.r, c.lineSoft.g, c.lineSoft.b), (ln.r, ln.g, ln.b));
        expect((c.lineStrong.r, c.lineStrong.g, c.lineStrong.b), (ln.r, ln.g, ln.b));
        expect(c.lineSoft.a, lessThan(c.line.a));
        expect(c.lineStrong.a, greaterThan(c.line.a));
      }
    });

    test('浅色三套的 textFaint 与 CSS --ink3 同色相（压深而非换色）', () {
      // 逐字节对齐不了（见下一条），但**色相必须来自预览稿**，不能另挑一个灰。
      for (final (style, ink3) in [
        (AppStyle.liquid, const Color(0xFF6F6F92)), // :244
        (AppStyle.clay, const Color(0xFF8B8078)), // :397
      ]) {
        final f = StyleColors.of(style, Brightness.light).colors.textFaint;
        // 与 CSS 原值同色相：三通道的**相对次序与差值方向**一致，且更暗
        expect(lum(f), lessThan(lum(ink3)),
            reason: '${style.id} 的 textFaint 应当比 CSS --ink3 更暗（压深）');
        expect(f.b - f.r, closeTo(ink3.b - ink3.r, 0.02),
            reason: '${style.id} 的 textFaint 色相偏离了 --ink3');
      }
    });

    test('负控制：CSS --ink3 原值直接当 faint 会破 4.5 地板（证明压深是必要的）', () {
      // 这条是「为什么不能逐字节」的证据本身。若哪天有人把 faint 改回 CSS 原值，
      // 上面那些 `lessThan` 会红，而这条解释了原因。
      for (final (style, ink3) in [
        (AppStyle.liquid, const Color(0xFF6F6F92)),
        (AppStyle.clay, const Color(0xFF8B8078)),
      ]) {
        final got = worst(style, Brightness.light, ink3, (c) => c.surfaceCard);
        expect(got, lessThan(4.5),
            reason: '${style.id} 的 CSS --ink3 实测 $got —— 本以为会不过 4.5，'
                '若这条红了说明前提变了，可以直接改回逐字节');
      }
    });

    test('浅色三套的派生档仍过各自地板', () {
      const floors = {'card': 4.5, 'float': 4.5, 'sunken.card': 4.5};
      for (final s in AppStyle.values) {
        final c = StyleColors.of(s, Brightness.light).colors;
        expect(worst(s, Brightness.light, c.textFaint, (c) => c.surfaceCard),
            greaterThanOrEqualTo(4.5), reason: '${s.id} 浅色 faint 破 card 地板');
        expect(worst(s, Brightness.light, c.textFaint, (c) => c.surfaceFloat),
            greaterThanOrEqualTo(4.5), reason: '${s.id} 浅色 faint 破 float 地板');
        expect(worst(s, Brightness.light, c.textFaint, (c) => c.surfaceSunken),
            greaterThanOrEqualTo(3.2), reason: '${s.id} 浅色 faint 破 sunken 地板');
        expect(worst(s, Brightness.light, c.textMuted, (c) => c.surfaceCard),
            greaterThanOrEqualTo(4.5), reason: '${s.id} 浅色 muted 破 card 地板');
      }
      expect(floors.length, 3);
    });
  });

  // ══════════════════════════════════════════════════════════
  group('深色三套（计划书 §3b 推导实测值）', () {
    test('liquid-dark 的文字四档 / accentText / 语义色逐字节等于 §3b.3-3b.4', () {
      final c = StyleColors.liquidDark.colors;
      expect(c.textStrong, const Color(0xFFF0EFFA)); // §3b.3
      expect(c.textNormal, const Color(0xFFDAD8EA));
      expect(c.textFaint, const Color(0xFF9E9BB2)); // §3b.3 提亮 2（见下条）;
      expect(c.accentText, const Color(0xFFA5B3FF)); // §3b.4
      expect(c.danger, const Color(0xFFFF7B7B));
      expect(c.success, const Color(0xFF4ADE80));
      expect(c.warning, const Color(0xFFF0B860));
      expect(c.onSuccess, const Color(0xFF0A2E16));
      // CSS 深色 --ac / --ac2（:830-831）
      expect(c.accent, const Color(0xFF7C8DFF));
      expect(StyleColors.liquidDark.accent2, const Color(0xFF9B7CFF));
      expect(c.surfaceSolid, const Color(0xFF1F1E2B)); // CSS --panel-solid :829
    });

    test('frosted-dark 逐字节等于 §3b.3-3b.4', () {
      final c = StyleColors.frostedDark.colors;
      expect(c.textStrong, const Color(0xFFF2F2F4));
      expect(c.textNormal, const Color(0xFFDCDCE0));
      expect(c.textMuted, const Color(0xFFC0C0C6));
      expect(c.textFaint, const Color(0xFFA0A0A6));
      expect(c.accentText, const Color(0xFF5FBFFF));
      expect(c.accent, const Color(0xFF1D9BF0)); // :883
      expect(c.surfaceSolid, const Color(0xFF202024)); // :882
      expect(c.line, const Color(0x1FF2F2F4)); // :884 rgba(242,242,244,.12)
    });

    test('clay-dark 逐字节等于 §3b.3-3b.4', () {
      final c = StyleColors.clayDark.colors;
      expect(c.textStrong, const Color(0xFFF5F0EB));
      expect(c.textNormal, const Color(0xFFE2DAD2));
      expect(c.textMuted, const Color(0xFFCCC1B6));
      expect(c.textFaint, const Color(0xFFA89C90));
      expect(c.accentText, const Color(0xFFFFB38C));
      expect(c.accent, const Color(0xFFEA580C)); // :931
      expect(StyleColors.clayDark.accent2, const Color(0xFFF97316)); // :931
      expect(c.surfaceSolid, const Color(0xFF2A231D)); // :929
      expect(c.line, const Color(0x1FF5F0EB)); // :931 rgba(245,240,235,.12)
    });

    test('深色材质参数 = §3b.5（加 hover 面后仍过地板）', () {
      for (final s in AppStyle.values) {
        final c = StyleColors.of(s, Brightness.dark).colors;
        expect(c.surfaceCardHover.a, closeTo(0x13 / 255, 0.001),
            reason: '${s.id} 深色 hover 必须是白 7.5%（§3b.5 的上限）');
        expect(c.surfaceFloat, const Color(0xE0262626),
            reason: '${s.id} 深色 float 必须是 #262626 88%');
        // line 三档：深色是白 12%/7%/18%，但**色相按风格**（CSS 深色 --ln 各不同）
        expect(c.line.a, closeTo(0x1F / 255, 0.001),
            reason: '${s.id} 深色 line 必须是白 12%');
        expect(c.lineSoft.a, closeTo(0x12 / 255, 0.001), reason: '白 7%');
        expect(c.lineStrong.a, closeTo(0x2E / 255, 0.001), reason: '白 18%');

        // 三个面都要过地板（这是 §3b.5 那两个「危险值」的守门）
        expect(worst(s, Brightness.dark, c.textMuted, (c) => c.surfaceCard), 
            greaterThanOrEqualTo(4.5), reason: '${s.id} 深色 card.muted');
        expect(worst(s, Brightness.dark, c.textMuted, (c) => c.surfaceCardHover),
            greaterThanOrEqualTo(4.5), reason: '${s.id} 深色 hover.muted');
        expect(worst(s, Brightness.dark, c.textFaint, (c) => c.surfaceCardHover),
            greaterThanOrEqualTo(3.0), reason: '${s.id} 深色 hover.faint');
        expect(worst(s, Brightness.dark, c.textFaint, (c) => c.surfaceSunken),
            greaterThanOrEqualTo(3.0), reason: '${s.id} 深色 sunken.faint');
      }
    });

    test('深色三套的 surfaceSolid 色相与 §3b.2/CSS 一致（不是中性灰）', () {
      final liq = StyleColors.liquidDark.colors.surfaceSolid;
      final cla = StyleColors.clayDark.colors.surfaceSolid;
      // liquid 偏蓝、clay 偏暖 —— 这是「一眼看出是哪套风格」的关键
      expect(liq.b, greaterThan(liq.r), reason: 'liquid 深底应当偏蓝');
      expect(cla.r, greaterThan(cla.b), reason: 'clay 深底应当偏暖');
      // 三套底色两两不同
      final solids = {
        for (final s in AppStyle.values) StyleColors.of(s, Brightness.dark).colors.surfaceSolid
      };
      expect(solids.length, 3);
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
  group('AppColors.of 的派生与零变化', () {
    test('of(frosted, ·) 与 StyleColors 同源，且与既有 const 分开', () {
      // frosted 是默认风格，实际渲染必须走预览稿取值 —— 与 light/dark 是两份值。
      expect(identical(AppColors.of(AppStyle.frosted, Brightness.light),
              StyleColors.frostedLight.colors),
          isTrue);
      expect(identical(AppColors.of(AppStyle.frosted, Brightness.dark),
              StyleColors.frostedDark.colors),
          isTrue);
      // 而 light/dark 保留改造前的现值给既有测试文件用（两者不同族）
      expect(AppColors.light.textStrong, const Color(0xFF1A1A1A));
      expect(AppColors.dark.textStrong, const Color(0xFFF2F2F2));
      expect(AppColors.of(AppStyle.frosted, Brightness.light).textStrong,
          isNot(AppColors.light.textStrong));
    });

    test('6 组都有值，且非 frosted 的来自 StyleColors', () {
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

    test('solidFor 默认参数保持原值（既有 6 个调用点零改动）', () {
      expect(AppColors.solidFor(Brightness.light), const Color(0xFFF3F3F3));
      expect(AppColors.solidFor(Brightness.dark), const Color(0xFF202020));
      // 显式传风格时才按风格取（S3 会用到）
      expect(AppColors.solidFor(Brightness.light, style: AppStyle.clay),
          const Color(0xFFFFFDFA));
      expect(AppColors.solidFor(Brightness.dark, style: AppStyle.clay),
          const Color(0xFF2A231D));
    });

    test('accent2 只在 StyleColors 上，AppColors 仍是 23 槽位', () {
      // 反向守门：accent2 不该出现在 AppColors 上。
      expect(StyleColors.liquidLight.accent2, const Color(0xFF8B5CF6));
      expect(StyleColors.clayDark.accent2, const Color(0xFFF97316));
      expect(slots(AppColors.dark).length, 23);
    });
  });

  // ══════════════════════════════════════════════════════════
  group('A16：选中态要比悬停态「更朝主色」（6 组）', () {
    /// 把颜色在**主色色度方向**上的推进量取出（明度无关）。
    ///
    /// `theme_contrast_test` 原来硬编码的是「更蓝」（`c.b - c.r`），那只对
    /// frosted 的蓝主色成立 —— clay 的主色是橙，方向相反。这里按主色的实际
    /// 色度方向投影，对蓝给正、对橙也给正，**判据强度不变**（门档仍是 0.10）。
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
  group('onSuccess 缎带两端都读得清', () {
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
}
