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

  /// WinUI3 · 深色。
  ///
  /// ### 2026-10-19 按**真实 Windows 11 设置页**重新取值（用户第三次判「不对」）
  ///
  /// 此前是我按理解猜的，层级搞反了。这次直接截 Windows 11「设置」真图，
  /// 逐点采样（`F:\samples\_verify\real_settings.png`）：
  ///
  ///   侧栏底   #21201F (33,32,31)   ← **最暗**
  ///   内容区底 #2B2B2B (43,43,43)   ← 中间层
  ///   卡片底   #2C2C2C (44,43,43)   ← 与内容区**几乎同色**，靠 1px 边线分层
  ///   卡片间隙 #202020 (32,32,32)
  ///   选中行底 #2F2D29 (47,45,41)   ← 极淡的暖色提亮
  ///   普通按钮 #383737 (56,55,55)   ← 比卡片亮一档
  ///
  /// 关键结论（我原先反了）：**侧栏比内容区更暗**，卡片与内容区几乎同色。
  static const winuiDark = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      // 卡片与内容区同色（实测 44 vs 43），分层靠边线
      surfaceCard: Color(0xFF2C2C2C),
      // 悬停/普通按钮面比卡片亮一档（实测 56）
      surfaceCardHover: Color(0xFF383737),
      // 凹面（输入框等）比卡片略暗
      surfaceSunken: Color(0xFF272727),
      surfaceFloat: Color(0xFF323232),
      // 内容区底（实测 43,43,43）
      surfaceSolid: Color(0xFF2B2B2B),
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
      // 2026-10-19 只剩一套风格，分流塌缩成明暗二选一。
      brightness == Brightness.dark ? winuiDark : winuiLight;
}
