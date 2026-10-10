/// 附加文件的**编排层**：协调器在起 ffmpeg 之前叫一次，把所有勾了的族
/// 一次取回、落盘，合成一份 [BiliAdditionalOutcome]。
///
/// 为什么要有这一层而不是让协调器逐个去调：合并命令要的是**一条排好序的字幕轨
/// 列表**（顺序由 `cfg.trackPriority` 定）与**一个章节中间文件路径**，
/// 这两样天然是「所有族的汇总」。放进协调器就会变成五次调用加三段拼接逻辑，
/// 而那些逻辑跟 aria2 与任务行毫无关系。
///
/// 接口调用一律走注入的 [BiliAdditionalDeps]：这一层不认识 `BiliApi`，也不认识
/// WebView2。要登录态才拿得到的东西由装配层把口换成页内 fetch，这里一行不用改
/// —— 凭据也因此永远不会挪到下载器那侧（aria2 的 per-task header 会被
/// `--save-session` 明文写盘）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import '../models/bili_config.dart';
import '../models/bili_meta.dart';
import '../models/media.dart';
import 'bili_additional.dart';
import 'bili_chapter.dart';
import 'bili_cover.dart';
import 'bili_danmaku.dart';
import 'bili_metadata.dart';
import 'bili_subtitle.dart';

/// 五个族共用的取数口。
class BiliAdditionalDeps {
  const BiliAdditionalDeps({
    required this.signedData,
    required this.plainData,
    required this.jsonAtUrl,
    required this.bytesAtUrl,
    required this.danmakuSegment,
  });

  /// WBI 签名的 `GET path`，回接口的 `data` 本体。
  final Future<Map<String, dynamic>> Function(
    String path,
    Map<String, dynamic> params,
  )
  signedData;

  /// 不签名的 `GET path`，回 `data` **本体原样**（标签那一支的 data 是数组）。
  final Future<Object?> Function(String path, Map<String, dynamic> params)
  plainData;

  /// 直接 GET 一个完整 URL 的 JSON —— 字幕正文 `subtitle_url` 是绝对地址。
  final Future<Map<String, dynamic>> Function(String url) jsonAtUrl;

  /// 直接 GET 一个完整 URL 的字节（封面）。
  final Future<List<int>> Function(String url) bytesAtUrl;

  /// 弹幕分段。`segmentIndex` 从 1 起（实测口径）。
  final Future<List<int>> Function(int cid, int segmentIndex) danmakuSegment;
}

/// cid / 时长取不到时的话。它们不是「失败」，是「没法开始」，得能看见。
const String kBiliAdditionalNoCid = '缺 cid，弹幕与字幕取不了';
const String kBiliAdditionalNoDuration = '缺时长，弹幕分段数算不出来';

