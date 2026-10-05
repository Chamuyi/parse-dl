/// 「已下载」台账 / 下载历史。
///
/// **粒度是「作品」而不是「文件」**（键 = `aweme_id`）：
/// 一条图文里少下了一张图，整条作品也会被标记为已下载。
/// 沿用这一粒度，「跳过已下载 N 个」的数字才和作品数对得上。
///
/// 相对浏览器形态的几点改动（都是桌面端可以做得更好的地方）：
///   1. 存**文件**（数据目录下的 `douyin_downloaded.json`）而不是页面 `localStorage`
///      —— 不怕清缓存、不受 5 MB 上限约束；
///   2. **形状校验**：读到坏数据整份丢弃，不让一条脏记录毁掉整个台账；
///   3. v2 起记录**下载时间 / 标题 / 作者**，于是「下载历史」才是一个
///      能看懂、能逐条删的列表；
///   4. **不再按「当前列表」裁剪**（v1 的 `prune`）：那样会让历史凭空消失。
///      改成按条数上限（[kMaxRecords]）丢最旧的。
///
/// 格式：
/// ```json
/// {"version":3,
///  "items":{"<aweme_id>":{"t":1699999999999,"text":"标题","user":"作者",
///                         "s":"pending","f":["<任务id>"]}}}
/// ```
/// `s` 缺省即 `done`；读入时同时兼容 v2（`{"<id>":{"t":..,"text":..,"user":..}}`）
/// 与 v1（`{"<id>": true}`）—— 老用户的记录不作废，一律当作已下载。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_paths.dart';

/// 一条记录的状态。
///
/// 为什么要分两态：「提交进 aria2 队列就算已下载」这种记法是错的，于是
/// **一次都没下成功**的作品（直链过期、网络断、aria2 拒绝）也永久占着
/// 「已下载」；用户开着「跳过已下载」就再也不会重试，而文件又不在手里，
/// 等于悄悄丢了一个作品。现在只有全部任务成功的才算 [done]。
enum DouyinLedgerState {
  /// 已提交给 aria2，这条作品的任务还没全部成功。
  pending,

  /// 全部任务都成功了 —— 这才是「已下载」，会出现在下载历史里。
  done,
}

/// 台账侧看到的工作状态（由调用方从 `DownloadStatus` 映射过来，
/// 台账不认识 `DownloadStore`，这样它能被单独测试）。
enum DouyinTaskState { complete, failed, running, unknown }

/// 一条作品「已提交下载」时台账要记的东西。
typedef DouyinQueuedAweme = ({
  List<String> taskIds,
  String? title,
  String? author,
});

/// 一条下载记录（作品粒度）
@immutable
class DouyinDownloadRecord {
  const DouyinDownloadRecord({
    required this.awemeId,
    this.at,
    this.title,
    this.author,
    this.state = DouyinLedgerState.done,
    this.taskIds = const [],
  });

  final String awemeId;

  /// 下载时间（epoch millis）。v1 的老记录没有这个值。
  final int? at;

  final String? title;
  final String? author;

  final DouyinLedgerState state;

  /// 这条作品提交过的任务 id（`DownloadStore` 的 localId）。
  /// 只用于推进 [pending] → [done]，成功后不再需要。
  final List<String> taskIds;

  bool get isDone => state == DouyinLedgerState.done;

  DateTime? get time =>
      at == null ? null : DateTime.fromMillisecondsSinceEpoch(at!);

  bool get hasTime => at != null;

  @override
  String toString() => 'DouyinDownloadRecord($awemeId, at: $at, $state)';
}

class DouyinLedger extends ChangeNotifier {
  /// [maxRecords] 可注入，便于测试上限行为
  DouyinLedger({this.maxRecords = kMaxRecords});

  /// 台账文件名（在数据目录下，与 `settings.json` 同处）
  static const String fileName = 'douyin_downloaded.json';

  /// 当前落盘格式版本。
  ///
  /// v3 起多了 `s`（状态）与 `f`（任务 id）；读入时 v2 与 v1 都还认
  /// （v2 没有状态字段，那些记录本来就是「已下载」语义 → 当 done）。
  static const int kFormatVersion = 3;

