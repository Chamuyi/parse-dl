import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/pages/download_management_page.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/aria2.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/auto_task_store.dart';
import 'package:parse_dl/services/creation_task_store.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_auto_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/services/homepage_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/app_toast.dart';

/// 「在错误 Tab 点重试 → 只是重新推了一遍，旧错误行还在，同一条媒体变成两行」
/// —— 2026-10-04 用户真机报的。
///
/// 根因有两层，这个文件把两层都钉住：
///
///   1. **`retryTask` 丢掉了 `remove()` 的返回值**：旧行没删掉就无条件 `_submit`，
///      于是新旧两行并存。现在移不掉就**不投新任务**，返回
///      [EnqueueOutcome.removeFailed] 并把引擎原文带给界面。
///   2. **`_unknownGidFault` 只认一种措辞**：用仓库自带的 aria2c 1.37.0 实测
///      （本机起临时 RPC + 临时源，对每种状态各发一次 `remove`）—— 对**已完成 /
///      已失败落到 stopped / 已被 forceRemove** 的任务调 `aria2.remove`，回的是
///      `Active Download not found for GID#<hex>`，而不是先前认的那句
///      `GID <hex> is not found`。用户那批「错误」行恰恰是后者，所以 remove
///      被误判成真失败、旧行删不掉 —— 上面那条重复行就是它触发的。
///
/// **负控制**（改坏代码时必须变红，别把用例当成永真）：
///   * 把 `retryTask` 里那句 `if (rm.outcome == RemoveOutcome.failed)` 判断去掉
///     （退回无条件 `_submit`）→ 下面 group「移不掉就不新建」整组红；
///   * 把正则放宽成「任何异常都算已不存在」→ group「非判据里的措辞仍算失败」红；
///   * 把正则收窄回只认 `GID … is not found`（删掉第二个备选分支）→
///     group「第二种措辞」红。
void main() {
  /// aria2 对「已不在活跃队列」的 gid 调 remove 的真机原文（HTTP 400 的
  /// `error.message`，Dart 侧再包一层成 `aria2 调用 aria2.remove 失败：…`）。
  const kActiveNotFoundRaw = 'Active Download not found for GID#e9b5ca82854c8163';
  const kActiveNotFoundFault = 'aria2 调用 aria2.remove 失败：$kActiveNotFoundRaw';
  const kOldWordingFault =
      'aria2 调用 aria2.remove 失败：GID e9b5ca82854c8163 is not found';

  late Directory tmp;

  /// 每条任务用**唯一**的 media id。
  ///
  /// 不是洁癖：`DownloadStore.addPending` 的 localId 是
  /// `<media.id>_<microsecondsSinceEpoch>`，假传输层的 remove 零耗时，同一条 media
  /// 连着两次 addPending 会落进**同一微秒**、key 互相覆盖，
  /// 「旧行没了、新行一条」就退化成看不出来的假通过（写这个文件时踩过）。
  var mediaSeq = 0;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jxxzq_retry_dup_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Media media() {
    final id = 'dup${mediaSeq++}';
    return Media(
      id: id,
      type: MediaType.image,
      url: 'https://cdn.example.invalid/$id.jpg',
      source: 'x',
    );
  }

  /// 协调器 + 已绑定 store，并真的走一次入队（这样任务才有 gid）。
  Future<({Aria2Coordinator c, DownloadStore s, _FakeAria2 a, String localId})>
      booted(Object? removeError) async {
    final aria = _FakeAria2(removeError: removeError);
    final c = Aria2Coordinator.withAria2(aria);
    final s = DownloadStore()..setSaveDir(tmp.path);
    await c.bootstrap(store: s, settings: SettingsStore());
    final r = await c.enqueueMedia(media());
    expect(r.outcome, EnqueueOutcome.queued, reason: '前置条件：任务要真的进了队列');
    return (c: c, s: s, a: aria, localId: r.localId!);
  }

  group('第二种措辞也算「引擎里已经没有它了」（B）', () {
    test('真机原文判得出来（含 aria2 调用前缀 / 裸串 / 大小写与空格容错）', () {
      expect(isUnknownGidFault(StateError(kActiveNotFoundFault)), isTrue);
      expect(isUnknownGidFault(StateError(kActiveNotFoundRaw)), isTrue);
      expect(
          isUnknownGidFault(
              StateError('active download not found for gid#E9B5CA82854C8163')),
          isTrue);
      // 先前认的那句不能因为加了新分支就退回去
      expect(isUnknownGidFault(StateError(kOldWordingFault)), isTrue);
    });

    test('remove 遇到这句 → alreadyGone、本地行删掉', () async {
      final env = await booted(StateError(kActiveNotFoundFault));

      final r = await env.c.remove(env.localId);

      expect(r.outcome, RemoveOutcome.alreadyGone);
      expect(env.s.task(env.localId), isNull);
      expect(env.a.removeCalls, 1, reason: '还是要真的问过一次引擎');

      await env.c.dispose();
    });

    test('重试一条「引擎侧已清理」的错误任务：照常重下，且只剩一行', () async {
      final env = await booted(StateError(kActiveNotFoundFault));
      env.s.markErrorByGid(env.a.gid, '403 Forbidden');

      final r = await env.c.retryTask(env.localId);

      expect(r.outcome, EnqueueOutcome.queued);
      expect(r.message, isNull);
      expect(env.s.tasks, hasLength(1),
          reason: '这就是用户报的两行：旧错误行必须先消失');
      expect(env.a.addCount, 2, reason: '旧行清掉后确实重新投了一遍');
      expect(env.s.tasks.single.status, isNot(DownloadStatus.error));

      await env.c.dispose();
    });
  });

  group('非判据里的措辞仍算失败（B 的反向用例）', () {
    /// 每一条都必须**判不出**「已不存在」。放宽成「任何异常都算」时这里就红。
    final stillFailed = <({String name, Object err})>[
      (
        name: 'RPC 连不通',
        err: SocketException('Connection refused',
            osError: const OSError('Connection refused', 122),
            address: InternetAddress('127.0.0.1'),
            port: 6800),
      ),
      (
        name: 'RPC 超时',
        err: TimeoutException('Future not completed', const Duration(seconds: 30)),
      ),
      (
        name: '引擎压根没起来',
        err: StateError('aria2 尚未就绪'),
      ),
      (
        // 源站没有资源，不代表引擎没有这条任务
        name: '源站 404',
        err: StateError('aria2 调用 aria2.remove 失败：'
            'The requested URL returned error: 404 Not Found'),
      ),
      (
        // 二进制里确有这句，但实测**不是** remove/forceRemove 发的（见取证文件），
        // 收进来就等于放宽判据 —— 这里钉住它不算。
        name: '另一句 not active（实测不来自 remove）',
        err: StateError('aria2 调用 aria2.remove 失败：'
            'No active download for GID#e9b5ca82854c8163'),
      ),
      (
        name: '移除结果条目失败',
        err: StateError('aria2 调用 aria2.remove 失败：'
            'Could not remove download result of GID#e9b5ca82854c8163'),
      ),
      (
        // 结构不完整：没有 gid 本体，不能当成「引擎明确说这条不存在」
        name: '少了 gid 的半截措辞',
        err: StateError('aria2 调用 aria2.remove 失败：'
            'Active Download not found for GID#'),
      ),
      (
        // gid 位子上不是十六进制串
        name: 'gid 位子上是别的东西',
        err: StateError('aria2 调用 aria2.remove 失败：'
            'Active Download not found for GID#not-a-gid'),
      ),
      (
        name: '这条现在不许动',
        err: StateError('aria2 调用 aria2.remove 失败：'
            'GID#e9b5ca82854c8163 cannot be removed now'),
      ),
    ];

    for (final e in stillFailed) {
      test('${e.name} → 不算已不存在', () {
        expect(isUnknownGidFault(e.err), isFalse,
            reason: '${e.name}：判据一放宽就退回修掉的静默失败');
      });
    }

    test('重试时遇到这些异常：不投新任务、旧行保留', () async {
      final env = await booted(
        SocketException('Connection refused',
            osError: const OSError('Connection refused', 122),
            address: InternetAddress('127.0.0.1'),
            port: 6800),
      );
      env.s.markErrorByGid(env.a.gid, '403 Forbidden');
      final addsBefore = env.a.addCount;

      final r = await env.c.retryTask(env.localId);

      expect(r.outcome, EnqueueOutcome.removeFailed);
      expect(env.a.addCount, addsBefore,
          reason: '旧行没清掉就再投一遍，正是用户看到的「同一条媒体两行」');
      expect(env.s.tasks, hasLength(1));
      expect(env.s.task(env.localId), isNotNull,
          reason: '引擎那边可能还挂着这条，本地行必须留着');
      expect(env.s.task(env.localId)!.status, DownloadStatus.error);

      await env.c.dispose();
    });
  });

  group('移不掉就不新建，且把原因回给 UI（A）', () {
    test('removeFailed 的 message 带上「重试已取消」与引擎原文', () async {
      final env = await booted(
          TimeoutException('Future not completed', const Duration(seconds: 30)));
      env.s.markErrorByGid(env.a.gid, '500 Internal Server Error');

      final r = await env.c.retryTask(env.localId);

      expect(r.outcome, EnqueueOutcome.removeFailed);
      expect(r.localId, env.localId, reason: '行还在，localId 要指向它');
      expect(r.message, contains('重试已取消'));
      expect(r.message, contains('没能从下载引擎里移除'));
      expect(r.message, contains('Future not completed'),
          reason: '引擎原文要能带出来，否则用户与排查的人都不知道为什么没重试');

      await env.c.dispose();
    });

    test('引擎已不存在的两种措辞都不该挡住重试', () async {
      for (final fault in [kOldWordingFault, kActiveNotFoundFault]) {
        final env = await booted(StateError(fault));
        env.s.markErrorByGid(env.a.gid, '403 Forbidden');

        final r = await env.c.retryTask(env.localId);

        expect(r.outcome, EnqueueOutcome.queued, reason: fault);
        expect(env.s.tasks, hasLength(1), reason: fault);

        await env.c.dispose();
      }
    });

    test('正常移除时行为不变：旧行没了、新行一条', () async {
      final env = await booted(null);
      env.s.markErrorByGid(env.a.gid, '403 Forbidden');

      final r = await env.c.retryTask(env.localId);

      expect(r.outcome, EnqueueOutcome.queued);
      expect(env.a.removeCalls, 1);
      expect(env.a.addCount, 2);
      expect(env.s.tasks, hasLength(1));
      // 按**状态**判，不按 localId 判：`addPending` 的 localId 是
      // `<media.id>_<microsecondsSinceEpoch>`，假传输层的 remove 零耗时，新旧两行
      // 可能落在同一微秒、共用同一个 key —— 那时 `task(旧 localId)` 拿到的是**新行**，
      // 单文件跑绿、全量跑（机器更忙、时钟刻度更粗）就假红。
      expect(env.s.tasks.single.status, isNot(DownloadStatus.error),
          reason: '列表里不该再留着那条错误行');
      expect(env.s.tasks.where((t) => t.status == DownloadStatus.error), isEmpty);

      await env.c.dispose();
    });

    test('任务已经不在表里时仍然不投新任务', () async {
      final env = await booted(null);

      final r = await env.c.retryTask('不存在的id');

      expect(r.outcome, isNot(EnqueueOutcome.queued));
      expect(env.a.addCount, 1, reason: '前置的那次入队而已');

      await env.c.dispose();
    });
  });

  group('用户看到的提示（点真实界面）', () {
    late AppState appState;
    late SettingsStore settings;
    late HomepageStore homepage;
    late DouyinStore douyin;
    late CreationTaskStore creationTasks;
    late AutoTaskStore autoTasks;
    late DouyinAutoStore douyinAuto;
    late _PageEnv env;

    setUp(() async {
      AppPrefs.setMockInitialValues({});
      await AppPaths.init(
          exeDirOverride: tmp, fallbackOverride: tmp);
      settings = SettingsStore();
      appState = await AppState.restore();
      douyin = DouyinStore();
      homepage = HomepageStore(appState);
      douyinAuto = DouyinAutoStore();

      // 装配（bootstrap + 入队碰真实文件 I/O）必须在 setUp 里做完：testWidgets 的
      // body 跑在假时钟里，await 真实 I/O 会以「did not complete」挂死。
      final b = await booted(null);
      b.s.markErrorByGid(b.a.gid, '403 Forbidden');
      await b.c.dispose(); // 停掉 1 秒进度轮询，store 绑定仍保留
      creationTasks = CreationTaskStore(appState: appState, coordinator: b.c);
      autoTasks = AutoTaskStore(
        appState: appState,
        homepageStore: homepage,
        creationTasks: creationTasks,
      );
      Aria2Coordinator.instanceForTest = b.c;
      env = _PageEnv(c: b.c, s: b.s, a: b.a);
    });

    tearDown(() => Aria2Coordinator.instanceForTest = null);

    Future<void> render(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsStore>.value(value: settings),
            ChangeNotifierProvider<AppState>.value(value: appState),
            ChangeNotifierProvider<HomepageStore>.value(value: homepage),
            ChangeNotifierProvider<DownloadStore>.value(value: env.s),
            ChangeNotifierProvider<DouyinStore>.value(value: douyin),
            ChangeNotifierProvider<CreationTaskStore>.value(value: creationTasks),
            ChangeNotifierProvider<AutoTaskStore>.value(value: autoTasks),
            ChangeNotifierProvider<DouyinAutoStore>.value(value: douyinAuto),
          ],
          child: const MaterialApp(
            home: Scaffold(body: DownloadManagementPage(feed: DownloadFeed.x)),
          ),
        ),
      ));
      env.s.setCurrentTab('错误');
      await tester.pump();
    }

    Future<void> tapRetry(WidgetTester tester) async {
      // `retryTask` 会先查磁盘上那份文件在不在（真实文件 I/O）。testWidgets 的 body
      // 跑在假时钟里，这类 await 不放进 runAsync 就永远等不到，表现成"点了没反应"。
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('重试'));
        await Future.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });
    }

    Future<void> settle(WidgetTester tester) async {
      AppToast.dismiss();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    }

    testWidgets('旧行移不掉：仍是一行、没有新行，提示是红色错误且带引擎原文',
        (tester) async {
      env.a.removeError = SocketException('Connection refused',
          osError: const OSError('Connection refused', 122),
          address: InternetAddress('127.0.0.1'),
          port: 6800);
      await render(tester);
      expect(find.text('403 Forbidden'), findsOneWidget);
      final addsBefore = env.a.addCount;

      await tapRetry(tester);

      expect(env.a.addCount, addsBefore, reason: '没清掉旧任务就不该再投一遍');
      expect(env.s.tasks, hasLength(1), reason: '用户报的就是这里变成两行');
      expect(find.text('403 Forbidden'), findsOneWidget, reason: '旧错误行还在原位');
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(find.textContaining('重试已取消'), findsOneWidget);
      expect(find.textContaining('Connection refused'), findsOneWidget,
          reason: '只说「重试失败」等于没说，要把原因给出去');

      await settle(tester);
    });

    testWidgets('引擎回「Active Download not found」：旧行消失、只剩一行，不弹错误',
        (tester) async {
      env.a.removeError = StateError(kActiveNotFoundFault);
      await render(tester);
      expect(find.text('403 Forbidden'), findsOneWidget);

      await tapRetry(tester);

      expect(env.s.tasks, hasLength(1));
      expect(env.s.tasks.single.status, isNot(DownloadStatus.error),
          reason: '旧行已被删掉，剩下的是这次重试新建的那条');
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      expect(find.textContaining('重试已取消'), findsNothing);
      expect(env.a.addCount, 2, reason: '这次重试真的重新投了一遍');

      await settle(tester);
    });

    testWidgets('重试全部：移不掉的计入「没成功」，不会把行数翻倍', (tester) async {
      env.a.removeError = StateError('aria2 尚未就绪');
      await render(tester);
      expect(find.text('重试全部（1）'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.textContaining('重试全部'));
        await Future.delayed(const Duration(milliseconds: 320));
        await tester.pump();
      });

      expect(env.s.tasks, hasLength(1), reason: '批量走的也是单条那条路，同样不能翻倍');
      expect(find.textContaining('1 个没成功'), findsOneWidget);
      expect(find.textContaining('已重新排队 0 个'), findsOneWidget);

      await settle(tester);
    });
  });
}

