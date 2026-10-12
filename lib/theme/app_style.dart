import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'style_colors.dart';

/// 风格缩略图里那块「桌面壁纸」的渐变。
///
/// 放在 `lib/theme/` 里是有意的：它是**视觉令牌**，而色板棘轮
/// （`test/visual_tokens_test.dart`）只扫 `lib/theme/` 之外 —— 缩略图的
/// 壁纸色是「预览用的数据」，不该逼着每个选择器各自登记一遍写死颜色。
const List<Color> kPreviewWallpaper = [
  Color(0xFF6C4BB0),
  Color(0xFF1E6E8C),
  Color(0xFFD9A441),
];

/// 界面风格。持久化在 `settings.json` 的 `appearance.visualStyle`。
///
/// 存进配置文件的 id 定下就不能改（同 [WindowMaterial.id] 的约定）。
///
/// 三套风格是**同一套界面**的三种材质表达，不是三套皮肤：页面结构、语义色、
/// 布局全部共用，差别只落在卡片的模糊 / 透明度 / 半径 / 渐变 / 描边 / 阴影上。
/// 所以它跟 [AppColors]（管「用什么颜色」）正交，由 [AppSurface] 表达。
enum AppStyle {
  liquid('liquid', '液体玻璃', '多层渐变加内缘亮环，模糊最轻、透光最强'),
  frosted('frosted', '磨砂清晰', '单层磨砂，模糊与不透明度取中，文字最清楚'),
  clay('clay', '陶土柔和', '实心面配更重的软阴影，完全不透明，性能最好');

  const AppStyle(this.id, this.label, this.description);

  /// 持久化用的标识，定下就不能改
  final String id;
  final String label;
  final String description;

  /// 缺字段 / 坏值一律回退 [AppStyle.frosted]。
  ///
  /// 旧配置里没有这个字段 → 升级后拿到默认风格，观感与改造前一致。
  static AppStyle fromId(String? id) => AppStyle.values.firstWhere(
        (s) => s.id == id,
        orElse: () => AppStyle.frosted,
      );

  /// 这套风格的色彩令牌。
  ///
  /// 与 [AppSurface.of] 并列：色彩与材质是**两个正交维度**，都在这里取，
  /// 调用方（页面 / 组件）不自己判断风格。取值出口只有 [StyleColors.of] 一处。
  StyleColors colorsFor(Brightness brightness) => StyleColors.of(this, brightness);
}

/// 卡片材质令牌 —— 一块面「有多厚、多透、多亮」。
///
/// 与 [AppColors] 正交：色板回答「用什么颜色」，这里回答「这块面是什么材质」。
/// 调用方（[AppCard]）只读令牌，不自己判断风格 —— 要加第四套风格时只改这里。
///
/// 三套取值照预览稿实测（`tools/ui/_redesign/preview/index.html`）。
@immutable
class AppSurface {
  /// 卡片高斯模糊 sigma。**0 表示实心面**，调用方据此决定不套 `BackdropFilter`
  /// （实心面不该有模糊，顺带省一层合成开销）。
  final double blur;

  /// 卡片不透明度 0~1。`1.0` = 实心面，直接取色板的不透明底色。
  final double opacity;

  /// 半径系数：乘到调用方传的 `radius` 上（调用方的半径语义保留）。
  final double radiusScale;

  /// 是否用渐变面（液体玻璃的多层折射感）
  final bool gradient;

  /// 是否画内缘亮环
  final bool rim;

  final double shadowY, shadowBlur, shadowOpacity;

  const AppSurface({
    required this.blur,
    required this.opacity,
    required this.radiusScale,
    required this.gradient,
    required this.rim,
    required this.shadowY,
    required this.shadowBlur,
    required this.shadowOpacity,
  });

  /// 液体玻璃：透光最强、半径最大，带渐变面与内缘亮环。
  static const liquid = AppSurface(
    blur: 5,
    opacity: 0.62,
    radiusScale: 1.25,
    gradient: true,
    rim: true,
    shadowY: 10,
    shadowBlur: 30,
    shadowOpacity: 0.20,
  );

