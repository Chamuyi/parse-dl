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

/// 「错误列表里那条其实**已经下载好了**，点重试又下一个一模一样的，
/// 目录里落出一串 `xxx.1.jpg`」—— 2026-10-05 用户真机报的。
///
/// 根因：入队路径有 `sameFileSkip`（投之前查一次目标文件在不在），
/// 但**手动重试路径以前没有** —— `retryTask` 直接 `_submit`，
/// 等于绕过了用户自己在设置里勾的那个开关。aria2 拿到一个磁盘上已存在的
/// `out` 时不会覆盖，而是改名 `xxx.1.jpg` 再下一份，于是重复文件成串出现。
///
/// 现在重试前先看磁盘：
///   * 文件在、且**没有** `<文件名>.aria2` 控制文件（= 不是半成品）
///     → 不投引擎，把这条如实标成「已完成」，结局 [EnqueueOutcome.skippedExisting]；
///   * 有 `.aria2`（aria2 没下完留下的）→ 照常重下，绝不能当成已完成放过去；
///   * `sameFileSkip` 关着 → 照常重下，尊重用户「已存在也要重下」的选择。
///
/// **负控制**（改坏代码时必须变红，别把用例当成永真）：
///   * 把 `retryTask` 里那段磁盘检查删掉 → group「文件已在磁盘上」三条全红；
///   * 把 `.aria2` 那半个条件去掉（半成品也算已下载）→ 「半成品照常重下」红；
///   * 把 `dl.sameFileSkip` 那半个条件去掉（无视用户开关）→ 「开关关着仍重下」红。
void main() {
  late Directory tmp;
  late Directory dlDir;
  var seq = 0;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jxxzq_retry_exist_');
    dlDir = Directory('${tmp.path}/dl')..createSync(recursive: true);
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 每条任务用唯一 media id：`addPending` 的 localId 带微秒时间戳，
  /// 假传输层零耗时会撞进同一微秒互相覆盖。
  Media media() {
    final id = 'exist${seq++}';
    return Media(
      id: id,
      type: MediaType.image,
      url: 'https://cdn.example.invalid/$id.jpg',
      source: 'x',
    );
  }

  /// 起一个已绑定的协调器并真的入队一次（任务因此有 gid），随后标成失败。
  Future<({Aria2Coordinator c, DownloadStore s, _FakeAria2 a, String localId})>
      errored({bool sameFileSkip = true}) async {
    final settings = SettingsStore();
    if (!sameFileSkip) {
      settings.setDownload((d) => d.sameFileSkip = false);
      await settings.save();
    }
    final aria = _FakeAria2();
    final c = Aria2Coordinator.withAria2(aria);
    final s = DownloadStore()..setSaveDir(dlDir.path);
    await c.bootstrap(store: s, settings: settings);
    final r = await c.enqueueMedia(media());
    expect(r.outcome, EnqueueOutcome.queued, reason: '前置条件：任务真的进了队列');
    s.markErrorByGid(aria.gid, '服务器返回空内容（0 字节）');
    return (c: c, s: s, a: aria, localId: r.localId!);
  }

  /// 在磁盘上放一份「已经下好的」同名文件（文件名取自任务本身）。
  File plant(DownloadStore s, String localId, {int bytes = 1234}) {
    final name = s.task(localId)!.fileName;
    final f = File('${dlDir.path}/$name')..writeAsBytesSync(List.filled(bytes, 0x41));
    return f;
  }

  group('文件已在磁盘上：重试不再下一次（A）', () {
    test('不投引擎、行变已完成、结局是 skippedExisting', () async {
      final e = await errored();
      final f = plant(e.s, e.localId, bytes: 4321);
      final addsBefore = e.a.addCount; // 入队时投过一次

      final r = await e.c.retryTask(e.localId);

      expect(r.outcome, EnqueueOutcome.skippedExisting);
      expect(r.localId, e.localId);
      expect(e.a.addCount, addsBefore, reason: '一个字节都不该再投');
      expect(e.a.removeCalls, 0, reason: '既然不重下，连引擎都不用问');
      final t = e.s.task(e.localId)!;
      expect(t.status, DownloadStatus.complete,
          reason: '文件真的在磁盘上，标完成比留在「错误」里诚实');
      expect(t.totalBytes, 4321, reason: '大小按磁盘实际值填，不是猜的');
      expect(t.errorMessage, isNull, reason: '别再挂着那条旧错误文案');
      expect(f.existsSync(), isTrue, reason: '原文件一个字节没动');
      expect(dlDir.listSync().where((x) => x is File && !x.path.endsWith('.aria2')),
          hasLength(1), reason: '没有多出 xxx.1.jpg');

      await e.c.dispose();
    });

    test('有 .aria2 控制文件＝半成品，必须照常重下', () async {
      final e = await errored();
      plant(e.s, e.localId);
      final name = e.s.task(e.localId)!.fileName;
      File('${dlDir.path}/$name.aria2').writeAsBytesSync([0]);
      final addsBefore = e.a.addCount;

      final r = await e.c.retryTask(e.localId);

      expect(r.outcome, EnqueueOutcome.queued);
      expect(e.a.addCount, addsBefore + 1, reason: '半成品要重下，不能当已完成');
      // 重试的正常流程是「旧行换成新行」，所以按旧 localId 查应当已经没了
      expect(e.s.task(e.localId), isNull);
      expect(e.s.tasks.single.status, isNot(DownloadStatus.complete));

      await e.c.dispose();
    });

    test('sameFileSkip 关着 → 用户要的就是重下，照旧投', () async {
      final e = await errored(sameFileSkip: false);
      plant(e.s, e.localId);
      final addsBefore = e.a.addCount;

      final r = await e.c.retryTask(e.localId);

      expect(r.outcome, EnqueueOutcome.queued);
      expect(e.a.addCount, addsBefore + 1);

      await e.c.dispose();
    });

    test('磁盘上没有这个文件 → 正常重试路径不受影响', () async {
      final e = await errored();
      final addsBefore = e.a.addCount;

      final r = await e.c.retryTask(e.localId);

      expect(r.outcome, EnqueueOutcome.queued);
      expect(e.a.addCount, addsBefore + 1);
      expect(e.s.tasks, hasLength(1), reason: '旧行删掉、新行一条，不翻倍');

      await e.c.dispose();
    });
  });

  group('用户看到的提示（点真实界面）', () {
    late AppState appState;
    late SettingsStore settings;
    late HomepageStore homepage;
    late DouyinStore douyin;
    late DouyinAutoStore douyinAuto;
    late CreationTaskStore creationTasks;
    late AutoTaskStore autoTasks;
    late Aria2Coordinator c;
    late DownloadStore s;
    late _FakeAria2 a;

    setUp(() async {
      AppPrefs.setMockInitialValues({});
      await AppPaths.init(
          exeDirOverride: tmp, fallbackOverride: tmp);
      settings = SettingsStore();
      appState = await AppState.restore();
      douyin = DouyinStore();
      homepage = HomepageStore(appState);
      douyinAuto = DouyinAutoStore();

      // 装配要在这里做完：testWidgets 跑在假时钟里，await 真实 I/O 会挂死。
      final e = await errored();
      plant(e.s, e.localId);
      await e.c.dispose(); // 停掉 1 秒轮询，store 绑定保留
      c = e.c;
      s = e.s;
      a = e.a;
      creationTasks = CreationTaskStore(appState: appState, coordinator: c);
      autoTasks = AutoTaskStore(
        appState: appState,
        homepageStore: homepage,
        creationTasks: creationTasks,
      );
      Aria2Coordinator.instanceForTest = c;
    });

    tearDown(() => Aria2Coordinator.instanceForTest = null);

    testWidgets('重试已下好的那条 → 提示「没有重复下载」，错误 Tab 清空',
        (tester) async {
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
            ChangeNotifierProvider<DownloadStore>.value(value: s),
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
      await tester.pumpAndSettle();
      // 默认停在「下载中」，错误行要切到「错误」Tab 才在界面上
      s.setCurrentTab('错误');
      await tester.pump();

      expect(find.text('服务器返回空内容（0 字节）'), findsOneWidget,
          reason: '前置条件：那条错误行在界面上');
      final addsBefore = a.addCount;

      // 重试这条路径现在要查磁盘（真实文件 I/O），而 testWidgets 的 body 跑在
      // 假时钟里 —— 不放进 runAsync 就永远等不到，表现成"点了没反应"。
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('重试'));
        await Future.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });

      expect(find.text('文件已经在磁盘上，没有重复下载'), findsOneWidget,
          reason: '提示要说清"没再下一次"，而不是含糊的"重试失败"');
      expect(s.tasks.single.status, DownloadStatus.complete);
      expect(a.addCount, addsBefore, reason: '点这一下没让引擎多收一个任务');
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing,
          reason: '不再是出错那一行');
    });
  });
}

/// 假传输层：只数调用次数，不启动真实 aria2c。
class _FakeAria2 extends Aria2 {
  final String gid = 'a1b2c3d4e5f60718';
  int addCount = 0;
  int removeCalls = 0;

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
  }

  @override
  Future<AriaTask> tellStatus(String gid) async => AriaTask(
        gid: gid,
        status: AriaStatus.error,
        completeSize: 0,
        totalSize: 0,
        fileName: 'x.jpg',
        dir: r'C:\tmp',
        error: 'resource not found',
      );

  @override
  Future<bool> shutdown({Duration timeout = const Duration(seconds: 2)}) async => true;

  @override
  Future<void> applyGlobalOptions(Map<String, String> options) async {}
}
