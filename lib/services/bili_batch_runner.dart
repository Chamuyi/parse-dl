/// B 站「一批分 P → 入队」的那一段，页面与批量页共用。
///
/// **为什么要从页面里抽出来**：这一段守着台账的红线（N3）——
/// 入队后只 `markPending`，转 done 只发生在协调器的收口回调里。同样的循环写两遍，
/// 将来一定有其中一遍被人改成「投成功就记 done」，而那在现场看不出来：
/// 合并失败的稿件也会变成「已下载」，之后开着「跳过已下载」就再也不重试了。
///
/// 界面一概不碰：Toast、勾选态、`setState` 都留在页面里，这里只回一份计数。
library;

import '../models/bili_config.dart';
import '../models/media.dart';
import 'aria2_coordinator.dart';
import 'app_logger.dart';
import 'bili_api.dart';
import 'bili_download_plan.dart';
import 'bili_link.dart';
import 'bili_ledger.dart';

/// 一批跑完的计数。页面各自决定怎么把它说成人话。
class BiliRunTally {
  int queued = 0;

  /// 台账里已经处理过（`pending` 或 `done`）
  int skippedLedger = 0;

  /// 成品已经在磁盘上（协调器判的，口径与台账不同）
  int skippedDisk = 0;
  int failed = 0;

  /// 失败原因，**去重后只留前面几条**：几十条分 P 撞同一个风控时，
  /// 提示条里不该出现三十遍同一句话（全量都在日志里）。
  final List<String> notes = [];

  void addNote(String? why) {
    if (why == null || why.isEmpty) return;
    if (!notes.contains(why)) notes.add(why);
  }

  int get touched => queued + skippedLedger + skippedDisk + failed;

  /// 把另一批的计数并进来（批量页一个目标要跑很多批：每条稿件一次）。
  void absorb(BiliRunTally other) {
    queued += other.queued;
    skippedLedger += other.skippedLedger;
    skippedDisk += other.skippedDisk;
    failed += other.failed;
    for (final n in other.notes) {
      if (!notes.contains(n)) notes.add(n);
    }
  }
}

/// `view` 摊成分 P 级 [Media]（解析页与批量页共用，一处口径）。
///
/// 刻意放在 runner 这一层而不是页面里：列表阶段那批 `biliPartMedia()` 出来的
/// 媒体**没有 cid 之外的标签**，两个页面各自映射一遍迟早会写歪一处字段。
List<Media> biliPartsOfView(BiliVideoView view) => [
  for (final pg in view.pages)
    if (pg.cid > 0)
      biliPartMedia(
        bvid: view.bvid,
        aid: view.aid,
        workTitle: view.title,
        upperName: view.upperName,
        upperMid: view.upperMid,
        publishTime: view.publishTime,
        cover: pg.pic.isNotEmpty ? pg.pic : view.cover,
        partTotal: view.partTotal,
        partIndex: pg.index,
        cid: pg.cid,
        partTitle: pg.partTitle,
        durationMs: pg.durationMs,
      ),
];

