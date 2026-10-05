import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'app_prefs.dart';

import '../models/download_filter.dart';
import 'app_state.dart';
import 'creation_task_store.dart';
import 'homepage_store.dart';

/// 自动执行：批量处理一组用户 ID，逐个串行执行「加载用户 → 创建下载任务」。
///
/// **关键不变量：**
/// 1. 所有状态都在 ChangeNotifier 里 —— 切走页面不丢进度。
/// 2. 停止 / 暂停标志放在实例上（不是局部变量），让循环在切页时仍可被控制。
/// 3. 每次点「开始」递增 runId，UI 用它把分页重置回 1。
///
/// **注意职责边界**（与原版一致）：这里只负责「把用户逐个解析出来并登记创建任务」，
/// **不做翻页、不直接投 aria2** —— 那是 [CreationTaskStore] 的事。
/// 所以一行的状态会很快变成「已加入下载队列」，真正的下载进度在下载管理页看。
class AutoTaskStore extends ChangeNotifier {
  final AppState appState;
  final HomepageStore homepageStore;
  final CreationTaskStore creationTasks;

  AutoTaskStore({
    required this.appState,
    required this.homepageStore,
    required this.creationTasks,
  });

  // ── 输入 ─────────────────────────────────────────────────
  String _rawText = '';
  String _fileName = '';
  int _intervalSec = 3;
  int _timeoutSec = 120;
  bool _skipOnError = true;

  // ── 名单预设（持久化） ────────────────────────────────────
  /// 用户保存的「历史名单」。每条：{name, content, createdAt}
  /// 持久化到 AppPrefs（key="auto_task_presets"）
  List<PresetEntry> _presets = [];
  List<PresetEntry> get presets => List.unmodifiable(_presets);

  /// 当前选中的预设 id（UI 用它高亮列表项；null 表示当前内容未保存为预设）
  String? _activePresetId;
  String? get activePresetId => _activePresetId;

  String get rawText => _rawText;
  String get fileName => _fileName;
  int get intervalSec => _intervalSec;
  int get timeoutSec => _timeoutSec;
  bool get skipOnError => _skipOnError;

  // ── 执行态 ───────────────────────────────────────────────
  final List<AutoTaskItem> _list = [];
  bool _running = false;
  bool _paused = false;
  int _runId = 0;

  List<AutoTaskItem> get list => List.unmodifiable(_list);
  bool get running => _running;
  bool get paused => _paused;
  int get runId => _runId;

  // ── 暂停/停止标志 ─────────────────────────────────────────
  // 切走页面时循环仍在跑 —— 这两个字段让它能继续/中止。
  bool _stopFlag = false;
  bool _pauseFlag = false;

  // ── 设置器 ───────────────────────────────────────────────

  void setRawText(String v) {
    _rawText = v;
    if (_fileName.isNotEmpty) _fileName = '';
    notifyListeners();
  }

  void setFileName(String v) {
    _fileName = v;
    notifyListeners();
  }

  // ── 预设操作 ────────────────────────────────────────────

  /// 从 AppPrefs 加载保存的名单预设
  Future<void> loadPresets() async {
    try {
      final prefs = await AppPrefs.getInstance();
      final raw = prefs.getString('auto_task_presets');
      if (raw == null || raw.isEmpty) {
        _presets = [];
        notifyListeners();
        return;
      }
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      _presets = list.map(PresetEntry.fromJson).toList();
      notifyListeners();
    } catch (e) {
      debugPrint('loadPresets failed: $e');
    }
  }

  /// 把当前 rawText 保存为预设
  /// 保存为预设。**返回 ok/entry 而不是可空 entry**：以前写盘失败也照样返回
  /// entry，界面弹「已保存到历史」，重启后预设没了 —— 假成功最难自己发现。
  Future<({bool ok, PresetEntry? entry})> saveAsPreset(String name) async {
    if (_rawText.trim().isEmpty) return (ok: false, entry: null);
    // 用当前时间戳 + 名字去重（同名字覆盖）
    final id = '${DateTime.now().millisecondsSinceEpoch}';
    final entry = PresetEntry(
      id: id,
      name: name.trim().isEmpty ? '名单 ${DateTime.now().toString().substring(11, 16)}' : name.trim(),
      content: _rawText,
      createdAt: DateTime.now(),
    );
    final prevPresets = _presets;
    final prevActive = _activePresetId;
    _presets = [entry, ..._presets];
    _activePresetId = entry.id;
    if (!await _persistPresets()) {
      // 写盘失败 → 回滚内存，别留一个重启后就消失的预设
      _presets = prevPresets;
      _activePresetId = prevActive;
      notifyListeners();
      return (ok: false, entry: null);
    }
    notifyListeners();
    return (ok: true, entry: entry);
  }

