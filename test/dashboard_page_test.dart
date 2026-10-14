import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/app.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/pages/dashboard_page.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/bili_ledger.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/app_card.dart';
import 'package:parse_dl/widgets/nav_items.dart';

/// 首页「总览」的判据。
///
/// 覆盖任务书的 5 条：渲染四区块 / 统计读真实数据 / 快捷入口回调 /
/// 路由两处注册 / 默认落地。每一条都要能**判错** —— 只测「渲染出来了」
/// 是恒真的，所以统计那条带负控制（清空 store 必须显示 0），
/// 路由那条带反例（不存在的 id 不许在清单里）。
void main() {
  late Directory tmp;
  late DownloadStore downloads;
  late BiliLedger biliLedger;
  late DouyinStore douyinStore;
  late SettingsStore settings;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dashboard-');
    await AppPaths.init(exeDirOverride: tmp, fallbackOverride: tmp);
    downloads = DownloadStore()..setSaveDir(tmp.path);
    biliLedger = BiliLedger();
    douyinStore = DouyinStore();
    settings = SettingsStore();
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Media media(String id, {String source = 'x'}) => Media(
        id: id,
        type: MediaType.video,
        url: 'https://cdn.example.invalid/$id.mp4',
        source: source,
        tweetId: '1700000000000000000',
      );

  /// 塞一条任务并返回它的 localId（状态由调用方自己翻）。
  ///
  /// **媒体 id 必须逐条唯一**：`DownloadStore.addPending` 的 localId 是
  /// `'${media.id}_${DateTime.now().microsecondsSinceEpoch}'`，而 Windows 上
  /// `DateTime.now()` 的实际精度只有毫秒级 —— 同一个测试里连着调两次时两个
  /// localId 会**完全相同**，后一条把前一条覆盖掉（实测：两条 active 只数出 1）。
  /// 所以这里带一个自增序号。
  var seedSeq = 0;
  String seed(DownloadStatus status, {String source = 'x', String id = ''}) {
    seedSeq++;
    final localId = downloads.addPending(
      media(
        id.isEmpty ? '${status.name}-$source-$seedSeq' : '$id-$seedSeq',
        source: source,
      ),
      tmp.path,
      fileName: '示例文件.mp4',
    );
    downloads.task(localId)!.status = status;
    return localId;
  }

  /// 在真实 Provider 树上渲染首页（与 `app.dart` 的挂载一致）。
  ///
  /// 视口给足高度：`ListView` 只构造可见区，视口太矮时下面的卡片根本
  /// 没被 build，`findsOneWidget` 会误报「区块缺失」。
  Future<void> pump(WidgetTester tester, {void Function(String)? onNavigate}) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<DownloadStore>.value(value: downloads),
            ChangeNotifierProvider<BiliLedger>.value(value: biliLedger),
            ChangeNotifierProvider<DouyinStore>.value(value: douyinStore),
            ChangeNotifierProvider<SettingsStore>.value(value: settings),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: DashboardPage(onNavigate: onNavigate),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 取某张统计卡里的数值文本。
  ///
  /// 按 `label → 卡片 → 数值` 定位，而不是全页 `find.text('2')`：
  /// 页面上别处也可能出现同一个数字，全页找会把「统计读对了」
  /// 变成「恰好哪里有个 2」。
  ///
  /// 2026-10-15 总览页改用共享 [StatGrid]（`lib/widgets/stat_grid.dart`）后，
  /// 数值那一行是 `Text.rich`（数字 + 单位两个 `TextSpan`，单位要小一号），
  /// 所以 `Text.data` 是 `null` —— 得从 `textSpan.toPlainText()` 取。
  /// **判据语义没变**：仍然是「按 label 找到那张卡，读它里面的数值」。
  Finder statValue(String label) => find.descendant(
        of: find.ancestor(
          of: find.text(label),
          matching: find.byType(AppCard),
        ),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Text &&
              w.textSpan != null &&
              RegExp(r'^\d').hasMatch(w.textSpan!.toPlainText()),
        ),
      );

  /// 读出 [statValue] 定位到的那段文本（`Text.rich` 走 `textSpan`）。
  String statText(WidgetTester tester, String label) {
    final w = tester.widget<Text>(statValue(label));
    return w.data ?? w.textSpan!.toPlainText();
  }

  group('判据 1 · 四段式区块都在', () {
    testWidgets('欢迎条 / 统计块 / 快捷开始 / 最近活动四段都渲染出来', (tester) async {
      await pump(tester);

      // ① 欢迎条：应用名 + 版本
      expect(find.text('解析下载器'), findsOneWidget, reason: '欢迎条缺应用名');
      expect(
        find.text('v$kDashboardVersion'),
        findsOneWidget,
        reason: '欢迎条缺版本药丸',
      );

      // ② 统计块 4 个（逐个点名，不用 hasLength —— 少一个也要当场报出来）
      for (final label in ['进行中', '已完成', '下载台账', '磁盘占用']) {
        expect(find.text(label), findsOneWidget, reason: '统计块缺「$label」');
      }

      // ③ 左栏上一：快捷开始
      expect(find.text('快捷开始'), findsOneWidget);

      // ④ 左栏下一：最近活动
      expect(find.text('最近活动'), findsOneWidget);

      // ④ 右栏：模块状态 / 下载引擎 / 环境
      expect(find.text('模块状态'), findsOneWidget);
      expect(find.text('下载引擎'), findsOneWidget);
      expect(find.text('环境'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('统计块数量正好 4 个（多一个少一个都报）', (tester) async {
      await pump(tester);
      // 4 张统计卡的 label 各自唯一 → 4 条「label 所在卡片」互不重复
      final cards = {
        for (final label in ['进行中', '已完成', '下载台账', '磁盘占用'])
          identityHashCode(
            tester.widget<AppCard>(
              find.ancestor(
                of: find.text(label),
                matching: find.byType(AppCard),
              ).first,
            ),
          ),
      };
      expect(cards.length, 4, reason: '统计块应各自一张卡');
    });
  });

  group('判据 2 · 统计读真实数据（带负控制）', () {
    testWidgets('2 条 active + 1 条 complete → 显示 2 与 1', (tester) async {
      seed(DownloadStatus.active);
      seed(DownloadStatus.active);
      seed(DownloadStatus.complete);

      await pump(tester);

      expect(statValue('进行中'), findsOneWidget);
      expect(statText(tester, '进行中'), startsWith('2'),
          reason: '进行中应等于 active 条数');
      expect(statText(tester, '已完成'), startsWith('1'),
          reason: '已完成应等于 complete 条数');
    });

    testWidgets('负控制：清空 store 后必须显示 0（证明不是写死）', (tester) async {
      seed(DownloadStatus.active);
      seed(DownloadStatus.active);
      seed(DownloadStatus.complete);
      await pump(tester);
      expect(statText(tester, '进行中'), startsWith('2'));

      // 同样的页面，数据换成空 —— 数字必须跟着走
      downloads.clearWhere((_) => true);
      await tester.pumpAndSettle();

      expect(statText(tester, '进行中'), startsWith('0'),
          reason: '清空后仍是 2 → 这个数字是写死的');
      expect(statText(tester, '已完成'), startsWith('0'));
    });

    testWidgets('四种非终态都算「进行中」，error 不算', (tester) async {
      seed(DownloadStatus.pending, id: 'p');
      seed(DownloadStatus.active, id: 'a');
      seed(DownloadStatus.waiting, id: 'w');
      seed(DownloadStatus.paused, id: 'z');
      seed(DownloadStatus.error, id: 'e');

      await pump(tester);

      expect(statText(tester, '进行中'), startsWith('4'),
          reason: 'pending/active/waiting/paused 应合计 4（error 不算）');
      expect(statText(tester, '已完成'), startsWith('0'));
    });

    testWidgets('台账合计 = BiliLedger.count + DouyinLedger.count', (tester) async {
      // 真文件 I/O **必须**包在 runAsync 里。
      //
      // `markDone` → `_commit` → `_save` → `_write()` 走的是真实磁盘写，而
      // `testWidgets` 跑在 FakeAsync 虚拟时钟下 —— 真 I/O 的 Future 永远不会
      // 被推进，直接 await 它会把**整条用例永久挂起**（不是超时失败，是死等）。
      // 2026-10-13 实测：整文件跑到本条之后再无输出，flutter_tester 的 CPU
      // 十分钟零增长，单跑本条 70s 不返回。`runAsync` 会切到真实事件循环。
      await tester.runAsync(() async {
        await biliLedger.markDone([biliPartKey(bvid: 'BV1', cid: '1001')]);
        await biliLedger.markDone([biliPartKey(bvid: 'BV1', cid: '1002')]);
        await douyinStore.ledger.markAll(['aweme-1']);
      });

      await pump(tester);

      expect(statText(tester, '下载台账'), startsWith('3'),
          reason: '2 条 B 站 + 1 条抖音 = 3');
    });
  });

  group('判据 3 · 快捷入口回调', () {
    testWidgets('6 个入口各自以目标路由 id 调用 onNavigate', (tester) async {
      final taps = <String>[];
      await pump(tester, onNavigate: taps.add);

      // 逐个点，每点一次就核对一次 —— 一次性收集再整体比会放过
      // 「六个都跳同一个路由」这种错。
      const expected = ['home', 'douyin', 'bili', 'auto-task', 'bili-batch', 'douyin-auto'];
      for (var i = 0; i < DashboardPage.quickEntries.length; i++) {
        final entry = DashboardPage.quickEntries[i];
        Finder tile = find.text(entry.title);
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(taps, expected.sublist(0, i + 1),
            reason: '第 ${i + 1} 个入口（${entry.title}）没跳到 ${expected[i]}');
      }
      expect(taps, expected);
    });

    testWidgets('快捷入口的目标路由全都在 kAppRoutes 里（点下去不会掉进占位页）',
        (tester) async {
      for (final id in DashboardPage.quickRouteIds) {
        expect(kAppRoutes, contains(id),
            reason: '快捷入口 $id 没登记进 kAppRoutes → 保活降级/占位页');
      }
    });

    testWidgets('onNavigate 为 null 时点击不崩', (tester) async {
      await pump(tester);
      await tester.ensureVisible(find.text('X 主页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('X 主页'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('判据 4 · 路由两处都注册（带反例）', () {
    final appSrc = File('lib/app.dart').readAsStringSync();

    test('kAppRoutes 含 dashboard，且排在清单最前（默认页）', () {
      expect(kAppRoutes, contains('dashboard'));
      expect(kAppRoutes.first, 'dashboard', reason: '默认落地页应排在清单最前');
      expect(kAppRoutes.toSet().length, kAppRoutes.length, reason: '清单里有重复 id');
    });

    test('_pageFor 有 case dashboard，且接的是 DashboardPage', () {
      final m = RegExp(r"case 'dashboard':").firstMatch(appSrc);
      expect(m, isNotNull, reason: '漏了这一处会静默降级成占位页');
      final body = appSrc.substring(m!.end, m.end + 160);
      expect(body, contains('DashboardPage'));
      expect(body, contains('onNavigate'), reason: '快捷入口要靠注入的回调跳转');
    });

    test('负控制：不存在的路由不在清单里，也没有 case', () {
      expect(kAppRoutes, isNot(contains('dashboard-nope')));
      expect(appSrc, isNot(contains("case 'dashboard-nope'")));
      // 正控制：同一条正则在真 case 上必须命中，否则上面那条是恒真的
      expect(
        RegExp(r"case 'dashboard-nope':").hasMatch("case 'dashboard':"),
        isFalse,
      );
      expect(RegExp(r"case 'dashboard':").hasMatch(appSrc), isTrue);
    });

    test('总览的导航项已登记（置顶列表，不属于三个模块）', () {
      expect(kNavPrimary.map((e) => e.id), contains('dashboard'));
      expect(kNavItems.map((e) => e.id), contains('dashboard'));
      // 它不能在模块里 —— 主页不是模块，这条是导航语义的护栏
      for (final g in kNavGroups) {
        expect(g.children.map((c) => c.id), isNot(contains('dashboard')),
            reason: '总览被塞进模块组「${g.id}」了');
      }
    });
  });

  group('判据 5 · 默认落地', () {
    final appSrc = File('lib/app.dart').readAsStringSync();

    test('_AppShellState 的初值是 dashboard（_routeId 与 _visited 同步）', () {
      expect(appSrc, contains("String _routeId = 'dashboard';"),
          reason: '_routeId 初值不是默认落地页');
      expect(appSrc, contains("final List<String> _visited = ['dashboard'];"),
          reason: '_visited 初值与 _routeId 不一致 → 首帧保活失效');
    });

    test('负控制：源码里已经没有 _routeId = home 的旧初值', () {
      expect(appSrc, isNot(contains("String _routeId = 'home';")));
      expect(appSrc, isNot(contains("final List<String> _visited = ['home'];")));
    });

    test('保活栈对 dashboard 的处理与其它路由一致（首个已访问页）', () {
      // dashboard 在清单里 → 有栈；它是首个已访问页 → 下标 0
      final s = keepAliveStack(['dashboard'], 'dashboard');
      expect(s, isNotNull, reason: 'dashboard 不在 kAppRoutes 里 → 退回单页渲染');
      expect(s!.index, 0);
      expect(s.children, ['dashboard']);

      // 与别的页面一起时仍按首次访问序，位置不漂
      final s2 = keepAliveStack(['dashboard', 'bili', 'douyin'], 'douyin')!;
      expect(s2.children, ['dashboard', 'bili', 'douyin']);
      expect(s2.index, 2);
    });

    test('标题栏给 dashboard 配了文案', () {
      expect(appSrc, contains("'dashboard' =>"), reason: '标题栏没有总览的映射');
    });
  });

  group('版本号不许与 app.dart 脱钩', () {
    test('kDashboardVersion 与 app.dart 的 kAppVersion 逐字节相同', () {
      // 首页欢迎条上的版本号是本文件里的常量（不能 import app.dart：
      // 那会形成 app.dart → dashboard_page.dart → app.dart 的循环）。
      // 所以用这条判据把两边钉住：改了 app.dart 不改这里就红。
      final m = RegExp(r"kAppVersion = '([^']+)'").firstMatch(
        File('lib/app.dart').readAsStringSync(),
      );
      expect(m, isNotNull, reason: 'app.dart 里找不到 kAppVersion');
      expect(kDashboardVersion, m!.group(1));
    });
  });
}
