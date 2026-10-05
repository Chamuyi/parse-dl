import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/douyin_ledger.dart';
import 'package:parse_dl/services/douyin_ledger_bridge.dart';
import 'package:parse_dl/services/download_store.dart';

/// 「下载完成 → 进已下载」这条链的中间一环。
///
/// `advance()` 自己的语义在 `douyin_ledger_test` 里测得很足，但**任务表变化会不会
/// 触发推进**原先只有 `main.dart` 里那三行内联接线知道 —— 也就是必须真开界面点一次
/// 下载才能确认。抽成 `bindLedgerToDownloads` 后，这里用真实的
/// `DownloadStore` + 真实的 `DouyinLedger`（落盘到临时目录）跑一遍。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ledger-bridge-');
    await AppPaths.init(
        exeDirOverride: tmp, fallbackOverride: tmp);
  });

  tearDown(() async {
    // Windows 上 `DownloadStore` 的写盘定时器可能还压着句柄，立刻删会 errno=32。
    // 试三次还不掉就留给系统临时目录 —— 断言已经跑完，不该为此挂红。
    for (var i = 0; i < 3 && tmp.existsSync(); i++) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    }
  });

  Future<(DownloadStore, DouyinLedger, String)> seeded() async {
    final store = DownloadStore()..setSaveDir(tmp.path);
    final ledger = DouyinLedger();
    await ledger.load();
    const media = Media(
      id: 'file-1',
      type: MediaType.video,
      url: 'https://cdn.example.invalid/file-1.mp4',
      source: 'douyin',
      tweetId: 'aweme-1',
    );
    final localId = store.addPending(media, tmp.path, fileName: 'aweme-1.mp4');
    await ledger.markQueued({
      'aweme-1': (taskIds: [localId], title: '一条作品', author: '某作者'),
    });
    return (store, ledger, localId);
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('入队只算「在下」，不算已下载', () async {
    final (store, ledger, _) = await seeded();
    bindLedgerToDownloads(ledger, store);
    await settle();
    expect(ledger.contains('aweme-1'), isTrue, reason: '要拦住重复入队');
    expect(ledger.doneCount, 0, reason: '还没下完就不能进「已下载」');
    expect(ledger.records, isEmpty);
  });

  test('任务真的下完 → 自动进「已下载」', () async {
    final (store, ledger, localId) = await seeded();
    bindLedgerToDownloads(ledger, store);
    store.markActive(localId, 'gid-1');
    await settle();
    expect(ledger.doneCount, 0, reason: '下载中也不算');

    store.markComplete('gid-1');
    await settle();
    expect(ledger.doneCount, 1);
    expect(ledger.records.single.awemeId, 'aweme-1');
    expect(ledger.records.single.title, '一条作品');
  });

  test('任务失败 → 撤掉记录，下次要能重试', () async {
    final (store, ledger, localId) = await seeded();
    bindLedgerToDownloads(ledger, store);
    store.markActive(localId, 'gid-1');
    store.markErrorByGid('gid-1', 'aria2 说 403');
    await settle();
    expect(ledger.contains('aweme-1'), isFalse);
    expect(ledger.doneCount, 0);
  });

  test('解除监听后不再推进（证明是这条监听在驱动）', () async {
    final (store, ledger, localId) = await seeded();
    final unbind = bindLedgerToDownloads(ledger, store);
    unbind();
    store.markActive(localId, 'gid-1');
    store.markComplete('gid-1');
    await settle();
    expect(ledger.doneCount, 0, reason: '解绑后还推进 = 这条测试没在测监听');
  });

  test('启动时补账：上次会话已经下完的任务，重启后仍要进「已下载」', () async {
    final (store, ledger, localId) = await seeded();
    // 模拟"完成事件丢了"：任务表里已是完成态，但台账还挂着 pending
    store.markActive(localId, 'gid-1');
    store.markComplete('gid-1');
    final fresh = DouyinLedger();
    await fresh.load(); // 从盘上读回 pending 状态
    expect(fresh.doneCount, 0);
    bindLedgerToDownloads(fresh, store); // 绑定即推一次
    await settle();
    expect(fresh.doneCount, 1);
    expect(ledger.doneCount, 0, reason: '别把两个实例混了');
  });
}
