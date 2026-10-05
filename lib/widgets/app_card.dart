import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 毛玻璃卡片。
///
/// 关键点：用 [BackdropFilter] 对**卡片背后的内容**做真高斯模糊，
/// 这是 egui / Slint 这类立即模式 GUI 做不到的（它们没法采样背后像素），
/// 也是选择 Flutter 而不是别的纯 Rust 方案的核心原因。
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;
  final bool glow;
  final Color? overrideColor;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = 16,
    this.blur = 24,
    this.glow = false,
    this.overrideColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: overrideColor ?? c.surfaceCard,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: glow ? c.accentLine : c.line, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: c.textStrong.computeLuminance() > 0.5 ? 0.07 : 0.30,
                ),
                blurRadius: 32,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: child,
        ),
      ),
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