Future<BiliAdditionalOutcome> biliProduceAdditional({
  required BiliConfig cfg,
  required String saveDir,
  required String outBase,
  required Media video,
  required BiliAdditionalDeps deps,
  void Function(int done, int total)? onDanmakuProgress,
}) async {
  final tracks = <BiliEmbeddedTrack>[];
  final written = <String>[];
  final missing = <String>[];
  String? chapterMetadataPath;

  final meta = video.bili;
  final cid = int.tryParse(meta?.cid ?? '');
  final bvid = meta?.bvid ?? '';
  // `Media.durationMs` 可空（X 与抖音那边也可能不给）：拿不到就当「算不出分段数」，
  // 而不是拿 null 去做除法。
  final durationSeconds = (video.durationMs ?? 0) ~/ 1000;

  // 播放器接口一支喂两族（字幕 + 章节），所以只在这两族真的开着时才发。
  Map<String, dynamic>? player;
  if (cid == null) {
    // 没有 cid 时这两族**一次请求都发不出去**。这话必须说在缺项里，否则
    // 用户看到的是一句「接口没返回任何一条字幕」，把原因指向了 B 站。
    if (cfg.saveSubtitle || cfg.saveChapter || cfg.saveDanmaku) {
      missing.add(kBiliAdditionalNoCid);
    }
  } else if (cfg.saveSubtitle || cfg.saveChapter) {
    try {
      player = await deps.signedData('/x/player/wbi/v2', {
        'cid': cid,
        if (bvid.isNotEmpty) 'bvid': bvid,
      });
    } catch (_) {
      missing.add('播放器信息取不到（字幕与章节都受影响）');
    }
  }

  if (cid != null && cfg.saveSubtitle) {
    await _family('字幕', missing, () async {
      written.addAll(
        await _subtitles(cfg, saveDir, outBase, player, deps, tracks, missing),
      );
    });
  }
  if (cid != null && cfg.saveChapter) {
    await _family('章节', missing, () async {
      chapterMetadataPath = await _chapters(
        saveDir,
        outBase,
        player,
        durationSeconds,
        missing,
      );
    });
  }
  if (cfg.saveCover) {
    await _family('封面', missing, () async {
      final name = await biliWriteCover(
        cfg: cfg,
        saveDir: saveDir,
        outBase: outBase,
        pic: video.previewUrl ?? '',
        fetch: deps.bytesAtUrl,
      );
      if (name == null) {
        missing.add('封面：取不到原图');
      } else {
        written.add(name);
      }
    });
  }
  if (cfg.saveMetadata) {
    await _family('元数据', missing, () async {
      written.addAll(
        await _metadata(bvid, meta, cfg, saveDir, outBase, deps, missing),
      );
    });
  }
  if (cid != null && cfg.saveDanmaku) {
    if (durationSeconds <= 0) {
      missing.add(kBiliAdditionalNoDuration);
    } else {
      await _family('弹幕', missing, () async {
        final run = await buildBiliDanmakuSideFile(
          saveDir: saveDir,
          base: outBase,
          cid: cid,
          durationSeconds: durationSeconds,
          cfg: cfg,
          fetchSegment: deps.danmakuSegment,
          onProgress: onDanmakuProgress,
        );
        tracks.addAll(run.outcome.tracks);
        written.addAll(run.outcome.written);
        missing.addAll(run.outcome.missing);
      });
    }
  }

  // 轨序只在这里定一次。各族自己排好的顺序到这里会被重新打散 ——
  // 弹幕墙与人工字幕谁占 0 号轨是用户的设置，不是某一族的内部事。
  return BiliAdditionalOutcome(
    tracks: orderTracks(tracks, cfg.trackPriority),
    written: written,
    missing: missing,
    chapterMetadataPath: chapterMetadataPath,
  );
}

/// 一族一个隔离圈：**单族失败只让它自己缺席**。
///
/// 2026-10-11 真机匿名档撞出来的：标签接口对没标签的稿件不给 `data`，
/// 那一句异常当时直接把**整个附加文件步骤**掀掉 —— 封面已经落到盘上、弹幕明明
/// 还能取，结果一起没登记，界面上那一行就成了「什么都没勾到」。
/// 附加文件之间没有依赖，没有理由共沉。
Future<void> _family(
  String label,
  List<String> missing,
  Future<void> Function() run,
) async {
  try {
    await run();
  } catch (e) {
    AppLogger.log('BILI', '附加文件「$label」这一族没跑成：$e');
    missing.add('$label：这一族没取成');
  }
}

