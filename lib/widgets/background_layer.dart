import 'dart:io';

import 'package:flutter/material.dart';

import '../models/settings.dart';
import '../theme/app_style.dart';
import '../theme/app_theme.dart';
import '../theme/style_backdrop.dart';
import '../theme/window_material.dart';

/// 窗口最底层的底色与背景图。
///
/// **关键不变量：必须始终铺一层** —— Mica / 亚克力在 Win10 / 旧 Win11 / 远程桌面下不生效，
/// 这种情况下**不铺任何东西** = 看到 Windows 默认的黑色（用户截图反馈）。
///
/// 策略（永远不返回 null）：
///   1. 用户选 Mica / 亚克力时 —— 铺**该风格的背景底**，再叠一层半透明主题底色
///      （85% alpha），让 Mica 透出来。如果 Mica 没生效，底层的风格背景也可见。
///   2. 用户选纯色材质   —— 铺**不透明**主题实色。
///   3. 用户开自定义色调 —— 铺与强调色混合后的色调（深色 / 浅色根据 brightness）。
///
/// **S3 · 风格背景**：Mica 路径的「底」现在按风格画 —— liquid 是三层 radial
/// 光晕 + 150° 线性渐变，frosted 是 165° 冷灰线性，clay 是 168° 暖米线性
/// （取值逐字节取证自 `tools/ui/_redesign/preview/app.css`，见 [StyleBackdrop]）。
/// **风格从哪拿**：本组件在 `AppTheme` 子树内（`app.dart` 的 `AppTheme` 包住
/// `_AppShell`，背景层挂在它下面），直接 `AppTheme.of(context).style` 取，
/// `app.dart` 零改动。
///
/// **历史**：这里曾经在顶部画过一道 4px 的品牌色渐变带（透明 → accent）。
/// 但 TitleBar 只有 85% 不透明，渐变会从标题栏底下透出来，在纯灰界面上形成
/// 一条**横贯窗口顶部的蓝色细线**，用户反馈为「顶栏有一条奇怪的线条」。
/// 已移除。品牌色现在只出现在标题栏左侧 Logo 上，不再铺满整窗宽度。
class BackgroundLayer extends StatelessWidget {
  final AppearanceSettings appearance;
  final Brightness brightness;

  const BackgroundLayer({
    super.key,
    required this.appearance,
    required this.brightness,
  });

  @override
  Widget build(BuildContext context) {
    final tint = _resolveTint(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        // ① 底：永远要铺，让 Mica 没生效时也不会黑窗。
        //    纯色材质 / 自定义色调是实色 ColoredBox；Mica 路径是
        //    风格背景（光晕 + 线性渐变）+ 半透明调色层。
        if (tint == null)
          _StyleBackdropWash(backdrop: StyleBackdrop.of(_styleOf(context), brightness))
        else
          ColoredBox(color: tint),

        // ② 用户导入的背景图
        if (appearance.backgroundImage.isNotEmpty)
          Opacity(
            opacity: appearance.backgroundImageOpacity.clamp(0.0, 1.0),
            child: _BackgroundImage(path: appearance.backgroundImage),
          ),
      ],
    );
  }

  /// 当前风格。`AppTheme.of` 带 assert（未挂载时红字报错），测试里
  /// BackgroundLayer 一律包在 AppTheme 内，行为与改造前一致。
  AppStyle _styleOf(BuildContext context) => AppTheme.of(context).style;

  /// 计算底色。返回 null = 用风格背景绘制（Mica / 亚克力路径 —— 绘制器
  /// 永不空画，[StyleBackdrop.linear] 恒有值，「永远铺一层底」在绘制器内兑现）；
  /// 非 null = 铺这个实色：
  /// - 纯色材质 → 不透明主题实色（**按风格**取，见 [AppColors.solidFor]）
  /// - 自定义色调 → 强调色与主题底色混合后的色调
  ///
  /// 浅色模式不要用 alpha=0.25（实测几乎透明 → 看到 Win 默认黑底）。
  Color? _resolveTint(BuildContext context) {
    if (appearance.windowMaterial == WindowMaterial.none) {
      // 纯色：完全不透明。**传风格** —— 三套风格连窗口底都不同，
      // 否则「换风格」在整窗最大的一块面上看不出任何变化。
      return AppColors.solidFor(brightness, style: _styleOf(context));
    }
    if (appearance.customTint) {
      final hex = appearance.tintColor.replaceFirst('#', '');
      final value = int.tryParse(hex, radix: 16);
      if (value != null) {
        final tint = Color(0xFF000000 | value);
        // tintFor 内部已经处理了与主题底色混合，并控制了不透明度
        return AppColors.tintFor(tint, brightness);
      }
    }
    // Mica / 亚克力材质：null = 交给风格背景绘制器（渐变打底 + 85% 调色层）
    return null;
  }
}

