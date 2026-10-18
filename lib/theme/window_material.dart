import 'package:flutter/material.dart';

/// 窗口材质。对应设置里的 `windowMaterial`。
///
/// 存进配置文件的字符串定下就不能改，否则用户已有的设置会失效。
enum WindowMaterial {
  mica('mica', 'Mica', '柔和云母', seeThrough: 0.18),
  micaAlt('mica-alt', 'Mica Alt', '层次云母', seeThrough: 0.18, layered: true),
  acrylic('acrylic', '亚克力', '磨砂玻璃',
      seeThrough: 0.45, blur: 3.2, grain: 1),
  acrylicThin(
    'acrylic-thin',
    '细亚克力',
    '更透亮的磨砂',
    seeThrough: 0.62,
    blur: 1.6,
    grain: 0.25,
  ),
  none('none', '纯色', '不使用特殊材质，性能最好');

  const WindowMaterial(
    this.id,
    this.label,
    this.description, {
    this.seeThrough = 0,
    this.blur = 0,
    this.grain = 0,
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

  /// 真机窗口底：磨砂颗粒强度（0 = 不撒颗粒）。
  ///
  /// Mica 系是柔和的云母，没有颗粒；亚克力系是磨砂玻璃，颗粒是它相对 Mica
  /// 的**真实特征**（WinUI 的 acrylic 刷子带 noise 纹理）。
  ///
  /// 两档差得远（亚克力 1.0 / 细亚克力 0.25）是**真机实测逼出来的**：
  /// 细亚克力的材质底色与纯色底的窗口底只差 10.7 分，颗粒一强就把它往纯色
  /// 那边推（实测那一对只剩 1.313，判据要 1.5）。细亚克力现在主要靠
  /// **底色档位**与纯色拉开，颗粒只留「它仍是磨砂」这一点信息。
  final double grain;

  /// 设置页缩略图：是否画出 Mica Alt 那道上下分层接缝
  final bool layered;

  static WindowMaterial fromId(String? id) => WindowMaterial.values.firstWhere(
        (m) => m.id == id,
        orElse: () => WindowMaterial.mica,
      );

  /// 材质底色（浅色 / 深色）。
  ///
  /// ### 两个用途
  ///
  /// 1. 设置页「窗口材质」那张缩略图里材质薄片的底色 —— 用户挑材质时唯一
  ///    看到的东西，所以它必须**如实代表**该材质在真机上的样子。
  /// 2. **真机窗口底**：`BackgroundLayer` 把这层色以 `_kSheetAlpha` 压在
  ///    85% 调色层**之上**（见 `background_layer.dart`）。两个用途共用一套
  ///    值 —— 缩略图里看到的薄片色，就是真机窗口底的那个色。
  ///
  /// ### 2026-10-16 二次定标：为什么必须偏离 WinUI 官方值
  ///
  /// 初版照抄 WinUI 官方资源值（`Common_themeresources_any.xaml` /
  /// `AcrylicBrush_themeresources.xaml`）。但 WinUI 自己这几档**挤在一起**：
  /// 深色 `#0A0A0A`(10) / `#171717`(23) / `#1C1C1C`(28) / `#202020`(32) /
  /// `#2C2C2C`(44) —— 相邻档位只差 4~5 个灰阶，而它们上面还压着 85% 的
  /// 主题调色层（**文字对比度的地板，不得下调**）。2026-10-16 真机实测
  /// （1400×1000、采样窗口中部）：mica / mica-alt / acrylic / acrylic-thin
  /// 四档**逐像素平均差 0.000**，纯色与它们也只差 0.476。
  ///
  /// ### 定标用的真机比例
  ///
  /// 真机读数 ≈ **0.20 ×** 判据里的窗口底差（材质特征只落在窗口底可见区上，
  /// 采样区里约八成被卡片盖住、只透一成）。所以真机判据「逐像素平均差 ≥1.5」
  /// 要求窗口底上相邻档位**至少差 7.5 分**；这里按 **10.7 分**排，
  /// 真机落点 ≈2.1，留 40% 余量。
  ///
  /// ### 排序
  ///
  /// 次序完全保留 WinUI 的（**深浅两态同序**）：
  /// `mica-alt < 纯色 < 细亚克力 < Mica < 亚克力`（深色）/
  /// `纯色 > 亚克力 > Mica > 细亚克力 > Mica Alt`（浅色，纯色在最亮端）。
  ///
  /// 深色下纯色底的实色是 `#14171E`(24.3)，正好卡在低端，所以四档只能钉在
  /// 它的上方 —— 细亚克力（0.25 的颗粒）被放到它**下方**才腾得出档位；
  /// 浅色下纯色底是 `#F8FAFC`(250)，四档全部压在它下方。两处让位都在
  /// **相邻档位只差 5 分**的位置上，次序本身不动。
  /// 材质薄片相对**当前风格底色**的亮度偏移（0~255 灰阶）。
  ///
  /// ## 2026-10-19 改为相对偏移（修「材质看不出区别」）
  ///
  /// 此前这里是**写死的绝对色值**（按 2026-10-16 的旧色板定标）。加入
  /// winui 风格后深色底从 `#14171E`(≈23) 变成 `#2C2C2C`(44)，而亚克力的
  /// 绝对底色 `#2A2A2A`(42) 没变 —— 二者只差 **2 个灰阶**，肉眼完全分不出。
  ///
  /// 根因是"绝对色值"这个设计：材质薄片以 0.86 的 alpha 压在调色层之上，
  /// 它能被看见的**只有与底色的差**。底色随风格变，绝对色值就必须跟着重算，
  /// 否则每加一套风格都要重新定标一次。
  ///
  /// 现在改成**相对于当前风格 `solidFor` 的偏移**，间距固定 12 灰阶：
  /// 无论底色是 23 还是 44，五档都稳定拉开 ≥12（判据要 ≥7.5），
  /// 加新风格时不需要再定标。
  ///
  /// 次序保留 WinUI 的（深色）：`mica-alt < 纯色 < 细亚克力 < Mica < 亚克力`；
  /// 浅色反向（纯色最亮）。**纯色 = 0**，因为它在真机上就是底色本身。
  int offsetFor(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (this) {
      WindowMaterial.micaAlt => dark ? -24 : -48,
      WindowMaterial.none => 0,
      WindowMaterial.acrylicThin => dark ? 12 : -36,
      WindowMaterial.mica => dark ? 24 : -24,
      WindowMaterial.acrylic => dark ? 36 : -12,
    };
  }

  /// 材质底色 = 当前风格底色 + [offsetFor]。
  ///
  /// [base] 是调用方按当前风格取的 `AppColors.solidFor(brightness, style)`。
  /// 不传时回退到中性灰（供不持有主题上下文的调用点使用）。
  Color previewFor(Brightness brightness, {Color? base}) {
    final dark = brightness == Brightness.dark;
    final b = base ?? (dark ? const Color(0xFF202020) : const Color(0xFFF3F3F3));
    final d = offsetFor(brightness);
    int ch(double v) => (v * 255 + d).round().clamp(0, 255);
    return Color.fromARGB(
      (b.a * 255).round(),
      ch(b.r),
      ch(b.g),
      ch(b.b),
    );
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
