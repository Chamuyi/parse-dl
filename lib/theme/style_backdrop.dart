import 'package:flutter/material.dart';

import 'app_style.dart';

/// 背景层令牌 —— 声明式描述一套风格的窗口底（[BackgroundLayer] 按此绘制）。
///
/// **为什么是声明式**：`BackgroundLayer` 只管「按描述画」，不认识风格 ——
/// 加第四套风格时只改这里，绘制代码零改动。与 `AppSurface` / `StyleColors`
/// 同一思路：调用方读令牌，不自己判断风格。
///
/// ### 取值出处（`tools/ui/_redesign/preview/app.css` 是权威）
///
/// 每套 = 若干层 radial 光晕 + 一层线性渐变（CSS `background` 多重背景，
/// 第一层画在最上面）：
///
/// | 风格 | 浅色 | 深色 | 出处 |
/// |---|---|---|---|
/// | liquid | 三层 radial + 150° 线性 | 三层 radial + 150° 线性 | `:248-252` / `:834-838` |
/// | frosted | 165° 线性 | 165° 线性 | `:332` / `:885` |
/// | clay | 168° 线性 | 168° 线性 | `:399` / `:932` |
///
/// 层数是 S3 的验收判据：liquid = 3（三层 radial）+ 1（线性），frosted = 1，
/// clay = 1（`style_backdrop_test.dart` 钉住）。
///
/// ### ⚠️ 2026-10-16 全部改成 35% 半透明（0x59）
///
/// 此前这里每个色停都是 **`0xFF` 完全不透明**，绘制器又铺满整个窗口 ——
/// 于是**窗口材质被整片盖死**：实测 mica / 亚克力 / 纯色三种材质渲染出来
/// 逐像素完全相同（平均差 **0.00**），「窗口材质」这个设置项等于没有效果。
///
/// 现在这一层只给 35%，上面再叠 `solidFor(style)@0.85` 的调色层，材质能透出
/// 约 10%。**为什么不是全透明**：全透明会让风格自身的渐变（三套的窗口底色
/// 差异）一起消失，而那是「换风格看得出来」的一部分；35% 是两者都留得住的值。
///
/// **为什么调色层不能一起调低**：它是文字对比度的地板。它的 alpha 一旦变小，
/// 「壁纸透进来」的幅度就变大，凹面上的弱档文字会跌破 4.5
/// （`theme_contrast_test` 的整张地板表就是按 0.85 算的）。所以材质可见度
/// 只能从这一层让出来。
@immutable
class StyleBackdrop {
  /// radial 光晕层，**从上到下按 CSS 的书写顺序**（第一层最靠上）。
  ///
  /// 空列表 = 该风格没有光晕（frosted / clay）。
  final List<StyleGlow> glows;

  /// 最底下的线性渐变。**永远有值** —— 对应 CSS `background` 的最后一层，
  /// 也是「永远铺一层底」不变量的取色来源。
  final StyleLinear linear;

  const StyleBackdrop({required this.glows, required this.linear});

  /// 光晕层数（liquid = 3，frosted / clay = 0）。
  int get glowCount => glows.length;

  static StyleBackdrop of(AppStyle style, Brightness brightness) =>
      // 2026-10-19 只剩一套风格，分流塌缩成明暗二选一。
      brightness == Brightness.dark ? winuiDark : winuiLight;

  /// WinUI3 · 浅色。#FCFCFC 单层（fluent_ui theme.dart:474）。
  static const winuiLight = StyleBackdrop(
    glows: [],
    linear: StyleLinear(
      stops: [
        Color(0x59FCFCFC),
        Color(0x59FAF9F8),
        Color(0x59F3F2F1),
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
  );

  /// WinUI3 · 深色。#2C2C2C 单层（暖灰，`theme.dart:470`）。
  static const winuiDark = StyleBackdrop(
    glows: [],
    linear: StyleLinear(
      stops: [
        Color(0x592C2C2C),
        Color(0x592A2A2A),
        Color(0x59252525),
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
  );

  static const frostedLight = StyleBackdrop(
    glows: [],
    linear: StyleLinear(
      stops: [
        Color(0x59EEF1F6), // #eef1f6 0%
        Color(0x59E8ECF3), // #e8ecf3 48%
        Color(0x59F0EEF3), // #f0eef3 100%
      ],
      begin: Alignment(-0.259, -0.966), // 165°
      end: Alignment(0.259, 0.966),
    ),
  );

  /// CSS `:885`。
  static const frostedDark = StyleBackdrop(
    glows: [],
    linear: StyleLinear(
      stops: [
        Color(0x5917171A), // 0%
        Color(0x591B1B1F), // 48%
        Color(0x59191820), // 100%
      ],
      begin: Alignment(-0.259, -0.966), // 165°
      end: Alignment(0.259, 0.966),
    ),
  );

  // ── 陶土柔和 ────────────────────────────────────────────────

  /// CSS `:399`：单层 `linear-gradient(168deg, …)`。
  static const clayLight = StyleBackdrop(
    glows: [],
    linear: StyleLinear(
      stops: [
        Color(0x59FAF6F1), // #faf6f1 0%
        Color(0x59F5EFE8), // #f5efe8 50%
        Color(0x59F8F4EF), // #f8f4ef 100%
      ],
      begin: Alignment(-0.208, -0.978), // 168°
      end: Alignment(0.208, 0.978),
    ),
  );

  /// CSS `:932`。
  static const clayDark = StyleBackdrop(
    glows: [],
    linear: StyleLinear(
      stops: [
        Color(0x591F1A16), // 0%
        Color(0x59241E19), // 50%
        Color(0x59221D19), // 100%
      ],
      begin: Alignment(-0.208, -0.978), // 168°
      end: Alignment(0.208, 0.978),
    ),
  );
}

/// 一层 radial 光晕。
///
/// [radiusFactor] 是**相对值**（相对窗口对角线的一半），不写死像素 ——
/// CSS 的 `1100px 700px` 是在预览稿窗口尺寸下量出来的，搬进桌面端要按
/// 窗口实际尺寸缩放，否则小窗口里光晕会溢出、大窗口里又缩成一团。
@immutable
class StyleGlow {
  /// 光晕中心的实色（CSS radial 第一个色停）。
  final Color color;

  /// 光晕中心（[Alignment] 坐标系：-1~-1 左上，1~1 右下）。
  final Alignment center;

  /// 光晕半径 ≈ `radiusFactor × 窗口对角线的一半`。
  final double radiusFactor;

  const StyleGlow({
    required this.color,
    required this.center,
    required this.radiusFactor,
  });
}

/// 最底下那层线性渐变。
@immutable
class StyleLinear {
  /// 渐变停点，按 CSS 原文顺序。
  final List<Color> stops;

  final Alignment begin;
  final Alignment end;

  const StyleLinear({
    required this.stops,
    required this.begin,
    required this.end,
  });

  /// 按 [stops] 数量均匀分布的停点表。
  ///
  /// CSS 里三停分别是 0% / 48~52% / 100% —— 中间停点在 48~52% 之间波动，
  /// 与均匀分布（50%）的偏差不足 2 个百分点，肉眼不可分辨，统一取均匀。
  List<double> get evenlySpaced {
    if (stops.length == 1) return const [0.0];
    return List.generate(
      stops.length,
      (i) => i / (stops.length - 1),
      growable: false,
    );
  }
}
