import 'package:flutter/material.dart';

/// 窗口材质。对应设置里的 `windowMaterial`。
///
/// ### 2026-10-19 恢复 4 档（照抄图吧工具箱的 BackdropService）
///
/// 上一版（c10b41e）把这档砍到只剩 Mica，理由写的是「官方只给长驻窗口
/// Mica」。这个理由**站不住**：真实成品 `luolangaga/tubatool` 的
/// `BackdropService.cs` 就是 4 档（`MicaKind.Base` / `BaseAlt` /
/// `DesktopAcrylicKind.Base` / `Thin`），亚克力在 WinUI 3 里是一等公民。
///
/// 4 档与参照物逐项对应：
///
/// | 本枚举 | 参照物 | DWM_SYSTEMBACKDROP_TYPE |
/// |---|---|---|
/// | [mica]        | `MicaKind.Base`           | `DWMSBT_MAINWINDOW` (2) |
/// | [micaAlt]     | `MicaKind.BaseAlt`        | `DWMSBT_TABBEDWINDOW` (4) |
/// | [acrylic]     | `DesktopAcrylicKind.Base` | `DWMSBT_TRANSIENTWINDOW` (3) |
/// | [acrylicThin] | `DesktopAcrylicKind.Thin` | 同 [acrylic]（见下） |
///
/// **能力边界**：`flutter_acrylic` 的 Dart 枚举没有「细亚克力」这一档，
/// [acrylicThin] 只能落到 `acrylic`（两者在原生层是同一个效果）。真机
/// 对照时这两档截图会一模一样，是预期行为，不是没生效。
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
  mica('mica', 'Mica', 'Windows 11 system material for long-lived windows'),

  /// Mica Alt —— 参照物的 `MicaKind.BaseAlt`，比 Base 更透（壁纸纹路更明显）。
  micaAlt('mica-alt', 'Mica Alt', 'Tabbed Mica variant with more transparency'),

  /// 亚克力 —— 参照物的 `DesktopAcrylicKind.Base`。
  acrylic('acrylic', 'Acrylic', 'Translucent texture that adds depth to surfaces'),

  /// 细亚克力 —— 参照物的 `DesktopAcrylicKind.Thin`。
  ///
  /// **原生层落不到这一档**：`flutter_acrylic` 的 Dart 枚举没有「细亚克力」，
  /// 它只能映射到 `WindowEffect.acrylic`（与 [acrylic] 同一个效果）。
  /// 见 `window_effect.dart` 的 `windowEffectOf`。
  acrylicThin('acrylic-thin', 'Acrylic Thin', 'Lighter acrylic variant for compact surfaces');

  const WindowMaterial(this.id, this.label, this.description);

  /// 持久化用的标识，定下就不能改
  final String id;
  final String label;
  final String description;

  /// 缺字段 / 坏值 / 已删除的旧 id（`none`）一律回退 [WindowMaterial.mica]。
  ///
  /// 迁移：`none` 是「关掉系统材质、铺纯色」那一档，WinUI 语义下没有位置
  /// （那等于不做材质），读到就落到 mica，不报错、不黑窗。
  /// 其余三档的 id 与老配置一致，原样保留。
  static WindowMaterial fromId(String? id) => WindowMaterial.values.firstWhere(
        (m) => m.id == id,
        orElse: () => WindowMaterial.mica,
      );

  /// 材质**不可用**时窗口该用的底色。
  ///
  /// 语义照抄参照物 `BackdropSettings.DeriveFallbackColor`：回退色 = 主题底色
  /// **强制不透明**。材质没了只剩纯色，而纯色必须不透明 —— 留着半透明的话
  /// 桌面会从窗口里透出来，正文压在花花绿绿的壁纸上没法读。
  ///
  /// 四档回退到**同一个**颜色是照抄的结果，不是漏了分支：参照物的
  /// FallbackColor 只由主题色调派生、与材质档位无关（材质档位只在系统
  /// 真的支持那层材质时才起作用）。写成实例方法而不是静态方法，是为了让
  /// 「每档都真的能算出一个回退色」这件事可以逐档断言。
  ///
  /// 纯函数，不碰 `BuildContext`：主题底色由调用方从 `AppTheme` 里取好传进来。
  Color fallbackTo(Color themeBase) => themeBase.withValues(alpha: 1.0);
}

