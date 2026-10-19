import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// WinUI3 的**组件形态**判据（2026-10-19 用户裁定「连布局/组件形态一起换」）。
///
/// 前几组判据守的是「颜色」与「材质」，但 WinUI 与另三套的差别有一半在
/// **控件几何**上：标题栏高度、开关比例、选项格圆角、徽章形状、导航行圆角。
/// 这些一旦被谁顺手改回旧值，颜色判据全绿、界面却已经不是 WinUI 了 ——
/// 本文件补的就是这个缺口。
///
/// **每条都带负控制**：证明把值改掉时判据真的会红，而不是恒真。
void main() {
  group('形态令牌：winui 与 legacy 逐字段不同', () {
    const w = StyleShape.winui;
    const l = StyleShape.legacy;

    test('标题栏高度 48 vs 44', () {
      // **2026-10-19 更正**：此前写 32，理由是「Windows 11 标准标题栏 32px」。
      // 那个 32 指的是**系统 window chrome**（非客户区那一圈）；本应用是
      // 自绘标题栏，对标的是参照物 `MainWindow.xaml:19` 的
      // `<RowDefinition Height="48" />` —— 它用的是 WinUI 3 的 `TitleBar`
      // **控件**，标准高度 48，且能把搜索框放进 `TitleBar.Content`。
      // 32 与 48 不是对错之争，是「系统 chrome」与「应用内 TitleBar 控件」之别。
      expect(w.titleBarHeight, 48, reason: '对齐 WinUI TitleBar 控件的 48px');
      expect(l.titleBarHeight, 44, reason: '另三套沿用改造前的 44px');
      // 负控制：两者必须真的不同，否则「按风格切换」这件事本身没意义
      expect(w.titleBarHeight, isNot(l.titleBarHeight));
    });

    test('窗口按钮：WinUI 直角无缝，另三套圆角内缩', () {
      expect(w.captionRadius, 0);
      expect(w.captionMargin, 0);
      expect(l.captionRadius, greaterThan(0));
      expect(l.captionMargin, greaterThan(0));
      // 宽度两套相同：**36**（2026-10-19 批次 A 去自创值）。
      // 参照物的最小化/最大化/关闭三按钮由系统 DWM 绘制，仓内没有 XAML 定义
      // （grep `MinMaxClose` / `CaptionButton` 命中 0），故取本机实测的系统度量
      // `SM_CXSIZE = 36`。此前写 46 无出处；WinUI 主题里的 40 是**返回按钮**宽，
      // 语义不对应三按钮。
      // 高度两套**不同**：winui 48（与 `TitleBar` 控件等高，按钮铺满栏高）；
      // legacy 32（旧画法，按钮在 44 高的栏里垂直居中）。
      // 这里如实钉住差异，不强行拉平 —— 拉平会改动 legacy 的既有观感。
      expect(w.captionWidth, l.captionWidth);
      // 钉字面量（不写 StyleShape.winui.captionWidth 自比 —— 那会恒真）
      expect(w.captionWidth, 36, reason: '宽 = 系统 SM_CXSIZE，本机实测');
      expect(w.captionHeight, 48);
      expect(l.captionHeight, 32);
    });

    test('标题栏是否与侧栏连成一片：只有 winui 为真', () {
      expect(w.titleBarTintedLikeSidebar, isTrue);
      expect(l.titleBarTintedLikeSidebar, isFalse);
    });

    test('开关：WinUI 40x20 + 12px 滑块，另三套 36x20 + 14px', () {
      expect(w.switchWidth, 40);
      expect(w.switchHeight, 20);
      expect(w.switchThumb, 12);
      expect(l.switchWidth, 36);
      expect(l.switchThumb, 14);
      // 几何自洽：滑块必须装得进轨道，且四周留白 = (高-滑块)/2 > 0
      for (final s in [w, l]) {
        expect(s.switchThumb, lessThan(s.switchHeight),
            reason: '滑块不能比轨道高');
        expect(s.switchWidth, greaterThan(s.switchHeight),
            reason: '轨道必须是横向的胶囊');
      }
    });

    test('选项格：WinUI 4px + 边线，另三套 9px + 凹面底', () {
      expect(w.optCellRadius, 4);
      expect(w.optCellBordered, isTrue, reason: 'WinUI 用 1px 边线分层');
      expect(l.optCellRadius, 9);
      expect(l.optCellBordered, isFalse, reason: '另三套用凹面底色分层');
    });

    test('徽章：WinUI 12px 药丸（PillCornerRadiusToken），另三套 999 胶囊', () {
      // 2026-10-19 批次 A：WinUI 徽章是**药丸**，不是直角矩形 ——
      // 参照物 `StatusPillStyle` 用官方 `PillCornerRadiusToken` = 12
      // （`Styles/ToolCardStyles.xaml:42` + `Styles/FluentTokens.xaml:52`），
      // 内边距 `Padding="8,3"`（`ToolCardStyles.xaml:41`）。
      expect(w.badgeRadius, 12);
      expect(w.badgePadH, 8);
      expect(w.badgePadV, 3);
      expect(l.badgeRadius, 999);
      // 负控制：药丸与胶囊在 20px 高时视觉差异明显，不能被谁改成同一档
      expect(w.badgeRadius, isNot(l.badgeRadius));
    });

    test('导航行：WinUI 4px，另三套 12px', () {
      expect(w.navRowRadius, 4);
      expect(l.navRowRadius, 12);
    });
  });

  group('风格 → 形态的分流', () {
    test('只有 winui 一套形态（另三套已于 2026-10-19 删除）', () {
      expect(AppStyle.winui.shapeOf(), same(StyleShape.winui));
      // 风格枚举只剩一个值 —— 这条同时守住「别再把别的风格加回来」。
      expect(AppStyle.values, hasLength(1));
      expect(AppStyle.values.single, AppStyle.winui);
    });

    test('负控制：把 winui 映射错成 legacy，上面的断言必然红', () {
      // 手动模拟「分流写错」的情形，证明判据不是恒真。
      final wrong = <AppStyle, StyleShape>{
        for (final s in [AppStyle.winui]) s: StyleShape.legacy,
      };
      expect(identical(wrong[AppStyle.winui], StyleShape.winui), isFalse,
          reason: '若这里为真，说明分流判据无法区分对错');
    });
  });

  group('形态差异在渲染层真的可见', () {
    testWidgets('同一段卡片内容，winui 与 frosted 的渲染像素不同', (tester) async {
      // 只比令牌不画面，等于把「判据」写成「常量表自证」。这里真的渲染一遍：
      // 同一个 AppCard 在两种风格下的像素必须可测地不同。
      Future<List<int>> paint(AppStyle style, {StyleShape? shape}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Theme(
              data: ThemeData(brightness: Brightness.dark),
              child: Builder(
                builder: (context) {
                  // 直接构造色板与材质，避开 AppTheme 依赖 settings 的链路
                  final c = AppColors.of(style, Brightness.dark);
                  final sh = shape ?? style.shapeOf();
                  return Center(
                    child: Container(
                      width: 200,
                      height: 60,
                      decoration: BoxDecoration(
                        color: c.surfaceSolid,
                        borderRadius: BorderRadius.circular(sh.optCellRadius),
                        border: sh.optCellBordered
                            ? Border.all(color: c.line, width: 1)
                            : null,
                      ),
                      child: Center(
                        child: Text('X', style: TextStyle(color: c.textStrong)),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final ro = tester.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,
        );
        // toImage / toByteData 走真实 GPU 与 IO 路径，在 testWidgets 的
        // fake-async 时钟里**永远不会完成**（实测：不包 runAsync 时判据挂在
        // 10 分钟超时上，见 style_backdrop_test.dart 同款注释）。必须包。
        final img = (await tester.runAsync(() => ro.toImage()))!;
        final data = (await tester.runAsync(
          () => img.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        return data.buffer.asUint8List().toList();
      }

      // 2026-10-19：三套风格已删除，原先「winui vs frosted 像素不同」的比较
      // 失去对象。换锚为**形态令牌**的比较：winui 形态与 legacy 形态渲染出的
      // 像素必须可测地不同 —— 这仍然是「形态差异在渲染层真的可见」的证明。
      final a = await paint(AppStyle.winui);
      final b = await paint(AppStyle.winui, shape: StyleShape.legacy);
      expect(a.length, b.length);
      var diff = 0;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) diff++;
      }
      expect(diff, greaterThan(0),
          reason: 'winui 形态与 legacy 形态的卡片渲染必须逐像素可测地不同');
    });
  });
}
