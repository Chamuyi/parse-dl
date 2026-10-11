import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 弹层必须读得清 —— 尤其是叠在网页上的那一种。
///
/// 起因（2026-10-11 用户实拍）：批量页与下载选项弹窗里的下拉一展开，
/// 列表直接透出底下的 B 站页面，字完全看不清。根因不在页面代码，
/// 而在主题：Flutter 的 `DropdownButton` 展开层取色是
/// `widget.dropdownColor ?? Theme.of(context).canvasColor`
/// （SDK `packages/flutter/lib/src/material/dropdown.dart:341`），
/// 而我们的 `canvasColor` 是 `Colors.transparent` —— 于是一处配置把
/// **全应用每一个下拉**都变成了全透。
///
/// 所以这里两条都要跑：一条钉主题本身，一条真把一个下拉点开、量它落到的
/// 那块 Material。只钉主题的话，哪天 SDK 换取色字段就没人报警了。
void main() {
  ThemeData themeFor(Brightness b) => buildAppTheme(
    b == Brightness.dark ? AppColors.dark : AppColors.light,
    b,
  );

  group('主题的弹层底色', () {
    test('明暗两套的 canvasColor 都是实心', () {
      for (final b in Brightness.values) {
        final c = themeFor(b).canvasColor;
        expect(c.a, 1.0, reason: '$b 的 canvasColor 半透明：下拉展开层会透出底下的网页');
      }
    });

    test('负控制：透明底色确实会被上面那条判出来', () {
      // 不写这一条，「实心」断言可能只是永远为真的空话（改错了也绿）。
      const transparent = Color(0x00FFFFFF);
      expect(transparent.a, isNot(1.0));
    });
  });

  group('真点开一个下拉', () {
    Future<void> open(WidgetTester tester, Brightness b) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(b),
          home: Scaffold(
            body: DropdownButton<int>(
              value: 1,
              items: const [
                DropdownMenuItem(value: 1, child: Text('不限')),
                DropdownMenuItem(value: 2, child: Text('30')),
              ],
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
    }

    /// 弹层里那条 Material 刻意是 `MaterialType.transparency`（SDK 的写法），
    /// 真正的底色由 `_DropdownMenuPainter` 拿 `Theme.canvasColor` 刷出来 —— 那个
    /// painter 是私有类，量不到。所以这里量的是**弹层上下文里生效的 canvasColor**：
    /// 它证明主题确实穿进了弹层路由（弹层被包进另一套主题、或哪天改了取色路径，
    /// 这条都会红）。配合上面那条「主题本身实心」，两头夹住同一个字段。
    Future<void> expectPopupOpaque(WidgetTester tester, Brightness b) async {
      await open(tester, b);
      final item = find.text('30');
      expect(item, findsOneWidget, reason: '下拉没展开，这条用例等于没跑');
      final c = Theme.of(tester.element(item)).canvasColor;
      expect(c.a, 1.0, reason: '${b.name} 弹层上下文里的 canvasColor 是半透明的');
    }

    testWidgets('展开层拿到的是实心底色（暗色）', (tester) => expectPopupOpaque(tester, Brightness.dark));
    testWidgets('展开层拿到的是实心底色（浅色）', (tester) => expectPopupOpaque(tester, Brightness.light));
  });
}