/// 按风格令牌绘制窗口底：风格渐变打底 + 85% 主题调色层（保 Mica 语义）。
///
/// 调色层沿用改造前同一条取值：`solidFor(brightness).withValues(alpha: 0.85)`
/// —— Mica 生效时透出 15% 窗口材质，Mica 没生效时这层保证界面可见、
/// 风格渐变仍隐约透出（三套渐变端点差都在 #10 以上，15% 透光率下可辨）。
class _StyleBackdropWash extends StatelessWidget {
  final StyleBackdrop backdrop;

  const _StyleBackdropWash({required this.backdrop});

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final brightness = theme.brightness;
    // **按风格取底色**（2026-10-16）。此前这里不传 style，于是三套风格的
    // 窗口底走的是同一个 frosted 值 —— 「三套风格」在最大的一块面（整个窗口
    // 背景）上根本没有区别，用户看到的就是「换风格没感觉」。
    final wash = AppColors.solidFor(brightness, style: theme.style)
        .withValues(alpha: 0.85);

    return Stack(
      fit: StackFit.expand,
      children: [
        // 风格背景：线性渐变打底 + 光晕（永远有这一层）
        CustomPaint(painter: _BackdropPainter(backdrop: backdrop)),

        // 半透明主题调色层（85%，与改造前 Mica 路径同色同 alpha）
        ColoredBox(color: wash),
      ],
    );
  }
}

/// 按 [StyleBackdrop] 画线性渐变 + radial 光晕。
///
/// CSS 多重背景**第一层画在最上面**：`glows[0]` 是 CSS 第一条 radial，
/// 所以光晕按列表**倒序**画（最后画 glows[0]，让它盖在其它光晕上面）。
class _BackdropPainter extends CustomPainter {
  final StyleBackdrop backdrop;

  _BackdropPainter({required this.backdrop});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // ① 线性渐变打底（CSS background 的最底层）
    final linear = backdrop.linear;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: linear.begin,
          end: linear.end,
          colors: linear.stops,
          stops: linear.evenlySpaced,
        ).createShader(rect),
    );

    // ② radial 光晕。CSS 的 `1100px 700px` 是预览稿窗口尺寸下量出来的，
    //    桌面端按窗口对角线等比缩放，避免小窗溢出 / 大窗缩成一团。
    final halfDiag = size.longestSide / 2;
    for (final glow in backdrop.glows.reversed) {
      final radius = glow.radiusFactor * halfDiag * 2;
      final center = Offset(
        (glow.center.x + 1) / 2 * size.width,
        (glow.center.y + 1) / 2 * size.height,
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [glow.color, glow.color.withValues(alpha: 0.0)],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter oldDelegate) =>
      oldDelegate.backdrop != backdrop;

  // 测试的负控制用「painter 的确定性指纹」判断背景是否真的随风格变化：
  // 不覆写的话 Object.toString 带 identityHash，三套永远不同，那条判据会恒真。
  @override
  String toString() =>
      '_BackdropPainter(glowCount: ${backdrop.glowCount}, '
      'linear: ${backdrop.linear.stops}, begin: ${backdrop.linear.begin})';
}

/// 背景图。用 Image.file 直接读本地文件。
class _BackgroundImage extends StatelessWidget {
  final String path;

  const _BackgroundImage({required this.path});

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    return Image.file(
      file,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
      // 大图先解码到合理尺寸，避免背景图占满内存
      cacheWidth: 2200,
    );
  }
}
