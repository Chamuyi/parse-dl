import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../models/douyin_auto_task.dart';
import '../models/media.dart';
import '../services/app_logger.dart';
import '../services/aria2_coordinator.dart';
import '../services/douyin_auto_store.dart';
import '../services/douyin_interceptor_js.dart';
import '../services/douyin_parser.dart';
import '../services/douyin_scroll.dart';
import '../services/douyin_store.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/app_toast.dart';
import '../l10n/l10n.dart';

/// 抖音「自动下载」页 —— 对应 X 模块的「自动执行」。
///
/// **它做什么**：把你给的一批抖音链接（作者主页 / 作品 / 短链 / 纯作品 ID）
/// 逐个打开、自动往下滚、把抓到的作品交给 aria2，全程不用手动点。
///
/// **为什么必须开一个真浏览器**：抖音的数据接口带 `a_bogus` 签名，没有能直接
/// 翻页的公开接口；「按作者取全部作品」这种能力只能靠把页面滚出来。
/// 所以这里内嵌一个 WebView2，和「解析下载」页用的是同一套拦截脚本与滚动逻辑。
///
/// **状态放在 [DouyinAutoStore]**：切走页面不丢进度（本页 State 会被重建，
/// 但 store 活到进程结束）。真正需要页面持有的只有 `WebviewController`。
class DouyinAutoPage extends StatefulWidget {
  const DouyinAutoPage({super.key});

  @override
  State<DouyinAutoPage> createState() => _DouyinAutoPageState();
}

class _DouyinAutoPageState extends State<DouyinAutoPage> {
  WebviewController? _web;
  bool _wvReady = false;
  String? _wvError;
  bool _loading = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// 当前目标收集到的媒体。跑批时轮换，跑完置空。
  DouyinAutoCollector? _collector;

  final TextEditingController _input = TextEditingController();

  /// 跑批状态所在的 store。
  ///
  /// 存一份引用是为了在 `dispose` 里也能喊停 —— 跑批依赖本页持有的
  /// `WebviewController`，页面一销毁就没有东西在驱动它了，必须把状态
  /// 归零，否则用户切回来会看到一个永远停在「运行中」的假进度。
  DouyinAutoStore? _autoStore;

