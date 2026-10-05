import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/creation_task.dart';
import '../models/download_filter.dart';
import '../models/user.dart';
import 'app_logger.dart';
import 'app_state.dart';
import 'aria2_coordinator.dart';
import 'x_api.dart';

/// 「创建下载任务」的后台队列。
///
///  里的 `creationTasks` +
/// `scheduleCreationTasks()` + `runCreationTask()` 三件套。
///
/// **它解决的问题**：主页点「开始下载」时，媒体列表可能只加载了第一页，
/// 而用户要的是「这个用户的全部媒体」。原版的做法不是当场把剩余页拉完再入队
/// （那会让界面卡住、看起来像没反应），而是：
///
///   1. 点按钮 → 登记一个 CreationTask 就**立刻返回**（界面上已出现「任务创建中」）
///   2. 后台串行取队头任务 → 翻页 → 逐条投给 aria2
///   3. 每翻一页更新 `completeCount` / `skipCount`，下载管理页实时看得见
///   4. 跑完（或到日期下界）就摘掉这个任务
///
/// **一次只跑一个**（与原版 `scheduleCreationTasks` 的
/// `if (creationTasks.find(t => t.status === 'active')) return` 一致），
/// 免得多个任务同时翻页把 X 接口打出风控。
class CreationTaskStore extends ChangeNotifier {
  CreationTaskStore({
    required this.appState,
    required this.coordinator,
  });

  final AppState appState;
  final Aria2Coordinator coordinator;

  final List<CreationTask> _tasks = [];

  /// 当前队列（只读视图）。下载管理页用它渲染「共 N 个任务创建中」。
  List<CreationTask> get tasks => List.unmodifiable(_tasks);

  int get count => _tasks.length;

  /// 正在翻页的那个（没有则 null）
  CreationTask? get active {
    for (final t in _tasks) {
      if (t.isActive) return t;
    }
    return null;
  }

  int _seq = 0;
  bool _pumping = false;
  bool _disposed = false;

  /// 登记一个创建任务并返回。**同步返回**，不等待翻页 —— 这就是「点一下
  /// 「开始下载」立刻推送到下载管理」的关键。
  CreationTask create(TwitterUser user, DownloadFilter filter) {
    final t = CreationTask(
      id: 'ct_${DateTime.now().millisecondsSinceEpoch}_${_seq++}',
      user: user,
      // 快照过滤条件：之后改界面上的过滤条件不影响这个已创建的任务
      filter: filter,
    );
    _tasks.add(t);
    AppLogger.log(
      'CREATE',
      '新建创建任务 ${t.displayName}（id=${t.id}，队列 ${_tasks.length}，'
      '日期下界=${filter.dateFrom ?? "无"}，类型=${filter.mediaTypes.isEmpty ? "不限" : filter.mediaTypes.map((e) => e.name).join("/")}）',
    );
    _safeNotify();
    // 不 await —— 让它自己在后台跑
    unawaited(_pump());
    return t;
  }

