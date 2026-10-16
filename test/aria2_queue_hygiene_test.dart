import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/app_logger.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/aria2.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/download_list_item.dart';

/// 下载队列的三处缺陷（2026-10-16，用户裁定「都修复」）：
///
///   ① 摘僵尸用错 API。`_dropOrphanGid` 只调 `aria2.remove`，而它**只作用于
///      还在队列里**的 gid；死任务此刻多半已经停下，一律回
///      `Active Download not found for GID#…`。结果是「检测到了、永远摘不掉」，
///      同一个 gid 每开机一次就被 `--save-session` 写回 `aria2.session`。
///   ①b 清理入口不全。僵尸只在 error 事件里被摘，而 `--input-file` 读回的
///      死任务**先落在 waiting** —— 那批永远走不到 error，白占并发槽。
///   ①c 清理入口还漏了 `active`（2026-10-16 二次取证）。同一批会话残留里，
///      握手挂住的那条直接进 **active**：真机取样 `totalLength=0`、
///      `downloadSpeed=0`、`connections=1`，47 秒后 `tellStatus` 仍是 `active`，
///      `tellWaiting` / `tellStopped` 两条都返回空表 —— 于是开机清理一行日志都
///      打不出来，它却在退出时被 `--save-session` 原样写回，每次开机复活一次。
///      并发数为 1 时它独占唯一那个槽，整个队列就此堵死。
///      另外 `tellActive` 的签名与另两条**不同**（只有 `keys`，没有 offset / num），
///      照抄三参数会被 aria2 回 `The parameter at 0 has wrong type.`，
///      而扫描源只是**静默**变空表。
///   ①d 一轮扫描仍会从缝里漏（2026-10-16 三次取证）。并发槽一空出来，引擎立刻
///      把 `waiting` 里的下一条提升进 `active`（真机日志里 `开始下载 gid=…`
///      就夹在清理行之间），等轮到扫 waiting 时那几条已经不在了 —— 实测第一轮
///      摘 5 条、漏掉 4 条。所以反复扫到「本轮没有没见过的新 gid」为止。
///      另外**退出那次落盘靠不住**：`shutdown` 只给 aria2 2 秒，超了就 `kill()`，
///      `--save-session` 的退出保存跟着一起丢（真机证据：关窗后 `aria2.session`
///      的 mtime 停在注入那一刻）。摘完必须自己 `saveSession` 落一次盘。
///   ② 重投前「移除旧的」失败被 `catch (_) {}` 吞掉：无日志、无补救，
///      旧 gid 留在会话里，是「33 个文件放大成 261 个任务」的放大器。
///   ③ `DownloadStatus.waiting` 在全 `lib/` 里**没有任何赋值点**，引擎里几百条
///      `waiting` 全被走成 `active`，界面只剩「下载中 0%」一种样子。
///
/// **负控制**（改坏对应实现时下面必须变红，别把这些用例当成恒真）：
///   * ① 把 `_dropOrphanGid` 退回只 `await _aria.remove(gid)` →
///     「已停下的 gid … 结果条目仍被清掉」红（`resultRemoved` 永远是空的）；
///   * ①b 去掉 `bootstrap` 末尾的 `_purgeOrphanSessionTasks()` →
///     「排队中的会话残留被摘掉」红；
///   * ①c 把 `('aria2 活跃任务', _aria.tellActiveGids)` 从扫描源里删掉 →
///     「正在下载里的会话残留也要摘」「活跃僵尸走 remove 那一手」红；
///   * ①c 把 `tellActiveGids` 改成 `_tellGids('aria2.tellActive', 1000)` →
///     「扫活跃任务用的是 tellActive(keys)」红；
///   * ①d 把多轮扫描退回单轮（去掉 `round` 那层循环）→
///     「批次之间被提升进 active 的残留也要摘掉」红；
///   * ①d 去掉 `_saveSessionAfterPurge()` 那次落盘 →
///     「摘完立刻把会话落盘」红；
///   * ② 把 `_resubmitAfterBackoff` 里那段换回 `catch (_) {}` →
///     「remove 报 Active Download not found」红（日志缺失、兜底未发）；
///   * ③ 把 `case AriaStatus.waiting` 合回 active 分支、或删掉
///     `DownloadStore.markWaiting` → ③ 整组红（状态停在 active、位次恒 null）。
void main() {
  /// aria2 对「已不在活跃队列」的 gid 调 remove 的真机原文（本机 aria2c 1.37.0）。
  const kActiveNotFoundRaw = 'Active Download not found for GID#e9b5ca82854c8163';
  const kActiveNotFoundFault = 'aria2 调用 aria2.remove 失败：$kActiveNotFoundRaw';

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jxxzq_queue_hygiene_');
    await AppPaths.init(exeDirOverride: tmp, fallbackOverride: tmp);
    await AppLogger.init(enabled: true);
  });
  tearDown(() async {
    await AppLogger.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<String> logText() async {
    await AppLogger.flushForTest();
    return File(await AppLogger.currentFilePath()).readAsString();
  }

  Future<({Aria2Coordinator c, DownloadStore s, _FakeAria2 a})> boot(
    _FakeAria2 aria,
  ) async {
    final c = Aria2Coordinator.withAria2(aria);
    final s = DownloadStore()..setSaveDir(tmp.path);
    await c.bootstrap(store: s, settings: SettingsStore());
    return (c: c, s: s, a: aria);
  }

  group('① 摘僵尸必须按状态分两手：remove → removeDownloadResult', () {
    test('已停下的 gid：remove 报 Active Download not found，结果条目仍被清掉', () async {
      final aria = _FakeAria2()..removeError = StateError(kActiveNotFoundFault);
      final env = await boot(aria);

      aria.emitError('deadgid0001');
      await aria.settle();

      expect(aria.removeCalls, contains('deadgid0001'),
          reason: '第一手还是要真的问过一次 aria2.remove');
      expect(aria.resultRemoved, contains('deadgid0001'),
          reason: '已停下的 gid 只有 removeDownloadResult 摘得掉；'
              '退回「只调 remove」它就会永远留在 aria2.session 里');
      expect(await logText(), isNot(contains('没能摘掉')),
          reason: '第二手成功就不该报「摘不掉」');

      await env.c.dispose();
    });

    test('还在队列里的僵尸只走第一手，不去动结果条目', () async {
      final aria = _FakeAria2();
      final env = await boot(aria);

      aria.emitError('queuedgid01');
      await aria.settle();

      expect(aria.removeCalls, contains('queuedgid01'));
      expect(aria.resultRemoved, isEmpty,
          reason: 'remove 成功就不该再多发一次无谓的 RPC');

      await env.c.dispose();
    });

    test('两条手都失败才记「没能摘掉」，且把手都写出来', () async {
      final aria = _FakeAria2()
        ..removeError = StateError(kActiveNotFoundFault)
        ..removeResultError =
            StateError('aria2 调用 aria2.removeDownloadResult 失败：'
                'Could not remove download result of GID#deadgid0001');
      final env = await boot(aria);

      aria.emitError('deadgid0001');
      await aria.settle();

      final log = await logText();
      expect(log, contains('没能摘掉'), reason: '真摘不掉时必须留下原因，不能假装成功');
      expect(log, contains('removeDownloadResult='),
          reason: '两条手分别失败在哪，排查时要能一眼看到');

      await env.c.dispose();
    });
  });

  group('①b 开机清理：会话里读回、本地任务表里没有的任务', () {
    test('排队中的会话残留被摘掉，本地表里有的那条不许动', () async {
      final aria = _FakeAria2()
        ..waitingGids = ['keep-gid', 'orphan-waiting'];
      final c = Aria2Coordinator.withAria2(aria);
      final s = DownloadStore()..setSaveDir(tmp.path);
      // 本地表里真的有这条（用户看得见），它必须原样留着。
      final keepId = s.addPending(_media(), tmp.path, fileName: 'keep.jpg');
      s.markActive(keepId, 'keep-gid');

      await c.bootstrap(store: s, settings: SettingsStore());

      expect(aria.removeCalls, contains('orphan-waiting'),
          reason: 'waiting 的僵尸永远走不到 error 事件那条路，只能开机主动扫');
      expect(aria.removeCalls, isNot(contains('keep-gid')));
      expect(aria.resultRemoved, isNot(contains('keep-gid')));
      expect(s.task(keepId)!.aria2Gid, 'keep-gid', reason: '本地行不许被清掉');

      await c.dispose();
    });

    test('已停任务里的会话残留同样被扫到（它们不会再发任何事件）', () async {
      final aria = _FakeAria2()
        ..stoppedGids = ['stale-complete-1']
        ..removeError = StateError(kActiveNotFoundFault);
      final env = await boot(aria);

      expect(env.a.resultRemoved, contains('stale-complete-1'),
          reason: '已停下的条目只能靠 removeDownloadResult 清');

      await env.c.dispose();
    });

    test('正在下载里的会话残留也要摘：它不发 error，只会白占并发槽', () async {
      final aria = _FakeAria2()..activeGids = ['orphan-active'];
      final env = await boot(aria);

      expect(env.a.removeCalls, contains('orphan-active'),
          reason: '握手挂住的死任务不进 waiting / stopped、也不发 error'
              '（真机 47 秒后仍是 active）—— 不扫 tellActive 就永远摘不掉，'
              '它只会在退出时被 --save-session 原样写回，每次开机复活一次');

      await env.c.dispose();
    });

    test('活跃僵尸走 remove 那一手，不去动结果条目', () async {
      final aria = _FakeAria2()..activeGids = ['orphan-active'];
      final env = await boot(aria);

      expect(env.a.removeCalls, contains('orphan-active'));
      expect(env.a.resultRemoved, isNot(contains('orphan-active')),
          reason: '它还在队列里，只有 remove 认得；removeDownloadResult '
              '对队列里的 gid 只会回 Could not remove download result');

      await env.c.dispose();
    });

    test('本地表里正在下载的那条不许误伤（active 里最常见的就是它）', () async {
      final aria = _FakeAria2()..activeGids = ['live-gid'];
      final c = Aria2Coordinator.withAria2(aria);
      final s = DownloadStore()..setSaveDir(tmp.path);
      final liveId = s.addPending(_media(), tmp.path, fileName: 'live.jpg');
      s.markActive(liveId, 'live-gid');
      s.markDownloading(liveId);

      await c.bootstrap(store: s, settings: SettingsStore());

      expect(aria.removeCalls, isNot(contains('live-gid')),
          reason: 'tellActive 里绝大多数是正常下载中的任务，'
              '判据只能取「本地任务表里没有它」');
      expect(s.task(liveId)!.aria2Gid, 'live-gid');

      await c.dispose();
    });

    test('扫活跃任务用的是 tellActive(keys)：它没有 offset / num', () async {
      final aria = _RecordingAria2()..response = [{'gid': 'a1'}, {'gid': 'b2'}];

      expect(await aria.tellActiveGids(), ['a1', 'b2']);
      expect(aria.calls.single.method, 'aria2.tellActive');
      expect(aria.calls.single.args, [['gid']],
          reason: '照 tellWaiting / tellStopped 的 [0, max, [gid]] 传过去，'
              'aria2 会回 The parameter at 0 has wrong type —— 扫描源静默变空表，'
              '日志里连一行异常都没有');
    });

    test('引擎响应畸形时只跳过坏条目，不整批放弃、也不凭空塞 null', () async {
      final aria = _RecordingAria2()
        ..response = [
          {'gid': 'ok'},
          {'status': 'active'},
          {'gid': null},
          'junk',
        ];

      expect(await aria.tellActiveGids(), ['ok']);
    });

    test('批次之间被提升进 active 的残留也要摘掉（单轮必漏）', () async {
      final aria = _FakeAria2()
        // 第 1 轮 active 只有 A；摘掉 A 的那一瞬间，引擎把 W 从 waiting
        // 提升进了 active（真机日志里 `开始下载 gid=…` 就夹在清理行之间），
        // 于是这一轮再扫 waiting 时 W 已经不在那里了。
        ..activeGidsByRound = [
          ['orphan-a'],
          ['orphan-w'],
          [],
        ];
      final env = await boot(aria);

      expect(env.a.removeCalls, contains('orphan-a'));
      expect(env.a.removeCalls, contains('orphan-w'),
          reason: '只扫一轮时 W 从两张列表的缝里漏过去，它下次开机再复活一次');

      await env.c.dispose();
    });

    test('摘完立刻把会话落盘：退出那一次保存靠不住', () async {
      final aria = _FakeAria2()..activeGids = ['orphan-active'];
      final env = await boot(aria);

      expect(env.a.saveSessionCalls, greaterThan(0),
          reason: '关窗只给 aria2 2 秒（超了就 kill），--save-session 的退出保存'
              '会一起丢 —— 真机实测关窗后会话文件 mtime 停在注入那一刻，'
              '摘掉的结果一个都没落盘，下次开机原样读回来');

      await env.c.dispose();
    });

    test('没有摘到东西就不写盘（正常开机不该白刷一次会话文件）', () async {
      final env = await boot(_FakeAria2());

      expect(env.a.saveSessionCalls, 0);

      await env.c.dispose();
    });

    test('落盘失败只记日志，不拖垮启动', () async {
      final aria = _FakeAria2()
        ..activeGids = ['orphan-active']
        ..saveSessionError = StateError('aria2 尚未就绪');
      final env = await boot(aria);

      expect(env.a.removeCalls, contains('orphan-active'));
      expect(await logText(), contains('开机清理：会话落盘失败'));

      await env.c.dispose();
    });

    test('读队列失败不拖垮启动（只记日志）', () async {
      final aria = _FakeAria2()..waitingListError = StateError('aria2 尚未就绪');
      final env = await boot(aria);

      expect(env.s.tasks, isEmpty);
      expect(await logText(), contains('开机清理：读 aria2 等待队列 失败'));

      await env.c.dispose();
    });
  });

  group('② 重投前「移除旧的」失败必须留痕并兜底', () {
    test('remove 报 Active Download not found → 失败要留下日志，不能静默吞掉', () async {
      final aria = _FakeAria2()..removeError = StateError(kActiveNotFoundFault);
      final env = await boot(aria);
      env.c.backoffFor = (used) => Duration.zero;

      final r = await env.c.enqueueMedia(_media(candidates: 3));
      expect(r.outcome, EnqueueOutcome.queued);
      // 这条任务在引擎里失败了 —— 失败重投那条路才会去掉「旧的」。
      aria.emitError('gid-1');
      await aria.settle();

      final log = await logText();
      expect(log, contains('重投前移除旧任务失败'),
          reason: '退回 catch (_) {} 时这行日志不存在 —— 失败就是完全静默的');
      expect(aria.added.length, greaterThan(1),
          reason: '兜底之后仍然要重新提交，不能把重试也一起吞掉');

      await env.c.dispose();
    });

    test('remove 失败要补兜底：forceRemove + 对已停下才有效的 removeDownloadResult',
        () async {
      final aria = _FakeAria2()..removeError = StateError(kActiveNotFoundFault);
      final env = await boot(aria);
      env.c.backoffFor = (used) => Duration.zero;

      final r = await env.c.enqueueMedia(_media(candidates: 3));
      expect(r.outcome, EnqueueOutcome.queued);
      aria.emitError('gid-1');
      await aria.settle();

      expect(aria.forceRemoved, isNotEmpty,
          reason: '② 要求补的 forceRemove 兜底没发出去');
      expect(aria.resultRemoved, isNotEmpty,
          reason: '重投的场景就是「这条刚失败」，它此刻多半已停下，'
              '光有 forceRemove 还是摘不掉旧 gid');

      await env.c.dispose();
    });

    test('remove 正常时不多发任何兜底 RPC', () async {
      final aria = _FakeAria2();
      final env = await boot(aria);
      env.c.backoffFor = (used) => Duration.zero;

      await env.c.enqueueMedia(_media(candidates: 3));
      aria.emitError('gid-1');
      await aria.settle();

      expect(aria.forceRemoved, isEmpty);
      expect(aria.resultRemoved, isEmpty);

      await env.c.dispose();
    });
  });

  group('③ 排队中与下载中必须分开，且排队要说清排在哪', () {
    test('轮询：引擎说 waiting → 本地是 waiting 并带上位次', () async {
      final aria = _FakeAria2();
      final env = await boot(aria);
      final r = await env.c.enqueueMedia(_media());
      expect(env.s.task(r.localId!)!.status, DownloadStatus.active,
          reason: '前置条件：入队后先按「下载中」记着');

      // 引擎那边这条其实还在排队（并发槽被别的任务占着）。
      aria
        ..batchStatus = AriaStatus.waiting
        ..waitingGids = ['gid-1'];
      // 轮询是 bootstrap 里的 Timer.periodic(1s)，真实计时器等它跑一轮。
      await Future<void>.delayed(const Duration(milliseconds: 1600));

      final t = env.s.task(r.localId!)!;
      expect(t.status, DownloadStatus.waiting,
          reason: '合回 active 分支时这里恒为 active —— 界面就是「下载中 0%」');
      expect(t.queueAhead, 0, reason: 'tellWaiting 里它排第 0 位');

      await env.c.dispose();
    });

    test('重启对账：aria2 说还在排队 → waiting，而不是「下载中 0%」', () async {
      final aria = _FakeAria2();
      final env = await boot(aria);
      final id = env.s.addPending(_media(), tmp.path, fileName: 'a.jpg');
      env.s.markActive(id, 'gid-w');
      aria.statusByGid['gid-w'] = _task('gid-w', AriaStatus.waiting);

      await env.c.reconcile();

      expect(env.s.task(id)!.status, DownloadStatus.waiting);

      await env.c.dispose();
    });

    test('引擎把它从队列里取出来开始下 → 翻回「下载中」并清掉位次', () async {
      final aria = _FakeAria2();
      final env = await boot(aria);
      final id = env.s.addPending(_media(), tmp.path, fileName: 'a.jpg');
      env.s.markActive(id, 'gid-1');
      env.s.markWaiting('gid-1', aheadCount: 7);
      expect(env.s.task(id)!.status, DownloadStatus.waiting);

      aria.emitStart('gid-1');
      await aria.settle();

      final t = env.s.task(id)!;
      expect(t.status, DownloadStatus.active,
          reason: '只认 paused 的 markResumed 管不到这一档，界面会永远停在「队列中」');
      expect(t.queueAhead, isNull, reason: '已经不在队列里，位次必须清掉');

      await env.c.dispose();
    });

    test('markWaiting 幂等：位次没变就不重复通知', () async {
      final s = DownloadStore()..setSaveDir(tmp.path);
      final id = s.addPending(_media(), tmp.path, fileName: 'a.jpg');
      s.markActive(id, 'gid-1');

      var notified = 0;
      s.addListener(() => notified++);
      s.markWaiting('gid-1', aheadCount: 3);
      final first = notified;
      s.markWaiting('gid-1', aheadCount: 3);
      expect(notified, first, reason: '每秒轮询一次，位次没变还重建整张表就是白写盘');
      s.markWaiting('gid-1', aheadCount: 2);
      expect(notified, first + 1, reason: '位次真的变了必须反映到界面');
    });

    testWidgets('列表行把「队列中」写具体：前面还有 N 条', (tester) async {
      final s = DownloadStore()..setSaveDir(tmp.path);
      final id = s.addPending(_media(), tmp.path, fileName: 'a.jpg');
      s.markActive(id, 'gid-1');
      s.markWaiting('gid-1', aheadCount: 2);

      await tester.pumpWidget(_host(DownloadListItem(task: s.task(id)!)));

      expect(find.text('队列中 · 前面还有 2 条'), findsOneWidget,
          reason: '只写「队列中」时，前面还有 180 条与下一个就轮到它长得一样');
      expect(find.textContaining('前面还有 2 条'), findsWidgets);

      // 落盘有 2 秒去抖，跑过去再收尾，否则报「A Timer is still pending」
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('位次拿不到时退回只写「队列中」，不显示 null', (tester) async {
      final s = DownloadStore()..setSaveDir(tmp.path);
      final id = s.addPending(_media(), tmp.path, fileName: 'a.jpg');
      s.markActive(id, 'gid-1');
      s.markWaiting('gid-1');

      await tester.pumpWidget(_host(DownloadListItem(task: s.task(id)!)));

      expect(find.text('队列中'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);

      // 同上：等过落盘的 2 秒去抖
      await tester.pump(const Duration(seconds: 3));
    });
  });
}

Media _media({int candidates = 1}) => Media(
      id: 'm1',
      type: MediaType.image,
      url: 'https://cdn.example.com/m1.jpg',
      altUrls: [
        for (var i = 1; i < candidates; i++) 'https://cdn.example.com/m1.jpg#$i'
      ],
    );

AriaTask _task(String gid, AriaStatus status) => AriaTask(
      gid: gid,
      status: status,
      completeSize: 0,
      totalSize: 100,
      fileName: 'm1.jpg',
      dir: r'C:\tmp',
      error: '',
    );

/// DownloadListItem 读 AppTheme.colorsOf，必须包一层才能渲染。
Widget _host(Widget child) => AppTheme(
      colors: AppColors.dark,
      brightness: Brightness.dark,
      child: MaterialApp(home: Scaffold(body: child)),
    );

/// 假传输层：不启 aria2c。每一条 RPC 的返回/报错都由用例给，用来把
/// 「摘不掉」「吞异常」「waiting 被当成 active」这三种坏法分别钉住。
class _FakeAria2 extends Aria2 {
  final _errors = StreamController<String>.broadcast();
  final _starts = StreamController<String>.broadcast();

  /// 非 null = 对应那一手抛这个异常。
  Object? removeError;
  Object? forceRemoveError;
  Object? removeResultError;

  /// 非 null = `tellWaitingGids` 抛这个异常。
  Object? waitingListError;

  /// `tellActive` / `tellWaiting` / `tellStopped` 的返回值（按顺序）。
  List<String> activeGids = const [];
  List<String> waitingGids = const [];
  List<String> stoppedGids = const [];

  /// 非 null 时 `tellActiveGids` 按调用次序逐轮返回（超出则重复最后一项）——
  /// 用来模拟「引擎在两次扫描之间把 waiting 里的任务提升进 active」。
  List<List<String>>? activeGidsByRound;
  int _activeCalls = 0;

  /// 非 null = `saveSession` 抛这个异常；[saveSessionCalls] 计调用次数。
  Object? saveSessionError;
  int saveSessionCalls = 0;

  /// 批量查询里所有任务的状态。
  AriaStatus batchStatus = AriaStatus.active;

  /// 单条查询（reconcile 用）的返回值。
  final Map<String, AriaTask> statusByGid = {};

  final List<String> removeCalls = [];
  final List<String> forceRemoved = [];
  final List<String> resultRemoved = [];
  final List<String> added = [];

  @override
  Future<void> bootstrap() async {}

  @override
  Stream<String> get onDownloadError => _errors.stream;

  @override
  Stream<String> get onDownloadStart => _starts.stream;

  @override
  Future<void> updateConcurrency(int value) async {}

  @override
  Future<String> addUri(
    String url, {
    required String dir,
    required String out,
    Map<String, String>? options,
  }) async {
    added.add(url);
    return 'gid-${added.length}';
  }

  @override
  Future<void> remove(String gid) async {
    removeCalls.add(gid);
    final e = removeError;
    if (e != null) throw e;
  }

  @override
  Future<void> forceRemove(String gid) async {
    final e = forceRemoveError;
    if (e != null) throw e;
    forceRemoved.add(gid);
  }

  @override
  Future<void> removeDownloadResult(String gid) async {
    final e = removeResultError;
    if (e != null) throw e;
    resultRemoved.add(gid);
  }

  @override
  Future<List<String>> tellActiveGids() async {
    final rounds = activeGidsByRound;
    if (rounds == null || rounds.isEmpty) return activeGids;
    final i = _activeCalls < rounds.length ? _activeCalls : rounds.length - 1;
    _activeCalls++;
    return rounds[i];
  }

  @override
  Future<void> saveSession() async {
    saveSessionCalls++;
    final e = saveSessionError;
    if (e != null) throw e;
  }

  @override
  Future<List<String>> tellWaitingGids({int max = 1000}) async {
    final e = waitingListError;
    if (e != null) throw e;
    return waitingGids;
  }

  @override
  Future<List<String>> tellStoppedGids({int max = 1000}) async => stoppedGids;

  @override
  Future<AriaTask> tellStatus(String gid) async {
    final t = statusByGid[gid];
    if (t == null) {
      throw StateError('aria2 调用 aria2.tellStatus 失败：GID $gid is not found');
    }
    return t;
  }

  @override
  Future<Map<String, AriaTask>> tellStatusBatch(List<String> gids) async => {
        for (final g in gids) g: _task(g, batchStatus),
      };

  void emitError(String gid) => _errors.add(gid);

  void emitStart(String gid) => _starts.add(gid);

  /// 等事件循环把「失败 → 退避 → 重投」这一串跑干净。
  Future<void> settle() async {
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

/// 只记录 RPC 调用形状的假客户端 —— 用来钉住 `tellActive` 的参数签名。
///
/// 它**只有 keys 一个参数**，与 `tellWaiting` / `tellStopped` 的
/// `(offset, num, keys)` 三参数不同；照那两条的写法传过去，aria2 会回
/// `The parameter at 0 has wrong type.`，而扫描源会**静默**变成空表 ——
/// 僵尸照旧每次复活，日志里连一行异常都看不到。`_FakeAria2` 直接 override 了
/// 结果，钉不住这层，所以这里必须量到 RPC 参数本身。
class _RecordingAria2 extends Aria2 {
  final List<({String method, List<dynamic> args})> calls = [];

  /// `invoke` 的返回值（模拟 aria2 的 `result` 字段）。
  dynamic response;

  @override
  Future<dynamic> invoke(String method, [List<dynamic> args = const []]) async {
    calls.add((method: method, args: args));
    return response;
  }
}
