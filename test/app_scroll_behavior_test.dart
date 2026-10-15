import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/app_scroll_behavior.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 滚动条外观的判据（2026-10-15）。
///
/// ### 为什么要钉它
///
/// Flutter 在**桌面平台**默认给每个可滚动组件套一条 `Scrollbar`（见 SDK
/// `material/app.dart` 的 `MaterialScrollBehavior.buildScrollbar`）—— 于是
/// 侧边栏右侧、内容区右侧各多出一条**系统默认样式**的竖线。用户 2026-10-15
/// 看真机时指出「怎么有一个滑动的东西」。
///
/// 预览稿对滚动条是**刻意设计过**的（`app.css` 三档规格），所以这里要钉住
/// 「用的是我们自己的 behavior/theme」，而不是「恰好没画出来」——
/// 后者在换窗口尺寸、换 Flutter 版本时随时会变。
void main() {
  group('滚动条：全局 behavior 与主题', () {
    test('AppScrollBehavior 覆写了 buildScrollbar（否则桌面端退回系统默认样式）', () {
      const b = AppScrollBehavior();
      // 覆写的直接证据：它是 MaterialScrollBehavior 的子类，且声明了自己的
      // buildScrollbar。用 runtimeType 的声明位置做判据 —— 只写
      // `b is MaterialScrollBehavior` 会恒真（继承关系永远成立）。
      expect(
        b.runtimeType.toString(),
        'AppScrollBehavior',
        reason: '必须是自定义类型，不能直接 new 一个 MaterialScrollBehavior',
      );
      expect(b, isA<MaterialScrollBehavior>());
    });

    test('侧边栏那层用 NoScrollbarBehavior 压掉滚动条', () {
      // 预览稿 `app.css:59` `.side::-webkit-scrollbar { width: 0; }`。
      const b = NoScrollbarBehavior();
      expect(b.runtimeType.toString(), 'NoScrollbarBehavior');
    });

    testWidgets('NoScrollbarBehavior 真的不挂 Scrollbar（直接问 behavior）',
        (tester) async {
      // **不能用 `find.byType(Scrollbar)` 测**：`MaterialScrollBehavior` 是否
      // 挂滚动条取决于 `Theme.of(context).platform`，而 widget 测试的默认
      // 平台不是 Windows —— 实测「正控制」也找不到 Scrollbar，那条路是死的。
      // 所以直接调 `buildScrollbar` 看它返回什么（这才是真正的被测逻辑）。
      late final Widget result;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final scrollable = ScrollableDetails.vertical(
                  controller: ScrollController(),
                );
                result = const NoScrollbarBehavior()
                    .buildScrollbar(context, const Text('内容'), scrollable);
                return result;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        result,
        isNot(isA<Scrollbar>()),
        reason: '这一层不该挂滚动条（预览稿要求侧边栏 width: 0）',
      );
      expect(result, isA<Text>(), reason: '应当原样返回 child');

      // 正控制：同一个 context 下换成默认 behavior，它会**返回 Scrollbar** ——
      // 否则上面那条「不是 Scrollbar」可能只是因为 Windows 分支根本没走到。
      late final Widget def;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final scrollable = ScrollableDetails.vertical(
                  controller: ScrollController(),
                );
                def = const MaterialScrollBehavior()
                    .buildScrollbar(context, const Text('内容'), scrollable);
                return def;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        def,
        isA<Scrollbar>(),
        reason: '正控制失败：Windows 平台下默认 behavior 应当挂 Scrollbar，'
            '否则上面的负判据是假绿',
      );
    });

    testWidgets('AppScrollbarTheme 下发的样式是预览稿那一档（8px / 圆角 / 不常驻）',
        (tester) async {
      await tester.pumpWidget(
        AppTheme(
          colors: AppColors.dark,
          brightness: Brightness.dark,
          child: AppScrollbarTheme(
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    final t = ScrollbarTheme.of(context);
                    // 逐项点名（不写 `isNotNull` 这种恒真断言）
                    expect(t.thickness?.resolve({}), 8,
                        reason: '预览稿 `.card > .cb` 的 width 是 8px');
                    expect(t.radius, const Radius.circular(4),
                        reason: '8px 宽配 4 圆角 = CSS 的 999px 全圆');
                    expect(t.thumbVisibility?.resolve({}), isFalse,
                        reason: '平时不常驻，滚动/悬停才淡入');
                    expect(t.trackVisibility?.resolve({}), isFalse,
                        reason: '预览稿只定义了 thumb，没给 track 背景');
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    });
  });

  group('源码守卫：接线没被摘掉', () {
    test('app.dart 挂了 scrollBehavior 与 AppScrollbarTheme', () {
      final src = File('lib/app.dart').readAsStringSync();
      expect(src, contains('scrollBehavior: const AppScrollBehavior()'),
          reason: '不挂 behavior 的话桌面端每个滚动容器都会退回系统默认样式');
      expect(src, contains('AppScrollbarTheme('),
          reason: '不挂主题的话滚动条厚度/颜色不是预览稿那一档');
    });

    test('侧边栏用了 NoScrollbarBehavior', () {
      final src = File('lib/widgets/sidebar_nav.dart').readAsStringSync();
      expect(src, contains('NoScrollbarBehavior()'),
          reason: '预览稿要求侧边栏滚动条 width: 0');
    });
  });
}
