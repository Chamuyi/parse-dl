import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/file_name_template.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/download_section.dart';
import 'package:parse_dl/widgets/field_row.dart';
import 'package:parse_dl/widgets/template_row.dart';

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
  /// 两个模板行的标签 —— 页面上按**语义**定位的锚点。
  ///
  /// S9b 之前这里按下标取 `TextField`（0 = 保存路径、1 = 文件夹模板、
  /// 2 = 文件名模板）。平铺改造把「保存路径」换成了 `FieldRow`（只读文本 +
  /// 按钮，不再是 `TextField`），页面上只剩两个输入框：下标整体左移一位、
  /// `.at(2)` 直接越界。判据本身没变（仍是「这个模板字段的输入框」），
  /// 所以改成按行的标签找它，不再依赖控件类型与顺序。
  const dirLabel = '文件夹模板';
  const nameLabel = '文件名模板';

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

  /// 某个模板行的整行 —— 按行标签定位（页面上两个标签各自唯一）。
  Finder tplRow(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(TemplateRow),
      );

  /// 某个模板行的输入框 —— 本行唯一那一个。
  Finder tplField(String label) => find.descendant(
        of: tplRow(label),
        matching: find.byType(TextField),
      );

  /// 某个模板行的变量表里的某一颗变量。
  Finder varChip(String label, String token) => find.descendant(
        of: tplRow(label),
        matching: find.text(token),
      );

  /// 取某个模板输入框的当前文本
  String tplText(WidgetTester tester, String label) =>
      tester.widget<TextField>(tplField(label)).controller!.text;

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

    final dirInput = tester.getCenter(tplField(dirLabel));
    final nameInput = tester.getCenter(tplField(nameLabel));

    // 渲染顺序：文件夹变量 → 文件夹输入框 → 文件名变量 → 文件名输入框
    final dirVar = tester.getCenter(varChip(dirLabel, '%USER_SCREEN_NAME%'));
    final nameVar = tester.getCenter(varChip(nameLabel, '%USER_SCREEN_NAME%'));

    expect(dirVar.dy, lessThan(dirInput.dy),
        reason: '文件夹模板的变量表应在文件夹模板输入框上方');
    expect(nameVar.dy, lessThan(nameInput.dy),
        reason: '文件名模板的变量表应在文件名模板输入框上方');
    expect(dirInput.dy, lessThan(nameVar.dy),
        reason: '文件夹模板整行应排在文件名模板整行之前');
  });

  testWidgets('点文件夹模板的变量 → 只写进文件夹模板', (tester) async {
    await pumpSection(tester);

    expect(tplText(tester, dirLabel), isEmpty);
    await tapAndSettle(tester, varChip(dirLabel, '%USER_SCREEN_NAME%'));

    expect(tplText(tester, dirLabel), '%USER_SCREEN_NAME%');
    expect(tplText(tester, nameLabel), defaultNameTpl,
        reason: '文件名模板必须保持不变');
  });

  testWidgets('点文件名模板的变量 → 只写进文件名模板', (tester) async {
    await pumpSection(tester);

    await tapAndSettle(tester, varChip(nameLabel, '%USER_SCREEN_NAME%'));

    expect(tplText(tester, nameLabel), startsWith('%POST_TIME%'));
    expect(tplText(tester, nameLabel), endsWith('%USER_SCREEN_NAME%'));
    expect(tplText(tester, dirLabel), isEmpty,
        reason: '文件夹模板必须保持不变');
  });

  testWidgets('插入目标不再依赖焦点（先不点任何输入框也能插对）', (tester) async {
    await pumpSection(tester);

    // 全程不 focus 任何 TextField，直接点文件夹模板那一份的第一颗变量
    final token = '%${kXTemplateVars.first.name}%';
    await tapAndSettle(tester, varChip(dirLabel, token));

    expect(tplText(tester, dirLabel), token);
    expect(tplText(tester, nameLabel), defaultNameTpl);

    // 焦点确实不在任何模板框上（保存路径那一行 S9b 后不再是输入框）
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

    final nameInput = tester.getCenter(tplField(nameLabel));
    final example = tester.getCenter(
      find.descendant(
        of: tplRow(nameLabel),
        matching: find.text('输出示例：'),
      ),
    );
    expect(nameInput.dy, lessThan(example.dy));

    // 保存路径整行仍在最上面。S9b 后它是 `FieldRow`（只读文本 + 选择按钮），
    // 不再是 `TextField` —— 判据本身没变，仍是「保存路径排在模板之前」。
    final saveDir = tester.getCenter(find.byType(FieldRow));
    expect(saveDir.dy, lessThan(nameInput.dy));
  });
}
