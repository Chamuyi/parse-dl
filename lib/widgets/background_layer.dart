import 'dart:io';

import 'package:flutter/material.dart';

import '../models/settings.dart';
import '../theme/app_theme.dart';
import '../theme/window_material.dart';

/// 窗口最底层的底色与背景图。
///
/// **关键不变量：必须始终铺一层** —— Mica / 亚克力在 Win10 / 旧 Win11 / 远程桌面下不生效，
/// 这种情况下**不铺任何东西** = 看到 Windows 默认的黑色（用户截图反馈）。
///
/// 策略（永远不返回 null）：
///   1. 用户选 Mica / 亚克力时 —— 铺一个**半透明**主题底色（约 75% alpha），
///      让 Mica 透出来。如果 Mica 没生效，半透明底色也能让界面可见。
///   2. 用户选纯色材质   —— 铺**不透明**主题实色。
///   3. 用户开自定义色调 —— 铺与强调色混合后的色调（深色 / 浅色根据 brightness）。
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
    final tint = _resolveTint();

    return Stack(
      fit: StackFit.expand,
      children: [
        // ① 底色调：永远要铺，让 Mica 没生效时也不会黑窗
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

  /// 计算底色。**永远不返回 null**：
  /// - 纯色材质 → 不透明主题实色
  /// - 自定义色调 → 强调色与主题底色混合后的色调
  /// - Mica / 亚克力材质（生效或未生效都安全）→ 半透明主题底色（保留 Mica 质感，
  ///   Mica 没生效时仍能让界面可见）
  Color _resolveTint() {
    if (appearance.windowMaterial == WindowMaterial.none) {
      // 纯色：完全不透明
      return AppColors.solidFor(brightness);
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
    // Mica / 亚克力材质：半透明主题底色（保证 Mica 没生效时也不黑）
    // 透明度约 75% —— Mica 生效时透出 25% 纹理（质感），Mica 没生效时仍清晰可见
    // 注意：浅色模式不要用 alpha=0.25（实测几乎透明 → 看到 Win 默认黑底）
    return AppColors.solidFor(brightness).withValues(alpha: 0.85);
  }
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
