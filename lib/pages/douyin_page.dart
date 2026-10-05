import 'dart:async';
import 'dart:math' show pi;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../models/douyin_config.dart';
import '../models/media.dart';
import '../services/app_logger.dart';
import '../services/aria2_coordinator.dart';
import '../services/douyin_filter.dart';
import '../services/douyin_groups.dart';
import '../services/douyin_interceptor_js.dart';
import '../services/douyin_parser.dart';
import '../services/douyin_scroll.dart';
import '../services/douyin_store.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/app_toast.dart';
import '../l10n/l10n.dart';

/// 「抖音」页。
///
/// **工作方式**：内嵌一个 WebView2 打开抖音网页版，并在文档创建前注入
/// [kDouyinInterceptorJs]。拦截脚本挂在页面的 XHR / fetch 出口上，
/// 把抖音自己请求回来的 `aweme` JSON 抄一份 `postMessage` 给 Dart；
/// 这边用 [parseDouyinPayload] 转成 [Media]，勾选后走**同一条**下载管线
/// （`Aria2Coordinator.enqueueMedia`）—— 也就是说文件名模板、保存目录、
/// 同名跳过、失败重试这些全都自动复用，不需要给抖音再写一套。
///
/// **为什么要真浏览器**：抖音网页版的数据接口带 `a_bogus` 签名，
/// 纯 HTTP 客户端拿不到数据（实测分享页 / 详情接口只返回校验页或空体）。
/// 本项目的做法是**不生成签名**，只读取页面自己已经取回的响应 ——
/// 平台的签名规则怎么变都不需要跟着改，浏览器扩展类工具普遍是这个思路。
///
/// **首次使用需要在窗口内登录一次**（扫码）。登录态落在
/// `<数据目录>\webview`（数据目录是 exe 同级的 `userdata`，
/// 装在哪个盘就落在哪个盘），之后长期有效。
class DouyinPage extends StatefulWidget {
  /// 页面内跳转（"去下载管理"用），与主页的 `onNavigate` 同签名。
  final void Function(String routeId)? onNavigate;

  const DouyinPage({super.key, this.onNavigate});

  @override
  State<DouyinPage> createState() => _DouyinPageState();
}

class _DouyinPageState extends State<DouyinPage> {
  WebviewController? _web;
  final List<StreamSubscription<dynamic>> _subs = [];

  // ── 滚轮接管 ────────────────────────────────────────────────
  // 插件把滚轮注入到客户区 (0,0)，而抖音的滚动容器不在那个点上（实测见
  // services/douyin_scroll.dart），所以这里自己接管：先累加几格，
  // 一个时间窗后按**真实鼠标坐标**滚一次。
  final ScrollAccumulator _scrollAcc = ScrollAccumulator();
  Offset _scrollPos = Offset.zero;
  Timer? _scrollTimer;

  /// 「自动加载」：一直往下滚，让抖音把下一页内容也吐出来
  final DouyinAutoScroller _autoScroller = DouyinAutoScroller();
  Timer? _autoTimer;

  /// WebView2 环境准备完成（可以渲染 [Webview] 了）
  bool _wvReady = false;

  /// 初始化失败的原因（含「没装 WebView2 运行时」），非空则显示占位面板
  String? _wvError;

  bool _loading = false;
  bool _canBack = false;
  bool _canForward = false;
  bool _enqueueing = false;

  /// 抓取结果详情浮层是否展开（覆盖在抖音页面上，不挤窄 WebView）
  bool _panelOpen = false;

  /// 详情浮层里**展开看逐张图**的作品 id（参照实现也是一行一作品，点开才摊开）
  final Set<String> _expanded = {};

