import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/aria2.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/download_list_item.dart';

/// 「暂停 → 继续」这个来回的回归测试。
///
/// 2026-09-24 用户报「X 下载点暂停后无法继续」。实测 aria2 本身的语义是好的
/// （`tool/aria2_pause_probe.py`：同进程内 unpause 能续上，跨重启也能，
/// `--save-session` 会存 paused 任务），坏在我们自己的状态层：
///
///   本地状态**只有入队时的 `markActive` 会设成 active**，`onDownloadStart`
///   只写日志，进度轮询又只问 `activeGids()`。于是 `unpause` 成功、aria2 已经
///   在正常下载了，界面还永远停在「已暂停」且进度不再走 —— 用户看到的就是
///   "点了继续没反应"。这条链此前没有任何测试覆盖。
class _FakeAria2 extends Aria2 {
  final paused = <String>[];
  final unpaused = <String>[];
  bool failUnpause = false;

  /// pause 是否抛错（模拟 aria2 的 `cannot be paused now`）
  bool failPause = false;

  /// 「pause 失败之后再去问 aria2，它那边其实是什么状态」
  AriaStatus remoteStatus = AriaStatus.paused;

  /// true 时 tellStatus 直接抛错 = aria2 已经不认这个 gid
  bool unknownOnTell = false;

  @override
  Future<void> bootstrap() async {}

  @override
  Future<String> addUri(String url,
      {required String dir,
      required String out,
      Map<String, String>? options}) async {
    return 'gid-1';
  }

  @override
  Future<void> pause(String gid) async {
    if (failPause) throw Exception('GID#$gid cannot be paused now');
    paused.add(gid);
  }

  @override
  Future<void> unpause(String gid) async {
    if (failUnpause) throw Exception('GID#$gid cannot be unpaused now');
    unpaused.add(gid);
  }

  @override
  Future<AriaTask> tellStatus(String gid) async {
    if (unknownOnTell) throw Exception('GID#$gid is not found');
    return AriaTask(
      gid: gid,
      status: remoteStatus,
      completeSize: 0,
      totalSize: 0,
      fileName: 'm1.jpg',
      dir: dirOf,
      error: '',
    );
  }

  /// coordinator 记日志时会读一下当前状态，给个不炸的默认值
  String dirOf = r'C:\tmp';

  /// 进度轮询（tellStatusBatch）返回的字节数
  int batchComplete = 0;
  int batchTotal = 0;

  @override
  Future<Map<String, AriaTask>> tellStatusBatch(List<String> gids) async => {
        for (final g in gids)
          g: AriaTask(
            gid: g,
            status: AriaStatus.active,
            completeSize: batchComplete,
            totalSize: batchTotal,
            fileName: 'm1.jpg',
            dir: dirOf,
            error: '',
          ),
      };

  @override
  Future<void> remove(String gid) async {}

  @override
  Future<void> applyGlobalOptions(Map<String, String> o) async {}
}

Media _m() => Media(
      id: 'm1',
      type: MediaType.image,
      url: 'https://cdn.example.com/m1.jpg',
      source: 'x',
    );

