/// 章节：`x/player/wbi/v2` 的 `data.view_points[]` → ffmpeg 的 ffmetadata 文本。
///
/// **合并层的实测结论（2026-10-10，取证 Q6d）决定了这里的形状**：章节是被
/// matroska/mp4 muxer **从那个输入本身**吸进成品的 —— 给不给 `-map_metadata`
/// 都一样出章节，而给了反而会把成品的全局 metadata 来源换成 ffmetadata 那一路。
/// 所以这一族只产一个「喂给 `-i` 的文件」，协调器不加 `-map_metadata`。
///
/// 两条必须守住的边界：
///  * `view_points` 空是**常态**（绝大多数稿件没有分段章节）。这时返回 null，
///    合并命令一个参数都不许多带，更不能因为「没章节」把合并判成失败。
///  * 末段的 `to` 实测可能是 0。用总时长兜底；总时长也没有就跳过那一段 ——
///    而不是写出一条 `END=0` 的章节（那会让成品里出现一条 0 秒的章节）。
library;

import '../models/bili_config.dart';

/// 章节文件的固定命名前缀由调用方拼（它是中间文件，不是交付物）。
String biliChapterScratchName(String outBase) => '.$outBase.chapters.ffmeta';

/// 渲染 ffmetadata。没有可用章节时返回 null（= 不该多带一个输入）。
///
/// [durationSeconds] 用于给末段兜底与**夹住越界的 END**：MP4 在章节超出媒体
/// 实际时长时会告警（`Application provided duration ... is invalid`），
/// 那是用户看得见的红字，不能当噪声忽略。
String? biliChaptersToFfmetadata(
  List<dynamic>? viewPoints,
  int durationSeconds,
) {
  if (viewPoints == null || viewPoints.isEmpty) return null;
  final points = [for (final e in viewPoints) if (e is Map) e];
  final capMs = durationSeconds > 0 ? durationSeconds * 1000 : null;
  final sb = StringBuffer(';FFMETADATA1')..writeln();
  var wrote = 0;
  for (var i = 0; i < points.length; i++) {
    // 接口这两个字段的单位是**秒**（参照实现 `chapter.py` 也是先乘 1000 再写），
    // 而 TIMEBASE 是 1/1000 —— 少乘一次就是一份缩到千分之一、全长四秒的章节。
    final startSec = _int(points[i]['from']);
    var endSec = _int(points[i]['to']);
    if (endSec <= startSec) {
      // 末段常给 0：先试下一段的起点，没有下一段才用总时长；都定不出来就跳过这一段
      //（写出一条 END=0 的章节等于在成品里塞一条 0 秒的章节）。
      endSec = i + 1 < points.length ? _int(points[i + 1]['from']) : durationSeconds;
    }
    final startMs = startSec * 1000;
    var endMs = endSec * 1000;
    if (capMs != null) {
      if (endMs > capMs) endMs = capMs;
      // 贴着片尾的那一格往前挪 1ms：与总时长相等的 END 一样会让 mp4 muxer 告警。
      if (endMs >= capMs) endMs = capMs - 1;
    }
    if (endMs <= startMs) continue;
    final title = (points[i]['content'] as String?)?.trim() ?? '';
    sb
      ..writeln()
      ..writeln('[CHAPTER]')
      ..writeln('TIMEBASE=1/1000')
      ..writeln('START=$startMs')
      ..writeln('END=$endMs')
      ..writeln('title=${_ffmetaValue(title.isEmpty ? '章节 ${wrote + 1}' : title)}');
    wrote++;
  }
  return wrote == 0 ? null : sb.toString();
}

int _int(Object? v) => (v as num?)?.toInt() ?? 0;

/// ffmetadata 的值里 `= ; # \` 与换行都要转义（照参照实现的那套字符集来）。
String _ffmetaValue(String v) {
  final sb = StringBuffer();
  for (final unit in v.runes) {
    final char = String.fromCharCode(unit);
    if ('=;#\\\n'.contains(char)) {
      sb.write(unit == 10 ? r'\N' : '\\$char');
    } else {
      sb.write(char);
    }
  }
  return sb.toString();
}

/// 该不该去做章节这一族（关了就一个请求都不该为它发）。
bool biliChapterWanted(BiliConfig cfg) => cfg.saveChapter;
