import 'dart:io';

import 'package:flutter/material.dart';

import '../models/settings.dart';
import '../theme/app_theme.dart';

/// 窗口最底层的底色与背景图。
///
/// ### 2026-10-19 大瘦身（用户裁定「窗口材质怎么没删」）
///
/// 曾经这里有一整套「按材质画窗口底」的绘制器：`_StyleBackdropWash` +
/// `_BackdropPainter` + `_MaterialSheetPainter`（含磨砂颗粒纹理、Mica Alt
/// 分层接缝、四种材质各自的底色与透光率），约 280 行。
///
/// 材质只剩 Mica 一档之后，那一整套**全部没有对象了**：微软官方文档规定
/// 长驻窗口的底由 DWM 画一层 Mica（`DWMSBT_MAINWINDOW`），应用侧不该再画
/// 自己的材质 —— 自己画反而会和系统那层打架。
///
/// 现在只剩两件事：
///   1. 铺一层**不透明**底（Mica 在旧系统/远程桌面下不生效时不至于黑窗）；
///   2. 叠用户导入的背景图（那是用户的显式选择，保留）。
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
    final t = AppTheme.of(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        // ① 底：永远铺一层不透明色。自定义色调优先（用户显式选择），
        //    否则用当前风格的窗口实色。
        ColoredBox(
          color: appearance.customTint
              ? _tintColor(t.colors, appearance.tintColor, brightness)
              : AppColors.solidFor(brightness, style: t.style),
        ),

        // ② 用户导入的背景图
        if (appearance.backgroundImage.isNotEmpty)
          Opacity(
            opacity: appearance.backgroundImageOpacity.clamp(0.0, 1.0),
            child: _BackgroundImage(path: appearance.backgroundImage),
          ),
      ],
    );
  }

  /// 自定义色调：强调色与主题底色按比例混合（不是直接铺强调色）。
  ///
  /// 直接铺满会在深色下变成一大片刺眼的亮色，浅色文字压上去几乎看不见 ——
  /// 这里踩过坑，所以走 [AppColors.tintFor]。
  Color _tintColor(AppColors c, String hex, Brightness brightness) {
    final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
    if (v == null) return AppColors.solidFor(brightness);
    return AppColors.tintFor(Color(0xFF000000 | v), brightness);
  }
}

/// 背景图。用 Image.file 直接读本地文件。
class _BackgroundImage extends StatelessWidget {
  final String path;

  const _BackgroundImage({required this.path});

  @override
  Widget build(BuildContext context) {
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
}