  /// 记录条数上限：超出时丢**最旧**的。
  ///
  /// 上限取 20000：真实重度用户的台账实测有
  /// **5215 条**，5000 会让迁移进来的记录在下次下载时被 `_trim()` 悄悄
  /// 删掉 215 条（而且迁移来的记录没有时间戳，按规则正好是「最旧」，
  /// 一删就是它们）。桌面端存的是 JSON 文件，5215 条约 140 KB、
  /// 20000 条约 540 KB，没有浏览器 localStorage 那种 5 MB 约束。
  static const int kMaxRecords = 20000;

  final int maxRecords;

  final Map<String, DouyinDownloadRecord> _records =
      <String, DouyinDownloadRecord>{};
  File? _file;
  bool _loaded = false;

  /// 台账里的全部条目数（含还在下载的）。
  ///
  /// 「跳过已下载」拦不拦是按这个集合判的 —— 正在下的也算，否则会重复提交。
  int get count => _records.length;

  /// **已下完**的作品数 —— 界面上「已下载 N 个」用它，别用 [count]。
  int get doneCount => _records.values.where((r) => r.isDone).length;

  bool get loaded => _loaded;

  bool contains(String awemeId) => _records.containsKey(awemeId);

  /// 这条媒体所属作品是否已下载。
  bool containsMedia(String? tweetId) =>
      tweetId != null && tweetId.isNotEmpty && _records.containsKey(tweetId);

  /// 已下完的记录，按下载时间**从新到旧**；没有时间的（v1 老记录）排在最后。
  ///
  /// 还在下的（[DouyinLedgerState.pending]）不在这里 —— 「已下载（抖音）」
  /// 这个列表给用户看的是「哪些作品我已经拿到手了」。
  List<DouyinDownloadRecord> get records {
    final list = _records.values.where((r) => r.isDone).toList()
      ..sort((a, b) {
        final x = a.at;
        final y = b.at;
        if (x == null && y == null) return a.awemeId.compareTo(b.awemeId);
        if (x == null) return 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });
    return List.unmodifiable(list);
  }

