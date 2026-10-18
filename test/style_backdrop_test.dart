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

  group('StyleBackdrop 层数', () {
    test('liquid 浅色 = 3 层 radial + 1 层线性（CSS :248-252）', () {
      final b = StyleBackdrop.of(AppStyle.liquid, Brightness.light);
      expect(b.glowCount, 3, reason: '液体玻璃浅色要有三层 radial 光晕');
      expect(b.linear.stops.length, 1 + 2, reason: '线性渐变至少两停');
      // 三层光晕的颜色 = CSS 原文 #cfe0ff / #ffd9ec / #d6fff0
      expect(b.glows[0].color, const Color(0x59CFE0FF));
      expect(b.glows[1].color, const Color(0x59FFD9EC));
      expect(b.glows[2].color, const Color(0x59D6FFF0));
      expect(b.linear.stops[0], const Color(0x59F7F8FE));
      expect(b.linear.stops.last, const Color(0x59F6F4F2));
    });

    test('liquid 深色 = 3 层 radial + 1 层线性（CSS :834-838）', () {
      final b = StyleBackdrop.of(AppStyle.liquid, Brightness.dark);
      expect(b.glowCount, 3);
      expect(b.glows[0].color, const Color(0x592A2545));
      expect(b.glows[1].color, const Color(0x593A2438));
      expect(b.glows[2].color, const Color(0x591F3A38));
      expect(b.linear.stops[0], const Color(0x5914131C));
      expect(b.linear.stops[1], const Color(0x59181722));
      expect(b.linear.stops.last, const Color(0x5916151F));
    });

    test('frosted = 1 层（单层线性，无光晕）（CSS :332 / :885）', () {
      for (final brightness in Brightness.values) {
        final b = StyleBackdrop.of(AppStyle.frosted, brightness);
        expect(b.glowCount, 0, reason: 'frosted 没有 radial 光晕');
        expect(b.linear.stops, hasLength(3));
      }
      expect(StyleBackdrop.frostedLight.linear.stops,
          const [Color(0x59EEF1F6), Color(0x59E8ECF3), Color(0x59F0EEF3)]);
      expect(StyleBackdrop.frostedDark.linear.stops,
          const [Color(0x5917171A), Color(0x591B1B1F), Color(0x59191820)]);
    });

    test('clay = 1 层（单层线性，无光晕）（CSS :399 / :932）', () {
      for (final brightness in Brightness.values) {
        final b = StyleBackdrop.of(AppStyle.clay, brightness);
        expect(b.glowCount, 0, reason: 'clay 没有 radial 光晕');
        expect(b.linear.stops, hasLength(3));
      }
      expect(StyleBackdrop.clayLight.linear.stops,
          const [Color(0x59FAF6F1), Color(0x59F5EFE8), Color(0x59F8F4EF)]);
      expect(StyleBackdrop.clayDark.linear.stops,
          const [Color(0x591F1A16), Color(0x59241E19), Color(0x59221D19)]);
    });

    test('六套背景两两不同（同亮度下三风格不同；同风格下两亮度不同）', () {
      final tokens = <String, StyleBackdrop>{
        for (final s in AppStyle.values)
          for (final b in Brightness.values)
            '${s.id}-${b.name}': StyleBackdrop.of(s, b),
      };
      expect(tokens, hasLength(AppStyle.values.length * 2));
      final seen = <StyleBackdrop>[];
      for (final entry in tokens.entries) {
        for (final prev in seen) {
          expect(
            entry.value == prev,
            isFalse,
            reason: '${entry.key} 与另一套背景完全相同 —— 风格区分失效',
          );
        }
        seen.add(entry.value);
      }
    });

    test('六套背景都必须**半透明** —— 否则窗口材质被整片盖死', () {
      // 2026-10-16 真机实测到的缺陷：这一层原本每个色停都是 `0xFF`，
      // 绘制器又铺满整窗，于是 mica / 亚克力 / 纯色三种材质渲染出来
      // 逐像素完全相同（平均差 0.00）——「窗口材质」这个设置项等于没有效果。
      //
      // 判据：任何一个色停都不能是 alpha=255；且整体要留出足够透光率
      // （<0.5），否则材质只剩几个亮度级、肉眼看不出来。
      for (final s in AppStyle.values) {
        for (final b in Brightness.values) {
          final bd = StyleBackdrop.of(s, b);
          final all = <Color>[
            for (final g in bd.glows) g.color,
            ...bd.linear.stops,
          ];
          expect(all, isNotEmpty);
          for (final c in all) {
            expect(c.a, lessThan(0.5),
                reason: '${s.id}/${b.name} 有不透明色停（alpha=${c.a}）—— '
                    '窗口材质会被它盖住，三种材质渲染结果将完全相同');
          }
        }
      }
    });

    test('负控制：把色停改成不透明会被上面那条判据抓住', () {
      // 复现改造前的写法（0xFF），证明上一条不是恒真。
      const opaqueStop = Color(0xFFF7F8FE);
      expect(opaqueStop.a, greaterThanOrEqualTo(0.5),
          reason: '不透明的色停必须被判为不合规');
    });
    test('六套窗口底实色两两不同（换风格的取值分叉必须还在）', () {
      // **为什么这条是 token 层、而不是像素层**：材质底以 `_kSheetAlpha`
      // （0.86）的不透明度压在窗口底上（`background_layer.dart`），窗口底的
      // 风格渐变只剩 14%。深色下三套 `solidFor` 的**亮度**本来就只差
      // 0.33~6.0，压到 14% 后直接落进噪声 —— 2026-10-16 实测像素差
      // liquid↔frosted 0.333 / liquid↔clay 1.000 / frosted↔clay 0.667。
      // 这不是回归，是「材质身份要落在窗口底上」的必然代价：
      // 「换风格看得出来」现在落在卡片与控件上（`AppSurface` / `StyleColors`
      // 的渐变、圆角、阴影都随风格走）。这条判据只守「窗口底的取值本身
      // 仍然按风格分叉」，防止连取值都退化成同一套。
      final solids = <String, Color>{
        for (final s in AppStyle.values)
          for (final b in Brightness.values)
            '${s.id}-${b.name}': AppColors.solidFor(b, style: s),
      };
      expect(solids, hasLength(AppStyle.values.length * 2));
      final seen = <MapEntry<String, Color>>[];
      for (final entry in solids.entries) {
        for (final prev in seen) {
          expect(entry.value == prev.value, isFalse,
              reason: '${entry.key} 与 ${prev.key} 的窗口底实色完全相同 —— '
                  '风格区分失效');
        }
        seen.add(entry);
      }
    });
  });

  // ══════════════════════════════════════════════════════════
  // 渲染像素层：判据落在真实像素上
  // ══════════════════════════════════════════════════════════

  group('背景层渲染像素', () {
    testWidgets('五种窗口材质的窗口底两两可测地不同（材质选择必须有实际后果）',
        (tester) async {
      // 2026-10-16 真机实测到的缺陷：mica / mica-alt / acrylic / acrylic-thin
      // 四种材质渲染出来**逐像素完全相同**（平均差 0.00 × 4 组）。
      // 现在材质由 `_MaterialSheetPainter` 整片画在 85% 调色层**之上**：
      // `previewFor` 的 WinUI 材质底（alpha 0.86）给亮度身份，`layered`
      // 叠上半区分层与接缝，`grain` 撒磨砂颗粒。
      final luma = <WindowMaterial, List<double>>{};
      for (final m in WindowMaterial.values) {
        luma[m] = await renderLuma(tester, material: m);
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
      print('材质窗口底差异矩阵（采样点平均绝对亮度差）:\n$matrix');

      for (final entry in pairs.entries) {
        expect(
          entry.value,
          greaterThanOrEqualTo(_kMinDelta),
          reason: '${entry.key} 的窗口底只差 ${entry.value.toStringAsFixed(3)} '
              '（判据要求 ≥ $_kMinDelta）—— 这一对材质真机上分不出来。\n'
              '全部 10 对：\n$matrix',
        );
      }
    });

    testWidgets('负控制：同一材质渲染两次，像素逐点相同（判据没有随机性）',
        (tester) async {
      // 上一条的能量必须全部来自材质本身。若量法带随机性（例如颗粒用了
      // 非固定种子、或每帧有抖动），这条会红 —— 那时上一条也就不可信了。
      for (final m in WindowMaterial.values) {
        final a = await renderLuma(tester, material: m);
        final b = await renderLuma(tester, material: m);
        expect(meanAbsDiff(a, b), 0,
            reason: '${m.id} 两次渲染的像素不同 —— 判据量的不是材质特征');
      }
    });

    testWidgets('负控制：材质差异是**全局**的，不是零星像素', (tester) async {
      // 平均值达标也可能是「几百个像素差很大、其余全同」撑出来的。
      // 真机阈值（逐像素平均差 ≥1.5）要求差异铺满窗口底，所以这里额外钉住
      // 「有差异的采样点占比」。
      final base = await renderLuma(tester, material: WindowMaterial.mica);
      for (final m in [
        WindowMaterial.micaAlt,
        WindowMaterial.acrylic,
        WindowMaterial.acrylicThin,
        WindowMaterial.none,
      ]) {
        final other = await renderLuma(tester, material: m);
        var differing = 0;
        for (var i = 0; i < base.length; i++) {
          if ((base[i] - other[i]).abs() > 0.5) differing++;
        }
        final ratio = differing / base.length;
        expect(ratio, greaterThan(0.5),
            reason: 'mica↔${m.id} 只有 ${(ratio * 100).toStringAsFixed(1)}% 的采样点'
                '有差异 —— 材质特征没有铺满窗口底');
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
            w.color == StyleColors.liquidLight.colors.surfaceSolid,
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
        colors: AppColors.of(AppStyle.liquid, Brightness.light),
        brightness: Brightness.light,
        style: AppStyle.liquid,
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

  testWidgets('Mica 路径永远铺一层底（绘制器 + 85% 调色层都在）', (tester) async {
    await pumpBackdrop(tester, WindowMaterial.mica,
        style: AppStyle.frosted, brightness: Brightness.dark);
    // 调色层是**文字对比度的地板**：不查具体色值（材质底会压在它上面），
    // 只查「85% 不透明的那一层还在」—— 它保证 Mica 没生效时不黑窗。
    expect(
      find.byWidgetPredicate((w) => w is ColoredBox && w.color.a == 0.85),
      findsOneWidget,
      reason: 'Mica 没生效时这层保证界面可见（黑窗 bug 的守门判据）',
    );
    // 风格渐变打底与材质底各一层 —— 两层都在，背景层才算铺满。
    expect(backdropPaint('style'), findsOneWidget);
    expect(backdropPaint('material'), findsOneWidget);
  });

  // ══════════════════════════════════════════════════════════
  // 颗粒绘制开销：必须是纹理平铺，不许在整窗上逐点画圆
  // ══════════════════════════════════════════════════════════

  testWidgets('磨砂颗粒走纹理平铺，不在整窗上逐点画圆', (tester) async {
    // 2026-10-16 用户报「亚克力选中后超级卡」。根因：颗粒按
    // `size.width * size.height / 11 * grain` 对**整窗**逐个 `drawCircle` ——
    // 那个密度是给设置页 64×44 缩略图（约 256 个点）定的，接到整窗后
    // 1280×720 的亚克力档要画 **83,782 个抗锯齿圆**／次重绘，一帧上百毫秒。
    // 现在颗粒来自预生成的噪点纹理（`ImageShader` 平铺 = 一次 `drawRect`），
    // 这条判据把「主 canvas 上不许逐点画圆」钉死。
    for (final m in [WindowMaterial.acrylic, WindowMaterial.acrylicThin]) {
      await pumpBackdrop(tester, m,
          style: AppStyle.frosted, brightness: Brightness.dark);
      final painter =
          tester.widget<CustomPaint>(backdropPaint('material')).painter!;
      final probe = _DrawCallProbe();
      painter.paint(probe, const Size(1280, 720));
      expect(probe.circles, 0,
          reason: '${m.id} 在 1280×720 的材质层上逐点画了 ${probe.circles} 个圆 —— '
              '颗粒必须走预生成纹理平铺；逐点实现这一档是 '
              '${(1280 * 720 / 11 * m.grain).round()} 个');
      expect(probe.rects, greaterThan(0), reason: '材质层应当画了底');
    }
  });

  testWidgets('负控制：有颗粒档的绘制调用数必须多于无颗粒档', (tester) async {
    // 上一条只证明「没有逐点画圆」。哪天颗粒整段被删掉，它照样绿 ——
    // 所以「颗粒确实画出来了」要单独钉一条：亚克力系（grain > 0）的
    // 绘制调用数必须**严格多于** Mica（grain 0）。
    Future<int> callsOf(WindowMaterial m) async {
      await pumpBackdrop(tester, m,
          style: AppStyle.frosted, brightness: Brightness.dark);
      final painter =
          tester.widget<CustomPaint>(backdropPaint('material')).painter!;
      final probe = _DrawCallProbe();
      painter.paint(probe, const Size(1280, 720));
      return probe.total;
    }

    final mica = await callsOf(WindowMaterial.mica);
    final acrylic = await callsOf(WindowMaterial.acrylic);
    final thin = await callsOf(WindowMaterial.acrylicThin);
    expect(acrylic, greaterThan(mica),
        reason: '亚克力的绘制调用数（$acrylic）不多于 Mica（$mica）—— 颗粒没画出来');
    expect(thin, greaterThan(mica),
        reason: '细亚克力的绘制调用数（$thin）不多于 Mica（$mica）—— 颗粒没画出来');
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
  AppStyle style = AppStyle.frosted,
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
  AppStyle style = AppStyle.liquid,
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
