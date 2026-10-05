import 'package:flutter/material.dart';

/// 窗口材质。对应设置里的 `windowMaterial`。
///
/// 存进配置文件的字符串定下就不能改，否则用户已有的设置会失效。
enum WindowMaterial {
  mica('mica', 'Mica', '柔和云母', seeThrough: 0.18),
  micaAlt('mica-alt', 'Mica Alt', '层次云母', seeThrough: 0.18, layered: true),
  acrylic('acrylic', '亚克力', '磨砂玻璃', seeThrough: 0.45, blur: 3.2),
  acrylicThin(
    'acrylic-thin',
    '细亚克力',
    '更透亮的磨砂',
    seeThrough: 0.62,
    blur: 1.6,
  ),
  none('none', '纯色', '不使用特殊材质，性能最好');

  const WindowMaterial(
    this.id,
    this.label,
    this.description, {
    this.seeThrough = 0,
    this.blur = 0,
    this.layered = false,
  });

  /// 持久化用的标识，定下就不能改
  final String id;
  final String label;
  final String description;

  /// 设置页缩略图：材质薄片**透出多少桌面壁纸**（0 = 完全不透，如纯色）
  final double seeThrough;

  /// 设置页缩略图：磨砂程度（对背后壁纸做模糊的 sigma，0 = 不模糊）
  final double blur;

  /// 设置页缩略图：是否画出 Mica Alt 那道上下分层接缝
  final bool layered;

  static WindowMaterial fromId(String? id) => WindowMaterial.values.firstWhere(
        (m) => m.id == id,
        orElse: () => WindowMaterial.mica,
      );

  /// 材质预览色板（浅色 / 深色）
  Color previewFor(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    switch (this) {
      case WindowMaterial.mica:
        return dark ? const Color(0xFF202020) : const Color(0xFFF3F3F3);
      case WindowMaterial.micaAlt:
        return dark ? const Color(0xFF2B2B2B) : const Color(0xFFDADADA);
      case WindowMaterial.acrylic:
        return dark ? const Color(0xFF2A2A2A) : const Color(0xFFE8E8E8);
      case WindowMaterial.acrylicThin:
        return dark ? const Color(0xFF242424) : const Color(0xFFF0F0F0);
      case WindowMaterial.none:
        return dark ? const Color(0xFF141414) : const Color(0xFFFBFBFB);
    }
  }
}

/// 主题模式。对应设置里的 `themeMode`。
enum ThemeMode2 {
  system('system', '跟随系统'),
  light('light', '浅色'),
  dark('dark', '深色');

  const ThemeMode2(this.id, this.label);

  final String id;
  final String label;

  static ThemeMode2 fromId(String? id) => ThemeMode2.values.firstWhere(
        (m) => m.id == id,
        orElse: () => ThemeMode2.system,
      );

  ThemeMode get materialMode => switch (this) {
        ThemeMode2.system => ThemeMode.system,
        ThemeMode2.light => ThemeMode.light,
        ThemeMode2.dark => ThemeMode.dark,
      };
}

/// 主界面导航形态。对应设置里的 `navLayout`。
///
/// 两种形态展示**同一组**导航项（`widgets/nav_items.dart` 的 `kNavItems`），
/// 项目顺序、激活态、悬停反馈、运行红点、图标格尺寸全部共用同一套实现，
/// 差别只在排布方向：
///
///   - [dock]    底部悬浮 Dock（类 macOS，图标式，浮在内容之上）
///   - [sidebar] 常规左侧竖向侧边栏（图标 + 文字，贴左侧通高，占位不遮挡内容）
///
/// **持久化**：写进 `settings.json` 的 `appearance.navLayout`。
/// 配置里没有这个字段 → `fromId(null)` 回退到 [dock]，
/// 保证观感不变；不认识这个字段的配置读时会直接忽略它。
enum NavLayout {
  dock('dock', '悬浮 Dock', '底部居中悬浮，图标式，横向占用小'),
  sidebar('sidebar', '常规侧边栏', '左侧竖向排列，带文字标签，当前页一目了然');

  const NavLayout(this.id, this.label, this.description);

  /// 持久化用的标识
  final String id;
  final String label;
  final String description;

  static NavLayout fromId(String? id) => NavLayout.values.firstWhere(
        (m) => m.id == id,
        orElse: () => NavLayout.dock,
      );
}