Future<List<String>> _subtitles(
  BiliConfig cfg,
  String saveDir,
  String outBase,
  Map<String, dynamic>? player,
  BiliAdditionalDeps deps,
  List<BiliEmbeddedTrack> tracks,
  List<String> missing,
) async {
  final subs = _subtitleRows(player);
  if (subs.isEmpty) {
    // 匿名态实测就是这个形状（取证 Q4）。这话必须说出来，
    // 否则用户以为「勾了就该有」。
    missing.add('字幕：接口没返回任何一条（匿名态多半如此，登录后再试）');
    return const [];
  }
  final out = <String>[];
  for (final row in subs) {
    final lan = row['lan'] is String ? row['lan'] as String : '';
    if (lan.isEmpty ||
        !biliSubtitleWanted(
          lan,
          cfg.subtitleLangs,
          manualOnly: cfg.subtitleManualOnly,
        )) {
      continue;
    }
    final url = row['subtitle_url'] is String ? row['subtitle_url'] as String : '';
    if (url.isEmpty) continue;
    final List<(int, int, String)> lines;
    try {
      lines = biliParseSubtitleBody(await deps.jsonAtUrl(_abs(url)));
    } catch (_) {
      missing.add('字幕：$lan 正文取回失败');
      continue;
    }
    if (lines.isEmpty) {
      missing.add('字幕：$lan 是空的');
      continue;
    }
    final entry = BiliSubtitleEntry(
      lan: lan,
      lanDoc: row['lan_doc'] is String ? row['lan_doc'] as String : lan,
      lines: lines,
    );
    final fmt = cfg.subtitleFormat;
    final content = switch (fmt) {
      BiliSubtitleFormat.srt => biliSubtitleToSrt(lines),
      BiliSubtitleFormat.txt => biliSubtitleToTxt(lines),
      BiliSubtitleFormat.ass => biliSubtitleToAss(entry, cfg),
    };
    final name = biliAdditionalName(
      base: outBase,
      qualifier: '字幕',
      lang: lan,
      ext: fmt.id,
    );
    await File(p.join(saveDir, name)).writeAsString(content);
    out.add(name);
    if (fmt != BiliSubtitleFormat.ass || !cfg.embedSubtitleTrack) continue;
    final blocked = cfg.embedBlockReason(forDanmaku: false);
    if (blocked == null) {
      tracks.add(
        BiliEmbeddedTrack(
          fileName: name,
          title: entry.trackTitle,
          iso639: biliIso639(lan),
          fromDanmaku: false,
        ),
      );
    } else {
      // 勾了内封却没登记成轨 —— 这一条必须说，而且要说清缺的是哪一步。
      missing.add('字幕：未登记内封轨 —— ${blocked.join('、')}');
    }
  }
  if (out.isEmpty && !missing.any((m) => m.startsWith('字幕：'))) {
    missing.add('字幕：勾选的语言一条都没有');
  }
  return out;
}

List<Map<String, dynamic>> _subtitleRows(Map<String, dynamic>? player) {
  final sub = player?['subtitle'];
  if (sub is! Map) return const [];
  final list = sub['subtitles'];
  if (list is! List) return const [];
  return [for (final e in list) if (e is Map) e.cast<String, dynamic>()];
}

Future<String?> _chapters(
  String saveDir,
  String outBase,
  Map<String, dynamic>? player,
  int durationSeconds,
  List<String> missing,
) async {
  final points = player?['view_points'];
  final text = biliChaptersToFfmetadata(
    points is List ? points : null,
    durationSeconds,
  );
  // 没有章节是**常态**，不进 missing：那会让九成下载都挂一句没意义的话。
  if (text == null) return null;
  final path = p.join(saveDir, biliChapterScratchName(outBase));
  try {
    await File(path).writeAsString(text);
    return path;
  } catch (_) {
    missing.add('章节：中间文件写不下去，成品不会有章节');
    return null;
  }
}

Future<List<String>> _metadata(
  String bvid,
  BiliMeta? meta,
  BiliConfig cfg,
  String saveDir,
  String outBase,
  BiliAdditionalDeps deps,
  List<String> missing,
) async {
  if (bvid.isEmpty) {
    missing.add('元数据：没有 bvid，取不到稿件信息');
    return const [];
  }
  // nfo 与 json 都以 `view` 为源：Media 上只有标题与 UP 主，正文、分区、发布时间
  // 还得回查一次。nfo 另外还要多一次 tag 接口（`view` 自己不给标签）。
  final view = await deps.signedData('/x/web-interface/wbi/view', {'bvid': bvid});
  return biliWriteMetadata(
    cfg: cfg,
    saveDir: saveDir,
    outBase: outBase,
    view: view,
    partTitle: meta?.partTitle ?? '',
    partIndex: meta?.partTotal ?? 1,
    fetchTags: cfg.metadataFormat == BiliMetadataFormat.nfo
        ? (id) async {
          try {
            // `plainData` 回的**就是 `data` 本体**（一个 `tag_name` 的列表）。
            // 这条稿件没标签时接口直接不给 `data`，`BiliApi` 那边报的是「响应里没有
            // data」—— 那是「没标签」，不是「元数据没拿到」，所以这里吞成空列表，
            // 由 nfo 少写几行 `<tag>` 来表达。
            final data = await deps.plainData(
              '/x/web-interface/view/detail/tag',
              {'bvid': id},
            );
            return biliTagsFromData(data);
          } catch (e) {
            AppLogger.log('BILI', '标签接口没给东西，nfo 按无标签写：$e');
            return const <String>[];
          }
        }
        : null,
  );
}

/// `subtitle_url` 实测可能给的是 `//xxx` 这种**协议相对**写法，直接 GET 会失败。
String _abs(String url) => url.startsWith('//') ? 'https:$url' : url;
