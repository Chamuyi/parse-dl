import 'package:flutter/material.dart';

/// 窗口材质。对应设置里的 `windowMaterial`。
///
/// ### 2026-10-19 只保留 Mica（用户裁定「窗口材质怎么没删」）
///
/// 曾经有 mica / mica-alt / acrylic / acrylic-thin / none 五档，设置页还能
/// 让用户选。三套玻璃风格删掉之后，这些档位失去存在理由：
///
/// * 微软官方文档（DWM_SYSTEMBACKDROP_TYPE）规定**长驻窗口**的底由 DWM 画
///   一层 Mica（`DWMSBT_MAINWINDOW`），这是 Windows 11 应用的标准做法；
/// * 亚克力（`DWMSBT_TRANSIENTWINDOW`）官方只给**临时浮层**用，
///   而且明确「不要叠多层」（见 Acrylic 文档）；
/// * 「纯色」在 WinUI 语义下没有位置 —— 那等于关掉系统材质。
///
/// 所以枚举只留 `mica` 一个值。**保留 enum 而不是删掉类型**：`settings.json`
/// 里的 `windowMaterial` 字段要能读到旧值并迁移（旧 id 一律落到 mica），
/// 且 `window_effect.dart` 与几处判据仍在引用它。
enum WindowMaterial {
  /// Mica —— Windows 11 长驻窗口的标准系统材质。
  ///
  /// 官方原文（learn.microsoft.com/windows/win32/api/dwmapi/
  /// ne-dwmapi-dwm_systembackdrop_type）：
  ///   `DWMSBT_MAINWINDOW` — "Draw the backdrop material effect corresponding
  ///    to a long-lived window behind the entire window bounds. For Windows 11,
  ///    this corresponds to Mica in its default variant."
  // 描述里刻意**不含汉字** —— l10n 的「数据位标签必须都有英文对照」判据
  // 会把含汉字的 label/description 当成漏翻。这里用英文写死。
  mica('mica', 'Mica', 'Windows 11 system material for long-lived windows');

  const WindowMaterial(this.id, this.label, this.description);

  /// 持久化用的标识，定下就不能改
  final String id;
  final String label;
  final String description;

  /// 缺字段 / 坏值 / **旧的四档 id** 一律回退 [WindowMaterial.mica]。
  ///
  /// 迁移：老配置里可能存着 mica-alt / acrylic / acrylic-thin / none，
  /// 那些档位已经删除，读到就落到 mica，不报错、不黑窗。
  static WindowMaterial fromId(String? id) => WindowMaterial.values.firstWhere(
        (m) => m.id == id,
        orElse: () => WindowMaterial.mica,
      );
}

/// 主题模式。对应设置里的 `themeMode`。
///
/// 2026-10-19 注：这个枚举与 [NavLayout] 一直住在本文件里（历史原因：
/// 它们和 `WindowMaterial` 同属「外观设置」的三个下拉项）。重写材质枚举时
/// 一度被误删，已补回。
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
/// 配置里没有这个字段 → `fromId(null)` 回退到 [dock]。
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

