import 'dart:async';

import 'download_store.dart';
import 'douyin_ledger.dart';

/// 抖音台账 ↔ 下载任务表 之间的桥。
///
/// 这段接线原来内联在 `main.dart` 里，于是"下载完成 → 进已下载"这条链的
/// 中间一环**没有任何测试能碰到**：`advance()` 自己的语义测得很足，
/// 但"任务表变了会不会触发推进"只能靠人开界面点一次才知道。
/// 抽出来之后 main.dart 只留一行调用。
DouyinTaskState douyinTaskStateOf(DownloadStore store, String taskId) {
  final s = store.task(taskId)?.status;
  if (s == null) return DouyinTaskState.unknown;
  if (s == DownloadStatus.complete) return DouyinTaskState.complete;
  if (s == DownloadStatus.error) return DouyinTaskState.failed;
  return DouyinTaskState.running;
}

/// 把台账接到任务表上：立刻推一次（补上次会话没落到的结局），
/// 之后任务表每次变化再推一次。返回解除监听的闭包。
void Function() bindLedgerToDownloads(
  DouyinLedger ledger,
  DownloadStore store,
) {
  DouyinTaskState of(String taskId) => douyinTaskStateOf(store, taskId);
  void listener() => unawaited(ledger.advance(of));
  unawaited(ledger.advance(of));
  store.addListener(listener);
  return () => store.removeListener(listener);
}