/// 把 [parts] 逐条取流、选流、摊成两条流并投进 aria2。
///
/// [cancel] 每投一条前问一次：批量页有「停止」按钮，而一次批量可能是几百条，
/// 不能等它自己跑完。解析页不传，行为与从前一致。
Future<BiliRunTally> biliDownloadParts({
  required BiliApi api,
  required BiliConfig cfg,
  required List<Media> parts,
  required BiliLedger ledger,
  Aria2Coordinator? coordinator,
  bool Function()? cancel,
}) async {
  final tally = BiliRunTally();
  final air = coordinator ?? Aria2Coordinator.instance;

  // 并发数是 aria2 的全局选项，入队前同步一次（幂等）
  await air.applyConcurrency(cfg.concurrency);

  for (final part in parts) {
    if (cancel?.call() ?? false) {
      AppLogger.log('BILI', '批量已停止，剩下的分 P 不再投（本条之前已投 ${tally.queued} 条）');
      break;
    }
    final key = biliPartKey(
      bvid: part.bili?.bvid,
      cid: part.bili?.cid,
    );
    // 「跳过已下载」= 台账（`pending` 与 `done` 都算处理过，见 bili_ledger.dart
    // 的 `contains` 注释：手快再点一次不该重复提交同一个分 P）。
    // 磁盘上有没有成品是协调器那一步的事（同名跳过）。
    if (cfg.skipDownloaded && biliKeyGroupUsable(key) && ledger.contains(key)) {
      tally.skippedLedger++;
      continue;
    }

    final cid = int.tryParse(part.bili?.cid ?? '');
    if (cid == null || cid <= 0) {
      tally.failed++;
      AppLogger.log('BILI', '这条分 P 没有 cid，投不出去：${part.id}');
      continue;
    }

    try {
      final r = await api.playurl(
        cid: cid,
        qn: cfg.quality.qn,
        codec: cfg.codec,
        bvid: part.bili?.bvid,
        aid: int.tryParse(part.bili?.aid ?? ''),
      );
      final pair = planBiliStreams(r, cfg.quality, cfg.codec);
      final why = pair.message;
      if (!pair.usable || why != null) {
        // 选流层已经算出人话了（要登录 / 要大会员 / 分段没做），原样带出去
        tally.failed++;
        AppLogger.log('BILI', '选流失败（${part.id}）：$why');
        tally.addNote(why);
        continue;
      }

      // 文件名里的 %QUALITY% / %CODEC% 只有到这一步才知道，
      // 所以 base 名必须在选流**之后**算（见 biliPartWithLabels）。
      final labeled = biliPartWithLabels(
        part,
        videoQn: pair.videoQn,
        codec: pair.videoCodec,
        r: r,
      );
      final base = Aria2Coordinator.biliOutBase(cfg.fileNameTemplate, labeled, cfg);
      final medias = biliPairToMedias(part: labeled, pair: pair);
      final audio = medias.audio;
      final res = await air.enqueueBiliMedia(
        medias.video,
        // durl 退化路径没有第二条流：给一条空地址的音频占位，
        // 协调器据此走「投一条、不建配对、不合并」。
        audio ?? _noStreamAudio(part),
        base,
        cfg,
      );

      switch (res.outcome) {
        case EnqueueOutcome.queued:
          tally.queued++;
          await _markPending(ledger, key, res, labeled);
          tally.addNote(res.message);
        case EnqueueOutcome.skippedExisting:
          // 「同名跳过」看的是**成品**在不在（不是裸流），这条口径由协调器持有。
          tally.skippedDisk++;
        case EnqueueOutcome.notReady:
        case EnqueueOutcome.rejected:
        case EnqueueOutcome.removeFailed:
          tally.failed++;
          AppLogger.log(
            'BILI',
            '入队失败（${res.outcome.name}，${part.id}）：${res.message ?? '无说明'}',
          );
          tally.addNote(res.message);
      }
    } catch (e) {
      tally.failed++;
      AppLogger.log('BILI', '取流/入队异常（${part.id}）：$e');
      tally.addNote('$e');
    }
  }
  return tally;
}

/// 入队成功之后记一笔「在下」（等收口回调转 done，转 done 的位置在 main.dart）。
Future<void> _markPending(
  BiliLedger ledger,
  BiliKeyGroup key,
  BiliEnqueueResult res,
  Media labeled,
) async {
  if (!biliKeyGroupUsable(key)) {
    AppLogger.log('BILI', '键组不完整，这条不记台账：${labeled.id}');
    return;
  }
  final ids = [res.videoLocalId, res.audioLocalId].whereType<String>().toList();
  final hash = ledger.hashOf(key);
  await ledger.markPending(
    [key],
    meta: {hash: (title: labeled.bili?.workTitle, author: labeled.userName)},
    taskIds: {hash: ids},
  );
}

/// durl 退化路径的音频占位：`url` 为空 + `chosen` 为空，正是协调器判
/// 「没有第二条流」的那两个条件（见 `enqueueBiliMedia` 的 `single`）。
Media _noStreamAudio(Media part) => Media(
      id: '${part.id}_audio',
      type: MediaType.audio,
      url: '',
      tweetId: part.tweetId,
      source: 'bili',
    );
