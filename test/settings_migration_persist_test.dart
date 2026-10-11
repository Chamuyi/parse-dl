import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/settings_store.dart';

/// 钉住「一次性迁移必须**落盘**」这件事。
///
/// 为什么值得单独一个文件：迁移函数写对 ≠ 用户看得到效果。`Settings.decode`
/// 只在**内存对象**上把旧默认值升级成新默认，盘上仍是旧串 —— 于是下次启动
/// 又迁一遍，而用户只要不改设置就永远看不到新默认。2026-10-11 真机撞上过：
/// `migrateBiliTemplate` 单测全绿，盘上却还是
/// `<P%P%->%PART_TITLE%-%QUALITY%-%CODEC%%EXT%`。
///
/// 这正是 `project-downloader-settings-defaults-trap` 那条教训的落地形式：
/// **改默认值必须同时想迁移，而迁移必须落盘。**
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('settings_migrate_');
    await AppPaths.init(exeDirOverride: tmp, fallbackOverride: tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 设置文件的**真实落点**：`AppPaths.configDir` = `<exeDir>\userdata`。
  ///
  /// 一开始我把文件写在了 `tmp\` 根下，而 store 读的是 `tmp\userdata\` ——
  /// 于是它读不到文件、按全新默认启动，测试红得莫名其妙。
  /// 路径这件事必须问 `AppPaths`，不能自己拼。
  File settingsFile() =>
      File('${AppPaths.configDir.path}\\settings.json');

  /// 造一份「盘上存着旧默认模板」的配置。
  void writeLegacy() {
    final s = Settings();
    s.bili.fileNameTemplate = kBiliLegacyFileNameTemplate;
    s.bili.dirTemplate = kBiliDefaultDirTemplate;
    settingsFile().writeAsStringSync(s.encode());
  }

  test('旧默认模板：load() 之后盘上必须变成新默认（回写）', () async {
    writeLegacy();
    expect(settingsFile().readAsStringSync(), contains(kBiliLegacyFileNameTemplate),
        reason: '前置条件：盘上确实是旧串');

    final store = SettingsStore();
    await store.load();

    // 内存里已是新值
    expect(store.settings.bili.fileNameTemplate, kBiliDefaultFileNameTemplate);
    // **盘上也必须是新值** —— 少了回写这一步，这条就红
    expect(
      settingsFile().readAsStringSync(),
      contains(kBiliDefaultFileNameTemplate),
      reason: '迁移只改了内存没落盘 —— 下次启动会再迁一遍，用户永远看不到新默认',
    );
    expect(settingsFile().readAsStringSync(),
        isNot(contains(kBiliLegacyFileNameTemplate)));
  });

  test('用户自己改过的模板：load() 不许动它，也不许触发回写', () async {
    const mine = '%BVID%_%PART_TITLE%%EXT%';
    final s = Settings();
    s.bili.fileNameTemplate = mine;
    settingsFile().writeAsStringSync(s.encode());
    final before = settingsFile().readAsStringSync();

    final store = SettingsStore();
    await store.load();

    expect(store.settings.bili.fileNameTemplate, mine);
    expect(settingsFile().readAsStringSync(), before,
        reason: '没有迁移要落盘时，文件应当逐字不变（回写判据不能误报）');
  });

  test('已经是新默认：幂等，不产生多余回写', () async {
    final s = Settings();
    s.bili.fileNameTemplate = kBiliDefaultFileNameTemplate;
    settingsFile().writeAsStringSync(s.encode());
    final before = settingsFile().readAsStringSync();

    final store = SettingsStore();
    await store.load();

    expect(store.settings.bili.fileNameTemplate, kBiliDefaultFileNameTemplate);
    expect(settingsFile().readAsStringSync(), before);
  });
}
