import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/pages/homepage_page.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/homepage_store.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 主页搜索区「未登录点加载 → 提示登录」的判据。
///
/// 缺陷（截图实证）：`_SearchBar` 的「加载」按钮在输入为空时一律禁用，
/// 而登录检查在 `_startSearch` 内部 —— 未登录 + 空输入时按钮点不动，
/// 「请先在「设置」中登录 X 账号」这条提示永远走不到，占位符
/// 「未登录，点右侧按钮会提示登录」承诺的交互不成立。
///
/// 修复：`_SearchBar` 增加 `disabledReason`；未登录时按钮可点，
/// `_startSearch` 先判登录再判空输入（登录提示优先）。
/// **已登录路径行为逐字节不变**：空输入仍禁用、有内容才能点。
///
/// 环境注入方式照抄 `dashboard_page_test.dart`：状态构造全放 **setUp**
/// （FakeAsync 区之外），testWidgets 体内只留 pump/tap —— 实测
/// testWidgets 体内 `await Directory.systemTemp.createTemp()` 这类真实
/// 异步 I/O 永不完成（FakeAsync 下挂死）。本测试用
/// `AppPrefs.setMockInitialValues` 走纯内存替身，全程零真实 I/O。
///
/// 判据有效性设计：
///  - 「可点」断言 onPressed 是否为 null —— 禁用即红；
///  - toast 用**精确文案**断言（不能用 contains('登录')：占位符
///    「未登录，点右侧按钮会提示登录」也含「登录」，会假绿）；
///  - 负控制（临时删掉 `_startSearch` 的登录检查 → 判据 1 必红）
///    由修复流程单独跑并留档。
void main() {
  late AppState appState;
  late HomepageStore homepage;

  /// 登录提示的精确文案（= 修复后未登录点「加载」应弹的那条）。
  const String loginHint = '请先在「设置」中登录 X 账号';

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: appState),
            ChangeNotifierProvider<HomepageStore>.value(value: homepage),
          ],
          child: const MaterialApp(home: Scaffold(body: HomepagePage())),
        ),
      ),
    );
    // 不用 pumpAndSettle：与 ui_smoke_test.dart 同因 —— 页面树里有持续
    // 调度帧的成分，FakeAsync 下 pumpAndSettle 会等到 10 分钟超时。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  tearDown(() {
    AppPrefs.resetForTest();
  });

  group('未登录', () {
    setUp(() async {
      AppPrefs.setMockInitialValues(<String, Object>{});
      appState = await AppState.restore();
      homepage = HomepageStore(appState);
    });

    testWidgets('空输入 → 按钮可点，点击弹「登录」提示（先判登录）', (tester) async {
      await pumpHome(tester);

      // ① 未登录时空输入也必须可点 —— 按钮禁用会让登录提示永远走不到。
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(
        button.onPressed,
        isNotNull,
        reason: '未登录 + 空输入：按钮被禁用，登录提示永远走不到（缺陷本体）',
      );

      // ② 点击 → 弹的是登录提示，而不是「请输入用户 ID」
      //    （钉住 _startSearch 的判断顺序：先登录、后空输入）。
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(
        find.text(loginHint),
        findsOneWidget,
        reason: '未登录 + 空输入应弹「请先在设置中登录」，而非「请输入用户 ID」',
      );
    });

    testWidgets('有内容 → 弹「登录」提示（点击确实走到了 _startSearch）',
        (tester) async {
      await pumpHome(tester);

      await tester.enterText(find.byType(TextField), 'example_user');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pump();

      // 弹出登录提示 = onSubmit → _startSearch 的登录分支被执行，
      // 同时证明未登录 + 有内容没有被空输入卡住。
      expect(
        find.text(loginHint),
        findsOneWidget,
        reason: '未登录 + 有内容：登录提示优先，不应发起搜索',
      );
    });
  });

  group('已登录（原行为逐字节不变）', () {
    setUp(() async {
      // 登录态 = prefs 里存了非空 cookie（AppState.isLoggedIn 的判据），
      // 走内存替身，零真实 I/O。
      AppPrefs.setMockInitialValues(
          <String, Object>{'app_state.cookie': 'auth_token=t; ct0=c'});
      appState = await AppState.restore();
      homepage = HomepageStore(appState);
    });

    testWidgets('空输入 → 按钮仍禁用', (tester) async {
      await pumpHome(tester);

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(
        button.onPressed,
        isNull,
        reason: '已登录 + 空输入必须维持原来的禁用行为',
      );
    });

    testWidgets('有内容 → 按钮可点', (tester) async {
      await pumpHome(tester);

      // 只断言可点：真点击会走 XApi.getUser 真网络，widget 测试不碰网络。
      // 「点击走 onSubmit」的行为由未登录两条点击路径钉住。
      await tester.enterText(find.byType(TextField), 'example_user');
      await tester.pump();

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(
        button.onPressed,
        isNotNull,
        reason: '已登录 + 有内容必须维持原来的可点行为',
      );
    });
  });
}
