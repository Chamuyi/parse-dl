import 'package:flutter/material.dart';

import 'app_style.dart';
import 'app_theme.dart';

/// 一套风格的色彩令牌 —— 23 个语义槽位（[AppColors]）加一个第二强调色。
///
/// **为什么要有这一层**：`AppSurface` 只表达材质（模糊 / 透明度 / 半径），
/// 色彩维度整个丢失，于是三套风格只差「糊不糊」，看不出是三套设计语言。
/// 这一层把色彩补回来：每套风格各有自己的强调色、文字四档、分隔线、底色。
///
/// ### 取值来源（`tools/ui/_redesign/preview/app.css` 是权威）
///
/// - **6 套底色**取 CSS 的 `--panel-solid`（浅色 `:243/:329/:396`、深色 `:829/:882/:929`）。
/// - **6 套文字**取 CSS 的 `--ink` / `--ink2` / `--ink3`（深色三套与计划书 §3b.3 一致）。
/// - **强调色**取 CSS 的 `--ac` / `--ac2`。
/// - CSS 未覆盖的项按 `docs/计划书_三套风格完整落地_2026-10-13.md` §3b 推导，逐处标注。
///
/// ### 两处必须偏离 CSS 的地方（都有实测证据，不是偷懒）
///
/// **(1) 文字是「两档照搬 + 两档派生」**。CSS 只定义 **3 档**文字色（`--ink`/`--ink2`/`--ink3`），
/// 而 [AppColors] 有 **4 档**且 `theme_contrast_test.dart` 要求相邻档 **≥1.2**：
///
/// | 槽位 | 来源 |
/// |---|---|
/// | `textStrong` | CSS `--ink`，逐字节 |
/// | `textNormal` | CSS `--ink2`，逐字节 |
/// | `textMuted` | 在 `--ink2` 与 `--ink3` 之间取**最小必要偏离**（直接沿用 `--ink2` 会与 normal 同值 → 层次 = 1.00，当场红） |
/// | `textFaint` | CSS `--ink3` 按**最小必要量**压深 / 深色则提亮 |
///
/// **(2) `textFaint` 与深色 `accentText` 的偏离**。对比度判据按「最坏壁纸」算 ——
/// 窗口底 = `AppColors.solidFor(brightness)` 以 0.85 压在壁纸上，**纯黑壁纸下卡片只有
/// #EDEDED 而不是白色**，CSS 的浅灰压上去就不够（实测：liquid 4.11 / frosted 3.94 /
/// clay 3.29，门槛 4.5）。这与 `app_theme.dart` 里记录旧值 `#737373` 只有 4.03 是同一笔账。
/// **过地板优先于逐字节对齐**，色相仍取自预览稿。
///
/// 深色三套另有两处同类偏离，都因 S2b 把 `surfaceCardHover` 纳入守护而暴露：
/// liquid 的 `textFaint` 原值在**悬停面**上只有 2.96（门槛 3.0）→ 提亮到 `#9E9BB2`；
/// frosted 的 `accentText` 原值 `#57B9FF` 在卡片面上只有 3.94（门槛 4.0）→ 提亮到 `#5BBDFF`。
@immutable
class StyleColors {
  /// 该风格的 23 个语义槽位。
  final AppColors colors;

  /// 第二强调色 —— 只有液体玻璃与陶土的渐变面用得上
  /// （CSS `#v-a`/`#v-c` 的 `--ac2`）；frosted 无渐变，等于主色。
  ///
  /// 它**不能**加进 [AppColors]：那是 23 个槽位的既有契约，926 处 `.字段`
  /// 访问依赖它不变。
  final Color accent2;

  const StyleColors({required this.colors, required this.accent2});

  // ══════════════════════════════════════════════════════════
  // 液体玻璃
  // ══════════════════════════════════════════════════════════

