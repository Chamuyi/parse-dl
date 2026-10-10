import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'app_logger.dart';
import 'app_paths.dart';

/// 把随包的 `assets/ffmpeg.exe` 释放到磁盘，返回可执行文件路径。
///
/// **照 `aria2.dart` 的 `_ensureSidecar` 同一套做法**：Flutter 的 assets 是打进
/// bundle 的，不能直接执行，必须先落盘；放 [AppPaths.configDir]（= exe 同级的
/// `userdata`）与 `aria2c.exe` 做邻居，升级时一起被带走。
///
/// 已存在就不重复释放 —— 这份构建 10 MB 级，每次启动都写一遍太亏。
/// 但它**不做版本自检**：换了新的 `assets/ffmpeg.exe` 得先手动删掉
/// `userdata\ffmpeg.exe` 才会生效（与 aria2c 同一个已知脾气）。
Future<String> ensureBiliFfmpeg() async {
  final dir = AppPaths.configDir;
  final target = File('${dir.path}\\ffmpeg.exe');
  if (!await target.exists()) {
    try {
      final data = await rootBundle.load('assets/ffmpeg.exe');
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      AppLogger.log(
        'BILI',
        'ffmpeg 已释放到 ${target.path}（${data.lengthInBytes} 字节）',
      );
    } catch (e) {
      AppLogger.log('BILI', '释放随包 ffmpeg 失败：$e');
      rethrow;
    }
  }
  return target.path;
}

/// 随包 ffmpeg 在不在、能不能跑一句 `-version`。
///
/// 给设置页那句「合并不可用」提示用。**不联网、不下载**，纯本地探测。
Future<bool> biliFfmpegAvailable() async {
  try {
    final path = await ensureBiliFfmpeg();
    final r = await Process.run(path, ['-version']);
    return r.exitCode == 0;
  } catch (e) {
    AppLogger.log('BILI', 'ffmpeg 探测失败：$e');
    return false;
  }
}
