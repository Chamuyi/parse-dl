import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/app_logger.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/aria2.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/settings_store.dart';

/// 失败重试的**退避与上限**。
///
/// 装机版 2026-10-02 开机后 3 分 17 秒写了 12,396 行日志，取证时看清了两件事：
///   - `aria2BootstrapArgs` 从来没传 `--max-tries` / `--retry-wait`，aria2 的
///     默认值是「重试 5 次、每次间隔 0 秒」，`--input-file` 读回的死任务
///     因此在几毫秒内各自跑完整轮重试；
///   - `_handleFailure` 重新提交也是**零等待**，而且换源不消耗原地重试额度，
///     一条任务可以在几十毫秒里烧掉「候选地址条数 + 5」次 RPC。
/// 这组用例钉住修好的两条：间隔逐次变大、总次数有上限；
/// 并且到上限之后**仍然把失败如实标出来**（不许退回之前的假成功）。
void main() {
  group('retryBackoffDelay（纯函数）', () {
    test('从 0 次起逐次翻倍，并封顶在 kRetryBackoffCap', () {
      expect(retryBackoffDelay(0), const Duration(milliseconds: 800));
      expect(retryBackoffDelay(1), const Duration(milliseconds: 1600));
      expect(retryBackoffDelay(2), const Duration(milliseconds: 3200));
      expect(retryBackoffDelay(3), const Duration(milliseconds: 6400));
      expect(retryBackoffDelay(4), kRetryBackoffCap);
      expect(retryBackoffDelay(50), kRetryBackoffCap,
          reason: '次数很大时也不能把 1<<n 移位成负数时长');
    });

    test('严格不减，前四次严格变大', () {
      for (var i = 0; i < 20; i++) {
        expect(retryBackoffDelay(i + 1) >= retryBackoffDelay(i), isTrue);
        if (i < 3) {
          expect(retryBackoffDelay(i + 1) > retryBackoffDelay(i), isTrue);
        }
      }
    });

    test('负数按 0 次处理（不能退化成 0 等待）', () {
      expect(retryBackoffDelay(-3), kRetryBackoffBase);
    });
  });

  group('autoResubmitsUsed（这条任务已经自动重投几次）', () {
    DownloadTask t({int attempt = 0, int remains = kAriaRetryTimes}) =>
        DownloadTask(
          localId: 'l1',
          media: const Media(
              id: 'm1', type: MediaType.image, url: 'https://a/1.jpg'),
          saveDir: '.',
          retryRemains: remains,
          attempt: attempt,
        );

    test('刚提交 = 0 次', () => expect(autoResubmitsUsed(t()), 0));

    test('换源与原地重试**共用**一份额度', () {
      expect(autoResubmitsUsed(t(attempt: 2, remains: 4)), 3);
    });

    test('重启恢复出来的任务不会被重置成满额度', () {
      expect(autoResubmitsUsed(t(attempt: 0, remains: 0)), kAriaRetryTimes);
    });

    test('脏数据（余量大于初始值）不会算成负数', () {
      expect(autoResubmitsUsed(t(remains: kAriaRetryTimes + 7)), 0);
    });
  });

  group('aria2 引擎级重试参数', () {
    final args = aria2BootstrapArgs(
      port: 6801,
      secret: 's',
      sessionFile: r'C:\cfg\aria2.session',
      resumeSession: true,
      parentPid: 1234,
    );

    test('开机读回会话时必须有重试次数上限与间隔', () {
      expect(args, contains('--max-tries=3'));
      expect(args, contains('--retry-wait=2'));
    });
  });

  group('失败 → 退避 → 重新提交（走真实事件链路）', () {
    late Directory tmp;
    late _FakeAria2 aria;
    late Aria2Coordinator c;
    late DownloadStore store;
    late List<int> requestedMs;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jxxzq_backoff_');
      await AppPaths.init(
          exeDirOverride: tmp, fallbackOverride: tmp);
      await AppLogger.init(enabled: true);

      aria = _FakeAria2();
      c = Aria2Coordinator.withAria2(aria);
      // 记录「每次要求等多久」，但测试不真等
      requestedMs = [];
      c.backoffFor = (used) {
        requestedMs.add(retryBackoffDelay(used).inMilliseconds);
        return Duration.zero;
      };
      store = DownloadStore()..setSaveDir(tmp.path);
      await c.bootstrap(store: store, settings: SettingsStore());
    });

    tearDown(() async {
      await c.dispose();
      await AppLogger.dispose();
      await aria.finish();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<String> logFile() async {
      await AppLogger.flushForTest();
      return File(await AppLogger.currentFilePath()).readAsString();
    }

    test('退避逐次变大，到 kMaxAutoResubmits 就停手', () async {
      final r = await c.enqueueMedia(_media(candidates: 10));
      expect(r.outcome, EnqueueOutcome.queued);
      await aria.settle();

      expect(requestedMs.take(4), [800, 1600, 3200, 6400],
          reason: '前四次必须指数增长');
      expect(requestedMs.length, kMaxAutoResubmits,
          reason: '上限之外不该再排任何一次退避');
      expect(aria.added.length, kMaxAutoResubmits + 1,
          reason: '首发 1 次 + 自动重投 $kMaxAutoResubmits 次');
      expect(requestedMs.last, kRetryBackoffCap.inMilliseconds);

      // 之后仍在失败，也不许再多投一次
      aria.added.clear();
      requestedMs.clear();
      await aria.emitLastFailure();
      await aria.settle();
      expect(aria.added, isEmpty, reason: '到上限后不能再重新提交');
      expect(requestedMs, isEmpty);
    });

    test('到上限后任务落在「错误」并带上原始错误说明（失败看得见）', () async {
      await c.enqueueMedia(_media(candidates: 10));
      await aria.settle();

      // 每轮重投都会在任务表里换一条新行，所以按最后那个 gid 找
      final t = store.tasks.firstWhere((e) => e.aria2Gid == aria.lastGid);
      expect(t.status, DownloadStatus.error);
      expect(t.errorMessage, contains('No URI available'),
          reason: '不能因为到上限就标成完成、或悄悄从列表删掉');
      expect(await logFile(), contains('自动重试到上限'),
          reason: '日志要说清是被上限挡住的，而不是无声消失');
    });

    test('永久错误（404）+ 只有一条地址 → 立刻认输，一次都不重投', () async {
      aria.errorText = 'The response status is not successful. status=404';
      final r = await c.enqueueMedia(_media(candidates: 1));
      await aria.settle();

      expect(aria.added.length, 1, reason: '404 不该被原地重试 5 次');
      expect(store.task(r.localId!)!.status, DownloadStatus.error);
      expect(requestedMs, isEmpty);
    });

    test('同一个 gid 连发两个错误事件 → 只排一次重新提交', () async {
      aria.failsImmediately = false;
      final r = await c.enqueueMedia(_media(candidates: 10));
      final gid = store.task(r.localId!)!.aria2Gid!;
      aria.emitError(gid);
      aria.emitError(gid);
      await aria.settle();
      expect(aria.added.length, 2,
          reason: '两个事件只该换来一次重投（否则退避越长、放大越凶）');
    });

    test('退避等待期间用户移除任务 → 不许把它投回去', () async {
      c.backoffFor = (_) => const Duration(milliseconds: 60);
      aria.failsImmediately = false;
      final r = await c.enqueueMedia(_media(candidates: 10));
      final gid = store.task(r.localId!)!.aria2Gid!;
      aria.emitError(gid);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      store.remove(r.localId!); // 用户在退避窗口里点了「移除」
      await aria.settle();
      expect(store.task(r.localId!), isNull, reason: '删掉的任务不能复活');
      expect(aria.added.length, 1, reason: '等待结束后不许再入队');
    });

    test('会话里读回的死任务（本地表没有它）被摘掉，不再每次开机重跑', () async {
      final before = aria.added.length;
      aria.emitError('deadgid0001');
      await aria.settle();

      expect(aria.removed, contains('deadgid0001'),
          reason: '留着它，--save-session 就把死任务留在会话里，下次开机又失败一次');
      expect(aria.added.length, before, reason: '但也不能把它复活成新下载');
    });
  });
}

