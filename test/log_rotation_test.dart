import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/app_logger.dart';
import 'package:parse_dl/services/app_paths.dart';

/// 日志的**大小上限 + 轮转**与**连续重复行压缩**。
///
/// 装机版 2026-10-02 那天：开机后 3 分 17 秒写了 12,396 行，全天单个文件
/// 8,039,140 字节 / 51,443 行，而且没有任何上限 —— 系统在最高负载里死机时，
/// 这个文件还在一路变大。轮转管住体积，压缩管住「同一个错刷屏」。
void main() {
  late Directory tmp;

  Future<String> currentPath() async => AppLogger.currentFilePath();
  Future<File> currentFile() async => currentPath().then(File.new);

  /// 单行 64 KB —— 几十行就能越过 2 MB 阈值，测试不必写一万行
  String bigLine(String mark) => '$mark${'x' * (64 * 1024 - mark.length - 24)}';

  Future<void> waitUntil(
    Future<bool> Function() done, {
    String why = '',
    int tries = 600,
  }) async {
    for (var i = 0; i < tries && !await done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(await done(), isTrue, reason: '超时：$why');
  }

  Future<bool> exists(String path) async => File(path).exists();

  Future<String> textOfCurrent() async {
    await AppLogger.flushForTest();
    return (await currentFile()).readAsString();
  }

  List<String> logFiles() {
    final dir = Directory(AppPaths.logsDir.path);
    if (!dir.existsSync()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList()
      ..sort();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jxxzq_logrotate_');
    await AppPaths.init(
        exeDirOverride: tmp, fallbackOverride: tmp);
    await AppLogger.init(enabled: true);
    AppLogger.lastError = null;
  });

  tearDown(() async {
    await AppLogger.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('大小上限与轮转', () {
    test('超过 kMaxLogBytes 就切出 .log.1，当前份重新计', () async {
      final day = await currentPath();
      for (var i = 0; i < 40; i++) {
        AppLogger.log('BULK', bigLine('i$i'));
      }
      await waitUntil(() => exists('$day.1'), why: '没有发生轮转');

      expect(File(day).existsSync(), isTrue, reason: '轮转后要接着写新文件');
      // 阈值同样**不引用常量**：把 kMaxLogBytes 改掉必须让这条红
      final rotatedSize = File('$day.1').lengthSync();
      expect(rotatedSize >= 2 * 1024 * 1024, isTrue,
          reason: '切出去的那份应当已写满到 2 MB 阈值，实际 $rotatedSize');
      expect(rotatedSize < 3 * 1024 * 1024, isTrue,
          reason: '也不该一路涨到远超阈值，实际 $rotatedSize');
      expect(File(day).lengthSync() < AppLogger.kMaxLogBytes, isTrue,
          reason: '当前份必须重新计');
      expect(AppLogger.writtenBytesForTest < AppLogger.kMaxLogBytes, isTrue);
    });

    test('反复超限 → 保留份数不超过 kMaxLogBackups', () async {
      final day = await currentPath();
      for (var round = 0; round < 6; round++) {
        for (var i = 0; i < 40; i++) {
          AppLogger.log('BULK', bigLine('r$round-$i'));
        }
        await waitUntil(() => exists('$day.${(round + 1).clamp(1, 3)}'),
            why: '第 $round 轮没有轮转');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      final names = logFiles();
      // 断言里**不能**引用 kMaxLogBackups —— 那样把保留份数改成 99 也照样绿，
      // 等于什么都没钉住。这里按出厂策略写死：当前 1 份 + 历史 3 份。
      expect(File('$day.4').existsSync(), isFalse,
          reason: '第 4 份历史不该存在（出厂策略只留 3 份）；实际：$names');
      expect(names.length, 4, reason: '轮转 6 次后应当正好是 1 份在写 + 3 份历史：$names');
      expect(names.where((n) => n.endsWith('.log')).length, 1,
          reason: '当前份只能有一份（实际：$names）');
      expect(names.every((n) => n.startsWith('${AppLogger.kFilePrefix}-')), isTrue,
          reason: 'logs 目录里不该冒出别的文件（$names）');
    });

    test('轮转在飞时到达的行不丢（排队后补写进新份）', () async {
      final day = await currentPath();
      for (var i = 0; i < 40; i++) {
        AppLogger.log('BULK', bigLine('q$i'));
      }
      // 轮转还没结束就接着写 —— 这几行进队列
      const marker = '轮转期间的行';
      AppLogger.log('BULK', marker);
      AppLogger.log('BULK', marker);

      await waitUntil(() => exists('$day.1'), why: '没有轮转');
      await waitUntil(() async => (await textOfCurrent()).contains(marker),
          why: '排队的行被丢掉了');
      expect(await textOfCurrent(), contains(marker));
    });
  });

  group('连续重复行压缩', () {
    test('同样的行只留第一条，行变化时补一行「上一行重复 ×N」', () async {
      AppLogger.log('ARIA2', '下载完成 gid=abc');
      for (var i = 0; i < 5; i++) {
        AppLogger.log('ARIA2', '下载完成 gid=abc');
      }
      AppLogger.log('ARIA2', '开始下载 gid=next');
      final text = await textOfCurrent();

      expect('下载完成 gid=abc'.allMatches(text).length, 1,
          reason: '5 条重复只能留 1 条');
      expect(text, contains('上一行重复 ×5'));
      expect(
          text
              .split('\n')
              .where((l) => l.contains('[ARIA2]') || l.contains('[DUP]'))
              .length,
          3,
          reason: '首条 + 压缩行 + 下一条（另有启动时那行 [APP]，不计）');
    });

    test('时间戳不同也算重复（判据是 tag + 正文，不是整行）', () async {
      AppLogger.log('XAPI', 'rate limited');
      await Future<void>.delayed(const Duration(milliseconds: 3));
      AppLogger.log('XAPI', 'rate limited');
      AppLogger.log('XAPI', '换一个请求');
      final text = await textOfCurrent();
      expect('rate limited'.allMatches(text).length, 1);
      expect(text, contains('上一行重复 ×1'));
    });

    test('中间隔了别的行就不算连续重复', () async {
      AppLogger.log('A', '同样的话');
      AppLogger.log('B', '插一句');
      AppLogger.log('A', '同样的话');
      final text = await textOfCurrent();
      expect('同样的话'.allMatches(text).length, 2);
      expect(text, isNot(contains('上一行重复')));
    });

    test('只差一个字符就不算重复（路径类日志每条都不同，压不掉）', () async {
      AppLogger.log('DOWNLOAD', '跳过（文件已存在）：G:\\1\\x\\a.jpg');
      AppLogger.log('DOWNLOAD', '跳过（文件已存在）：G:\\1\\x\\b.jpg');
      final text = await textOfCurrent();
      expect(text, contains('a.jpg'));
      expect(text, contains('b.jpg'));
      expect(text, isNot(contains('上一行重复')));
    });
  });

  group('原有行为不能坏', () {
    test('开关关掉之后一个字都不写', () async {
      AppLogger.log('A', '开关开着时的一行');
      await AppLogger.flushForTest();
      final size = (await currentFile()).lengthSync();
      await AppLogger.init(enabled: false);
      AppLogger.log('A', '开关关掉之后的一行');
      await AppLogger.flushForTest();
      final text = (await currentFile()).readAsStringSync();
      expect(text, contains('开关开着时的一行'));
      expect(text, isNot(contains('开关关掉之后的一行')));
      expect((await currentFile()).lengthSync(), size);
    });

    test('正常开着时 lastError 保持 null（不能把轮转当成报错）', () async {
      for (var i = 0; i < 40; i++) {
        AppLogger.log('BULK', bigLine('e$i'));
      }
      await waitUntil(() async => exists('${await currentPath()}.1'),
          why: '没轮转');
      expect(AppLogger.lastError, isNull);
      expect(AppLogger.enabled, isTrue);
    });

    test('开不起来仍然写 lastError（界面据此报错一次）', () async {
      final logs = AppPaths.logsDir;
      await AppLogger.init(enabled: false);
      // 把 logs 的位置换成一个同名普通文件 → 建目录必然失败
      logs.deleteSync(recursive: true);
      File(logs.path).writeAsStringSync('我不是目录');
      await AppLogger.init(enabled: true);

      expect(AppLogger.enabled, isFalse,
          reason: '开不起来就必须关掉，不能留一个绿开关骗用户说在记日志');
      expect(AppLogger.lastError, isNotNull,
          reason: '这条链路是「开关拨到开、回头却没有日志文件」那类假成功的唯一出口');
    });
  });
}
