// 设置页在**真机可用宽度**下不溢出的回归判据。
//
// 真机取证（2026-10-19）：窗口 1280×920 物理，DPI 120（1.25 倍），
// Flutter 侧 MediaQuery.size = 1267.2 × 912.8（窗口未被系统二次放大 ——
// Flutter 逻辑宽就等于客户区物理宽）。扣掉侧边栏 220 与页面内边距 28/32，
// 内容区只剩约 980。旧版双栏在该宽度下溢出 18px，真机表现为右栏文字
// 被窗口右缘切断。
//
// 判据口径：直接量 RenderFlex 的溢出。Flutter 的溢出会以 FlutterError
// 形式从 pump 抛出，`tester.takeException()` 能拿到；**必须先证明它拿得到**
// （负控制），否则「没异常」可能只是没量到。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/pages/settings_page.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:provider/provider.dart';

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final store = SettingsStore();
  await store.load();

  await tester.pumpWidget(
    AppTheme(
      colors: AppColors.dark,
      brightness: Brightness.dark,
      style: AppStyle.winui,
      child: ChangeNotifierProvider<SettingsStore>.value(
        value: store,
        child: MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              brightness: Brightness.dark,
              onMaterialChanged: (_) async {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 泵一次并收集所有溢出异常（不只第一条）。
Future<List<Object>> _overflowErrors(WidgetTester tester, Size size) async {
  final errors = <Object>[];
  await _pump(tester, size);
  Object? e;
  while ((e = tester.takeException()) != null) {
    errors.add(e!);
  }
  return errors;
}

void main() {
  // **真机实测值**（2026-10-19 探针）：窗口 1280×920 物理 @ DPI 120 时，
  // LayoutBuilder 拿到的 maxWidth 是 **1007.2**。旧版双栏在该宽度下溢出，
  // 真机表现为右栏「下载」卡被窗口右缘切断。
  testWidgets('真机内容区 1007.2 宽下不溢出（必须已转单栏）', (tester) async {
    final errors = await _overflowErrors(tester, const Size(1007.2, 900));
    expect(errors, isEmpty, reason: '1007.2 宽下仍有溢出：\$errors');
  });

  testWidgets('可用宽 880（最小窗口）下设置页不溢出', (tester) async {
    final errors = await _overflowErrors(tester, const Size(880, 900));
    expect(errors, isEmpty, reason: '880 宽下仍有溢出：\$errors');
  });

  testWidgets('宽屏 1400 仍走双栏（不能因为转单栏把宽屏也压成一列）', (tester) async {
    await _pump(tester, const Size(1400, 900));
    // 双栏时左右两张「外观」「下载」卡并排：它们的左边缘应相差一个栏宽。
    final appear = tester.getTopLeft(find.text('外观').first);
    final download = tester.getTopLeft(find.text('下载').first);
    expect(download.dx, greaterThan(appear.dx + 200),
        reason: '宽屏下「下载」卡没有被排到右栏 —— 双栏退化了');
  });

  // 负控制：证明这条量法**真的能**检出溢出。
  // 320 宽下单栏仍然塞不下「窗口材质」2×2 选项格，必须报溢出。
  testWidgets('负控制：320 宽确实检出溢出', (tester) async {
    final errors = await _overflowErrors(tester, const Size(320, 600));
    expect(errors, isNotEmpty, reason: '量不到溢出 → 上面的"不溢出"也不算数');
  });
}