  /// 磨砂清晰（默认）。
  ///
  /// `blur: 22` / `opacity: .76` **取自 morrow 源码的默认值** ——
  /// `tools/ui/_redesign/morrow/lib/appearance.dart` 里 `ComponentMaterial`
  /// 的构造默认 `this.blur = 22, this.opacity = .76`（第 44~45 行），
  /// `fromJson` 也用同一对值兜底（第 96~97 行 `?? 22` / `?? .76`）。
  /// 这是本项目「预览稿实测值」的出处，改这两个数前先去核对那份源码。
  static const frosted = AppSurface(
    blur: 22,
    opacity: 0.76,
    radiusScale: 1.0,
    gradient: false,
    rim: false,
    shadowY: 8,
    shadowBlur: 24,
    shadowOpacity: 0.22,
  );

  /// 陶土柔和：实心面 + 最重的软阴影，完全不透明。
  static const clay = AppSurface(
    blur: 0,
    opacity: 1.0,
    radiusScale: 1.0,
    gradient: false,
    rim: false,
    shadowY: 12,
    shadowBlur: 28,
    shadowOpacity: 0.35,
  );

  static AppSurface of(AppStyle s) => switch (s) {
        AppStyle.liquid => liquid,
        AppStyle.frosted => frosted,
        AppStyle.clay => clay,
      };

  /// 卡片实际底色。
  ///
  /// [base] 是色板给的半透明卡片色，[solid] 是不透明底色。
  ///
  /// **frosted 必须逐字节等于 [base]**：它是默认风格，不改设置的用户不该看出
  /// 任何差别，所以缩放比例以它自己的 [opacity] 为 1.0 基准。比它更透的风格
  /// 按比例减 alpha；实心风格（[opacity] ≥ 1）直接换成 [solid] —— 把半透明底色的
  /// alpha 拉满会让深色主题的卡片变成一张纯白板，那是另一个 bug。
  Color resolveCardColor(Color base, Color solid) {
    if (opacity >= 1) return solid;
    return base.withValues(
      alpha: (base.a * (opacity / frosted.opacity)).clamp(0.0, 1.0),
    );
  }

  /// 卡片投影的不透明度。
  ///
  /// 浅色主题按深色档的 23% 派生：同一档黑影压在浅底上格外显眼，改造前就是
  /// 分两档的（旧值 0.07 / 0.30，比值 0.233）。单一值会让浅色主题的卡片
  /// 突然长出一圈黑边。
  double shadowAlphaFor(Brightness brightness) =>
      shadowOpacity * (brightness == Brightness.light ? 0.23 : 1.0);

  /// 渐变面的高光端色（只有 [gradient] 为真时用）。
  Color gradientTop(Color cardColor) =>
      Color.lerp(cardColor, Colors.white, 0.18)!;

  /// 内缘亮环色（只有 [rim] 为真时用）。
  Color rimColor(Brightness brightness) => Colors.white.withValues(
        alpha: brightness == Brightness.light ? 0.55 : 0.28,
      );
}

// ══════════════════════════════════════════════════════════════
// S4 · 圆角分档 / 边框 / 投影 / 悬停
//
// 下面四组令牌的取值**逐项取证自** `tools/ui/_redesign/preview/app.css`，
// 每条注明出处行号。计划书 §1 只给了概括，这里按 CSS 原文取值。
//
// 为什么放在 [AppStyle] 的扩展里而不是塞进 [AppSurface]：`AppSurface` 的三套
// 现值（blur / opacity / radiusScale）是 P1 期已验收的，有测试钉着，不许改。
// 这四组是**新增维度**，所以另开扩展，互不干扰。
// ══════════════════════════════════════════════════════════════

/// 圆角**档位** —— 取代调用方传像素。
///
/// 三套风格对同一个档位给不同半径（液体玻璃更圆、磨砂更方、陶土居中），
/// 这是「一套设计语言」的一部分，所以对外暴露的稳定 API 是**档位**而不是像素：
/// 调用方说「我这是张卡片」，半径由当前风格决定。
enum AppRadius {
  /// `.card` —— 卡片本体。`app.css:266` / `:347` / `:408`
  card,

  /// `.qi` / `.opt` / `.hero` —— 小控件与首屏块。`app.css:273` / `:348` / `:409`
  qi,

  /// `.field` / `.web` / `.pill` / `.tabs2` / `.sw` / `.li` —— 输入框与胶囊。
  /// `app.css:274` / `:349` / `:410`
  field,

  /// `.hero2` / `.stat` —— 大统计块。`app.css:804` / `:805` / `:806`
  hero2,
}

