import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_style.dart';
import '../theme/app_theme.dart';

/// 毛玻璃卡片。
///
/// 关键点：用 [BackdropFilter] 对**卡片背后的内容**做真高斯模糊，
/// 这是 egui / Slint 这类立即模式 GUI 做不到的（它们没法采样背后像素），
/// 也是选择 Flutter 而不是别的纯 Rust 方案的核心原因。
///
/// 材质由 [AppTheme.surfaceOf] 给的 [AppSurface] 驱动，三套风格共用这一个组件：
///   - [radius] 是**档位**（[AppRadius]），像素由当前风格决定（S4）；
///   - [blur] 传 null 时用 `surface.blur`，显式传值仍然优先；
///   - `blur == 0` 的风格（陶土）**不套** [BackdropFilter] —— 实心面不该有模糊，
///     顺带省掉一层合成开销；
///   - **边框 / 投影 / 悬停底色都随风格变**（S4）：取值逐项取证自
///     `tools/ui/_redesign/preview/app.css`，见 [AppStyle] 上的那三组扩展。
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// 圆角**档位**（不再是像素）。
  ///
  /// 改造前这里是 `double radius = 16`，实际半径 = `radius * radiusScale`，
  /// 三套拿到 20 / 16 / 16 —— 与预览稿的 **20 / 14 / 16** 不符。现在语义改为
  /// 档位，像素查 `AppStyle.radiusOf`。已核实显式传 `radius` 的调用点是 **0 处**，
  /// 所以这次语义替换是零迁移。
  final AppRadius radius;

  /// null = 用当前风格的模糊值；显式传值则覆盖风格（老调用点的语义）。
  final double? blur;
  final bool glow;
  final Color? overrideColor;

  /// 悬停态：底色叠上该风格的悬停色。
  ///
  /// 改造前三套风格共用 `c.surfaceCardHover`，**而浅色三套那个值恰好完全相同**
  /// （都是白 78%）—— 浅色下悬停反馈看不出风格。现在按各套 CSS 的 `:hover`
  /// 规则取色并叠在卡片底色上（`Color.alphaBlend`）：叠加而不是替换，因为
  /// CSS 里那条规则是铺在已有面上的覆盖层。
  final bool hovered;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = AppRadius.card,
    this.blur,
    this.glow = false,
    this.overrideColor,
    this.hovered = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final c = t.colors;
    final s = t.surface;
    final style = t.style;
    final brightness = t.brightness;

    final r = style.radiusOf(radius);
    final b = blur ?? s.blur;
    final baseColor =
        overrideColor ?? s.resolveCardColor(c.surfaceCard, c.surfaceSolid);
    final cardColor =
        hovered ? Color.alphaBlend(style.hoverColor(brightness), baseColor) : baseColor;

    // 边框：四边同色（`--rim`）。液体玻璃另有一条**更亮的顶边高光**，但它在
    // CSS 里是 `box-shadow: inset 0 1px 0 …` 而**不是** border —— 所以这里
    // 用内阴影表达（见 [StyleBorder] 类文档里那段最小复现：把顶边写成另一种
    // 颜色的 `Border` 会让 `isUniform=false`，带圆角时子内容整片消失）。
    // [glow] 仍能把三边换成强调色描边（老调用点的语义）。
    final rim = style.cardBorderOf(c, brightness);
    final border = glow
        ? Border.all(color: c.accentLine, width: 1)
        : rim.toBorder();

    // 顶边 1px 高光：内阴影（`inset 0 1px 0`）在 Flutter 里没有直接对应物，
    // 用「紧贴顶边、只向下扩散 1px 的浅色内描边」近似 —— 画在内容**下面**，
    // 因此不会盖住子内容。只有 [StyleBorder.hasTopHighlight] 的风格才画。
    final topHighlight = rim.hasTopHighlight
        ? [
            BoxShadow(
              color: rim.top,
              offset: const Offset(0, 1),
              blurRadius: 0,
              spreadRadius: 0,
            ),
          ]
        : const <BoxShadow>[];

    final body = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: s.gradient ? null : cardColor,
        gradient: s.gradient
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [s.gradientTop(cardColor), cardColor],
              )
            : null,
        borderRadius: BorderRadius.circular(r),
        border: border,
        boxShadow: [...topHighlight, ...style.cardShadows(brightness)],
      ),
      child: child,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
      // 实心面（blur == 0）不挂 BackdropFilter：糊一层什么都看不出来，
      // 白付一次离屏合成的代价。
      child: b > 0
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: b, sigmaY: b),
              child: body,
            )
          : body,
    );
  }
}

/// 浮动层 —— 对应 `.app-float`（底部 Dock、弹出面板、对话框）。
/// 比普通卡片更不透明、阴影更重，保证浮在内容之上时依然清晰。
class AppFloat extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  const AppFloat({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 16,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: c.surfaceFloat,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: c.line, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 50,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 渐变标题 —— 对应 `.neon-title`
class GradientTitle extends StatelessWidget {
  final String text;
  final double size;
  final FontWeight weight;

  const GradientTitle(
    this.text, {
    super.key,
    this.size = 24,
    this.weight = FontWeight.w600,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        colors: [c.accentText, c.accent],
      ).createShader(bounds),
      child: Text(
        text,
        style: TextStyle(
          fontSize: size,
          fontWeight: weight,
          color: Colors.white,
          letterSpacing: -0.3,
        ),
      ),
    );
  }
}
