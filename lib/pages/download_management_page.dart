import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/creation_task.dart';
import '../services/aria2_coordinator.dart';
import '../services/creation_task_store.dart';
import '../services/download_store.dart';
import '../services/douyin_ledger.dart';
import '../services/douyin_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/download_list_item.dart';
import '../l10n/l10n.dart';
import '../services/app_logger.dart';
import '../widgets/app_toast.dart';

/// 下载管理页归属哪个模块。
///
/// 两个模块各有一个「下载管理」导航项，共用这一个页面，但**各看各的任务队列**：
/// aria2 底层只有一条队列，界面按 `Media.source` 分列 —— X 的页面里既看不到
/// 抖音的任务，也不会出现抖音的下载历史 Tab，反之同理。
enum DownloadFeed {
  x('x'),
  douyin('douyin');

  const DownloadFeed(this.source);

  /// 与 `Media.source` 对齐的取值
  final String source;

  bool get isDouyin => this == douyin;
}

/// 抖音模块独有的第 4 个 Tab 名（作品粒度的下载历史，数据就是「跳过已下载」那份台账）。
///
/// 只在这个页面出现，所以就近定义；X 模块的页面不会渲染它。
const String _kHistoryTab = '已下载（抖音）';

/// 下载管理：下载中 / 错误 / 已完成 三个 Tab，抖音模块再加一个下载历史 Tab。
///
/// 
class DownloadManagementPage extends StatefulWidget {
  final DownloadFeed feed;

  const DownloadManagementPage({super.key, this.feed = DownloadFeed.x});

  @override
  State<DownloadManagementPage> createState() => _DownloadManagementPageState();
}

class _DownloadManagementPageState extends State<DownloadManagementPage> {
  static const _tabs = [
    ('下载中', {
      DownloadStatus.active,
      DownloadStatus.waiting,
      DownloadStatus.paused,
      DownloadStatus.pending,
    }),
    ('错误', {DownloadStatus.error}),
    ('已完成', {DownloadStatus.complete}),
  ];

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final store = context.watch<DownloadStore>();
    final coordinator = Aria2Coordinator.instance;
    final feed = widget.feed;

    // 「创建中」区块只在 X 侧显示（那是 X 的翻页抓取概念），它不计入 Tab 角标 ——
    // 角标永远只反映点进来能看见的那些 aria2 任务。
    // 历史 Tab 用 doneCount：那个列表只列已下完的作品，角标得跟内容一致，
    // 不能让「还在下的」也占一个数字（点进来数不上，看着像 bug）。
    final historyCount = feed.isDouyin
        ? context.watch<DouyinStore>().ledger.doneCount
        : 0;