  /// 防止重复点「开始」
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _input.text = context.read<DouyinAutoStore>().rawText;
    unawaited(_initWebView());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _autoStore = context.read<DouyinAutoStore>();
  }

  @override
  void dispose() {
    // 页面没了就没人驱动跑批了 —— 状态归零，别留个假的「运行中」
    _autoStore?.stop();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    final ctrl = _web;
    _web = null;
    if (ctrl != null) {
      unawaited(ctrl.dispose().catchError((_) {}));
    }
    _input.dispose();
    super.dispose();
  }

  // ── WebView ────────────────────────────────────────────────

  Future<void> _initWebView() async {
    if (!mounted) return;
    try {
      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        _failWebView(
          '未检测到 Edge WebView2 运行时。\n'
          'Win11 自带；Win10 请安装「Microsoft Edge WebView2 Runtime」后重试。',
        );
        return;
      }

      final ctrl = WebviewController();
      _web = ctrl;
      await ctrl.initialize();
      await ctrl.addScriptToExecuteOnDocumentCreated(kDouyinInterceptorJs);
      await ctrl.setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
      try {
        await ctrl.setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        );
      } catch (_) {
        // 设不上 UA 不影响使用
      }

      _subs.add(ctrl.webMessage.listen(_onWebMessage, onError: (_) {}));
      _subs.add(
        ctrl.loadingState.listen((s) {
          if (!mounted) return;
          setState(() => _loading = s == LoadingState.loading);
        }),
      );

      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() => _wvReady = true);

      // 先开首页：用户可能还没登录，看到首页才知道要扫码。
      await ctrl.loadUrl(DouyinStore.kHomeUrl);
    } catch (e, st) {
      AppLogger.log('DOUYIN-AUTO', 'WebView 初始化失败：$e\n$st');
      _failWebView('$e');
    }
  }

  void _failWebView(String message) {
    if (!mounted) return;
    setState(() => _wvError = message);
  }

  /// 拦截脚本的批量结果 → 当前目标的收集器。
  void _onWebMessage(dynamic msg) {
    final collector = _collector;
    if (collector == null || !mounted) return;

    final result = parseDouyinPayload(msg);
    if (result.media.isEmpty) return;

    collector.noteAweme(result.awemeCount);
    collector.ingest(result.media);

    final auto = context.read<DouyinAutoStore>();
    final task = auto.current;
    if (task != null) {
      task.awemeCount = collector.awemeCount;
      task.mediaCount = collector.count;
      auto.refresh();
    }
  }

  // ── 跑批 ───────────────────────────────────────────────────

  Future<void> _start() async {
    final auto = context.read<DouyinAutoStore>();
    if (_busy) return;

    if (!auto.hasTargets) {
      _toast(t('先填至少一个目标'), AppToastKind.error);
      return;
    }
    final ctrl = _web;
    if (ctrl == null || !_wvReady) {
      _toast(t('内嵌浏览器还没就绪，稍等一下再开始'), AppToastKind.error);
      return;
    }
    final coordinator = Aria2Coordinator.instance;
    if (auto.autoDownload && !coordinator.booted) {
      _toast(t('下载引擎还没起来（aria2 未就绪），稍后重试'), AppToastKind.error);
      return;
    }

    _busy = true;
    if (mounted) setState(() {});

    auto.start();
    AppLogger.log('DOUYIN-AUTO', '开始跑批：${auto.total} 个目标');

    try {
      while (auto.running && auto.currentIndex < auto.total) {
        await _runOne(auto, ctrl);
        if (!auto.running) break;
        auto.advance();
      }
    } finally {
      auto.stop();
      _collector = null;
      _busy = false;
      if (mounted) setState(() {});
      AppLogger.log(
        'DOUYIN-AUTO',
        '跑批结束：完成 ${auto.settledCount}/${auto.total}，'
            '失败 ${auto.failedCount}，收集 ${auto.totalAweme} 个作品，'
            '提交 ${auto.totalQueued} 个媒体',
      );
    }
  }

  /// 跑一个目标：打开 → 滚 → 收集 → 提交。
  Future<void> _runOne(DouyinAutoStore auto, WebviewController ctrl) async {
    final task = auto.current;
    if (task == null) return;

    _collector = DouyinAutoCollector();
    task.reset();
    task.setStatus(DouyinAutoStatus.opening);
    auto.refresh();

    try {
      await ctrl.loadUrl(task.url);
      await _settle();
      if (!auto.running) return;

      task.setStatus(DouyinAutoStatus.collecting);
      auto.refresh();
      final reason = await _collect(auto, ctrl);
      if (!auto.running) return;
      if (reason == AutoScrollStopReason.reachedMaxRounds) {
        task.incomplete = true;
        AppLogger.log(
          'DOUYIN-AUTO',
          '目标「${task.label}」轮数用尽（上限 ${auto.maxRounds} 轮），'
          '已抓 ${task.awemeCount} 个作品，可能没翻完',
        );
      }

      task.setStatus(DouyinAutoStatus.downloading);
      auto.refresh();
      await _submit(auto, task);

      task.setStatus(
        task.awemeCount == 0 ? DouyinAutoStatus.empty : DouyinAutoStatus.done,
      );
    } catch (e) {
      AppLogger.log('DOUYIN-AUTO', '目标「${task.label}」失败：$e');
      task.fail(_shortError(e));
    } finally {
      // 计数在 _onWebMessage 里滚动更新，这里兜一次底
      final collector = _collector;
      if (collector != null) {
        task.awemeCount = collector.awemeCount;
        task.mediaCount = collector.count;
      }
      auto.refresh();
    }
  }

  /// 等页面加载落定，再多等一会儿让首批 aweme 到位。
  Future<void> _settle() async {
    final sw = Stopwatch()..start();
    while (_loading && sw.elapsedMilliseconds < 20000) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    // 拦截脚本是异步 postMessage 过来的，加载完成的那一刻往往还没收到。
    await Future.delayed(const Duration(milliseconds: 1800));
  }

  /// 一直往下滚，直到停止条件满足（轮次上限 / 连续无增长 / 用户停止）。
  ///
  /// 把停止原因交回调用方 —— 「到底了」和「轮数用完了」必须在界面上分开，
  /// 后者意味着这个号的作品没翻完，用户看到的「下载 N 个」是个不完整的数。
  Future<AutoScrollStopReason?> _collect(
    DouyinAutoStore auto,
    WebviewController ctrl,
  ) async {
    final scroller = DouyinAutoScroller(maxRounds: auto.maxRounds);
    scroller.start();

    while (auto.running && scroller.running) {
      final Object? raw = await ctrl.executeScript(buildAutoScrollScript());
      final report = AutoScrollReport.decode(raw?.toString());
      final more = scroller.onRoundResult(report.scrollHeight);

      final collector = _collector;
      final task = auto.current;
      if (collector != null && task != null) {
        task.awemeCount = collector.awemeCount;
        task.mediaCount = collector.count;
        auto.refresh();
      }
      if (!more) break;
      await Future.delayed(scroller.interval);
    }
    return scroller.stopReason;
  }

  /// 把当前目标收集到的媒体组装并提交给 aria2。
  Future<void> _submit(DouyinAutoStore auto, DouyinAutoTask task) async {
    final collector = _collector;
    if (collector == null || collector.count == 0) return;

    final douyin = context.read<DouyinStore>();
    final cfg = context.read<SettingsStore>().settings.douyin;

    // 与手动下载**同一套规则**：跳过已下载 → 时长筛选 → 选源 → BGM → 聚合
    final batch = DouyinStore.assemble(
      collector.items,
      cfg,
      isDownloaded: douyin.isDownloaded,
    );
    task.skippedDownloaded = batch.skippedDownloaded;
    auto.refresh();

    if (!auto.autoDownload || batch.items.isEmpty) return;

    final coordinator = Aria2Coordinator.instance;
    if (!coordinator.booted) throw StateError('aria2 未就绪');

    await coordinator.applyConcurrency(cfg.concurrency);

    final outcomes = <({Media media, String? localId, EnqueueOutcome outcome})>[];
    for (final m in batch.items) {
      if (!auto.running) break;
      final r = await coordinator.enqueueMedia(m, douyin: cfg);
      outcomes.add((media: m, localId: r.localId, outcome: r.outcome));
      task.queued = outcomes
          .where((o) => o.outcome == EnqueueOutcome.queued)
          .length;
      auto.refresh();
    }

    // 台账只记**确认进入队列**的作品，而且记的是「在下」（理由见 douyin_page）。
    // 元数据直接从入队结果里取 —— 这一批媒体不属于 DouyinStore 的抓取结果，
    // 以前借道 `markDownloaded` 从 `_items` 里找标题，自动下载那条路上永远找不到，
    // 于是下完的作品在「已下载」列表里没有标题。
    final queuedByAweme = queuedTasksByAweme(outcomes);
    if (queuedByAweme.isNotEmpty) {
      await douyin.ledger.markQueued(queuedByAweme);
      douyin.refreshLedgerView();
    }
  }

  void _stop() {
    final auto = context.read<DouyinAutoStore>();
    auto.stop();
    _toast(t('已请求停止，当前目标跑完就结束'));
  }

  // ── 目标输入 ───────────────────────────────────────────────

  Future<void> _importFile() async {
    // 先取好 —— 后面要 await 选文件/读文件，那时再用 context 就跨了异步间隙
    final auto = context.read<DouyinAutoStore>();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      final path = picked.path;
      if (path == null) return;

      String content;
      try {
        content = await File(path).readAsString();
      } catch (e) {
        _toast(tf('读取文件失败：{e}', {'e': e}), AppToastKind.error);
        return;
      }

      auto.setRawText(content);
      _input.text = content;
      if (!mounted) return;
      _toast(
          tf('已读取 {file}：识别出 {n} 个目标',
              {'file': picked.name, 'n': auto.total}),
          AppToastKind.success);
    } catch (e) {
      _toast(tf('选择文件失败：{e}', {'e': e}), AppToastKind.error);
    }
  }

  void _clearInput() {
    context.read<DouyinAutoStore>().clearText();
    _input.clear();
  }

  void _toast(String message, [AppToastKind kind = AppToastKind.info]) {
    if (!mounted) return;
    AppToast.show(context, message, kind: kind);
  }

  static String _shortError(Object e) {
    final s = e.toString().replaceFirst('Exception: ', '');
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  // ── 界面 ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final auto = context.watch<DouyinAutoStore>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(c, auto),
        const SizedBox(height: 12),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: _leftPane(c, auto)),
              const SizedBox(width: 14),
              Expanded(flex: 6, child: _browserPane(c)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolbar(AppColors c, DouyinAutoStore auto) {
    final running = auto.running;

    final String status;
    if (running) {
      status = tf('运行中 · 第 {i}/{total} 个 · {label}', {
        'i': auto.currentIndex + 1,
        'total': auto.total,
        'label': auto.current?.label ?? '',
      });
    } else if (auto.total == 0) {
      status = '未开始 · 还没有目标';
    } else if (auto.settledCount > 0) {
      status = tf('已结束 · 完成 {done}/{total} · 下载 {n} 个媒体', {
        'done': auto.settledCount,
        'total': auto.total,
        'n': auto.totalQueued,
      });
    } else {
      status = tf('未开始 · {n} 个目标待处理', {'n': auto.total});
    }

    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                running ? Icons.autorenew_rounded : Icons.bolt_rounded,
                size: 17,
                color: running ? c.accent : c.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: c.textStrong,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (running)
                OutlinedButton.icon(
                  onPressed: _stop,
                  icon: const Icon(Icons.stop_rounded, size: 16),
                  label: Text(t('停止')),
                )
              else
                FilledButton.icon(
                  onPressed: _busy ? null : _start,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(t('开始')),
                ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: auto.total == 0 ? null : auto.settledCount / auto.total,
                minHeight: 4,
                backgroundColor: c.surfaceSunken,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _leftPane(AppColors c, DouyinAutoStore auto) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        _targetCard(c, auto),
        const SizedBox(height: 12),
        _optionCard(c, auto),
        const SizedBox(height: 12),
        _taskCard(c, auto),
      ],
    );
  }

  Widget _targetCard(AppColors c, DouyinAutoStore auto) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(c, '目标', '一行一个，跑批时按顺序逐个处理'),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: c.surfaceSunken,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: c.line, width: 0.8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: TextField(
              controller: _input,
              onChanged: (v) => context.read<DouyinAutoStore>().setRawText(v),
              enabled: !auto.running,
              maxLines: 6,
              minLines: 4,
              style: TextStyle(
                fontSize: 12.5,
                color: c.textStrong,
                height: 1.6,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText:
                    t('作者主页 / 作品链接 / 短链 / 纯作品 ID，一行一个\n'
                    '分享口令整段粘进来也能认出链接'),
                hintStyle: TextStyle(
                  fontSize: 12,
                  color: c.textFaint,
                  height: 1.6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: auto.running ? null : _importFile,
                icon: const Icon(Icons.upload_file_rounded, size: 15),
                label: Text(t('从 txt 导入')),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: (auto.running || auto.rawText.isEmpty)
                    ? null
                    : _clearInput,
                icon: const Icon(Icons.clear_all_rounded, size: 15),
                label: Text(t('清空')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _parseSummary(c, auto),
        ],
      ),
    );
  }

  Widget _parseSummary(AppColors c, DouyinAutoStore auto) {
    final lines = <Widget>[];

    lines.add(
      Text(
        auto.total == 0 ? '还没有识别到目标' : '已识别 ${auto.total} 个目标（同一地址只跑一次）',
        style: TextStyle(
          fontSize: 12,
          color: auto.total == 0 ? c.textMuted : c.accentText,
        ),
      ),
    );

    if (auto.truncated > 0) {
      lines.add(const SizedBox(height: 4));
      lines.add(
        Text(
          tf('超出上限：多出的 {n} 个目标被忽略（一次最多 {max} 个）', {
            'n': auto.truncated,
            'max': DouyinAutoStore.kMaxTargets,
          }),
          style: TextStyle(fontSize: 11.5, color: c.danger, height: 1.5),
        ),
      );
    }

    if (auto.rejected.isNotEmpty) {
      final head = auto.rejected.take(3).join(' / ');
      lines.add(const SizedBox(height: 4));
      lines.add(
        Text(
          tf('认不出的 {n} 行已忽略：{head}{more}', {
            'n': auto.rejected.length,
            'head': head,
            'more': auto.rejected.length > 3 ? ' …' : '',
          }),
          style: TextStyle(fontSize: 11.5, color: c.textMuted, height: 1.5),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    );
  }

  Widget _optionCard(AppColors c, DouyinAutoStore auto) {
    final douyin = context.watch<DouyinStore>();
    final skip = context.watch<SettingsStore>().settings.douyin.skipDownloaded;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(c, '选项', '跑批策略'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('每个目标最多滚动轮数'),
                      style: TextStyle(fontSize: 13, color: c.textStrong),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      t('一轮约 0.7 秒。作者主页作品多就调大些；'
                      '太小会漏掉后面的作品。'),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: c.textMuted,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _roundPicker(c, auto),
            ],
          ),
          const SizedBox(height: 14),
          _toggleRow(
            c,
            '收集完自动下载',
            '关掉的话只收集不下载 —— 结果不进台账，可以当"看看有多少新作品"用',
            auto.autoDownload,
            auto.running ? null : (v) => auto.setAutoDownload(v),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: c.surfaceSunken,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              skip
                  ? '会跳过已下载作品：台账里已有 ${douyin.ledger.count} 个作品'
                  : '当前**不会**跳过已下载作品（在「抖音设置 → 跳过已下载作品」里开）',
              style: TextStyle(fontSize: 11.5, color: c.textMuted, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roundPicker(AppColors c, DouyinAutoStore auto) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line, width: 0.8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: auto.maxRounds,
          isDense: true,
          // surfaceCard 是半透明色（给毛玻璃卡片用的），当下拉菜单底色时
          // 展开的选项会和页面内容叠在一起看不清（2026-09-20 反馈）。
          dropdownColor: c.surfaceSolid,
          style: TextStyle(fontSize: 12.5, color: c.textStrong),
          items: [
            for (final n in DouyinAutoStore.kRoundChoices)
              DropdownMenuItem(value: n, child: Text(tf('{n} 轮', {'n': n}))),
          ],
          onChanged: auto.running
              ? null
              : (v) {
                  if (v != null) auto.setMaxRounds(v);
                },
        ),
      ),
    );
  }

  Widget _taskCard(AppColors c, DouyinAutoStore auto) {
    final tasks = auto.tasks;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(
            c,
            '任务',
            tasks.isEmpty ? '还没有目标' : '共 ${tasks.length} 个，按顺序逐个处理',
          ),
          const SizedBox(height: 8),
          if (tasks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                t('在上面填一批链接，再点右上角「开始」。'),
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
            )
          else
            for (var i = 0; i < tasks.length; i++)
              _taskRow(c, auto, i, tasks[i]),
        ],
      ),
    );
  }

  Widget _taskRow(
    AppColors c,
    DouyinAutoStore auto,
    int index,
    DouyinAutoTask task,
  ) {
    final active = auto.running && auto.currentIndex == index;
    final color = switch (task.status) {
      DouyinAutoStatus.done => c.accent,
      DouyinAutoStatus.failed => c.danger,
      DouyinAutoStatus.empty => c.textMuted,
      DouyinAutoStatus.waiting => c.textFaint,
      _ => c.accent,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: active ? c.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? c.accentLine : Colors.transparent,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: 11.5,
                color: active ? c.accentText : c.textFaint,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: active ? c.textStrong : c.textNormal,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  task.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              t(task.status.label),
              style: TextStyle(fontSize: 10.5, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _browserPane(AppColors c) {
    final err = _wvError;
    if (err != null) {
      return AppCard(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.web_asset_off_rounded, size: 34, color: c.danger),
                const SizedBox(height: 12),
                Text(
                  t('内嵌浏览器不可用'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: c.textStrong,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  err,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: c.textMuted,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final ctrl = _web;
    if (ctrl == null || !_wvReady) {
      return AppCard(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(height: 12),
              Text(
                t('正在准备内嵌浏览器…'),
                style: TextStyle(fontSize: 12.5, color: c.textMuted),
              ),
            ],
          ),
        ),
      );
    }

    return AppCard(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Webview(ctrl),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            t('跑批时这里会自动打开每个目标并往下滚，不用手动操作。'
            '如果提示登录，可以直接在这里登录 —— 登录态与「解析下载」共用。'),
            style: TextStyle(fontSize: 11, color: c.textMuted, height: 1.5),
          ),
        ],
      ),
    );
  }

  // ── 小部件 ─────────────────────────────────────────────────

  Widget _title(AppColors c, String title, String desc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: c.textStrong,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          desc,
          style: TextStyle(fontSize: 11.5, color: c.textMuted, height: 1.45),
        ),
      ],
    );
  }

  Widget _toggleRow(
    AppColors c,
    String title,
    String desc,
    bool value,
    ValueChanged<bool>? onChanged,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  color: onChanged == null ? c.textMuted : c.textStrong,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                desc,
                style: TextStyle(
                  fontSize: 11.5,
                  color: c.textMuted,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}