Widget _host(Widget child) => AppTheme(
      colors: AppColors.dark,
      brightness: Brightness.dark,
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pause_resume_');
  });
  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<(Aria2Coordinator, DownloadStore, String)> wired(
      {_FakeAria2? aria}) async {
    final a = aria ?? _FakeAria2();
    final c = Aria2Coordinator.withAria2(a);
    final store = DownloadStore()..setSaveDir(tmp.path);
    await c.bootstrap(store: store, settings: SettingsStore());
    final r = await c.enqueueMedia(_m());
    return (c, store, r.localId!);
  }

  group('暂停', () {
    test('pause 成功后本地状态立刻翻到已暂停 —— 不能只等 aria2 的事件', () async {
      // aria2 对「还在排队（waiting）」的任务执行 pause 时只把它摘出队列，
      // **既不发 onDownloadPause 也不发 onDownloadStop**。2026-10-06 真机：
      // 「全部暂停」停住 765 条排队任务后，本地仍有 766 条显示「下载中 0%」，
      // 而工具栏的「全部继续」要本地存在 paused 才渲染 → 队列看着就是卡死了。
      final aria = _FakeAria2();
      final (c, store, localId) = await wired(aria: aria);

      final err = await c.pause(localId);

      expect(aria.paused, ['gid-1'], reason: '必须真的通知 aria2，不能只改本地状态');
      expect(err, isNull);
      expect(store.task(localId)!.status, DownloadStatus.paused,
          reason: '这里没有任何事件回调参与，状态必须由 pause 自己写对');
      expect(store.activeGids(), isEmpty,
          reason: '进度轮询只问 activeGids，还留在里面就是「下载中」的假象');
    });

    test('aria2 拒了但它那边其实已经暂停 → 不报失败，状态收口', () async {
      // 「GID#… cannot be paused now」的第二种来源：它早就是 paused。
      // 报成失败会在界面上刷出一排红色「暂停失败」，而用户要的效果已经生效。
      final aria = _FakeAria2()
        ..failPause = true
        ..remoteStatus = AriaStatus.paused;
      final (c, store, localId) = await wired(aria: aria);

      final err = await c.pause(localId);

      expect(err, isNull, reason: '目标已达成就不该骗用户说失败');
      expect(store.task(localId)!.status, DownloadStatus.paused);
    });

    test('aria2 已经不再认这条 gid → 落到错误态，给出可用的「重试」', () async {
      final aria = _FakeAria2()
        ..failPause = true
        ..unknownOnTell = true;
      final (c, store, localId) = await wired(aria: aria);

      final err = await c.pause(localId);

      expect(err, isNull, reason: '行里的状态已经说清楚了，不必再弹一条重复的报错');
      expect(store.task(localId)!.status, DownloadStatus.error);
      expect(store.task(localId)!.errorMessage, contains('无法暂停'));
    });

    test('真的停不下来（aria2 那边还在 active）才返回失败文案，状态不许乱翻', () async {
      final aria = _FakeAria2()
        ..failPause = true
        ..remoteStatus = AriaStatus.active;
      final (c, store, localId) = await wired(aria: aria);

      final err = await c.pause(localId);

      expect(err, contains('暂停失败'));
      expect(store.task(localId)!.status, DownloadStatus.active,
          reason: '它其实还在下载，标成已暂停就是反向骗人');
    });

    test('已暂停的任务不在进度轮询名单里（这正是"进度不动"的来源）', () async {
      final (_, store, localId) = await wired();
      expect(store.activeGids(), hasLength(1));
      store.markPaused(localId);
      expect(store.activeGids(), isEmpty,
          reason: 'paused 被排除是合理的，所以恢复时必须把状态翻回来');
    });
  });

  group('继续', () {
    test('unpause 成功后本地状态翻回 active，进度轮询重新带上它', () async {
      final aria = _FakeAria2();
      final (c, store, localId) = await wired(aria: aria);
      store.markPaused(localId);

      await c.resume(localId);

      expect(aria.unpaused, ['gid-1']);
      expect(store.task(localId)!.status, DownloadStatus.active,
          reason: '不翻状态的话界面会一直停在「已暂停」，就是用户报的 bug');
      expect(store.activeGids(), ['gid-1'],
          reason: '进度轮询只问 activeGids，不在里面就永远不动');
    });

    test('aria2 不认这条任务时落到「错误」，给出可用的「重试」而不是死掉的「继续」',
        () async {
      final aria = _FakeAria2()..failUnpause = true;
      final (c, store, localId) = await wired(aria: aria);
      store.markPaused(localId);

      await c.resume(localId);

      expect(aria.unpaused, isEmpty);
      expect(store.task(localId)!.status, DownloadStatus.error,
          reason: '续不上却仍显示已暂停 = 用户只会反复点一颗没用的按钮');
      expect(store.task(localId)!.errorMessage, contains('无法继续'));
    });

    test('markResumed 只从「已暂停」翻，不会把完成/错误的任务复活', () async {
      final (_, store, localId) = await wired();
      store.markComplete('gid-1');
      store.markResumed(localId);
      expect(store.task(localId)!.status, DownloadStatus.complete);
    });
  });

  group('进度轮询', () {
    test('已下字节要一起写回，否则进度条在走、字数却停在 0 B', () async {
      // 2026-10-06 真机截图：暂停后再看，行上进度条约 50%，右边写「0 B / 32 MB」。
      // 原因是 updateProgress 只写 progress 与 totalBytes，界面那行字节读的是
      // downloadedBytes —— 没人写它。
      final aria = _FakeAria2()
        ..batchComplete = 16 * 1024 * 1024
        ..batchTotal = 32 * 1024 * 1024;
      final (_, store, localId) = await wired(aria: aria);
      expect(store.task(localId)!.downloadedBytes, isNot(16 * 1024 * 1024));

      // 轮询是 bootstrap 里的 Timer.periodic(1s)，真实计时器等它跑一轮
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      final t = store.task(localId)!;
      expect(t.totalBytes, 32 * 1024 * 1024);
      expect(t.progress, 500);
      expect(t.downloadedBytes, 16 * 1024 * 1024,
          reason: '条子和字节数必须同源，不然两个数字互相打脸');
    });
  });

  group('按钮跟着状态走', () {
    // 这一组刻意不碰 Aria2Coordinator：它带一个 `Timer.periodic` 的进度轮询，
    // 在 `testWidgets` 的假时钟里永远跑不完，测试会以 "did not complete" 收场
    // （实测卡了近 5 分钟）。协调器那条路径由上面两组非 widget 测试覆盖。
    DownloadStore storeWithTask() {
      final s = DownloadStore()..setSaveDir(tmp.path);
      s.addPending(_m(), tmp.path, fileName: 'm1.jpg');
      return s;
    }

    testWidgets('已暂停时给「继续」，状态翻回来就换回「暂停」', (tester) async {
      final store = storeWithTask();
      final t = store.tasks.single;

      // DownloadListItem 是 StatelessWidget：光 tester.pump() 不会重跑 build
      // （widget 实例没换），必须重新 pumpWidget 造一个新实例 —— 真实场景里
      // 是 store 通知后列表重建，等价于这一步。
      Future<void> render() =>
          tester.pumpWidget(_host(DownloadListItem(task: t)));

      store.markPaused(t.localId);
      await render();
      expect(find.byTooltip('继续'), findsOneWidget);
      expect(find.byTooltip('暂停'), findsNothing);

      store.markResumed(t.localId);
      await render();
      expect(find.byTooltip('暂停'), findsOneWidget,
          reason: '恢复后必须回到可暂停的样子，否则看着就像点了没反应');
      expect(find.byTooltip('继续'), findsNothing);

      // 落盘有 2 秒去抖，跑过去再收尾，否则报「A Timer is still pending」
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