    final knownTabs = <String>[
      ..._tabs.map((t) => t.$1),
      if (feed.isDouyin) _kHistoryTab,
    ];
    final currentName = knownTabs.contains(store.currentTab)
        ? store.currentTab
        : _tabs.first.$1;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ① aria2 启动状态（不在顶部显示「启动中…」，避免每次切换都要抖动）
          if (!coordinator.booted)
            Container(
              margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: c.dangerSoft,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.danger.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6, color: c.danger),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t('aria2 未启动，请稍候或重启应用'),
                      style: TextStyle(fontSize: 12.5, color: c.danger),
                    ),
                  ),
                ],
              ),
            ),
          // ② 「创建中」的任务（对应原版 CreationTasks 组件）—— 只有 X 侧有翻页抓取
          if (!feed.isDouyin) const _CreationTasksSection(),

          // ③ Tab 头 + 工具栏
          Row(
            children: [
              for (final tab in _tabs)
                _TabButton(
                  label: t(tab.$1),
                  // 角标只算 aria2 里的任务，和点进去看到的列表严格一致。
                  // 原版把「创建中」的任务数也加进「下载中」角标，结果是
                  // 角标写着 16、列表却是空的（创建中的用户在上方那个区块里，
                  // 不在这个列表里）—— 看着像坏了。
                  count: store
                      .tasksByStatuses(tab.$2, source: feed.source)
                      .length,
                  selected: currentName == tab.$1,
                  onTap: () => store.setCurrentTab(tab.$1),
                ),
              if (feed.isDouyin)
                _TabButton(
                  label: t(_kHistoryTab),
                  count: historyCount,
                  selected: currentName == _kHistoryTab,
                  onTap: () => store.setCurrentTab(_kHistoryTab),
                ),
              const Spacer(),
              // 一键重试只在「错误」Tab 出现：别的 Tab 里没有可重试的东西，
              // 常驻一个灰按钮只会让人以为"全部暂停"那种全局动作。
              if (currentName == _tabs[1].$1)
                _RetryAllFailed(
                  failed: store.tasksByStatuses(_tabs[1].$2, source: feed.source),
                  coordinator: coordinator,
                ),
              _Toolbar(coordinator: coordinator, store: store, feed: feed),
              const SizedBox(width: 8),
            ],
          ),
          Divider(height: 0.5, thickness: 0.5, color: c.line),

          // ② 内容
          Expanded(
            child: currentName == _kHistoryTab
                ? const _DouyinHistoryBody()
                : _TabBody(
                    statuses: _tabs
                        .firstWhere((t) => t.$1 == currentName,
                            orElse: () => _tabs.first)
                        .$2,
                    tabName: currentName,
                    coordinator: coordinator,
                    store: store,
                    feed: feed,
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Tab 按钮 ───────────────────────────────────────────────

class _TabButton extends StatelessWidget {
  final String label;

  /// 角标数量（由父级算好：任务状态计数 + 创建任务数，或台账条数）
  final int count;

  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? c.textStrong : c.textMuted,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '($count)',
                  style: TextStyle(fontSize: 13, color: c.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 2,
              width: selected ? 24 : 0,
              decoration: BoxDecoration(
                color: c.accent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 工具栏（全部暂停 / 全部开始 / 清空已完成）─────────────

/// 「错误」Tab 的一键重试。
///
/// 逐条走的还是单条重试那个 `retryTask`，**不新造第二套重试语义** ——
/// 单条重试会换任务 id、抖音台账靠 `attachTask` 自动续上，批量走同一条路才不会
/// 出现"单条能重试、批量把台账弄丢"。
///
/// 结局只汇总成一条提示：几十条失败各弹一个 toast 等于没有提示。
class _RetryAllFailed extends StatefulWidget {
  final List<DownloadTask> failed;
  final Aria2Coordinator coordinator;

  const _RetryAllFailed({required this.failed, required this.coordinator});

  @override
  State<_RetryAllFailed> createState() => _RetryAllFailedState();
}

class _RetryAllFailedState extends State<_RetryAllFailed> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    var ok = 0, skip = 0, fail = 0;
    for (final task in widget.failed) {
      final r = await widget.coordinator.retryTask(task.localId);
      if (r.outcome == EnqueueOutcome.queued) {
        ok++;
      } else if (r.outcome == EnqueueOutcome.skippedExisting) {
        skip++;
      } else {
        fail++;
      }
    }
    if (!mounted) return;
    AppToast.show(
      context,
      tf('已重新排队 {ok} 个，{skip} 个文件已在磁盘上无需重下，{fail} 个没成功', {
        'ok': ok,
        'skip': skip,
        'fail': fail,
      }),
      kind: fail == 0 ? AppToastKind.success : AppToastKind.error,
    );
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final enabled = widget.failed.isNotEmpty && !_busy;
    return TextButton.icon(
      onPressed: enabled ? _run : null,
      icon: Icon(Icons.refresh_rounded, size: 15),
      label: Text(_busy ? t('重试中…') : tf('重试全部（{n}）', {'n': widget.failed.length})),
      style: TextButton.styleFrom(
        foregroundColor: c.accentText,
        disabledForegroundColor: c.textFaint,
        textStyle: const TextStyle(fontSize: 12),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final Aria2Coordinator coordinator;
  final DownloadStore store;
  final DownloadFeed feed;

  const _Toolbar({
    required this.coordinator,
    required this.store,
    required this.feed,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    // 计数和操作都只覆盖本模块的任务 —— 显示的是「本模块 N 个在下载」，
    // 点下去就不该把另一个模块的队列一起停掉（aria2 的 pauseAll 是全局的，
    // 所以这里逐条按 localId 暂停）。
    final active = store.tasksByStatuses(
      {DownloadStatus.active, DownloadStatus.waiting},
      source: feed.source,
    );
    final paused = store.tasksByStatuses(
      {DownloadStatus.paused},
      source: feed.source,
    );
    final completed = store.tasksByStatuses(
      {DownloadStatus.complete},
      source: feed.source,
    );

    return Row(
      children: [
        if (active.isNotEmpty)
          _ToolbarBtn(
            icon: Icons.pause_rounded,
            label: t('全部暂停'),
            onTap: () async {
              // 逐个暂停并把失败的汇总报出来 —— 以前整批静默，
              // 全部失败时界面看起来跟"按了没生效"一模一样。
              var failed = 0;
              for (final task in active) {
                if (await coordinator.pause(task.localId) != null) failed++;
              }
              if (failed == 0 || !context.mounted) return;
              AppToast.show(
                context,
                tf('{n} 个任务暂停失败', {'n': failed}),
                kind: AppToastKind.error,
              );
            },
          ),
        if (paused.isNotEmpty) ...[
          const SizedBox(width: 6),
          _ToolbarBtn(
            icon: Icons.play_arrow_rounded,
            label: t('全部继续'),
            onTap: () {
              for (final t in paused) {
                coordinator.resume(t.localId);
              }
            },
          ),
        ],
        if (completed.isNotEmpty) ...[
          const SizedBox(width: 6),
          _ToolbarBtn(
            icon: Icons.cleaning_services_outlined,
            label: t('清空已完成'),
            onTap: () => store.clearWhere(
              (t) =>
                  t.status == DownloadStatus.complete &&
                  t.media.source == feed.source,
            ),
          ),
        ],
        if (active.isEmpty && paused.isEmpty && completed.isEmpty)
          Text(
            coordinator.booted ? '暂无任务' : 'aria2 未启动',
            style: TextStyle(fontSize: 12.5, color: c.textMuted),
          ),
      ],
    );
  }
}

class _ToolbarBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ToolbarBtn(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: c.textMuted,
        textStyle: const TextStyle(fontSize: 12.5),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 14),
      label: Text(label),
    );
  }
}

// ── Tab 内容（真实列表）──────────────────────────────────

class _TabBody extends StatelessWidget {
  final Set<DownloadStatus> statuses;
  final String tabName;
  final Aria2Coordinator coordinator;
  final DownloadStore store;
  final DownloadFeed feed;

  const _TabBody({
    required this.statuses,
    required this.tabName,
    required this.coordinator,
    required this.store,
    required this.feed,
  });

  @override
  Widget build(BuildContext context) {
    final tasks = store.tasksByStatuses(statuses, source: feed.source);

    if (tasks.isEmpty) {
      return _EmptyHint(
        name: tabName,
        // 引导语按模块给：抖音侧不该看到「主页 / 自动执行页」这种 X 模块的页面名
        hint: feed.isDouyin
            ? '在解析下载页或自动下载页勾选作品后，\n任务会出现在这里'
            : '在主页或自动执行页选择媒体后，\n任务会出现在这里',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      itemCount: tasks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final t = tasks[i];
        return DownloadListItem(
          task: t,
          onPause: () async {
            final why = await coordinator.pause(t.localId);
            if (why == null || !context.mounted) return;
            AppToast.show(context, why, kind: AppToastKind.error);
          },
          onResume: () => coordinator.resume(t.localId),
          onRetry: () async {
            // 以前整个 EnqueueResult 被丢掉：aria2 未就绪时 retryTask 返回
            // notReady，什么都不发生，任务原地不动 —— 看起来就是按钮坏了。
            //
            // 旧任务没能从引擎里移掉时（removeFailed）引擎原文在 `message` 里，
            // 优先按它提示：只给一句「重试失败」等于没说。
            final r = await coordinator.retryTask(t.localId);
            if (!context.mounted) return;
            if (r.outcome == EnqueueOutcome.queued) return;
            AppToast.show(
              context,
              r.message ?? _retryOutcomeText(r.outcome),
              kind: r.outcome == EnqueueOutcome.skippedExisting
                  ? AppToastKind.info
                  : AppToastKind.error,
            );
          },
          onRemove: () async {
            final r = await coordinator.remove(t.localId);
            if (!context.mounted) return;
            switch (r.outcome) {
              case RemoveOutcome.failed:
                // 引擎那边没谈拢：行留在列表里，让用户看得见、重试得到
                AppToast.show(context, r.message!, kind: AppToastKind.error);
              case RemoveOutcome.alreadyGone:
                // 引擎里本来就没有它了 —— 行已删，说一句就够，不该是红色错误
                AppToast.show(context, _alreadyGoneText(),
                    kind: AppToastKind.info);
              case RemoveOutcome.removed:
                break;
            }
          },
          onOpenFolder: () => _openFolder(context, t.saveDir),
        );
      },
    );
  }

  /// 重试结局 → 给用户看的话。
  ///
  /// 单独成方法是因为列表项里有 `final t = tasks[i]`，它把 l10n 的 `t()`
  /// 函数遮蔽掉了，文案只能在这一层之外取。
  static String _retryOutcomeText(EnqueueOutcome o) => switch (o) {
        EnqueueOutcome.queued => '',
        EnqueueOutcome.skippedExisting => t('文件已经在磁盘上，没有重复下载'),
        EnqueueOutcome.notReady => t('下载引擎还没起来（aria2 未就绪），请稍后重试'),
        EnqueueOutcome.rejected => t('重试失败：下载引擎拒绝了这条任务'),
        // 正常路径下 retryTask 会带上引擎原文（走 message），这里是兜底。
        EnqueueOutcome.removeFailed =>
          t('重试已取消：旧任务没能从下载引擎里移除，它还留在列表里'),
      };

  /// 「引擎里已经没有这条任务」时给用户看的话。
  ///
  /// 和 [_retryOutcomeText] 同一个原因单独成方法：列表项里有 `final t = tasks[i]`，
  /// 它把 l10n 的 `t()` 遮蔽掉了，文案只能在这一层之外取。
  static String _alreadyGoneText() => t('引擎里已经没有它了，已从列表移除');

  /// 在资源管理器里打开这条任务的保存目录。
  ///
  /// 三处按同一类 bug 修掉（2026-09-24，与「暂停后无法继续」是同一个毛病：
  /// 用户点了、没反应、日志里也查不到）：
  ///   1. 原先失败只 `debugPrint`，不写日志文件也没有任何界面提示；
  ///   2. 原先拿 `exitCode != 0` 当失败判据 —— 不可靠，`explorer.exe` 打开成功
  ///      也常常回非 0，真失败时反倒可能回 0。改成**先查目录在不在**；
  ///   3. `path.isEmpty` 原先直接 return，等于按钮是死的。
  Future<void> _openFolder(BuildContext context, String path) async {
    void tell(String msg) {
      AppLogger.log('DOWNLOAD', msg);
      // _TabBody 是 StatelessWidget，没有自己的 mounted；跨过一次 await 之后
      // 要用 context.mounted 守一下，否则节点已拆、toast 会抛。
      if (!context.mounted) return;
      AppToast.show(context, msg, kind: AppToastKind.error);
    }

    if (path.isEmpty) {
      tell('这条任务没有记录保存目录');
      return;
    }
    if (!await Directory(path).exists()) {
      tell('目录还不存在：$path');
      return;
    }
    try {
      await Process.run('explorer.exe', [path]);
    } catch (e) {
      tell('打开文件夹失败：$e');
    }
  }
}

// ── 「创建中」的任务 ─────────────────────────────────────────

/// 下载管理页顶部的「共 N 个任务创建中」区块。
///
/// 列表为空时整块不渲染；每个任务显示头像 + 昵称 + 已发送 / 已跳过 + 取消。
///
/// 这是「主页点一下就把任务推到下载管理」的可见证据 —— 任务在翻页期间一直留在这里，
/// `已发送` 会随每页递增。
class _CreationTasksSection extends StatelessWidget {
  const _CreationTasksSection();

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final store = context.watch<CreationTaskStore>();
    final tasks = store.tasks;
    if (tasks.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: c.accent,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                tf('共 {n} 个任务创建中', {'n': tasks.length}),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.textStrong,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  t('正在读取该用户的媒体并加入下载队列'),
                  style: TextStyle(fontSize: 11.5, color: c.textFaint),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 任务多时限高滚动（原版是 max-h-40 overflow-y-auto）
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 140),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final t in tasks) _CreationTaskRow(task: t),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreationTaskRow extends StatelessWidget {
  final CreationTask task;

  const _CreationTaskRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final cs = context.read<CreationTaskStore>();
    final avatar = task.user.avatar;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          // 头像
          ClipOval(
            child: avatar == null || avatar.isEmpty
                ? Container(
                    width: 20,
                    height: 20,
                    color: c.surfaceCardHover,
                    child: Icon(Icons.person, size: 12, color: c.textFaint),
                  )
                : Image.network(
                    avatar,
                    width: 20,
                    height: 20,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 20,
                      height: 20,
                      color: c.surfaceCardHover,
                      child: Icon(Icons.person, size: 12, color: c.textFaint),
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          // 昵称 + @用户名
          Expanded(
            child: Text(
              task.user.screenName == null
                  ? task.displayName
                  : '${task.displayName} @${task.user.screenName}',
              style: TextStyle(fontSize: 12.5, color: c.textStrong),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          // 已发送 / 已跳过（跳过的原因见 tooltip）
          Text(
            tf('已发送：{n}', {'n': task.completeCount}),
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
          if (task.skipCount > 0) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: t('以下几种情况会跳过：\n'
                  '1. 文件名已存在且开启了「跳过相同文件」开关；\n'
                  '2. 推文时间超出设定的日期范围。'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(tf('已跳过：{n}', {'n': task.skipCount}),
                      style: TextStyle(fontSize: 12, color: c.textMuted)),
                  const SizedBox(width: 3),
                  Icon(Icons.help_outline_rounded,
                      size: 12, color: c.accent),
                ],
              ),
            ),
          ],
          if (task.failCount > 0) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: t('aria2 拒绝了这些任务，详情见「失败」Tab'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(tf('失败：{n}', {'n': task.failCount}),
                      style: TextStyle(fontSize: 12, color: c.danger)),
                  const SizedBox(width: 3),
                  Icon(Icons.help_outline_rounded,
                      size: 12, color: c.danger),
                ],
              ),
            ),
          ],
          if (task.error != null) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: task.error!,
              child: Icon(Icons.error_outline_rounded,
                  size: 14, color: c.danger),
            ),
          ],
          const SizedBox(width: 4),
          TextButton(
            onPressed: () => cs.cancel(task.id),
            style: TextButton.styleFrom(
              foregroundColor: c.danger,
              textStyle: const TextStyle(fontSize: 12),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(t('取消')),
          ),
        ],
      ),
    );
  }
}

