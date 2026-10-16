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

  /// 这一行的限速（KB/s），null = 不限。
  ///
  /// 记在任务行上而不是只在入队那一刻用：aria2 的限速是 **per-task option**，
  /// 每次 `addUri` 都要重传一遍。换源自动重投和用户手动重试走的是同一条
  /// `_submit`，不带着它就会出「明明设了限速，失败重试一次后变全速」这种
  /// 没法归因的现象。
  final int? speedLimitKbps;

  /// aria2 实测的**当前下载速度**（字节/秒），null = 此刻没有在跑。
  ///
  /// 与 [speedLimitKbps] 刻意分成两个字段，语义不同、不能混用：
  ///   - `speedLimitKbps` 是**用户设的上限**（KB/s，`null` = 不限速），
  ///     是配置，持久化到任务表，换源重投时还要带回去；
  ///   - 本字段是**这一秒实际跑了多少**，只由 `Aria2Coordinator._pollActive`
  ///     每轮轮询写入，**不进 [DownloadTask.toJson]**（见那里的说明）。
  ///
  /// 界面只对 `active` / `waiting` 渲染它；终态（已完成 / 失败 / 暂停）的
  /// 行上它必须是 `null`，否则用户会看到一个「挂着上次会话旧速度」的假数字。
  int? speedBytesPerSec;

  /// 排队位次：队列里排在它前面、还没轮到它的任务数（0 = 下一个就是它）。
  ///
  /// 只有 `waiting` 时才由 `DownloadStore.markWaiting` 写入 —— 界面据此把
  /// 「队列中」写具体（「前面还有 N 条」，见 `download_list_item.dart`）。
  ///
  /// 与 [speedBytesPerSec] 同一类：**这是此刻的一帧快照，不是这一行的属性**，
  /// 所以同样不进 `_taskToJson`。重启后由 `Aria2Coordinator._pollActive` /
  /// `reconcile` 重新问一遍引擎，写进任务表只会变成一个过期假数字。
  int? queueAhead;

  /// 完成之后要补给用户看的一句说明（**不是错误**，状态仍是已完成）。
  ///
  /// 这一期唯一的使用者是 B 站的附加文件：主产物完好、但用户勾的某样没拿到。
  /// 那种「部分成功」既不该把行标成错误（会被自动重试、也会让人重下一遍），
  /// 也不能只进日志（日志不是界面）。
  final String? note;

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
    this.speedLimitKbps,
    this.speedBytesPerSec,
    this.queueAhead,
    this.note,
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

  /// 实时速度（人类可读，如 `1.2 MB/s`）；**不在下载时返回空串**。
  ///
  /// 界面据此决定要不要画这一格 —— 空串即「这一行不该出现速度」。
  /// 人类可读化沿用 [_humanBytes] 的分档与舍入，只是单位换成 `/s`。
  String get speedReadable {
    final b = speedBytesPerSec;
    if (b == null || b <= 0) return '';
    return '${_humanBytes(b)}/s';
  }

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
        // 实时速度**刻意不写进任务表**。理由有两条：
        //   1. 它是「这一秒实际跑了多少」的一帧快照，写进去等于把一个随时
        //      失效的数字固化下来 —— 重启后一条「已完成」任务上会挂着上次
        //      会话最后那一轮的速度，用户看到的就是假数据；
        //   2. `updateSpeed` 每秒被轮询调一次，跟着 `_changed()` 落盘会让
        //      下载期间白白写盘（[updateProgress] 同理，也不落盘）。
        // 语义上它由「当前是否在下载」决定，而那个状态已经由 'status' 承载。
        if (t.speedLimitKbps != null) 'speedLimitKbps': t.speedLimitKbps,
        if (t.note != null) 'note': t.note,
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
      speedLimitKbps: (j['speedLimitKbps'] as num?)?.toInt(),
      note: j['note'] as String?,
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
    int? speedLimitKbps,
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
      speedLimitKbps: speedLimitKbps,
    );
    _changed();
    return id;
  }

  /// 给某一行的完成态补一句说明（不改状态，只改这行并通知界面）。
  void markNote(String localId, String note) {
    final t = _tasks[localId];
    if (t == null || t.note == note) return;
    _tasks[localId] = DownloadTask(
      localId: t.localId,
      aria2Gid: t.aria2Gid,
      media: t.media,
      saveDir: t.saveDir,
      fileName: t.fileName,
      status: t.status,
      progress: t.progress,
      totalBytes: t.totalBytes,
      downloadedBytes: t.downloadedBytes,
      errorMessage: t.errorMessage,
      retryRemains: t.retryRemains,
      attempt: t.attempt,
      speedLimitKbps: t.speedLimitKbps,
      // **必须带上实时速度与排队位次**：本方法整体重建 DownloadTask，
      // 漏掉就是「改个备注 → 速度显示消失」这种静默抖动。本类重建共三处
      // （`markNote` / `markActive` / `renameTaskFile`），加新可变字段时三处都要带。
      speedBytesPerSec: t.speedBytesPerSec,
      queueAhead: t.queueAhead,
      note: note,
      createdAt: t.createdAt,
    );
    _changed();
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
      speedLimitKbps: t.speedLimitKbps,
      // 同上：整体重建时不能丢实时速度与排队位次（换源重投、恢复下载都走这里）。
      speedBytesPerSec: t.speedBytesPerSec,
      queueAhead: t.queueAhead,
      note: t.note,
      createdAt: t.createdAt,
    );
    _changed();
  }

  /// 引擎说这条任务还在**排队**（aria2 的 `waiting`），不是「正在下载」。
  ///
  /// 为什么需要（2026-10-16）：`DownloadStatus.waiting` 此前在全 `lib/` 里
  /// **没有任何赋值点** —— 它只被读取。引擎那边 200 条 `waiting` 全被
  /// `aria2_coordinator.dart` 的 `case AriaStatus.active: case AriaStatus.waiting:`
  /// 走成 `active`，于是界面上只有「下载中 0%」一种样子：用户看不出队列是在
  /// 往前挪还是整个卡死了。
  ///
  /// [aheadCount] 是队列里排在它前面的任务数（0 = 下一个就轮到它）。
  /// 幂等：状态与位次都没变就**不落盘也不通知** —— 这个方法是每秒轮询调的。
  void markWaiting(String gid, {int? aheadCount}) {
    final t = _findByGid(gid);
    if (t == null) return;
    if (t.status == DownloadStatus.waiting && t.queueAhead == aheadCount) {
      return;
    }
    t.status = DownloadStatus.waiting;
    t.queueAhead = aheadCount;
    _changed();
  }

  /// 引擎开始下载这条任务了 —— 把「排队中 / 已暂停」翻回「下载中」。
  ///
  /// [markResumed] 只管「已暂停 → 下载中」（它是为「点了继续没反应」修的），
  /// 而 `waiting` 的任务被引擎取出开始下时同样要翻回 `active`：只认 `paused`
  /// 的话，界面会**永远停在「队列中」**，比不显示排队更糟。
  void markDownloading(String localId) {
    final t = _tasks[localId];
    if (t == null) return;
    if (t.status != DownloadStatus.paused &&
        t.status != DownloadStatus.waiting) {
      return;
    }
    t.status = DownloadStatus.active;
    _clearQueueAhead(t);
    _changed();
  }

  /// 更新进度（aria2 推送）。
  /// 进度轮询的回写口。
  ///
  /// `downloaded` 必须一起传：界面那行「已下 X B / 共 Y MB」读的是
  /// [AriaTask.downloadedBytes]，只更新 [AriaTask.progress] 的话会出现
  /// **进度条走到一半、字数还写着 0 B**（2026-10-06 真机截图就是这样）。
  void updateProgress(String gid, int progress, int? total, {int? downloaded}) {
    final t = _findByGid(gid);
    if (t == null) return;
    t.progress = progress;
    if (total != null) t.totalBytes = total;
    if (downloaded != null) t.downloadedBytes = downloaded;
    notifyListeners();
  }

  /// 写入 aria2 实测的当前速度（字节/秒）—— 只由进度轮询调用。
  ///
  /// 与 [updateProgress] 分开而不是塞进它的参数：`reconcile()` 那种只补进度
  /// 的场景不该顺手动速度（那一轮拿到的是对账快照，不是实时速率）。
  /// [speedBytesPerSec] 传 `null` 即清空（aria2 说「现在没有速率」时）。
  void updateSpeed(String gid, int? bytesPerSec) {
    final t = _findByGid(gid);
    if (t == null) return;
    if (t.speedBytesPerSec == bytesPerSec) return;
    t.speedBytesPerSec = bytesPerSec;
    notifyListeners();
  }

  /// 离开下载态时清掉实时速度。
  ///
  /// 速度是「此刻实际跑多少」的一帧快照，不是这一行的属性。完成 / 失败 /
  /// 暂停之后它就不再描述任何正在发生的事，留着就是一个**过期假数据**：
  /// 用户会在「已完成 5 分钟」的行上看到一个上周的 `1.2 MB/s`。
  ///
  /// 因此每个「翻出下载态」的入口都调它一遍（幂等，null 就不动）。
  /// 与本字段不进 `toJson` 的双保险见 [_taskToJson]。
  void _clearSpeed(DownloadTask t) {
    if (t.speedBytesPerSec == null) return;
    t.speedBytesPerSec = null;
  }

  /// 离开排队态时清掉位次 —— 与 [_clearSpeed] 同一个理由：它是「此刻」的快照。
  ///
  /// 不清的话，一条「已完成」或「已暂停」的行上会继续写着「前面还有 3 条」，
  /// 而它早就不在队列里了。
  void _clearQueueAhead(DownloadTask t) {
    if (t.queueAhead == null) return;
    t.queueAhead = null;
  }

  /// 标记完成。
  void markComplete(String gid) {
    final t = _findByGid(gid);
    if (t == null) return;
    t.status = DownloadStatus.complete;
    t.progress = 1000;
    _clearSpeed(t);
    _clearQueueAhead(t);
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
    _clearSpeed(t);
    _clearQueueAhead(t);
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
    _clearSpeed(t);
    _clearQueueAhead(t);
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
    _clearSpeed(t);
    _clearQueueAhead(t);
    _changed();
  }

  /// 暂停（只是状态切换，不取消 aria2 任务）。
  void pause(String localId) {
    final t = _tasks[localId];
    if (t == null) return;
    t.status = DownloadStatus.paused;
    _clearSpeed(t);
    _clearQueueAhead(t);
    _changed();
  }

  /// 删除任务。
  void remove(String localId) {
    if (_tasks.remove(localId) != null) _changed();
  }

  /// 换掉一行任务的落盘名，**不改磁盘上的文件**。
  ///
  /// 为什么需要：B 站 DASH 先落 `<base>.video.m4s` + `<base>.audio.m4s` 两个裸流，
  /// ffmpeg 合出 `<base>.mp4` 并把两条裸流删掉之后，界面上那一行还写着
  /// `.video.m4s` —— 用户看到一个「已完成」的 m4s，而磁盘上那个文件早就不在了
  /// （双击打不开、右键「打开文件夹」也定位不到）。这一行本身没错，错的只是名字。
  ///
  /// [DownloadTask.fileName] 是 `final`（任务行按整体替换来保证「改一处不会漏另一处」，
  /// 见 [markActive]），所以这里**构造新实例替换**而不是就地改字段：
  /// 状态 / 进度 / 字节数 / 错误说明 / 重试余量 / 创建时间全部原样带过去，
  /// 只有名字换掉。
  ///
  /// 走 [_changed]：既通知界面重建，也让新名字**落进任务表** ——
  /// 不落盘的话下次开机那一行又变回 `.video.m4s`，等于白改一次。
  /// 返回是否改成了（id 不存在或新名为空时 false，调用方据此决定要不要报错）。
  bool renameTaskFile(String localId, String newName) {
    final t = _tasks[localId];
    if (t == null || newName.isEmpty || t.fileName == newName) return false;
    _tasks[localId] = DownloadTask(
      localId: t.localId,
      aria2Gid: t.aria2Gid,
      media: t.media,
      saveDir: t.saveDir,
      fileName: newName,
      status: t.status,
      progress: t.progress,
      totalBytes: t.totalBytes,
      downloadedBytes: t.downloadedBytes,
      errorMessage: t.errorMessage,
      retryRemains: t.retryRemains,
      attempt: t.attempt,
      speedLimitKbps: t.speedLimitKbps,
      // 同上：整体重建时不能丢实时速度与排队位次（下载中改文件名也会走到这里）。
      speedBytesPerSec: t.speedBytesPerSec,
      queueAhead: t.queueAhead,
      note: t.note,
      createdAt: t.createdAt,
    );
    _changed();
    return true;
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
    _clearSpeed(t);
    _clearQueueAhead(t);
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