  /// 取消一个任务。等待中的直接出队；正在跑的会在下一个检查点停下。
  void cancel(String id) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    final t = _tasks[idx];
    t.cancelled = true;
    AppLogger.log('CREATE', '取消创建任务 ${t.displayName}（id=$id）');
    if (!t.isActive) {
      _tasks.removeAt(idx);
    }
    _safeNotify();
  }

  // ── 后台调度 ─────────────────────────────────────────────

  /// 串行泵：一次只跑队头那个任务，跑完摘掉再取下一个。
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (!_disposed && _tasks.isNotEmpty) {
        final t = _tasks.first;

        if (t.cancelled) {
          _tasks.remove(t);
          _safeNotify();
          continue;
        }

        t.status = CreationStatus.active;
        _safeNotify();

        try {
          await _run(t);
          AppLogger.log(
            'CREATE',
            '完成创建任务 ${t.displayName}：翻页 ${t.pages} 次，'
            '发送 ${t.completeCount} 个，跳过 ${t.skipCount} 个'
            '${t.cancelled ? "（已被用户取消）" : ""}',
          );
        } catch (e) {
          t.error = e is CreationTaskException ? e.message : '$e';
          AppLogger.log('CREATE', '创建任务失败 ${t.displayName}：${t.error}');
        }

        _tasks.remove(t);
        _safeNotify();
      }
    } finally {
      _pumping = false;
    }
  }

  /// 真正的爬取循环 —— 逐行
  Future<void> _run(CreationTask t) async {
    final uid = t.user.id;
    if (uid == null || uid.isEmpty) {
      throw const CreationTaskException('未获取到用户 ID');
    }
    if (!coordinator.booted) {
      throw const CreationTaskException('aria2 未就绪，无法创建下载任务');
    }

    String? cursor;
    // 原版：let now = dayjs()，每页更新为「本页最旧一条推文的时间」，
    // 再用 now.isAfter(since) 判断是否可以收工。
    var oldest = DateTime.now();
    // 连续空了几页 —— X 到底之后每页都只回游标，靠这个收工
    var emptyStreak = 0;

    while (true) {
      if (t.cancelled || _disposed) return;

      final page = await appState.api.getUserMedias(
        uid,
        cursor: cursor,
        count: 100,
      );
      if (t.cancelled || _disposed) return;
      t.pages++;

      for (final m in page.tweets) {
        if (t.cancelled || _disposed) return;

        // 超出日期范围 / 媒体类型不符 → 不计入发送，但计入跳过（同原版 skipCount）
        if (!t.filter.accepts(m)) {
          t.skipCount++;
          continue;
        }

        final r = await coordinator.enqueueMedia(m);
        switch (r.outcome) {
          case EnqueueOutcome.queued:
            t.completeCount++;
          case EnqueueOutcome.skippedExisting:
            // 文件名已存在且开了「跳过相同文件」
            t.skipCount++;
          case EnqueueOutcome.rejected:
            // aria2 明确拒绝 —— **不能**计入「已发送」，否则界面上的
            // 数字会把没进队列的媒体也算成成功（S2 的第二层后果）。
            t.failCount++;
          // removeFailed 只出自 retryTask，入队路径不会遇到 —— 同样计入失败。
          case EnqueueOutcome.removeFailed:
            t.failCount++;
          case EnqueueOutcome.notReady:
            throw const CreationTaskException('aria2 未就绪，任务中止');
        }
      }

      // 本页最旧的时间（取最小值，接口顺序异常时也不会漏掉停止条件）
      for (final m in page.tweets) {
        final c = m.createdAt;
        if (c != null && c.isBefore(oldest)) oldest = c;
      }
      // 每页刷一次，下载管理页上能看见进度在动
      _safeNotify();

      final requested = cursor;
      final more = mediaPageHasMore(
        requestedCursor: requested,
        page: page,
        emptyPagesBefore: emptyStreak,
      );
      emptyStreak = page.tweets.isEmpty ? emptyStreak + 1 : 0;
      cursor = more ? page.nextCursor : null;
      if (cursor == null) {
        // 三种收工原因都写进日志，下次再出问题不用靠猜
        final why = page.nextCursor == null || page.nextCursor!.isEmpty
            ? '接口没再给游标'
            : page.nextCursor == requested
            ? '游标未前进'
            : '连续 $emptyStreak 页 0 条媒体';
        AppLogger.log(
          'CREATE',
          '${t.displayName}：第 ${t.pages} 页后停止翻页（$why）'
          '发送 ${t.completeCount} / 跳过 ${t.skipCount} / 失败 ${t.failCount}',
        );
        break;
      }

      // 已经翻到日期下界之前 → 收工（原版 `while (nextCursor !== null && now.isAfter(since))`）
      if (t.filter.reachedDateFloor(oldest)) {
        AppLogger.log(
          'CREATE',
          '已翻到日期下界之前（$oldest <= ${t.filter.dateFrom}），停止翻页',
        );
        break;
      }
    }
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class CreationTaskException implements Exception {
  final String message;
  const CreationTaskException(this.message);

  @override
  String toString() => 'CreationTaskException: $message';
}