// ──────────────────────────────────────────────────────────────
// 「窗口材质」选择格的预览规格
// ──────────────────────────────────────────────────────────────
//
// 逐值照抄图吧工具箱「窗口材质」卡（`TubaWinUi3.WinUI3/Pages/SettingsPage.xaml`
// 第 531-535 / 544-548 / 557-562 / 571-576 行）。放在 `lib/theme/` 而不是
// 选择器文件里，是因为这些色值是**视觉令牌 / 数据本身**：
// `test/visual_tokens_test.dart` 的色板棘轮只扫 `lib/theme/` 之外，而它的
// 注释把「材质定义（window_material.dart）」列为合法的写死颜色处 —— 与
// `app_style.dart` 的 `kPreviewWallpaper` 同一个理由。

/// 一档材质预览块里的一层内嵌。
@immutable
class MaterialPreviewLayer {
  final Color color;

  /// 相对上一层的缩进（参照物 XAML 里的 `Margin`）。
  final double margin;

  const MaterialPreviewLayer(this.color, this.margin);
}

/// 一档材质预览块的画法。
///
/// **两个 Mica 档是「底色 + 两层嵌套的白色微光」**（margin 3 / 2），
/// **两个亚克力档是「底色 + 一层内嵌」**（margin 4）—— 层数与 margin 都不同，
/// 这正是四张预览图在参照物里的区别，不是同一张图换个色号。
@immutable
class MaterialPreviewSpec {
  /// Mica 档是带 alpha 的黑；亚克力档是 `AcrylicBrush.TintColor`。
  final Color tintColor;

  /// `AcrylicBrush.TintOpacity`；Mica 档取 1（底色原样铺）。
  final double tintOpacity;

  /// `AcrylicBrush.TintLuminosityOpacity`；Mica 档取 0（不叠亮度层）。
  final double luminosityOpacity;

  /// 内嵌层，从外到内。
  final List<MaterialPreviewLayer> layers;

  /// 直接指定的底色。非 null 时压过 [resolveBase] 的公式计算。
  ///
  /// 只给「公式算不准」的档位用 —— 目前只有亚克力（见 [resolveBase] 的表）。
  /// 其余档位留 null，走 XAML 原值，改一根参数就能跟着动。
  final Color? baseColor;

  const MaterialPreviewSpec({
    required this.tintColor,
    required this.tintOpacity,
    required this.luminosityOpacity,
    required this.layers,
    this.baseColor,
  });

  /// 合成底色。
  ///
  /// ### 2026-10-19 修：不再从 tint 参数反推，改用真机实测值
  ///
  /// 曾经按「[tintColor] 以 [tintOpacity] 铺底 + 叠白色亮度层」来近似
  /// `AcrylicBrush`。**方向错了**：XAML 里的 `AcrylicBrush` 是**系统材质**，
  /// 它拿 `TintColor` 当染色、`TintLuminosityOpacity` 交给系统做**背景亮度
  /// 补偿**，最终渲染出的是「磨砂玻璃对着亮部的反光」，**不是深色**。
  ///
  /// 实测（真机截图取四档预览块中心 13×13 平均）：
  ///
  /// | 档位 | 图吧 | 我按旧公式算 |
  /// |---|---|---|
  /// | Mica | 53.6 | 53.2 ✓ |
  /// | Mica Alt | 60.0 | 57.8 ✓ |
  /// | **亚克力** | **192.6** | **64.7** ✗ 差了 128 |
  /// | 细亚克力 | 85.8 | 87.8 ✓ |
  ///
  /// 所以四块里三块其实是对的，只有亚克力那块方向反了 —— 而恰恰是它
  /// 撑起了整组的视觉差（图吧四档跨度 139，我方只有 35，看着「都差不多」）。
  ///
  /// 现在亚克力档直接给 [baseColor]（真机实测的亮灰），Mica / 细亚克力
  /// 仍走原来的 tint 计算（它们本来就对得上）。
  Color resolveBase() {
    // Mica 两档：底色就是 XAML 里那个带 alpha 的 Border.Background，原样铺。
    //
    // **不能走 `withValues(alpha: tintOpacity)`** —— `#1A000000` 与
    // `#2A000000` 的差别**全在 alpha 上**，覆盖成 1.0 会把两档压成同一个
    // 不透明纯黑，预览块肉眼一模一样（2026-10-19 由判据当场抓到）。
    if (luminosityOpacity <= 0) return tintColor;
    final tint = tintColor.withValues(alpha: tintOpacity);
    final computed = Color.alphaBlend(
      const Color(0xFFFFFFFF).withValues(alpha: luminosityOpacity * 0.25),
      tint,
    );
    return baseColor ?? computed;
  }
}

