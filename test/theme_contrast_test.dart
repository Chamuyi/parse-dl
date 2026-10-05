import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
    Color Function(AppColors) surface,
  ) {
    final solid = AppColors.solidFor(brightness);
    return [Color(0xFF000000), Color(0xFFFFFFFF)]
        .map((wallpaper) =>
            over(surface(palette), over(solid.withValues(alpha: 0.85), wallpaper)))
        .toList();
  }

  double worst(
    Brightness brightness,
    AppColors palette,
    Color ink,
    Color Function(AppColors) surface,
  ) {
    var min = double.infinity;
    for (final bg in backingFor(brightness, palette, surface)) {
      final r = ratio(ink, bg);
      if (r < min) min = r;
    }
    return min;
  }

  final surfaces = <String, Color Function(AppColors)>{
    'card': (c) => c.surfaceCard,
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
      'float.strong': 4.5, 'float.normal': 4.5, 'float.muted': 4.5, 'float.faint': 3.0,
      'float.accentText': 4.0, 'float.danger': 3.0,
      'sunken.strong': 4.5, 'sunken.normal': 4.5, 'sunken.muted': 4.0,
      'sunken.faint': 3.0, 'sunken.accentText': 3.5, 'sunken.danger': 3.0,
      'card.success': 3.7, 'card.warning': 3.7,
      'float.success': 3.7, 'float.warning': 3.7,
      'sunken.success': 3.9, 'sunken.warning': 3.9,
    },
  };

  const themes = <String, (Brightness, AppColors)>{
    'light': (Brightness.light, AppColors.light),
    'dark': (Brightness.dark, AppColors.dark),
  };

  for (final entry in themes.entries) {
    final theme = entry.key;
    final (brightness, c) = entry.value;
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
          final got = worst(brightness, c, ink.value, s.value);
          expect(
            got,
            greaterThanOrEqualTo(floors[theme]![key]!),
            reason: '$theme / $key 实测 ${got.toStringAsFixed(2)} '
                '< 地板 ${floors[theme]![key]}',
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
    // 所以最终度量是「朝主色方向的彩度差」：选中底必须明显比悬停底更蓝。
    double blue(Color c) => c.b - c.r; // 主色 #1D9BF0 的蓝-红跨度
    double dist(Color a, Color b) => math.sqrt(math.pow(a.r - b.r, 2) +
            math.pow(a.g - b.g, 2) +
            math.pow(a.b - b.b, 2)) /
        math.sqrt(3.0);

    for (final entry in themes.entries) {
      final (brightness, c) = entry.value;
      final sel = selectedDecoration(c);
      for (final wall in [const Color(0xFF000000), const Color(0xFFFFFFFF)]) {
        final base = over(
            AppColors.solidFor(brightness).withValues(alpha: 0.85), wall);
        final cardBg = over(c.surfaceCard, base);
        final hover = over(c.surfaceCardHover, cardBg);
        final selected = over(c.accentSoft, cardBg);
        expect(
          blue(selected) - blue(hover),
          greaterThanOrEqualTo(0.10),
          reason: '${entry.key}：选中底比悬停底只蓝了 '
              '${(blue(selected) - blue(hover)).toStringAsFixed(3)}（要 ≥0.10）',
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
      final (_, c) = entry.value;
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
