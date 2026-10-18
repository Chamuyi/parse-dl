import 'dart:io';
import 'dart:ui' as ui;

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
    // WinUI3 的窗口底是 **Mica —— 不透明材质**。
    //
    // 微软官方文档（learn.microsoft.com/windows/apps/design/style/mica）原文：
    //   "Mica is an **opaque**, dynamic material that incorporates theme and
    //    desktop wallpaper to paint the background of long-lived windows …
    //    it only samples the desktop wallpaper **once**"
    //
    // 也就是说：它**不是**半透明玻璃，壁纸不会被"透"上来，而是被取样一次
    // 混进底色。所以这里既不铺用户壁纸、也不画渐变光晕 —— 只铺一层不透明底。
    // 用户想换壁纸效果时，WinUI 语义下应由 Mica 自己随系统壁纸变化。
    // 但**自定义色调仍然要生效**：那是用户的显式选择，不该被风格吞掉。
    if (_styleOf(context) == AppStyle.winui && !appearance.customTint) {
      return ColoredBox(
        color: AppColors.solidFor(brightness, style: AppStyle.winui),
      );
    }

    final tint = _resolveTint(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        // ① 底：永远要铺，让 Mica 没生效时也不会黑窗。
        //    纯色材质 / 自定义色调是实色 ColoredBox；Mica 路径是
        //    风格背景（光晕 + 线性渐变）+ 半透明调色层。
        if (tint == null)
          _StyleBackdropWash(
            backdrop: StyleBackdrop.of(_styleOf(context), brightness),
            material: appearance.windowMaterial,
          )
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

/// 按风格令牌绘制窗口底：风格渐变打底 + 85% 主题调色层（保 Mica 语义）
/// + 材质特征层。
///
/// 调色层沿用改造前同一条取值：`solidFor(brightness, style).withValues(alpha: 0.85)`
/// —— 它是**文字对比度的地板**（页面标题直接压在窗口背景上，没有卡片托底），
/// alpha 一松弱档文字就跌破 4.5，所以材质只能往它**上面**叠，不能往下调。
class _StyleBackdropWash extends StatelessWidget {
  final StyleBackdrop backdrop;

  /// 用户选的窗口材质。**2026-10-16 起真正参与绘制**。
  ///
  /// 此前它只影响设置页那张缩略图，实际渲染完全不看它 —— 于是 mica /
  /// mica-alt / acrylic / acrylic-thin 四种材质渲染出来**逐像素完全相同**
  /// （实测平均差 0.00 × 4 组），「窗口材质」这个设置项等于摆设。
  final WindowMaterial material;

  const _StyleBackdropWash({required this.backdrop, required this.material});

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final brightness = theme.brightness;
    // **按风格取底色**（2026-10-16）。此前这里不传 style，于是三套风格的
    // 窗口底走的是同一个 frosted 值 —— 「三套风格」在最大的一块面（整个窗口
    // 背景）上根本没有区别，用户看到的就是「换风格没感觉」。
    final wash = AppColors.solidFor(brightness, style: theme.style)
        .withValues(alpha: 0.85);

    // 材质越"透"，风格背景画得越淡 —— [WindowMaterial.seeThrough] 的语义
    // 就是「薄片透出多少桌面壁纸」，把它接进来才让材质选择有实际后果。
    final veil = (1 - material.seeThrough).clamp(0.0, 1.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        // 风格背景：线性渐变打底 + 光晕（永远有这一层）
        CustomPaint(
          painter: _BackdropPainter(backdrop: backdrop, veil: veil),
        ),

        // 半透明主题调色层（85%）
        ColoredBox(color: wash),

        // 材质底（+ Mica Alt 分层 + 亚克力磨砂颗粒）—— 必须画在调色层之
        // 上，否则整片被 85% 的调色层盖掉（实测差 0.037，肉眼不可见）。
        CustomPaint(
          painter: _MaterialSheetPainter(
            material: material,
            brightness: brightness,
            base: AppColors.solidFor(brightness, style: theme.style),
          ),
        ),
      ],
    );
  }
}

