import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/widgets/liquid_glass.dart';

/// 液体玻璃降级路径（Stage A）的判据。
///
/// 观测手段是 `LiquidRimPainter` 的**公开字段**（`press` / `light` /
/// `intensity`）—— 它们是这个组件唯一诚实的光学状态出口，比截图稳。
GlassMaterial _liquid() => GlassMaterial.liquid(
  tint: Colors.white,
  dark: false,
  borderRadius: BorderRadius.circular(20),
);

/// S7 的 fake shader：记录 uniform 写入。
/// （SDK 的 FragmentProgram / FragmentShader 都是 base class，无法 mock；
/// `ui.ImageFilter` 构造私有且 `_toNativeImageFilter` 返回私有类型，
/// 库外不可实现 —— 探针的 [filter] 返回真 blur 滤镜，仅作类型占位，
/// 路径判据靠 `_composeInner` 读装配层 toString。）
class _ProbeShader extends ChangeNotifier implements GlassShader {
  final List<double> floats = [];
  int filterCalls = 0;

  @override
  void setFloat(int index, double value) {
    while (floats.length <= index) {
      floats.add(0);
    }
    floats[index] = value;
  }

  @override
  ui.ImageFilter filter() {
    filterCalls++;
    // compose 套 blur 是探针的指纹：降级路径的内层是 matrix、外层是
    // blur(5)，装配层 toString 的首段永远不会是 compose。
    return ui.ImageFilter.compose(
      outer: ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1),
      inner: ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1),
    );
  }
}

