import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 液体玻璃的材质参数（光学数值；内容刻意留在 state 之外）。
@immutable
class GlassMaterial {
  const GlassMaterial({
    required this.blur,
    required this.liquid,
    required this.decoration,
  });

  /// 背板高斯模糊 sigma。
  final double blur;

  /// 液态程度：`<= .001` 视为非液态，不折射（光学静止）。
  final double liquid;

  final BoxDecoration decoration;

  factory GlassMaterial.liquid({
    required Color tint,
    required bool dark,
    required BorderRadius borderRadius,
    bool readable = false,
  }) => GlassMaterial(
    blur: 5,
    liquid: 1,
    decoration: BoxDecoration(
      borderRadius: borderRadius,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          tint.withValues(alpha: readable
              ? .88
              : dark
              ? .40
              : .25),
          tint.withValues(alpha: readable
              ? .82
              : dark
              ? .24
              : .09),
          tint.withValues(alpha: readable
              ? .88
              : dark
              ? .34
              : .18),
        ],
      ),
    ),
  );
}

/// 跨平台的液体玻璃材质。
///
/// Impeller 有着色器逐像素折射（Stage B）；其它后端（Windows / Skia 默认）
/// 走**降级路径**：真实的放大背板滤镜 + 同一套光照跟随与按压反馈 + 内缘亮环。
///
/// 光照跟随与按压都只驱动 `Listenable` 重建**光学图层**，
/// 子树（`child`）不参与重建 —— 见 [_optics]。
class LiquidGlassSurface extends StatefulWidget {
  const LiquidGlassSurface({
    super.key,
    required this.child,
    required this.tint,
    required this.dark,
    required this.borderRadius,
    this.canvas = false,
    this.material,
  });

  final Widget child;
  final Color tint;
  final bool dark;

  /// 透明画布（不采样 OS 桌面，内部不绘制背板，只留亮环）。
  final bool canvas;

  /// 不传则按 `tint` / `dark` 现算一份液态材质。
  final GlassMaterial? material;

  final BorderRadius borderRadius;

  /// 按压前推的时长。
  static const Duration pressForward = Duration(milliseconds: 180);

  /// 按压回退的时长（比前推慢，收得柔）。
  static const Duration pressReverse = Duration(milliseconds: 320);

  /// Stage B 着色器的 asset 键；加载失败静默回退降级路径。
  static const String shaderAsset = 'shaders/liquid_glass.frag';

  /// 静止时的光照方向。
  static const Offset restLight = Offset(-.65, -.8);

  /// 鼠标归一化位置的生效阈值（distanceSquared）。
  static const double lightThreshold = .0004;

  /// 降级路径的放大折射倍率：`1 + k * liquid * (1 + .3 * press)`。
  ///
  /// 纯函数，`_filter` 直接调用它 —— 测试断言的就是这里。
  static double zoomOf(double liquid, double press, {bool canvas = false}) =>
      1 + (canvas ? .004 : .014) * liquid * (1 + .3 * press);

  /// Stage B 探测与加载的**注入点**（测试用它驱动 shader / 降级两条路径，
  /// 不碰真实 GPU）。生产代码不赋值，走 SDK 真值。
  @visibleForTesting
  static bool Function()? shaderSupported;

  @visibleForTesting
  static Future<GlassShader> Function()? shaderLoader;

  @override
  State<LiquidGlassSurface> createState() => _LiquidGlassSurfaceState();
}

