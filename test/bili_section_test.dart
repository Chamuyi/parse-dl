import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/l10n/l10n.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/file_name_template.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/bili_section.dart';
import 'package:parse_dl/widgets/template_row.dart';

/// B 站设置分区的回归测试。
///
/// 钉四件事，都是这一页最容易被改坏的地方：
///   1. **「启用模版」下拉的选中态从 config 反推**，不从文本框反推 ——
///      模板逐字等于某个预设就停在那个预设，改过一个字就落「自定义」。
///      这条一旦反过来（从控制器算），未落盘的中间态会让下拉和实际配置不一致。
///   2. **改动真的落到 `SettingsStore`** —— `setBili` 写进去、`isDefault` 翻 false。
///   3. **「可用变量」表不许串术语**：只列 B 站那 18 个，X 专有与抖音专有一个都不许出现
///      （`platform_terms_test` 守的是数据层那张表，这里守的是**界面上真渲染出来的芯片**）。
///   4. **「输出示例」走的就是下载侧那个入口**，且在多 P 样例上能带出 `P03` 这种补零名 ——
///      单 P 样例会让 `<P%P%>` 整段消失，看不出补零有没有生效。
///
/// 避开的坑：不构造 `Aria2Coordinator` 单例（带 `Timer.periodic`，widget 测试里会
/// 以 `did not complete` 挂死），所以本分区不直接碰并发下发；断言只比**文本内容**，
/// 不比文字宽度（`flutter test` 用 Ahem 等宽字体，拉丁文案上的宽度断言是假信号）。
void main() {
  /// X 专有的变量名 —— 出现在 B 站设置里就是串了术语
  const xOnly = [
    'POST_ID',
    'POST_TIME',
    'USER_ID',
    'USER_NAME',
    'USER_SCREEN_NAME',
    'MEDIA_ID',
    'MEDIA_WIDTH',
    'MEDIA_HEIGHT',
    'CONTENT',
    'TAGS',
  ];

  /// 抖音专有的变量名 —— 其中 `CUSTOM_TEXT` / `RESOLUTION` / `DURATION` /
  /// `FILE_SIZE` 是三个模块共用的中性变量，不在这里列。
  const douyinOnly = [
    'AUTHOR',
    'AUTHOR_ID',
    'AUTHOR_UNIQUE_ID',
    'CREATE_TIME',
    'DESCRIPTION',
    'AWEME_ID',
    'IMAGE_INDEX',
    'BITRATE',
    'FPS',
    'LIKE_COUNT',
    'COMMENT_COUNT',
    'COLLECT_COUNT',
    'SHARE_COUNT',
  ];

  /// 把分区单独泵出来（不套 `CollapsibleGroup`，折叠行为归
  /// `settings_collapsed_test` 管；这里只管分区内部）。
  Future<SettingsStore> pumpSection(
    WidgetTester tester, {
    bool? ffmpegAvailable,
  }) async {
    // 画布要够高：模板行 + 两张可用变量表都在下面，矮画布上 ListView 会懒构建掉。
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    AppPrefs.setMockInitialValues({});
    final store = SettingsStore();

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsStore>.value(value: store),
            // 保存根目录留空时，框子里要显示「这一趟实际落到哪」，
            // 那一条链从 DownloadStore 的会话目录起算。
            ChangeNotifierProvider<DownloadStore>(create: (_) => DownloadStore()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: BiliSection(ffmpegAvailable: ffmpegAvailable),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  group('启用模版下拉', () {
    testWidgets('默认模板逐字等于第一个预设 —— 下拉停在「按作品分文件夹（推荐）」',
        (tester) async {
      final store = await pumpSection(tester);
      final p = kBiliTemplatePresets.first;
      expect(store.settings.bili.dirTemplate, p.dirTemplate);
      expect(store.settings.bili.fileNameTemplate, p.fileNameTemplate);
      expect(find.text(t(p.label)), findsOneWidget);
      expect(find.text('自定义（已手动修改）'), findsNothing);
    });

    testWidgets('config 换成另一个预设的组合 → 下拉跟着停过去', (tester) async {
      final store = await pumpSection(tester);
      final bvid = kBiliTemplatePresets.firstWhere((e) => e.id == 'bvid');
      expect(bvid.dirTemplate, '%BVID%');
      expect(bvid.fileNameTemplate, kBiliDefaultFileNameTemplate);

      await store.setBili((b) => b.dirTemplate = bvid.dirTemplate);
      await tester.pumpAndSettle();

      expect(find.text(t(bvid.label)), findsOneWidget);
      expect(find.text('按作品分文件夹（推荐）'), findsNothing);
    });

    testWidgets('改过一个字 → 落「自定义（已手动修改）」', (tester) async {
      final store = await pumpSection(tester);
      expect(find.text('按作品分文件夹（推荐）'), findsOneWidget);

      await store.setBili(
        (b) => b.fileNameTemplate = '${b.fileNameTemplate}x',
      );
      await tester.pumpAndSettle();

      expect(find.text('自定义（已手动修改）'), findsOneWidget);
      for (final p in kBiliTemplatePresets) {
        expect(find.text(t(p.label)), findsNothing,
            reason: '${p.id} 已经不再逐字匹配了，不该还停在那里');
      }
    });

    testWidgets('选一个预设 → 两个模板框都被填上，落盘后下拉停在该预设',
        (tester) async {
      final store = await pumpSection(tester);
      final up = kBiliTemplatePresets.firstWhere((e) => e.id == 'up');

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t(up.label)).last);
      await tester.pumpAndSettle();
      // 文本框的监听器 500ms 去抖后才落盘
      await tester.pump(const Duration(milliseconds: 600));

      expect(store.settings.bili.dirTemplate, up.dirTemplate);
      expect(store.settings.bili.fileNameTemplate, up.fileNameTemplate);
      expect(find.text(t(up.label)), findsOneWidget);
    });
  });

  group('改动落盘', () {
    testWidgets('改画质上限 → setBili 真的写进去了，isDefault 翻 false', (tester) async {
      final store = await pumpSection(tester);
      expect(store.settings.bili.isDefault, isTrue);

      await tester.tap(find.byType(DropdownButtonFormField<BiliQuality>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1080P'));
      await tester.pumpAndSettle();

      expect(store.settings.bili.quality, BiliQuality.q1080);
      expect(store.settings.bili.isDefault, isFalse);
      expect(store.settings.bili.toJson()['quality'], '1080p');
    });

    testWidgets('关掉合并 / 改编码 —— 同样落到 bili 那一份上', (tester) async {
      final store = await pumpSection(tester);
      // 另两个模块的配置先拍一份，事后逐字段比 —— 只比一两个字段的话，
      // 「顺手把别人的设置也写了」这类越界改动测不出来。
      final douyinBefore = prettyJson(store.settings.douyin.toJson());
      final downloadBefore = prettyJson(store.settings.download.toJson());

      await tester.tap(find.text('下载完成后合并'));
      await tester.pumpAndSettle();
      expect(store.settings.bili.mergeAfterDownload, isFalse);

      await tester.tap(find.byType(DropdownButtonFormField<BiliCodec>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AV1'));
      await tester.pumpAndSettle();
      expect(store.settings.bili.codec, BiliCodec.av1);

      expect(prettyJson(store.settings.douyin.toJson()), douyinBefore,
          reason: 'B 站这一页的改动不许写到抖音的配置上');
      expect(prettyJson(store.settings.download.toJson()), downloadBefore,
          reason: 'B 站这一页的改动不许写到 X 下载的配置上');
    });

    testWidgets('ffmpeg 探测结论只影响那一行提示，不影响开关本身', (tester) async {
      const hint = '当前环境找不到可用的 ffmpeg，合并这一步会失败：'
          '下完只会得到两个不能单独播放的 .m4s 文件。';

      final missing = await pumpSection(tester, ffmpegAvailable: false);
      expect(find.text(hint), findsOneWidget);
      expect(missing.settings.bili.mergeAfterDownload, isTrue);

      // 没探测出来（null）与探测到可用，都不该吓用户
      await pumpSection(tester);
      expect(find.text(hint), findsNothing);

      await pumpSection(tester, ffmpegAvailable: true);
      expect(find.text(hint), findsNothing);
    });
  });

  group('可用变量表', () {
    /// 只在**变量表**里数芯片。
    ///
    /// 不能拿全页 `find.text('%WORK_TITLE%')` —— 文件夹模板的默认值本身就是
    /// `%WORK_TITLE%`，输入框的内容与它的 hintText 会各自再匹配一次，
    /// 芯片数就不再是 2 了。`VariablePicker` 才是那张表的本体。
    Finder varChips(String name) => find.descendant(
      of: find.byType(VariablePicker),
      matching: find.text('%$name%'),
    );

    testWidgets('表里出现的正是 kBiliTemplateVars，一个不多一个不少', (tester) async {
      await pumpSection(tester);

      // 文件夹模板与文件模板各带一份变量表，所以每个变量都是 2 枚芯片。
      for (final v in kBiliTemplateVars) {
        expect(varChips(v.name), findsNWidgets(2),
            reason: '${v.name} 应在两张可用变量表里各出现一次');
      }
      expect(kBiliTemplateVars.length, 18);

      // B 站专有那几个必须在（术语表变了这里会先红，避免默默漏掉）
      for (final n in [
        'WORK_TITLE',
        'PART_TITLE',
        'P',
        'PART_TOTAL',
        'BVID',
        'AVID',
        'CID',
        'UP_NAME',
        'UP_MID',
        'QUALITY',
        'CODEC',
      ]) {
        expect(varChips(n), findsNWidgets(2), reason: '$n 是 B 站专有变量，必须可见');
      }
    });

    testWidgets('X 与抖音的专有变量一个都不出现 —— 术语不许串门', (tester) async {
      await pumpSection(tester);

      for (final n in xOnly) {
        expect(varChips(n), findsNothing, reason: '$n 是 X 的说法，不该进 B 站设置');
      }
      for (final n in douyinOnly) {
        expect(varChips(n), findsNothing, reason: '$n 是抖音的说法，不该进 B 站设置');
      }
    });
  });

  group('输出示例', () {
    testWidgets('多 P 示例数据上渲染出带 P03 的名字，且用的就是 kBiliFileNameResolver',
        (tester) async {
      await pumpSection(tester);

      final example = biliExampleMedia();
      expect(example.bili?.partTotal, 12, reason: '示例必须是多 P 稿件，否则 <P%P%> 整段消失');
      expect(example.mediaIndex, 3);

      final expected =
          kBiliFileNameResolver(kBiliDefaultFileNameTemplate, example);
      expect(expected, contains('P03'));
      expect(expected, endsWith('.m4s'));

      // 「输出示例」那行渲染的就是上面这个串 —— 预览与下载同一条路径
      expect(find.text(expected), findsOneWidget);

      // 文件夹模板的示例同样实时跟随（默认模板 = 作品标题）
      expect(find.text(resolveVariables(kBiliDefaultDirTemplate, example).trim()),
          findsOneWidget);
    });

    testWidgets('模板清空后示例行退回说明文字，不留一个空样例', (tester) async {
      await pumpSection(tester);

      await tester.enterText(
        find.widgetWithText(TextField, kBiliDefaultFileNameTemplate),
        '',
      );
      await tester.pump();

      expect(find.textContaining('P03'), findsNothing);
      expect(find.text('留空则不按模板命名 —— 兜底名字由下载层决定，点「填入默认」恢复'),
          findsOneWidget);
    });
  });
}
