import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 「自定义色调」两个滑块（色调不透明度 / 明度不透明度）的参数化判据。
///
/// ### 为什么先钉「默认值不变性」
///
/// 这两个参数是把 `AppColors.tintFor` 里写死的两件事（混合权重 0.30/0.18、
/// alpha 217）拆成可调旋钮。拆的过程中只要有一点点偏移，压在这条链路上的
/// 既有像素判据（`style_backdrop_test.dart` 直接比对 `tintFor` 的返回值）
/// 就会成片变红。所以第一条判据钉的就是「默认参数 == 改造前那套算式」，
/// 而且钉的是**逐通道相等**，不是「差不多」。
///
/// 其余每条判据都配一条负控制 —— 判据全绿本身不能证明判据有效，
/// 必须先证明它在该红的时候会红。
void main() {
  /// 改造前 `tintFor` 的实现，逐字抄下来当「旧值」的独立出处。
  ///
  /// 关键：**不复用新实现里的任何辅助函数**（tintWeight / luminosityFactor
  /// / tintBaseFor 一个都不碰），否则新实现算错了它也一起错，判据恒真。
  Color legacyTintFor(Color tint, Brightness brightness) {
    final base = brightness == Brightness.dark
        ? const Color(0xFF18181B)
        : const Color(0xFFF3F3F3);
    final w = brightness == Brightness.dark ? 0.30 : 0.18;
    int mix(double t, double b) =>
        ((t * w + b * (1 - w)) * 255).round().clamp(0, 255);
    return Color.fromARGB(
      217,
      mix(tint.r, base.r),
      mix(tint.g, base.g),
      mix(tint.b, base.b),
    );
  }

  /// 一组覆盖明暗两档、含极端色值的取样。
  const samples = <Color>[
    Color(0xFF1D9BF0),
    Color(0xFFFF0000),
    Color(0xFF000000),
    Color(0xFFFFFFFF),
    Color(0xFF107C10),
    Color(0xFF7B2FF7),
  ];

  /// 两个颜色在 RGB 三通道上的欧氏距离（0~441.67）。
  double rgbDistance(Color a, Color b) {
    final dr = (a.r - b.r) * 255;
    final dg = (a.g - b.g) * 255;
    final db = (a.b - b.b) * 255;
    return math.sqrt(dr * dr + dg * dg + db * db);
  }

  // ══════════════════════════════════════════════════════════
  // 1. 默认值不变性（最重要）
  // ══════════════════════════════════════════════════════════
  group('默认值不变性', () {
    test('默认参数与改造前算式逐通道相等（明暗 × 6 个取样色）', () {
      for (final brightness in Brightness.values) {
        for (final tint in samples) {
          final now = AppColors.tintFor(tint, brightness);
          final legacy = legacyTintFor(tint, brightness);
          expect(
            [now.a, now.r, now.g, now.b],
            [legacy.a, legacy.r, legacy.g, legacy.b],
            reason: '默认参数下必须与改造前逐值相同（$brightness / $tint）',
          );
        }
      }
    });

    test('显式传默认值与省略参数，输出逐通道相等', () {
      for (final brightness in Brightness.values) {
        for (final tint in samples) {
          final implicit = AppColors.tintFor(tint, brightness);
          final explicit = AppColors.tintFor(
            tint,
            brightness,
            tintOpacity: 0.6,
            tintLuminosityOpacity: 0.3,
          );
          expect(
            [explicit.a, explicit.r, explicit.g, explicit.b],
            [implicit.a, implicit.r, implicit.g, implicit.b],
            reason: '省略参数与显式写默认值必须是同一件事',
          );
        }
      }
    });

    test('负控制：把默认值写歪 1/100 就会被抓到', () {
      const tint = Color(0xFF1D9BF0);
      final legacy = legacyTintFor(tint, Brightness.dark);
      // 权重偏一点点 —— 混合色会差出可测的量
      final off = AppColors.tintFor(
        tint,
        Brightness.dark,
        tintOpacity: 0.61,
      );
      expect(
        rgbDistance(off, legacy),
        greaterThan(0.5),
        reason: '若这条不红，上一条「逐值相等」就可能是恒真的',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 2. 单调性
  // ══════════════════════════════════════════════════════════
  group('色调不透明度单调性', () {
    test('0→1 时结果离主题底色越来越远（逐档严格递增）', () {
      for (final brightness in Brightness.values) {
        final base = AppColors.tintBaseFor(brightness);
        var prev = -1.0;
        for (var i = 0; i <= 10; i++) {
          final o = i / 10;
          final d = rgbDistance(
            AppColors.tintFor(
              const Color(0xFF1D9BF0),
              brightness,
              tintOpacity: o,
            ),
            base,
          );
          expect(
            d,
            greaterThan(prev),
            reason: 'tintOpacity=$o 时离底色应更远（$brightness）',
          );
          prev = d;
        }
      }
    });

    test('负控制：方向反过来会被单调性判据抓到', () {
      // 用「离 tint 的距离」量同一批点 —— 它必须**递减**；
      // 若判据写成双向都行，这条就会和上一条一起绿，等于没测。
      const tint = Color(0xFF1D9BF0);
      final base = AppColors.tintBaseFor(Brightness.dark);
      final far = AppColors.tintFor(tint, Brightness.dark, tintOpacity: 0.0);
      final near = AppColors.tintFor(tint, Brightness.dark, tintOpacity: 1.0);
      expect(
        rgbDistance(far, base),
        lessThan(rgbDistance(near, base)),
        reason: '反向断言必须成立，否则上一条的「递增」是巧合',
      );
    });
  });

  group('明度不透明度单调性', () {
    test('0→1 时结果越来越接近主题底色（越透越不浓）', () {
      for (final brightness in Brightness.values) {
        final base = AppColors.tintBaseFor(brightness);
        var prev = double.infinity;
        for (var i = 0; i <= 10; i++) {
          final l = i / 10;
          final d = rgbDistance(
            AppColors.tintFor(
              const Color(0xFF1D9BF0),
              brightness,
              tintLuminosityOpacity: l,
            ),
            base,
          );
          expect(
            d,
            lessThan(prev),
            reason: 'tintLuminosityOpacity=$l 时更接近底色（$brightness）',
          );
          prev = d;
        }
      }
    });

    test('负控制：把语义写反（越大越浓）会被上一条抓到', () {
      const tint = Color(0xFF1D9BF0);
      final base = AppColors.tintBaseFor(Brightness.light);
      final thin = AppColors.tintFor(
        tint,
        Brightness.light,
        tintLuminosityOpacity: 1.0,
      );
      final thick = AppColors.tintFor(
        tint,
        Brightness.light,
        tintLuminosityOpacity: 0.0,
      );
      expect(
        rgbDistance(thin, base),
        lessThan(rgbDistance(thick, base)),
        reason: '1.0 应比 0.0 更透；这条红了说明单调方向判据本身站不住',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 3. 两个参数都不是摆设
  // ══════════════════════════════════════════════════════════
  group('两个参数各取极值时颜色确实不同', () {
    test('色调不透明度 0 vs 1：差到肉眼可辨的量级', () {
      for (final brightness in Brightness.values) {
        final a = AppColors.tintFor(
          const Color(0xFF1D9BF0),
          brightness,
          tintOpacity: 0.0,
        );
        final b = AppColors.tintFor(
          const Color(0xFF1D9BF0),
          brightness,
          tintOpacity: 1.0,
        );
        expect(
          rgbDistance(a, b),
          greaterThan(20),
          reason: '两个极值必须真的不同（$brightness）',
        );
      }
    });

    test('明度不透明度 0 vs 1：差到肉眼可辨的量级', () {
      for (final brightness in Brightness.values) {
        final a = AppColors.tintFor(
          const Color(0xFF1D9BF0),
          brightness,
          tintLuminosityOpacity: 0.0,
        );
        final b = AppColors.tintFor(
          const Color(0xFF1D9BF0),
          brightness,
          tintLuminosityOpacity: 1.0,
        );
        expect(
          rgbDistance(a, b),
          greaterThan(20),
          reason: '明度层不是摆设（$brightness）',
        );
      }
    });

    test('负控制：两个参数各管一段，互不吞掉', () {
      const tint = Color(0xFF1D9BF0);
      final base = AppColors.tintBaseFor(Brightness.dark);
      // 固定色调不透明度，只推明度层 —— 结果必须跟着动。
      final lumLo = AppColors.tintFor(
        tint,
        Brightness.dark,
        tintLuminosityOpacity: 0.0,
      );
      final lumHi = AppColors.tintFor(
        tint,
        Brightness.dark,
        tintLuminosityOpacity: 1.0,
      );
      expect(rgbDistance(lumLo, lumHi), greaterThan(1.0),
          reason: '固定浓度时明度层必须仍然有效');

      // 反向：固定明度层，只推浓度 —— 结果也必须跟着动。
      final oLo = AppColors.tintFor(tint, Brightness.dark, tintOpacity: 0.0);
      final oHi = AppColors.tintFor(tint, Brightness.dark, tintOpacity: 1.0);
      expect(rgbDistance(oLo, oHi), greaterThan(1.0),
          reason: '固定明度层时浓度必须仍然有效');

      // 量纲不同的两条：浓度的极值跨度远大于明度层（0.30 vs 0.15 权重差），
      // 若实现里一个参数吞掉了另一个，这两个跨度会相等。
      expect(
        rgbDistance(oLo, oHi),
        greaterThan(rgbDistance(lumLo, lumHi)),
        reason: '两个旋钮的跨度不同，说明它们是两条独立通路',
      );
      expect(rgbDistance(lumHi, base), lessThan(rgbDistance(lumLo, base)));
    });
  });

  // ══════════════════════════════════════════════════════════
  // 4. 数据层
  // ══════════════════════════════════════════════════════════
  group('AppearanceSettings 数据层', () {
    test('默认值 0.6 / 0.3', () {
      final a = AppearanceSettings();
      expect(a.tintOpacity, 0.6);
      expect(a.tintLuminosityOpacity, 0.3);
    });

    test('往返编解码保留取值', () {
      final a = AppearanceSettings(
        tintOpacity: 0.42,
        tintLuminosityOpacity: 0.77,
      );
      final r = AppearanceSettings.fromJson(a.toJson());
      expect(r.tintOpacity, 0.42);
      expect(r.tintLuminosityOpacity, 0.77);
      expect(a.toJson()['tintOpacity'], 0.42);
      expect(a.toJson()['tintLuminosityOpacity'], 0.77);
    });

    test('旧配置缺字段 → 落默认值', () {
      final a = AppearanceSettings.fromJson({'themeMode': 'dark'});
      expect(a.tintOpacity, 0.6);
      expect(a.tintLuminosityOpacity, 0.3);
    });

    test('越界值 clamp 到 0..1', () {
      final hi = AppearanceSettings.fromJson({
        'tintOpacity': 3.5,
        'tintLuminosityOpacity': 9,
      });
      expect(hi.tintOpacity, 1.0);
      expect(hi.tintLuminosityOpacity, 1.0);

      final lo = AppearanceSettings.fromJson({
        'tintOpacity': -2,
        'tintLuminosityOpacity': -0.4,
      });
      expect(lo.tintOpacity, 0.0);
      expect(lo.tintLuminosityOpacity, 0.0);
    });

    test('坏值（NaN / 无穷 / 字符串）落默认值', () {
      final a = AppearanceSettings.fromJson({
        'tintOpacity': double.nan,
        'tintLuminosityOpacity': double.infinity,
      });
      expect(a.tintOpacity, 0.6);
      expect(a.tintLuminosityOpacity, 0.3);

      final b = AppearanceSettings.fromJson({'tintOpacity': '0.9'});
      expect(b.tintOpacity, 0.6);
    });

    test('负控制：clamp 与落默认是两件事，别互相顶替', () {
      // 越界要 clamp（0.5 变不了 0.6），坏值要落默认（不是 0）——
      // 若实现把所有异常输入一律当 0，这两条会给出不同的期望值。
      expect(AppearanceSettings.fromJson({'tintOpacity': 0.5}).tintOpacity, 0.5);
      expect(
        AppearanceSettings.fromJson({'tintOpacity': double.nan}).tintOpacity,
        isNot(0.0),
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 5. 像素级：把 tintFor 的输出真的画出来，量渲染像素
  // ══════════════════════════════════════════════════════════
  //
  // 为什么不是渲染 BackgroundLayer：本轮禁止改 `background_layer.dart`
  // （另一条改动正在改它），它当前调 `tintFor` 时**没有**传这两个新参数，
  // 所以从它那里量不到滑块的效果。这里改为直接把 `tintFor` 的返回值铺成
  // 一块色并读真实像素 —— 走的是完整渲染管线，不是「比较两个 Color 对象」。
  group('像素级：tintFor 输出经渲染管线后的平均色差', () {
    const boundaryKey = ValueKey('tint-boundary');

    Future<List<int>> renderAverage(
      WidgetTester tester,
      Color color,
    ) async {
      tester.view.physicalSize = const Size(120, 80);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: ColoredBox(color: color, child: const SizedBox.expand()),
        ),
      );
      await tester.pump();

      late final ui.Image image;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        image = await b.toImage();
      });
      late final ByteData? bd;
      await tester.runAsync(() async {
        bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      });
      final bytes = bd!.buffer.asUint8List();
      var r = 0, g = 0, b = 0, n = 0;
      for (var i = 0; i + 3 < bytes.length; i += 4) {
        r += bytes[i];
        g += bytes[i + 1];
        b += bytes[i + 2];
        n++;
      }
      return [r ~/ n, g ~/ n, b ~/ n];
    }

    double meanDelta(List<int> a, List<int> b) =>
        ((a[0] - b[0]).abs() + (a[1] - b[1]).abs() + (a[2] - b[2]).abs()) /
            3;

    testWidgets('色调不透明度极值：平均色差 ≥ 阈值', (tester) async {
      const tint = Color(0xFF1D9BF0);
      final lo = await renderAverage(
        tester,
        AppColors.tintFor(tint, Brightness.dark, tintOpacity: 0.0),
      );
      final hi = await renderAverage(
        tester,
        AppColors.tintFor(tint, Brightness.dark, tintOpacity: 1.0),
      );
      expect(meanDelta(lo, hi), greaterThanOrEqualTo(3.0),
          reason: '实测均值 $lo vs $hi');
    });

    testWidgets('明度不透明度极值：平均色差 ≥ 阈值', (tester) async {
      const tint = Color(0xFF1D9BF0);
      final lo = await renderAverage(
        tester,
        AppColors.tintFor(tint, Brightness.dark, tintLuminosityOpacity: 0.0),
      );
      final hi = await renderAverage(
        tester,
        AppColors.tintFor(tint, Brightness.dark, tintLuminosityOpacity: 1.0),
      );
      expect(meanDelta(lo, hi), greaterThanOrEqualTo(3.0),
          reason: '实测均值 $lo vs $hi');
    });

    testWidgets('负控制：同一颜色渲染两次 → 平均色差为 0', (tester) async {
      final c = AppColors.tintFor(
        const Color(0xFF1D9BF0),
        Brightness.dark,
        tintOpacity: 0.6,
        tintLuminosityOpacity: 0.3,
      );
      final a = await renderAverage(tester, c);
      final b = await renderAverage(tester, c);
      expect(meanDelta(a, b), 0.0,
          reason: '同色必须同像素，否则上面的阈值判据量到的是噪声');
    });
  });
}