  /// 加载某个预设（覆盖当前 rawText）
  void loadPreset(String id) {
    final entry = _presets.firstWhere(
      (p) => p.id == id,
      orElse: () => PresetEntry(id: '', name: '', content: '', createdAt: DateTime.now()),
    );
    if (entry.id.isEmpty) return;
    _rawText = entry.content;
    _fileName = '';
    _activePresetId = entry.id;
    notifyListeners();
  }

  /// 删除某个预设
  Future<void> deletePreset(String id) async {
    _presets = _presets.where((p) => p.id != id).toList();
    if (_activePresetId == id) _activePresetId = null;
    await _persistPresets();
    notifyListeners();
  }

  /// 重命名某个预设
  Future<void> renamePreset(String id, String newName) async {
    final idx = _presets.indexWhere((p) => p.id == id);
    if (idx == -1) return;
    final old = _presets[idx];
    _presets[idx] = old.copyWith(name: newName.trim());
    await _persistPresets();
    notifyListeners();
  }

  Future<bool> _persistPresets() async {
    try {
      final prefs = await AppPrefs.getInstance();
      final raw = jsonEncode(_presets.map((p) => p.toJson()).toList());
      final saved = await prefs.setString('auto_task_presets', raw);
      return saved;
    } catch (e) {
      debugPrint('_persistPresets failed: $e');
      return false;
    }
  }

  void setIntervalSec(int v) {
    _intervalSec = v.clamp(0, 600);
    notifyListeners();
  }

  void setTimeoutSec(int v) {
    _timeoutSec = v.clamp(10, 1800);
    notifyListeners();
  }

  void setSkipOnError(bool v) {
    _skipOnError = v;
    notifyListeners();
  }

  void clearList() {
    if (_running) return; // 运行中不允许清空，避免 UI/状态错乱
    _list.clear();
    notifyListeners();
  }

  /// 解析当前 rawText，返回有效 ID 与被跳过的行数。
  ParseResult get parsed => parseIds(_rawText);

  /// 返回错误文案；正常开始返回 null。
  /// 调用后立即返回：实际执行在后台循环。
  Future<String?> start() async {
    final ids = parsed.ids;
    if (ids.isEmpty) return '请先选择名单文件或粘贴用户 ID';
    if (!appState.isLoggedIn) return '请先登录 X 账号';

    _list
      ..clear()
      ..addAll(ids.asMap().entries.map((e) => AutoTaskItem(
            key: '${e.key}-${e.value}',
            id: e.value,
            status: AutoTaskStatus.pending,
          )));

    _running = true;
    _paused = false;
    _runId++;
    _stopFlag = false;
    _pauseFlag = false;
    notifyListeners();

    // 异步执行 —— 不阻塞 UI
    unawaited(_runLoop(ids));

    return null;
  }

  void togglePause() {
    if (!_running) return;
    _pauseFlag = !_pauseFlag;
    _paused = _pauseFlag;
    notifyListeners();
  }

  void stop() {
    if (!_running) return;
    _stopFlag = true;
    _pauseFlag = false;
    _paused = false;
    notifyListeners();
  }

  // ── 主循环 ───────────────────────────────────────────────

  Future<void> _runLoop(List<String> ids) async {
    for (var i = 0; i < ids.length; i++) {
      if (_stopFlag) break;

      // 暂停循环
      while (_pauseFlag && !_stopFlag) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (_stopFlag) break;

      _patch(i, status: AutoTaskStatus.loading, message: null);

      try {
        // 加载用户（带超时）
        final loaded = await _raceWithTimeout(
          homepageStore.loadUser(ids[i]),
          Duration(seconds: _timeoutSec),
          '加载超时（${_timeoutSec}s）',
        );
        if (!loaded) {
          throw const AutoTaskException('加载被中止');
        }

        final user = homepageStore.user;
        if (user == null || user.id == null) {
          throw const AutoTaskException('未获取到用户信息');
        }

        // 登记一个后台创建任务 —— 翻页与入队由 CreationTaskStore 串行执行
        // （原版 auto-task.ts 同样是 `createCreationTask(user, filter)`）
        creationTasks.create(user, _effectiveFilter);

        await appState.addSearchHistory(ids[i]);
        _patch(i, status: AutoTaskStatus.done, message: '已加入下载队列');
      } catch (e) {
        final reason = e is AutoTaskException
            ? e.message
            : (e is String ? e : e.toString());
        _patch(i, status: AutoTaskStatus.fail, message: reason);
        if (!_skipOnError) break;
      }

      // 间隔
      if (i < ids.length - 1 && !_stopFlag) {
        await Future<void>.delayed(
            Duration(seconds: _intervalSec.clamp(0, 600)));
      }
    }

    _running = false;
    _paused = false;
    notifyListeners();
  }

