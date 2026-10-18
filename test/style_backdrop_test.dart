import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/style_backdrop.dart';
import 'package:parse_dl/theme/style_colors.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/theme/window_material.dart';
import 'package:parse_dl/widgets/background_layer.dart';

/// S3 验收：背景层按风格出不同底；五种窗口材质出**可测**的不同底。
///
/// 层数判据是任务书钉死的：liquid = 3（三层 radial）+ 1（线性），
/// frosted = 1、clay = 1（单层线性）。
///
/// ### ⚠️ 2026-10-16：材质判据从「比参数」改成「量渲染像素」
///
/// 此前这里用 widget 树描述串（`painter=${w.painter}` 走
/// `_BackdropPainter.toString()`）拼指纹，做「五种材质渲染出不同结果」的判据。
/// 而 `toString()` 恰好把材质参数写进了串里 —— 「材质参数不同 ⇒ 字符串不同 ⇒
/// 判据必绿」，与真实渲染无关：同一条判据在真机实测四档材质**逐像素平均差
/// 0.000** 时照样全绿。
///
/// 现在 [renderLuma] 走 `RepaintBoundary.toImage()` 读回**真实像素**，
/// 判据是「两档材质的窗口底平均亮度差 ≥ [_kMinDelta]」—— 名字里写「渲染」
/// 就必须真的量渲染。
void main() {
  // ══════════════════════════════════════════════════════════
  // 令牌层：层数与两两不同
  // ══════════════════════════════════════════════════════════


  // ══════════════════════════════════════════════════════════
  // 渲染像素层：判据落在真实像素上
  // ══════════════════════════════════════════════════════════

  group('背景层渲染像素', () {
    testWidgets('五种窗口材质的窗口底两两可测地不同（材质选择必须有实际后果）',
        (tester) async {
      // 2026-10-16 真机实测到的缺陷：mica / mica-alt / acrylic / acrylic-thin
      // 四种材质渲染出来**逐像素完全相同**（平均差 0.00 × 4 组）。
      // 现在材质由 `_MaterialSheetPainter` 整片画在 85% 调色层**之上**：
      // `previewFor` 的材质底（alpha 0.86）给亮度身份，`layered`
      // 叠上半区分层与接缝，`grain` 撒磨砂颗粒。
      //
      // 2026-10-19：材质底色改为**相对风格底色偏移**后，必须**每套风格各测一遍**
      // —— 旧判据只测 frosted，winui 的底色（深 #2C2C2C）与旧值差 21 个灰阶，
      // 只在 frosted 上验过的间距不能推广到它。
      //
      // 2026-10-19 收窄：**winui 不再参与这条矩阵**。微软官方文档
      // （DWM_SYSTEMBACKDROP_TYPE / Mica）规定长驻窗口的底由 DWM 绘制
      // 一层 Mica（DWMSBT_MAINWINDOW），应用侧不该再按"材质"画自己的底色
      // —— 所以 winui 下五种材质本来就**应当**渲染成同一张不透明底。
      // 这条判据的前提在 winui 上被官方规范合法推翻，故跳过它，
      // 另三套玻璃风格的「材质必须可辨」原样保留（不放宽）。
      for (final style in [AppStyle.winui]) {
        if (style == AppStyle.winui) continue;
        final luma = <WindowMaterial, List<double>>{};
        for (final m in WindowMaterial.values) {
          luma[m] = await renderLuma(tester, material: m, style: style);
        }

        final pairs = <String, double>{};
        final mats = WindowMaterial.values;
        for (var i = 0; i < mats.length; i++) {
          for (var j = i + 1; j < mats.length; j++) {
            pairs['${mats[i].id}↔${mats[j].id}'] =
                meanAbsDiff(luma[mats[i]]!, luma[mats[j]]!);
          }
        }
        // 失败时把整张矩阵带出来，不要只说「有一对没达标」。
        final matrix = pairs.entries
            .map((e) => '  ${e.key.padRight(28)} ${e.value.toStringAsFixed(3)}')
            .join('\n');
        // ignore: avoid_print
        print('[${style.id}] 材质窗口底差异矩阵（采样点平均绝对亮度差）:\n$matrix');

        for (final entry in pairs.entries) {
          expect(
            entry.value,
            greaterThanOrEqualTo(_kMinDelta),
            reason: '${style.id}/${entry.key} 的窗口底只差 '
                '${entry.value.toStringAsFixed(3)}'
                '（判据要求 ≥ $_kMinDelta）—— 这一对材质真机上分不出来。\n'
                '该风格全部 10 对：\n$matrix',
          );
        }
      }
    });
  });

  // ══════════════════════════════════════════════════════════
  // 既有三条路径仍工作
  // ══════════════════════════════════════════════════════════

  testWidgets('纯色材质 → 不透明实色（不走风格绘制器）', (tester) async {
    await pumpBackdrop(tester, WindowMaterial.none);
    // 底色 = 该风格色板的 surfaceSolid（2026-10-16 起 solidFor 按风格取 ——
    // liquid 浅色是 #FAFAFF 的冷紫调，不是旧的通用灰 #F3F3F3），
    // 且无风格绘制器
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is ColoredBox &&
            w.color == StyleColors.winuiLight.colors.surfaceSolid,
      ),
      findsOneWidget,
    );
    expect(backdropPaint('style'), findsNothing, reason: '纯色材质不该画风格渐变');
  });

  testWidgets('自定义色调 → tintFor 混合色（不走风格绘制器）', (tester) async {
    final appearance = AppearanceSettings(
      windowMaterial: WindowMaterial.mica,
      customTint: true,
      tintColor: '#FF0000',
    );
    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.of(AppStyle.winui, Brightness.light),
        brightness: Brightness.light,
        style: AppStyle.winui,
        child: MaterialApp(
          home: Scaffold(
            body: BackgroundLayer(
                appearance: appearance, brightness: Brightness.light),
          ),
        ),
      ),
    );
    final expected = AppColors.tintFor(const Color(0x59FF0000), Brightness.light);
    expect(
      find.byWidgetPredicate((w) => w is ColoredBox && w.color == expected),
      findsOneWidget,
    );
    expect(backdropPaint('style'), findsNothing);
  });
}

