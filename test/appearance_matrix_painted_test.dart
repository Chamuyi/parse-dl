import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/app_card.dart';

/// 外观矩阵的**像素级**判据：`AppStyle × Brightness` 每一档都要能把
/// 「卡片内容真的被画出来」判出来，并且**在错误实现下必须判红**。
///
/// ### 为什么不是复用既有的 `card_content_painted_test.dart`
///
/// 那个文件用「数深色像素（三通道 < 80）> 1000」做判据。2026-10-19 实测
/// 该口径**在深色档恒真**，没有区分力：
///
/// | 组合 | 正常卡片 | 非 uniform 边框（内容消失） | 判据结论 |
/// |---|---|---|---|
/// | `winui · dark`  | 80000 | 80000 | **恒绿**（失效） |
/// | `winui · light` | 1958  | 112   | 有效 |
///
/// 原因是深色档的卡片底色 `surfaceCard = #1B1F27`（27,31,39）**本身就
/// 三通道 < 80**，整块卡片面积都被计成「深色像素」—— 内容画没画出来，
/// 数字都一样。于是「深色档」在形式上被遍历到了（`Brightness.values`），
/// 实质上**没有任何有效判据覆盖**：这正是本文件要补的那一档。
///
/// ### 判据口径
///
/// 改用**内容色像素**：卡片里放一个 80×80 的纯红方块（`#FF0000`），
/// 只数「红通道 > 170 且绿/蓝 < 90」的像素。红是内容色，**不是任何一档
/// 的背景色**，所以两档的背景都不会把它算进去：
///
/// * `winui · dark`  → 6400
/// * `winui · light` → 6400
///
/// 两档同值、且都远离 0，说明这个口径对两档都成立。
///
/// ### 与渲染日志 / 语义层的关系
///
/// 内容被材质或边框盖住时，widget 树完整、无障碍树文字俱在、渲染日志
/// 零异常（2026-10-15 真机缺陷就是这样穿过全部 1804 条判据的）。
/// 只有量像素能判出来，所以这里**不看 widget 树、只看渲染结果**。
void main() {
  const boundaryKey = ValueKey('appearance-matrix-boundary');

  /// 主判据阈值。实测正常实现 6400、错误实现 0，取 3000 落在两者中间：
  /// 正常实现有 2.1 倍余量，错误实现离阈值有 3000 的差距，两边都分得开。
  const int kContentPixelFloor = 3000;

  /// 纯红方块 —— 内容色。**不是**任何一档的背景色。
  const contentColor = Color(0xFFFF0000);

  /// 把卡片子树渲染成像素，数「内容色像素」。
  ///
  /// 取图前先 `pump()`：`toImage()` 要求目标 `RenderRepaintBoundary` 已经
  /// paint 过，否则会拿到 `NEEDS-PAINT` 的树并抛异常。
  Future<int> contentPixels(WidgetTester tester) async {
    await tester.pump();
    late final ui.Image image;
    await tester.runAsync(() async {
      image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey))
          .toImage();
    });
    late final ByteData? bd;
    await tester.runAsync(() async {
      bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    });
    final bytes = bd!.buffer.asUint8List();
    var hits = 0;
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      if (bytes[i] > 170 && bytes[i + 1] < 90 && bytes[i + 2] < 90) hits++;
    }
    return hits;
  }

  /// 泵一档外观。`broken` = 复刻**修复前**的实现（顶边与三边不同色的
  /// `Border`，`Border.isUniform == false`），它会让带圆角的 `BoxDecoration`
  /// 盖住子内容 —— 也就是真机上「卡片里什么都没有」的那个缺陷。
  Future<void> pump(
    WidgetTester tester,
    AppStyle style,
    Brightness brightness, {
    bool broken = false,
  }) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final colors =
        brightness == Brightness.light ? AppColors.light : AppColors.dark;

    const block = SizedBox(
      width: 80,
      height: 80,
      child: ColoredBox(color: contentColor),
    );

    final Widget card = broken
        ? Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.surfaceCard,
              borderRadius: BorderRadius.circular(12),
              border: const Border(
                top: BorderSide(color: Color(0xF2FFFFFF)),
                left: BorderSide(color: Color(0xBFFFFFFF)),
                right: BorderSide(color: Color(0xBFFFFFFF)),
                bottom: BorderSide(color: Color(0xBFFFFFFF)),
              ),
            ),
            child: block,
          )
        : const AppCard(child: block);

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
                child: SizedBox(width: 400, height: 200, child: card),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ══════════════════════════════════════════════════════════
  // 主判据：AppStyle × Brightness 全矩阵
  // ══════════════════════════════════════════════════════════
  for (final style in AppStyle.values) {
    for (final brightness in Brightness.values) {
      final label = '${style.name} · ${brightness.name}';
      testWidgets('$label：卡片内容真的被绘制（内容色像素）', (tester) async {
        await pump(tester, style, brightness);

        // 前置（语义层，单独不充分）：方块在树上
        expect(find.byType(ColoredBox), findsWidgets,
            reason: '$label：内容方块应当在树上');

        // 主判据（像素层）
        final hits = await contentPixels(tester);
        expect(
          hits,
          greaterThan(kContentPixelFloor),
          reason: '$label：卡片里的红色方块应当被画出来（实测 $hits 个内容色像素）。'
              '数量过少 = 内容被边框/材质盖住了 —— 语义层与渲染日志都判不出来，'
              '只有这一层能判。',
        );
      });
    }
  }

  // ══════════════════════════════════════════════════════════
  // 负控制：证明上面那条判据**在错误实现下会判红**
  //
  // 这里不新造一套断言，而是拿**主判据本身**（> kContentPixelFloor）去跑
  // 错误实现，并断言它确实抛 TestFailure。若它没有抛，说明这条判据是
  // 恒真的死判据 —— 那比没有判据更危险（既有的深色档就是这样）。
  // ══════════════════════════════════════════════════════════
  for (final style in AppStyle.values) {
    for (final brightness in Brightness.values) {
      final label = '${style.name} · ${brightness.name}';
      testWidgets('负控制：$label 内容被盖住时，主判据必须判红', (tester) async {
        await pump(tester, style, brightness, broken: true);

        // 非 uniform 边框是内容消失的根因；先钉住前提，否则负控制本身没意义
        const badBorder = Border(
          top: BorderSide(color: Color(0xF2FFFFFF)),
          left: BorderSide(color: Color(0xBFFFFFFF)),
          right: BorderSide(color: Color(0xBFFFFFFF)),
          bottom: BorderSide(color: Color(0xBFFFFFFF)),
        );
        expect(badBorder.isUniform, isFalse,
            reason: '前提：错误实现的边框必须是非 uniform，这是内容消失的根因');

        final hits = await contentPixels(tester).catchError((_) => -1);
        // 非 uniform 边框下子树可能停在 NEEDS-PAINT（toImage 抛异常），
        // 那也属于「内容没被画出来」；收走渲染阶段记下的异常，避免污染用例。
        tester.takeException();

        expect(
          () => expect(hits, greaterThan(kContentPixelFloor),
              reason: '$label：错误实现下内容应当被画出来'),
          throwsA(isA<TestFailure>()),
          reason: '负控制失败：错误实现（非 uniform 边框）下主判据竟然没判红'
              '（实测 $hits 个内容色像素）。若这条不再成立，说明判据已失去区分力，'
              '**不要**直接删掉主判据 —— 先复核本文件顶部的口径说明。',
        );
      });
    }
  }
}
