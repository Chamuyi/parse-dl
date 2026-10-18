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
import 'package:parse_dl/widgets/collapsible_group.dart';
import 'package:parse_dl/widgets/section_card.dart';

/// 设置页回归测试 —— 三件事一起钉。
///
/// **一、设置归属**（模块化改造）
///   - 全局设置页**只保留全局设置**：外观 / 代理 / 分模块设置 / 应用；
///   - **X 下载设置**是独立一页：账号（登录）+ 下载（保存路径与模板）。
///     账号归在这里，是因为它是 X 下载的前置条件：没登录就抓不到媒体；
///   - **抖音解析下载设置**是独立一页：只有抖音分区；
///   - **B 站解析下载设置**是独立一页：只有 B 站分区；
///   - 互不混入，各模块的设置也互不合并。
///
/// **二、平铺**（2026-10-14 取代原来的「都折叠」）
///
/// 用户 2026-10-13 看真机后裁定：预览稿 `index.html` 是**视觉层与页面骨架的
/// 统一基准**，设置页要「所见即所得」—— 打开页面就把当前值摊在卡片上，
/// 不再需要逐个点开。于是 `CollapsibleGroup` 在设置页整体退役，每块内容
/// 改成平铺的 [SectionCard]。
///
/// 这条裁定**反转了下面这些 UI 可见性判据**（原来是「收起态不外漏」，
/// 现在是「当前值必须直接可见」）：
///   - 「不外漏」组 → 「所见即所得」组；
///   - 「代理地址必填」原来靠 `forceExpand` 自动展开保证可见，
///     现在收起态不存在了，改由 [ProxySection] 的红框 + 红字常驻表达。
///
/// **数据层断言一字未改**：Store 读写（`setDownload` / `setProxy` /
/// `setBili` / `setAppearance` / `setDouyin`）与组件归属（哪个模块的设置
/// 在哪一页）全部原样保留，只是承载它们的容器换了。
void main() {
  /// 全局设置页该有的卡（账号已挪到 X 下载模块）
  ///
  /// 「高级」那个分区原本只装一项「刷新 X 接口缓存」—— 接口缓存搬到 X 设置页后
  /// 它就成了空壳，所以整块去掉，全局页换成「分模块设置」小节（在「下载」卡里）。
  const globalCardTitles = <String>['外观', '代理', '下载', '应用'];

  /// X 下载设置页该有的卡（按页面里的渲染顺序：账号 → 接口缓存 → 下载）
  const xCardTitles = <String>['账号', '接口缓存', '下载'];

  /// 抖音解析下载设置页该有的卡
  const douyinCardTitles = <String>['抖音'];

  /// B 站解析下载设置页该有的卡
  const biliCardTitles = <String>['B 站'];

  /// 每张卡的**卡头灰字** —— 必须是中性描述，不含任何用户当前值
  ///
  /// 平铺后卡头右侧的灰字承接了原来「收起态概要」的位置与语义（[SectionCard.trailing]）：
  /// 它说明这一块管什么，但不写当前值。
  const cardTrailings = <String, String>{
    '账号': '登录状态、cookie 输入与验证',
    '接口缓存': 'X 接口标识缓存（搜索用户或加载媒体失败时使用）',
    '下载': '保存路径、文件夹 / 文件名模板、同名文件处理',
    '抖音': '下载源、质量优先策略、图片格式、批量与筛选选项',
    'B 站': '画质上限、编码偏好、下载完合并、命名模板',
  };

  /// 这些值只要出现在**卡头灰字**里就算「外漏」
  ///
  /// 平铺后卡头右侧的灰字（[SectionCard.trailing]）承接了原来「收起态概要」
  /// 的位置，所以它同样只许写中性描述、不许写当前值。
  const sentinels = <String>[
    '%USER_SCREEN_NAME%',
    '%POST_ID%%EXT%',
    '%BVID%/%P%-%QUALITY%%EXT%',
    r'D:\secret-path',
    r'D:\bili-secret-path',
    '#123456',
    '127.0.0.1',
  ];

  /// 按**卡头标题**定位那一张卡的子树。
  ///
  /// 2026-10-14 平铺改造后，折叠容器（`collapsible-content-<id>`）连同它的
  /// key 一起退役 —— 设置页每块内容现在都是 [SectionCard]，卡头标题就是
  /// 那一块的名字。用「标题 → 最近的 SectionCard」当锚点，搜索范围仍然
  /// **限定在这一张卡里**：别处的同名文字不会撞进来。
  ///
  /// **不要加 `.first`**：`Finder.first` 在匹配为空时会抛 `Bad state: No element`，
  /// 而这里大量用于 `findsNothing` 的负向断言（判某张卡**不在**这一页）——
  /// 加了 `.first` 会让那些断言从「找不到」变成「测试报错」。卡头标题与卡片
  /// 内容里的文字重名时（如「下载」），`findsOneWidget` 若数出多个会当场暴露，
  /// 比静默取第一个更安全。
  Finder cardOf(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byType(SectionCard),
  );

  /// 只在该卡**内容子树**里找文字。
  ///
  /// 别处的同名文字仍在元素树上 —— 例如「下载」卡变量表里的「自定义文本」
  /// 会跟「抖音」卡的同名标题撞车，全页 `find.text` 会数出 3 个。
  Finder inCard(String title, String text) => find.descendant(
    of: cardOf(title),
    matching: find.text(text),
  );

  /// 泵出设置页。
  ///
  /// [store] 用来在**同一个**设置仓库上依次泵四个页面（验证归属时要用同一份数据）。
  Future<SettingsStore> pumpPage(
    WidgetTester tester, {
    SettingsScope scope = SettingsScope.global,
    SettingsStore? store,
  }) async {
    // 画布要足够高，保证全部卡片都被 `ListView` 建出来。
    // `ListView` 是懒构建的：画布只放得下前半截时，后面的卡根本不在
    // 元素树上，`find.byType(...)` 会直接抛 `Bad state: No element`。
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

  /// 断言这些卡的卡头灰字**逐字**是中性描述，且不含任何 sentinel
  ///
  /// 只审**卡头灰字确实存在**的那些卡：全局页的「下载」卡没有灰字（它装的是
  /// 分模块入口，不是一个模块的设置块），所以泵全局页时传的清单里不含它。
  void expectTrailingsClean(List<String> titles, WidgetTester tester) {
    for (final title in titles) {
      final trailing = cardTrailings[title];
      if (trailing == null) continue;
      final w = tester.widget<Text>(
        find.descendant(of: cardOf(title), matching: find.text(trailing)),
      );
      expect(w.data, trailing, reason: '「$title」卡的卡头灰字必须是固定的中性描述');
      for (final s in sentinels) {
        expect(w.data, isNot(contains(s)), reason: '「$title」卡头把当前值「$s」漏出去了');
      }
    }
  }

  // ══════════════════════════════════════════════════════════
  // 一、设置归属：全局页只留全局，三个模块各自独立成页
  // ══════════════════════════════════════════════════════════
  group('设置归属', () {
    testWidgets('全局设置页只有全局卡：账号/抖音/B 站都不在', (tester) async {
      await pumpPage(tester);

      for (final title in globalCardTitles) {
        expect(cardOf(title), findsOneWidget, reason: '全局设置页应当有「$title」卡');
      }
      // 这些卡已经搬到各自模块里，全局页里连节点都不该有
      expect(cardOf('账号'), findsNothing, reason: 'X 账号登录属于 X 下载模块，不该留在全局设置里');
      expect(cardOf('抖音'), findsNothing, reason: '抖音解析下载的设置不该混进全局设置页');
      expect(cardOf('B 站'), findsNothing, reason: 'B 站解析下载的设置不该混进全局设置页');
      // 「下载」这张卡全局页也有（里面是分模块入口），所以不能靠标题判它不在 ——
      // 要判的是**内容**：全局页那张「下载」卡里没有 X 的保存路径与模板字段。
      expect(
        find.text('文件夹模板'),
        findsNothing,
        reason: 'X 下载的模板设置不该混进全局设置页',
      );
    });

    testWidgets('X 下载设置页：账号登录与下载设置都在，没有抖音、没有 B 站', (tester) async {
      await pumpPage(tester, scope: SettingsScope.xDownload);

      expect(find.text('X 下载设置'), findsOneWidget, reason: '页头要表明这是哪个模块的设置');
      for (final title in xCardTitles) {
        expect(cardOf(title), findsOneWidget, reason: 'X 设置页应当有「$title」卡');
      }

      expect(cardOf('抖音'), findsNothing, reason: '抖音的设置不该出现在 X 下载的设置页里');
      expect(cardOf('B 站'), findsNothing, reason: 'B 站的设置不该出现在 X 下载的设置页里');
      // 全局卡也不该跟过来
      expect(cardOf('外观'), findsNothing);
      expect(cardOf('代理'), findsNothing);
    });

    testWidgets('抖音解析下载设置页：只有抖音卡，没有账号/B 站', (tester) async {
      await pumpPage(tester, scope: SettingsScope.douyin);

      expect(find.text('抖音解析下载设置'), findsOneWidget);
      for (final title in douyinCardTitles) {
        expect(cardOf(title), findsOneWidget, reason: '抖音设置页应当有「$title」卡');
      }
      expect(cardOf('账号'), findsNothing, reason: 'X 账号登录不属于抖音模块');
      expect(cardOf('B 站'), findsNothing, reason: 'B 站的设置不该出现在抖音设置页里');
      expect(cardOf('外观'), findsNothing);
      expect(cardOf('代理'), findsNothing);
    });

    testWidgets('B 站解析下载设置页：只有 B 站卡，没有账号/抖音', (tester) async {
      await pumpPage(tester, scope: SettingsScope.bili);

      expect(find.text('B 站解析下载设置'), findsOneWidget, reason: '页头要表明这是哪个模块的设置');
      for (final title in biliCardTitles) {
        expect(cardOf(title), findsOneWidget, reason: 'B 站设置页应当有「$title」卡');
      }
      expect(cardOf('账号'), findsNothing, reason: 'X 账号登录不属于 B 站模块');
      expect(cardOf('抖音'), findsNothing, reason: '抖音的设置不该出现在 B 站设置页里');
      expect(cardOf('外观'), findsNothing);
      expect(cardOf('代理'), findsNothing);
    });

    testWidgets('三个模块的设置页互不相同（不合并成同一页）', (tester) async {
      await pumpPage(tester, scope: SettingsScope.xDownload);
      expect(find.text('X 下载设置'), findsOneWidget);

      await pumpPage(tester, scope: SettingsScope.douyin);
      expect(find.text('X 下载设置'), findsNothing, reason: '抖音的设置页里不该出现 X 下载的标题');
      expect(find.text('抖音解析下载设置'), findsOneWidget);

      await pumpPage(tester, scope: SettingsScope.bili);
      expect(find.text('X 下载设置'), findsNothing);
      expect(find.text('抖音解析下载设置'), findsNothing,
          reason: 'B 站的设置页里不该出现抖音的标题');
      expect(find.text('B 站解析下载设置'), findsOneWidget);
    });

    testWidgets('四个页面的页头标题各不相同', (tester) async {
      await pumpPage(tester);
      expect(find.text('设置'), findsWidgets);

      await pumpPage(tester, scope: SettingsScope.xDownload);
      expect(find.text('X 下载设置'), findsOneWidget);

      await pumpPage(tester, scope: SettingsScope.douyin);
      expect(find.text('抖音解析下载设置'), findsOneWidget);

      await pumpPage(tester, scope: SettingsScope.bili);
      expect(find.text('B 站解析下载设置'), findsOneWidget);
    });
  });

  // ══════════════════════════════════════════════════════════
  // 二、平铺：打开页面即见当前值（取代原来的「都折叠」）
  //
  // 用户 2026-10-13 裁定：预览稿是页面骨架的统一基准，设置页要「所见即所得」。
  // 于是折叠壳整体退役，下面这些判据**语义反转**：原来要求「收起态不露内容」，
  // 现在要求「当前值直接可见、不需要任何点击」。
  // ══════════════════════════════════════════════════════════
  group('所见即所得', () {
    testWidgets('全局页的四张卡都在，且没有折叠壳', (tester) async {
      await pumpPage(tester);

      for (final title in globalCardTitles) {
        expect(cardOf(title), findsOneWidget, reason: '全局页的「$title」卡不能丢');
      }
      // 折叠时代的三样东西一个都不该剩下
      expect(find.text('展开设置'), findsNothing, reason: '平铺后没有「展开设置」这种动作文案');
      expect(find.text('收起'), findsNothing);
      expect(find.byType(CollapsibleGroup), findsNothing,
          reason: '设置页不该再有任何折叠组');
    });

    testWidgets('外观卡的字段一次性全部可见 —— 不需要点开任何东西', (tester) async {
      await pumpPage(tester);

      // 字段直接摊在卡上（原来要先点开「外观」分区才看得到）。
      // 2026-10-19：'窗口材质' 与 '界面风格' 两项已删除 —— 材质只剩 Mica、
      // 风格只剩 WinUI，留一个只有一项的下拉框没有意义。判据强度不变：
      // 仍然要求「剩下的每一项都必须直接可见」。
      for (final f in [
        '界面语言',
        '自定义色调',
        '导航形态',
        '主题模式',
        '背景图片',
      ]) {
        expect(
          inCard('外观', f),
          findsOneWidget,
          reason: '「$f」应当直接可见，不需要展开',
        );
      }
    });

    testWidgets('X 下载设置页：账号与下载卡的内容直接可见', (tester) async {
      await pumpPage(tester, scope: SettingsScope.xDownload);

      // 账号卡：登录状态直接可见（原来要先点开「账号」分区）
      expect(
        find.text('登录状态'),
        findsWidgets,
        reason: '账号卡里的登录状态应当直接可见',
      );

      // 下载卡：模板字段与变量表直接可见
      expect(find.text('文件夹模板'), findsOneWidget);
      expect(find.text('文件名模板'), findsOneWidget);
      // 两个字段各自一份可用变量表，且都是展开的
      expect(find.text('可用变量'), findsNWidgets(2));
    });

    testWidgets('抖音设置页：各选项直接可见（没有第二层折叠）', (tester) async {
      await pumpPage(tester, scope: SettingsScope.douyin);

      for (final f in ['下载源', '图片格式', '并发数', '跳过已下载作品']) {
        expect(
          inCard('抖音', f),
          findsOneWidget,
          reason: '「$f」应当直接可见，不需要展开',
        );
      }
      // 「自定义文本」特殊：卡内除了它自己的标题，两个模板字段各自的
      // 「可用变量」表里也有一枚 %CUSTOM_TEXT% 芯片，描述文字同为
      // 「自定义文本」。所以这里只要求「至少出现一次」。
      expect(
        inCard('抖音', '自定义文本'),
        findsWidgets,
        reason: '「自定义文本」应当直接可见',
      );
      expect(
        find.text('质量优先策略'),
        findsNothing,
        reason: '默认下载源不是「质量优先」两档，该下拉不该出现',
      );
    });

    testWidgets('B 站设置页：各选项直接可见（没有第二层折叠）', (tester) async {
      await pumpPage(tester, scope: SettingsScope.bili);

      for (final f in [
        '画质上限',
        '编码偏好',
        '下载完成后合并',
        '跳过已下载的分 P',
        '同一稿件的分 P 排在一起',
        '并发数',
        '保存与命名',
        '启用保存文件夹',
        '启用模版',
      ]) {
        expect(
          inCard('B 站', f),
          findsOneWidget,
          reason: '「$f」应当直接可见，不需要展开',
        );
      }
      // 「自定义文本」和抖音那页同理：选项标题之外，两张变量表里还各有一枚
      // %CUSTOM_TEXT% 芯片，描述文字同为「自定义文本」，所以只要求至少一次。
      expect(
        inCard('B 站', '自定义文本'),
        findsWidgets,
        reason: '「自定义文本」应当直接可见',
      );

      // 三个模块各说各的话：抖音专有的说法不该出现在 B 站这一页
      for (final f in ['下载源', '质量优先策略', '图片格式']) {
        expect(find.text(f), findsNothing, reason: '「$f」是抖音的说法，不该出现在 B 站页');
      }
    });

    testWidgets('下载源切到「质量优先」后，质量优先策略下拉才出现', (tester) async {
      final settings = await pumpPage(tester, scope: SettingsScope.douyin);

      expect(find.text('质量优先策略'), findsNothing);

      await settings.setDouyin((d) => d.source = DouyinSource.qualityFirst);
      await tester.pumpAndSettle();
      expect(find.text('质量优先策略'), findsOneWidget);
    });
  });

  group('卡头灰字中性', () {
    testWidgets('卡头灰字只给中性描述，不写任何当前值', (tester) async {
      final settings = await pumpPage(tester);

      // 先塞入一批「一旦写进卡头就会被看到」的值：模板 / 保存路径 / 代理地址 / 自定义色调
      await settings.setDownload((d) {
        d.dirTemplate = '%USER_SCREEN_NAME%';
        d.fileNameTemplate = '%POST_ID%%EXT%';
        d.saveDirBase = r'D:\secret-path';
      });
      await settings.setProxy((p) => p.url = 'http://127.0.0.1:7890');
      await settings.setBili((b) {
        b.dirTemplate = '%BVID%';
        b.fileNameTemplate = '%BVID%/%P%-%QUALITY%%EXT%';
        b.saveDirBase = r'D:\bili-secret-path';
      });
      await settings.setAppearance((a) {
        a.customTint = true;
        a.tintColor = '#123456';
      });
      await tester.pumpAndSettle();

      // 平铺后「露在屏幕上」的是卡头标题 + 卡头灰字 + 全部字段。
      // 卡头灰字承接了原「收起态概要」的位置，所以**它**只许写中性描述。
      //
      // 注意：不能拿 `find.text` 去全页扫 sentinel —— 平铺后那些当前值
      // **本来就该显示在字段里**（这正是本次改造的目的）。要审的是卡头那一行。
      //
      // 全局页的「下载」卡没有灰字（它装的是分模块入口），所以这条用 X 页的
      // 三张卡 + 另外两个模块的卡来审 —— 它们才是「一个模块的设置块」。
      await pumpPage(tester, scope: SettingsScope.xDownload, store: settings);
      expectTrailingsClean(xCardTitles, tester);

      await pumpPage(tester, scope: SettingsScope.douyin, store: settings);
      expectTrailingsClean(douyinCardTitles, tester);

      await pumpPage(tester, scope: SettingsScope.bili, store: settings);
      expectTrailingsClean(biliCardTitles, tester);
    });
  });

  group('必填项保护', () {
    testWidgets('代理地址变成必填 → 红框与错误文案常驻可见', (tester) async {
      final settings = await pumpPage(tester);

      // 「启用代理 + 不使用系统代理 + 地址为空」→ 地址是必填项
      await settings.setProxy((p) {
        p.enable = true;
        p.useSystem = false;
        p.url = '';
      });
      await tester.pumpAndSettle();

      // 平铺后收起态不存在了，这条判据**换了表达方式但没放宽**：
      // 原来靠 `forceExpand` 把分区自动展开（「必需项不能被藏在收起态里」），
      // 现在改由 [ProxySection] 的红框 + 红字常驻表达 —— 错误状态永远在屏幕上，
      // 比原来更直接（不用先展开才看得见）。
      expect(
        find.text('还没填代理地址'),
        findsOneWidget,
        reason: '必需项缺失必须在界面上直接可见',
      );

      // 填上地址后错误消失
      await settings.setProxy((p) => p.url = 'http://127.0.0.1:7890');
      await tester.pumpAndSettle();
      expect(find.text('还没填代理地址'), findsNothing, reason: '填上地址后不该还报错');
    });
  });
}