/// 一条媒体，候选地址条数可指定（换源次数由它决定）。
Media _media({required int candidates}) => Media(
      id: 'm1',
      type: MediaType.image,
      url: 'https://cdn.example.com/m1.jpg',
      altUrls: [
        for (var i = 1; i < candidates; i++) 'https://cdn.example.com/m1.jpg#$i'
      ],
    );

/// 假传输层：不启 aria2c，把「入队 → 立刻失败」模拟成真实事件流。
class _FakeAria2 extends Aria2 {
  final _errors = StreamController<String>.broadcast();
  final List<String> added = [];
  final List<String> removed = [];

  /// 每条投出去的任务是否立刻失败（上限之后要能停住级联）
  bool failsImmediately = true;
  String errorText = 'No URI available.';
  String _lastGid = '';
  String get lastGid => _lastGid;

  @override
  Future<void> bootstrap() async {}

  @override
  Future<void> updateConcurrency(int value) async {}

  @override
  Stream<String> get onDownloadError => _errors.stream;

  @override
  Future<String> addUri(
    String url, {
    required String dir,
    required String out,
    Map<String, String>? options,
  }) async {
    added.add(url);
    final gid = 'gid-${added.length}';
    _lastGid = gid;
    if (failsImmediately) {
      // 真 aria2 是「收任务 → 请求 → 失败 → 发事件」；隔一拍再发，
      // 免得 addUri 的 await 链把整轮级联压成同步递归
      Timer.run(() => emitError(gid));
    }
    return gid;
  }

  @override
  Future<void> remove(String gid) async => removed.add(gid);

  @override
  Future<AriaTask> tellStatus(String gid) async => AriaTask(
        gid: gid,
        status: AriaStatus.error,
        completeSize: 0,
        totalSize: 0,
        fileName: 'm1.jpg',
        dir: '',
        error: errorText,
      );

  void emitError(String gid) => _errors.add(gid);

  /// 级联跑完之后，再单独打一发失败 —— 用来验「上限之后不再重投」。
  Future<void> emitLastFailure() async {
    failsImmediately = false;
    emitError(_lastGid);
  }

  /// 等事件循环把当前这一串「失败 → 退避 → 重投」跑干净
  Future<void> settle() async {
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> finish() => _errors.close();
}