/// 背景底绘制器的公开标记 —— 让测试用公开类型定位图层，不必依赖私有类名
/// 或 `toString()` 覆写。
///
/// **2026-10-16 的教训**：此前 `style_backdrop_test.dart` 靠
/// `painter.toString()` 拼出的 widget 树描述串做「五种材质渲染出不同结果」的
/// 判据，而 `_BackdropPainter.toString()` 恰好把材质参数写进了串里 ——
/// 于是「材质参数不同 ⇒ 字符串不同 ⇒ 判据必绿」，与真实渲染无关。同一条
/// 判据在真机实测四档材质**逐像素平均差 0.000** 时照样全绿。
/// 现在判据改成直接量渲染像素，这里只留一个稳定的定位锚。
abstract class BackdropPainter extends CustomPainter {
  const BackdropPainter(this.kind);

  /// `'style'` = 风格渐变打底；`'material'` = 材质特征（分层 / 磨砂颗粒）。
  final String kind;
}

/// 按 [StyleBackdrop] 画线性渐变 + radial 光晕。
///
/// CSS 多重背景**第一层画在最上面**：`glows[0]` 是 CSS 第一条 radial，
/// 所以光晕按列表**倒序**画（最后画 glows[0]，让它盖在其它光晕上面）。
class _BackdropPainter extends BackdropPainter {
  final StyleBackdrop backdrop;

  /// 整体不透明度（由窗口材质决定，见 `_StyleBackdropWash`）。
  final double veil;

  _BackdropPainter({
    required this.backdrop,
    this.veil = 1.0,
  }) : super('style');

  /// 按 [veil] 缩放一个颜色的 alpha。
  Color _v(Color c) => c.withValues(alpha: c.a * veil);

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
          colors: [for (final s in linear.stops) _v(s)],
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
            colors: [
              _v(glow.color),
              _v(glow.color).withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter oldDelegate) =>
      oldDelegate.backdrop != backdrop || oldDelegate.veil != veil;
}

/// 材质底（+ Mica Alt 分层 + 亚克力磨砂颗粒）—— 五种窗口材质在真机上
/// **唯一看得见身份的地方**。
///
/// ### 为什么必须画在调色层之上，且必须够实
///
/// 层序是「风格渐变 → 85% 主题调色层 → **本层**」。调色层那 0.85 是
/// **文字对比度的地板**（页面标题直接压在窗口底上、没有卡片托底），
/// 不许下调、也不许移除，所以材质只能往它**上面**叠。
///
/// alpha 取 [_kSheetAlpha] 而不是「极低」是有实测依据的：WinUI 官方材质底
/// 五档只差 4~5 个灰阶（深色 `#0A0A0A`(10) ↔ `#202020`(32)），任何低 alpha
/// 的叠加都会把四档压回同一片像素（0.000 那次实测就是这么来的）。
/// 「材质身份要体现在窗口底色上」这个要求，和「叠一层极淡的特征」是互斥的。
///
/// 代价：窗口底的风格渐变只剩 `1 - _kSheetAlpha`；三套风格的区分主要落在
/// 卡片与控件上（`AppSurface` / `StyleColors`），窗口底只保住底色差。
class _MaterialSheetPainter extends BackdropPainter {
  final WindowMaterial material;
  final Brightness brightness;

  /// 当前风格的窗口底色 —— 材质薄片按它做相对偏移（2026-10-19）。
  /// 传 null 时 [WindowMaterial.previewFor] 回退到中性灰。
  final Color? base;

  const _MaterialSheetPainter({
    required this.material,
    required this.brightness,
    this.base,
  }) : super('material');

  /// 分层接缝的位置（命令区与内容区的分界，窗口高度的 42%）。
  static const double _seamAt = 0.42;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = brightness == Brightness.dark;
    final sheet = material.previewFor(brightness, base: base);

