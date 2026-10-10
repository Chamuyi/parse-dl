import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/l10n/app_locale.dart';
import 'package:parse_dl/l10n/l10n.dart';
import 'package:parse_dl/models/creation_task.dart';
import 'package:parse_dl/models/download_filter.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/user.dart';
import 'package:parse_dl/pages/download_management_page.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/bili_ledger.dart';
import 'package:parse_dl/services/creation_task_store.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/app_toast.dart';
import 'package:parse_dl/widgets/download_history_section.dart';

import 'module_boundary_test.dart' show stringLiterals;

/// B 站这条队列（第三个 `DownloadFeed`）的界面回归。
///
/// 钉的是四件事：
///   1. **队列隔离**：B 站页只列 `Media.source == 'bili'` 的任务；
///   2. **Tab 归属**：「已下载（B 站）」只在 B 站页出现，抖音那份也只在抖音页出现；
///   3. **判据拆分**：顶部「创作任务」区块是 X 独有的 —— 以前那里写的是
///      `!feed.isDouyin`，第三个队列进来后 B 站页会平白多出 X 的区块；
///   4. **台账接得上**：历史 Tab 的行、单条移除、清空都真的落在 `BiliLedger` 上。
///
/// ## 这个文件里避开的坑（与 `download_history_tab_test.dart` 同一批）
///   * 不能用 `pumpAndSettle`：aria2 没起来时顶部有个 `CircularProgressIndicator`，
///     无限动画会让 `pumpAndSettle` 一直等 → 超时；
///   * 真实文件 IO（台账读写）必须包进 `tester.runAsync()`，假时钟里那些 Future
///     永远完不成，表现成「点了没反应」；
///   * 协调器这个带 `Timer.periodic` 的单例只在 `setUp` 里拿（给 CreationTaskStore
///     构造参数用），不在 `testWidgets` 里新建、也不 `boot()`，否则假时钟下挂死；
///   * **「点一下 → 等真实写盘 → 再看提示」这类动作要整段放进 `runAsync`，并在里面
///     `pump()`**（弹窗退场要帧、落盘要真实事件循环），而且落盘之后还要再推几帧才
///     轮得到 handler 里 `await` 后面那句提示。见「清空」那条用例的循环。
/// 「有创建任务」这件事的测试替身。
///
/// 真实 `CreationTaskStore.create()` 会顺手起后台泵 `_pump()`，而泵在
/// aria2 未就绪时立刻抛错并把任务摘掉 —— 那几个 microtask 常在界面画到
/// 第一帧之前就跑完了，于是「X 页画得出创作任务区块」这条正控制根本按不住。
/// 这里只把任务留在队列里、不起泵：界面渲染读的就是 `tasks` 这一个口子。
class _HeldCreationTaskStore extends CreationTaskStore {
  _HeldCreationTaskStore({required super.appState, required super.coordinator});

  final List<CreationTask> _held = [];

  @override
  List<CreationTask> get tasks => List.unmodifiable(_held);

  @override
  CreationTask create(TwitterUser user, DownloadFilter filter) {
    final t = CreationTask(
      id: 'ct_held_${_held.length + 1}',
      user: user,
      filter: filter,
    );
    _held.add(t);
    notifyListeners();
    return t;
  }
}

