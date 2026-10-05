import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/app_logger.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/app_prefs.dart';

/// `AppPrefs`（登录 cookie、搜索历史等小数据的自建存储）的行为回归。
///
/// 钉住四件事：
/// 1. 数据落在 [AppPaths] 给的数据目录里，和 `settings.json` 同目录；
/// 2. 写不进去必须返回 `false` —— 界面据此才不能说「已保存」（假成功最难自己发现）；
/// 3. 读不出来的文件**不被覆盖**（写一半截断是真实场景），改名留原件；
/// 4. 日志只记出问题的路径，**绝不记值**（cookie 是登录凭据）。
void main() {
  late Directory exe;
  late Directory fallback;

  File prefsFile() => File(
      '${AppPaths.configDir.path}${Platform.pathSeparator}${AppPrefs.kFileName}');

  setUp(() async {
    AppPrefs.resetForTest();
    exe = await Directory.systemTemp.createTemp('app_prefs_');
    fallback = await Directory.systemTemp.createTemp('app_prefs_fb_');
    await AppPaths.init(exeDirOverride: exe, fallbackOverride: fallback);
  });

  tearDown(() async {
    await AppLogger.init(enabled: false);
    AppPrefs.resetForTest();
    for (final d in [exe, fallback]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  group('读写', () {
    test('写在数据目录的 prefs.json 里', () async {
      final p = await AppPrefs.getInstance();
      expect(await p.setString('app_state.cookie', 'ct0=deadbeef'), isTrue);
      final f = prefsFile();
      expect(await f.exists(), isTrue);
      expect(f.path.startsWith(AppPaths.configDir.path), isTrue);
      final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      expect(raw['app_state.cookie'], 'ct0=deadbeef');
    });

    test('重启后读得回来，列表也在', () async {
      final p = await AppPrefs.getInstance();
      await p.setString('auto_task_presets', '[{"id":"1"}]');
      await p.setStringList('app_state.search_history', ['abc', '中文']);
      AppPrefs.resetForTest();

      final again = await AppPrefs.getInstance();
      expect(again.getString('auto_task_presets'), '[{"id":"1"}]');
      expect(again.getStringList('app_state.search_history'), ['abc', '中文']);
    });

    test('remove 掉的键重启后不会回来', () async {
      final p = await AppPrefs.getInstance();
      await p.setString('app_state.cookie', 'ct0=1');
      expect(await p.remove('app_state.cookie'), isTrue);
      AppPrefs.resetForTest();

      expect((await AppPrefs.getInstance()).getString('app_state.cookie'), isNull);
    });

    test('写不进去就返回 false，不假装存住了', () async {
      final p = await AppPrefs.getInstance();
      // prefs.json 的位置换成同名目录 → 写盘必然失败（实测 File.writeAsString 抛
      // PathAccessException，且 File.existsSync 对目录返回 false）
      await Directory(prefsFile().path).create();
      expect(await p.setString('app_state.cookie', 'ct0=1'), isFalse,
          reason: '界面据此才能不说「已保存」');
    });
  });

  group('坏文件', () {
    test('解析不出来时改名留原件，不被下一次写入覆盖', () async {
      const broken = '{"app_state.cookie": "ct0=secret';
      await prefsFile().writeAsString(broken, flush: true);

      final p = await AppPrefs.getInstance();
      expect(p.getString('app_state.cookie'), isNull);
      expect(await prefsFile().exists(), isFalse, reason: '原路径已让出来，坏文件另有备份');

      final backups = AppPaths.configDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.unreadable-'))
          .toList();
      expect(backups, hasLength(1));
      expect(await backups.single.readAsString(), broken);

      await p.setString('app_state.cookie', 'ct0=2');
      expect(await prefsFile().readAsString(), contains('ct0=2'));
      expect(await backups.single.readAsString(), broken,
          reason: '补一份登录凭据不能把上一份冲掉');
    });

    test('prefs.json 是个同名目录时不崩，按空偏好启动', () async {
      await Directory(prefsFile().path).create();
      final p = await AppPrefs.getInstance();
      expect(p.getString('app_state.cookie'), isNull);
      // 挪不动就明说：写盘照样失败，不能假装存住了
      expect(await p.setString('app_state.cookie', 'ct0=1'), isFalse);
    });
  });

  test('日志记出问题的路径，不记 cookie 的值', () async {
    await AppLogger.init(enabled: true);
    await prefsFile().writeAsString('{"app_state.cookie": "ct0=超级机密', flush: true);

    final p = await AppPrefs.getInstance();
    await p.setStringList('app_state.search_history', ['随便一个词']);
    await AppLogger.flushForTest();

    final text = AppPaths.logsDir
        .listSync()
        .whereType<File>()
        .map((f) => f.readAsStringSync())
        .join('\n');
    expect(text, contains(AppPrefs.kFileName), reason: '正控制：出问题的路径确实记了');
    expect(text, isNot(contains('超级机密')), reason: '值进日志就是凭据泄漏');
  });

  test('数据目录里除 prefs.json 与备份外不冒出别的文件', () async {
    final p = await AppPrefs.getInstance();
    await p.setString('x_query_id_cache_v1', '{}');

    expect(
      AppPaths.configDir.listSync().map((e) => e.uri.pathSegments.last),
      [AppPrefs.kFileName],
    );
  });
}