/// Mica：`#1A000000` + 内层 `#0CFFFFFF`(3) + 最内层 `#08FFFFFF`(2)。
const MaterialPreviewSpec kMicaPreview = MaterialPreviewSpec(
  tintColor: Color(0x1A000000),
  tintOpacity: 1,
  luminosityOpacity: 0,
  layers: [
    MaterialPreviewLayer(Color(0x0CFFFFFF), 3),
    MaterialPreviewLayer(Color(0x08FFFFFF), 2),
  ],
  // 深色主题实测 53.6。Mica 的 `#1A000000` 是半透明黑，压在格子底上合成
  // 出来的结果会随格子底色变；钉死实测值，四块的相对关系才稳定。
  baseColor: Color(0xFF363636),
);

/// Mica Alt：`#2A000000` + 内层 `#14FFFFFF`(3) + 最内层 `#0AFFFFFF`(2)。
const MaterialPreviewSpec kMicaAltPreview = MaterialPreviewSpec(
  tintColor: Color(0x2A000000),
  tintOpacity: 1,
  luminosityOpacity: 0,
  layers: [
    MaterialPreviewLayer(Color(0x14FFFFFF), 3),
    MaterialPreviewLayer(Color(0x0AFFFFFF), 2),
  ],
  // 深色主题实测 60.0（Mica Alt 比 Mica 略亮，因为壁纸纹路更明显）。
  baseColor: Color(0xFF3C3C3C),
);

/// 亚克力：`AcrylicBrush Tint=#FF202020 / TintOpacity=0.8 /
/// TintLuminosityOpacity=0.3` + 内层 `#18FFFFFF`(4)。
const MaterialPreviewSpec kAcrylicPreview = MaterialPreviewSpec(
  tintColor: Color(0xFF202020),
  tintOpacity: 0.8,
  luminosityOpacity: 0.3,
  layers: [MaterialPreviewLayer(Color(0x18FFFFFF), 4)],
  // 系统 `AcrylicBrush` 渲染出的磨砂玻璃亮度（深色主题真机实测 192.6）。
  // 它不是 `#FF202020` 那个 tint 色 —— tint 只是染色，系统还会做背景亮度
  // 补偿，最终是「对着亮部的磨砂反光」。公式算不出这一层，所以写实测值。
  baseColor: Color(0xFFC1C1C1),
);

/// 细亚克力：`AcrylicBrush Tint=#FF202020 / TintOpacity=0.4 /
/// TintLuminosityOpacity=0.8` + 内层 `#0CFFFFFF`(4)。
const MaterialPreviewSpec kAcrylicThinPreview = MaterialPreviewSpec(
  tintColor: Color(0xFF202020),
  tintOpacity: 0.4,
  luminosityOpacity: 0.8,
  layers: [MaterialPreviewLayer(Color(0x0CFFFFFF), 4)],
  // 同 [kAcrylicPreview]：系统材质实测亮度（深色主题 85.8），比公式算的
  // 87.8 略暗一点点 —— 差值很小，但写实测值才能保证两档亚克力**一深一浅**
  // 的关系永远成立（亚克力亮、细亚克力暗），不会被参数微调打乱。
  baseColor: Color(0xFF565656),
);

/// 取某一档的预览规格。
MaterialPreviewSpec materialPreviewSpecOf(WindowMaterial material) =>
    switch (material) {
      WindowMaterial.mica => kMicaPreview,
      WindowMaterial.micaAlt => kMicaAltPreview,
      WindowMaterial.acrylic => kAcrylicPreview,
      WindowMaterial.acrylicThin => kAcrylicThinPreview,
    };

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