/// 圆角分档表：`(风格, 档位) → 半径`。
extension AppStyleRadiusTokens on AppStyle {
  double radiusOf(AppRadius slot) => switch ((this, slot)) {
        (AppStyle.liquid, AppRadius.card) => 20,
        (AppStyle.frosted, AppRadius.card) => 14,
        (AppStyle.clay, AppRadius.card) => 16,
        (AppStyle.liquid, AppRadius.qi) => 11,
        (AppStyle.frosted, AppRadius.qi) => 10,
        (AppStyle.clay, AppRadius.qi) => 12,
        (AppStyle.liquid, AppRadius.field) => 9,
        (AppStyle.frosted, AppRadius.field) => 8,
        (AppStyle.clay, AppRadius.field) => 10,
        (AppStyle.liquid, AppRadius.hero2) => 14,
        (AppStyle.frosted, AppRadius.hero2) => 12,
        (AppStyle.clay, AppRadius.hero2) => 14,
      };
}

/// 卡片边框的两层色：顶部 1px 高光 + 其余三边的环。
///
/// 为什么分成两个槽位而不是一个 [Color]：液体玻璃的边缘来自 CSS 的
/// `border: 1px solid var(--rim)` **叠加** `inset 0 1px 0 rgba(255,255,255,.95)`
/// ——顶边被高光盖住，另外三边留 ring 色。一个 [Color] 表达不了这个差异。
///
/// **能力边界（如实记录）**：CSS 的 `inset 0 -14px 26px -18px …` 那道底部内光晕
/// 用 Flutter 的 [BoxDecoration] 无法表达（它没有 inset shadow），这里只取
/// 「可表达的 1px 顶部高光」这一半，不做近似伪造。
@immutable
class StyleBorder {
  final Color top;
  final Color side;

  const StyleBorder({required this.top, required this.side});

  /// 顶部高光与三边同色时用这个（磨砂 / 陶土都没有独立的高光边）。
  const StyleBorder.uniform(this.side) : top = side;

  Border toBorder() => Border(
        top: BorderSide(color: top),
        left: BorderSide(color: side),
        right: BorderSide(color: side),
        bottom: BorderSide(color: side),
      );

  @override
  bool operator ==(Object other) =>
      other is StyleBorder && other.top == top && other.side == side;

  @override
  int get hashCode => Object.hash(top, side);
}

/// 卡片边框随风格变。
extension AppStyleBorderTokens on AppStyle {
  StyleBorder cardBorderOf(AppColors c, Brightness brightness) =>
      switch ((this, brightness)) {
        // `:259` `border: 1px solid var(--rim)`，`--rim` = `rgba(255,255,255,.75)`
        // （`:247`）；`:260` `inset 0 1px 0 rgba(255,255,255,.95)`。
        (AppStyle.liquid, Brightness.light) => const StyleBorder(
              top: Color(0xF2FFFFFF),
              side: Color(0xBFFFFFFF),
            ),
        // 深色 `--rim` = `rgba(255,255,255,.14)`（`:833`）。CSS 深色**未给**
        // `.card` 的顶部高光（只有 `::after` 内缘环，`:843`），所以这里不编造，
        // 顶边与三边同色。
        (AppStyle.liquid, Brightness.dark) =>
          const StyleBorder.uniform(Color(0x24FFFFFF)),
        // `:341` `border: 1px solid rgba(255,255,255,.9)`；`:891` 深色 `.10`。
        (AppStyle.frosted, Brightness.light) =>
          const StyleBorder.uniform(Color(0xE6FFFFFF)),
        (AppStyle.frosted, Brightness.dark) =>
          const StyleBorder.uniform(Color(0x1AFFFFFF)),
        // `:405` / `:939` 两处都是 `border: 1px solid var(--ln)`，
        // 而 `--ln` 已逐字节进了色板（`StyleColors` 的 `line`），所以取色板而不是
        // 在这里再写一个值 —— 分隔线只有一处出处。
        (AppStyle.clay, Brightness.light) ||
        (AppStyle.clay, Brightness.dark) =>
          StyleBorder.uniform(c.line),
      };
}

