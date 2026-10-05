import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_prefs.dart';
import 'x_api.dart';

/// 全局应用状态：登录态、搜索历史、代理设置。
///
/// 本类只持有**会话期**需要的状态，
/// 真正「设置」层面的代理/并发/下载目录放在 `SettingsStore` 里。
class AppState extends ChangeNotifier {
  final XApi api = XApi();

  /// 已登录的 cookie 字符串。
  String _cookie = '';
  String get cookie => _cookie;

  /// 搜索历史（最新在前）。
  List<String> _searchHistory = [];
  List<String> get searchHistory => List.unmodifiable(_searchHistory);

  /// 是否已登录。
  bool get isLoggedIn => _cookie.isNotEmpty;

  AppState._(this._cookie, this._searchHistory);

  static const _kCookieKey = 'app_state.cookie';
  static const _kHistoryKey = 'app_state.search_history';

  /// 从持久化存储还原。
  static Future<AppState> restore() async {
    final prefs = await AppPrefs.getInstance();
    final cookie = prefs.getString(_kCookieKey) ?? '';
    final history = prefs.getStringList(_kHistoryKey) ?? <String>[];

    final s = AppState._(cookie, history);
    s.api.setCookie(cookie);
    return s;
  }

  /// 设置 cookie（登录成功后调用）。
  Future<void> setCookie(String cookie) async {
    _cookie = cookie;
    api.setCookie(cookie);
    notifyListeners();

    final prefs = await AppPrefs.getInstance();
    await prefs.setString(_kCookieKey, cookie);
  }

  /// 清空 cookie（退出登录）。
  Future<void> clearCookie() async {
    _cookie = '';
    api.setCookie('');
    notifyListeners();

    final prefs = await AppPrefs.getInstance();
    await prefs.remove(_kCookieKey);
  }

  /// 添加搜索历史（去重、最多 10 条）。
  Future<void> addSearchHistory(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    _searchHistory = [k, ..._searchHistory.where((s) => s != k)];
    if (_searchHistory.length > 10) {
      _searchHistory = _searchHistory.sublist(0, 10);
    }
    notifyListeners();

    final prefs = await AppPrefs.getInstance();
    await prefs.setStringList(_kHistoryKey, _searchHistory);
  }

  /// 清空搜索历史。
  Future<void> clearSearchHistory() async {
    _searchHistory = [];
    notifyListeners();

    final prefs = await AppPrefs.getInstance();
    await prefs.remove(_kHistoryKey);
  }

  /// 调试用：把整个状态序列化（包含 cookie —— 仅用于本地诊断文件，不要写到日志里）。
  String debugDump() => jsonEncode({
        'cookie': _cookie,
        'history': _searchHistory,
      });
}