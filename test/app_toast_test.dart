import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/app_toast.dart';

/// 提示条必须**出现在顶部**，而且**不能挤动页面布局**。
///
/// 用户原话：「点击下载后的提示框不要出现在最下面」。
/// 老的 `SnackBar` 恒锚定 Scaffold 底部 —— 本应用底部要么浮着 Dock、
/// 要么贴着内容区下沿，提示一出来就压在操作区上。
///
/// 这里用几何断言把新行为钉死：位置在上半屏 + 页面尺寸不变。
void main() {
  /// 搭一个最小宿主：AppTheme + MaterialApp（要 Navigator 提供 Overlay）。
  ///
  /// **顺序必须和 `app.dart` 一致** —— `AppTheme` 包在 `MaterialApp` 外面，
  /// 这样 `MaterialApp` 内部那个 Overlay 才能向上找到主题色板。
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(AppTheme(
      colors: AppColors.dark,
      brightness: Brightness.dark,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return Column(
              children: const [
                SizedBox(key: ValueKey('marker'), height: 120, width: 200),
                Expanded(child: SizedBox.expand()),
              ],
            );
          }),
        ),
      ),
    ));
    return ctx;
  }

  /// 走完弹出动画（不等到自动消失）。
  Future<void> settleIn(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
  }

  /// 走完自动消失，避免测试结束时留下 pending timer。
  Future<void> settleOut(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('提示条渲染在屏幕上半部，而不是底部', (tester) async {
    final ctx = await pumpHost(tester);
    final screen = tester.getSize(find.byType(MaterialApp));

    AppToast.show(ctx, '已提交 3 个视频');
    await settleIn(tester);

    final text = find.text('已提交 3 个视频');
    expect(text, findsOneWidget);

    final rect = tester.getRect(text);
    expect(rect.top, lessThan(screen.height / 2),
        reason: '必须落在上半屏');
    expect(rect.top, greaterThanOrEqualTo(AppToast.kToastTopInset),
        reason: '不能压住自绘标题栏（高 44）');
    expect(rect.bottom, lessThan(screen.height / 2),
        reason: '整条提示都在上半屏');

    await settleOut(tester);
  });

  testWidgets('弹出提示不会改变页面布局（不挤动其他内容）', (tester) async {
    final ctx = await pumpHost(tester);
    final before = tester.getRect(find.byKey(const ValueKey('marker')));

    AppToast.show(ctx, '已提交 12 个');
    await settleIn(tester);

    final after = tester.getRect(find.byKey(const ValueKey('marker')));
    expect(after, before, reason: 'Overlay 浮层不参与页面布局');

    await settleOut(tester);
  });

  testWidgets('底部不再出现 SnackBar', (tester) async {
    final ctx = await pumpHost(tester);
    AppToast.show(ctx, '已提交 1 个');
    await settleIn(tester);

    expect(find.byType(SnackBar), findsNothing);

    await settleOut(tester);
  });

  testWidgets('带动作按钮：点击后回调并收起', (tester) async {
    final ctx = await pumpHost(tester);
    var tapped = 0;

    AppToast.show(
      ctx,
      '已提交 2 个',
      actionLabel: '去下载管理',
      onAction: () => tapped++,
    );
    await settleIn(tester);

    expect(find.text('去下载管理'), findsOneWidget);
    await tester.tap(find.text('去下载管理'));
    await tester.pumpAndSettle();

    expect(tapped, 1);
    expect(find.text('已提交 2 个'), findsNothing, reason: '动作执行后应自动收起');
  });

  testWidgets('自动消失：超过时长后自己收掉', (tester) async {
    final ctx = await pumpHost(tester);
    AppToast.show(ctx, '会自动消失', duration: const Duration(seconds: 1));
    await settleIn(tester);
    expect(find.text('会自动消失'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('会自动消失'), findsNothing);
  });

  testWidgets('连续弹两条：新的顶掉旧的，不叠成一摞', (tester) async {
    final ctx = await pumpHost(tester);
    AppToast.show(ctx, '第一条');
    await settleIn(tester);

    AppToast.show(ctx, '第二条');
    await settleIn(tester);

    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsOneWidget);

    await settleOut(tester);
  });
}
