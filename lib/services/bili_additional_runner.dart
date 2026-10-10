/// 附加文件的**编排层**：协调器在起 ffmpeg 之前叫一次，把所有勾了的族
/// 一次取回、落盘，合成一份 [BiliAdditionalOutcome]。
///
/// 为什么要有这一层而不是让协调器逐个去调：合并命令要的是**一条排好序的字幕轨
/// 列表**（顺序由 `cfg.trackPriority` 定）与**一个章节中间文件路径**，
/// 这两样天然是「所有族的汇总」。放在协调器里就会变成七零八落的四次调用加三段
/// 拼接逻辑，而那些逻辑跟 aria2 与任务行毫无关系。
///
/// 目前只接了弹幕一族。字幕／封面／元数据那三族落地后往 [biliProduceAdditional]
/// 里加调用即可 —— 它们的返回值同样是 [BiliAdditionalOutcome]，合并规则不用改。
library;

import '../models/bili_config.dart';
import '../models/media.dart';
import 'bili_additional.dart';
import 'bili_danmaku.dart';

/// cid 与时长都得从这条 `Media` 上取；取不到就不硬打接口，而是留一句能看见的话。
const String kBiliAdditionalNoCid = '缺 cid，弹幕与字幕取不了';
const String kBiliAdditionalNoDuration = '缺时长，弹幕分段数算不出来';

Future<BiliAdditionalOutcome> biliProduceAdditional({
  required BiliConfig cfg,
  required String saveDir,
  required String outBase,
  required Media video,
  required BiliDanmakuSegmentFetcher fetchDanmakuSegment,
  void Function(int done, int total)? onDanmakuProgress,
}) async {
  final tracks = <BiliEmbeddedTrack>[];
  final written = <String>[];
  final missing = <String>[];
  String? chapterMetadataPath;

  final cid = int.tryParse(video.bili?.cid ?? '');
  // Media.durationMs 是可空的（X 与抖音那边也可能不给）：
  // 拿不到就当作「算不出分段数」，而不是拿 null 去做除法。
  final durationSeconds = (video.durationMs ?? 0) ~/ 1000;

  if (cfg.saveDanmaku) {
    if (cid == null) {
      missing.add(kBiliAdditionalNoCid);
    } else if (durationSeconds <= 0) {
      missing.add(kBiliAdditionalNoDuration);
    } else {
      final run = await buildBiliDanmakuSideFile(
        saveDir: saveDir,
        base: outBase,
        cid: cid,
        durationSeconds: durationSeconds,
        cfg: cfg,
        fetchSegment: fetchDanmakuSegment,
        onProgress: onDanmakuProgress,
      );
      tracks.addAll(run.outcome.tracks);
      written.addAll(run.outcome.written);
      missing.addAll(run.outcome.missing);
    }
  }

  // 轨序只在这里定一次。各族自己排好的顺序到这里会被重新打散——
  // 弹幕墙与人工字幕谁占 0 号轨是用户的设置，不是某一族的内部事。
  return BiliAdditionalOutcome(
    tracks: orderTracks(tracks, cfg.trackPriority),
    written: written,
    missing: missing,
    chapterMetadataPath: chapterMetadataPath,
  );
}