/// 卡片投影随风格变 —— **每套是两条**（磨砂与陶土是 CSS 的双层影，
/// 液体玻璃是一条带负 spread 的大影）。
///
/// 返回值**不是常量**，调用方不该缓存；它只是把 CSS 的 `box-shadow` 列表
/// 逐条翻成 [BoxShadow]。
extension AppStyleShadowTokens on AppStyle {
  List<BoxShadow> cardShadows(Brightness brightness) =>
      switch ((this, brightness)) {
        // `:262` `0 10px 30px -12px rgba(38,38,80,.20)`。
        (AppStyle.liquid, Brightness.light) => const [
            BoxShadow(
              color: Color(0x33362650),
              offset: Offset(0, 10),
              blurRadius: 30,
              spreadRadius: -12,
            ),
          ],
        // CSS 深色 `#v-a` 没给 `.card` 的投影（`:828` 起只有变量与 `::after`）。
        // 深色底上需要比浅色更重的影才看得出层次，取同一几何、黑影 35%。
        (AppStyle.liquid, Brightness.dark) => const [
            BoxShadow(
              color: Color(0x59000000),
              offset: Offset(0, 10),
              blurRadius: 30,
              spreadRadius: -12,
            ),
          ],
        // `:342` `0 1px 2px rgba(16,16,20,.05), 0 8px 24px -14px rgba(16,16,20,.22)`。
        (AppStyle.frosted, Brightness.light) => const [
            BoxShadow(
              color: Color(0x0D101014),
              offset: Offset(0, 1),
              blurRadius: 2,
            ),
            BoxShadow(
              color: Color(0x38101014),
              offset: Offset(0, 8),
              blurRadius: 24,
              spreadRadius: -14,
            ),
          ],
        // `:892` `0 1px 2px rgba(0,0,0,.30), 0 8px 24px -14px rgba(0,0,0,.50)`。
        (AppStyle.frosted, Brightness.dark) => const [
            BoxShadow(
              color: Color(0x4D000000),
              offset: Offset(0, 1),
              blurRadius: 2,
            ),
            BoxShadow(
              color: Color(0x80000000),
              offset: Offset(0, 8),
              blurRadius: 24,
              spreadRadius: -14,
            ),
          ],
        // `:406` `0 2px 4px rgba(87,78,70,.05), 0 12px 28px -18px rgba(87,78,70,.35)`。
        (AppStyle.clay, Brightness.light) => const [
            BoxShadow(
              color: Color(0x0D574E46),
              offset: Offset(0, 2),
              blurRadius: 4,
            ),
            BoxShadow(
              color: Color(0x59574E46),
              offset: Offset(0, 12),
              blurRadius: 28,
              spreadRadius: -18,
            ),
          ],
        // `:940` `0 2px 4px rgba(0,0,0,.28), 0 12px 28px -18px rgba(0,0,0,.55)`。
        (AppStyle.clay, Brightness.dark) => const [
            BoxShadow(
              color: Color(0x47000000),
              offset: Offset(0, 2),
              blurRadius: 4,
            ),
            BoxShadow(
              color: Color(0x8C000000),
              offset: Offset(0, 12),
              blurRadius: 28,
              spreadRadius: -18,
            ),
          ],
      };
}

/// 悬停底色随风格变。
///
/// 改造前三套风格共用色板的 `surfaceCardHover`，**而浅色三套的那个值恰好
/// 完全相同**（都是白 78%）—— 也就是说浅色下悬停反馈根本分不出风格。
/// 这里按各套 CSS 的 `:hover` 规则取值。
///
/// 浅色三套的 hover 都是**往亮里加**：[AppColors.surfaceCard] 本身是半透明白，
/// 再叠一层更亮的白 → 压在卡片上的文字对比度只会升高，不会跌地板。
extension AppStyleHoverTokens on AppStyle {
  Color hoverColor(Brightness brightness) => switch ((this, brightness)) {
        // `:280` `.grp > .hd:hover { background: rgba(255,255,255,.44) }`。
        (AppStyle.liquid, Brightness.light) => const Color(0x70FFFFFF),
        // `:846` `body.dark #v-a .grp > .hd:hover { … .07 }`。
        (AppStyle.liquid, Brightness.dark) => const Color(0x12FFFFFF),
        // `:352` `#v-b .grp > .hd:hover { background: rgba(16,16,20,.05) }`。
        (AppStyle.frosted, Brightness.light) => const Color(0x0D101014),
        // `:895` `body.dark #v-b .grp > .hd:hover { … .06 }`。
        (AppStyle.frosted, Brightness.dark) => const Color(0x0FFFFFFF),
        // `:415` `#v-c .grp > .hd:hover { background: rgba(43,38,34,.05) }`。
        (AppStyle.clay, Brightness.light) => const Color(0x0D2B2622),
        // `:942` `body.dark #v-c .grp > .hd:hover { … rgba(245,240,235,.06) }`。
        (AppStyle.clay, Brightness.dark) => const Color(0x0FF5F0EB),
      };
}
