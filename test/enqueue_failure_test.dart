import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/aria2.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/settings_store.dart';

/// S2 回归测试：「入队失败被当成成功」。
///
/// 现场（`aria2_coordinator.dart` 的入队 catch + `download_store.dart` 的标记）：
///
/// ```dart
/// } catch (e) {
///   store.markError(localId, 'aria2 拒绝任务：$e');   // markError 是按 gid 查的
///   return (localId: localId, outcome: EnqueueOutcome.queued);  // 却报「已入队」
/// }
/// ```
///
/// 三个叠加后果：
///   1. 失败任务永远停在 `pending`（下载管理页把 pending 划进「下载中」），
///      用户看不到失败，连错误消息都没有；
///   2. 返回值 `queued` 让三个调用方都按成功计数（「已提交 N 个」说谎）；
///   3. **最严重**：抖音页据此把整批作品写进「已下载」台账 ——
///      压根没提交成功的作品会被「跳过已下载」永久静默跳过。
///
/// 这里用「注入假 aria2 传输层」的方式把 `_submit` 的成功/失败两条路径
/// 都钉住 —— 这正是原报告 §7 指出的测试盲区（只覆盖了纯函数 `decideRetry`）。
///
/// 关于注入：`Aria2Coordinator.withAria2()` 只换掉传输层，
/// `bootstrap()` 的其余装配（store 绑定、事件订阅）仍是生产代码路径。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jxxzq_enqueue_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Media sampleMedia({String id = 'm1', String? awemeId = 'aweme-1'}) => Media(
        id: id,
        type: MediaType.video,
        url: 'https://cdn.example.com/$id.mp4',
        tweetId: awemeId,
        source: awemeId == null ? 'x' : 'douyin',
      );

  Future<({Aria2Coordinator coordinator, DownloadStore store, _FakeAria2 aria})>
      boot({required bool reject}) async {
    final aria = _FakeAria2(reject: reject);
    final coordinator = Aria2Coordinator.withAria2(aria);
    final store = DownloadStore()..setSaveDir(tmp.path);
    await coordinator.bootstrap(store: store, settings: SettingsStore());
    return (coordinator: coordinator, store: store, aria: aria);
  }

  group('Aria2Coordinator 入队失败（S2）', () {
    test('aria2 拒绝 → 任务必须进入失败态并带上原因（不能停在「等待入队」）', () async {
      final env = await boot(reject: true);

      await env.coordinator.enqueueMedia(sampleMedia());

      final t = env.store.tasks.single;
      expect(t.status, DownloadStatus.error,
          reason: '停在 pending 会被下载管理页当成「下载中」，用户永远看不到失败');
      expect(t.errorMessage, isNotNull);
      expect(t.errorMessage, contains('拒绝'));

      await env.coordinator.dispose();
    });

    test('aria2 拒绝 → 结局必须是 rejected，不能谎报 queued', () async {
      final env = await boot(reject: true);

      final r = await env.coordinator.enqueueMedia(sampleMedia());

      expect(r.outcome, EnqueueOutcome.rejected);
      expect(r.localId, isNotNull, reason: '失败的任务也要能反查到，用户在列表里能看到它');

      await env.coordinator.dispose();
    });

    test('aria2 接受 → 绑定 gid、结局为 queued', () async {
      final env = await boot(reject: false);

      final r = await env.coordinator.enqueueMedia(sampleMedia());

      expect(r.outcome, EnqueueOutcome.queued);
      final t = env.store.tasks.single;
      expect(t.status, DownloadStatus.active);
      expect(t.aria2Gid, env.aria.gid);
      expect(env.store.gidFor(r.localId!), env.aria.gid);

      await env.coordinator.dispose();
    });
  });

  group('台账只能记「确认入队」的作品（S2 数据污染）', () {
    test('只有 queued 的条目对应的作品才会被记录', () {
      final ok = sampleMedia(id: 'a', awemeId: 'aweme-ok');
      final bad = sampleMedia(id: 'b', awemeId: 'aweme-failed');
      final skipped = sampleMedia(id: 'c', awemeId: 'aweme-skipped');

      final byAweme = queuedTasksByAweme([
        (media: ok, localId: 'L1', outcome: EnqueueOutcome.queued),
        (media: bad, localId: null, outcome: EnqueueOutcome.rejected),
        (media: skipped, localId: null, outcome: EnqueueOutcome.skippedExisting),
      ]);

      expect(byAweme.keys, {'aweme-ok'});
      // 记的是任务 id 而不是「已下载」结论：后面要靠任务结局推进
      expect(byAweme['aweme-ok']!.taskIds, ['L1']);
    });

    test('整批都没提交成功 → 台账为空（否则作品会被永久静默跳过）', () {
      final byAweme = queuedTasksByAweme([
        (
          media: sampleMedia(id: 'a'),
          localId: null,
          outcome: EnqueueOutcome.rejected
        ),
        (
          media: sampleMedia(id: 'b'),
          localId: null,
          outcome: EnqueueOutcome.notReady
        ),
      ]);

      expect(byAweme, isEmpty);
    });

    test('同一作品的多个媒体归到同一条记录、任务 id 全收；没有作品 id 的跳过', () {
      final byAweme = queuedTasksByAweme([
        (
          media: sampleMedia(id: 'a1', awemeId: 'aweme-x'),
          localId: 'L1',
          outcome: EnqueueOutcome.queued
        ),
        (
          media: sampleMedia(id: 'a2', awemeId: 'aweme-x'),
          localId: 'L2',
          outcome: EnqueueOutcome.queued
        ),
        (
          media: sampleMedia(id: 'b', awemeId: null),
          localId: 'L3',
          outcome: EnqueueOutcome.queued
        ),
      ]);

      expect(byAweme.keys, {'aweme-x'});
      // 图集里每张图是一个独立任务 —— 少收一个就会「下了一半却算全完」
      expect(byAweme['aweme-x']!.taskIds, ['L1', 'L2']);
    });
  });
}

/// 假传输层：只替换「进程 + RPC」，其余装配与生产一致。
class _FakeAria2 extends Aria2 {
  _FakeAria2({required this.reject});

  final bool reject;
  final String gid = 'gid-ok';

  @override
  Future<void> bootstrap() async {
    // 不启动真实 aria2c 进程
  }

  @override
  Future<String> addUri(
    String url, {
    required String dir,
    required String out,
    Map<String, String>? options,
  }) async {
    if (reject) {
      throw StateError('aria2 调用 aria2.addUri 失败：拒绝任务');
    }
    return gid;
  }
}
