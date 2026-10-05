import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/media.dart';
import 'app_paths.dart';

/// 下载任务的状态机。
///
///  里的 AriaStatus + 内部 pending/loading/fail 状态。
enum DownloadStatus {
  /// 还没投给 aria2
  pending,

  /// 已投给 aria2，正在下载
  active,

  /// aria2 等待中（队列里）
  waiting,

  /// 用户暂停
  paused,

  /// 成功
  complete,

  /// 失败
  error;

  /// 终态：不会再变。重启对账与自动重试都跳过它们。
  bool get isTerminal => this == complete || this == error;
}

/// 一个下载任务。
///
/// 把 aria2 的 gid 与原始 Media 绑定：UI 列表展示来自 Media，
/// 进度/状态来自 aria2 的推送。
class DownloadTask {
  final String localId; // 我们自己的 id（aria2 的 gid 还没生成）
  final String? aria2Gid; // aria2 任务 id（已投出去才有）
  final Media media;
  final String saveDir;

  /// 按用户模板解析出来的文件名（含扩展名）。空串表示还没解析。
  final String fileName;

  DownloadStatus status;
  int progress; // 0~1000（aria2 的精度是千分之）
  int? totalBytes;
  int? downloadedBytes;
  String? errorMessage;
  DateTime createdAt;

  /// 失败后还能自动重试几次。（初始 5）。
  ///
  /// 原版 `syncDownloadTaskStatus` 在发现 aria2 报 error 且余量 > 0 时，
  /// 会把任务从列表移除、重新 `prepareDownloadTask` 后再次 `addUri`。
  int retryRemains;

  /// 当前用的是第几条候选下载地址（`media.downloadCandidates` 的下标）。
  ///
  /// **换源重试**用它递进：抖音一条视频有多条 CDN 地址，失败后换下一条，
  /// 直到用尽才考虑原地重试（见 `Aria2Coordinator._handleFailure`）。
  int attempt;

  DownloadTask({
    required this.localId,
    required this.media,
    required this.saveDir,
    this.fileName = '',
    this.aria2Gid,
    this.status = DownloadStatus.pending,
    this.progress = 0,
    this.totalBytes,
    this.downloadedBytes,
    this.errorMessage,
    this.retryRemains = 0,
    this.attempt = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 列表里显示的名字：优先模板解析结果，兜底退回媒体 ID。
  String get displayName => fileName.isNotEmpty ? fileName : media.id;

  /// 完整落盘路径（用于 tooltip / 打开文件夹）。
  String get fullPath => fileName.isEmpty
      ? saveDir
      : p.join(saveDir, fileName);

  /// 已完成的字节数（人类可读）。
  String get downloadedReadable => _humanBytes(downloadedBytes ?? 0);

  /// 总字节数。
  String get totalReadable => _humanBytes(totalBytes ?? 0);

  /// 下载进度（百分比，0~100）。
  double get progressPercent => progress / 10.0;

  static String _humanBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 10 ? 0 : 1)} ${units[unit]}';
  }
}

/// 全局下载 store：任务列表 + 当前选中的 Tab。
///
/// **关键不变量：** 所有状态都在这里，
/// 切走页面也不丢进度，aria2 推事件时直接 update()。
class DownloadStore extends ChangeNotifier {
  final Map<String, DownloadTask> _tasks = {};
  String _currentTab = '下载中';
  String _saveDir = '';

  DownloadStore();

  List<DownloadTask> get tasks => _tasks.values.toList(growable: false);

  /// 默认下载目录。设置页可改。
  String get defaultSaveDir => _saveDir;
  void setSaveDir(String path) {
    _saveDir = path;
    notifyListeners();
    _scheduleSave();
  }

  // ── 落盘 / 恢复（重启后继续）────────────────────────────────

  /// 任务表文件名（与 `settings.json`、抖音台账同目录）
  static const String fileName = 'download_tasks.json';

  File? _file;
  Timer? _saveTimer;

  /// 绑定落盘文件并读回上次的任务表。
  ///
  /// 在 `main()` 里、`Aria2Coordinator.bootstrap()` **之前**调用：
  /// bootstrap 结束时会做一次 `reconcile()`，那时任务表必须已经就位。
  Future<void> load() async {
    try {
      final dir = await _configDir();
      if (!await dir.exists()) await dir.create(recursive: true);
      final f = File('${dir.path}\\$fileName');
      _file = f;
      if (await f.exists()) _restore(await f.readAsString());
    } catch (e) {
      debugPrint('[DownloadStore] 读取任务表失败：$e');
    }
    notifyListeners();
  }

