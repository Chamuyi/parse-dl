import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_paths.dart';

/// 应用日志。
///
/// 由「设置 → 应用 → 记录日志文件」开关控制。开启后把 **X API 请求/错误**
/// 与 **aria2 事件**写入 `<数据目录>\logs\parse-dl-YYYY-MM-DD.log`
/// （数据目录由 [AppPaths] 决定：默认是 exe 同级的 `userdata`，
/// 安装目录不可写时才回退到系统应用数据目录）。
///
/// 设计要点：
/// - 全静态，任何地方 `AppLogger.log(tag, msg)` 即可，无需注入依赖
/// - 开关关闭时是**零开销**（直接 return，不建目录不开文件）
/// - 按天切文件，跨天自动重新打开
/// - 单个文件超过 [kMaxLogBytes] 就轮转（见 [kMaxLogBackups]）
/// - 连续相同的行折叠成一行 + `上一行重复 ×N`
/// - 写入走 `IOSink` 缓冲，不阻塞调用方
///
/// 为什么要加轮转与压缩：装机版 2026-10-02 开机后 3 分 17 秒写了
/// 12,396 行（全天 8.1 MB / 51,443 行），整机在高负载里死掉时，这个没有任何
/// 上限的单文件还在一路变大 —— 既挤磁盘，又把真正有用的那几行冲掉了。
class AppLogger {
  AppLogger._();

  /// 单个日志文件的大小上限。
  ///
  /// 2 MB 的取值理由：实测本机一行约 160 字节（含中文路径），2 MB ≈ 1.2 万行
  /// ≈ 死机那次会话的全部输出 —— 也就是「一次事故看得完整」的下限；
  /// 再大用户用记事本打开就卡了。
  static const int kMaxLogBytes = 2 * 1024 * 1024;

  /// 日志文件名前缀（`parse-dl-YYYY-MM-DD.log`）。
  static const String kFilePrefix = 'parse-dl';

  /// 轮转后保留几份历史（`parse-dl-日期.log.1` 最新）。
  /// 3 份 + 当前文件 = 单日上限 8 MB，够回看三次轮转之前的现场。
  static const int kMaxLogBackups = 3;

  /// 轮转在飞时先排队的行数上限（轮转卡住也不能无限吃内存）。
  static const int kMaxPendingLines = 500;

  static bool _enabled = false;
  static Directory? _dir;
  static IOSink? _sink;
  static String? _currentDay;

  /// 已经交给 sink 的字节数（轮转判据）
  static int _bytes = 0;
  static bool _rotating = false;
  static final List<String> _pending = [];

  /// 重复行折叠：上一条写入的「[tag] 正文」（不含时间戳）与它被重复的次数
  static String? _lastKey;
  static int _repeat = 0;

  static bool get enabled => _enabled;

  /// 日志目录（未初始化时返回 null）
  static String? get dirPath => _dir?.path;

  /// 日志目录：数据目录下的 `logs\`（由 [AppPaths] 统一决定，
  /// 与 `settings.json` 同处一个数据目录，用户找得到）
  static Future<Directory> logsDirectory() async => AppPaths.logsDir;

  /// 最近一次「日志开不起来」的原因（`null` = 正常）。
  ///
  /// 以前开关切到「开」但建目录失败时，只是 `_enabled=false`，界面上开关
  /// 仍是绿的 —— 用户以为在记日志，回头点「查看日志」只看到「今天还没有
  /// 日志文件」。根 widget 取走并提示一次。
  static String? lastError;

  /// 初始化 / 切换开关。在启动时与设置变更时调用。
  static Future<void> init({required bool enabled}) async {
    lastError = null;
    if (!enabled) {
      _enabled = false;
      _bytes = 0;
      _rotating = false;
      _pending.clear();
      _resetRun();
      await _closeSink();
      return;
    }
    try {
      final dir = await logsDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _dir = dir;
      _enabled = true;
      await _ensureTodayFile();
      log('APP', '日志已启动');
    } catch (e) {
      _enabled = false;
      lastError = '日志开关没能生效：建目录或创建文件失败（$e）';
      debugPrint('AppLogger: 初始化失败：$e');
    }
  }

  /// 写一行日志。开关关闭时立即返回。
  ///
  /// 连续内容相同的行只写第一条，行变化时补一行「上一行重复 ×N」——
  /// 时间戳每行都不同，所以比较的是 `[tag] 正文` 那一段。
  static void log(String tag, String message) {
    if (!_enabled) return;
    final now = DateTime.now();
    final ts = '${_p(now.hour)}:${_p(now.minute)}:${_p(now.second)}'
        '.${now.millisecond.toString().padLeft(3, '0')}';
    final line = '[$ts][$tag] $message';
    debugPrint(line);

    if (_dayOf(now) != _currentDay) {
      unawaited(_ensureTodayFile());
      return; // 这一行等文件打开后再写会丢顺序，直接跳过
    }

    final key = '[$tag] $message';
    if (key == _lastKey) {
      _repeat++;
      return;
    }
    if (_repeat > 0) {
      _emit('[$ts][DUP] 上一行重复 ×$_repeat');
    }
    _lastKey = key;
    _repeat = 0;
    _emit(line);
  }

