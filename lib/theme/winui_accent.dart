import 'package:flutter/material.dart';

/// WinUI 风格下的强调色**三选一**（2026-10-19 用户裁定）。
///
/// 背景：用户要求「照抄其他 Flutter 项目的界面风格」，参考 `bdlukaa/fluent_ui`
/// （BSD-3-Clause）。强调色给三档由用户自选 —— 既保留 WinUI 的原生感，
/// 又不强迫所有人接受同一个蓝。
///
/// 持久化写进 `settings.json` 的 `appearance.winUiAccent`；
/// 旧配置没有这个字段 → 回退 [WinUiAccent.windows]（WinUI 官方蓝）。
enum WinUiAccent {
  /// WinUI3 官方默认蓝 `#0078D4`（深色亮一档 `#4CC2FF`）。
  windows('windows', 'Windows 蓝', 'WinUI3 官方强调色，最像系统自带应用'),

  /// 紫罗兰 —— 本项目改造前的品牌色，给习惯旧观感的人留一条路。
  violet('violet', '紫罗兰', '保留改造前的紫色系，与旧观感衔接'),

  /// 跟随 Windows「个性化 → 颜色」里设置的强调色。
  ///
  /// 读取方式：`HKCU\\Software\\Microsoft\\Windows\\DWM\\ColorizationColor`。
  /// **读失败一律回退到 [WinUiAccent.windows]**，绝不因为读不到系统色就不显示。
  system('system', '跟随系统', '读取 Windows 个性化里的强调色'),
  ;

  const WinUiAccent(this.id, this.label, this.description);

  /// 持久化用的标识，定下就不能改
  final String id;
  final String label;
  final String description;

  static WinUiAccent fromId(String? id) => WinUiAccent.values.firstWhere(
        (a) => a.id == id,
        orElse: () => WinUiAccent.windows,
      );

  /// 该系统强调色是否已解析出具体颜色（[WinUiAccent.system] 专用）。
  static Color? _systemColor;
  static Color? get resolvedSystemColor => _systemColor;

  /// 注入系统强调色（由启动流程 `readSystemAccentColor()` 读注册表后调用）。
  ///
  /// 传 null 表示读取失败 —— 此时 [WinUiAccent.system] 回退到官方蓝。
  /// **不是测试专用**：生产路径 `main.dart` 就要调它。
  static void setSystemColor(Color? c) => _systemColor = c;

  /// 取这套强调色在指定明暗下的三个关键色：主色 / 文本色 / 压在主色上的前景色。
  ///
  /// **为什么是三个而不是一个**：浅色主题的 accent 要够深（白字压上去才有
  /// 对比度），深色主题要够亮（配深字）。这条方向是 2026-10-16 真机踩出来的
  /// —— 旧实现一律白字压 accent，深色的 `#38BDF8` 上白字只有 2.14。
  ({Color accent, Color accentText, Color onAccent}) colorsFor(
    Brightness brightness,
  ) {
    final dark = brightness == Brightness.dark;
    switch (this) {
      case WinUiAccent.windows:
        return dark
            ? (
                accent: const Color(0xFF4CC2FF),
                accentText: const Color(0xFF7FD4FF),
                onAccent: const Color(0xFF00304D),
              )
            : (
                accent: const Color(0xFF0078D4),
                accentText: const Color(0xFF005A9E),
                onAccent: const Color(0xFFFFFFFF),
              );
      case WinUiAccent.violet:
        return dark
            ? (
                accent: const Color(0xFF818CF8),
                accentText: const Color(0xFFA5B4FC),
                onAccent: const Color(0xFF12122B),
              )
            : (
                accent: const Color(0xFF4F46E5),
                accentText: const Color(0xFF4338CA),
                onAccent: const Color(0xFFFFFFFF),
              );
      case WinUiAccent.system:
        final base = _systemColor;
        // 读不到系统色 → 与「Windows 蓝」完全一致（不是近似，是同一份值）。
        if (base == null) {
          return WinUiAccent.windows.colorsFor(brightness);
        }
        return _deriveFromSystem(base, dark);
    }
  }

  /// 从系统强调色派生三色。
  ///
  /// 系统色只有一个值，而 WinUI 需要「主色 + 可读前景 + 文本色」。这里的
  /// 规则与官方 Windows 一致：**色相不动，只按明暗调亮度** ——
  /// 深色主题把它提亮到能配深字，浅色主题压深到能配白字。
  static ({Color accent, Color accentText, Color onAccent}) _deriveFromSystem(
    Color base,
    bool dark,
  ) {
    final hsl = HSLColor.fromColor(base);
    if (dark) {
      final a = hsl.withLightness(0.68).withSaturation(
            hsl.saturation.clamp(0.35, 0.85),
          );
      return (
        accent: a.toColor(),
        accentText: a.withLightness(0.80).toColor(),
        onAccent: a.withLightness(0.14).toColor(),
      );
    }
    final a = hsl.withLightness(0.38).withSaturation(
          hsl.saturation.clamp(0.45, 0.95),
        );
    return (
      accent: a.toColor(),
      accentText: a.withLightness(0.30).toColor(),
      onAccent: const Color(0xFFFFFFFF),
    );
  }
}
