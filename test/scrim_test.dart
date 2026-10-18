import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/style_colors.dart';

/// 模态遮罩（`AppColors.scrim`）必须**压暗**它盖住的东西。
///
/// ### 为什么要钉这一条（2026-10-15 真机）
///
/// 选项选择器浮层原先拿 `textMuted` 当遮罩：
///
/// ```dart
/// barrierColor: c.textMuted.withValues(alpha: 0.55)   // ← 错的
/// ```
///
/// 深色主题的 `textMuted` 是 `#BCBCBC` 的**浅灰**。55% 浅灰盖在暗色界面上，
/// 等于给整屏蒙了一层发白的雾 —— 实测同一块侧栏的平均亮度从 44.4 涨到
/// 126.8（2.86 倍），与「把背景退下去、把弹层推上来」正好相反。
///
/// 这条判据不看「像不像雾」（那要靠眼睛），只钉一条可计算的性质：
/// **把遮罩叠在任何一个表面上，叠完必须比叠之前更暗。**
void main() {
  /// 三风格 × 两明暗的全部组合。
  final combos = <(String, AppColors)>[
    for (final s in AppStyle.values)
      for (final b in Brightness.values)
        ('${s.name}/${b.name}', StyleColors.of(s, b).colors),
  ];

  /// 合成后的相对亮度：`scrim` 叠在 [bg] 上。
  double blendedLuma(Color scrim, Color bg) =>
      Color.alphaBlend(scrim, bg).computeLuminance();

  group('遮罩', () {
    test('六种组合都齐（少一种这条判据就只盖住一半）', () {
      expect(combos, hasLength(AppStyle.values.length * 2));
      // 负控制：组合确实是**互不相同**的色板，不是同一个对象被列了六遍。
      final distinct = combos.map((e) => identityHashCode(e.$2)).toSet();
      expect(distinct, hasLength(AppStyle.values.length * 2), reason: '六种组合取到的是同一个色板，遍历是假的');
    });

    test('本身是近黑（不是从浅色文字色派生出来的）', () {
      for (final (name, c) in combos) {
        expect(c.scrim.computeLuminance(), lessThan(0.05),
            reason: '$name 的遮罩不是近黑 —— 浅色遮罩会把界面罩成发白的雾');
        expect(c.scrim.a, greaterThan(0.3),
            reason: '$name 的遮罩几乎全透明，压不住背景');
      }
    });

    test('叠在任何表面上都让它变暗（这是遮罩的定义）', () {
      for (final (name, c) in combos) {
        // 覆盖三种典型底：实心面板、浮动层、以及「卡片叠在浅色壁纸上」
        // 那种中间亮度（深色主题卡片透出白壁纸时约 #4C4C4C）。
        final backgrounds = <String, Color>{
          'surfaceSolid': c.surfaceSolid,
          'surfaceFloat': Color.alphaBlend(c.surfaceFloat, c.surfaceSolid),
          '中间灰': const Color(0xFF4C4C4C),
        };
        for (final entry in backgrounds.entries) {
          final before = entry.value.computeLuminance();
          final after = blendedLuma(c.scrim, entry.value);
          expect(after, lessThan(before),
              reason: '$name：遮罩叠在「${entry.key}」上反而把它提亮了 '
                  '（$before -> $after）');
        }
      }
    });

    test('负控制：旧写法（textMuted 55%）确实会被这条判据抓住', () {
      // 复现 2026-10-15 的真机缺陷写法，证明上一条不是恒真。
      var caught = 0;
      for (final (name, c) in combos) {
        final buggy = c.textMuted.withValues(alpha: 0.55);
        final bg = c.surfaceSolid;
        final before = bg.computeLuminance();
        final after = blendedLuma(buggy, bg);
        if (after >= before) {
          caught++;
          // 深色主题是重灾区：浅灰遮罩把暗底提亮近一个数量级。
          expect(after, greaterThan(before),
              reason: '$name 的旧写法本该提亮，判据模型没复现出来');
        }
      }
      expect(caught, greaterThan(0),
          reason: '旧写法一个都没被抓到 —— 说明上面的判据模型失效了');
      // 至少深色那一半必须被抓到（浅色主题下 textMuted 是深灰，本来就会压暗，
      // 那不是缺陷；缺陷是「同一行代码在深色下反转了行为」）。
      expect(caught, greaterThanOrEqualTo(3),
          reason: '三个深色风格都应该被抓到，实际只抓到 $caught 个');
    });

    test('负控制：把遮罩换成纯白也必定被抓', () {
      for (final (name, c) in combos) {
        const white = Color(0x8AFFFFFF);
        final bg = c.surfaceSolid;
        expect(blendedLuma(white, bg), greaterThan(bg.computeLuminance()),
            reason: '$name：白色遮罩必须被判为「提亮」');
      }
    });
  });
}