    // ① 材质底：整窗一层 [WindowMaterial.previewFor] 的材质底色
    //    （相对当前风格底色偏移，见该方法文档）。
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = sheet.withValues(alpha: _kSheetAlpha),
    );

    if (material.layered) {
      // ② Mica Alt 的上下分层：上半区（命令区）比下半区更暗 —— 这是它相对
      //    Mica 的身份特征，也是五种材质里唯一「一眼可辨」的一个。
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height * _seamAt),
        Paint()..color = Colors.black.withValues(alpha: dark ? 0.20 : 0.10),
      );
      // 分界处一道 2px 的缝，让分层有个明确的边。
      canvas.drawRect(
        Rect.fromLTWH(0, size.height * _seamAt, size.width, 2),
        Paint()
          ..color =
              (dark ? Colors.white : Colors.black).withValues(alpha: 0.22),
      );
    }

    if (material.grain > 0) _paintGrain(canvas, size, dark);
  }

  /// 磨砂颗粒。**预生成一张噪点 tile 后平铺整窗**，不是逐点画圆。
  ///
  /// ### 2026-10-16 性能修复（用户报「亚克力选中后超级卡」）
  ///
  /// 原实现按设置页缩略图的密度公式 `size.width * size.height / 11 * grain`
  /// 对**整窗**逐个 `drawCircle`。那个密度是给 64×44 的缩略图（约 256 个点）
  /// 定的，接到整窗后点数随**面积**增长：1280×720 的亚克力档要画
  /// **83,782 个抗锯齿圆**／次重绘（细亚克力 20,945 个，Mica 系 0 个）——
  /// 一帧上百毫秒，正好解释「只有亚克力超级卡，Mica 不卡」。
  ///
  /// 现在噪点预生成到一张 [_kGrainTile] 见方的 tile，再用 `ImageShader` +
  /// `TileMode.repeated` 平铺：**每帧只有一次 `drawRect`**，开销与窗口尺寸无关。
  /// 点密度、半径、浓淡全部沿用原公式，视觉不变。
  ///
  /// 颗粒色必须与窗口底**对立**才看得见：深色主题撒亮颗粒、浅色主题撒暗颗粒。
  /// 浓淡用 `0.30 × grain` 而不是「越薄越淡」的线性关系 —— 亚克力那一档的
  /// 颗粒在真机上是它区别于 Mica 的主要证据，实测证明淡了就不够。
  void _paintGrain(Canvas canvas, Size size, bool dark) {
    final image = _grainTile(dark, material.grain);
    if (image == null) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ImageShader(
          image,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.identity().storage,
          // tile 内是 0.6px 的锐利颗粒，插值会把它糊掉。
          filterQuality: FilterQuality.none,
        ),
    );
  }

  /// 噪点 tile 的边长（逻辑像素）。取 128 而不是更小，是为了让平铺后的
  /// 重复周期大到肉眼看不出规律。
  static const double _kGrainTile = 128;

  /// `(深色, grain)` → 预生成的噪点图。全项目只有 2 档 grain，至多 4 张，
  /// 生成一次后常驻（每张 128×128 ≈ 64 KB）。
  static final Map<String, ui.Image> _grainTiles = {};

  /// 取（必要时生成）噪点 tile。`grain <= 0`（Mica 系 / 纯色）返回 null。
  ///
  /// 生成用的是与原来**同一套**密度 / 半径 / 种子公式，所以颗粒长相不变；
  /// 区别只在于这次它只覆盖 128×128 那一小块，且**一辈子只算一次**。
  static ui.Image? _grainTile(bool dark, double grain) {
    if (grain <= 0) return null;
    final key = '${dark ? 'dark' : 'light'}:$grain';
    final cached = _grainTiles[key];
    if (cached != null) return cached;

    final recorder = ui.PictureRecorder();
    final tile = Canvas(recorder);
    final paint = Paint()
      ..color =
          (dark ? Colors.white : Colors.black).withValues(alpha: 0.30 * grain);
    var seed = 20261016;
    int next() {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      return seed;
    }

    final count = (_kGrainTile * _kGrainTile / 11 * grain).round();
    for (var i = 0; i < count; i++) {
      tile.drawCircle(
        Offset(
          (next() % 1000) / 1000 * _kGrainTile,
          (next() % 1000) / 1000 * _kGrainTile,
        ),
        0.6,
        paint,
      );
    }
    final image = recorder
        .endRecording()
        .toImageSync(_kGrainTile.round(), _kGrainTile.round());
    _grainTiles[key] = image;
    return image;
  }

  @override
  bool shouldRepaint(_MaterialSheetPainter oldDelegate) =>
      oldDelegate.material != material || oldDelegate.brightness != brightness;
}

/// 材质底压在窗口底上的不透明度。
///
/// 定标（`style_backdrop_test.dart` 的「五种窗口材质的窗口底两两可测地不同」
/// 把 10 对差都钉在 ≥ `_kMinDelta`）：0.86 时最小一对（纯色↔细亚克力）
/// 落 10.4 分；再低到 0.7 就掉到 8 分以下守不住真机阈值。
const double _kSheetAlpha = 0.86;

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
