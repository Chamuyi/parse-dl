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

  /// WinUI3 · 浅色。**逐条对齐官方 WinUI 语义画刷**
  /// （权威源：`F:\samples\_verify\fluent_full\lib\src\styles\color_resources.dart`
  /// 的 `ResourceDictionary.light`）。
  ///
  /// 两条换算规则（上一轮踩过坑，写在这里避免再犯）：
  ///
  /// 1. **表面保留官方 alpha**。官方卡片底 `cardBackgroundFillColorDefault`
  ///    = 70% 白，它不是颜色而是"提亮膜"，靠压在下面的 `solidBackgroundFillColorBase`
  ///    上透出来分层。旧值 `#FCFCFC` 是把它当实色画，所以层次死板。
  /// 2. **文字换算成实色**。官方四档文字是带 alpha 的黑；而对比度判据只读
  ///    RGB、不读 alpha，直接照抄会让四档被算成同一色（实测 strong→normal
  ///    只有 1.000，层次判据整组判红）。换算基准 = 底色 #F3F3F3。
  static const winuiLight = StyleColors(
    colors: AppColors(
      // = 官方 solidBackgroundFillColorBase。内容区铺它当底 ——
      // WinUI 里这层由 Mica 提供，Flutter 侧没有 Mica，用官方同名令牌兜底。
      surfaceBase: Color(0xFFF3F3F3),
      // cardBackgroundFillColorDefault（70% 白）**合成到不透明**后的值。
      // 理由同 [winuiDark]：官方是压在 Mica 上的，我方要自己合掉，
      // 否则深色壁纸会把卡片压暗、对比度不稳。
      surfaceCard: Color(0xFFFBFBFB),
      // controlFillColorSecondary（50% 的 #F9F9F9）合成后
      surfaceCardHover: Color(0xFFF7F7F7),
      // solidBackgroundFillColorTertiary
      surfaceSunken: Color(0xFFF9F9F9),
      // solidBackgroundFillColorQuarternary
      surfaceFloat: Color(0xFFFFFFFF),
      // solidBackgroundFillColorBase
      surfaceSolid: Color(0xFFF3F3F3),
      // smokeFillColorDefault
      scrim: Color(0x4D000000),
      // 四档文字**不用官方 alpha 的换算值**：官方 textFillColorTertiary
      // （44.7% 黑压 #F3F3F3 = #868686）是给**不透明表面**设计的；我方窗口底
      // 只有 0.85 不透明度、壁纸会参与合成，卡片会被顶到接近纯白，
      // 那套值实测只有 3.52 < 地板 4.5（对比度判据当场抓出）。
      // 这里保留项目原有的四档实色 —— 它们是在同一合成模型下实测校准的。
      textStrong: Color(0xFF1B1A19),
      textNormal: Color(0xFF3B3A39),
      textMuted: Color(0xFF484644),
      textFaint: Color(0xFF5E5C5A),
      // cardStrokeColorDefault / subtleFillColorTertiary / controlStrokeColorSecondary
      line: Color(0x0F000000),
      lineSoft: Color(0x06000000),
      lineStrong: Color(0x29000000),
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

  /// WinUI3 · 深色。**逐条对齐官方语义画刷**
  /// （权威源：`fluent_full/lib/src/styles/color_resources.dart` 的 `ResourceDictionary.dark`）。
  ///
  /// ### 2026-10-19 换源：从"截图采样"改为"官方令牌表"
  ///
  /// 此前是截 Windows 11 设置页真图逐点采样（侧栏 33 / 内容区 43 / 卡片 44）。
  /// 那些数是「DWM 材质 + 用户桌面壁纸 + 应用色」**三层合成**的结果，不是应用
  /// 自己的色值 —— 把它写进色板等于把用户壁纸的颜色抄进代码，观感会发脏。
  /// 现在改抄官方令牌表，与应用无关、与壁纸无关。
  ///
  /// 换算规则同 [winuiLight]：表面保留 alpha，文字换算成实色（基准 #202020）。
  static const winuiDark = StyleColors(
    colors: AppColors(
      // = 官方 solidBackgroundFillColorBase（#202020）。同 [winuiLight]。
      surfaceBase: Color(0xFF202020),
      // cardBackgroundFillColorDefault（5% 白）**合成到不透明**后的值。
      //
      // 官方那 5% 白是压在**不透明 Mica** 上的；我方窗口底只有 0.85 不透明度，
      // 白壁纸会从下面顶上来把卡片冲淡（实测 faint 对比度掉到 1.79）。
      // 所以这里预先把它合成掉 —— 等价于 Mica 那一层，观感与官方一致。
      surfaceCard: Color(0xFF2B2B2B),
      // controlFillColorSecondary（8% 白）合成后
      surfaceCardHover: Color(0xFF323232),
      // solidBackgroundFillColorSecondary
      surfaceSunken: Color(0xFF1C1C1C),
      // solidBackgroundFillColorQuarternary
      surfaceFloat: Color(0xFF2C2C2C),
      // solidBackgroundFillColorBase
      surfaceSolid: Color(0xFF202020),
      // smokeFillColorDefault
      scrim: Color(0x4D000000),
      // 同 [winuiLight]：官方 textFillColorDisabled（36.5% 白压 #202020
      // = #717171）在不透明表面上够用，但我方壁纸会参与合成、卡片会变亮，
      // 实测 faint 只有 2.90 < 地板 3.0。保留项目原有的四档实色。
      textStrong: Color(0xFFFFFFFF),
      textNormal: Color(0xFFE8E8E8),
      textMuted: Color(0xFFC8C8C8),
      textFaint: Color(0xFFA6A6A6),
      // dividerStrokeColorDefault / subtleFillColorTertiary / controlStrokeColorDefault
      line: Color(0x15FFFFFF),
      lineSoft: Color(0x0AFFFFFF),
      lineStrong: Color(0x12FFFFFF),
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
