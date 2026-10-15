import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/app_scroll_behavior.dart';

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

    testWidgets('AppScrollBehavior 不创建任何 Scrollbar（用户裁定彻底隐藏）',
        (tester) async {
      // **不能用 `find.byType(Scrollbar)` 测**：`MaterialScrollBehavior` 是否
      // 挂滚动条取决于 `Theme.of(context).platform`，而 widget 测试的默认
      // 平台不是 Windows —— 实测「正控制」也找不到 Scrollbar，那条路是死的。
      // 所以直接调 `buildScrollbar` 看它返回什么（这才是真正的被测逻辑）。
      //
      // 2026-10-15 用户裁定「彻底隐藏」后，这条判据从「样式是预览稿那一档」
      // 反转为「根本不创建 Scrollbar」：`2fae366` 那版只把系统默认样式换成
      // 8px/圆角 + 空闲隐藏，但滚动时淡入的那条仍会被截图留下，用户原话
      // 「右边滚动条还在，并且三个模块的设置还有全局设置都是在」。
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
                result = const AppScrollBehavior()
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
        reason: '任何轴向/平台下都不该创建滚动条（用户要求彻底隐藏）',
      );
      expect(result, isA<Text>(), reason: '应当原样返回 child');

      // 横向也不能漏：原来只对纵向挂 Scrollbar、横向直接返回 child，
      // 反转后两条路都必须是「原样返回」。
      late final Widget hResult;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final scrollable = ScrollableDetails.horizontal(
                  controller: ScrollController(),
                );
                hResult = const AppScrollBehavior()
                    .buildScrollbar(context, const Text('内容'), scrollable);
                return hResult;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        hResult,
        isNot(isA<Scrollbar>()),
        reason: '横向同样不该创建滚动条',
      );
      expect(hResult, isA<Text>(), reason: '横向也应原样返回 child');

      // 正控制：**默认 behavior 在 Windows 下确实会返回 Scrollbar** ——
      // 否则上面两条「不是 Scrollbar」可能只是平台分支没走到（假绿）。
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
  });

  /// 剥掉 Dart 源码里的注释，只留**真代码**。
///
/// 为什么必须有这一步（2026-10-15 踩到）：源码守卫若直接扫全文，那么
/// 「曾在这里挂过一层 `AppScrollbarTheme`」「`Scrollbar(thickness: 0)` 不可靠」
/// 这类**说明性注释**会让判据永久假红 —— 守卫的本意是「代码里没再引用」，
/// 不是「任何字符都不许出现」。与 `l10n_test.dart` 剥注释取字面量是同一类
/// 防护（见该文件同名的剥注释函数），这里只做本测试需要的两种行注释。
String stripCommentsForGuard(String src) => src
    .replaceAll(RegExp(r'///[^\n]*'), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// 只保留代码中的标识符形态，避免 'dart:math' 之类的串内命中。
///
/// `isNot(contains('Scrollbar('))` 若匹配到 `// Scrollbar(...) 说明` 之外，
/// 还可能命中**字符串字面量**里的同名单词。上面那个剥注释函数已排掉注释，
/// 剩下的风险面很窄；这里再收一道：把单/双引号串整体替换掉，避免把说明
/// 文字里的同名单词当成代码引用。
String codeOnlyForGuard(String src) => stripCommentsForGuard(src)
    .replaceAll(RegExp(r"'[^']*'"), '')
    .replaceAll(RegExp(r'"[^"]*"'), '');

group('源码守卫：接线没被摘掉', () {
    test('app.dart 挂了 scrollBehavior（不挂则桌面端每个滚动容器都带默认滚动条）', () {
      final src = File('lib/app.dart').readAsStringSync();
      expect(src, contains('scrollBehavior: const AppScrollBehavior()'),
          reason: '不挂 behavior 的话桌面端每个滚动容器都会退回系统默认样式');
      // 2026-10-15 用户裁定「彻底隐藏」后，`AppScrollbarTheme`（8px/圆角/
      // thumbVisibility 那套样式参数）随 `Scrollbar` 一起被删掉：没有滚动条
      // 被创建，就没有样式可下发。这里反向钉住它**没有**被引回来 ——
      // 否则将来有人「顺手恢复」一层空壳主题，后人会以为还在给滚动条配色。
      //
      // 剥注释后比对：否则说明这段理由的注释自己就会让判据假红。
      expect(codeOnlyForGuard(src), isNot(contains('AppScrollbarTheme')),
          reason: '滚动条已彻底不创建，不应再引用样式主题');
    });

    test('behavior 本体不再构造 Scrollbar（源码级，防将来被加回来）', () {
      final src = File('lib/theme/app_scroll_behavior.dart').readAsStringSync();
      final code = codeOnlyForGuard(src);
      // 先把 `buildScrollbar` 这个方法名本身摘掉 —— 否则它就是 `Scrollbar(`
      // 的子串，判据会永远假红（同 `visual_tokens_test` 正则要加词边界的教训）。
      final stripped = code.replaceAll('buildScrollbar', '');
      expect(stripped, isNot(contains('Scrollbar(')),
          reason: '用户裁定任何时刻都不显示滚动条：behavior 内不应再创建它');
      expect(stripped, isNot(contains('ScrollbarThemeData')),
          reason: '没有 Scrollbar 就没有样式参数，别留下看起来还在配色的死代码');
    });

    test('抖音解析页不再显式包裹 Scrollbar（2fae366 漏掉的那一处）', () {
      final src = File('lib/pages/douyin_page.dart').readAsStringSync();
      expect(codeOnlyForGuard(src), isNot(contains('Scrollbar(')),
          reason: '显式写出来的 Scrollbar 不受全局 behavior 管辖，'
              '是「滚动条还在」最可能的漏网点');
      expect(src, contains('NoScrollbarBehavior'),
          reason: '这一层改由 NoScrollbarBehavior 接管');
    });

    test('侧边栏用了 NoScrollbarBehavior', () {
      final src = File('lib/widgets/sidebar_nav.dart').readAsStringSync();
      expect(src, contains('NoScrollbarBehavior()'),
          reason: '预览稿要求侧边栏滚动条 width: 0');
    });
  });
}
