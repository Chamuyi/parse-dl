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
///   - 传进来的 [radius] 语义保留，实际半径 = `radius * surface.radiusScale`；
///   - [blur] 传 null 时用 `surface.blur`，显式传值仍然优先；
///   - `blur == 0` 的风格（陶土）**不套** [BackdropFilter] —— 实心面不该有模糊，
///     顺带省掉一层合成开销。
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// null = 用当前风格的模糊值；显式传值则覆盖风格（老调用点的语义）。
  final double? blur;
  final bool glow;
  final Color? overrideColor;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = 16,
    this.blur,
    this.glow = false,
    this.overrideColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final s = AppTheme.surfaceOf(context);
    final brightness = AppTheme.of(context).brightness;

    final r = radius * s.radiusScale;
    final b = blur ?? s.blur;
    final cardColor =
        overrideColor ?? s.resolveCardColor(c.surfaceCard, c.surfaceSolid);

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
        border: Border.all(
          // 内缘亮环：用一圈更亮的描边模拟玻璃边缘的折射高光
          color: s.rim
              ? s.rimColor(brightness)
              : (glow ? c.accentLine : c.line),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: s.shadowAlphaFor(brightness)),
            blurRadius: s.shadowBlur,
            offset: Offset(0, s.shadowY),
          ),
        ],
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