  /// 取出当前 HomepageStore 里的 filter，没有则给个默认（全部媒体）。
  ///
  /// 原版在创建任务那一刻读取 filter（`useHomepageStore.getState().filter`），
  /// 由 [CreationTaskStore.create] 快照一份，所以之后改过滤条件不影响已排队的任务。
  DownloadFilter get _effectiveFilter {
    return homepageStore.filter;
  }

  /// Promise.race 替代：执行 future，限时未完成则抛 AutoTaskException。
  Future<bool> _raceWithTimeout(
    Future<void> future,
    Duration timeout,
    String timeoutMessage,
  ) async {
    try {
      await future.timeout(timeout, onTimeout: () {
        // 这里不抛，由下面 catch 捕获
        throw AutoTaskException(timeoutMessage);
      });
      return true;
    } on AutoTaskException {
      rethrow;
    } catch (e) {
      rethrow;
    }
  }

  void _patch(int index, {AutoTaskStatus? status, String? message}) {
    if (index < 0 || index >= _list.length) return;
    final old = _list[index];
    _list[index] = AutoTaskItem(
      key: old.key,
      id: old.id,
      status: status ?? old.status,
      message: message,
    );
    notifyListeners();
  }
}

class AutoTaskItem {
  final String key;
  final String id;
  final AutoTaskStatus status;
  final String? message;

  const AutoTaskItem({
    required this.key,
    required this.id,
    required this.status,
    this.message,
  });
}

enum AutoTaskStatus { pending, loading, done, fail }

class AutoTaskException implements Exception {
  final String message;
  const AutoTaskException(this.message);

  @override
  String toString() => 'AutoTaskException: $message';
}

class ParseResult {
  final List<String> ids;
  final int skipped;
  const ParseResult(this.ids, this.skipped);
}

/// 解析名单：兼容 纯ID / @ID / 主页URL / 带行号；忽略空行与 # 注释；自动去重。
///
/// 沿用 `parseIds`。
ParseResult parseIds(String text) {
  // 去掉 BOM
  final cleaned = text.replaceFirst(RegExp(r'^\uFEFF'), '');

  final ids = <String>[];
  final seen = <String>{};
  var skipped = 0;

  for (final rawLine in cleaned.split(RegExp(r'\r?\n'))) {
    var s = rawLine.trim();
    if (s.isEmpty || s.startsWith('#')) continue;

    // 去前缀：数字序号（1. / 1、/ 1) / 1]）
    s = s.replaceFirst(RegExp(r'^\d+[\.\u3001)\]]\s*'), '');
    // 去 URL 前缀
    s = s.replaceFirst(
        RegExp(r'^https?://(?:www\.)?(?:x|twitter)\.com/', caseSensitive: false),
        '');
    // 去掉 query/hash 与尾斜杠，取第一段
    s = s.split('?').first.split('#').first.replaceAll(RegExp(r'/+$'), '').split('/').first;
    // 去 @
    s = s.replaceFirst(RegExp(r'^@'), '').trim();

    if (!RegExp(r'^[A-Za-z0-9_]{1,25}$').hasMatch(s)) {
      skipped++;
      continue;
    }
    final lower = s.toLowerCase();
    if (seen.contains(lower)) continue;
    seen.add(lower);
    ids.add(s);
  }

  return ParseResult(ids, skipped);
}
/// 一个保存的「名单预设」。
///
/// 持久化到 AppPrefs（key="auto_task_presets"）。
class PresetEntry {
  final String id;
  final String name;
  final String content;
  final DateTime createdAt;

  PresetEntry({
    required this.id,
    required this.name,
    required this.content,
    required this.createdAt,
  });

  factory PresetEntry.fromJson(Map<String, dynamic> j) => PresetEntry(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        content: j['content'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
      };

  PresetEntry copyWith({String? name}) => PresetEntry(
        id: id,
        name: name ?? this.name,
        content: content,
        createdAt: createdAt,
      );

  /// 取内容前几行作为预览
  String get preview {
    final lines = content
        .split(RegExp(r'\r?\n'))
        .where((l) => l.trim().isNotEmpty)
        .take(3)
        .toList();
    return lines.join(' · ');
  }

  /// 统计有效行数
  int get lineCount => content
      .split(RegExp(r'\r?\n'))
      .where((l) => l.trim().isNotEmpty)
      .length;
}
