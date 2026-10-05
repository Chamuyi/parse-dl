import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/file_name_template.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/download_section.dart';

/// 「可用变量」区块的回归测试。
///
/// 背景：原版 `settings/FileNameTemplateInput.tsx` 把
/// `VariablePicker + Input + TemplateExample` 打包成一个组件，
/// **文件夹模板与文件名模板各自都有一份**可用变量表。
///
/// 移植时曾退化成一个共享区块（挂在最下面、靠焦点猜插入目标），
/// 结果「文件夹模板」看起来没有自己的可用变量 —— 用户就是这么反馈的。
/// 这里把两件事钉死：
///   1. 两个模板字段**各有一份**变量表，且都摆在**本字段输入框上方**；
///   2. 点哪一份的变量就插进哪个字段，**不依赖焦点状态**。
void main() {
  /// `_TemplateRow` 在 Section 里的出现顺序，用于按索引取 TextField：
  /// 0 = 保存路径（只读）、1 = 文件夹模板、2 = 文件名模板。
  const idxSaveDir = 0;
  const idxDirTpl = 1;
  const idxNameTpl = 2;

  /// 与 `DownloadSettings.fileNameTemplate` 的默认值一致
  const defaultNameTpl =
      '%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%';

  Future<void> pumpSection(WidgetTester tester) async {
    // 整段设置内容很高，给足画布，避免 RenderFlex overflow 干扰断言
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsStore>(create: (_) => SettingsStore()),
            ChangeNotifierProvider<DownloadStore>(create: (_) => DownloadStore()),
          ],
          child: const MaterialApp(
            home: Scaffold(
              // 这里直接挂 DownloadSection（不带设置页的分区折叠壳），
              // 页面级的「默认收起」由 settings_collapsed_test.dart 负责。
              body: SingleChildScrollView(child: DownloadSection()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 取第 index 个模板输入框的当前文本
  String tplText(WidgetTester tester, int index) =>
      tester.widget<TextField>(find.byType(TextField).at(index)).controller!.text;

  /// 点变量 → 触发去抖保存 + 弹出 SnackBar，把这几十毫秒走完，
  /// 否则测试结束时留下未触发的 Timer 会报错。
  Future<void> tapAndSettle(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  }

  testWidgets('两个模板字段各有一份可用变量表（核心回归）', (tester) async {
    await pumpSection(tester);

    expect(find.text('可用变量'), findsNWidgets(2),
        reason: '文件夹模板 + 文件名模板 各一份，不能再退回共享单份');
    expect(
      find.text('共 ${kXTemplateVars.length} 个，点击插入到本模板'),
      findsNWidgets(2),
    );

    // 13 个变量在两个字段下各出现一次
    for (final v in kXTemplateVars) {
      expect(
        find.text('%${v.name}%'),
        findsNWidgets(2),
        reason: '${v.name} 应同时出现在文件夹模板与文件名模板的变量表里',
      );
    }

    // 旧的共享区块已删除
    expect(find.text('点击插入到光标处'), findsNothing);
  });

  testWidgets('每份变量表都摆在「自己那个」输入框的上方', (tester) async {
    await pumpSection(tester);

    final dirInput = tester.getCenter(find.byType(TextField).at(idxDirTpl));
    final nameInput = tester.getCenter(find.byType(TextField).at(idxNameTpl));

    // 渲染顺序：文件夹变量 → 文件夹输入框 → 文件名变量 → 文件名输入框
    final dirVar = tester.getCenter(find.text('%USER_SCREEN_NAME%').at(0));
    final nameVar = tester.getCenter(find.text('%USER_SCREEN_NAME%').at(1));

    expect(dirVar.dy, lessThan(dirInput.dy),
        reason: '文件夹模板的变量表应在文件夹模板输入框上方');
    expect(nameVar.dy, lessThan(nameInput.dy),
        reason: '文件名模板的变量表应在文件名模板输入框上方');
    expect(dirInput.dy, lessThan(nameVar.dy),
        reason: '文件夹模板整行应排在文件名模板整行之前');
  });

  testWidgets('点文件夹模板的变量 → 只写进文件夹模板', (tester) async {
    await pumpSection(tester);

    expect(tplText(tester, idxDirTpl), isEmpty);
    await tapAndSettle(tester, find.text('%USER_SCREEN_NAME%').at(0));

    expect(tplText(tester, idxDirTpl), '%USER_SCREEN_NAME%');
    expect(tplText(tester, idxNameTpl), defaultNameTpl,
        reason: '文件名模板必须保持不变');
  });

  testWidgets('点文件名模板的变量 → 只写进文件名模板', (tester) async {
    await pumpSection(tester);

    await tapAndSettle(tester, find.text('%USER_SCREEN_NAME%').at(1));

    expect(tplText(tester, idxNameTpl), startsWith('%POST_TIME%'));
    expect(tplText(tester, idxNameTpl), endsWith('%USER_SCREEN_NAME%'));
    expect(tplText(tester, idxDirTpl), isEmpty,
        reason: '文件夹模板必须保持不变');
  });

  testWidgets('插入目标不再依赖焦点（先不点任何输入框也能插对）', (tester) async {
    await pumpSection(tester);

    // 全程不 focus 任何 TextField，直接点文件夹模板那一份的第一颗变量
    final firstDirVar = find.text('%${kXTemplateVars.first.name}%').at(0);
    await tapAndSettle(tester, firstDirVar);

    expect(tplText(tester, idxDirTpl), '%${kXTemplateVars.first.name}%');
    expect(tplText(tester, idxNameTpl), defaultNameTpl);

    // 焦点确实不在任何模板框上（默认焦点在保存路径那个只读框上或者无焦点）
    final focused = tester
        .widgetList<TextField>(find.byType(TextField))
        .where((t) => t.focusNode?.hasFocus ?? false)
        .length;
    expect(focused, 0, reason: '这条用例的前提就是"没有焦点"');
  });

  testWidgets('变量表可折叠，且两个字段各自独立', (tester) async {
    await pumpSection(tester);

    expect(find.text('%CONTENT%'), findsNWidgets(2));

    // 收起「文件夹模板」那一份
    await tester.tap(find.text('可用变量').at(0));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(find.text('%CONTENT%'), findsOneWidget,
        reason: '只剩文件名模板那一份还展开着');
    expect(find.text('可用变量'), findsNWidgets(2),
        reason: '折叠只是收起内容，标题仍在');

    // 再展开回来
    await tester.tap(find.text('可用变量').at(0));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.text('%CONTENT%'), findsNWidgets(2));
  });

  testWidgets('输出示例仍在输入框下方（顺序未被改坏）', (tester) async {
    await pumpSection(tester);

    final nameInput = tester.getCenter(find.byType(TextField).at(idxNameTpl));
    final example = tester.getCenter(find.text('输出示例：').last);
    expect(nameInput.dy, lessThan(example.dy));

    final saveDir = tester.getCenter(find.byType(TextField).at(idxSaveDir));
    expect(saveDir.dy, lessThan(nameInput.dy));
  });
}
