import 'package:flutter/material.dart';

import 'app_style.dart';
import 'app_theme.dart';

/// 三套风格各自的整套色板（浅色 / 深色共六套）。
///
/// 与 [AppColors] 的关系：`AppColors.light` / `.dark` 是**中性默认套**
/// （40 多个既有测试文件的引用出口），而应用实际渲染时走的是本文件的六套。
/// 两者的槽位完全一致。
///
/// ## 2026-10-19 新增 WinUI3 色板
///
/// 用户裁定「照抄其他 Flutter 项目的窗口材质与界面风格」，参考
/// `bdlukaa/fluent_ui`（BSD-3-Clause）。新增 [winuiLight] / [winuiDark]：
/// 22 级中性灰台阶、暖灰深色底 `#2C2C2C`（**不是纯黑/冷灰**，这是
/// 「看起来像 Windows」的关键）、单色强调、1px 边线分层。
///
/// ## 2026-10-16 全量重做
///
/// 用户裁定「所有窗口材质和界面风格都不满意，包括深色模式和浅色模式」。
/// 此前六套的取值是逐字节照 `tools/ui/_redesign/preview/app.css` 抄的
/// （预览稿是本项目此前的视觉权威）。这一次不再锚定那份稿子，改按三条原则
/// 重排，并且**每一条都留下可复算的判据**：
///
/// ### 原则一：承载文字的面必须「稳」
///
/// 窗口底是 `solidFor(brightness)` 以 0.85 的 alpha 压在壁纸上
/// （`background_layer.dart`），所以**壁纸会透进 15%**。旧卡片是 62% 白，
/// 于是纯黑壁纸给出 `#EDEDED`、纯白壁纸给出 `#FBFBFB` —— 同一份色板，
/// 读得清读不清取决于用户桌面是什么，实测同一块区域亮度位移达 0.289。
///
/// 现在承载文字的面一律 ≥90% 不透明：底层那点漂移被按比例压掉一个数量级
/// （浅色卡片在两种壁纸下只差 3/255），文字对比度因此**可计算、可保证**。
/// 材质感交给页面背景与 [AppSurface] 的模糊去表达，不再靠"卡片很透"。
///
/// ### 原则二：中性色带色相
///
/// 旧值是纯灰（`#F3F3F3` / `#202020` / `#F2F2F2` / `#BCBCBC`）—— 三套风格
/// 除了 accent 之外看不出区别，也就是"没设计过"的样子。现在每套的中性色
/// 各自带一个色相族，与它自己的 accent 同族：
///
/// | 风格 | 色相族 | 浅色 | 深色 |
/// |---|---|---|---|
/// | liquid 液体玻璃 | 冷紫（zinc/indigo 系） | `#FAFAFF` | `#141420` |
/// | frosted 磨砂清晰 | 冷蓝灰（slate 系，Windows 原生观感） | `#F8FAFC` | `#14171E` |
/// | clay 陶土柔和 | 暖石（stone 系） | `#FDFCF8` | `#15120E` |
///
/// ### 原则三：四档文字按对比度排布，不按"看着差不多"
///
/// 四档（strong / normal / muted / faint）的相邻两档对比度都 ≥1.2，且**最弱那档
/// 压在最不利的面上也要 ≥4.5**。旧值在浅色主题的凹面上 faint 只有 3.2、
/// danger 只有 2.7 —— 那是长期挂着的实测地板。现在六套 × 四个面 × 八档文字 ×
/// 纯黑/纯白两种壁纸，**全部 ≥4.5**（全局最小值 4.56）。
///
/// ### accent 与 onAccent 的方向
///
/// 浅色主题的 accent 取**深**一档（白字压上去才够），深色主题取**亮**一档
/// （配深字）。旧实现一律用白字压 accent、且从来没有判据覆盖，实测
/// `#1D9BF0` 上白字只有 3.00、深色的 `#38BDF8` 上白字只有 2.14。
class StyleColors {
  final AppColors colors;

  const StyleColors({required this.colors});