  /// 拿到台账文件句柄（必要时建目录）。
  ///
  /// 单独抽出来是为了**没先 `load()` 也能落盘**：否则「标记了却没保存」
  /// 会静默发生，用户看到的就是「下载历史又空了」。
  Future<File> _ensureFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await _configDir();
    if (!await dir.exists()) await dir.create(recursive: true);
    return _file = File('${dir.path}\\$fileName');
  }

  Future<void> load() async {
    try {
      final f = await _ensureFile();
      if (await f.exists()) {
        final raw = await f.readAsString();
        _records
          ..clear()
          ..addAll(_decode(raw));
      }
    } catch (e) {
      debugPrint('[DouyinLedger] 读取失败：$e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// 解析台账：v2（`{"version":2,"items":{...}}`）与 v1（`{"<id>": true}`）都认。
  ///
  /// 与参照实现的读入校验同思路 —— 形状不对就整份丢弃，不让脏数据污染内存状态。
  static Map<String, DouyinDownloadRecord> _decode(String raw) {
    final out = <String, DouyinDownloadRecord>{};
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return out;

      // ── v2 / v3 ──
      final items = v['items'];
      final ver = v['version'];
      if ((ver == kFormatVersion || ver == 2) && items is Map) {
        items.forEach((k, value) {
          if (k is! String || k.isEmpty) return;
          if (value is! Map) return;
          final t = value['t'];
          final f = value['f'];
          out[k] = DouyinDownloadRecord(
            awemeId: k,
            at: t is num ? t.toInt() : null,
            title: _str(value['text']),
            author: _str(value['user']),
            // v2 没有 s，缺省按「已下载」——那些记录本来就是下载完才写的
            state: value['s'] == DouyinLedgerState.pending.name
                ? DouyinLedgerState.pending
                : DouyinLedgerState.done,
            taskIds: f is List ? [for (final x in f) if (x is String) x] : const [],
          );
        });
        return out;
      }

      // ── v1（以及任何 `{id: true}` 形状）──
      v.forEach((k, value) {
        if (k is! String || k.isEmpty) return;
        if (value == true) out[k] = DouyinDownloadRecord(awemeId: k);
      });
    } catch (_) {
      // 整份丢弃
    }
    return out;
  }

  static String? _str(Object? v) {
    if (v is! String) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  /// 时间戳保证**严格递增**：同一毫秒内连续标记多条时，
  /// 「从新到旧」的顺序才是确定的（Windows 时钟精度可能只有几毫秒）。
  int _nextStamp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var maxAt = 0;
    for (final r in _records.values) {
      final t = r.at;
      if (t != null && t > maxAt) maxAt = t;
    }
    return now > maxAt ? now : maxAt + 1;
  }

  /// 记为「已提交下载」（作品粒度）。
  ///
  /// 这是下载链路上唯一该由 UI 调的入口：入队成功 ≠ 拿到文件，所以这里只写
  /// [DouyinLedgerState.pending]，之后由 [advance] 按任务结局转成已下载或撤销。
  Future<void> markQueued(Map<String, DouyinQueuedAweme> byAweme) async {
    if (byAweme.isEmpty) return;
    final meta = <String, ({String? title, String? author})>{
      for (final e in byAweme.entries)
        if (e.value.title != null || e.value.author != null)
          e.key: (title: e.value.title, author: e.value.author),
    };
    await markAll(
      byAweme.keys,
      meta: meta,
      taskIds: {for (final e in byAweme.entries) e.key: e.value.taskIds},
    );
  }

  /// 记入台账。
  ///
  /// 给了 [taskIds] 就记成 [DouyinLedgerState.pending]（已入队、还没下完），
  /// 不给就是直接算 [DouyinLedgerState.done]。
  ///
  /// [meta] 可选带上标题/作者，用于「下载历史」展示。
  /// **已经算已下载的不覆盖时间** —— 历史时间应当是第一次拿到它的时间。
  Future<void> markAll(
    Iterable<String> awemeIds, {
    Map<String, ({String? title, String? author})>? meta,
    Map<String, List<String>>? taskIds,
  }) async {
    final toPending = taskIds != null;
    int? stamp;
    int takeStamp() => stamp ??= _nextStamp();
    var changed = false;

    for (final id in awemeIds) {
      if (id.isEmpty) continue;
      final old = _records[id];
      final m = meta?[id];

      if (toPending) {
        final ids = taskIds[id] ?? const <String>[];
        if (old == null) {
          _records[id] = DouyinDownloadRecord(
            awemeId: id,
            at: takeStamp(),
            title: m?.title,
            author: m?.author,
            state: DouyinLedgerState.pending,
            taskIds: ids,
          );
          changed = true;
        } else if (!old.isDone && !_sameTaskIds(old.taskIds, ids)) {
          // 同一作品再次提交（失败后重试）—— **换成**新任务 id，不并集：
          // 旧的失败任务留在里面会让 [advance] 把刚下好的作品又撤销。
          _records[id] = DouyinDownloadRecord(
            awemeId: id,
            at: old.at,
            title: old.title ?? m?.title,
            author: old.author ?? m?.author,
            state: DouyinLedgerState.pending,
            taskIds: ids,
          );
          changed = true;
        }
        continue;
      }

      if (old != null && old.isDone) continue;
      _records[id] = DouyinDownloadRecord(
        awemeId: id,
        at: old?.at ?? takeStamp(),
        title: old?.title ?? m?.title,
        author: old?.author ?? m?.author,
      );
      changed = true;
    }

    if (!changed) return;
    _trim();
    notifyListeners();
    await _save();
  }

  /// 把一个新任务 id 续到这条作品的「在下」记录上（失败重试会换任务 id）。
  ///
  /// 没有对应 pending 记录时**什么都不做**：这条 API 由 aria2 的提交回调驱动，
  /// 而 X 侧的下载、以及没有被台账认领的作品都不该凭空冒出一条 pending。
  Future<void> attachTask(String awemeId, String taskId) async {
    final r = _records[awemeId];
    if (r == null || r.isDone) return;
    if (r.taskIds.contains(taskId)) return;
    _records[awemeId] = DouyinDownloadRecord(
      awemeId: awemeId,
      at: r.at,
      title: r.title,
      author: r.author,
      state: DouyinLedgerState.pending,
      taskIds: [...r.taskIds, taskId],
    );
    notifyListeners();
    await _save();
  }

  /// 按任务的实际结局推进台账。返回是否发生了变化。
  ///
  /// 为什么需要它：记账点从「入队时」挪到了「下完时」，而「下完」这件事发生在
  /// aria2 事件里 —— 事件可能丢（进程在完成前退出、任务被从下载管理里删掉）。
  /// 所以这里不依赖事件顺序：任何时候拿任务表对一遍就能纠正，启动时也调一次。
  ///
  /// [statusOf] 由调用方按任务 id 查状态。台账**不认识 `DownloadStore`**，
  /// 这样它能被单独测试。判据：
  ///   * 任一任务 [DouyinTaskState.failed] → 撤掉这条记录，下次刷到同一作品能重试
  ///     （这正是这次修复要解决的问题：失败的作品不该永久占着「已下载」）；
  ///   * 其余**查得到的**任务全部 [DouyinTaskState.complete] → 转成 done；
  ///   * [DouyinTaskState.running] 还挂在上面 → 保持在下；
  ///   * 全部 [DouyinTaskState.unknown]（任务被重试换掉、或用户从下载管理里删了）
  ///     → 保持原状，**不猜**。
  ///
  /// 为什么要「忽略 unknown 再判」而不是「全部都要 complete」：失败重试会把旧任务
  /// 从任务表里删掉、换一个新 id，旧 id 从此查不到。若把它当阻碍，这条作品
  /// 就永远转不成已下载。
  Future<bool> advance(DouyinTaskState Function(String taskId) statusOf) async {
    var changed = false;
    for (final id in _records.keys.toList()) {
      final r = _records[id];
      if (r == null || r.isDone) continue;
      if (r.taskIds.isEmpty) continue;
      final known = [
        for (final tid in r.taskIds) statusOf(tid),
      ].where((s) => s != DouyinTaskState.unknown).toList(growable: false);
      if (known.isEmpty) continue;

      if (known.any((s) => s == DouyinTaskState.failed)) {
        _records.remove(id);
        changed = true;
        continue;
      }
      if (known.every((s) => s == DouyinTaskState.complete)) {
        _records[id] = DouyinDownloadRecord(
          awemeId: id,
          at: _nextStamp(),
          title: r.title,
          author: r.author,
        );
        changed = true;
      }
    }
    if (!changed) return false;
    notifyListeners();
    await _save();
    return true;
  }

  /// 删掉一条记录（下载历史里的「移除」）
  Future<void> remove(String awemeId) async {
    if (_records.remove(awemeId) == null) return;
    notifyListeners();
    await _save();
  }

  /// 「清除下载记录」。**返回是否真的落盘**。
  ///
  /// 以前是无条件弹「已清除」：写盘失败时台账其实还在，用户下次批量下载
  /// 会继续静默跳过那批作品，而他以为自己已经清干净了 —— 比不提示更难查。
  Future<bool> clear() async {
    if (_records.isEmpty) return true;
    _records.clear();
    notifyListeners();
    return _save();
  }

  /// 超出上限时丢最旧的（没有时间的当作最旧）
  void _trim() {
    if (_records.length <= maxRecords) return;
    final sorted = _records.values.toList()
      ..sort((a, b) {
        final x = a.at;
        final y = b.at;
        if (x == null && y == null) return a.awemeId.compareTo(b.awemeId);
        if (x == null) return -1;
        if (y == null) return 1;
        return x.compareTo(y); // 最旧在前
      });
    final drop = sorted.length - maxRecords;
    for (var i = 0; i < drop; i++) {
      _records.remove(sorted[i].awemeId);
    }
  }

  Future<bool> _save() async {
    try {
      final f = await _ensureFile();
      final payload = <String, Object?>{
        'version': kFormatVersion,
        'items': <String, Object?>{
          for (final e in _records.values)
            e.awemeId: <String, Object?>{
              if (e.at != null) 't': e.at,
              if (e.title != null) 'text': e.title,
              if (e.author != null) 'user': e.author,
              // done 是缺省态，不写字段，省得每条都多一行
              if (!e.isDone) 's': e.state.name,
              if (e.taskIds.isNotEmpty) 'f': e.taskIds,
            },
        },
      };
      await f.writeAsString(jsonEncode(payload));
      return true;
    } catch (e) {
      debugPrint('[DouyinLedger] 写入失败：$e');
      return false;
    }
  }

  /// 数据目录由 [AppPaths] 统一决定（跟着软件走，不再写 C 盘）
  Future<Directory> _configDir() async => AppPaths.configDir;
}

/// 两组任务 id 是否等价（顺序无关）—— 用来判断「再次提交」要不要更新记录。
bool _sameTaskIds(List<String> a, List<String> b) =>
    a.length == b.length && a.toSet().containsAll(b);
