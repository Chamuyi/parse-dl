import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/aria2.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/settings_store.dart';

/// S1 续传回归测试：**任务表落盘 / 重启恢复 / 与 aria2 会话对账**。
///
/// 现场（`download_store.dart:112`、`aria2.dart:122-128`）：
///   - `_tasks` 是纯内存 Map，退出即丢；
///   - aria2 启动参数没有 `--continue` / `--save-session`，
///     在途任务与队列全部消失，半截文件被 `--auto-file-renaming` 存成
///     `xxx.1.mp4`，用户看到重复堆积。
///
/// 实测前提（`probe/aria2-session-probe.ps1`）：会话文件里**保留了 gid**，
/// 用 `--input-file` 重启后 gid 与上次逐字一致 —— 所以「按 gid 重新绑定」
/// 是可行的，[Aria2Coordinator.reconcile] 做的就是这件事。
void main() {
  Media douyinMedia({String id = 'm1', String awemeId = 'aweme-1'}) => Media(
        id: id,
        type: MediaType.video,
        url: 'https://cdn.example.com/$id.mp4',
        previewUrl: 'https://cdn.example.com/$id.jpg',
        tweetId: awemeId,
        userName: '作者',
        userScreenName: 'author',
        source: 'douyin',
        altUrls: ['https://backup.example.com/$id.mp4'],
        mediaIndex: 3,
        createdAt: DateTime.utc(2026, 9, 15, 1, 2, 3),
        durationMs: 12000,
        tags: const ['t1', 't2'],
      );

  group('Media 落盘往返（重试要用的字段一个都不能丢）', () {
    test('url / altUrls / source / tweetId / 时间 / 扩展名都要保住', () {
      final m = douyinMedia();
      final back = Media.fromJson(
          (jsonDecode(jsonEncode(m.toJson())) as Map).cast<String, dynamic>());

      expect(back.id, m.id);
      expect(back.url, m.url);
      expect(back.altUrls, m.altUrls,
          reason: '换源重试完全依赖 altUrls，丢了就等于没有备用地址');
      expect(back.downloadCandidates, m.downloadCandidates);
      expect(back.tweetId, m.tweetId, reason: '台账与按作品聚合都要它');
      expect(back.source, 'douyin', reason: '单任务 Referer 只在抖音源上加');
      expect(back.extension, m.extension);
      expect(back.createdAt, m.createdAt);
      expect(back.durationMs, 12000);
      expect(back.mediaIndex, 3);
      expect(back.tags, ['t1', 't2']);
    });

    test('图片的 X 源仍会补 ?name=orig（往返不能把它弄丢）', () {
      final m = Media(
        id: 'p1',
        type: MediaType.image,
        url: 'https://pbs.twimg.com/media/x.jpg',
      );
      final back = Media.fromJson(
          (jsonDecode(jsonEncode(m.toJson())) as Map).cast<String, dynamic>());
      expect(back.source, 'x');
      expect(back.downloadCandidates.single, contains('name=orig'));
    });
  });

  group('DownloadStore 任务表落盘 / 恢复', () {
    late Directory tmp;
    setUp(() async =>
        tmp = await Directory.systemTemp.createTemp('jxxzq_persist_test_'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('往返后任务的关键字段全部保住（含 gid 与本地 id）', () {
      final store = DownloadStore()..setSaveDir(tmp.path);
      final localId = store.addPending(douyinMedia(), tmp.path,
          fileName: '%POST_ID%-1.mp4', retryRemains: 5, attempt: 1);
      store.markActive(localId, 'gid-restored');

      final back = DownloadStore()..restoreFromJson(store.encode());

      final t = back.tasks.single;
      expect(t.localId, localId, reason: 'localId 是 UI 与 aria2 事件之间的桥梁');
      expect(t.aria2Gid, 'gid-restored');
      expect(t.status, DownloadStatus.active);
      expect(t.fileName, '%POST_ID%-1.mp4');
      expect(t.saveDir, tmp.path);
      expect(t.retryRemains, 5);
      expect(t.attempt, 1);
      expect(back.defaultSaveDir, tmp.path);
      expect(back.gidFor(localId), 'gid-restored');
      expect(t.media.altUrls, isNotEmpty);
    });

    test('完成 / 失败态也要保住（否则重启后历史全没了）', () {
      final store = DownloadStore()..setSaveDir(tmp.path);
      final a = store.addPending(douyinMedia(id: 'a'), tmp.path,
          fileName: 'a.mp4', retryRemains: 0);
      store.markActive(a, 'gid-a');
      store.markComplete('gid-a');
      final b = store.addPending(douyinMedia(id: 'b'), tmp.path,
          fileName: 'b.mp4', retryRemains: 0);
      store.markActive(b, 'gid-b');
      store.markErrorByLocalId(b, '磁盘满了');

      final back = DownloadStore()..restoreFromJson(store.encode());
      final byId = {for (final t in back.tasks) t.localId: t};
      expect(byId[a]!.status, DownloadStatus.complete);
      expect(byId[b]!.status, DownloadStatus.error);
      expect(byId[b]!.errorMessage, '磁盘满了');
    });

    test('「还没入队就退出」的任务不能伪装成在下载 —— 如实标记失败', () {
      final store = DownloadStore()..setSaveDir(tmp.path);
      store.addPending(douyinMedia(), tmp.path, fileName: 'x.mp4');

      final back = DownloadStore()..restoreFromJson(store.encode());

      final t = back.tasks.single;
      expect(t.status, DownloadStatus.error);
      expect(t.errorMessage, isNotNull);
      expect(t.errorMessage, contains('入队'));
    });

    test('坏数据只丢坏行：整份 JSON 损坏 → 空表；单行损坏 → 其它行照常恢复', () {
      final store = DownloadStore()
        ..restoreFromJson('not json at all')
        ..restoreFromJson('{"version":1,"tasks":"wrong shape"}');
      expect(store.tasks, isEmpty);

      final good = DownloadStore()..setSaveDir(tmp.path);
      final id = good.addPending(douyinMedia(), tmp.path, fileName: 'ok.mp4');
      good.markActive(id, 'gid-ok');
      final raw = jsonDecode(good.encode()) as Map<String, dynamic>;
      final rows = (raw['tasks'] as List).cast<Map<String, dynamic>>();
      rows.insertAll(0, [
        {'localId': 'broken'}, // 缺 media
        {'localId': 'broken2', 'media': {'id': 'm', 'type': 'video'}}, // 缺 url/saveDir
      ]);

      final back = DownloadStore()
        ..restoreFromJson(jsonEncode({'version': 1, 'tasks': rows}));
      expect(back.tasks.length, 1, reason: '一条脏记录不该毁掉整张任务表');
      expect(back.tasks.single.aria2Gid, 'gid-ok');
    });
  });

  group('重启对账（reconcile）：按 gid 找 aria2，找不到就看文件', () {
    late Directory tmp;
    setUp(() async =>
        tmp = await Directory.systemTemp.createTemp('jxxzq_reconcile_test_'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<({Aria2Coordinator coordinator, DownloadStore store})> boot(
      _ReconcileAria2 aria,
    ) async {
      final coordinator = Aria2Coordinator.withAria2(aria);
      final store = DownloadStore()..setSaveDir(tmp.path);
      await coordinator.bootstrap(store: store, settings: SettingsStore());
      return (coordinator: coordinator, store: store);
    }

    AriaTask task(String gid, AriaStatus status, {String error = ''}) =>
        AriaTask(
          gid: gid,
          status: status,
          completeSize: 0,
          totalSize: 0,
          fileName: '',
          dir: '',
          error: error,
        );

    test('aria2 会话里还在（暂停）→ 恢复成暂停，而不是永远「下载中」', () async {
      final aria = _ReconcileAria2(
        byGid: {'gid-1': task('gid-1', AriaStatus.paused)},
      );
      final env = await boot(aria);
      final id = env.store.addPending(douyinMedia(), tmp.path, fileName: 'a.mp4');
      env.store.markActive(id, 'gid-1');

      await env.coordinator.reconcile();

      expect(env.store.tasks.single.status, DownloadStatus.paused);
      await env.coordinator.dispose();
    });

    test('aria2 不认识这个 gid，但文件已经下好 → 判定完成（别让用户重下）', () async {
      final aria = _ReconcileAria2(byGid: const {});
      final env = await boot(aria);
      final id = env.store.addPending(douyinMedia(), tmp.path, fileName: 'done.mp4');
      env.store.markActive(id, 'gid-gone');
      await File('${tmp.path}\\done.mp4').writeAsBytes([1, 2, 3]);

      await env.coordinator.reconcile();

      expect(env.store.tasks.single.status, DownloadStatus.complete);
      await env.coordinator.dispose();
    });

    test('aria2 不认识这个 gid，文件也不在 → 标记失败并说明原因', () async {
      final aria = _ReconcileAria2(byGid: const {});
      final env = await boot(aria);
      final id = env.store.addPending(douyinMedia(), tmp.path, fileName: 'lost.mp4');
      env.store.markActive(id, 'gid-gone');

      await env.coordinator.reconcile();

      final t = env.store.tasks.single;
      expect(t.status, DownloadStatus.error);
      expect(t.errorMessage, contains('未能恢复'));
      await env.coordinator.dispose();
    });

    test('对账不动终态任务（已完成 / 已失败的不再回炉）', () async {
      final aria = _ReconcileAria2(
        byGid: {'gid-1': task('gid-1', AriaStatus.error, error: '会话里报错了')},
      );
      final env = await boot(aria);
      final id = env.store.addPending(douyinMedia(), tmp.path, fileName: 'a.mp4');
      env.store.markActive(id, 'gid-1');
      env.store.markComplete('gid-1');

      await env.coordinator.reconcile();

      expect(env.store.tasks.single.status, DownloadStatus.complete);
      await env.coordinator.dispose();
    });
  });
}

/// 假传输层：只回答 `tellStatus`，用来驱动重启对账。
class _ReconcileAria2 extends Aria2 {
  _ReconcileAria2({required this.byGid});

  final Map<String, AriaTask> byGid;

  @override
  Future<void> bootstrap() async {}

  @override
  Future<AriaTask> tellStatus(String gid) async {
    final t = byGid[gid];
    if (t == null) {
      throw StateError('aria2 调用 aria2.tellStatus 失败：GID $gid is not found');
    }
    return t;
  }
}