void main() {
  late Directory tmp;
  late DownloadStore store;
  late DouyinStore douyin;
  late BiliLedger bili;
  late AppState appState;
  late CreationTaskStore creationTasks;

  setUp(() async {
    AppPrefs.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('bili-feed-');
    // fallbackOverride 也要给：AppPaths.init 会先问一次备用目录，
    // 测试环境里没有 path_provider 插件，不传就 MissingPluginException。
    await AppPaths.init(exeDirOverride: tmp, fallbackOverride: tmp);
    store = DownloadStore();
    douyin = DouyinStore();
    bili = BiliLedger();
    appState = await AppState.restore();
    // 协调器只在这里取一次（setUp 跑在假时钟之外）：B 站页不画创作任务区块，
    // 但 X 那条对照用例要渲染它，而 CreationTaskStore 的构造非要一个协调器。
    creationTasks = _HeldCreationTaskStore(
      appState: appState,
      coordinator: Aria2Coordinator.instance,
    );
  });

  tearDown(() async {
    AppToast.dismiss();
    preferredLocale = AppLocale.system;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// 手动走几帧（原因见文件头「坑 1」）
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// 放任务会让 [DownloadStore] 起 2 秒的去抖落盘定时器；不跑过它，
  /// 测试结束时会报「A Timer is still pending」。
  Future<void> flushSave(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
  }

  /// 提示条自带 3 秒定时器与入场动画：不收掉它、不跑过那一秒，
  /// 测试结束同样报「A Timer is still pending」。
  Future<void> flushToast(WidgetTester tester) async {
    AppToast.dismiss();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
  }

  Future<void> pumpPage(WidgetTester tester, DownloadFeed feed) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: appState),
            ChangeNotifierProvider<DownloadStore>.value(value: store),
            ChangeNotifierProvider<CreationTaskStore>.value(
                value: creationTasks),
            ChangeNotifierProvider<DouyinStore>.value(value: douyin),
            ChangeNotifierProvider<BiliLedger>.value(value: bili),
          ],
          child: MaterialApp(home: Scaffold(body: DownloadManagementPage(feed: feed))),
        ),
      ),
    );
    await settle(tester);
    await flushSave(tester);
  }

  Media media(String id, String source) => Media(
        id: id,
        type: MediaType.video,
        url: 'https://example.invalid/$id.mp4',
        source: source,
      );

  /// 往 B 站台账里塞一条**已下完**的分 P。
  ///
  /// 走 [BiliLedger.markDone]（而不是 markPending）：历史 Tab 只列已下完的，
  /// 键组必须是 `biliPartKey` 那种每段都有值的，否则台账直接丢掉这条。
  Future<void> seedPart(
    WidgetTester tester,
    String bvid,
    String cid, {
    String? title,
    String? author,
  }) async {
    final key = biliPartKey(bvid: bvid, cid: cid);
    final meta = (title == null && author == null)
        ? null
        : {bili.hashOf(key): (title: title, author: author)};
    await tester.runAsync(() async {
      await bili.markDone([key], meta: meta);
    });
  }

  Future<void> openHistoryTab(WidgetTester tester) async {
    await tester.tap(find.text(kBiliHistoryTab));
    await settle(tester);
  }

  /// 页面上所有可见文字（用于断言「这一侧根本看不到对方的字样」）
  List<String> visibleTexts(WidgetTester tester) => find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .toList();

  /// B 站侧不许出现的说法：另两个模块的平台名与专有术语。
  /// 判据与 `module_boundary_test.dart` / `platform_terms_test.dart` 一致 ——
  /// 「作品」不在列表里，B 站自己就叫作品（`%WORK_TITLE%` 的说明是「作品标题」）。
  const biliForbidden = ['推文', '帖子', 'tweet', 'twitter', '抖音', 'aweme', 'douyin'];

  group('B 站队列的隔离', () {
    testWidgets('只列 bili 的任务，X 与抖音的一条都不显示', (tester) async {
      store.addPending(media('x-1', 'x'), r'F:\dl\x', fileName: 'x-file.mp4');
      store.addPending(
          media('d-1', 'douyin'), r'F:\dl\d', fileName: 'douyin-file.mp4');
      store.addPending(
          media('b-1', 'bili'), r'F:\dl\b', fileName: 'bili-file.mp4');

      await pumpPage(tester, DownloadFeed.bili);

      expect(find.text('bili-file.mp4'), findsOneWidget);
      expect(find.text('x-file.mp4'), findsNothing);
      expect(find.text('douyin-file.mp4'), findsNothing);
      // 角标也得只数自己那条：三种 source 各一条时，B 站的「下载中」角标是 (1)
      expect(find.text('(1)'), findsWidgets);
      expect(find.text('(3)'), findsNothing);
    });

    testWidgets('队列空了的引导语说 B 站自己的页面名，不说别家的', (tester) async {
      await pumpPage(tester, DownloadFeed.bili);

      expect(find.textContaining('B 站解析下载页勾选分P'), findsOneWidget);
      expect(find.textContaining('主页或自动执行页'), findsNothing);
      expect(find.textContaining('自动下载页勾选作品'), findsNothing);
    });
  });

  group('历史 Tab 的归属', () {
    testWidgets('B 站页有「已下载（B 站）」，且看不到抖音那份', (tester) async {
      await pumpPage(tester, DownloadFeed.bili);

      expect(find.text('已下载（B 站）'), findsOneWidget);
      expect(find.text('已下载（抖音）'), findsNothing);
    });

    testWidgets('抖音页没有「已下载（B 站）」', (tester) async {
      await pumpPage(tester, DownloadFeed.douyin);

      expect(find.text('已下载（抖音）'), findsOneWidget);
      expect(find.text('已下载（B 站）'), findsNothing);
    });

    testWidgets('X 页两个历史 Tab 都没有', (tester) async {
      await pumpPage(tester, DownloadFeed.x);

      expect(find.text('已下载（B 站）'), findsNothing);
      expect(find.text('已下载（抖音）'), findsNothing);
    });

    testWidgets('B 站台账的 doneCount 反映到角标上（pending 不算）', (tester) async {
      // 一条已下完 + 一条还在下：角标只认已下完的，点进去才数得上
      await seedPart(tester, 'BV1aa411b111', '1001',
          title: '第 1 话', author: 'UP 甲');
      final pendingKey = biliPartKey(bvid: 'BV1bb411c222', cid: '2002');
      await tester.runAsync(() => bili.markPending([pendingKey]));
      expect(bili.count, 2);
      expect(bili.doneCount, 1);

      await pumpPage(tester, DownloadFeed.bili);
      expect(find.text('(1)'), findsWidgets);
      expect(find.text('(2)'), findsNothing);
    });
  });

  group('创作任务是 X 独有的（原判据 !feed.isDouyin 的回归）', () {
    testWidgets('X 页画得出创作任务区块', (tester) async {
      creationTasks.create(
        const TwitterUser(name: '测试用户', screenName: 'testuser'),
        const DownloadFilter(),
      );

      await pumpPage(tester, DownloadFeed.x);
      expect(find.textContaining('个任务创建中'), findsOneWidget);
    });

    testWidgets('B 站页不画创作任务区块', (tester) async {
      creationTasks.create(
        const TwitterUser(name: '测试用户', screenName: 'testuser'),
        const DownloadFilter(),
      );

      await pumpPage(tester, DownloadFeed.bili);
      expect(find.textContaining('个任务创建中'), findsNothing);
      expect(find.textContaining('正在读取该用户的媒体'), findsNothing);
    });

    testWidgets('抖音页同样不画创作任务区块', (tester) async {
      creationTasks.create(
        const TwitterUser(name: '测试用户', screenName: 'testuser'),
        const DownloadFilter(),
      );

      await pumpPage(tester, DownloadFeed.douyin);
      expect(find.textContaining('个任务创建中'), findsNothing);
    });
  });

  group('历史 Tab 的行与台账', () {
    testWidgets('行里有 BV 号、分P标题、UP 主、时间，且没有别家术语', (tester) async {
      await seedPart(tester, 'BV1zx411c7mD', '310000000',
          title: '【测试】第 3 话 中文字幕', author: '测试UP主');

      await pumpPage(tester, DownloadFeed.bili);
      await openHistoryTab(tester);

      expect(find.text('【测试】第 3 话 中文字幕'), findsOneWidget);
      expect(find.textContaining('BV1zx411c7mD'), findsOneWidget);
      expect(find.textContaining('测试UP主'), findsOneWidget);
      expect(find.textContaining('共 1 个分P'), findsOneWidget);
      // 时间：台账落的是 epoch millis，渲染成 YYYY-MM-DD HH:mm
      expect(find.textContaining(RegExp(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}')),
          findsOneWidget);

      for (final text in visibleTexts(tester)) {
        for (final term in biliForbidden) {
          expect(text.toLowerCase(), isNot(contains(term.toLowerCase())),
              reason: 'B 站的下载历史页面上出现了「$term」：$text');
        }
      }
    });

    testWidgets('没记录时空态说清「记的是下过的分P，移走也算下过」', (tester) async {
      await pumpPage(tester, DownloadFeed.bili);
      await openHistoryTab(tester);

      expect(find.text('还没有下载记录'), findsOneWidget);
      expect(find.textContaining('把文件移走或删掉也仍然算下过'), findsOneWidget);
    });

    testWidgets('单条移除：行消失，台账里也真的少了（下次才会重新下）', (tester) async {
      await seedPart(tester, 'BV1rem000001', '4001',
          title: '要删掉的分P', author: 'UP 乙');
      final key = biliPartKey(bvid: 'BV1rem000001', cid: '4001');
      expect(bili.contains(key), isTrue);

      await pumpPage(tester, DownloadFeed.bili);
      await openHistoryTab(tester);
      expect(find.text('要删掉的分P'), findsOneWidget);

      // drop() 里要落盘，整段动作放进 runAsync（假时钟等不到那次写盘完成）
      await tester.runAsync(() async {
        await tester.tap(
            find.byTooltip('从历史中移除（下次会重新下载）'));
        await Future.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });
      await settle(tester);

      expect(find.text('要删掉的分P'), findsNothing);
      expect(bili.count, 0,
          reason: '删了就该从台账里消失，否则下次批量下载还会跳过这个分P');
      expect(bili.contains(key), isFalse);
    });

    testWidgets('清空：确认后台账与台账文件都空了', (tester) async {
      await seedPart(tester, 'BV1cle0000001', '5001', title: '分P 甲');
      await seedPart(tester, 'BV1cle0000002', '5002', title: '分P 乙');
      expect(bili.doneCount, 2);

      await pumpPage(tester, DownloadFeed.bili);
      await openHistoryTab(tester);

      await tester.tap(find.text('清空'));
      await settle(tester);
      // 确认框照抖音那份的措辞结构来，但说的是分 P
      expect(find.text('清空下载历史？'), findsOneWidget);
      expect(find.textContaining('就不会再跳过这些分P了'), findsOneWidget);

      // 确认这一路必须整段待在 runAsync 里：`_confirmClear` 里既有弹窗退场
      // 动画（要 pump）又有 `clear()` 的真实写盘（要真实事件循环）。
      // 把 tap 放在假时钟那边发起的话，那条 await 链会卡在假时钟的队列上，
      // 表现成「盘写了、提示没弹」。
      final ledgerFile = File('${AppPaths.configDir.path}'
          '${Platform.pathSeparator}${BiliLedger.fileName}');
      Map? onDisk;
      await tester.runAsync(() async {
        await tester.tap(find.descendant(
            of: find.byType(AlertDialog), matching: find.text('清空')));
        // 轮询而不是拍一个固定延时：慢盘上固定延时会假失败
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 60));
          await Future<void>.delayed(const Duration(milliseconds: 40));
          if (!ledgerFile.existsSync()) continue;
          onDisk = jsonDecode(ledgerFile.readAsStringSync()) as Map;
          if ((onDisk!['items'] as Map).isEmpty) {
            // 盘落了之后还要再推几帧：`await ledger.clear()` 之后的那句提示排在
            // 真实事件循环上，立刻退出 runAsync 它就赶不上，表现成「清了但没吭声」。
            for (var j = 0; j < 4; j++) {
              await Future<void>.delayed(const Duration(milliseconds: 30));
              await tester.pump();
            }
            break;
          }
        }
      });
      await settle(tester);

      expect(bili.count, 0, reason: '确认之后 clear() 该被调到（内存里先清）');
      expect(bili.doneCount, 0);
      expect(find.text('分P 甲'), findsNothing);
      // 内存里清了还不算数：写盘失败时用户以为清干净了，下次批量下载却继续跳过
      expect(onDisk, isNotNull, reason: '${BiliLedger.fileName} 根本没写出来');
      expect(onDisk!['items'], isEmpty,
          reason: '清空必须落盘，否则下次启动台账又回来了');
      // 清成功了要说得出口：静默清完和「写盘失败但记录还在」在界面上长得一样
      expect(find.textContaining('已清除 B 站下载记录'), findsOneWidget);

      await flushToast(tester);
    });

    testWidgets('取消确认框不动台账', (tester) async {
      await seedPart(tester, 'BV1keep00001', '6001', title: '留下吧');

      await pumpPage(tester, DownloadFeed.bili);
      await openHistoryTab(tester);
      await tester.tap(find.text('清空'));
      await settle(tester);

      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('取消')));
      await settle(tester);

      expect(bili.doneCount, 1);
      expect(find.text('留下吧'), findsOneWidget);
    });
  });

  group('英文档不漏翻（历史分区每句都得有对照）', () {
    testWidgets('Tab 名、计数行、行内的分P说法都翻了', (tester) async {
      preferredLocale = AppLocale.en;
      await seedPart(tester, 'BV1en0000001', '7001',
          title: 'Part three', author: 'SomeUP');

      await pumpPage(tester, DownloadFeed.bili);
      // 队列表头的引导语也在表里：英文界面不该夹这句中文
      expect(find.textContaining('Pick parts on the Bilibili'), findsOneWidget);

      expect(find.text('Downloaded (Bilibili)'), findsOneWidget);
      expect(find.text('已下载（B 站）'), findsNothing);

      await tester.tap(find.text('Downloaded (Bilibili)'));
      await settle(tester);
      expect(find.textContaining('1 parts in total'), findsOneWidget);
      expect(find.textContaining('Part 7001'), findsOneWidget);
      expect(find.textContaining('BV1en0000001'), findsOneWidget);
      expect(find.textContaining('Uploader'), findsNothing,
          reason: '这条记录有 UP 主，不该落到「UP 主未知」那句兜底上');
      expect(find.textContaining('SomeUP'), findsOneWidget);
    });

    testWidgets('英文档的空态与表头也翻了', (tester) async {
      preferredLocale = AppLocale.en;
      await pumpPage(tester, DownloadFeed.bili);
      await tester.tap(find.text('Downloaded (Bilibili)'));
      await settle(tester);

      expect(find.text('No download records yet'), findsOneWidget);
      expect(find.textContaining('moving or deleting the files'), findsOneWidget);
      // 清空按钮走的是共用的那句（说法不带平台名），已经有条目才谈得上清空
      expect(find.text('还没有下载记录'), findsNothing);
    });
  });

  group('术语串门扫描（照 module_boundary 的口径，按文件扫）', () {
    const sectionPath = 'lib/widgets/download_history_section.dart';

    test('扫描器真读得到这个文件的字面量（正控制，免得负扫永远绿）', () {
      final lits = stringLiterals(File(sectionPath).readAsStringSync());
      // B 站自己的说法必须扫得到……
      expect(lits.any((s) => s.contains('分P')), isTrue,
          reason: '一条 B 站说法都没扫到，说明提取器跟不上源码写法，那下面的空结果毫无意义');
      // ……而对照组必须能被扫出「抖音」字样：同一个提取器扫共用的下载管理页，
      // 那里合法地写着「已下载（抖音）」，扫不出来说明它把字面量整份漏了。
      final shared = stringLiterals(
          File('lib/pages/download_management_page.dart').readAsStringSync());
      expect(shared.any((s) => s.contains('抖音')), isTrue);
    });

    test('B 站历史分区的界面文案里没有 X 与抖音说法', () {
      final hits = [
        for (final lit in stringLiterals(File(sectionPath).readAsStringSync()))
          for (final term in biliForbidden)
            if (lit.toLowerCase().contains(term.toLowerCase()))
              '「${lit.replaceAll('\n', '⏎')}」含「$term」',
      ];
      expect(hits, isEmpty);
    });

    test('B 站自己的历史 Tab 名不在另外两个模块的页面上渲染', () {
      // kBiliHistoryTab 只在 DownloadFeed.bili 那一条分支里进 knownTabs；
      // 这条由上面「历史 Tab 的归属」那组用例覆盖，这里钉住常量本身没被写串。
      expect(kBiliHistoryTab, '已下载（B 站）');
      expect(DownloadFeed.bili.historyTabName, kBiliHistoryTab);
      expect(DownloadFeed.douyin.historyTabName, isNot(kBiliHistoryTab));
      expect(DownloadFeed.x.historyTabName, isNull);
    });
  });

  group('三个队列的判据各是各的', () {
    test('hasHistoryTab / hasCreationTasks 的归属', () {
      // 有台账的才有历史 Tab；只有 X 有翻页抓取
      expect(DownloadFeed.x.hasHistoryTab, isFalse);
      expect(DownloadFeed.douyin.hasHistoryTab, isTrue);
      expect(DownloadFeed.bili.hasHistoryTab, isTrue);
      expect(DownloadFeed.x.hasCreationTasks, isTrue);
      expect(DownloadFeed.douyin.hasCreationTasks, isFalse);
      expect(DownloadFeed.bili.hasCreationTasks, isFalse);
    });

    test('source 与 Media.source 对得上', () {
      expect(DownloadFeed.values.map((f) => f.source), ['x', 'douyin', 'bili']);
    });
  });
}
