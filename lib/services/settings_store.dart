import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/douyin_config.dart';
import '../models/settings.dart';
import 'app_paths.dart';

/// 设置的加载与持久化。
///
/// **存储格式是固定的一种**：
///   结构 `{ "state": { proxy, download, app, appearance }, "version": 3 }`
///   文件名 `settings.json`，落在 [AppPaths.configDir]（= exe 同级的
///   `userdata`），与 `prefs.json`、`download_tasks.json` 同目录）
/// 界面显示的路径、代理、外观全部从这里读。
class SettingsStore extends ChangeNotifier {
  Settings _settings = Settings();
  File? _file;

  Settings get settings => _settings;

  /// 数据目录由 [AppPaths] 统一决定（跟着软件走，不再写 C 盘）
  Future<Directory> _configDir() async => AppPaths.configDir;

  Future<void> load() async {
    try {
      final dir = await _configDir();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final f = File('${dir.path}\\settings.json');
      _file = f;

      if (await f.exists()) {
        final raw = await f.readAsString();
        _settings = Settings.decode(raw);
      } else {
        _settings = Settings();
      }
    } catch (e) {
      debugPrint('读取设置失败，使用默认值: $e');
      _settings = Settings();
    }
    notifyListeners();
  }

  /// 上一次写盘失败的原因（`null` = 正常）。根 widget 取走并提示一次。
  ///
  /// 为什么要专门留这个：设置开关有几十处调用点，逐个加提示不现实；而以前
  /// 写盘失败只 `debugPrint`，用户看到的现象是「开关翻过去了，重启又弹回原值」，
  /// 完全不知道改动没保存。
  String? lastSaveError;

  Future<bool> save() async {
    final f = _file;
    if (f == null) {
      // 只有「没先 load() 就 save()」才会走到这里，属编程错误而不是用户可遇
      // 故障（生产路径 main() 一进来就 load）→ 不通知、不打扰用户。
      debugPrint('SettingsStore.save() 在没有数据文件时被调用');
      return false;
    }
    try {
      await f.writeAsString(_settings.encode());
      return true;
    } catch (e) {
      debugPrint('写入设置失败: $e');
      lastSaveError = '设置没能写入磁盘，重启后会回到旧值：$e';
      notifyListeners();
      return false;
    }
  }

  /// 修改设置的统一入口：改完立刻落盘并通知界面
  Future<void> update(void Function(Settings s) mutate) async {
    mutate(_settings);
    notifyListeners();
    await save();
  }

  // ── 便捷方法 ─────────────────────────────────────────────

  Future<void> setAppearance(void Function(AppearanceSettings a) mutate) =>
      update((s) => mutate(s.appearance));

  Future<void> setDownload(void Function(DownloadSettings d) mutate) =>
      update((s) => mutate(s.download));

  Future<void> setProxy(void Function(ProxySettings p) mutate) =>
      update((s) => mutate(s.proxy));

  Future<void> setDouyin(void Function(DouyinConfig d) mutate) =>
      update((s) => mutate(s.douyin));

  Future<void> setApp(void Function(AppOptions a) mutate) =>
      update((s) => mutate(s.app));
}

/// 用 jsonEncode 的默认实现保证中文不被转义
String prettyJson(Object o) => const JsonEncoder.withIndent('  ').convert(o);