/// widget 用例的装配结果（在 setUp 里造好，body 里只改 removeError）。
class _PageEnv {
  _PageEnv({required this.c, required this.s, required this.a});

  final Aria2Coordinator c;
  final DownloadStore s;
  final _FakeAria2 a;
}

/// 假传输层：只换掉「进程 + RPC」，remove 抛什么由测试给，addUri 计数用来
/// 判定「有没有偷偷多投一次」。
class _FakeAria2 extends Aria2 {
  _FakeAria2({required this.removeError});

  /// 非 null = `aria2.remove` 抛这个异常。
  Object? removeError;
  final String gid = 'e9b5ca82854c8163';

  int removeCalls = 0;
  int addCount = 0;
  final removedGids = <String>[];

  @override
  Future<void> bootstrap() async {}

  @override
  Future<String> addUri(
    String url, {
    required String dir,
    required String out,
    Map<String, String>? options,
  }) async {
    addCount++;
    return gid;
  }

  @override
  Future<void> remove(String gid) async {
    removeCalls++;
    final e = removeError;
    if (e != null) throw e;
    removedGids.add(gid);
  }

  @override
  Future<AriaTask> tellStatus(String gid) async => AriaTask(
        gid: gid,
        status: AriaStatus.active,
        completeSize: 0,
        totalSize: 100,
        fileName: 'm1.jpg',
        dir: r'C:\tmp',
        error: '',
      );

  @override
  Future<void> pause(String gid) async {}

  @override
  Future<void> unpause(String gid) async {}

  @override
  Future<void> applyGlobalOptions(Map<String, String> o) async {}
}