// ── 「已下载（抖音）」Tab ─────────────────────────────────────


/// 抖音下载历史（**作品粒度**）。
///
/// 数据就是「跳过已下载」用的那份台账（`douyin_downloaded.json`）。
/// 所以在这里删掉一条，下次批量下载就会重新下载它 —— 这也是它放在
/// 「下载管理」而不是抖音页里的原因：它管的是「下过什么」。
class _DouyinHistoryBody extends StatelessWidget {
  const _DouyinHistoryBody();

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final ledger = context.watch<DouyinStore>().ledger;

    return ListenableBuilder(
      listenable: ledger,
      builder: (context, _) {
        final records = ledger.records;
        if (records.isEmpty) {
          return _EmptyHint(
            name: _kHistoryTab,
            title: t('还没有下载记录'),
            hint: t('勾选作品加入下载队列后就会记在这里。\n'
                '记录按「作品」计，下次批量下载会跳过它们。'),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
              child: Row(
                children: [
                  Icon(Icons.history_rounded, size: 15, color: c.accent),
                  const SizedBox(width: 7),
                  Text(
                    tf('共 {n} 个作品', {'n': records.length}),
                    style: TextStyle(fontSize: 12.5, color: c.textMuted),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _confirmClear(context, ledger),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 15),
                    label: Text(t('清空')),
                    style: TextButton.styleFrom(
                      foregroundColor: c.danger,
                      textStyle: const TextStyle(fontSize: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                itemCount: records.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) =>
                    _historyRow(c, ledger, records[i]),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _historyRow(
      AppColors c, DouyinLedger ledger, DouyinDownloadRecord r) {
    final title = (r.title?.isNotEmpty ?? false) ? r.title! : '作品 ${r.awemeId}';
    final author = (r.author?.isNotEmpty ?? false) ? r.author! : '作者未知';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: c.surfaceCardHover,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line),
      ),
      child: Row(
        children: [
          Icon(Icons.smart_display_outlined, size: 16, color: c.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: c.textStrong),
                ),
                const SizedBox(height: 3),
                Text(
                  '$author · ${_formatTime(r.time)} · ID ${r.awemeId}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: c.textFaint),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            onPressed: () => ledger.remove(r.awemeId),
            tooltip: t('从历史中移除（下次会重新下载）'),
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            color: c.textMuted,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, DouyinLedger ledger) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('清空下载历史？')),
        content: Text(t('清空之后，下次批量下载就不会再跳过这些作品了。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t('清空')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 以前清完不吭声，也不知道有没有真的写回磁盘 —— 而台账没清干净的话，
    // 下次批量下载会继续静默跳过那批作品。
    final cleared = await ledger.clear();
    if (!context.mounted) return;
    AppToast.show(
      context,
      cleared ? t('已清除抖音下载记录') : t('清除失败：记录文件写入出错，记录还在'),
      kind: cleared ? AppToastKind.success : AppToastKind.error,
    );
  }

  static String _formatTime(DateTime? t) {
    if (t == null) return '时间未知';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}

class _EmptyHint extends StatelessWidget {
  final String name;

  /// 空态标题（默认「<名字> 里还没有任务」；带括号的 Tab 名这么套不通顺，可覆盖）
  final String? title;

  /// 空态说明 —— 必须显式给：两个模块的入口页名不同，写死默认值会串到对方模块
  final String hint;

  const _EmptyHint({required this.name, required this.hint, this.title});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_download_outlined,
              size: 56, color: c.textFaint),
          const SizedBox(height: 14),
          Text(
            // Tab 名直接拼会写成「下载中 里还没有任务」——那个空格是模板带的，
            // 读起来像漏字。用「」把 Tab 名框住。
            title ?? '「$name」里还没有任务',
            style: TextStyle(fontSize: 14, color: c.textMuted),
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: c.textFaint, height: 1.6),
          ),
        ],
      ),
    );
  }
}