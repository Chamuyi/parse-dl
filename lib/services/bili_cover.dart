/// 封面：B 站图床的后缀缩放语法 + 三次重试。
///
/// `{原图 URL}@.{jpg|png|webp|avif}` 是图床自己认的写法（照参照实现与实测），
/// 所以「换封面格式」不需要本地转码 —— 随包那份 10 MB 的 ffmpeg 也确实不该被
/// 用来干这种事。
///
/// 走 Dart 直连而不是 aria2：一张图几十 KB，用不上分片与续传，
/// 却会撞上「per-task header 被 `--save-session` 明文写盘」那条红线。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/bili_config.dart';
import 'bili_additional.dart';

/// 失败重试次数（参照实现也是 3）。图床偶发 5xx，一次就放弃太脆。
const int kBiliCoverAttempts = 3;

typedef BiliBytesFetch = Future<List<int>> Function(String url);

/// 图床的缩放写法：`https://i0.hdslb.com/x.jpg` + `jpg` → `https://i0.hdslb.com/x.jpg@.jpg`。
String biliCoverUrl(String pic, String suffix) =>
    pic.isEmpty ? pic : '$pic@.$suffix';

/// 取一张封面落盘。返回文件名；一次都没成则返回 null（调用方记进 `missing`）。
///
/// [fetch] 抛错算一次失败（重试），全失败不抛给上层 —— 主产物已经好了，
/// 一张封面取不到不该把收口改判成失败。
Future<String?> biliWriteCover({
  required BiliConfig cfg,
  required String saveDir,
  required String outBase,
  required String pic,
  required BiliBytesFetch fetch,
}) async {
  if (!cfg.saveCover || pic.isEmpty) return null;
  final url = biliCoverUrl(pic, cfg.coverFormat.id);
  List<int>? bytes;
  for (var i = 0; i < kBiliCoverAttempts; i++) {
    try {
      final got = await fetch(url);
      if (got.isNotEmpty) {
        bytes = got;
        break;
      }
    } catch (_) {
      // 最后一次以外都当作「再试一次」
    }
  }
  if (bytes == null) return null;
  final name = biliAdditionalName(
    base: outBase,
    qualifier: '封面',
    ext: cfg.coverFormat.id,
  );
  await File(p.join(saveDir, name)).writeAsBytes(bytes);
  return name;
}
