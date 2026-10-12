import 'package:flutter/material.dart';

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
