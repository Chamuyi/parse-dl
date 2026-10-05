import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/app_paths.dart';

/// 数据目录决策的测试。
///
/// 规则：数据跟着软件走 —— 优先 `exe 同级\userdata`，
/// 安装目录不可写时回退到系统应用数据目录并标记。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('apppaths_test_');
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory dir(String name) =>
      Directory('${tmp.path}${Platform.pathSeparator}$name');
  File file(String path) => File(path);

  group('plan：目录选择是纯决策，可注入可写性', () {
    test('安装目录可写 → root = exe 同级 userdata，不回退', () {
      final exe = dir('app')..createSync(recursive: true);
      final fb = dir('fallback')..createSync(recursive: true);

      final p = AppPaths.plan(
        exeDir: exe,
        fallbackDir: fb,
        canWrite: (_) => true,
      );

      expect(p.root.path,
          '${exe.path}${Platform.pathSeparator}${AppPaths.kDataDirName}');
      expect(p.fallback, isFalse);
      expect(p.fallbackReason, isNull);
    });

    test('安装目录不可写 → 回退到系统应用数据目录，并带原因', () {
      final exe = dir('app')..createSync(recursive: true);
      final fb = dir('fallback')..createSync(recursive: true);

      final p = AppPaths.plan(
        exeDir: exe,
        fallbackDir: fb,
        canWrite: (_) => false,
      );

      expect(p.root.path, fb.path);
      expect(p.fallback, isTrue);
      expect(p.fallbackReason, isNotNull);
      expect(p.fallbackReason, contains('不可写'));
    });

    test('只有 exe 同级候选可写时才用它（回退目录不参与竞争）', () {
      final exe = dir('app')..createSync(recursive: true);
      final fb = dir('fallback')..createSync(recursive: true);
      var asked = 0;

      AppPaths.plan(
        exeDir: exe,
        fallbackDir: fb,
        canWrite: (_) {
          asked++;
          return true;
        },
      );

      expect(asked, 1, reason: '可写时不应该再去探测回退目录');
    });
  });

  group('init：真实 IO 路径', () {
    test('可写环境 → 建出 userdata，configDir/logsDir/webviewDir 都在 exe 同级', () async {
      final exe = dir('app')..createSync(recursive: true);
      final fb = dir('fallback')..createSync(recursive: true);

      await AppPaths.init(exeDirOverride: exe, fallbackOverride: fb);

      expect(AppPaths.ready, isTrue);
      expect(AppPaths.usingFallback, isFalse);
      expect(AppPaths.root.existsSync(), isTrue);
      expect(AppPaths.configDir.path, AppPaths.root.path);
      expect(AppPaths.logsDir.path,
          '${AppPaths.root.path}${Platform.pathSeparator}logs');
      expect(AppPaths.webviewDir.path,
          '${AppPaths.root.path}${Platform.pathSeparator}webview');
      expect(AppPaths.root.path, contains(AppPaths.kDataDirName));
    });

    test('探测文件不会留在数据目录里', () async {
      final exe = dir('app')..createSync(recursive: true);
      final fb = dir('fallback')..createSync(recursive: true);

      await AppPaths.init(exeDirOverride: exe, fallbackOverride: fb);

      final leftovers = AppPaths.root
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .where((n) => n.contains('probe'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('不可写环境 → root 就是回退目录，且 usingFallback 带原因', () async {
      final exe = dir('app')..createSync(recursive: true);
      final fb = dir('fallback')..createSync(recursive: true);

      // 把 exe 同级的 userdata 位置占成一个文件 → 建目录必然失败
      file('${exe.path}${Platform.pathSeparator}${AppPaths.kDataDirName}')
          .writeAsStringSync('我不是目录');

      await AppPaths.init(exeDirOverride: exe, fallbackOverride: fb);

      expect(AppPaths.usingFallback, isTrue,
          reason: '装进 Program Files 又非管理员时，数据必须落到可写的地方并说明原因');
      expect(AppPaths.root.path, fb.path);
      expect(AppPaths.root.existsSync(), isTrue);
      expect(AppPaths.fallbackReason, contains('不可写'));
    });
  });
}
