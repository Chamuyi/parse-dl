import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import 'app_paths.dart';

/// 小数据持久化：X 的登录 cookie、搜索历史、自动执行名单预设、queryId 缓存。
///
/// 文件是 [AppPaths.configDir]（默认 exe 同级的 `userdata\`）下的 [kFileName]，
/// 和 `settings.json` 同目录 —— **数据跟着软件走**。不用现成插件是因为
/// `shared_preferences` 在 Windows 上把路径写死成
/// `%APPDATA%\<exe 版本资源里的 CompanyName>\<ProductName>\`，那一处不跟着软件走。
///
/// 日志只记键名，绝不记值（cookie 是登录凭据）。
class AppPrefs {
  AppPrefs._(this._file, this._values);

  /// 偏好文件名
  static const String kFileName = 'prefs.json';

  final File? _file;
  final Map<String, Object> _values;

  static AppPrefs? _instance;

  /// 单测用的内存替身：设了它就不碰磁盘。
  static Map<String, Object>? _mock;

  /// 取实例（首次调用时读盘）。
  static Future<AppPrefs> getInstance() async {
    final cur = _instance;
    if (cur != null) return cur;

    final mock = _mock;
    if (mock != null) {
      return _instance = AppPrefs._(null, Map<String, Object>.of(mock));
    }

    final file =
        File('${AppPaths.configDir.path}${Platform.pathSeparator}$kFileName');
    final prefs = AppPrefs._(file, <String, Object>{});

    if (await file.exists()) {
      String? source;
      try {
        source = await file.readAsString();
      } catch (e) {
        // 读不出来（被占用、权限、甚至是个同名目录）不能把整个应用带崩。
        AppLogger.log('PREFS', '${file.path} 读不出来（$e）：先留原件，再按空偏好启动');
        await prefs._reserveUnreadable(file);
      }
      final loaded = source == null ? null : _tryDecode(source);
      if (loaded != null) {
        prefs._values.addAll(loaded);
      } else if (source != null) {
        await prefs._reserveUnreadable(file);
      }
    }
    return _instance = prefs;
  }

  /// 读一个键。类型不对就当没有。
  String? getString(String key) {
    final v = _values[key];
    return v is String ? v : null;
  }

  List<String>? getStringList(String key) {
    final v = _values[key];
    return v is List ? v.whereType<String>().toList() : null;
  }

  /// 写一个键。返回**是否真的落了盘** —— 假成功（界面说存了、重启就没了）
  /// 是最难自己发现的一类问题，所以调用方要拿这个返回值决定说什么。
  Future<bool> setString(String key, String value) async {
    _values[key] = value;
    return _flush(key);
  }

  Future<bool> setStringList(String key, List<String> value) async {
    _values[key] = value;
    return _flush(key);
  }

  Future<bool> remove(String key) async {
    if (_values.remove(key) == null) return true;
    return _flush(key);
  }

  Future<bool> _flush([String? key]) async {
    final f = _file;
    if (f == null) return true; // 内存替身
    try {
      await f.writeAsString(jsonEncode(_values), flush: true);
      return true;
    } catch (e) {
      AppLogger.log('PREFS',
          '偏好没能写盘（${f.path}${key == null ? "" : "，键 $key"}）：$e —— 重启后会丢');
      debugPrint('AppPrefs: 写盘失败：$e');
      return false;
    }
  }

  /// 读不出来的文件**不能**让下一次写入覆盖它（里面可能是用户唯一一份登录态），
  /// 先改名留一份原件。
  Future<void> _reserveUnreadable(File f) async {
    final bak =
        File('${f.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}');
    try {
      await f.rename(bak.path);
      AppLogger.log('PREFS',
          '${f.path} 读不出来，原件已留成 ${bak.path}（直接写回去会把里面的登录态冲掉）');
    } catch (e) {
      AppLogger.log('PREFS', '${f.path} 读不出来，且没能留出备份（$e）；下次写盘会覆盖它');
    }
  }

  static Map<String, Object>? _tryDecode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) return null;
      final out = <String, Object>{};
      decoded.forEach((k, v) {
        if (k is String && v != null) out[k] = v;
      });
      return out;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void setMockInitialValues(Map<String, Object> values) {
    _mock = values;
    _instance = null;
  }

  /// 单测用：清掉单例与内存替身（临时目录换一个接一个，缓存的实例会串味）。
  @visibleForTesting
  static void resetForTest() {
    _instance = null;
    _mock = null;
  }
}