  /// 液体玻璃 · 浅色（CSS `#v-a`）。
  static const liquidLight = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      // CSS 卡片底是 `--ga`→`--gb` 渐变（白 62%→38%）；[AppColors.surfaceCard]
      // 只有一个色，取渐变起点（最亮那端）。
      surfaceCard: Color(0x9EFFFFFF),
      surfaceCardHover: Color(0xC7FFFFFF),
      surfaceSunken: Color(0x09000000),
      surfaceFloat: Color(0xD1FAFAFA),
      surfaceSolid: Color(0xFFFBFBFF), // CSS --panel-solid :243
      textStrong: Color(0xFF16162A), // CSS --ink :244
      textNormal: Color(0xFF3D3D5C), // CSS --ink2 :244
      textMuted: Color(0xFF494968), // 派生：--ink2 压深至与 normal 拉开 1.21
      textFaint: Color(0xFF67678A), // CSS --ink3 压深 8/通道
      line: Color(0x1216162A), // CSS --ln :247 rgba(22,22,42,.07)
      lineSoft: Color(0x0A16162A),
      lineStrong: Color(0x1D16162A),
      accent: Color(0xFF5B6CFF), // CSS --ac :245
      // CSS 没有独立的「文字强调色」变量（`--ac` 同时当填充与文字）。
      // 本项目的 accentText 语义历来是 accent 的压暗版（改造前的 frosted 就是
      // #0F6FA8 而非 #1D9BF0），沿用该语义：压到能过 card/float 的 4.0 地板。
      accentText: Color(0xFF4453D6),
      // CSS --accent-soft 是 .14，但选中底与悬停底的「朝主色色度差」只有 0.086，
      // 过不了 A16（≥0.10）→ 提到 .16。
      accentSoft: Color(0x295B6CFF),
      accentLine: Color(0x735B6CFF),
      accentGlow: Color(0x2E5B6CFF),
      danger: Color(0xFFD93B3B),
      dangerSoft: Color(0x14D93B3B),
      success: Color(0xFF0F7A38),
      warning: Color(0xFF9A5B00),
      onSuccess: Color(0xFFFFFFFF),
    ),
    accent2: Color(0xFF8B5CF6), // CSS --ac2 :245
  );

  /// 液体玻璃 · 深色（CSS `body.dark #v-a` + 计划书 §3b）。
  static const liquidDark = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      // CSS 深色 `#v-a` **没有** `.card` 底色规则（只有 `::after` 内缘环），
      // 所以按计划书 §3b.5 的白 6.5%（推导值）。
      surfaceCard: Color(0x11FFFFFF),
      surfaceCardHover: Color(0x13FFFFFF), // §3b.5：白 7.5%（上限，再高跌地板）
      surfaceSunken: Color(0x11FFFFFF), // §3b.5：白 6.5%
      surfaceFloat: Color(0xE0262626), // §3b.5：#262626 88%
      surfaceSolid: Color(0xFF1F1E2B), // CSS --panel-solid :829
      textStrong: Color(0xFFF0EFFA), // §3b.3
      textNormal: Color(0xFFDAD8EA), // §3b.3
      textMuted: Color(0xFFC1BED5), // §3b.3 原值提亮 5/通道（原值在悬停面 4.29 < 4.5）
      textFaint: Color(0xFF9E9BB2), // §3b.3 原值提亮 2/通道（原值在悬停面 2.96 < 3.0）
      line: Color(0x1FF0EFFA), // CSS --ln :833 rgba(240,239,250,.12)
      lineSoft: Color(0x12F0EFFA), // §3b.5：白 7%
      lineStrong: Color(0x2EF0EFFA), // §3b.5：白 18%
      accent: Color(0xFF7C8DFF), // CSS --ac :831
      accentText: Color(0xFFA5B3FF), // CSS :848 深色导航激活态文字色
      // CSS --accent-soft 是 .16，但选中底与悬停底的「朝主色色度差」只有 0.08，
      // 过不了 `theme_contrast_test` 的 A16（≥0.10）→ 提到 .20。
      accentSoft: Color(0x337C8DFF),
      accentLine: Color(0x807C8DFF),
      accentGlow: Color(0x4D7C8DFF),
      danger: Color(0xFFFF7B7B), // §3b.4
      dangerSoft: Color(0x29FF7B7B),
      success: Color(0xFF4ADE80), // §3b.4
      warning: Color(0xFFF0B860), // §3b.4
      onSuccess: Color(0xFF0A2E16), // §3b.4（缎带文字，6 组都过 4.5）
    ),
    accent2: Color(0xFF9B7CFF), // CSS --ac2 :831
  );

  // ══════════════════════════════════════════════════════════
  // 磨砂清晰（默认风格）
  // ══════════════════════════════════════════════════════════

  /// 磨砂清晰 · 浅色（CSS `#v-b`）。
  ///
  /// **注意**：这一套与 `AppColors.light` 是**两份不同的值**。`AppColors.light`
  /// 是改造前的通用中性灰，保留它是为了 40 多个既有测试文件的引用；
  /// 而应用**实际渲染** frosted 时走的是本套（预览稿的冷灰蓝）。
  static const frostedLight = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0x9EFFFFFF),
      surfaceCardHover: Color(0xC7FFFFFF),
      surfaceSunken: Color(0x09000000),
      surfaceFloat: Color(0xD1FAFAFA),
      surfaceSolid: Color(0xFFF7F9FC), // CSS --panel-solid :329
      textStrong: Color(0xFF101014), // CSS --ink :331
      textNormal: Color(0xFF34343D), // CSS --ink2 :331
      textMuted: Color(0xFF404049), // 派生（层次 1.201）
      textFaint: Color(0xFF696974), // CSS --ink3 压深 11/通道
      line: Color(0x1A101014), // CSS --ln :331 rgba(16,16,20,.10)
      lineSoft: Color(0x0E101014),
      lineStrong: Color(0x29101014),
      accent: Color(0xFF1D9BF0), // CSS --ac :330
      accentText: Color(0xFF0F6FA8),
      accentSoft: Color(0x331D9BF0), // 改造前的 20%（真机复核过，不动）
      accentLine: Color(0x731D9BF0),
      accentGlow: Color(0x2E1D9BF0),
      danger: Color(0xFFD93B3B),
      dangerSoft: Color(0x14D93B3B),
      success: Color(0xFF0F7A38),
      warning: Color(0xFF9A5B00),
      onSuccess: Color(0xFFFFFFFF),
    ),
    accent2: Color(0xFF1D9BF0), // 无渐变面，等于主色
  );

  /// 磨砂清晰 · 深色（CSS `body.dark #v-b` + §3b.3）。
  static const frostedDark = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0x11FFFFFF), // CSS :891 rgba(255,255,255,.065)
      surfaceCardHover: Color(0x13FFFFFF), // §3b.5：白 7.5%
      surfaceSunken: Color(0x11FFFFFF), // §3b.5
      surfaceFloat: Color(0xE0262626), // §3b.5
      surfaceSolid: Color(0xFF202024), // CSS --panel-solid :882
      textStrong: Color(0xFFF2F2F4), // §3b.3
      textNormal: Color(0xFFDCDCE0), // §3b.3
      textMuted: Color(0xFFC0C0C6), // §3b.3 原值提亮 4/通道（原值在悬停面 4.33 < 4.5）
      textFaint: Color(0xFFA0A0A6), // §3b.3
      line: Color(0x1FF2F2F4), // CSS --ln :884 rgba(242,242,244,.12)
      lineSoft: Color(0x12F2F2F4),
      lineStrong: Color(0x2EF2F2F4),
      accent: Color(0xFF1D9BF0), // CSS --ac :883
      accentText: Color(0xFF5FBFFF), // §3b.4 原值 #57B9FF 提亮（hover 面 3.82 < 4.0）
      accentSoft: Color(0x291D9BF0), // CSS --accent-soft :882（.16）
      accentLine: Color(0x801D9BF0),
      accentGlow: Color(0x4D1D9BF0),
      danger: Color(0xFFFF7B7B), // §3b.4
      dangerSoft: Color(0x29FF7B7B),
      success: Color(0xFF4ADE80),
      warning: Color(0xFFF0B860),
      onSuccess: Color(0xFF0A2E16),
    ),
    accent2: Color(0xFF1D9BF0),
  );

  // ══════════════════════════════════════════════════════════
  // 陶土柔和
  // ══════════════════════════════════════════════════════════

  /// 陶土柔和 · 浅色（CSS `#v-c`）。
  static const clayLight = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0xFFFFFDFA), // CSS :405 实心卡面
      surfaceCardHover: Color(0xC7FFFFFF),
      surfaceSunken: Color(0x09000000),
      surfaceFloat: Color(0xD1FAFAFA),
      surfaceSolid: Color(0xFFFFFDFA), // CSS --panel-solid :396
      textStrong: Color(0xFF2B2622), // CSS --ink :397
      textNormal: Color(0xFF574E46), // CSS --ink2 :397
      textMuted: Color(0xFF635A52), // 派生（层次 1.206）
      textFaint: Color(0xFF736860), // CSS --ink3 压深 24/通道
      line: Color(0x172B2622), // CSS --ln :398 rgba(43,38,34,.09)
      lineSoft: Color(0x0D2B2622),
      lineStrong: Color(0x252B2622),
      accent: Color(0xFFC2410C), // CSS --ac :398
      accentText: Color(0xFF9A3412),
      // CSS --accent-soft 是 .10，A16 过不了（toward 0.0902 < 0.10）→
      // 提到 .122（0x1F）为**最小合法值**：clay-light 是六组里唯一靠这条红的，
      // 实测 .122 时 toward=0.1020（其余五组见 theme_contrast_test）。
      accentSoft: Color(0x1FC2410C),
      accentLine: Color(0x73C2410C),
      accentGlow: Color(0x2EC2410C),
      danger: Color(0xFFD93B3B),
      dangerSoft: Color(0x14D93B3B),
      success: Color(0xFF0F7A38),
      warning: Color(0xFF9A5B00),
      onSuccess: Color(0xFFFFFFFF),
    ),
    accent2: Color(0xFFEA580C), // CSS --ac2 :398
  );

  /// 陶土柔和 · 深色（CSS `body.dark #v-c`）。
  ///
  /// ⚠️ 已知遗留：本套的 `surfaceCard` 是**实色**（CSS 里与 `--panel-solid` 同色，
  /// 靠 `border: 1px solid var(--ln)` 分界）。当 S3 把背景层改成按风格取 `solidFor`
  /// 之后，凹面（`surfaceSunken` = 白 6.5%）会叠在这块实色上、比卡片更亮，
  /// `textFaint` 在凹面上只有 **2.95**（门槛 3.0）。本批 `solidFor` 仍返回现值
  /// `#202020`，所以判据是过的；**S3 接线时要一并处理这个组合**。
  static const clayDark = StyleColors(
    colors: AppColors(
      surfaceBase: Colors.transparent,
      surfaceCard: Color(0xFF2A231D), // CSS :939 实心，与 --panel-solid 同色
      surfaceCardHover: Color(0x13FFFFFF), // §3b.5：白 7.5%
      surfaceSunken: Color(0x11FFFFFF), // §3b.5
      surfaceFloat: Color(0xE0262626), // §3b.5
      surfaceSolid: Color(0xFF2A231D), // CSS --panel-solid :929
      textStrong: Color(0xFFF5F0EB), // §3b.3
      textNormal: Color(0xFFE2DAD2), // §3b.3
      textMuted: Color(0xFFCCC1B6), // §3b.3
      textFaint: Color(0xFFA89C90), // §3b.3
      line: Color(0x1FF5F0EB), // CSS --ln :931 rgba(245,240,235,.12)
      lineSoft: Color(0x12F5F0EB),
      lineStrong: Color(0x2EF5F0EB),
      accent: Color(0xFFEA580C), // CSS --ac :931
      accentText: Color(0xFFFFB38C), // CSS :944 深色导航激活态文字色
      accentSoft: Color(0x29EA580C), // CSS --accent-soft :929（.16）
      accentLine: Color(0x80EA580C),
      accentGlow: Color(0x4DEA580C),
      danger: Color(0xFFFF7B7B), // §3b.4
      dangerSoft: Color(0x29FF7B7B),
      success: Color(0xFF4ADE80),
      warning: Color(0xFFF0B860),
      onSuccess: Color(0xFF0A2E16),
    ),
    accent2: Color(0xFFF97316), // CSS --ac2 :931
  );

  /// 按「风格 + 亮度」取令牌。穷尽 `switch` —— 加第四套风格时编译期就会报错。
  static StyleColors of(AppStyle style, Brightness brightness) =>
      switch ((style, brightness)) {
        (AppStyle.liquid, Brightness.light) => liquidLight,
        (AppStyle.liquid, Brightness.dark) => liquidDark,
        (AppStyle.frosted, Brightness.light) => frostedLight,
        (AppStyle.frosted, Brightness.dark) => frostedDark,
        (AppStyle.clay, Brightness.light) => clayLight,
        (AppStyle.clay, Brightness.dark) => clayDark,
      };
}