  final TextEditingController _addr = TextEditingController();
  final ScrollController _gridScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    final store = context.read<DouyinStore>();
    _addr.text = store.lastUrl;
    // 「跳过已下载」要用台账；`main.dart` 启动时已读过一次，
    // 这里兜一层（比如将来支持热重载或从别处进页面）。
    if (!store.ledger.loaded) unawaited(store.ledger.load());
    // WebView 初始化要建原生视图，放到首帧之后，避免和布局抢时机
    WidgetsBinding.instance.addPostFrameCallback((_) => _initWebView());
  }

  @override
  void dispose() {
    _stopAutoScroll();
    _scrollTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    try {
      _web?.dispose();
    } catch (_) {
      // 原生侧可能已经随窗口销毁，忽略
    }
    _addr.dispose();
    _gridScroll.dispose();
    super.dispose();
  }

  // ── WebView 生命周期 ────────────────────────────────────────

  Future<void> _initWebView() async {
    if (!mounted) return;
    final store = context.read<DouyinStore>();

    try {
      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        _fail(
          '未检测到 Edge WebView2 运行时。\n'
          'Win11 自带；Win10 请安装「Microsoft Edge WebView2 Runtime」后重试。',
        );
        return;
      }
      AppLogger.log('DOUYIN', 'WebView2 运行时：$version');

      final ctrl = WebviewController();
      _web = ctrl;
      await ctrl.initialize();

      // 关键一步：注册后对**之后所有文档**生效（含 SPA 内部跳转产生的新文档）
      await ctrl.addScriptToExecuteOnDocumentCreated(kDouyinInterceptorJs);

      await ctrl.setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
      try {
        await ctrl.setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        );
      } catch (_) {
        // 设不上 UA 不影响使用，桌面站点照样出
      }

      _subs.add(ctrl.webMessage.listen(_onWebMessage, onError: (_) {}));
      _subs.add(
        ctrl.url.listen((u) {
          if (!mounted || u.isEmpty) return;
          setState(() {
            if (_addr.text != u) _addr.text = u;
          });
          // 换页即刻换「结果分组」：这样右侧抓取列表里只会是**当前页面**的内容
          store.setCurrentUrl(u);
        }),
      );
      _subs.add(
        ctrl.loadingState.listen((s) {
          if (!mounted) return;
          setState(() => _loading = s == LoadingState.loading);
        }),
      );
      _subs.add(
        ctrl.historyChanged.listen((h) {
          if (!mounted) return;
          setState(() {
            _canBack = h.canGoBack;
            _canForward = h.canGoForward;
          });
        }),
      );

      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() => _wvReady = true);

      final start = store.lastUrl;
      await ctrl.loadUrl(start.isEmpty ? DouyinStore.kHomeUrl : start);
    } catch (e, st) {
      AppLogger.log('DOUYIN', 'WebView 初始化失败：$e\n$st');
      _fail('$e');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _wvError = message);
  }

  /// 收到拦截脚本的批量结果。
  void _onWebMessage(dynamic msg) {
    if (!mounted) return;
    final store = context.read<DouyinStore>();

    final result = parseDouyinPayload(msg);
    if (result.media.isEmpty) return;

    final added = store.ingest(result.media);
    if (added > 0) {
      AppLogger.log(
        'DOUYIN',
        '页面出现 ${result.awemeCount} 条作品 / 新增 $added 个媒体（累计 ${store.count}）',
      );
    }
  }

  // ── 地址栏 ──────────────────────────────────────────────────

  /// 把用户输入补全成可导航的网址。
  ///
  /// 支持三种贴法：完整链接、`v.douyin.com/xxx` 短链（WebView 自己会跟 302）、
  /// 以及一串纯数字的作品 ID。
  String _normalizeInput(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return DouyinStore.kHomeUrl;
    // 与「自动下载」的目标解析共用同一套判断 —— 分享口令也能直接粘进来。
    // 认不出来时按原样交给 WebView（会显示错误页，比静默跳首页更清楚）。
    return normalizeDouyinUrl(t) ?? t;
  }

  /// 内嵌浏览器没起来、或导航动作失败时给一句人话。
  ///
  /// 以前这两条路径要么静默 `return`、要么只进日志（`writeLogs` 默认关），
  /// 而刷新与「回首页」这些按钮**永远亮着** —— 点了没反应，只能以为程序坏了。
  void _navHint(String msg) {
    if (!mounted) return;
    AppToast.show(context, msg, kind: AppToastKind.error);
  }

  Future<void> _submitAddress(String raw) async {
    final ctrl = _web;
    final target = _normalizeInput(raw);
    if (ctrl == null || !_wvReady) {
      _navHint(t('内嵌浏览器还没就绪，请稍后再试'));
      return;
    }
    try {
      await ctrl.loadUrl(target);
    } catch (e) {
      AppLogger.log('DOUYIN', '导航失败：$target — $e');
      _navHint(t('打开这个地址失败，详见日志'));
    }
  }

  Future<void> _run(String what) async {
    final ctrl = _web;
    if (ctrl == null || !_wvReady) {
      _navHint(t('内嵌浏览器还没就绪，请稍后再试'));
      return;
    }
    try {
      switch (what) {
        case 'back':
          await ctrl.goBack();
        case 'forward':
          await ctrl.goForward();
        case 'reload':
          await ctrl.reload();
        case 'home':
          await ctrl.loadUrl(DouyinStore.kHomeUrl);
        case 'devtools':
          await ctrl.openDevTools();
      }
    } catch (e) {
      AppLogger.log('DOUYIN', '导航动作 $what 失败：$e');
      _navHint(t('这个导航动作失败了，详见日志'));
    }
  }

  /// 诊断：确认拦截脚本挂上没、捞了多少条。
  Future<void> _diagnose() async {
    final ctrl = _web;
    if (ctrl == null || !_wvReady) return;
    try {
      final raw = await ctrl.executeScript(
        'JSON.stringify(window.__pdDouyinInfo ? window.__pdDouyinInfo() : {hooked:false})',
      );
      if (!mounted) return;
      AppToast.show(
          context,
          tf('拦截脚本状态：{v}', {'v': raw ?? t('无返回')}));
      AppLogger.log('DOUYIN', '诊断：$raw');
    } catch (e) {
      AppLogger.log('DOUYIN', '诊断失败：$e');
    }
  }

  // ── 入队 ────────────────────────────────────────────────────

  /// 把勾选的媒体（没勾就全部）交给 aria2。
  ///
  /// 这一步**不再直接遍历 `store.items`** —— 先过
  /// `DouyinStore.buildDownloadList(cfg)`，它会按当前设置完成参照实现
  /// 「批量下载」弹窗点「开始下载」之后的全部工作：
  ///   跳过已下载（作品粒度台账）→ 时长筛选 → 按下载源/质量策略解析地址
  ///   → 附带 BGM（图文作品、按地址去重）→ 按作品聚合。
  Future<void> _enqueue() async {
    final store = context.read<DouyinStore>();
    if (_enqueueing) return;

    final cfg = context.read<SettingsStore>().settings.douyin;
    final batch = store.buildDownloadList(cfg);

    // 一个都没剩下时也要给说法 —— 否则用户点下去毫无反应，
    // 完全不知道是「全被已下载台账挡了」还是「都被时长筛掉了」。
    if (batch.items.isEmpty) {
      final why = <String>[];
      if (batch.skippedDownloaded > 0) {
        why.add('${batch.skippedDownloaded} 个已下载作品');
      }
      if (batch.skippedDuration > 0) {
        why.add('${batch.skippedDuration} 个不符合时长范围');
      }
      AppToast.show(
        context,
        why.isEmpty ? '没有可下载的条目' : '这批全部被跳过（${why.join('，')}）',
        kind: AppToastKind.info,
        duration: const Duration(seconds: 4),
      );
      return;
    }

    setState(() => _enqueueing = true);
    var queued = 0;
    var skipped = 0;
    var notReady = 0;
    var failed = 0;

    // 每条媒体的结局 —— 台账只能记「确认进入 aria2 队列」的那些（见下），
    // 而且要连着任务 id 一起记，好让 [DouyinLedger.advance] 事后按结局推进。
    final outcomes = <({Media media, String? localId, EnqueueOutcome outcome})>[];

    try {
      final coordinator = Aria2Coordinator.instance;
      if (!coordinator.booted) {
        if (!mounted) return;
        AppToast.show(
          context,
          t('下载引擎还没起来（aria2 未就绪），请稍后重试或查看日志'),
          kind: AppToastKind.error,
        );
        return;
      }
      // 并发数是全局选项，入队前同步一次（幂等）
      await coordinator.applyConcurrency(cfg.concurrency);

      for (final m in batch.items) {
        // 传 cfg：让这次下载走**抖音自己的**文件夹 / 文件模板
        // （不传则落回 X 下载的模板，两个模块的命名规则就串了）。
        final r = await coordinator.enqueueMedia(m, douyin: cfg);
        outcomes.add((media: m, localId: r.localId, outcome: r.outcome));
        switch (r.outcome) {
          case EnqueueOutcome.queued:
            queued++;
          case EnqueueOutcome.skippedExisting:
            skipped++;
          case EnqueueOutcome.notReady:
            notReady++;
          case EnqueueOutcome.rejected:
          // removeFailed 只出自 retryTask，入队路径不会遇到 —— 一并计入失败，
          // 别让「没进队列」在任何一档被算成成功。
          case EnqueueOutcome.removeFailed:
            failed++;
        }
      }
    } finally {
      if (mounted) setState(() => _enqueueing = false);
    }

    // 写台账（作品粒度）。**只写确认进入 aria2 队列的作品**，而且写的是
    // 「在下」（pending）而不是「已下载」：
    //   * 早期实现是「整批里成功数 > 0 → 把 batch.awemeIds 整批写进台账」，
    //     于是被 aria2 拒绝的作品也被标成「已下载」；用户开着「跳过已下载」时，
    //     这些作品会被永久静默跳过，而界面上只报数不报 id，无从发现。
    //   * 再把「已下载」这一步交给 [DouyinLedger.advance]：只有该作品的
    //     任务全部成功才算下过，失败的会被撤掉，下次刷到同一作品能重试。
    final queuedByAweme = queuedTasksByAweme(outcomes);
    if (queuedByAweme.isNotEmpty) {
      await store.ledger.markQueued(queuedByAweme);
      store.refreshLedgerView();
    }

    if (!mounted) return;
    if (notReady > 0) AppLogger.log('DOUYIN', 'aria2 未就绪，$notReady 个媒体未能入队');
    AppLogger.log(
      'DOUYIN',
      '入队完成：新增 $queued / 已在磁盘 $skipped / 台账跳过 ${batch.skippedDownloaded} / '
          '时长跳过 ${batch.skippedDuration} / 未就绪 $notReady / aria2 拒绝 $failed',
    );

    final parts = <String>['已提交 $queued 个'];
    if (batch.skippedDownloaded > 0) {
      parts.add('跳过 ${batch.skippedDownloaded} 个已下载项目');
    }
    if (batch.skippedDuration > 0) {
      parts.add('时长不符跳过 ${batch.skippedDuration} 个');
    }
    if (skipped > 0) parts.add('已存在跳过 $skipped 个');
    if (notReady > 0) parts.add('未就绪 $notReady 个');
    if (failed > 0) parts.add('失败 $failed 个');

    // 代理连不上时把原因一起说出来 —— 否则用户只看到「下载失败」，
    // 完全想不到根因是代理软件没开（aria2 会报 target machine actively refused）。
    final warn = Aria2Coordinator.instance.proxyWarning;
    final msg = warn == null ? parts.join('，') : '${parts.join('，')}（$warn）';

    AppToast.show(
      context,
      msg,
      kind: (notReady > 0 || failed > 0)
          ? AppToastKind.error
          : AppToastKind.success,
      duration: const Duration(seconds: 4),
      actionLabel: widget.onNavigate == null ? null : '去下载管理',
      // 抖音页跳的必须是**抖音的**下载管理（`douyin-downloads`）。
      // 之前写成 `download-management` 是 X 模块那一份 —— 从抖音下完东西
      // 点提示跳过去，看到的是 X 的任务列表（2026-09-19 用户实测）。
      onAction: widget.onNavigate == null
          ? null
          : () => widget.onNavigate!('douyin-downloads'),
    );
  }

  // ── 下载选项（对齐参照实现「下载设置」）────────────────────────

  /// 下载源 / 质量策略 / 图片格式的三行紧凑选项。
  ///
  /// 为什么放在抓取面板里而不是只放设置页：参照实现的这套选项就长在
  /// 批量下载弹窗上，用户抓完一批会就地切换对比效果。设置页那份是
  /// **同一份数据**（`settings.douyin`），改哪边都即时生效。
  Widget _buildOptionBar(AppColors c, DouyinConfig cfg) {
    final settings = context.read<SettingsStore>();
    void set(void Function(DouyinConfig d) mutate) =>
        settings.setDouyin(mutate);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _miniDropdown<DouyinSource>(
          c,
          icon: Icons.link_rounded,
          value: cfg.source,
          items: [
            for (final s in DouyinSource.values)
              DropdownMenuItem(value: s, child: Text(s.label)),
          ],
          onChanged: (v) => set((d) => d.source = v),
        ),
        if (cfg.source.needsQualityMode) ...[
          const SizedBox(height: 5),
          _miniDropdown<DouyinQualityMode>(
            c,
            icon: Icons.high_quality_outlined,
            value: cfg.qualityMode,
            items: [
              for (final m in DouyinQualityMode.values)
                DropdownMenuItem(value: m, child: Text(m.label)),
            ],
            onChanged: (v) => set((d) => d.qualityMode = v),
          ),
        ],
        const SizedBox(height: 5),
        _miniDropdown<DouyinImageFormat>(
          c,
          icon: Icons.image_outlined,
          value: cfg.imageFormat,
          items: [
            for (final f in DouyinImageFormat.values)
              DropdownMenuItem(value: f, child: Text(f.label)),
          ],
          onChanged: (v) => set((d) => d.imageFormat = v),
        ),
      ],
    );
  }

  Widget _miniDropdown<T>(
    AppColors c, {
    required IconData icon,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required void Function(T) onChanged,
  }) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: c.line, width: 0.8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 13, color: c.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                isDense: true,
                dropdownColor: c.surfaceSolid,
                style: TextStyle(fontSize: 11.5, color: c.textStrong),
                icon: Icon(
                  Icons.expand_more_rounded,
                  size: 14,
                  color: c.textMuted,
                ),
                items: items,
                onChanged: (v) {
                  if (v != null) onChanged(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 批量选择 + 筛选入口。
  Widget _buildActionBar(AppColors c, DouyinStore store, DouyinConfig cfg) {
    final hasItems = store.count > 0;
    final filtered = store.hasFilter;

    return Row(
      children: [
        _miniAction(
          c,
          icon: Icons.play_circle_outline_rounded,
          tip: '勾选全部视频',
          enabled: hasItems,
          onTap: () => store.selectAllOfType(video: true),
        ),
        _miniAction(
          c,
          icon: Icons.photo_library_outlined,
          tip: '勾选全部图文',
          enabled: hasItems,
          onTap: () => store.selectAllOfType(video: false),
        ),
        // 自动加载：对应参照实现的「自动滚动加载」
        _miniAction(
          c,
          icon: _autoScroller.running
              ? Icons.stop_circle_outlined
              : Icons.slow_motion_video_rounded,
          tip: _autoScroller.running
              ? '停止自动加载（${_autoScroller.describe}）'
              : '自动加载：自动往下滚，把更多内容翻出来',
          enabled: _wvReady,
          active: _autoScroller.running,
          onTap: _toggleAutoScroll,
        ),
        // 跳过已下载（就是下载历史里的那些作品）
        _miniAction(
          c,
          icon: cfg.skipDownloaded
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          tip: cfg.skipDownloaded
              ? '已开启「跳过已下载」：批量下载会跳过下载历史里的作品（点一下关闭）'
              : '已关闭「跳过已下载」：批量下载会把下载过的再下一遍（点一下开启）',
          enabled: true,
          active: cfg.skipDownloaded,
          onTap: () => unawaited(_toggleSkipDownloaded()),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: hasItems ? () => _openFilter(store) : null,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: filtered ? c.accent : c.textNormal,
              side: BorderSide(color: filtered ? c.accent : c.line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
              ),
            ),
            icon: Icon(
              filtered ? Icons.filter_alt_rounded : Icons.filter_alt_outlined,
              size: 14,
            ),
            label: Text(
              filtered ? '筛选结果 ${store.visibleCount}' : '筛选',
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
        ),
        if (filtered)
          _miniAction(
            c,
            icon: Icons.filter_alt_off_outlined,
            tip: '清除筛选',
            enabled: true,
            onTap: store.clearFilter,
          ),
      ],
    );
  }

  Widget _miniAction(
    AppColors c, {
    required IconData icon,
    required String tip,
    required bool enabled,
    required VoidCallback onTap,
    bool active = false,
  }) => IconButton(
    onPressed: enabled ? onTap : null,
    tooltip: tip,
    iconSize: 16,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    color: !enabled ? c.textFaint : (active ? c.accent : c.textNormal),
    icon: Icon(icon),
  );

  // ── 自动加载 ────────────────────────────────────────────────

  /// 「自动加载」：持续往下滚，让抖音把下一页内容吐出来。
  /// 什么时候停由 [DouyinAutoScroller] 决定（轮次上限 / 连续无增长 / 手动）。
  void _toggleAutoScroll() {
    if (_autoScroller.running) {
      _stopAutoScroll();
      AppToast.show(context, t('已停止自动加载'));
    } else {
      _autoScroller.start();
      unawaited(_autoTick());
      AppToast.show(context, t('开始自动加载，到底或到上限会自动停'));
    }
    setState(() {});
  }

  void _stopAutoScroll() {
    _autoTimer?.cancel();
    _autoTimer = null;
    if (_autoScroller.running) _autoScroller.stop();
  }

  Future<void> _autoTick() async {
    final ctrl = _web;
    if (!_autoScroller.running || ctrl == null || !_wvReady) {
      _stopAutoScroll();
      if (mounted) setState(() {});
      return;
    }

    try {
      final Object? raw = await ctrl.executeScript(buildAutoScrollScript());
      final report = AutoScrollReport.decode(raw?.toString());
      final more = _autoScroller.onRoundResult(report.scrollHeight);
      if (mounted) setState(() {});
      if (!more) {
        final reason = _autoScroller.stopReason;
        AppLogger.log(
          'DOUYIN',
          '自动加载结束：${reason?.label}（${_autoScroller.describe}）',
        );
        if (mounted && reason != null) {
          AppToast.show(
            context,
            '自动加载结束：${reason.label}（${_autoScroller.describe}）',
          );
        }
        return;
      }
    } catch (e) {
      AppLogger.log('DOUYIN', '自动加载失败：$e');
      _autoScroller.stop(AutoScrollStopReason.error);
      if (mounted) setState(() {});
      return;
    }

    _autoTimer = Timer(_autoScroller.interval, () => unawaited(_autoTick()));
  }

  /// 一键开关「跳过已下载」（写在设置里，与设置页那个开关是同一个值）
  Future<void> _toggleSkipDownloaded() async {
    final settings = context.read<SettingsStore>();
    await settings.update(
      (s) => s.douyin.skipDownloaded = !s.douyin.skipDownloaded,
    );
  }

  /// 结果分组的页面切换条。
  ///
  /// 抖音切页只是换内容、不换 WebView，所以抓取结果按页面分桶；
  /// 这里只显示**当前页面**的那一桶，同时给出切回其它页面的入口。
  Widget _buildPageTabs(AppColors c, DouyinStore store) {
    final pages = store.pages;
    if (pages.length <= 1) {
      return Row(
        children: [
          Icon(Icons.tab_rounded, size: 12, color: c.textFaint),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              tf('当前页面：{page}', {
                'page': pages.isEmpty ? t('首页') : t(pages.first.label),
              }),
              style: TextStyle(fontSize: 11, color: c.textFaint),
            ),
          ),
        ],
      );
    }

    return SizedBox(
      height: 24,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pages.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final b = pages[i];
          final on = b.key == store.currentPageKey;
          return InkWell(
            onTap: () => store.selectPage(b.key),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: on
                    ? c.accent.withValues(alpha: 0.14)
                    : c.surfaceCardHover,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: on ? c.accent : c.line),
              ),
              child: Text(
                tf('{label} ({count})', {'label': t(b.label), 'count': b.count}),
                style: TextStyle(
                  fontSize: 11,
                  color: on ? c.accent : c.textMuted,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 打开筛选面板（对话弹窗）。字段与参照实现一致：
  /// 关键词 / 发布日期区间 / 作者 / 标签 / 视频时长。
  Future<void> _openFilter(DouyinStore store) async {
    final facets = store.facets;
    final result = await showDialog<DouyinFilter>(
      context: context,
      builder: (_) => _DouyinFilterDialog(
        initial: store.filter,
        authors: facets.authors,
        tags: facets.tags,
      ),
    );
    if (result == null) return;
    store.setFilter(result);
  }

  // ── 构建 ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final store = context.watch<DouyinStore>();
    // 下载源 / 质量策略 / 图片格式由设置驱动 —— 用 watch 保证改完当帧生效
    final cfg = context.watch<SettingsStore>().settings.douyin;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(c, store),
        const SizedBox(height: 12),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    _buildWebPane(c),
                    if (_panelOpen) _buildResultOverlay(c, store),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              // 侧边栏收窄一档，把宽度让给抖音页面（用户反馈页面偏小）
              SizedBox(width: 268, child: _buildCapturePane(c, store, cfg)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(AppColors c, DouyinStore store) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _navBtn('back', Icons.arrow_back_rounded, '后退', _canBack),
          _navBtn('forward', Icons.arrow_forward_rounded, '前进', _canForward),
          _navBtn('reload', Icons.refresh_rounded, '刷新', true),
          _navBtn('home', Icons.home_rounded, '抖音首页', true),
          const SizedBox(width: 6),
          Expanded(
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: c.surfaceSunken,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: c.line, width: 0.8),
              ),
              child: Center(
                child: TextField(
                  controller: _addr,
                  onSubmitted: _submitAddress,
                  textInputAction: TextInputAction.go,
                  style: TextStyle(fontSize: 12.5, color: c.textStrong),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: t('粘贴抖音链接 / 作品 ID，回车打开'),
                    hintStyle: TextStyle(fontSize: 12.5, color: c.textFaint),
                    icon: Icon(
                      Icons.link_rounded,
                      size: 15,
                      color: c.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (_loading)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(c.accent),
              ),
            )
          else
            IconButton(
              onPressed: _diagnose,
              tooltip: t('检查拦截脚本状态'),
              iconSize: 17,
              visualDensity: VisualDensity.compact,
              color: c.textMuted,
              icon: const Icon(Icons.bug_report_outlined),
            ),
          if (store.count > 0)
            Text(
              tf('已抓 {n}', {'n': store.count}),
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
        ],
      ),
    );
  }

  Widget _navBtn(String action, IconData icon, String tip, bool enabled) {
    final c = AppTheme.colorsOf(context);
    return IconButton(
      onPressed: enabled ? () => _run(action) : null,
      tooltip: tip,
      iconSize: 17,
      visualDensity: VisualDensity.compact,
      color: enabled ? c.textNormal : c.textFaint,
      icon: Icon(icon),
    );
  }

  Widget _buildWebPane(AppColors c) {
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceSolid,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.line, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildWebContent(c),
    );
  }

  Widget _buildWebContent(AppColors c) {
    final err = _wvError;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.web_asset_off_outlined, size: 40, color: c.danger),
              const SizedBox(height: 14),
              Text(
                t('内嵌浏览器不可用'),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: c.textStrong,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                err,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: c.textMuted,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() => _wvError = null);
                  _initWebView();
                },
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: Text(t('重试'), style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      );
    }

    final ctrl = _web;
    if (!_wvReady || ctrl == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation(c.accent),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              t('正在启动内嵌浏览器…'),
              style: TextStyle(fontSize: 12.5, color: c.textMuted),
            ),
          ],
        ),
      );
    }
    // 滚轮自己接管：插件那条路把事件注入到客户区 (0,0)，而抖音的滚动容器
    // 不在那个点上 → 页面一格都滑不动（实测见 services/douyin_scroll.dart）。
    return Listener(onPointerSignal: _onPointerSignal, child: Webview(ctrl));
  }

  /// 接管鼠标滚轮：先累加（一次滑动会连着来好几格），到时间窗再按真实坐标滚一次。
  ///
  /// 用的是 Flutter 给的 `scrollDelta`（逻辑像素 ≈ CSS 像素），
  /// **不做倍数换算** —— 插件那个 `×6` 正是实测里滚动量错乱的来源。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (_web == null || !_wvReady) return;

    _scrollPos = event.localPosition;
    _scrollAcc.add(event.scrollDelta.dx, event.scrollDelta.dy);
    // 窗口内已有定时器就不重复建 —— 多格合并成一次脚本调用，手感才顺
    _scrollTimer ??= Timer(
      kScrollFlushInterval,
      () => unawaited(_flushScroll()),
    );
  }

  Future<void> _flushScroll() async {
    _scrollTimer = null;
    final d = _scrollAcc.take();
    if (d.isZero) return;
    final ctrl = _web;
    if (ctrl == null || !_wvReady) return;

    try {
      final Object? raw = await ctrl.executeScript(
        buildScrollScript(
          dx: d.dx,
          dy: d.dy,
          x: _scrollPos.dx,
          y: _scrollPos.dy,
        ),
      );
      final outcome = ScrollOutcome.decode(raw?.toString());
      // 只在「没滚动 / 出错」时记日志：正常滚动每次都写会把日志冲爆
      if (!outcome.effective) {
        AppLogger.log(
          'DOUYIN',
          '滚轮未生效（${outcome.describe}）'
              ' delta=(${d.dx}, ${d.dy}) at=(${_scrollPos.dx}, ${_scrollPos.dy})',
        );
      }
    } catch (e) {
      AppLogger.log('DOUYIN', '滚轮转发失败：$e');
    }
  }

  // ── 抓取结果面板 ────────────────────────────────────────────

  Widget _buildCapturePane(AppColors c, DouyinStore store, DouyinConfig cfg) {
    final groups = store.awemeGroups;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome_motion_rounded,
                size: 16,
                color: c.accent,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  t('抓取结果'),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: c.textStrong,
                  ),
                ),
              ),
              Text(
                tf('{n} 个作品', {'n': groups.length}),
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
              // 展开成覆盖在抖音页面上的详情列表（参照实现就是浮层）
              IconButton(
                onPressed: groups.isEmpty
                    ? null
                    : () => setState(() => _panelOpen = true),
                tooltip: t('展开详情列表（覆盖在页面上）'),
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                color: c.textMuted,
                icon: const Icon(Icons.open_in_full_rounded),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildPageTabs(c, store),
          const SizedBox(height: 2),
          Text(
            store.hasFilter
                ? '已按筛选条件隐藏 ${store.allAwemeGroupCount - groups.length} 个作品'
                : (store.overflowed
                      ? '超出上限，已丢弃最早 ${store.dropped} 项'
                      : '在左侧浏览抖音，页面上出现的作品会抓到这里'),
            style: TextStyle(fontSize: 11.5, color: c.textFaint, height: 1.5),
          ),
          const SizedBox(height: 8),

          // 下载选项（下载源 / 质量优先策略 / 图片格式）
          _buildOptionBar(c, cfg),
          const SizedBox(height: 8),
          // 批量勾选 + 筛选 + 自动加载 + 跳过已下载
          _buildActionBar(c, store, cfg),
          const SizedBox(height: 4),

          Row(
            children: [
              SizedBox(
                height: 24,
                width: 24,
                child: Checkbox(
                  // 三态：勾了一部分时显示横杠。原先 value 用 bool 的 allSelected，
                  // 已选 145/156 时它是 false，全选框看着像没勾，和旁边的
                  // 「已选 145」自相矛盾。
                  value: store.selectionState,
                  tristate: true,
                  activeColor: c.accent,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: groups.isEmpty
                      ? null
                      : (v) => store.setAllSelected(v ?? false),
                ),
              ),
              const SizedBox(width: 4),
              Text(t('全选'), style: TextStyle(fontSize: 12, color: c.textNormal)),
              const Spacer(),
              Text(
                tf('已选 {n}', {'n': store.selectedCount}),
                style: TextStyle(fontSize: 11.5, color: c.textFaint),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: store.count == 0 ? null : store.clear,
                tooltip: t('清空结果'),
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                color: c.textMuted,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: groups.isEmpty
                ? _emptyHint(c, filtered: store.hasFilter)
                : _buildGrid(c, store, groups),
          ),
          const SizedBox(height: 10),
          _buildEnqueueButton(c, store),
        ],
      ),
    );
  }

  Widget _emptyHint(AppColors c, {bool filtered = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filtered
                  ? Icons.filter_alt_off_outlined
                  : Icons.movie_filter_outlined,
              size: 30,
              color: c.textFaint,
            ),
            const SizedBox(height: 12),
            Text(
              filtered
                  ? '当前筛选条件下没有条目\n\n'
                        '· 放宽关键词或日期范围\n'
                        '· 或点上面的「筛选」按钮右侧的清除图标'
                  : '还没有抓到内容\n\n'
                        '· 首次使用请先在左侧扫码登录\n'
                        '· 刷一刷首页推荐流，或打开某个作品页\n'
                        '· 抓到的条目会自动出现在这里',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: c.textMuted, height: 1.7),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(
    AppColors c,
    DouyinStore store,
    List<DouyinAwemeGroup> groups,
  ) {
    return Scrollbar(
      controller: _gridScroll,
      child: GridView.builder(
        controller: _gridScroll,
        padding: const EdgeInsets.only(right: 4),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 78,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          childAspectRatio: 1,
        ),
        itemCount: groups.length,
        itemBuilder: (context, i) => _buildTile(c, store, groups[i]),
      ),
    );
  }

  /// 侧边栏里**一个作品一方格**。图文作品只占一格（角标写「9 图」），
  /// 不再一张图一格 —— 这是用户明确要改的。
  Widget _buildTile(AppColors c, DouyinStore store, DouyinAwemeGroup g) {
    // 三态：只要勾了任何一条就要看得见（原先用 isGroupSelected 的整组判定，
    // 「勾选全部图文」后这些组永远画成没选 —— 2026-09-24 用户报的就是这个）
    final sel = store.groupSelectionOf(g);
    final picked = sel != DouyinSelection.none;
    final cover = g.coverUrl;

    return Tooltip(
      message: tf('{title}\n{type}', {'title': g.title, 'type': t(g.typeLabel)}),
      waitDuration: const Duration(milliseconds: 500),
      child: GestureDetector(
        onTap: () => store.toggleGroup(g),
        child: Container(
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(9),
            // 与页面上那圈黄框同色同宽，用户靠这个把两边对上
            border: Border.all(
              color: picked ? kMarkYellow : c.lineSoft,
              width: picked ? 2 : 0.8,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _coverImage(c, cover),

              // 类型角标：视频给播放键，图集给「N 图」
              Positioned(
                left: 3,
                bottom: 3,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        g.hasMainVideo
                            ? Icons.play_arrow_rounded
                            : Icons.photo_rounded,
                        size: 10,
                        color: Colors.white,
                      ),
                      if (!g.hasMainVideo && g.imageCount > 1)
                        Text(
                          '${g.imageCount}',
                          style: const TextStyle(
                            fontSize: 9,
                            color: Colors.white,
                            height: 1.1,
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // 勾选角标：整组勾上给对勾，只勾了一部分给横杠
              Positioned(
                right: 3,
                top: 3,
                child: Container(
                  width: 15,
                  height: 15,
                  decoration: BoxDecoration(
                    color: picked ? kMarkYellow : Colors.black.withValues(alpha: 0.42),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: picked ? kMarkYellow : Colors.white70,
                      width: 1,
                    ),
                  ),
                  child: sel == DouyinSelection.all
                      ? const Icon(
                          Icons.check_rounded,
                          size: 10,
                          color: Colors.black,
                        )
                      : sel == DouyinSelection.some
                          ? const Icon(
                              Icons.remove_rounded,
                              size: 10,
                              color: Colors.black,
                            )
                          : null,
                ),
              ),

              if (store.isGroupDownloaded(g))
                const Positioned.fill(child: _DownloadedRibbon()),
            ],
          ),
        ),
      ),
    );
  }

  /// 抖音图片 CDN 会校验来源，必须带 Referer + UA 才给图。
  Widget _coverImage(AppColors c, String? url) {
    if (url == null || url.isEmpty) {
      return Icon(Icons.image_outlined, size: 16, color: c.textFaint);
    }
    return Image.network(
      url,
      fit: BoxFit.cover,
      headers: const {
        'Referer': 'https://www.douyin.com/',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      },
      errorBuilder: (_, _, _) =>
          Icon(Icons.image_not_supported_outlined, size: 16, color: c.textFaint),
    );
  }

  // ── 抓取结果详情浮层 ──────────────────────────────────────
  //
  // 参照实现的批量下载列表是**一层盖在抖音页面上的浮层**，不把页面挤窄
  // （2026-09-19 用户明确要求照这个做法）。一行一个作品，图文不平铺。
  Widget _buildResultOverlay(AppColors c, DouyinStore store) {
    final groups = store.awemeGroups;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _panelOpen = false),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.42),
          child: Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              // 面板内的空白不该关掉浮层，这里把点击吃掉
              onTap: () {},
              child: Container(
                width: 560,
                margin: const EdgeInsets.fromLTRB(0, 14, 14, 14),
                decoration: BoxDecoration(
                  // **不能用 surfaceFloat** —— 它是 0xE0 半透明（给毛玻璃弹层设计的），
                  // 底下再叠一层黑遮罩，盖在抖音页面上就糊成一片（2026-09-19 反馈）。
                  color: c.surfaceSolid,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: c.line),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildPanelHeader(c, store, groups.length),
                    Divider(height: 1, color: c.lineSoft),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: groups.length,
                        itemBuilder: (context, i) =>
                            _buildGroupRow(c, store, groups[i]),
                      ),
                    ),
                    Divider(height: 1, color: c.lineSoft),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                      child: _buildEnqueueButton(c, store),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanelHeader(AppColors c, DouyinStore store, int n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Icon(Icons.auto_awesome_motion_rounded, size: 17, color: c.accent),
          const SizedBox(width: 8),
          Text(
            t('抓取结果'),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: c.textStrong,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            tf('{n} 个作品', {'n': n}),
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
          const Spacer(),
          Text(
            tf('已选 {n}', {'n': store.selectedCount}),
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
          IconButton(
            onPressed: () => setState(() => _panelOpen = false),
            tooltip: t('收起'),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            color: c.textMuted,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  /// 一行 = 一个作品（对齐参照实现的列表）：勾选框 + 缩略图 + 类型标签 +
  /// 标题 + 点赞/评论/收藏/分享 + 话题 + 时间。点行可以摊开看逐张图。
  Widget _buildGroupRow(AppColors c, DouyinStore store, DouyinAwemeGroup g) {
    // 与右侧格子同一套三态判定，否则浮层里看着没勾、格子里看着勾了
    final sel = store.groupSelectionOf(g);
    final picked = sel != DouyinSelection.none;
    final open = _expanded.contains(g.awemeId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (open) {
              _expanded.remove(g.awemeId);
            } else {
              _expanded.add(g.awemeId);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 26,
                  height: 26,
                  child: Checkbox(
                    // null = 半选（横杠）：勾了图但同组还带着没勾的 BGM 视频时
                    value: switch (sel) {
                      DouyinSelection.all => true,
                      DouyinSelection.some => null,
                      DouyinSelection.none => false,
                    },
                    tristate: true,
                    activeColor: c.accent,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (_) => store.toggleGroup(g),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 88,
                  height: 110,
                  child: Container(
                    decoration: BoxDecoration(
                      color: c.surfaceSunken,
                      borderRadius: BorderRadius.circular(7),
                      // 勾了就描黄框，与右侧格子、抖音页面上的框同色同宽
                      border: Border.all(
                        color: picked ? kMarkYellow : c.lineSoft,
                        width: picked ? 2 : 1,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _coverImage(c, g.coverUrl),
                        if (store.isGroupDownloaded(g))
                          const Positioned.fill(
                            child: _DownloadedRibbon(scale: 1.7),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: _TypeChip(c, t(g.typeLabel)),
                            ),
                            const WidgetSpan(child: SizedBox(width: 6)),
                            TextSpan(
                              text: g.title,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: c.textStrong,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),
                      _StatRow(c, g: g),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              [
                                for (final t in g.tags.take(3)) t,
                                if (g.createdAt != null) _clock(g.createdAt!),
                              ].join('  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: c.textFaint,
                              ),
                            ),
                          ),
                          Icon(
                            open
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            size: 17,
                            color: c.textFaint,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // 摊开：逐条媒体 + 各自勾选（图文想单挑某几张时用）
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(41, 0, 12, 10),
            child: Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final m in g.items)
                  _MiniMediaTile(
                    c: c,
                    media: m,
                    checked: store.isSelected(m.id),
                    onTap: () => store.toggle(m.id),
                  ),
              ],
            ),
          ),
        Divider(height: 1, indent: 10, color: c.lineSoft.withValues(alpha: 0.5)),
      ],
    );
  }

  static String _clock(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Widget _buildEnqueueButton(AppColors c, DouyinStore store) {
    final picked = store.selectedCount;
    final visible = store.visibleCount;
    final label = picked > 0
        ? '下载选中（$picked）'
        : (store.hasFilter ? '下载筛选结果（$visible）' : '下载全部（$visible）');

    return SizedBox(
      height: 36,
      child: FilledButton.icon(
        onPressed: visible == 0 || _enqueueing ? null : _enqueue,
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: Colors.white,
          // 不给这两条，禁用时走主题默认的灰底灰字 —— 它是面板里唯一的终点
          // 动作，灰到和面板背景糊成一片，用户分不清是"没东西可下"还是"坏了"。
          disabledBackgroundColor: c.accent.withValues(alpha: 0.28),
          disabledForegroundColor: c.textMuted,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: _enqueueing
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Colors.white),
                ),
              )
            : const Icon(Icons.download_rounded, size: 17),
        label: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 筛选面板 —— 对齐参照实现的 5 个筛选谓词。
///
/// 五个条件全部命中才入选（源码是 `every` 串联），关掉就是「不限」：
///   1. 关键词（作品描述 + 作者昵称 + 标签 拼接后子串匹配）
///   2. 发布日期（选了「日」会展开成**整天区间**，否则当天下发的作品查不到）
///   3. 作者（可多选）
///   4. 标签（任一 / 全部）
///   5. 视频时长（秒，作用于**视频本身**，图片没有时长会被排除）
class _DouyinFilterDialog extends StatefulWidget {
  final DouyinFilter initial;
  final List<String> authors;
  final List<String> tags;

  const _DouyinFilterDialog({
    required this.initial,
    required this.authors,
    required this.tags,
  });

  @override
  State<_DouyinFilterDialog> createState() => _DouyinFilterDialogState();
}

class _DouyinFilterDialogState extends State<_DouyinFilterDialog> {
  late final TextEditingController _keyword;
  late final TextEditingController _minSec;
  late final TextEditingController _maxSec;

  late DateQuickRange _quick;
  late Set<String> _authors;
  late Set<String> _tags;
  late TagMode _tagMode;
  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    final f = widget.initial;
    _keyword = TextEditingController(text: f.keyword);
    _minSec = TextEditingController(
      text: f.minDurationSec == null ? '' : '${f.minDurationSec}',
    );
    _maxSec = TextEditingController(
      text: f.maxDurationSec == null ? '' : '${f.maxDurationSec}',
    );
    _quick = f.quickRange;
    _authors = {...f.authorIds};
    _tags = {...f.tags};
    _tagMode = f.tagMode;
    _start = f.dateStart;
    _end = f.dateEnd;
  }

  @override
  void dispose() {
    _keyword.dispose();
    _minSec.dispose();
    _maxSec.dispose();
    super.dispose();
  }

  void _reset() {
    setState(() {
      _keyword.clear();
      _minSec.clear();
      _maxSec.clear();
      _quick = DateQuickRange.none;
      _authors.clear();
      _tags.clear();
      _tagMode = TagMode.any;
      _start = null;
      _end = null;
    });
  }

  DouyinFilter _collect() {
    final min = int.tryParse(_minSec.text.trim());
    final max = int.tryParse(_maxSec.text.trim());
    return DouyinFilter(
      keyword: _keyword.text.trim(),
      dateStart: _start,
      dateEnd: _end,
      quickRange: _quick,
      authorIds: _authors,
      tags: _tags,
      tagMode: _tagMode,
      minDurationSec: (min == null || min < 0) ? null : min,
      maxDurationSec: (max == null || max < 0) ? null : max,
      groupByAweme: widget.initial.groupByAweme,
    );
  }

  Future<void> _pickDate({required bool isStart}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? _start : _end) ?? now,
      firstDate: DateTime(2016),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    setState(() {
      // 选了手动日期就相当于关掉快捷范围 —— 两者互斥
      _quick = DateQuickRange.none;
      if (isStart) {
        _start = picked;
      } else {
        _end = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return AlertDialog(
      backgroundColor: c.surfaceFloat,
      title: Text(
        t('筛选抓取结果'),
        style: TextStyle(fontSize: 15, color: c.textStrong),
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ① 关键词
              _label(c, '关键词'),
              _textField(c, _keyword, '匹配作品描述 / 作者昵称 / 标签'),
              const SizedBox(height: 14),

              // ② 发布日期
              _label(c, '发布日期'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final q in DateQuickRange.values)
                    _chip(
                      c,
                      label: q.label,
                      selected: _quick == q,
                      onTap: () => setState(() {
                        _quick = q;
                        if (q != DateQuickRange.none) {
                          _start = null;
                          _end = null;
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _dateBox(c, isStart: true)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('~', style: TextStyle(color: c.textMuted)),
                  ),
                  Expanded(child: _dateBox(c, isStart: false)),
                ],
              ),
              const SizedBox(height: 14),

              // ③ 作者
              _label(
                c,
                '作者${widget.authors.isEmpty ? '' : '（${widget.authors.length}）'}',
              ),
              if (widget.authors.isEmpty)
                _hint(c, '还没有抓到作者')
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in widget.authors)
                      _chip(
                        c,
                        label: a,
                        selected: _authors.contains(a),
                        onTap: () => setState(() {
                          if (!_authors.remove(a)) _authors.add(a);
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: 14),

              // ④ 标签
              Row(
                children: [
                  _label(c, '标签'),
                  const Spacer(),
                  for (final m in TagMode.values)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _chip(
                        c,
                        label: m.label,
                        selected: _tagMode == m,
                        onTap: () => setState(() => _tagMode = m),
                      ),
                    ),
                ],
              ),
              if (widget.tags.isEmpty)
                _hint(c, '还没有抓到标签')
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in widget.tags)
                      _chip(
                        c,
                        label: t,
                        selected: _tags.contains(t),
                        onTap: () => setState(() {
                          if (!_tags.remove(t)) _tags.add(t);
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: 14),

              // ⑤ 时长
              _label(c, '视频时长（秒）'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _minSec,
                      keyboardType: TextInputType.number,
                      style: TextStyle(fontSize: 13, color: c.textStrong),
                      decoration: _decoration(c, '最短'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('~', style: TextStyle(color: c.textMuted)),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _maxSec,
                      keyboardType: TextInputType.number,
                      style: TextStyle(fontSize: 13, color: c.textStrong),
                      decoration: _decoration(c, '最长'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _hint(c, '时长筛的是视频本身时长（图片没有时长，会被排除）'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _reset,
          child: Text(t('重置'), style: TextStyle(color: c.textMuted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('取消'), style: TextStyle(color: c.textMuted)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_collect()),
          child: Text(t('应用', sense: 'filter')),
        ),
      ],
    );
  }

  Widget _label(AppColors c, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w500,
        color: c.textStrong,
      ),
    ),
  );

  Widget _hint(AppColors c, String text) =>
      Text(text, style: TextStyle(fontSize: 11.5, color: c.textFaint));

  Widget _textField(AppColors c, TextEditingController ctrl, String hint) =>
      TextField(
        controller: ctrl,
        style: TextStyle(fontSize: 13, color: c.textStrong),
        decoration: _decoration(c, hint),
      );

  InputDecoration _decoration(AppColors c, String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(fontSize: 12, color: c.textFaint),
    filled: true,
    fillColor: c.surfaceSunken,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c.line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c.line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c.accent, width: 1.4),
    ),
  );

  Widget _dateBox(AppColors c, {required bool isStart}) {
    final v = isStart ? _start : _end;
    final text = v == null
        ? '不限'
        : '${v.year}-${v.month.toString().padLeft(2, '0')}-'
              '${v.day.toString().padLeft(2, '0')}';
    final disabled = _quick != DateQuickRange.none;
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: InkWell(
        onTap: disabled ? null : () => _pickDate(isStart: isStart),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.line),
          ),
          child: Row(
            children: [
              Icon(Icons.event_outlined, size: 14, color: c.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: v == null ? c.textFaint : c.textStrong,
                  ),
                ),
              ),
              if (v != null && !disabled)
                GestureDetector(
                  onTap: () => setState(() {
                    if (isStart) {
                      _start = null;
                    } else {
                      _end = null;
                    }
                  }),
                  child: Icon(
                    Icons.close_rounded,
                    size: 13,
                    color: c.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(
    AppColors c, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(6),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: selected ? c.accent : c.surfaceSunken,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: selected ? c.accent : c.line),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          color: selected ? Colors.white : c.textNormal,
        ),
      ),
    ),
  );
}

/// 「已下载」斜缎带 —— 台账是作品粒度，所以整条作品都带。
/// 样式：绿色底、-45° 斜跨左上角、文案「已下载」。
/// 靠**外层**的 `clipBehavior` 把溢出部分裁掉，正好裁成缎带。
class _DownloadedRibbon extends StatelessWidget {
  const _DownloadedRibbon({this.scale = 1});

  /// 缎带跟着缩略图尺寸走：侧边栏小格子用默认 1，浮层里的大缩略图用 1.7
  final double scale;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Stack(
      children: [
        Positioned(
          top: 8 * scale,
          left: -16 * scale,
          child: Transform.rotate(
            angle: -pi / 4,
            child: Container(
              width: 52 * scale,
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(vertical: 1 * scale),
              color: c.success,
              child: Text(
                t('已下载'),
                style: TextStyle(
                  fontSize: 8 * scale,
                  color: c.onSuccess,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 行首的「图文 9 图 / 视频 / 实况图文 3 图」小标签
class _TypeChip extends StatelessWidget {
  const _TypeChip(this.c, this.label);

  final AppColors c;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.accentLine),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10.5, color: c.accent, height: 1.35),
      ),
    );
  }
}

/// 点赞 / 评论 / 收藏 / 分享 —— 参照实现列表里那四个数
class _StatRow extends StatelessWidget {
  const _StatRow(this.c, {required this.g});

  final AppColors c;
  final DouyinAwemeGroup g;

  @override
  Widget build(BuildContext context) {
    Widget one(IconData icon, int v) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: c.textFaint),
        const SizedBox(width: 3),
        Text('$v', style: TextStyle(fontSize: 11, color: c.textMuted)),
      ],
    );
    return Wrap(
      spacing: 12,
      runSpacing: 3,
      children: [
        one(Icons.favorite_border_rounded, g.likeCount),
        one(Icons.mode_comment_rounded, g.commentCount),
        one(Icons.star_outline_rounded, g.collectCount),
        one(Icons.share_outlined, g.shareCount),
      ],
    );
  }
}

/// 摊开一行后的单条媒体小方格：想只下其中几张图时用
class _MiniMediaTile extends StatelessWidget {
  const _MiniMediaTile({
    required this.c,
    required this.media,
    required this.checked,
    required this.onTap,
  });

  final AppColors c;
  final Media media;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 52,
        height: 62,
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: c.surfaceSunken,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: checked ? c.accent : c.lineSoft,
                    width: checked ? 1.5 : 0.8,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: (media.previewUrl ?? '').isEmpty
                    ? Icon(
                        media.type.isVideo
                            ? Icons.play_arrow_rounded
                            : Icons.photo_rounded,
                        size: 16,
                        color: c.textFaint,
                      )
                    : Image.network(
                        media.previewUrl!,
                        fit: BoxFit.cover,
                        headers: const {
                          'Referer': 'https://www.douyin.com/',
                          'User-Agent':
                              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                              '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
                        },
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.image_not_supported_outlined,
                          size: 16,
                          color: Colors.white54,
                        ),
                      ),
              ),
            ),
            Positioned(
              right: 2,
              top: 2,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: checked ? c.accent : Colors.black45,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: checked ? c.accent : Colors.white70,
                    width: 1,
                  ),
                ),
                child: checked
                    ? const Icon(
                        Icons.check_rounded,
                        size: 9,
                        color: Colors.white,
                      )
                    : null,
              ),
            ),
            Positioned(
              left: 3,
              bottom: 2,
              child: Text(
                media.type.isVideo ? '视频' : '${media.mediaIndex}',
                style: const TextStyle(
                  fontSize: 9,
                  color: Colors.white,
                  backgroundColor: Colors.black54,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