  /// 真正交给 sink，并在这里判大小上限。
  ///
  /// 轮转在飞的时候先排队（`_sink` 已经关了，直接写会丢），轮转结束补写，
  /// 顺序不变。
  static void _emit(String line) {
    if (_rotating) {
      if (_pending.length < kMaxPendingLines) _pending.add(line);
      return;
    }
    final s = _sink;
    if (s == null) return;
    try {
      s.writeln(line);
    } catch (e) {
      debugPrint('AppLogger: 写入失败：$e');
      return;
    }
    _bytes += utf8.encode(line).length + 1; // +1 是 writeln 的换行
    if (_bytes >= kMaxLogBytes) unawaited(_rotate());
  }

  /// 轮转：当前文件让位成 `.log.1`，最老的 `.log.{kMaxLogBackups}` 删掉。
  ///
  /// 失败也要继续记日志（出问题的正是最需要日志的时候）：改名失败就退回
  /// 「接着往原文件追加」，并把原因落到 [lastError] 让界面提示一次。
  static Future<void> _rotate() async {
    final dir = _dir;
    final day = _currentDay;
    if (dir == null || day == null || _rotating) return;
    _rotating = true;
    final base =
        '${dir.path}${Platform.pathSeparator}$kFilePrefix-$day.log';
    await _closeSink(); // Windows 上不先关掉句柄就改不了名
    _bytes = 0;
    Object? rotateError;
    try {
      for (var i = kMaxLogBackups; i >= 1; i--) {
        final src = File('$base.$i');
        if (!await src.exists()) continue;
        if (i == kMaxLogBackups) {
          await src.delete();
        } else {
          await src.rename('$base.${i + 1}');
        }
      }
      final cur = File(base);
      if (await cur.exists()) await cur.rename('$base.1');
    } catch (e) {
      rotateError = e;
    }
    try {
      _sink = File(base).openWrite(
          mode: rotateError == null ? FileMode.write : FileMode.append);
      lastError = rotateError == null
          ? null
          : '日志文件没能轮转（改名或删历史失败：$rotateError），'
              '已继续写入原文件，单文件可能超过 ${kMaxLogBytes ~/ (1024 * 1024)} MB';
    } catch (e) {
      _sink = null;
      lastError = '日志轮转后没能重新打开日志文件（$e），日志已停止写入';
    }
    _rotating = false;
    final queued = List<String>.of(_pending);
    _pending.clear();
    for (final l in queued) {
      _emit(l);
    }
  }

  /// 返回当前日志文件路径（用于 UI 展示 / 打开）
  static Future<String> currentFilePath() async {
    final dir = await logsDirectory();
    return '${dir.path}${Platform.pathSeparator}'
        '$kFilePrefix-${_dayOf(DateTime.now())}.log';
  }

  static Future<void> _ensureTodayFile() async {
    final dir = _dir;
    if (dir == null) return;
    final day = _dayOf(DateTime.now());
    if (day == _currentDay && _sink != null) return;
    await _closeSink();
    _currentDay = day;
    _bytes = 0;
    _resetRun();
    try {
      final f = File(
          '${dir.path}${Platform.pathSeparator}$kFilePrefix-$day.log');
      _sink = f.openWrite(mode: FileMode.append);
    } catch (e) {
      debugPrint('AppLogger: 打开日志文件失败：$e');
    }
  }

  /// 折叠状态清零（新文件 / 新的一天 / 重新开关日志）
  static void _resetRun() {
    _lastKey = null;
    _repeat = 0;
  }

  /// 单测用：把缓冲里的行真正落盘，好让断言读文件内容。
  @visibleForTesting
  static Future<void> flushForTest() async {
    final s = _sink;
    if (s == null) return;
    try {
      await s.flush();
    } catch (_) {}
  }

  /// 单测用：轮转判据用的字节数。
  @visibleForTesting
  static int get writtenBytesForTest => _bytes;

  static Future<void> _closeSink() async {
    final s = _sink;
    _sink = null;
    if (s == null) return;
    try {
      await s.flush();
      await s.close();
    } catch (_) {}
  }

  static Future<void> dispose() => _closeSink();

  static String _dayOf(DateTime d) =>
      '${d.year}-${_p(d.month)}-${_p(d.day)}';

  static String _p(int v) => v.toString().padLeft(2, '0');
}
