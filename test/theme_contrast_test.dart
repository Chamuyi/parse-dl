import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 文字档位压在透明材质上时的对比度。
///
/// 为什么要用算的而不是截图取像素：这个应用的底色**跟着壁纸浮动**。
/// 窗口底 = `solidFor(brightness)` 以 alpha 0.85 压在壁纸上（`background_layer.dart:76`），
/// 于是浅色主题换一张黑壁纸，卡片从 #FBFBFB 掉到 #EDEDED；暗色主题换一张白壁纸，
/// 卡片从 #282828 抬到 #4C4C4C。同一份色板，读得清读不清取决于用户桌面是什么，
/// 而截图只能拍到"拍的那一刻、那张壁纸"。这里把纯黑与纯白两端都算进去取最差值。
void main() {
  double lin(double s) => s <= 0.03928
      ? s / 12.92
      : math.pow((s + 0.055) / 1.055, 2.4).toDouble();

  double lum(Color color) =>
      0.2126 * lin(color.r) + 0.7152 * lin(color.g) + 0.0722 * lin(color.b);

  double ratio(Color ink, Color bg) {
    final hi = lum(ink) > lum(bg) ? lum(ink) : lum(bg);
    final lo = lum(ink) > lum(bg) ? lum(bg) : lum(ink);
    return (hi + 0.05) / (lo + 0.05);
  }

  /// 半透明前景压在不透明背景上（与 CSS 合成同一套算法；`.r/.g/.b` 是 0~1）
  Color over(Color fg, Color bg) {
    final a = fg.a;
    int mix(double f, double b) => ((f * a + b * (1 - a)) * 255).round().clamp(0, 255);
    return Color.fromARGB(255, mix(fg.r, bg.r), mix(fg.g, bg.g), mix(fg.b, bg.b));
  }

  /// [surface] 在「0.85 的窗口底色 + 壁纸」上，壁纸取黑/白两端，返回两个实色底
  List<Color> backingFor(
    Brightness brightness,
    AppColors palette,
    Color Function(AppColors) surface, {
    required AppStyle style,
  }) {
    // **必须传风格**：`solidFor` 现在按风格取底色（2026-10-16 起），
    // 不传就退回 frosted —— 那样另外两套的底会被算错，判据与生产脱节。
    final solid = AppColors.solidFor(brightness, style: style);
    return [Color(0xFF000000), Color(0xFFFFFFFF)]
        .map((wallpaper) =>
            over(surface(palette), over(solid.withValues(alpha: 0.85), wallpaper)))
        .toList();
  }

  double worst(
    Brightness brightness,
    AppColors palette,
    Color ink,
    Color Function(AppColors) surface, {
    required AppStyle style,
  }) {
    var min = double.infinity;
    for (final bg in backingFor(brightness, palette, surface, style: style)) {
      final r = ratio(ink, bg);
      if (r < min) min = r;
    }
    return min;
  }

  final surfaces = <String, Color Function(AppColors)>{
    'card': (c) => c.surfaceCard,
    // hover 面此前无人守（计划书 §3b.5 末的测试盲区）—— 深色那两个「危险值」
    // 能骗过第一遍推导就是因为这张表里没有它。门槛与 card 相同。
    'hover': (c) => c.surfaceCardHover,
    'float': (c) => c.surfaceFloat,
    'sunken': (c) => c.surfaceSunken,
  };

  // 地板值：钉住"已经测到这个水平"的现状，谁把可读性改差就会红。
  // 分表面是因为凹下去那层（chips / 输入框底 / 分段控件托盘）天生比卡片暗一档 ——
  // 浅色主题配深色壁纸时卡片 #EDEDED、凹层只有 #C7C7C7，弱档灰字与警告色在上面
  // 拿不到 4.5。这是已知的结构问题（要改窗口不透明度才能治，属于观感决策），
  // 所以这里按实测值钉住、只不许继续恶化。
  const floors = <String, Map<String, double>>{
    'light': {
      'card.strong': 4.5, 'card.normal': 4.5, 'card.muted': 4.5, 'card.faint': 4.5,
      'card.accentText': 4.0, 'card.danger': 3.0,
      // hover 面：门槛与 card 相同（S2b 新增覆盖，不是放宽 —— 计划书 §3b.5 末）。
      'hover.strong': 4.5, 'hover.normal': 4.5, 'hover.muted': 4.5, 'hover.faint': 4.5,
      'hover.accentText': 4.0, 'hover.danger': 3.0,
      'hover.success': 4.5, 'hover.warning': 4.5,
      'float.strong': 4.5, 'float.normal': 4.5, 'float.muted': 4.5, 'float.faint': 4.5,
      'float.accentText': 4.0, 'float.danger': 3.0,
      'sunken.strong': 4.5, 'sunken.normal': 4.5, 'sunken.muted': 3.7,
      'sunken.faint': 3.2, 'sunken.accentText': 3.1, 'sunken.danger': 2.6,
      'card.success': 4.5, 'card.warning': 4.5,
      'float.success': 4.5, 'float.warning': 4.5,
      'sunken.success': 3.1, 'sunken.warning': 3.1,
    },
    'dark': {
      'card.strong': 4.5, 'card.normal': 4.5, 'card.muted': 4.5, 'card.faint': 3.0,
      'card.accentText': 4.0, 'card.danger': 3.0,
      // hover 面同 card —— 这一档此前无人守，深色 hover 白 11% 的错误值
      // 正是从这道缺口溜进去的（实测 muted 只有 4.03）。
      'hover.strong': 4.5, 'hover.normal': 4.5, 'hover.muted': 4.5, 'hover.faint': 3.0,
      'hover.accentText': 4.0, 'hover.danger': 3.0,
      'hover.success': 3.7, 'hover.warning': 3.7,
      'float.strong': 4.5, 'float.normal': 4.5, 'float.muted': 4.5, 'float.faint': 3.0,
      'float.accentText': 4.0, 'float.danger': 3.0,
      'sunken.strong': 4.5, 'sunken.normal': 4.5, 'sunken.muted': 4.0,
      'sunken.faint': 3.0, 'sunken.accentText': 3.5, 'sunken.danger': 3.0,
      'card.success': 3.7, 'card.warning': 3.7,
      'float.success': 3.7, 'float.warning': 3.7,
      'sunken.success': 3.9, 'sunken.warning': 3.9,
    },
  };

  const themes = <String, (AppStyle, Brightness)>{
    'liquid-light': (AppStyle.liquid, Brightness.light),
    'liquid-dark': (AppStyle.liquid, Brightness.dark),
    'frosted-light': (AppStyle.frosted, Brightness.light),
    'frosted-dark': (AppStyle.frosted, Brightness.dark),
    'clay-light': (AppStyle.clay, Brightness.light),
    'clay-dark': (AppStyle.clay, Brightness.dark),
  };

  /// 地板值按**亮度**取（与改造前一致），风格只决定色板。
  String floorKey(Brightness b) => b == Brightness.dark ? 'dark' : 'light';

  for (final entry in themes.entries) {
    final theme = entry.key;
    final (style, brightness) = entry.value;
    final c = AppColors.of(style, brightness);
    final inks = <String, Color>{
      'strong': c.textStrong,
      'normal': c.textNormal,
      'muted': c.textMuted,
      'faint': c.textFaint,
      'accentText': c.accentText,
      'danger': c.danger,
      'success': c.success,
      'warning': c.warning,
    };

    for (final s in surfaces.entries) {
      for (final ink in inks.entries) {
        final key = '${s.key}.${ink.key}';
        test('$theme：${ink.key} 压在${s.key}上，最坏壁纸下也够对比度', () {
          final got = worst(brightness, c, ink.value, s.value, style: style);
          final need = floors[floorKey(brightness)]![key];
          expect(
            need,
            isNotNull,
            reason: '$theme / $key 没有登记地板值 —— 新增面必须补地板，'
                '否则它是无人守的盲区',
          );
          expect(
            got,
            greaterThanOrEqualTo(need!),
            reason: '$theme / $key 实测 ${got.toStringAsFixed(2)} '
                '< 地板 $need',
          );
        });
      }
    }

    test('$theme：四档文字还分得出层次（不许靠压平色阶来过线）', () {
      // 用相邻两档之间的对比度衡量，而不是相对亮度之差 —— 暗端那一头
      // 相对亮度被 gamma 压得很扁，#1A1A1A 与 #2F2F2F 只差 0.018 却明显是两种灰。
      final steps = <(String, Color, Color)>[
        ('strong→normal', c.textStrong, c.textNormal),
        ('normal→muted', c.textNormal, c.textMuted),
        ('muted→faint', c.textMuted, c.textFaint),
      ];
      for (final (label, a, b) in steps) {
        final gap = ratio(a, b);
        expect(
          gap,
          greaterThanOrEqualTo(1.2),
          reason: '$label 两档之间只有 ${gap.toStringAsFixed(2)}（要 ≥1.2），会并成一种灰',
        );
      }
    });
  }

  test('悬停态与选中态不同形（2026-09-30 那条旧账的守门检查）', () {
    // 旧账：「选中态与 hover 态几乎同形：都是深底胶囊，只差一圈描边」。
    // 度量方式换过两次：
    //  1) 先拿 WCAG 对比度量两种填充 —— 浅色主题怎么调都上不去（hover 往白里走、
    //     selected 是淡蓝，明度本来就接近），说明"看着一样"靠的不是明度。
    //  2) 再换成 sRGB 距离 —— 暗色主题只有 0.061，因为两种填充确实都偏暗，
    //     人眼区分它们靠的是**蓝不蓝**。
    // 所以最终度量是「朝主色方向的彩度差」：选中底必须明显比悬停底更靠主色。
    //
    // 6 组时主色不再都是蓝的（clay 是橙 `#C2410C`），所以把「蓝-红跨度」换成
    // 「主色的蓝-红跨度方向」：主色偏蓝 → 因子 +1（与改造前逐字节同式）；
    // 主色偏暖 → 因子 -1（更橙读作正向）。**度量单位与阈值都没动**。
    double chromaToward(Color x, Color accent) {
      final ax = accent.b - accent.r;
      return (x.b - x.r) * (ax >= 0 ? 1 : -1);
    }

    double dist(Color a, Color b) => math.sqrt(math.pow(a.r - b.r, 2) +
            math.pow(a.g - b.g, 2) +
            math.pow(a.b - b.b, 2)) /
        math.sqrt(3.0);

    for (final entry in themes.entries) {
      final (style, brightness) = entry.value;
      final c = AppColors.of(style, brightness);
      final sel = selectedDecoration(c);
      for (final wall in [const Color(0xFF000000), const Color(0xFFFFFFFF)]) {
        final base = over(
            AppColors.solidFor(brightness).withValues(alpha: 0.85), wall);
        final cardBg = over(c.surfaceCard, base);
        final hover = over(c.surfaceCardHover, cardBg);
        final selected = over(c.accentSoft, cardBg);
        final toward = chromaToward(selected, c.accent) -
            chromaToward(hover, c.accent);
        expect(
          toward,
          greaterThanOrEqualTo(0.10),
          reason: '${entry.key}：选中底比悬停底只朝主色推进了 '
              '${toward.toStringAsFixed(3)}（要 ≥0.10）',
        );
        expect(
          dist(hover, selected),
          greaterThanOrEqualTo(0.05),
          reason: '${entry.key}：两种填充的距离只有 ${dist(hover, selected).toStringAsFixed(3)}',
        );
      }
      // 选中态还要多两样 hover 没有的东西：主色描边 + 柔光
      final border = (sel.border! as Border).top.color;
      expect(border.a, greaterThan(0), reason: '选中态必须有可见描边');
      expect(sel.boxShadow, isNotEmpty, reason: '选中态必须有柔光');
    }
  });

  test('整块成功色填充上的文字（那条「已下载」缎带）两端都读得清', () {
    // 缎带是 8px 的小字，按正文标准要 4.5。暗色主题的 success 是亮绿，
    // 白字压上去只有 2.20 —— 所以要 onSuccess，不能沿用 textStrong。
    for (final entry in themes.entries) {
      final (style, brightness) = entry.value;
      final c = AppColors.of(style, brightness);
      final r = ratio(c.onSuccess, c.success);
      expect(r, greaterThanOrEqualTo(4.5),
          reason: '${entry.key}：onSuccess 压在 success 上只有 ${r.toStringAsFixed(2)}');
    }
  });

  test('strong/faint 的明暗方向随主题翻转，别把两套写反', () {
    expect(lum(AppColors.dark.textStrong),
        greaterThan(lum(AppColors.dark.textFaint)));
    expect(lum(AppColors.light.textStrong),
        lessThan(lum(AppColors.light.textFaint)));
  });
}
