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

/// 「错误」列表里那条任务永远删不掉 —— 2026-10-02 用户真机截图报的。
///
/// 现场：点 × 之后弹红色错误
/// `没能从下载引擎里移除，任务先留在列表里：Bad state: aria2 调用 aria2.remove
/// 失败：GID e9b5ca82854c8163 is not found`，再点一次还是一样，行永久卡住。
///
/// 根因：`remove` 把 aria2 抛回来的**任何** fault 都当成「移除失败」。而
/// 「GID 不存在」恰恰说明引擎侧已经没有这条任务了 —— 目标状态早就达成，本地行
/// 应该照删。
///
/// 但这个口子不能开宽：修那批静默失败时特意立了「aria2 没谈拢就不删
/// 本地行 + 必须弹错误」的规矩（当时的原缺陷是失败也照删，于是 aria2 还在写文件、
/// 界面上却没了这条，下次入队又被判「已存在跳过」）。所以这个文件把**两侧都钉住**：
/// unknown-GID 走「删行 + 信息级提示」，连不通/超时/别的 fault 一律维持原样。
///
/// `test/remove_unknown_gid_test.dart` 的两条主用例互为负控制 —— 判定改成
/// 「任何异常都当 GID 不存在」则第二条红，改成「任何异常都算失败」则第一条红。
void main() {
  const kRealFault =
      'aria2 调用 aria2.remove 失败：GID e9b5ca82854c8163 is not found';

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jxxzq_remove_test_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Media media({String id = 'm1'}) => Media(
        id: id,
        type: MediaType.image,
        url: 'https://cdn.example.invalid/$id.jpg',
        source: 'x',
      );

  /// 协调器 + 已绑定的 store：任务走真实入队路径（这样才有 gid）。
  Future<({Aria2Coordinator c, DownloadStore s, _FakeAria2 a, String localId})>
      booted(Object? removeError) async {
    final aria = _FakeAria2(removeError: removeError);
    final c = Aria2Coordinator.withAria2(aria);
    final s = DownloadStore()..setSaveDir(tmp.path);
    await c.bootstrap(store: s, settings: SettingsStore());
    final r = await c.enqueueMedia(media());
    expect(r.localId, isNotNull, reason: '前置条件：任务要真的进了队列');
    return (c: c, s: s, a: aria, localId: r.localId!);
  }

  group('引擎说「没有这条 GID」→ 算已清理', () {
    test('真机原文判得出来（含 Bad state 前缀的 toString 形态）', () {
      expect(isUnknownGidFault(StateError(kRealFault)), isTrue);
      // 同一形状但大小写不同也要认（aria2 只实测到上面那句，这里是容错）
      expect(
          isUnknownGidFault(StateError('aria2.remove 失败：gid E9B5 is not found')),
          isTrue);
    });

    test('删掉本地行，结局是 alreadyGone 而不是失败', () async {
      final env = await booted(StateError(kRealFault));

      final r = await env.c.remove(env.localId);

      expect(r.outcome, RemoveOutcome.alreadyGone);
      expect(env.s.task(env.localId), isNull,
          reason: '引擎里已经没有它了，行必须能删掉 —— 否则用户永远收拾不了这条');
      expect(env.a.removeCalls, 1, reason: '还是要真的问过一次 aria2');

      await env.c.dispose();
    });

    test('重试一条引擎里已不存在的失败任务：不留重复行', () async {
      final env = await booted(StateError(kRealFault));
      env.s.markErrorByGid(env.a.gid, '403 Forbidden');

      final r = await env.c.retryTask(env.localId);

      expect(r.outcome, EnqueueOutcome.queued);
      expect(env.s.tasks.length, 1,
          reason: '旧行没删干净时，重试成功也会让死任务继续挂在「错误」里（同一个根因）');
      expect(env.s.tasks.single.localId, r.localId);

      await env.c.dispose();
    });
  });

  group('其它异常仍是失败', () {
    /// 每一条都必须**留行 + 弹错误**。判据求窄：拿不准就当失败。
    final stillFailed = <({String name, Object err, String needle})>[
      (
        name: 'RPC 连不通',
        err: SocketException('Connection refused',
            osError: const OSError('Connection refused', 122),
            address: InternetAddress('127.0.0.1'),
            port: 6800),
        needle: 'Connection refused',
      ),
      (
        name: 'RPC 超时',
        // 生产里这来自 `_invoke` 的 `.timeout(30s)`
        err: TimeoutException('Future not completed', const Duration(seconds: 30)),
        needle: 'Future not completed',
      ),
      (
        name: '引擎压根没起来',
        err: StateError('aria2 尚未就绪'),
        needle: 'aria2 尚未就绪',
      ),
      (
        // 「Not Found」但不带 GID —— 是源站没有资源，不是引擎没有这条任务
        name: '源站 404',
        err: StateError(
            'aria2 调用 aria2.remove 失败：The requested URL returned error: 404 Not Found'),
        needle: '404 Not Found',
      ),
      (
        name: 'gid 串本身非法',
        err: StateError('aria2 调用 aria2.remove 失败：The length of GID is invalid'),
        needle: 'length of GID is invalid',
      ),
      (
        name: '磁盘/权限类异常',
        err: const FileSystemException('拒绝访问', 'D:\\downloads\\a.jpg'),
        needle: '拒绝访问',
      ),
      (
        name: 'aria2 说这条当前不能删',
        err: StateError(
            'aria2 调用 aria2.remove 失败：Pause is not allowed for gid e9b5ca82854c8163'),
        needle: 'not allowed',
      ),
    ];

    for (final e in stillFailed) {
      test('${e.name} → 行保留、结局 failed、原因带上原文', () async {
        final env = await booted(e.err);

        final r = await env.c.remove(env.localId);

        expect(r.outcome, RemoveOutcome.failed, reason: '${e.name} 不能算已清理');
        expect(isUnknownGidFault(e.err), isFalse);
        expect(env.s.task(env.localId), isNotNull,
            reason: 'aria2 那边可能还在写同一个文件，删了行就退回「引擎失败却照删本地行」');
        expect(r.message, contains('没能从下载引擎里移除'));
        expect(r.message, contains(e.needle),
            reason: '给用户的原因要带上引擎侧原文，否则无从下手');

        await env.c.dispose();
      });
    }

    test('aria2 正常移除 → removed，行删掉', () async {
      final env = await booted(null);

      final r = await env.c.remove(env.localId);

      expect(r.outcome, RemoveOutcome.removed);
      expect(r.message, isNull);
      expect(env.s.task(env.localId), isNull);
      expect(env.a.removedGids, [env.a.gid]);

      await env.c.dispose();
    });

    test('本地压根没有 gid 时不去问引擎，直接删行', () async {
      final aria = _FakeAria2(removeError: null);
      final c = Aria2Coordinator.withAria2(aria);
      final s = DownloadStore()..setSaveDir(tmp.path);
      await c.bootstrap(store: s, settings: SettingsStore());
      final id = s.addPending(media(id: 'no-gid'), tmp.path, fileName: 'n.jpg');

      final r = await c.remove(id);

      expect(r.outcome, RemoveOutcome.removed);
      expect(aria.removeCalls, 0, reason: '没有 gid 就不该发 aria2.remove');
      expect(s.task(id), isNull);

      await c.dispose();
    });
  });

  group('用户看到的提示分级（点真实的 ×）', () {
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

      // 装配（bootstrap + 入队会碰真实文件 I/O）必须在 setUp 里做完：
      // `testWidgets` 的 body 跑在假时钟里，await 真实 I/O 的 future 永远不完成，
      // 整条用例会以「did not complete」挂死（pause_resume_test 里也记着这条陷阱）。
      final b = await booted(null);
      b.s.markErrorByGid(b.a.gid, '403 Forbidden');
      // 停掉 1 秒进度轮询：它是 Timer.periodic，留着会把下面的 pump 拖住。
      // dispose 只断事件与轮询，`_store` 仍绑着，remove() 照常走生产路径。
      await b.c.dispose();
      creationTasks = CreationTaskStore(appState: appState, coordinator: b.c);
      autoTasks = AutoTaskStore(
        appState: appState,
        homepageStore: homepage,
        creationTasks: creationTasks,
      );
      // 页面直接读 `Aria2Coordinator.instance`，只能用这个缝隙把假协调器换进去
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

    /// 点 × 后走完弹层动画（不等它自动消失）。
    Future<void> tapRemove(WidgetTester tester) async {
      await tester.tap(find.byTooltip('移除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
    }

    /// 走完提示条的自动消失，避免测试结束时留下 pending timer。
    Future<void> settle(WidgetTester tester) async {
      AppToast.dismiss();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    }

    testWidgets('引擎里已无此任务：行从列表消失，提示是信息级而不是红色错误',
        (tester) async {
      env.a.removeError = StateError(kRealFault);
      await render(tester);
      expect(find.text('403 Forbidden'), findsOneWidget,
          reason: '前置条件：错误 Tab 里确实看得见这条');

      await tapRemove(tester);

      expect(find.text('引擎里已经没有它了，已从列表移除'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing,
          reason: '引擎侧早就没有它了，不该给用户一条红色错误');
      expect(find.textContaining('没能从下载引擎里移除'), findsNothing);
      expect(env.s.tasks, isEmpty);
      expect(find.text('403 Forbidden'), findsNothing,
          reason: '用户报的后果是「这一条永远删不掉」—— 行必须真的没了');

      await settle(tester);
    });

    testWidgets('引擎没谈拢：行留着，提示仍是红色错误', (tester) async {
      env.a.removeError = SocketException('Connection refused',
          osError: const OSError('Connection refused', 122),
          address: InternetAddress('127.0.0.1'),
          port: 6800);
      await render(tester);

      await tapRemove(tester);

      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
      expect(find.text('引擎里已经没有它了，已从列表移除'), findsNothing);
      expect(env.s.tasks, hasLength(1),
          reason: '这一档退回修掉的缺陷，绝不能跟着删');

      await settle(tester);
    });

    testWidgets('正常移除：什么都不弹', (tester) async {
      env.a.removeError = null;
      await render(tester);

      await tapRemove(tester);

      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
      expect(env.s.tasks, isEmpty);

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

/// 假传输层：只换掉「进程 + RPC」，remove 的结局由测试给。
class _FakeAria2 extends Aria2 {
  _FakeAria2({required this.removeError});

  /// 非 null = `aria2.remove` 抛这个异常。
  Object? removeError;
  final String gid = 'e9b5ca82854c8163';

  int removeCalls = 0;
  final removedGids = <String>[];

  @override
  Future<void> bootstrap() async {}

  @override
  Future<String> addUri(
    String url, {
    required String dir,
    required String out,
    Map<String, String>? options,
  }) async =>
      gid;

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