Widget _surface({
  required Widget child,
  bool canvas = false,
  bool reduceMotion = false,
  bool tickerEnabled = true,
  bool? shaderSupported,
  Future<GlassShader> Function()? loader,
}) {
  // 注入探测/加载（null = 用 SDK 真值）；测完恢复，防串到别的用例。
  LiquidGlassSurface.shaderSupported = shaderSupported == null
      ? null
      : () => shaderSupported;
  LiquidGlassSurface.shaderLoader = loader;
  addTearDown(() {
    LiquidGlassSurface.shaderSupported = null;
    LiquidGlassSurface.shaderLoader = null;
  });
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Center(
        child: SizedBox(
          width: 240,
          height: 120,
          child: TickerMode(
            enabled: tickerEnabled,
            child: LiquidGlassSurface(
              tint: Colors.white,
              dark: false,
              borderRadius: BorderRadius.circular(20),
              canvas: canvas,
              material: _liquid(),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

/// `.single` 本身就是判据：亮环恰好一个。
LiquidRimPainter _rim(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((paint) => paint.painter)
    .whereType<LiquidRimPainter>()
    .single;

/// 折射装配层的观测：`ImageFilter.compose` 的 toString 形如
/// `ImageFilter.compose(source -> blur(…) -> matrix([…]) -> result)`。
/// SDK 契约保证 compose 的顺序是 `inner -> outer`（painting.dart:4655），
/// 取**第一个**内层段判路径：降级 = `matrix(...)`，Stage B = `shader(...)`。
String _composeInner(WidgetTester tester) {
  final widget = tester.widgetList<BackdropFilter>(
    find.byType(BackdropFilter),
  ).single;
  final description = widget.filter.toString();
  // `ImageFilter.compose(source -> <inner> -> <outer> -> result)`：
  // 跳过 compose 自身的前缀，取其后第一个滤镜段判路径。
  final afterSource = description.indexOf('source -> ');
  final tail = afterSource < 0
      ? description
      : description.substring(afterSource + 10);
  final match = RegExp(r'\b(matrix|shader|blur|compose)\(').firstMatch(tail);
  return match?.group(1) ?? 'NO-MATCH: $description';
}

void main() {
  group('放大折射', () {
    test('静止与按压的 zoom 是具体数值：1.014 / 1.018242', () {
      // 普通态 k = .014、liquid = 1
      expect(LiquidGlassSurface.zoomOf(1, 0), 1.014);
      // 按压到底：1 + .014 * 1 * (1 + .3) = 1.0182
      expect(
        LiquidGlassSurface.zoomOf(1, 1),
        closeTo(1.0182, 1e-9),
      );
      // canvas 态放大减到 .004，同样是「放大」而不是缩小
      expect(LiquidGlassSurface.zoomOf(1, 0, canvas: true), 1.004);
      // 每档都严格大于 1：k 的符号抄错会立刻被这条拦住
      for (final liquid in [.25, .5, 1.0]) {
        for (final press in [0.0, .5, 1.0]) {
          expect(LiquidGlassSurface.zoomOf(liquid, press), greaterThan(1));
        }
      }
    });

    testWidgets('纯模糊态（liquid = 0）不折射、不发光', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 240,
              height: 120,
              child: LiquidGlassSurface(
                tint: Colors.white,
                dark: false,
                borderRadius: BorderRadius.circular(20),
                material: GlassMaterial(
                  blur: 22,
                  liquid: 0,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: Colors.white,
                  ),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      // 非液态：光学静止
      expect(_rim(tester).intensity, 0);
      expect(_rim(tester).press, 0);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('光照跟随', () {
    testWidgets('鼠标划过改方向、移开回到初始值、且不重建子树', (tester) async {
      var childBuilds = 0;
      await tester.pumpWidget(
        _surface(
          child: Builder(
            builder: (_) {
              childBuilds++;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      final surface = tester.widget<LiquidGlassSurface>(
        find.byType(LiquidGlassSurface),
      );
      final startLight = _rim(tester).light;
      expect(startLight, const Offset(-.65, -.8));
      // 静止方向的渐变方向：左上 → 右下
      expect(_rim(tester).lightDirection, const Alignment(-.65, -.8));

      final bounds = tester.getRect(find.byType(LiquidGlassSurface));
      final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
      await mouse.addPointer(location: bounds.topLeft + const Offset(15, 15));
      await mouse.moveTo(bounds.bottomRight - const Offset(15, 15));
      await tester.pump();

      // 光从左上翻到右下：方向值确实换了，而且是算出来的那个值
      final moved = _rim(tester).light;
      expect(moved, isNot(startLight));
      expect(moved.dx, greaterThan(0));
      expect(moved.dy, greaterThan(0));
      expect(_rim(tester).lightDirection, Alignment(moved.dx, moved.dy));
      expect(_rim(tester).lightDirection, isNot(const Alignment(-.65, -.8)));

      // 不重建：子树只 build 过一次，且 surface 是**同一个实例**
      expect(childBuilds, 1);
      expect(
        tester.widget<LiquidGlassSurface>(find.byType(LiquidGlassSurface)),
        same(surface),
      );

      await mouse.removePointer();
      await tester.pump();
      // 移开还原 —— 证明是「跟随」不是「一次性置位」
      expect(_rim(tester).light, const Offset(-.65, -.8));
      expect(childBuilds, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('按压反馈', () {
    testWidgets('三态：前推 → 回退到 0 → 取消，且不吃掉子组件点击', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _surface(
          child: GestureDetector(
            key: const ValueKey('target'),
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox.expand(),
          ),
        ),
      );
      final center = tester.getCenter(find.byKey(const ValueKey('target')));

      // 前推
      final gesture = await tester.startGesture(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final pushed = _rim(tester).press;
      expect(pushed, greaterThan(0));
      expect(pushed, lessThan(1));
      // 90ms / 180ms ≈ .5，允许 2ms 的调度误差
      expect(pushed, closeTo(.5, .03));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(_rim(tester).press, 0);
      expect(taps, 1);

      // 取消路径：同样前推，但取消后回 0，且不算点击
      final cancelled = await tester.startGesture(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(_rim(tester).press, greaterThan(0));
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(_rim(tester).press, 0);
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('右键不触发放大（非触摸只认主键）', (tester) async {
      await tester.pumpWidget(_surface(child: const SizedBox.expand()));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LiquidGlassSurface)),
        kind: ui.PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(_rim(tester).press, 0);
      await gesture.up();
      expect(tester.takeException(), isNull);
    });

    testWidgets('disableAnimations 下按压不启动', (tester) async {
      await tester.pumpWidget(
        _surface(reduceMotion: true, child: const SizedBox.expand()),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LiquidGlassSurface)),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(_rim(tester).press, 0);
      await gesture.cancel();
      expect(tester.takeException(), isNull);
    });

    testWidgets('TickerMode 关闭时按压不启动', (tester) async {
      await tester.pumpWidget(
        _surface(tickerEnabled: false, child: const SizedBox.expand()),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LiquidGlassSurface)),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(_rim(tester).press, 0);
      await gesture.cancel();
      expect(tester.takeException(), isNull);
    });
  });

  group('内缘亮环与外阴影', () {
    testWidgets('画布态留亮环但不绘内部背板', (tester) async {
      await tester.pumpWidget(
        _surface(canvas: true, child: const Text('Canvas content')),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('Canvas content'), findsOneWidget);
      expect(_rim(tester).intensity, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('外阴影路径是 evenOdd，且轮廓内部被挖空', (tester) async {
      const radius = 20.0;
      const rect = Rect.fromLTWH(0, 0, 240, 120);
      final path = OuterGlassShadowPainter.outsidePath(
        rect,
        BorderRadius.circular(radius),
      );
      expect(path.fillType, ui.PathFillType.evenOdd);
      // 轮廓之外、画布之内（左下角那个 20px 圆角切掉的地方）算在路径里
      // —— 阴影就是要画在这种"贴着轮廓外缘"的位置
      expect(path.contains(const Offset(2, 2)), isTrue);
      // 轮廓正中心：被挖空（清透内部不被阴影染色）
      expect(path.contains(const Offset(120, 60)), isFalse);
      // 轮廓里但贴边（上边中点内侧 4px）：同样挖空
      expect(path.contains(const Offset(120, 4)), isFalse);
      expect(tester.takeException(), isNull);
    });

    test('亮环是 3 层描边，宽度 1.6 / 3 / .65', () {
      final rim = LiquidRimPainter(
        radius: 20,
        light: const Offset(-.65, -.8),
        dark: false,
      );
      expect(rim.rimStroke, 1.6);
      expect(rim.innerGlowStroke, 3);
      expect(rim.innerStroke, .65);
      // 层数就是这三个宽度，多一层少一层都会在这里露出来
      expect({rim.rimStroke, rim.innerGlowStroke, rim.innerStroke}.length, 3);
    });

    test('shouldRepaint 认得出每个光学字段', () {
      LiquidRimPainter make({
        double intensity = 1,
        double press = 0,
        Offset light = const Offset(-.65, -.8),
      }) => LiquidRimPainter(
        radius: 20,
        light: light,
        dark: false,
        intensity: intensity,
        press: press,
      );
      final base = make();
      expect(base.shouldRepaint(make()), isFalse);
      expect(base.shouldRepaint(make(press: .5)), isTrue);
      expect(base.shouldRepaint(make(intensity: 0)), isTrue);
      expect(base.shouldRepaint(make(light: const Offset(1, 1))), isTrue);
    });
  });

  group('Stage B：GLSL 折射与自动回退', () {
    // 只挂 probe，不触发 fake 加载 —— 用装配层观测。
    testWidgets('探测为 false → BackdropFilter 内层是 ImageFilter.matrix（Stage A 原样）',
        (tester) async {
      await tester.pumpWidget(
        _surface(shaderSupported: false, child: const SizedBox.expand()),
      );
      await tester.pump();
      expect(_composeInner(tester), 'matrix');
      expect(tester.takeException(), isNull);
    });

    testWidgets('探测为 true → uniform 按 setFloat(2..6) 写入、内层换成 shader 路径',
        (tester) async {
      final probe = _ProbeShader();
      await tester.pumpWidget(
        _surface(
          shaderSupported: true,
          loader: () async => probe,
          child: const SizedBox.expand(),
        ),
      );
      await tester.pump();
      // u_radius / u_depth / u_light / u_press 都已写入，且索引从 2 起
      // —— u_size 占 0/1 由引擎写入，Dart 侧绝不碰。
      expect(probe.floats.length, greaterThanOrEqualTo(7));
      expect(probe.floats[2], 20); // borderRadius.topLeft.x
      expect(probe.floats[3], 9); // 非画布：9 * liquid(1)
      expect(probe.floats[4], LiquidGlassSurface.restLight.dx);
      expect(probe.floats[5], LiquidGlassSurface.restLight.dy);
      expect(probe.floats[6], 0); // 未按压
      expect(
        probe.floats.sublist(0, 2).every((v) => v == 0),
        isTrue,
        reason: '索引 0/1（u_size）必须保持引擎默认，Dart 侧不得写入',
      );
      // shader 路径真的进了装配层：探针滤镜被 _filter 消费。探针指纹：
      // _filter 把探针滤镜（blur(1) 套 blur(1)）当 inner、blur(5) 当 outer，
      // 全文是 `compose(source -> blur(1) -> blur(1) -> blur(5) -> result)`；
      // 降级路径（内层 matrix）的全文里永远不会出现 blur(1)。
      expect(probe.filterCalls, greaterThanOrEqualTo(1));
      final raw = tester
          .widgetList<BackdropFilter>(find.byType(BackdropFilter))
          .single
          .filter
          .toString();
      expect(raw, contains('blur(1.0, 1.0'), reason: 'raw=$raw');
      expect(raw, contains('-> blur(5.0, 5.0'), reason: 'raw=$raw');
      expect(tester.takeException(), isNull);
    });

    testWidgets('加载抛异常 → 静默回退 matrix 路径，takeException 为 null',
        (tester) async {
      var loadCalls = 0;
      await tester.pumpWidget(
        _surface(
          shaderSupported: true,
          loader: () async {
            loadCalls++;
            throw StateError('asset broken');
          },
          child: const SizedBox.expand(),
        ),
      );
      await tester.pump();
      expect(loadCalls, 1);
      expect(tester.takeException(), isNull);
      expect(_composeInner(tester), 'matrix');
    });

    testWidgets('探测为 false 时绝不触发加载（loader 一次都不被调用）',
        (tester) async {
      var loadCalls = 0;
      await tester.pumpWidget(
        _surface(
          shaderSupported: false,
          loader: () async {
            loadCalls++;
            throw StateError('must not be called');
          },
          child: const SizedBox.expand(),
        ),
      );
      await tester.pump();
      expect(loadCalls, 0);
      expect(_composeInner(tester), 'matrix');
      expect(tester.takeException(), isNull);
    });

    testWidgets('真机事实锚点：Windows/Skia 下探测为 false（isShaderFilterSupported）',
        (tester) async {
      await tester.pumpWidget(_surface(child: const SizedBox.expand()));
      await tester.pump();
      // 本机（Windows/Skia）的真实探测值；测试环境同样默认 Skia。
      expect(ui.ImageFilter.isShaderFilterSupported, isFalse);
      // 由此默认路径必然是 Stage A。
      expect(_composeInner(tester), 'matrix');
      expect(tester.takeException(), isNull);
    });

    testWidgets('负控制：探测恒 true 但加载走生产路径（无着色器环境）→ 静默回退不崩',
        (tester) async {
      // 不注入 loader —— 生产加载会真调 FragmentProgram.fromAsset：
      // 测试环境无 shader 资产注册表，加载必抛 → 证明「探测说支持 +
      // 加载失败」的组合同样静默回退，绝不崩、绝不进 shader 路径。
      await tester.pumpWidget(
        _surface(shaderSupported: true, child: const SizedBox.expand()),
      );
      await tester.pump();
      expect(ui.ImageFilter.isShaderFilterSupported, isFalse);
      expect(_composeInner(tester), 'matrix');
      expect(tester.takeException(), isNull);
    });
  });
}