  /// 立即落盘（退出钩子里会 await 它）。
  Future<void> save() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final f = _file;
    if (f == null) return;
    try {
      await f.writeAsString(encode(), flush: true);
    } catch (e) {
      debugPrint('[DownloadStore] 写任务表失败：$e');
    }
  }

  /// 离散的状态变更合并成一次写入。
  ///
  /// **进度更新不进这里** —— 它每秒都在变，落盘只会在下载时白白写盘。
  void _scheduleSave() {
    _saveTimer ??= Timer(const Duration(seconds: 2), () {
      _saveTimer = null;
      unawaited(save());
    });
  }

  /// 任务表 → JSON。
  String encode() => jsonEncode({
        'version': 1,
        'saveDir': _saveDir,
        'tasks': [for (final t in _tasks.values) _taskToJson(t)],
      });

  /// JSON → 任务表（公开给单测用；生产路径走 [load]）。
  @visibleForTesting
  void restoreFromJson(String raw) => _restore(raw);

  void _restore(String raw) {
    Map<String, dynamic> root;
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return;
      root = v.cast<String, dynamic>();
    } catch (e) {
      // 整份损坏（写盘时断电 / 被手工改坏）→ 当作没有任务表。
      debugPrint('[DownloadStore] 任务表损坏，已忽略：$e');
      return;
    }

    final dir = root['saveDir'] as String? ?? '';
    if (dir.isNotEmpty) _saveDir = dir;

    final rows = root['tasks'];
    if (rows is! List) return;

    var skipped = 0;
    for (final row in rows) {
      final t = _taskFromJson(row);
      if (t == null) {
        skipped++;
        continue;
      }
      _tasks[t.localId] = t;
    }
    if (skipped > 0) {
      debugPrint('[DownloadStore] 跳过 $skipped 条损坏的任务记录');
    }
  }

  static Map<String, dynamic> _taskToJson(DownloadTask t) => {
        'localId': t.localId,
        if (t.aria2Gid != null) 'aria2Gid': t.aria2Gid,
        'media': t.media.toJson(),
        'saveDir': t.saveDir,
        'fileName': t.fileName,
        'status': t.status.name,
        'progress': t.progress,
        if (t.totalBytes != null) 'totalBytes': t.totalBytes,
        if (t.downloadedBytes != null) 'downloadedBytes': t.downloadedBytes,
        if (t.errorMessage != null) 'errorMessage': t.errorMessage,
        'retryRemains': t.retryRemains,
        'attempt': t.attempt,
        'createdAt': t.createdAt.toIso8601String(),
      };

  /// 一行任务记录 → [DownloadTask]；不可用返回 null（**只丢这一行**）。
  static DownloadTask? _taskFromJson(Object? row) {
    if (row is! Map) return null;
    final j = row.cast<String, dynamic>();

    final localId = j['localId'] as String? ?? '';
    final mediaRaw = j['media'];
    if (localId.isEmpty || mediaRaw is! Map) return null;

    final media = Media.fromJson(mediaRaw.cast<String, dynamic>());
    if (media.id.isEmpty || media.url.isEmpty) return null;

    final status = DownloadStatus.values.firstWhere(
      (s) => s.name == (j['status'] as String?),
      orElse: () => DownloadStatus.pending,
    );
    final gid = j['aria2Gid'] as String?;
    var errorMessage = j['errorMessage'] as String?;

    // 「还没入队就退出了」：没有 gid 说明它从没进过 aria2 的队列。
    // 如实标成失败，别让它挂在「下载中」里骗人（用户重跑一次批次即可）。
    var finalStatus = status;
    if (gid == null && !status.isTerminal) {
      finalStatus = DownloadStatus.error;
      errorMessage = '应用退出时该任务还没入队（aria2 未接收），请重新下载';
    }

    return DownloadTask(
      localId: localId,
      aria2Gid: gid,
      media: media,
      saveDir: j['saveDir'] as String? ?? '',
      fileName: j['fileName'] as String? ?? '',
      status: finalStatus,
      progress: ((j['progress'] as num?)?.toInt() ?? 0).clamp(0, 1000),
      totalBytes: (j['totalBytes'] as num?)?.toInt(),
      downloadedBytes: (j['downloadedBytes'] as num?)?.toInt(),
      errorMessage: errorMessage,
      retryRemains: (j['retryRemains'] as num?)?.toInt() ?? 0,
      attempt: (j['attempt'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
    );
  }

  /// 数据目录由 [AppPaths] 统一决定（跟着软件走，不再写 C 盘）
  Future<Directory> _configDir() async => AppPaths.configDir;

  /// 按状态过滤的任务。
  ///
  /// [source] 传 `'x'` / `'douyin'` 时只看该来源的任务 —— 两个模块的下载管理
  /// 各看各的队列（aria2 底层仍是一条队列，只是界面按 `Media.source` 分列）。
  List<DownloadTask> tasksByStatuses(
    Set<DownloadStatus> statuses, {
    String? source,
  }) => _tasks.values
      .where(
        (t) =>
            statuses.contains(t.status) &&
            (source == null || t.media.source == source),
      )
      .toList(growable: false);

  String get currentTab => _currentTab;

  void setCurrentTab(String name) {
    if (_currentTab != name) {
      _currentTab = name;
      notifyListeners();
    }
  }

  // ── 任务 CRUD ─────────────────────────────────────────────

  /// 添加一个待下载任务。返回 localId 用于后续通过 aria2 gid 反查。
  ///
  /// [fileName] 是按用户模板解析好的文件名；不传则退回 `media.safeFileName`。
  /// [retryRemains] 是失败后允许的自动重试次数（原版默认 5）。
  String addPending(
    Media media,
    String saveDir, {
    String? fileName,
    int retryRemains = 0,
    int attempt = 0,
  }) {
    final id = '${media.id}_${DateTime.now().microsecondsSinceEpoch}';
    _tasks[id] = DownloadTask(
      localId: id,
      media: media,
      saveDir: saveDir,
      fileName: fileName ?? media.safeFileName,
      status: DownloadStatus.pending,
      retryRemains: retryRemains,
      attempt: attempt,
    );
    _changed();
    return id;
  }

  /// 标记任务已投给 aria2（绑定 gid）。
  void markActive(String localId, String gid) {
    final t = _tasks[localId];
    if (t == null) return;
    _tasks[localId] = DownloadTask(
      localId: t.localId,
      aria2Gid: gid,
      media: t.media,
      saveDir: t.saveDir,
      fileName: t.fileName,
      status: DownloadStatus.active,
      totalBytes: t.totalBytes,
      downloadedBytes: t.downloadedBytes,
      retryRemains: t.retryRemains,
      attempt: t.attempt,
      createdAt: t.createdAt,
    );
    _changed();
  }

  /// 更新进度（aria2 推送）。
  void updateProgress(String gid, int progress, int? total) {
    final t = _findByGid(gid);
    if (t == null) return;
    t.progress = progress;
    if (total != null) t.totalBytes = total;
    notifyListeners();
  }

  /// 标记完成。
  void markComplete(String gid) {
    final t = _findByGid(gid);
    if (t == null) return;
    t.status = DownloadStatus.complete;
    t.progress = 1000;
    _changed();
  }

  /// 标记失败 —— **按 aria2 gid 查**（下载过程中失败的任务用这个）。
  ///
  /// 名字里带 `ByGid` 是刻意的：早前它叫 `markError(String, String)`，
  /// 与按 localId 的 `pause/remove` 签名一模一样，于是在 `_submit` 的 catch 里
  /// 被误传 localId，`_findByGid` 查不到就**静默返回**，失败任务永远停在
  /// pending。现在 key 的种类写进方法名，传错就编译不过。
  void markErrorByGid(String gid, String message) {
    final t = _findByGid(gid);
    if (t == null) return;
    t.status = DownloadStatus.error;
    t.errorMessage = message;
    _changed();
  }

  /// 标记失败 —— **按本地 id 查**。
  ///
  /// 用于「还没拿到 gid 就已经失败」的入队阶段（`aria2.addUri` 抛错）：
  /// 那时任务只有 localId，用 gid 版本会静默失效。
  void markErrorByLocalId(String localId, String message) {
    final t = _tasks[localId];
    if (t == null) return;
    t.status = DownloadStatus.error;
    t.errorMessage = message;
    _changed();
  }

  /// 标记完成 —— **按本地 id 查**，用于「文件其实已经在磁盘上了」这一档。
  ///
  /// 手动重试时如果目标文件已存在且不是半成品，就不该再投一次给 aria2
  /// （再投会落出 `xxx.1.jpg` 这种一模一样的重复文件）。那种情况下如实把这条
  /// 标成已完成，比留在「错误」里更接近事实。[totalBytes] 传磁盘上的真实大小。
  void markCompleteByLocalId(String localId, {int? totalBytes}) {
    final t = _tasks[localId];
    if (t == null) return;
    t.status = DownloadStatus.complete;
    t.progress = 1000;
    t.errorMessage = null;
    if (totalBytes != null) t.totalBytes = totalBytes;
    _changed();
  }

  /// 暂停（只是状态切换，不取消 aria2 任务）。
  void pause(String localId) {
    final t = _tasks[localId];
    if (t == null) return;
    t.status = DownloadStatus.paused;
    _changed();
  }

  /// 删除任务。
  void remove(String localId) {
    if (_tasks.remove(localId) != null) _changed();
  }

  /// 清空指定状态的任务。
  void clearWhere(bool Function(DownloadTask) pred) {
    final removed = _tasks.entries.where((e) => pred(e.value)).toList();
    for (final e in removed) {
      _tasks.remove(e.key);
    }
    if (removed.isNotEmpty) _changed();
  }

  /// 状态变了：通知界面 + 合并落盘。
  ///
  /// 进度更新（[updateProgress]）**只通知不落盘** —— 它每秒都在变。
  void _changed() {
    notifyListeners();
    _scheduleSave();
  }

  DownloadTask? _findByGid(String gid) {
    for (final t in _tasks.values) {
      if (t.aria2Gid == gid) return t;
    }
    return null;
  }

  /// 按 gid 取任务（失败重试时要用它的 media / fileName / 重试余量）。
  DownloadTask? taskByGid(String gid) => _findByGid(gid);

  /// 按 localId 取任务（界面上的「重试」按钮只有 localId）。
  DownloadTask? task(String localId) => _tasks[localId];

  /// 直接改某个任务的重试余量（重试前递减）。
  void setRetryRemains(String localId, int value) {
    final t = _tasks[localId];
    if (t == null) return;
    t.retryRemains = value < 0 ? 0 : value;
    _changed();
  }

  // ── Aria2Coordinator 需要的反查 ────────────────────────

  /// localId → aria2 gid（用于 coordinator 调用 aria2.pause/remove 等）
  String? gidFor(String localId) => _tasks[localId]?.aria2Gid;

  /// aria2 gid → localId（用于 coordinator 收到事件后反查任务）
  String? localIdForGid(String gid) {
    final t = _findByGid(gid);
    return t?.localId;
  }

  /// 列出所有仍活跃的任务的 gid（用于 coordinator 周期拉进度）
  List<String> activeGids() {
    return _tasks.values
        .where((t) =>
            t.aria2Gid != null &&
            (t.status == DownloadStatus.active ||
                t.status == DownloadStatus.waiting))
        .map((t) => t.aria2Gid!)
        .toList(growable: false);
  }

  /// aria2 推送「暂停」事件时用（区别于用户主动 pause）
  void markPaused(String localId) {
    final t = _tasks[localId];
    if (t == null) return;
    t.status = DownloadStatus.paused;
    _changed();
  }

  /// 「继续」成功之后把状态翻回来。
  ///
  /// 为什么需要这个方法：本地状态此前**只有**入队时的 `markActive` 会设成
  /// active，aria2 的 `onDownloadStart` 只写日志不改状态（见 coordinator 的
  /// `_onStart`），而进度轮询 `_pollActive` 又只问 `activeGids()`。
  /// 于是 `unpause` 成功、aria2 已经在正常下载了，界面却永远停在「已暂停」
  /// 且进度不再走 —— 用户看到的就是"点了继续没反应"（2026-09-24 报）。
  void markResumed(String localId) {
    final t = _tasks[localId];
    if (t == null || t.status != DownloadStatus.paused) return;
    t.status = DownloadStatus.active;
    _changed();
  }
}