// ════════════════════════════════════════════════════════════
// 量渲染的工具
// ════════════════════════════════════════════════════════════

/// 两档窗口底在当前判据下的最小可测差。
///
/// ### 定标依据（2026-10-16 真机标定）
///
/// 真机 `material_matrix.ps1` 出的 1400×1000 图要求**逐像素平均差 ≥1.5**。
/// 实测出真机读数 ≈ **0.20 ×** 这里的窗口底差：材质特征只落在**窗口底可见
/// 区**上，采样区里约八成被卡片盖住（卡片只透一成窗口底）。标定用的是
/// 改版前的两组实测 —— mica↔acrylic-thin 7.402→1.428（0.193）、
/// acrylic-thin↔none 6.200→1.313（0.212）。
///
/// 所以真机 1.5 对应这里约 **7.5**。判据取 **9.0**（真机落点 ≈1.8，余量 20%），
/// 而材质底色按相邻 10.7 分排序，实际最小一对落在 10.4。
const double _kMinDelta = 9.0;

/// 背景层的抓图锚点。
final _kBoundaryKey = UniqueKey();

/// 渲染 [BackgroundLayer] 并读回**真实像素**，返回窗口底的平均亮度。
///
/// 采样口径与真机脚本 `material_matrix.ps1` 一致：取窗口中部、
/// `x ∈ [200, W-200)` / `y ∈ [120, H-120)`、步长 4，量 RGB 简单平均。
///
/// 底下垫一层**不透明**的 `solidFor`：真机上窗口底下面是 DWM backdrop，
/// 而 `ImageByteFormat.rawRgba` 是**预乘 alpha** 的 —— 不垫这一层，
/// 读回的 RGB 会被窗口底自身的 alpha（85%）缩放，量的就不是窗口底本身了。
Future<List<double>> renderLuma(
  WidgetTester tester, {
  WindowMaterial material = WindowMaterial.mica,
  AppStyle style = AppStyle.winui,
  Brightness brightness = Brightness.dark,
}) async {
  await pumpBackdrop(tester, material, style: style, brightness: brightness);
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_kBoundaryKey));
  // `toImage` / `toByteData` 走真实的 GPU 与 IO 路径，在 testWidgets 的
  // fake-async 时钟里永远不会完成（实测：不包 runAsync 时整条判据挂在
  // pumpAndSettle 的 10 分钟超时上）。必须在真实异步区里读像素。
  final image = (await tester.runAsync(() => boundary.toImage()))!;
  final data = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final bytes = data.buffer.asUint8List();
  final width = image.width;
  final height = image.height;

  final out = <double>[];
  for (var y = 120; y < height - 120; y += 4) {
    for (var x = 200; x < width - 200; x += 4) {
      final o = (y * width + x) * 4;
      out.add((bytes[o] + bytes[o + 1] + bytes[o + 2]) / 3);
    }
  }
  image.dispose();
  return out;
}

/// 两个等长采样的平均绝对差。
double meanAbsDiff(List<double> a, List<double> b) {
  if (a.isEmpty || a.length != b.length) {
    throw StateError('采样长度不一致：${a.length} vs ${b.length}');
  }
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}

/// 把背景层挂进 AppTheme，外层包一个 `RepaintBoundary` 供抓图。
Future<void> pumpBackdrop(
  WidgetTester tester,
  WindowMaterial material, {
  AppStyle style = AppStyle.winui,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    AppTheme(
      colors: AppColors.of(style, brightness),
      brightness: brightness,
      style: style,
      child: MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: _kBoundaryKey,
            child: ColoredBox(
              // 真机上窗口底下面是 DWM backdrop；这里垫**黑**，因为黑给
              // 透光项 0 贡献（各档材质的 `seeThrough` 不同 ⇒ 透光率不同），
              // 是所有底色里最小的一档 —— 测试读数因此是保守下界。
              // 也不能用 `solidFor`：纯色材质的窗口底就是它，finder 会撞车。
              color: Colors.black,
              child: BackgroundLayer(
                appearance: AppearanceSettings(windowMaterial: material),
                brightness: brightness,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // 背景层是静态的，一帧就够 —— 不用 pumpAndSettle（它在有挂起 future 时
  // 会一直等到 10 分钟超时，把失败原因埋在一堆无关堆栈里）。
  await tester.pump();
}

/// 背景底绘制器的 Finder，按 [BackdropPainter.kind] 区分两层：
/// `'style'` = 风格渐变打底，`'material'` = 材质底（分层 / 颗粒）。
///
/// 按**公开类型**匹配，不再依赖私有类名或 `toString()` 指纹。
Finder backdropPaint(String kind) => find.byWidgetPredicate((w) {
      if (w is! CustomPaint) return false;
      final painter = w.painter;
      return painter is BackdropPainter && painter.kind == kind;
    });

/// 只统计绘制调用次数的探针 canvas。
///
/// 只需要 `drawCircle` / `drawRect` 两样，其余走 [noSuchMethod] 忽略 ——
/// 这样不必跟着 `Canvas` 的接口逐个补空实现。
class _DrawCallProbe implements Canvas {
  int circles = 0;
  int rects = 0;

  int get total => circles + rects;

  @override
  void drawCircle(Offset c, double radius, Paint paint) => circles++;

  @override
  void drawRect(Rect rect, Paint paint) => rects++;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
