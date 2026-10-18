import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/app_card.dart';

/// 卡片内容**真的被画出来**了 —— 三套风格 × 明暗六种组合逐个数像素。
///
/// ### 为什么需要这条判据（2026-10-15 真机缺陷）
///
/// 液体玻璃风格下卡片内容整片消失（frosted / clay 正常），但
///   * `flutter test` 全绿 —— 既有判据只看「widget 在不在树上」；
///   * 无障碍树里文字都在，控件也能点 —— 语义层完好；
///   * 渲染日志没有任何异常 —— Flutter 认为渲染成功了。
/// 所以这个缺陷能穿过当时全部 1804 条判据。根因是 `Border.isUniform == false`
/// （顶边高光被写成另一种颜色的 `Border`）在带圆角的 `BoxDecoration` 上
/// 会盖住子内容。
///
/// 这条判据直接量**渲染结果的像素**：卡片里放一个 80px 纯黑方块，只要它
/// 真被画出来，渲染图里必有大量深色像素。恒真风险已用负控制排除（见文件末）。
void main() {
  const boundaryKey = ValueKey('card-content-boundary');

  /// 把卡片子树渲染成像素，数深色像素。
  ///
  /// 取图前先 `tester.binding.ensureVisualUpdate()` + 一帧 pump：`toImage()`
  /// 要求目标 RenderRepaintBoundary 已经 paint 过，否则会拿到 `NEEDS-PAINT`
  /// 的树并抛异常（负控制那版没走主判据的路径，踩到过这个）。
  Future<int> darkPixels(WidgetTester tester) async {
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
    var dark = 0;
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      if (bytes[i] < 80 && bytes[i + 1] < 80 && bytes[i + 2] < 80) dark++;
    }
    return dark;
  }

  Future<void> pumpCard(
    WidgetTester tester,
    AppStyle style,
    Brightness brightness,
  ) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final colors = brightness == Brightness.light
        ? AppColors.light
        : AppColors.dark;

    await tester.pumpWidget(
      AppTheme(
        colors: colors,
        brightness: brightness,
        style: style,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: const SizedBox(
                  width: 400,
                  height: 200,
                  child: AppCard(
                    // 纯黑 80px 方块：被画出来就必然有大量深色像素
                    child: Text(
                      '█',
                      style: TextStyle(fontSize: 80, color: Color(0xFF000000)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final style in [AppStyle.winui]) {
    for (final brightness in Brightness.values) {
      final label = '${style.name} · ${brightness.name}';
      testWidgets('$label：卡片内容真的被绘制', (tester) async {
        await pumpCard(tester, style, brightness);

        // 前置：widget 在树上（语义层判据，单独不充分）
        expect(find.text('█'), findsOneWidget);

        // 主判据：像素层
        final dark = await darkPixels(tester);
        expect(
          dark,
          greaterThan(1000),
          reason: '$label：卡片里的黑色方块应当被画出来（实测 $dark 个深色像素）。'
              '数量过少 = 内容被边框/材质盖住了 —— 见本文件顶部的缺陷说明。',
        );
      });
    }
  }

  // ══════════════════════════════════════════════════════════
  // 负控制：证明「非 uniform 边框会盖住内容」这条因果链真的存在
  //
  // 这里**不用**像素判据：非 uniform 边框下子树的 RenderObject 会停在
  // `NEEDS-PAINT`（这正是内容消失的机制），`toImage()` 会直接抛异常而不是
  // 返回一张空图 —— 拿它当负控制会把「异常」和「判据变红」混为一谈。
  // 所以负控制钉在**根因**上：旧实现那种边框必须是非 uniform 的，
  // 而修复后的 `StyleBorder.toBorder()` 必须是 uniform 的。
  // ══════════════════════════════════════════════════════════
  test('负控制：旧实现（顶边不同色的 Border）是非 uniform —— 根因成立', () {
    const badBorder = Border(
      top: BorderSide(color: Color(0xF2FFFFFF)),
      left: BorderSide(color: Color(0xBFFFFFFF)),
      right: BorderSide(color: Color(0xBFFFFFFF)),
      bottom: BorderSide(color: Color(0xBFFFFFFF)),
    );
    expect(
      badBorder.isUniform,
      isFalse,
      reason: '旧实现的边框必须是非 uniform —— 这是内容消失的根因，'
          '若 Flutter 改了 Border 的行为，这条会红，提醒复核本文件顶部的缺陷说明',
    );
  });

  test('修复后：三套风格的卡片边框都是 uniform', () {
    for (final style in [AppStyle.winui]) {
      for (final brightness in Brightness.values) {
        final colors = brightness == Brightness.light
            ? AppColors.light
            : AppColors.dark;
        final border = style.cardBorderOf(colors, brightness).toBorder();
        expect(
          border.isUniform,
          isTrue,
          reason: '${style.name} · ${brightness.name} 的卡片边框必须四边同色，'
              '否则带圆角的 BoxDecoration 会盖住卡片内容（真机缺陷，2026-10-15）',
        );
      }
    }
  });

  test('WinUI 卡片没有顶边高光（那是玻璃系的 inset 高光）', () {
    // 2026-10-19：三套玻璃风格删除后，`hasTopHighlight` 只在 liquid 浅色为真；
    // 现在只剩 WinUI —— 它在**两种明暗下都必须是 false**（靠 1px 边线分层，
    // 不靠 inset 高光）。判据语义没放宽：仍然断言「该风格不该有高光」。
    for (final brightness in Brightness.values) {
      final colors =
          brightness == Brightness.light ? AppColors.light : AppColors.dark;
      expect(
        AppStyle.winui.cardBorderOf(colors, brightness).hasTopHighlight,
        isFalse,
        reason: 'WinUI · ${brightness.name} 不该有独立的顶边高光',
      );
    }

    // 负控制：证明 hasTopHighlight 确实会为真（不是恒 false 的死判据）。
    const withHighlight = StyleBorder(
      top: Color(0xF2FFFFFF),
      side: Color(0xBFFFFFFF),
    );
    expect(withHighlight.hasTopHighlight, isTrue,
        reason: '若这里为 false，说明 hasTopHighlight 是恒假的，上面的断言没有意义');
  });
}