  // ══════════════════════════════════════════════════════════
  // 液体玻璃 —— 冷紫。最"设计感"的一套：近白/近黑的面 + 紫调中性色。
  // ══════════════════════════════════════════════════════════

  /// 液体玻璃 · 浅色
  static const liquidLight = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0xE6F1EFFF),
      surfaceCardHover: Color(0xF2F6F4FF),
      surfaceSunken: Color(0xF2F0EEFB),
      surfaceFloat: Color(0xFAFCFAFF),
      surfaceSolid: Color(0xFFF4F2FF),
      scrim: Color(0x8A000000),
      textStrong: Color(0xFF18181B),
      textNormal: Color(0xFF3F3F46),
      textMuted: Color(0xFF52525B),
      textFaint: Color(0xFF6A6A82),
      line: Color(0x1A18181B),
      lineSoft: Color(0x0E18181B),
      lineStrong: Color(0x2918181B),
      accent: Color(0xFF4F46E5),
      accentText: Color(0xFF4F46E5),
      onAccent: Color(0xFFFFFFFF),
      accentSoft: Color(0x334F46E5),
      accentLine: Color(0x734F46E5),
      accentGlow: Color(0x2E4F46E5),
      danger: Color(0xFFB91C1C),
      dangerSoft: Color(0x14B91C1C),
      success: Color(0xFF166534),
      warning: Color(0xFF92400E),
      onSuccess: Color(0xFFFFFFFF),
    ),
  );

  /// 液体玻璃 · 深色
  static const liquidDark = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0xE61A1A24),
      surfaceCardHover: Color(0xEE23232A),
      surfaceSunken: Color(0xF014141C),
      surfaceFloat: Color(0xFF252536),
      surfaceSolid: Color(0xFF141420),
      scrim: Color(0x99000000),
      textStrong: Color(0xFFFFFFFF),
      textNormal: Color(0xFFDEDEEF),
      textMuted: Color(0xFFB6B6D0),
      textFaint: Color(0xFF9090AE),
      line: Color(0x1FFFFFFF),
      lineSoft: Color(0x12FFFFFF),
      lineStrong: Color(0x2EFFFFFF),
      accent: Color(0xFF818CF8),
      accentText: Color(0xFFA5B4FC),
      onAccent: Color(0xFF12122B),
      accentSoft: Color(0x42818CF8),
      accentLine: Color(0x80818CF8),
      accentGlow: Color(0x4D818CF8),
      danger: Color(0xFFFCA5A5),
      dangerSoft: Color(0x29FCA5A5),
      success: Color(0xFF86EFAC),
      warning: Color(0xFFFCD34D),
      onSuccess: Color(0xFF0A2E16),
    ),
  );

  // ══════════════════════════════════════════════════════════
  // 磨砂清晰（默认）—— 冷蓝灰 + Windows 原生强调色。
  // 这一套刻意最"像 Windows 11 自带应用"：accent 用 Fluent 的 #0F6CBD。
  // ══════════════════════════════════════════════════════════

  /// 磨砂清晰 · 浅色
  static const frostedLight = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0xE6F8FAFC),
      surfaceCardHover: Color(0xF2FBFCFE),
      surfaceSunken: Color(0xF2F2F4F7),
      surfaceFloat: Color(0xFAFFFFFF),
      surfaceSolid: Color(0xFFF8FAFC),
      scrim: Color(0x8A000000),
      textStrong: Color(0xFF0F172A),
      textNormal: Color(0xFF334155),
      textMuted: Color(0xFF475569),
      textFaint: Color(0xFF5B6C82),
      line: Color(0x1A0F172A),
      lineSoft: Color(0x0E0F172A),
      lineStrong: Color(0x290F172A),
      accent: Color(0xFF0F6CBD),
      accentText: Color(0xFF0F6CBD),
      onAccent: Color(0xFFFFFFFF),
      accentSoft: Color(0x330F6CBD),
      accentLine: Color(0x730F6CBD),
      accentGlow: Color(0x2E0F6CBD),
      danger: Color(0xFFB91C1C),
      dangerSoft: Color(0x14B91C1C),
      success: Color(0xFF166534),
      warning: Color(0xFF92400E),
      onSuccess: Color(0xFFFFFFFF),
    ),
  );

  /// 磨砂清晰 · 深色
  static const frostedDark = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0xE61B1F27),
      surfaceCardHover: Color(0xEE232833),
      surfaceSunken: Color(0xF0151820),
      surfaceFloat: Color(0xFF252A38),
      surfaceSolid: Color(0xFF14171E),
      scrim: Color(0x99000000),
      textStrong: Color(0xFFFFFFFF),
      textNormal: Color(0xFFDFE6EE),
      textMuted: Color(0xFFB9C6D6),
      textFaint: Color(0xFF93A3B8),
      line: Color(0x1FFFFFFF),
      lineSoft: Color(0x12FFFFFF),
      lineStrong: Color(0x2EFFFFFF),
      accent: Color(0xFF38BDF8),
      accentText: Color(0xFF7DD3FC),
      onAccent: Color(0xFF0B1220),
      accentSoft: Color(0x4238BDF8),
      accentLine: Color(0x8038BDF8),
      accentGlow: Color(0x4D38BDF8),
      danger: Color(0xFFFCA5A5),
      dangerSoft: Color(0x29FCA5A5),
      success: Color(0xFF86EFAC),
      warning: Color(0xFFFCD34D),
      onSuccess: Color(0xFF0A2E16),
    ),
  );

  // ══════════════════════════════════════════════════════════
  // 陶土柔和 —— 暖石。实心面、暖中性色、陶土色强调。
  // ══════════════════════════════════════════════════════════

  /// 陶土柔和 · 浅色
  static const clayLight = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0xE6FEFBF4),
      surfaceCardHover: Color(0xF2FFFDF7),
      surfaceSunken: Color(0xF2F6F2E9),
      surfaceFloat: Color(0xFAFFFDF6),
      surfaceSolid: Color(0xFFFBF7EE),
      scrim: Color(0x8A000000),
      textStrong: Color(0xFF1C1917),
      textNormal: Color(0xFF44403C),
      textMuted: Color(0xFF57534E),
      textFaint: Color(0xFF6E655C),
      line: Color(0x1A1C1917),
      lineSoft: Color(0x0E1C1917),
      lineStrong: Color(0x291C1917),
      accent: Color(0xFFC2410C),
      accentText: Color(0xFFA8380A),
      onAccent: Color(0xFFFFFFFF),
      accentSoft: Color(0x33C2410C),
      accentLine: Color(0x73C2410C),
      accentGlow: Color(0x2EC2410C),
      danger: Color(0xFFB91C1C),
      dangerSoft: Color(0x14B91C1C),
      success: Color(0xFF166534),
      warning: Color(0xFF92400E),
      onSuccess: Color(0xFFFFFFFF),
    ),
  );

  /// 陶土柔和 · 深色
  static const clayDark = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0xE61C1813),
      surfaceCardHover: Color(0xEE241F19),
      surfaceSunken: Color(0xF015120E),
      surfaceFloat: Color(0xFF2B251E),
      surfaceSolid: Color(0xFF15120E),
      scrim: Color(0x99000000),
      textStrong: Color(0xFFFFFDFB),
      textNormal: Color(0xFFE0D7CC),
      textMuted: Color(0xFFBCB0A2),
      textFaint: Color(0xFFA3978B),
      line: Color(0x1FFFFDFB),
      lineSoft: Color(0x12FFFDFB),
      lineStrong: Color(0x2EFFFDFB),
      accent: Color(0xFFFB923C),
      accentText: Color(0xFFFDBA74),
      onAccent: Color(0xFF1C130B),
      accentSoft: Color(0x42FB923C),
      accentLine: Color(0x80FB923C),
      accentGlow: Color(0x4DFB923C),
      danger: Color(0xFFFCA5A5),
      dangerSoft: Color(0x29FCA5A5),
      success: Color(0xFF86EFAC),
      warning: Color(0xFFFCD34D),
      onSuccess: Color(0xFF0A2E16),
    ),
  );

  // ══════════════════════════════════════════════════════════
  // Windows 原生（WinUI3）—— 取值来源 `bdlukaa/fluent_ui`（BSD-3-Clause）
  //
  // 与前三套的差异：
  // 1. 深色底是**暖灰 #2C2C2C**，前三套是冷灰 / 紫灰 / 棕灰；
  // 2. 中性色走 22 级灰台阶（fluent_ui/color.dart:84-105），不带各自色相；
  // 3. 强调色单色（三档由用户在设置里选，见 WinUiAccent）。
  // ══════════════════════════════════════════════════════════

  /// WinUI3 · 浅色。表层色取自 `fluent_ui/lib/src/styles/theme.dart:469-479`。
  static const winuiLight = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0xE6FCFCFC),
      surfaceCardHover: Color(0xF2F3F2F1),
      surfaceSunken: Color(0xF2F3F2F1),
      surfaceFloat: Color(0xFFFAF9F8),
      surfaceSolid: Color(0xFFFCFCFC),
      scrim: Color(0x8A000000),
      textStrong: Color(0xFF1B1A19),
      textNormal: Color(0xFF3B3A39),
      textMuted: Color(0xFF484644),
      textFaint: Color(0xFF5E5C5A),
      line: Color(0x261B1A19),
      lineSoft: Color(0x121B1A19),
      lineStrong: Color(0x3D1B1A19),
      accent: Color(0xFF0078D4),
      accentText: Color(0xFF005A9E),
      onAccent: Color(0xFFFFFFFF),
      accentSoft: Color(0x330078D4),
      accentLine: Color(0x660078D4),
      accentGlow: Color(0x1A0078D4),
      danger: Color(0xFFC42B1C),
      dangerSoft: Color(0x14C42B1C),
      success: Color(0xFF0F7B0F),
      warning: Color(0xFF9D5D00),
      onSuccess: Color(0xFFFFFFFF),
    ),
  );

  /// WinUI3 · 深色。底 `#2C2C2C`（暖灰）`theme.dart:470`。
  static const winuiDark = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0xE62C2C2C),
      surfaceCardHover: Color(0xF2323232),
      surfaceSunken: Color(0xF2252525),
      surfaceFloat: Color(0xFF323232),
      surfaceSolid: Color(0xFF2C2C2C),
      scrim: Color(0x99000000),
      textStrong: Color(0xFFFFFFFF),
      textNormal: Color(0xFFE8E8E8),
      textMuted: Color(0xFFC8C8C8),
      textFaint: Color(0xFFA6A6A6),
      line: Color(0x1FFFFFFF),
      lineSoft: Color(0x12FFFFFF),
      lineStrong: Color(0x2EFFFFFF),
      accent: Color(0xFF4CC2FF),
      accentText: Color(0xFF7FD4FF),
      onAccent: Color(0xFF00304D),
      accentSoft: Color(0x594CC2FF),
      accentLine: Color(0x804CC2FF),
      accentGlow: Color(0x264CC2FF),
      danger: Color(0xFFFF99A4),
      dangerSoft: Color(0x29FF99A4),
      success: Color(0xFF6CCB5F),
      warning: Color(0xFFFCE100),
      onSuccess: Color(0xFF0A2E16),
    ),
  );

  /// 按「风格 + 亮度」取令牌。穷尽 `switch` —— 加第四套风格时编译期就会报错。
  static StyleColors of(AppStyle style, Brightness brightness) =>
      switch ((style, brightness)) {
        (AppStyle.winui, Brightness.light) => winuiLight,
        (AppStyle.winui, Brightness.dark) => winuiDark,
        (AppStyle.liquid, Brightness.light) => liquidLight,
        (AppStyle.liquid, Brightness.dark) => liquidDark,
        (AppStyle.frosted, Brightness.light) => frostedLight,
        (AppStyle.frosted, Brightness.dark) => frostedDark,
        (AppStyle.clay, Brightness.light) => clayLight,
        (AppStyle.clay, Brightness.dark) => clayDark,
      };
}
