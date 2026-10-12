import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/app_paths.dart';
import '../services/aria2_coordinator.dart';
import '../services/bili_ledger.dart';
import '../services/download_store.dart';
import '../services/douyin_store.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';

/// 首页「总览」。
///
/// 软件打开时的默认落地页（`app.dart` 的 `_routeId` / `_visited` 初值都是
/// `'dashboard'`），也是「所有模块的公共入口」：快捷开始那 6 张卡把用户直接
/// 送到各模块的解析页，其余区块给出全局状态。
///
/// **它不在任何模块里**：导航上是置顶的独立项（`kNavPrimary`），因为
/// 「三个下载模块」各自完整独立，而总览是横跨它们的视图。
///
/// 数据全部**真实读取**，没有一处写死：
///   * 进行中 / 已完成 / 最近活动 ← [DownloadStore.tasks]
///   * 台账合计 / 各模块已下载 ← [BiliLedger] + `DouyinStore.ledger`
///   * 下载引擎 ← [Aria2Coordinator.engineReady]（真机实测：引擎挂掉时
///     以前界面毫无异常，这个通知量就是为了让首页如实显示）
///
/// 页面骨架照 `about_page.dart`：`ListView` + [AppCard]，颜色一律走
/// [AppTheme.colorsOf]。风格（液体玻璃 / 磨砂清晰 / 陶土）由 [AppCard]
/// 自己按 [AppTheme.surfaceOf] 决定，这里**不判断风格**。
class DashboardPage extends StatelessWidget {
  /// 页面内跳转 —— 快捷开始卡片用它把用户送到各模块。
  ///
  /// 与 `HomepagePage` / `BiliPage` 同签名，由 `app.dart` 的 `_pageFor`
  /// 注入 `_setRoute`。
  final void Function(String routeId)? onNavigate;

  const DashboardPage({super.key, this.onNavigate});

  /// 快捷开始的 6 个入口。
  ///
  /// 顺序照预览稿：第一行三个「解析」类入口，第二行三个「批量 / 自动」类。
  /// `routeId` 必须都在 [kDashboardRoutes] 与 `app.dart` 的 `_pageFor` 里有 case，
  /// 否则点下去会走 `_PagePlaceholder`。
  static const List<({String routeId, IconData icon, String title, String sub})>
  quickEntries = [
    (
      routeId: 'home',
      icon: Icons.home_rounded,
      title: 'X 主页',
      sub: '输入用户 ID 批量下载',
    ),
    (
      routeId: 'douyin',
      icon: Icons.play_circle_outline_rounded,
      title: '解析抖音作品',
      sub: '左边浏览，右边抓取',
    ),
    (
      routeId: 'bili',
      icon: Icons.live_tv_rounded,
      title: '解析 B 站稿件',
      sub: '支持合集 / 系列 / 收藏夹',
    ),
    (
      routeId: 'auto-task',
      icon: Icons.bolt_rounded,
      title: '自动执行',
      sub: '按名单批量跑 X 用户',
    ),
    (
      routeId: 'bili-batch',
      icon: Icons.playlist_play_rounded,
      title: 'B 站批量',
      sub: '主页 / 合集 / 收藏夹',
    ),
    (
      routeId: 'douyin-auto',
      icon: Icons.slow_motion_video_rounded,
      title: '抖音自动下载',
      sub: '按目标批量滚动抓取',
    ),
  ];

  /// 快捷入口的目标路由 —— 判据 4 拿它和 `kAppRoutes` 对账。
  static List<String> get quickRouteIds =>
      [for (final e in quickEntries) e.routeId];

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    // watch 而不是 read：下载进行中时条数会变，首页要跟着动。
    final downloads = context.watch<DownloadStore>();
    final bili = context.watch<BiliLedger>();
    // 抖音台账挂在 DouyinStore 上（与「下载管理（抖音）」读的是同一份）
    final douyin = context.watch<DouyinStore>().ledger;

