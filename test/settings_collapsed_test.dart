import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/models/douyin_config.dart';
import 'package:parse_dl/pages/settings_page.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 设置页回归测试 —— 两件事一起钉。
///
/// **一、折叠行为**（原有约定）
///   1. **都折叠** —— 分区默认全部收起，内容可见高度为 0；分区内部没有第二层折叠。
///   2. **不外漏** —— 收起态只给一行**中性概要**（说明该分区管什么），
///      **绝不写入当前值**：材质、路径、模板、代理地址、登录状态都不露。
///   唯一例外是「代理」分区：地址变成必填时自动展开（`forceExpand`）。
///
/// **二、设置归属**（模块化改造）
///   - 全局设置页**只保留全局设置**：外观 / 代理 / 高级 / 应用；
///   - **X 下载设置**是独立一页：账号（登录）+ 下载（保存路径与模板）。
///     账号归在这里，是因为它是 X 下载的前置条件：没登录就抓不到媒体；
///   - **抖音解析下载设置**是独立一页：只有抖音分区；
///   - 三者互不混入，两个模块的设置也互不合并。
void main() {
  /// 全局设置页该有的分区（账号已挪到 X 下载模块）
  const globalSectionIds = <String>[
    'section.appearance',
    'section.proxy',
    'section.advanced',
    'section.app',
  ];

  /// X 下载设置页该有的分区（按页面里的渲染顺序：账号在前、下载在后）
  const xSectionIds = <String>['section.account', 'section.download'];

  /// 抖音解析下载设置页该有的分区
  const douyinSectionIds = <String>['section.douyin'];

  /// 每个分区的收起概要 —— 必须是中性描述，不含任何用户当前值
  const summaries = <String, String>{
    'section.appearance': '窗口材质、自定义色调、导航形态、主题模式、背景图片、界面语言',
    'section.account': '登录状态、cookie 输入与验证',
    'section.download': '保存路径、文件夹 / 文件名模板、同名文件处理',
    'section.douyin': '下载源、质量优先策略、图片格式、批量与筛选选项',
    'section.proxy': '启用代理、使用系统代理、自定义代理地址、连通性测试',
    'section.advanced': 'X 接口标识缓存（搜索用户或加载媒体失败时使用）',
    'section.app': '日志记录、日志目录与文件',
  };

  /// 这些值只要出现在概要里就算「外漏」
  const sentinels = <String>[
    '%USER_SCREEN_NAME%',
    '%POST_ID%%EXT%',
    r'D:\secret-path',
    '#123456',
    '127.0.0.1',
  ];

  /// 可见高度必须量 `SizeTransition` 本身：它里面的孩子仍保留自然高度。
  Key contentAnim(String id) => ValueKey('collapsible-content-anim-$id');

  /// 概要行的 `Text`（收起时唯一露在屏幕上的文字）
  Key summaryKey(String id) => ValueKey('collapsible-summary-$id');

  /// 分区内容容器的 key —— 分区**存不存在**用它判断最准
  Key contentKey(String id) => ValueKey('collapsible-content-$id');

  /// 只在该分区**内容子树**里找文字。
  ///
  /// 折叠组「只裁剪不销毁」，别处的同名文字仍在元素树上 ——
  /// 例如「下载」分区变量表里的「自定义文本」会跟「抖音」分区的
  /// 同名标题撞车，全页 `find.text` 会数出 3 个。
  Finder inSection(String id, String text) => find.descendant(
    of: find.byKey(contentKey(id)),
    matching: find.text(text),
  );

  double contentHeight(WidgetTester tester, String id) =>
      tester.getSize(find.byKey(contentAnim(id))).height;

  /// 泵出设置页。
  ///
  /// [store] 用来在**同一个**设置仓库上依次泵三个页面（验证归属时要用同一份数据）。
  Future<SettingsStore> pumpPage(
    WidgetTester tester, {
    SettingsScope scope = SettingsScope.global,
    SettingsStore? store,
  }) async {
    // 画布要足够高，保证全部分区都被 `ListView` 建出来。
    // `ListView` 是懒构建的：画布只放得下前半截时，后面的分区根本不在
    // 元素树上，`find.byKey(...)` 会直接抛 `Bad state: No element`。
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    AppPrefs.setMockInitialValues({});
    final appState = await AppState.restore();
    final settings = store ?? SettingsStore();

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: appState),
            ChangeNotifierProvider<SettingsStore>.value(value: settings),
            ChangeNotifierProvider<DownloadStore>(
              create: (_) => DownloadStore(),
            ),
            // 抖音分区要读 app 级的抓取结果仓库（台账条数那一行）
            ChangeNotifierProvider<DouyinStore>(create: (_) => DouyinStore()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SettingsPage(
                brightness: Brightness.dark,
                onMaterialChanged: (_) async {},
                scope: scope,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  /// 断言这些分区的概要**逐字**是中性描述，且不含任何 sentinel
  void expectSummariesClean(List<String> ids, WidgetTester tester) {
    for (final id in ids) {
      final t = tester.widget<Text>(find.byKey(summaryKey(id)));
      expect(t.data, summaries[id], reason: '$id 的概要必须是固定的中性描述');
      for (final s in sentinels) {
        expect(t.data, isNot(contains(s)), reason: '$id 的概要把当前值「$s」漏出去了');
      }
    }
  }

  // ══════════════════════════════════════════════════════════
  // 一、设置归属：全局页只留全局，两个模块各自独立成页
  // ══════════════════════════════════════════════════════════
  group('设置归属', () {
    testWidgets('全局设置页只有全局分区：账号/下载/抖音都不在', (tester) async {
      await pumpPage(tester);

      for (final id in globalSectionIds) {
        expect(
          find.byKey(contentKey(id)),
          findsOneWidget,
          reason: '全局设置页应当有 $id',
        );
      }
      // 这三个分区已经搬到各自模块里，全局页里连节点都不该有
      expect(
        find.byKey(contentKey('section.account')),
        findsNothing,
        reason: 'X 账号登录属于 X 下载模块，不该留在全局设置里',
      );
      expect(
        find.byKey(contentKey('section.download')),
        findsNothing,
        reason: 'X 下载的设置不该混进全局设置页',
      );
      expect(
        find.byKey(contentKey('section.douyin')),
        findsNothing,
        reason: '抖音解析下载的设置不该混进全局设置页',
      );

      // 连标题文字也不该出现
      expect(find.text('账号'), findsNothing);
      expect(find.text('下载'), findsNothing);
      expect(find.text('抖音'), findsNothing);
    });

    testWidgets('X 下载设置页：账号登录与下载设置都在，没有抖音', (tester) async {
      await pumpPage(tester, scope: SettingsScope.xDownload);

      expect(find.text('X 下载设置'), findsOneWidget, reason: '页头要表明这是哪个模块的设置');
      for (final id in xSectionIds) {
        expect(find.byKey(contentKey(id)), findsOneWidget);
      }
      // 账号登录是 X 下载的前置条件，必须在这一页
      expect(find.text('账号'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);

      expect(
        find.byKey(contentKey('section.douyin')),
        findsNothing,
        reason: '抖音的设置不该出现在 X 下载的设置页里',
      );
      // 全局分区也不该跟过来
      expect(find.byKey(contentKey('section.appearance')), findsNothing);
      expect(find.byKey(contentKey('section.proxy')), findsNothing);
    });

    testWidgets('抖音解析下载设置页：只有抖音分区，没有账号/下载', (tester) async {
      await pumpPage(tester, scope: SettingsScope.douyin);

      expect(find.text('抖音解析下载设置'), findsOneWidget);
      for (final id in douyinSectionIds) {
        expect(find.byKey(contentKey(id)), findsOneWidget);
      }
      expect(
        find.byKey(contentKey('section.account')),
        findsNothing,
        reason: 'X 账号登录不属于抖音模块',
      );
      expect(
        find.byKey(contentKey('section.download')),
        findsNothing,
        reason: 'X 下载的设置不该出现在抖音设置页里',
      );
      expect(find.byKey(contentKey('section.appearance')), findsNothing);
      expect(find.byKey(contentKey('section.proxy')), findsNothing);
    });

    testWidgets('两个模块的设置页互不相同（不合并成同一页）', (tester) async {
      await pumpPage(tester, scope: SettingsScope.xDownload);
      expect(find.text('X 下载设置'), findsOneWidget);

      await pumpPage(tester, scope: SettingsScope.douyin);
      expect(find.text('X 下载设置'), findsNothing, reason: '抖音的设置页里不该出现 X 下载的标题');
      expect(find.text('抖音解析下载设置'), findsOneWidget);
    });

    testWidgets('三个页面的页头标题各不相同', (tester) async {
      await pumpPage(tester);
      expect(find.text('设置'), findsWidgets);

      await pumpPage(tester, scope: SettingsScope.xDownload);
      expect(find.text('X 下载设置'), findsOneWidget);

      await pumpPage(tester, scope: SettingsScope.douyin);
      expect(find.text('抖音解析下载设置'), findsOneWidget);
    });
  });

  // ══════════════════════════════════════════════════════════
  // 二、折叠行为
  // ══════════════════════════════════════════════════════════
  group('都折叠', () {
    testWidgets('全局页的分区默认全部收起（内容可见高度均为 0）', (tester) async {
      await pumpPage(tester);

      for (final id in globalSectionIds) {
        expect(contentHeight(tester, id), 0, reason: '$id 默认必须收起');
      }
    });

    testWidgets('分区标题都在，动作文案统一是「展开」', (tester) async {
      await pumpPage(tester);

      for (final t in ['外观', '代理', '高级', '应用']) {
        expect(find.text(t), findsOneWidget, reason: '分区「$t」的标题不能丢');
      }

      // 四个普通分区 + 高级的诊断入口 —— 「展开诊断工具」那个特例已经统一掉，
      // 动作文案现在全站只有一个词。
      expect(find.text('展开设置'), findsNWidgets(4));
      expect(find.text('展开诊断工具'), findsNothing);
      expect(find.text('收起'), findsNothing);
    });

    testWidgets('展开一个分区不影响其它分区', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();

      expect(contentHeight(tester, 'section.appearance'), greaterThan(0));
      for (final id in globalSectionIds.where(
        (s) => s != 'section.appearance',
      )) {
        expect(contentHeight(tester, id), 0, reason: '$id 不该被连带展开');
      }
      expect(find.text('收起'), findsOneWidget);
    });

    testWidgets('再次点击分区标题 → 收回', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();
      expect(contentHeight(tester, 'section.appearance'), greaterThan(0));

      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();
      expect(contentHeight(tester, 'section.appearance'), 0);
      expect(find.text('收起'), findsNothing);
    });

    testWidgets('展开后字段平铺 —— 没有第二层折叠', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();

      // 五个字段一次性全部可见，展开后不需要再点一次
      for (final f in ['窗口材质', '自定义色调', '导航形态', '主题模式', '背景图片']) {
        expect(find.text(f), findsOneWidget, reason: '「$f」应在展开后直接可见');
      }
      // 「自定义色调」曾经被同一个分区渲染了两遍，这里守住只出现一次
      expect(find.text('自定义色调'), findsOneWidget);
    });

    testWidgets('X 下载设置页：账号分区展开后能看到登录状态', (tester) async {
      await pumpPage(tester, scope: SettingsScope.xDownload);

      await tester.tap(find.text('账号'));
      await tester.pumpAndSettle();

      expect(
        contentHeight(tester, 'section.account'),
        greaterThan(0),
        reason: '账号分区展开后内容要真的露出来',
      );
    });

    testWidgets('X 下载设置页：下载分区展开后模板字段与变量表直接可见', (tester) async {
      await pumpPage(tester, scope: SettingsScope.xDownload);

      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      expect(find.text('文件夹模板'), findsOneWidget);
      expect(find.text('文件名模板'), findsOneWidget);
      // 两个字段各自一份可用变量表，且都是展开的
      expect(find.text('可用变量'), findsNWidgets(2));
    });

    testWidgets('抖音设置页：抖音分区展开后各选项直接可见（没有第二层折叠）', (tester) async {
      await pumpPage(tester, scope: SettingsScope.douyin);

      await tester.tap(find.text('抖音'));
      await tester.pumpAndSettle();

      for (final f in ['下载源', '图片格式', '并发数', '跳过已下载作品']) {
        expect(
          inSection('section.douyin', f),
          findsOneWidget,
          reason: '「$f」应在展开后直接可见',
        );
      }
      // 「自定义文本」特殊：分区内除了它自己的标题，两个模板字段各自的
      // 「可用变量」表里也有一枚 %CUSTOM_TEXT% 芯片，描述文字同为
      // 「自定义文本」。所以这里只要求「至少出现一次」—— 变量表本身就在
      // 该选项内部，选项若被折叠，它和变量表会一起消失，断言依然成立。
      expect(
        inSection('section.douyin', '自定义文本'),
        findsWidgets,
        reason: '「自定义文本」应在展开后直接可见',
      );
      expect(
        find.text('质量优先策略'),
        findsNothing,
        reason: '默认下载源不是「质量优先」两档，该下拉不该出现',
      );
    });

    testWidgets('下载源切到「质量优先」后，质量优先策略下拉才出现', (tester) async {
      final settings = await pumpPage(tester, scope: SettingsScope.douyin);

      await tester.tap(find.text('抖音'));
      await tester.pumpAndSettle();
      expect(find.text('质量优先策略'), findsNothing);

      await settings.setDouyin((d) => d.source = DouyinSource.qualityFirst);
      await tester.pumpAndSettle();
      expect(find.text('质量优先策略'), findsOneWidget);
    });
  });

  group('不外漏', () {
    testWidgets('收起态只给中性概要，不写任何当前值', (tester) async {
      final settings = await pumpPage(tester);

      // 先塞入一批「一旦外漏就会被看到」的值：模板 / 保存路径 / 代理地址 / 自定义色调
      await settings.setDownload((d) {
        d.dirTemplate = '%USER_SCREEN_NAME%';
        d.fileNameTemplate = '%POST_ID%%EXT%';
        d.saveDirBase = r'D:\secret-path';
      });
      await settings.setProxy((p) => p.url = 'http://127.0.0.1:7890');
      await settings.setAppearance((a) {
        a.customTint = true;
        a.tintColor = '#123456';
      });
      await tester.pumpAndSettle();

      // 概要必须与中性描述**逐字一致**，且不含任何一个 sentinel。
      //
      // 注意：折叠组的内容仍在元素树上（只裁剪不销毁），所以这里不能拿
      // `find.text` 去全页扫 —— 变量表里的 `%USER_SCREEN_NAME%` 一直都在树上。
      // 真正「露在屏幕上」的只有分区标题 + 这一行概要，所以直接审概要本身。
      expectSummariesClean(globalSectionIds, tester);

      // 两个模块的设置页同样不许外漏（用同一个 store，保证塞进去的值还在）
      await pumpPage(tester, scope: SettingsScope.xDownload, store: settings);
      expectSummariesClean(xSectionIds, tester);

      await pumpPage(tester, scope: SettingsScope.douyin, store: settings);
      expectSummariesClean(douyinSectionIds, tester);
    });
  });

  group('必填项保护', () {
    testWidgets('代理地址变成必填 → 代理分区自动展开', (tester) async {
      final settings = await pumpPage(tester);
      expect(
        contentHeight(tester, 'section.proxy'),
        0,
        reason: '前置条件：代理分区默认收起',
      );

      // 「启用代理 + 不使用系统代理 + 地址为空」→ 地址是必填项
      await settings.setProxy((p) {
        p.enable = true;
        p.useSystem = false;
        p.url = '';
      });
      await tester.pumpAndSettle();

      expect(
        contentHeight(tester, 'section.proxy'),
        greaterThan(0),
        reason: '必需项不能被藏在收起态里',
      );
      expect(find.text('收起'), findsOneWidget);

      // 填上地址后条件消失，不再强制展开（但仍保持用户当前看到的展开态）
      await settings.setProxy((p) => p.url = 'http://127.0.0.1:7890');
      await tester.pumpAndSettle();
      expect(contentHeight(tester, 'section.proxy'), greaterThan(0));
    });
  });
}