class _LiquidGlassSurfaceState extends State<LiquidGlassSurface>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram>? _program;

  bool _shaderSupported() =>
      LiquidGlassSurface.shaderSupported?.call() ??
      ui.ImageFilter.isShaderFilterSupported;

  GlassShader? _glassShader;
  bool _loadingShader = false;
  late final AnimationController _press;

  /// 光照方向，归一化到 `[-1, 1]`。用 ValueNotifier 而不是 setState：
  /// 鼠标划过只重画光学图层，不重建子树。
  final ValueNotifier<Offset> _light = ValueNotifier(
    LiquidGlassSurface.restLight,
  );

  late final Listenable _optics = Listenable.merge([_light, _press]);

  bool get _filterEnabled => !widget.canvas;

  bool get _needsRefraction => (widget.material?.liquid ?? 1) > .001;

  bool get _motionEnabled =>
      !MediaQuery.disableAnimationsOf(context) &&
      TickerMode.valuesOf(context).enabled;

  @override
  void initState() {
    super.initState();
    _press =
        AnimationController(
          vsync: this,
          duration: LiquidGlassSurface.pressForward,
          reverseDuration: LiquidGlassSurface.pressReverse,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) _press.reverse();
        });
    if (_filterEnabled && _needsRefraction && _shaderSupported()) {
      _loadShader();
    }
  }

  @override
  void didUpdateWidget(LiquidGlassSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_needsRefraction) _resetInteraction();
    if (_filterEnabled &&
        _needsRefraction &&
        _glassShader == null &&
        _shaderSupported()) {
      _loadShader();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_motionEnabled) _resetInteraction();
  }

  /// Stage B 加载：成功则 `setState` 挂上 shader（下一次 build 走 GLSL 折射）；
  /// 失败（后端/资产/注入的假加载器抛错）**静默回退**到降级路径 —— 绝不崩。
  Future<void> _loadShader() async {
    if (_loadingShader) return;
    _loadingShader = true;
    try {
      final loader =
          LiquidGlassSurface.shaderLoader ?? _loadDefaultProgramShader;
      final shader = await loader();
      if (mounted && _filterEnabled && _needsRefraction) {
        setState(() => _glassShader = shader);
      }
    } catch (_) {
      // 后端/资产/测试注入的加载器失败时保持放大折射的降级材质。
    } finally {
      _loadingShader = false;
    }
  }

  /// 生产加载路径：读 asset 的程序并取一个 fragment shader。
  /// 与 morrow 一致：程序级缓存（静态 `_program`），shader 每次新取。
  ///
  /// 末尾的**金丝雀**在加载期就地验证两件事（任何一条不满足都算加载失败，
  /// 走静默回退，而不是等 build 期才炸）：
  /// - 后端真的支持 `ImageFilter.shader`（探测说支持但后端撒谎时在这里暴露）；
  /// - SDK 契约「第一个 uniform 是 vec2」（`u_size`）成立，否则抛 `StateError`。
  static Future<GlassShader> _loadDefaultProgramShader() async {
    final program = await (_program ??=
        ui.FragmentProgram.fromAsset(LiquidGlassSurface.shaderAsset));
    final shader = program.fragmentShader();
    ui.ImageFilter.shader(shader);
    return SdkGlassShader(shader);
  }

  void _resetInteraction() {
    if (_press.isAnimating || _press.value != 0) _press.reset();
    if (_light.value != LiquidGlassSurface.restLight) {
      _light.value = LiquidGlassSurface.restLight;
    }
  }

  @override
  void dispose() {
    _glassShader?.dispose();
    _press.dispose();
    _light.dispose();
    super.dispose();
  }

  /// 降级路径的核心：**先模糊、再折射**（`compose(outer: 模糊, inner: 折射)`），
  /// 顺序不能反。Stage B 可用时内层换成逐像素折射的 shader 滤镜。
  ui.ImageFilter _filter(Size size, GlassMaterial material) {
    if (material.liquid <= .001) {
      return ui.ImageFilter.blur(sigmaX: material.blur, sigmaY: material.blur);
    }
    final ui.ImageFilter refraction;
    if (_glassShader case final shader?) {
      shader
        ..setFloat(2, widget.borderRadius.topLeft.x) // u_radius
        ..setFloat(3, (widget.canvas ? 4 : 9) * material.liquid) // u_depth
        ..setFloat(4, _light.value.dx) // u_light.x
        ..setFloat(5, _light.value.dy) // u_light.y
        ..setFloat(6, _press.value); // u_press
      // u_size（索引 0/1）由引擎按采样区域自动写入，Dart 侧只填 2..6。
      refraction = shader.filter();
    } else {
      final zoom = LiquidGlassSurface.zoomOf(
        material.liquid,
        _press.value,
        canvas: widget.canvas,
      );
      final transform = Matrix4.identity()
        ..setEntry(0, 0, zoom)
        ..setEntry(1, 1, zoom)
        // 缩放后必须重新居中，否则内容被往左上拽。
        ..setEntry(0, 3, size.width * (1 - zoom) / 2)
        ..setEntry(1, 3, size.height * (1 - zoom) / 2);
      refraction = ui.ImageFilter.matrix(transform.storage);
    }
    return ui.ImageFilter.compose(
      outer: ui.ImageFilter.blur(sigmaX: material.blur, sigmaY: material.blur),
      inner: refraction,
    );
  }

  /// 把指针位置归一化到 `[-1, 1]`；变化不足阈值就**不通知**（省重绘）。
  void _updateLight(PointerEvent event) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || box.size.isEmpty) return;
    final point = box.globalToLocal(event.position);
    final next = Offset(
      (point.dx / box.size.width * 2 - 1).clamp(-1.0, 1.0),
      (point.dy / box.size.height * 2 - 1).clamp(-1.0, 1.0),
    );
    if ((_light.value - next).distanceSquared >
        LiquidGlassSurface.lightThreshold) {
      _light.value = next;
    }
  }

  void _pressAt(PointerDownEvent event) {
    if (!_needsRefraction || !_motionEnabled) return;
    // 非触摸设备只认主键：右键/中键不该触发放大。
    if (event.kind != ui.PointerDeviceKind.touch &&
        (event.buttons & kPrimaryButton) == 0) {
      return;
    }
    _updateLight(event);
    _press.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final motionEnabled = _motionEnabled;
    final material =
        widget.material ??
        GlassMaterial.liquid(
          tint: widget.tint,
          dark: widget.dark,
          readable: MediaQuery.highContrastOf(context),
          borderRadius: widget.borderRadius,
        );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _pressAt,
      onPointerCancel: (_) => _resetInteraction(),
      child: MouseRegion(
        onHover: !motionEnabled || !_needsRefraction ? null : _updateLight,
        onExit: !motionEnabled || !_needsRefraction
            ? null
            : (_) => _light.value = LiquidGlassSurface.restLight,
        child: CustomPaint(
          painter: widget.canvas
              ? null
              : OuterGlassShadowPainter(
                  borderRadius: widget.borderRadius,
                  shadows: material.decoration.boxShadow ?? const [],
                ),
          child: ClipRRect(
            borderRadius: widget.borderRadius,
            child: Stack(
              children: [
                if (_filterEnabled)
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _optics,
                      builder: (_, _) => LayoutBuilder(
                        builder: (_, constraints) => BackdropFilter(
                          filter: _filter(constraints.biggest, material),
                          child: DecoratedBox(
                            decoration: material.decoration.copyWith(
                              boxShadow: const [],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                widget.child,
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _optics,
                      builder: (_, _) => CustomPaint(
                        painter: LiquidRimPainter(
                          radius: widget.borderRadius.topLeft.x,
                          light: _light.value,
                          dark: widget.dark,
                          canvas: widget.canvas,
                          intensity: material.liquid,
                          press: _press.value,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 把模糊阴影**裁在轮廓外侧**。清透材质的内部是透明的，
/// 偏移出去的阴影不该把里面染色。
class OuterGlassShadowPainter extends CustomPainter {
  const OuterGlassShadowPainter({
    required this.borderRadius,
    required this.shadows,
  });

  final BorderRadius borderRadius;
  final List<BoxShadow> shadows;

  /// 轮廓外侧的裁剪路径：外框矩形 + 圆角轮廓，`evenOdd` 让轮廓内部被挖空。
  static Path outsidePath(Rect bounds, BorderRadius borderRadius) => Path()
    ..fillType = ui.PathFillType.evenOdd
    ..addRect(bounds)
    ..addRRect(borderRadius.toRRect(bounds));

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || shadows.isEmpty) return;
    final outline = borderRadius.toRRect(Offset.zero & size);
    canvas.save();
    canvas.clipPath(outsidePath(canvas.getLocalClipBounds(), borderRadius));
    for (final shadow in shadows) {
      canvas.drawRRect(
        outline.shift(shadow.offset).inflate(shadow.spreadRadius),
        shadow.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(OuterGlassShadowPainter old) =>
      old.borderRadius != borderRadius || old.shadows != shadows;
}

/// 内缘亮环：3 层描边。主环用随 [light] 旋转的 4 段渐变。
///
/// 字段全部公开 —— 它们是**可观测状态**，交互判据直接断言这里。
class LiquidRimPainter extends CustomPainter {
  LiquidRimPainter({
    required this.radius,
    required this.light,
    required this.dark,
    this.canvas = false,
    this.intensity = 1,
    this.press = 0,
  });

  /// 液态程度；`<= 0` 不画（光学静止）。
  final double intensity;

  final double press;
  final double radius;

  /// 归一化到 `[-1, 1]` 的光照方向。
  final Offset light;

  final bool dark, canvas;

  /// 主环描边宽度。
  final double rimStroke = 1.6;

  /// 内侧柔光描边宽度。
  final double innerGlowStroke = 3;

  /// 次环描边宽度。
  final double innerStroke = .65;

  /// 主环渐变方向（`light` 为起点的对角）。
  Alignment get lightDirection => Alignment(light.dx, light.dy);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || intensity <= 0) return;
    final rect = (Offset.zero & size).deflate(.8);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final glow = 1 + .38 * press;
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rimStroke
        ..shader = LinearGradient(
          begin: lightDirection,
          end: Alignment(-light.dx, -light.dy),
          colors: [
            Colors.white.withValues(
              alpha: ((dark ? .70 : .94) * intensity * glow)
                  .clamp(0.0, 1.0)
                  .toDouble(),
            ),
            Colors.white.withValues(alpha: .08 * intensity),
            Colors.white.withValues(alpha: .12 * intensity),
            Colors.white.withValues(
              alpha: (.55 * intensity * glow).clamp(0.0, 1.0).toDouble(),
            ),
          ],
          stops: const [0, .36, .66, 1],
        ).createShader(rect),
    );
    canvas.drawRRect(
      rrect.deflate(2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = innerGlowStroke
        ..shader = LinearGradient(
          begin: lightDirection,
          end: Alignment.center,
          colors: [
            Colors.white.withValues(alpha: .17 * intensity),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
    canvas.drawRRect(
      rrect.deflate(5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = innerStroke
        ..color = Colors.white.withValues(alpha: .10 * intensity),
    );
  }

  @override
  bool shouldRepaint(LiquidRimPainter old) =>
      old.intensity != intensity ||
      old.press != press ||
      old.radius != radius ||
      old.light != light ||
      old.dark != dark ||
      old.canvas != canvas;
}

/// Stage B 的着色器抽象：组件通过它写 uniform 并产出折射滤镜。
///
/// SDK 的 `ui.FragmentProgram` / `ui.FragmentShader` 都是 `base class`，
/// 测试造不出实例 —— 可注入性的落点就是这层薄封装：生产实现
/// [SdkGlassShader] 包真 shader，测试注入记录 uniform 的 fake。
abstract class GlassShader {
  /// 写 float uniform（索引即 frag 里 uniform 的声明序，采样器不占位）。
  void setFloat(int index, double value);

  /// Stage B 的折射滤镜（`_filter` 的内层）。
  ui.ImageFilter filter();

  /// 释放底层资源。
  void dispose();
}

/// 生产实现：包 SDK fragment shader；dispose 时置脏，之后任何
/// `filter()` 调用都显式抛错（防把已释放的 shader 交回渲染管线）。
class SdkGlassShader implements GlassShader {
  SdkGlassShader(this._shader);

  final ui.FragmentShader _shader;
  bool _disposed = false;

  @override
  void setFloat(int index, double value) {
    if (_disposed) {
      throw StateError('GlassShader used after dispose');
    }
    _shader.setFloat(index, value);
  }

  @override
  ui.ImageFilter filter() {
    if (_disposed) {
      throw StateError('GlassShader used after dispose');
    }
    return ui.ImageFilter.shader(_shader);
  }

  @override
  void dispose() {
    _disposed = true;
    _shader.dispose();
  }
}