    final tasks = downloads.tasks;
    final running = tasks.where(_isRunning).length;
    final done = tasks.where((t) => t.status == DownloadStatus.complete).length;
    final ledgerTotal = bili.count + douyin.count;

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 16),
      children: [
        // ① 欢迎条
        _HeroBar(
          colors: c,
          engineReady: Aria2Coordinator.engineReady,
        ),

        // ② 统计块 ×4
        //
        // 必须套 [IntrinsicHeight]：四张卡要等高，靠 `stretch` 才对齐；而
        // `stretch` 需要父级给一个**有限**高度，`ListView` 给的是无限 —— 直接
        // 写 `Row(crossAxisAlignment: stretch)` 会当场抛「BoxConstraints forces
        // an infinite height」。IntrinsicHeight 先把最高的一张量出来，
        // 再把那个高度给整行。
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _StatCard(
                  colors: c,
                  icon: Icons.hourglass_empty_rounded,
                  label: t('进行中'),
                  value: '$running',
                  unit: t('个'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  colors: c,
                  icon: Icons.check_circle_outline_rounded,
                  label: t('已完成'),
                  value: '$done',
                  unit: t('条'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  colors: c,
                  icon: Icons.receipt_long_rounded,
                  label: t('下载台账'),
                  value: '$ledgerTotal',
                  unit: t('条'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  colors: c,
                  icon: Icons.sd_storage_outlined,
                  label: t('磁盘占用'),
                  value: _humanBytes(_totalBytes(tasks)),
                  unit: '',
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // ③④ 两栏
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 135,
              child: Column(
                children: [
                  _QuickStartCard(
                    colors: c,
                    onNavigate: onNavigate,
                  ),
                  const SizedBox(height: 12),
                  _RecentActivityCard(colors: c, tasks: tasks),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 100,
              child: Column(
                children: [
                  _ModuleStatusCard(
                    colors: c,
                    tasks: tasks,
                    biliDone: bili.doneCount,
                    douyinDone: douyin.doneCount,
                    onNavigate: onNavigate,
                  ),
                  const SizedBox(height: 12),
                  _EngineCard(colors: c, tasks: tasks),
                  const SizedBox(height: 12),
                  _EnvironmentCard(colors: c),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 「进行中」的判据：非终态、且不是失败。
///
/// 照任务书的数据源表：`pending` / `active` / `waiting` / `paused` 四态。
/// 用 `!isTerminal` 会漏掉语义（`error` 也是终态），所以逐态写出来。
bool _isRunning(DownloadTask t) =>
    t.status == DownloadStatus.pending ||
    t.status == DownloadStatus.active ||
    t.status == DownloadStatus.waiting ||
    t.status == DownloadStatus.paused;

/// 磁盘占用：把每个任务已知的总字节加起来。
///
/// 只认 [DownloadTask.totalBytes]（aria2 给的真实大小）；没有的任务跳过 ——
/// 宁可少算也不拿进度去估一个假数出来。
int _totalBytes(List<DownloadTask> tasks) {
  var sum = 0;
  for (final t in tasks) {
    sum += t.totalBytes ?? 0;
  }
  return sum;
}

/// 字节 → 人类可读（B / KB / MB / GB）。
///
/// **不复用 `DownloadTask.downloadedReadable`**：那是任务行的逐条读数，
/// 这里要给的是四项统计里的一个聚合总量，量纲到 GB 也要显示得下。
String _humanBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  // 小于 10 的给一位小数（1.8 GB），否则取整（137 MB）—— 卡片宽度有限。
  final text = v >= 10 || i == 0 ? v.round().toString() : v.toStringAsFixed(1);
  return '$text ${units[i]}';
}

/// ① 欢迎条：应用名 + 一句话 + 引擎状态 + 版本。
class _HeroBar extends StatelessWidget {
  final AppColors colors;
  final ValueListenable<bool> engineReady;

  const _HeroBar({required this.colors, required this.engineReady});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset('assets/logo.png', fit: BoxFit.cover),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('解析下载器'),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: c.textStrong,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  t('批量下载 X、抖音与 B 站上的图片与视频'),
                  style: TextStyle(fontSize: 13.5, color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 引擎就绪信号与顶部红色告警条同源（`Aria2Coordinator.engineReady`）
          ValueListenableBuilder<bool>(
            valueListenable: engineReady,
            builder: (context, ready, _) => _Pill(
              colors: c,
              text: t(ready ? '下载引擎就绪' : '下载引擎未就绪'),
              dotColor: ready ? c.success : c.danger,
            ),
          ),
          const SizedBox(width: 8),
          _Pill(colors: c, text: 'v$kDashboardVersion'),
        ],
      ),
    );
  }
}

/// 版本号。
///
/// **不从 `app.dart` import `kAppVersion`**：那会造成 `app.dart` → 页面 →
/// `app.dart` 的循环 import。版本号本来就要跟着应用走，所以
/// `test/dashboard_page_test.dart` 有一条判据把它和 `app.dart` 的 `kAppVersion`
/// 钉在一起，改了那边不改这里会红。
const String kDashboardVersion = '1.3';

/// 小药丸标签。
class _Pill extends StatelessWidget {
  final AppColors colors;
  final String text;
  final Color? dotColor;

  const _Pill({required this.colors, required this.text, this.dotColor});

  @override
  Widget build(BuildContext context) {
    final dot = dotColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              color: colors.textNormal,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// ② 单个统计块。
class _StatCard extends StatelessWidget {
  final AppColors colors;
  final IconData icon;
  final String label;
  final String value;
  final String unit;

  const _StatCard({
    required this.colors,
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: c.accent),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(fontSize: 12.5, color: c.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              // 数值单独一个 Text：判据 2 靠它断言「真读数据」
              Text(
                value,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: c.textStrong,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  unit,
                  style: TextStyle(fontSize: 12.5, color: c.textMuted),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// ③ 快捷开始：6 张卡，两行三列。
class _QuickStartCard extends StatelessWidget {
  final AppColors colors;
  final void Function(String routeId)? onNavigate;

  const _QuickStartCard({required this.colors, required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final entries = DashboardPage.quickEntries;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SectionTitle(t('快捷开始'), c),
              const Spacer(),
              Text(
                t('点一下直达'),
                style: TextStyle(fontSize: 12, color: c.textFaint),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 两行三列：Row 套 Expanded，每行 3 张。用固定两行而不是 Wrap，
          // 窄窗口下 6 张卡会变成 3+2+1 的不齐排列，看起来像漏了一张。
          // 每行套 IntrinsicHeight 让三张卡等高（理由同统计块那一段）。
          for (var row = 0; row < 2; row++) ...[
            if (row > 0) const SizedBox(height: 10),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var col = 0; col < 3; col++) ...[
                    if (col > 0) const SizedBox(width: 10),
                    Expanded(
                      child: _QuickTile(
                        colors: c,
                        entry: entries[row * 3 + col],
                        onTap: () =>
                            onNavigate?.call(entries[row * 3 + col].routeId),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一张快捷入口卡。
class _QuickTile extends StatefulWidget {
  final AppColors colors;
  final ({String routeId, IconData icon, String title, String sub}) entry;
  final VoidCallback onTap;

  const _QuickTile({
    required this.colors,
    required this.entry,
    required this.onTap,
  });

  @override
  State<_QuickTile> createState() => _QuickTileState();
}

class _QuickTileState extends State<_QuickTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final e = widget.entry;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        // 判据 3 找的就是这个 onTap（它必须把 entry.routeId 透传给 onNavigate）
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hover ? c.accentLine : c.line,
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(e.icon, size: 18, color: _hover ? c.accent : c.textNormal),
              const SizedBox(height: 8),
              Text(
                t(e.title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: c.textStrong,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                t(e.sub),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: c.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ③ 最近活动：任务按时间倒序前 5 条。
class _RecentActivityCard extends StatelessWidget {
  final AppColors colors;
  final List<DownloadTask> tasks;

  const _RecentActivityCard({required this.colors, required this.tasks});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    // 倒序取前 5 —— 排序副本，不动 store 的列表
    final recent = [...tasks]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final top = recent.take(5).toList(growable: false);

    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SectionTitle(t('最近活动'), c),
              const Spacer(),
              Text(
                t('来自下载任务'),
                style: TextStyle(fontSize: 12, color: c.textFaint),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (top.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                t('还没有下载任务'),
                style: TextStyle(fontSize: 13, color: c.textFaint),
              ),
            )
          else
            for (final task in top) _RecentRow(colors: c, task: task),
        ],
      ),
    );
  }
}

/// 最近活动的一行：来源徽标 + 文件名 + 状态。
class _RecentRow extends StatelessWidget {
  final AppColors colors;
  final DownloadTask task;

  const _RecentRow({required this.colors, required this.task});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final source = task.media.source;
    final (badge, label) = switch (source) {
      'bili' => ('B', t('B 站')),
      'douyin' => ('抖', t('抖音')),
      _ => ('X', t('X 下载')),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.surfaceSunken,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: c.line, width: 0.8),
            ),
            child: Text(
              badge,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: c.textNormal,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              label: label,
              child: Text(
                task.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: c.textNormal),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _statusText(task.status),
            style: TextStyle(fontSize: 11.5, color: _statusColor(c, task.status)),
          ),
        ],
      ),
    );
  }
}

String _statusText(DownloadStatus s) => t(switch (s) {
  DownloadStatus.pending => '等待中',
  DownloadStatus.active => '下载中',
  DownloadStatus.waiting => '排队中',
  DownloadStatus.paused => '已暂停',
  DownloadStatus.complete => '已完成',
  DownloadStatus.error => '失败',
});

Color _statusColor(AppColors c, DownloadStatus s) => switch (s) {
  DownloadStatus.complete => c.success,
  DownloadStatus.error => c.danger,
  DownloadStatus.active => c.accent,
  _ => c.textMuted,
};

/// ④ 模块状态：三个模块各自的「进行中 / 已下载」。
class _ModuleStatusCard extends StatelessWidget {
  final AppColors colors;
  final List<DownloadTask> tasks;
  final int biliDone;
  final int douyinDone;
  final void Function(String routeId)? onNavigate;

  const _ModuleStatusCard({
    required this.colors,
    required this.tasks,
    required this.biliDone,
    required this.douyinDone,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;

    int runningOf(String source) =>
        tasks.where((t) => t.media.source == source && _isRunning(t)).length;
    int doneOf(String source) => tasks
        .where(
          (t) =>
              t.media.source == source &&
              t.status == DownloadStatus.complete,
        )
        .length;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SectionTitle(t('模块状态'), c),
              const Spacer(),
              Text(
                t('进行中 / 已下载'),
                style: TextStyle(fontSize: 12, color: c.textFaint),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _ModuleRow(
            colors: c,
            badge: 'X',
            name: t('X 下载'),
            running: runningOf('x'),
            done: doneOf('x'),
            onTap: () => onNavigate?.call('home'),
          ),
          _ModuleRow(
            colors: c,
            badge: '抖',
            name: t('抖音解析下载'),
            running: runningOf('douyin'),
            done: douyinDone,
            onTap: () => onNavigate?.call('douyin'),
          ),
          _ModuleRow(
            colors: c,
            badge: 'B',
            name: t('B 站下载'),
            running: runningOf('bili'),
            done: biliDone,
            onTap: () => onNavigate?.call('bili'),
          ),
        ],
      ),
    );
  }
}

/// 模块状态一行。
class _ModuleRow extends StatelessWidget {
  final AppColors colors;
  final String badge;
  final String name;
  final int running;
  final int done;
  final VoidCallback onTap;

  const _ModuleRow({
    required this.colors,
    required this.badge,
    required this.name,
    required this.running,
    required this.done,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.surfaceSunken,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: c.line, width: 0.8),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: c.textNormal,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: c.textNormal),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$running / $done',
                style: TextStyle(
                  fontSize: 12.5,
                  color: c.textStrong,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ④ 下载引擎：就绪状态 + 本机任务计数。
class _EngineCard extends StatelessWidget {
  final AppColors colors;
  final List<DownloadTask> tasks;

  const _EngineCard({required this.colors, required this.tasks});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final active = tasks.where((t) => t.status == DownloadStatus.active).length;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(t('下载引擎'), c),
          const SizedBox(height: 10),
          ValueListenableBuilder<bool>(
            valueListenable: Aria2Coordinator.engineReady,
            builder: (context, ready, _) => _EngineStateRow(
              colors: c,
              ready: ready,
            ),
          ),
          const SizedBox(height: 6),
          _InfoLine(
            colors: c,
            label: t('正在下载'),
            value: '$active',
          ),
          // 引擎开关本身是**只读状态展示**：aria2c 由应用在启动时拉起，
          // 界面上没有「关掉下载引擎」这个动作（关掉它等于所有下载都失败）。
          // 所以这里如实显示可用性，而不是放一个点了没用的开关。
          _InfoLine(
            colors: c,
            label: t('任务总数'),
            value: '${tasks.length}',
          ),
        ],
      ),
    );
  }
}

class _EngineStateRow extends StatelessWidget {
  final AppColors colors;
  final bool ready;

  const _EngineStateRow({required this.colors, required this.ready});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Row(
      children: [
        Icon(
          ready ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
          size: 16,
          color: ready ? c.success : c.danger,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            t(ready ? 'aria2 正在运行' : '下载引擎未就绪'),
            style: TextStyle(fontSize: 13, color: c.textStrong),
          ),
        ),
      ],
    );
  }
}

/// ④ 环境信息：数据目录 / 日志目录 / 日志开关 / 版本。
class _EnvironmentCard extends StatelessWidget {
  final AppColors colors;

  const _EnvironmentCard({required this.colors});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final settings = context.watch<SettingsStore>().settings;
    final logsOn = settings.app.writeLogs;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(t('环境'), c),
          const SizedBox(height: 10),
          _InfoLine(
            colors: c,
            label: t('数据目录'),
            value: AppPaths.ready ? AppPaths.configDir.path : t('未初始化'),
            ellipsis: true,
          ),
          _InfoLine(
            colors: c,
            label: t('日志'),
            value: t(logsOn ? '已开启' : '已关闭'),
          ),
          _InfoLine(
            colors: c,
            label: t('界面风格'),
            value: t(settings.appearance.visualStyle.label),
          ),
        ],
      ),
    );
  }
}

/// 一行「标签 + 值」。
class _InfoLine extends StatelessWidget {
  final AppColors colors;
  final String label;
  final String value;
  final bool ellipsis;

  const _InfoLine({
    required this.colors,
    required this.label,
    required this.value,
    this.ellipsis = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: ellipsis
                  ? TextOverflow.ellipsis
                  : TextOverflow.clip,
              // 路径从尾部截断（开头都是 C:\Users\xxx，留头没意义）
              textDirection: ellipsis ? TextDirection.rtl : null,
              style: TextStyle(fontSize: 12.5, color: c.textNormal),
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片小标题。
class _SectionTitle extends StatelessWidget {
  final String text;
  final AppColors c;

  const _SectionTitle(this.text, this.c);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: c.textStrong,
        letterSpacing: 0.2,
      ),
    );
  }
}
