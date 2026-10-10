import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../l10n/l10n.dart';
import '../models/bili_config.dart';
import '../models/bili_meta.dart';
import '../models/media.dart';
import '../services/aria2_coordinator.dart';
import '../services/app_logger.dart';
import '../services/bili_api.dart';
import '../services/bili_download_plan.dart';
import '../services/bili_feed.dart';
import '../services/bili_ledger.dart';
import '../services/bili_link.dart';
import '../services/bili_store.dart';
import '../services/bili_web.dart';
import '../services/file_name_template.dart' show resolveVariables;
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/app_toast.dart';

/// 「B 站解析下载」页。
///
/// **工作方式**：左边内嵌一个 WebView2 打开 bilibili.com，右边是操作面板。
/// 两条取列表的路都**不靠劫持页面**：
///   * 「取主页推荐」在页面里发 `fetch(..., {credentials:'include'})`
///     （见 [BiliInPage]）—— B 站的登录态是 HttpOnly Cookie，我们读不到也
///     导不出，但它就在这个 WebView 的会话里；让页面自己去问，Cookie /
///     Referer / Origin 全由浏览器补，我们**不需要碰凭据**。
///   * 「解析这条链接」走 [BiliApi]（纯 HTTP + WBI 签名），匿名也能取到 480P，
///     是「没登录也能用」的兜底路径。
/// 下载与抖音共用同一条管线：`playurl` → [planBiliStreams] → [biliPairToMedias]
/// → `Aria2Coordinator.enqueueBiliMedia`，所以文件名模板、保存目录、同名跳过、
/// 失败重试全部复用，不需要给 B 站再写一套。
///
/// **刻意没有的东西**（相对抖音页）：拦截脚本、无限滚动、按页面分桶、自动下滑。
/// B 站这一路是「粘一条链接 → 展开这个稿件的分 P」，一次一批，没有滚动。
/// 「自动下载」属 P2/P3，现在挂上来就是个白屏入口，所以导航里也没有它。
class BiliPage extends StatefulWidget {
  /// 页面内跳转（"去下载管理"用），与抖音页同签名。
  final void Function(String routeId)? onNavigate;

  const BiliPage({super.key, this.onNavigate});

  @override
  State<BiliPage> createState() => _BiliPageState();
}

/// 内嵌浏览器的起始地址。
const String kBiliHomeUrl = 'https://www.bilibili.com/';

/// 主页推荐接口（**要 WBI 签名**，所以每次都得先拿密钥再拼完整地址）。
const String kBiliFeedPath = '/x/web-interface/wbi/index/top/feed/rcmd';

/// ── 纯函数：界面上那几个「说人话」的地方 ──────────────────────────
/// 单独拎出来是为了能被 widget 测试直接钉住 —— 这三处的文案混淆是真会发生的：
/// 把「检测不到」写成「未登录」，用户会去扫码，而根因是被风控。

/// 登录态那一行的文案。三态（[BiliLoginState.unknown] 不等于未登录）刻意分开说。
String biliLoginLineText(BiliLoginState? s) {
  if (s == null) return t('登录状态还没检测');
  if (s.unknown) return t('检测不到登录状态（被风控或页面没就绪）');
  if (s.isLoggedIn) {
    return s.uname.isEmpty
        ? t('已登录（没取到昵称）')
        : tf('已登录：{name}', {'name': s.uname});
  }
  return t('未登录（只能取到 480P）');
}

/// 时长 `mm:ss` / `h:mm:ss`；拿不到时长就回空串（而不是「0:00」那种假数字）。
String biliClockText(int? ms) {
  final s = (ms ?? 0) ~/ 1000;
  if (s <= 0) return '';
  String p2(int v) => v.toString().padLeft(2, '0');
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  return h > 0 ? '$h:${p2(m)}:${p2(sec)}' : '$m:${p2(sec)}';
}

/// 分 P 号那一枚 `P01` 形状的标记。
///
/// **直接借模板引擎**（`<P%P%>` 的可选段规则）而不是在这里再算一遍补零：
/// 界面上看到的分 P 号必须和落盘文件名里那段一致，两处各写一份迟早会对不上。
/// 单 P 稿件 `%P%` 取到 0 → 整段消失 → 这里回空串，界面就不画这枚标记。
String biliPartBadgeText(Media m) => resolveVariables('<P%P%>', m).trim();

/// 把选流结果里的画质 / 编码标签补进这条分 P。
///
/// 为什么必须在**选流之后**：`%QUALITY%` / `%CODEC%` 读的是 `Media.bili` 里这两个
/// 标签（见 `file_name_template.dart`），而它们只有等 `planBiliStreams` 挑出实际
/// 档位才知道该写什么 —— 列表里那批 `biliPartMedia()` 刻意不带标签，
/// 因为「上限 1080P60」与「这次真拿到 1080P」是两件事，写早了就是替用户说谎。
Media biliPartWithLabels(
  Media part, {
  required int videoQn,
  required BiliCodec? codec,
  required BiliPlayUrl r,
}) {
  final b = part.bili;
  if (b == null) return part;
  // 档位文案优先用响应里 `support_formats` 给的那一份（它才是 B 站自己怎么说这一档的），
  // 查不到才退回内置的短标签表。
  final fromResponse = r.video
      .where((s) => s.id == videoQn && !s.isAudio)
      .map((s) => s.qualityLabel)
      .firstWhere((label) => label.isNotEmpty, orElse: () => '');
  return part.copyWith(
    bili: BiliMeta(
      workTitle: b.workTitle,
      partTitle: b.partTitle,
      bvid: b.bvid,
      aid: b.aid,
      cid: b.cid,
      partTotal: b.partTotal,
      qualityLabel:
          fromResponse.isNotEmpty ? fromResponse : (kBiliQualityNames[videoQn] ?? ''),
      codecLabel: codec == null ? '' : biliCodecLabel(codec),
    ),
  );
}

class _BiliPageState extends State<BiliPage> {
  WebviewController? _web;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// WebView2 环境准备完成（可以渲染 [Webview] 了）
  bool _wvReady = false;

  /// 初始化失败的原因（含「没装 WebView2 运行时」），非空则显示占位面板
  String? _wvError;

  bool _loading = false;
  bool _canBack = false;
  bool _canForward = false;

  /// 接口客户端：**刻意留在页面 State 里而不是塞进 BiliStore**。
  /// `BiliStore` 只管「有哪些结果 / 选了哪些」，而这一个对象手里握着登录态，
  /// 它不该被序列化、也不该在切页面时被当成结果一起重建。
  BiliApi? _api;

  /// 给 [_api] 的 cookie。**由登录层注入，本期不实现** ——
  /// 留这个字段是为了让「cookie 从哪来」只有一处，而不是散在三四个地方。
  /// 本期不做任何读盘 / 导出 cookie 的代码：B 站的登录态只活在 WebView2 的会话里，
  /// 页面里那条 `fetch` 才是它的唯一出口（见 `bili_web.dart`）。
  String? _cookieForApi;

  BiliLoginState? _login;
  bool _loginChecking = false;

  /// 页面首次就绪后只自动查一次登录态（**不用 Timer.periodic**：
  /// 轮询会把 widget 测试挂住，而且这一步本来就该是人点的）。
  bool _loginProbed = false;

  /// 本地闸门：一次「取列表 / 下载」正在跑，禁掉所有动作按钮。
  /// 与 `store.busy` 的分工：busy 是给界面显示用的状态，这个字段是防重入的。
  bool _working = false;

  final TextEditingController _addr = TextEditingController(text: kBiliHomeUrl);
  final TextEditingController _link = TextEditingController();

  @override
  void initState() {
    super.initState();
    _api = BiliApi(cookie: _cookieForApi);
    // WebView 初始化要建原生视图，放到首帧之后，避免和布局抢时机
    WidgetsBinding.instance.addPostFrameCallback((_) => _initWebView());
  }

  @override
  void dispose() {
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
    _link.dispose();
    super.dispose();
  }

  // ── WebView 生命周期 ────────────────────────────────────────

  /// 生命周期照抖音页那一条：判运行时 → 建控制器 → initialize →
  /// 弹窗策略 → 试设 UA → 订阅 url / loadingState / historyChanged。
  ///
  /// **唯一但关键的差别**：这里**不注册** `addScriptToExecuteOnDocumentCreated`
  /// 那类拦截脚本。抖音要靠它把页面自己请求回来的 JSON 抄一份给我们，
  /// 而 B 站的接口是公开可得 + 可自己签名的：我们只在页面里发一条自己的
  /// `fetch`，不需要劫持任何人。少一层注入就少一类「页面升级后脚本失效」。
  Future<void> _initWebView() async {
    if (!mounted) return;

    try {
      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        _fail(t('未检测到 Edge WebView2 运行时。\n'
            'Win11 自带；Win10 请安装「Microsoft Edge WebView2 Runtime」后重试。'));
        return;
      }
      AppLogger.log('BILI', 'WebView2 运行时：$version');

      final ctrl = WebviewController();
      _web = ctrl;
      await ctrl.initialize();
      await ctrl.setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
      try {
        // UA 与接口层、下载器**同一份**：三处只要差一个版本号，就会出现
        // 「页面能播、接口能查、下载 403」这种极难归因的组合。
        await ctrl.setUserAgent(kBiliUserAgent);
      } catch (_) {
        // 设不上 UA 不影响使用，桌面站点照样出
      }

      _subs.add(
        ctrl.url.listen((u) {
          if (!mounted || u.isEmpty) return;
          setState(() {
            if (_addr.text != u) _addr.text = u;
          });
        }),
      );
      _subs.add(
        ctrl.loadingState.listen((s) {
          if (!mounted) return;
          final loading = s == LoadingState.loading;
          setState(() => _loading = loading);
          // 首份文档加载完就查一次登录态（只查这一次）
          if (!loading && !_loginProbed) {
            _loginProbed = true;
            unawaited(_checkLogin());
          }
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
      await ctrl.loadUrl(kBiliHomeUrl);
    } catch (e, st) {
      AppLogger.log('BILI', 'WebView 初始化失败：$e\n$st');
      _fail('$e');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _wvError = message);
  }

  /// 内嵌浏览器没起来、或导航动作失败时给一句人话。
  ///
  /// 与抖音页同一个理由：这些按钮**永远亮着**，静默 return 的话用户只能以为程序坏了。
  void _navHint(String msg) {
    if (!mounted) return;
    AppToast.show(context, msg, kind: AppToastKind.error);
  }

  Future<void> _submitAddress(String raw) async {
    final ctrl = _web;
    final target = raw.trim();
    if (ctrl == null || !_wvReady) {
      _navHint(t('内嵌浏览器还没就绪，请稍后再试'));
      return;
    }
    if (target.isEmpty) return;
    try {
      await ctrl.loadUrl(target);
    } catch (e) {
      AppLogger.log('BILI', '导航失败：$target — $e');
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
          await ctrl.loadUrl(kBiliHomeUrl);
      }
    } catch (e) {
      AppLogger.log('BILI', '导航动作 $what 失败：$e');
      _navHint(t('这个导航动作失败了，详见日志'));
    }
  }

  // ── 登录态 ──────────────────────────────────────────────────

  /// 查一次登录态。刷新按钮和页面首次就绪各调一次，**没有轮询**。
  Future<void> _checkLogin() async {
    final ctrl = _web;
    if (ctrl == null || !_wvReady || _loginChecking) return;
    setState(() => _loginChecking = true);
    final s = await BiliInPage.loginState(ctrl);
    if (!mounted) return;
    setState(() {
      _login = s;
      _loginChecking = false;
    });
    // 未登录不是错误，所以不弹提示条 —— 那一行文案自己会说明只拿得到 480P。
  }

  // ── 取列表：主页推荐 ────────────────────────────────────────

  /// 签名在 Dart 侧算、凭据在浏览器侧带 —— 两边都不越界（见 [BiliInPage]）。
  ///
  /// `BiliApi` 自己没有「用页内 fetch 发请求」这条路：它的 `_signedData` 走的是
  /// dart:io 的 HttpClient，那种请求**没有登录态**（这一版 cookie 也不进它），
  /// 所以个性化推荐必须由页面在 WebView 里发。
  Future<void> _fetchFeed() async {
    final ctrl = _web;
    final api = _api;
    final store = context.read<BiliStore>();
    if (ctrl == null || !_wvReady || api == null) {
      _navHint(t('内嵌浏览器还没就绪，请稍后再试'));
      return;
    }
    if (_working) return;
    setState(() => _working = true);
    store.setBusy(true);
    try {
      final keys = await api.fetchWbiKeys();
      final uri = biliSignedUri(kBiliFeedPath, const {'y_num': 30, 'fresh_type': 3}, keys.mixinKey);
      final body = await BiliInPage.get(ctrl, uri.toString());
      final data = body['data'];
      final items = data is Map
          ? biliFeedItems(data.cast<String, dynamic>())
          : const <BiliFeedItem>[];
      if (!mounted) return;
      if (items.isEmpty) {
        // 认不出一稿件就直说。硬把直播间 / 专栏当成稿件塞进列表，
        // 用户勾完会在取流那一步撞一个看不懂的错。
        store.setError(t('推荐流里没有被认出的稿件（接口形状变了，或者这次被风控了）'));
        AppLogger.log('BILI', '主页推荐：code=${body['code']} 里没有 goto==av 的条目');
        return;
      }
      store.replaceAll(
        [for (final it in items) it.toSeedMedia()],
        link: kBiliHomeUrl,
      );
      AppLogger.log('BILI', '主页推荐：拿到 ${items.length} 条可下载稿件');
    } catch (e) {
      AppLogger.log('BILI', '取主页推荐失败：$e');
      if (mounted) store.setError(tf('取主页推荐失败：{why}', {'why': '$e'}));
    } finally {
      if (mounted) {
        store.setBusy(false);
        setState(() => _working = false);
      }
    }
  }

  // ── 取列表：解析这条链接 ────────────────────────────────────

  /// 输入框那一行 → 分 P 列表。
  ///
  /// 三步都可能有「不是错但也不该静默」的结果：认不出来 / 本期不支持的形态 /
  /// 短链展开失败。三条各自给一句可读的原因（`unsupportedReason` 由
  /// `bili_link.dart` 定义，它本来就是一句面向用户的话）。
  Future<void> _parseLink() async {
    final api = _api;
    final store = context.read<BiliStore>();
    if (api == null) return;
    if (_working) return;
    final raw = _link.text.trim();
    if (raw.isEmpty) {
      store.setError(t('把 B 站稿件链接或 BV 号粘进来再解析'));
      return;
    }

    setState(() => _working = true);
    store.setBusy(true);
    BiliRef? ref;
    try {
      ref = parseBiliRef(raw);
      if (ref == null) {
        _failParse(tf('这不是一个能认出来的 B 站链接：{link}', {'link': raw}), raw);
        return;
      }
      if (ref.isUnsupported) {
        _failParse(ref.unsupportedReason!, raw);
        return;
      }
      if (ref.needsExpand) {
        final expanded = await expandBiliShortLink(ref.shortLink!);
        if (expanded == null) {
          _failParse(t('短链没能展开（没有重定向、页面里也找不到 BV 号）'), raw);
          return;
        }
        ref = expanded;
        if (ref.isUnsupported) {
          _failParse(ref.unsupportedReason!, raw);
          return;
        }
      }
      if (ref.bvid == null && ref.aid == null) {
        _failParse(t('这条链接里没有 BV 号也没有 AV 号'), raw);
        return;
      }

      final view = await api.view(bvid: ref.bvid, aid: ref.aid?.toString());
      final parts = <Media>[
        for (final pg in view.pages)
          if (pg.cid > 0)
            biliPartMedia(
              bvid: view.bvid,
              aid: view.aid,
              workTitle: view.title,
              upperName: view.upperName,
              upperMid: view.upperMid,
              publishTime: view.publishTime,
              cover: pg.pic.isNotEmpty ? pg.pic : view.cover,
              partTotal: view.partTotal,
              partIndex: pg.index,
              cid: pg.cid,
              partTitle: pg.partTitle,
              durationMs: pg.durationMs,
            ),
      ];
      if (parts.isEmpty) {
        _failParse(t('这个稿件没有可下载的分 P（已下架或仅自己可见）'), raw);
        return;
      }
      if (!mounted) return;
      store.replaceAll(parts, link: raw);
      AppLogger.log(
        'BILI',
        '解析 ${ref.bvid ?? 'av${ref.aid}'}：${view.title}，${parts.length} 个分 P',
      );
    } catch (e) {
      // BiliApiException 的 message 只有 HTTP 状态、B 站文案与路径 ——
      // 接口层保证异常文本里不含 cookie（见 bili_api.dart 的文件头）。
      _failParse('$e', raw);
    } finally {
      if (mounted) {
        store.setBusy(false);
        setState(() => _working = false);
      }
    }
  }

  void _failParse(String why, String input) {
    AppLogger.log('BILI', '解析失败（输入「$input」）：$why');
    if (mounted) context.read<BiliStore>().setError(why);
  }

  // ── 下载 ────────────────────────────────────────────────────

  /// 对勾选的每条分 P：**取流 → 选流 → 摊成两条 Media → 入队**。
  ///
  /// 台账时序（红线，改这里之前先读完 `bili_ledger.dart` 与
  /// `bili_ledger_bridge.dart` 的文件头）：
  ///   * 入队之后只 `markPending`；
  ///   * **只有协调器收口回调里的 `merged` / `streamsKept` 才转 done**，
  ///     而 `mergeFailed` 不转 —— 因为 DASH 的两条 `.m4s` 行都会先变成
  ///     `complete`，用 `BiliLedger.advance` 判结局的话，**合并失败也会被
  ///     算成已下载**，之后开着「跳过已下载」就永远不再重试，而用户手里
  ///     只有两个不能单独播放的裸流。转 done 的位置在 `main.dart` 装的
  ///     `bindBiliLedgerToSettled` 里，不在这里。
  ///   * 单条失败**不重新投整批**：那一行已经进了任务表，用户在
  ///     「下载管理（B 站）」里对它单独重试（`retryTask`）即可。
  Future<void> _download() async {
    final store = context.read<BiliStore>();
    final ledger = context.read<BiliLedger>();
    final cfg = context.read<SettingsStore>().settings.bili;
    final api = _api;
    if (api == null) return;
    if (_working) return;

    final chosen = store.chosen;
    if (chosen.isEmpty) {
      AppToast.show(context, t('没有勾选任何分 P'), kind: AppToastKind.info);
      return;
    }

    final coordinator = Aria2Coordinator.instance;
    if (!coordinator.booted) {
      AppLogger.log('BILI', 'aria2 未就绪，本次下载没投出去（${chosen.length} 条）');
      AppToast.show(
        context,
        t('下载引擎还没起来（aria2 未就绪），请稍后重试或查看日志'),
        kind: AppToastKind.error,
      );
      return;
    }

    setState(() => _working = true);
    store.setBusy(true);
    var queued = 0;
    var skippedLedger = 0;
    var skippedDisk = 0;
    var failed = 0;
    final notes = <String>[];

    try {
      // 并发数是 aria2 的全局选项，入队前同步一次（幂等）
      await coordinator.applyConcurrency(cfg.concurrency);

      for (final part in chosen) {
        final key = biliPartKey(
          bvid: part.bili?.bvid,
          cid: part.bili?.cid,
        );
        // 「跳过已下载」= 台账（`pending` 与 `done` 都算处理过，见 bili_ledger.dart
        // 的 `contains` 注释：手快再点一次不该重复提交同一个分 P）。
        // 磁盘上有没有成品是协调器那一步的事（见下 sameFileSkip）。
        if (cfg.skipDownloaded && biliKeyGroupUsable(key) && ledger.contains(key)) {
          skippedLedger++;
          continue;
        }

        final cid = int.tryParse(part.bili?.cid ?? '');
        if (cid == null || cid <= 0) {
          failed++;
          AppLogger.log('BILI', '这条分 P 没有 cid，投不出去：${part.id}');
          continue;
        }

        try {
          final r = await api.playurl(
            cid: cid,
            qn: cfg.quality.qn,
            codec: cfg.codec,
            bvid: part.bili?.bvid,
            aid: int.tryParse(part.bili?.aid ?? ''),
          );
          final pair = planBiliStreams(r, cfg.quality, cfg.codec);
          final why = pair.message;
          if (!pair.usable || why != null) {
            // 选流层已经算出人话了（要登录 / 要大会员 / 分段没做），原样带出去
            failed++;
            AppLogger.log('BILI', '选流失败（${part.id}）：$why');
            _addNote(notes, why);
            continue;
          }

          // 文件名里的 %QUALITY% / %CODEC% 只有到这一步才知道，
          // 所以 base 名必须在选流**之后**算（见 biliPartWithLabels）。
          final labeled = biliPartWithLabels(
            part,
            videoQn: pair.videoQn,
            codec: pair.videoCodec,
            r: r,
          );
          final base =
              Aria2Coordinator.biliOutBase(cfg.fileNameTemplate, labeled, cfg);
          final medias = biliPairToMedias(part: labeled, pair: pair);
          final audio = medias.audio;
          final res = await coordinator.enqueueBiliMedia(
            medias.video,
            // durl 退化路径没有第二条流：给一条空地址的音频占位，
            // 协调器据此走「投一条、不建配对、不合并」。
            audio ?? _noStreamAudio(part),
            base,
            cfg,
          );

          switch (res.outcome) {
            case EnqueueOutcome.queued:
              queued++;
              await _markPending(ledger, key, res, labeled);
              if (res.message != null) _addNote(notes, res.message);
            case EnqueueOutcome.skippedExisting:
              // 「同名跳过」看的是**成品**在不在（不是裸流），这条口径由协调器持有。
              skippedDisk++;
            case EnqueueOutcome.notReady:
            case EnqueueOutcome.rejected:
            case EnqueueOutcome.removeFailed:
              failed++;
              AppLogger.log(
                'BILI',
                '入队失败（${res.outcome.name}，${part.id}）：${res.message ?? '无说明'}',
              );
              _addNote(notes, res.message);
          }
        } catch (e) {
          failed++;
          AppLogger.log('BILI', '取流/入队异常（${part.id}）：$e');
          _addNote(notes, '$e');
        }
      }
    } finally {
      if (mounted) {
        store.setBusy(false);
        setState(() => _working = false);
      }
    }

    if (!mounted) return;
    AppLogger.log(
      'BILI',
      '本批入队完成：提交 $queued / 台账跳过 $skippedLedger / 成品已在磁盘 $skippedDisk / 失败 $failed',
    );
    final parts = <String>[tf('已提交 {n} 条', {'n': queued})];
    if (skippedLedger > 0) {
      parts.add(tf('跳过 {n} 条（台账里已处理过）', {'n': skippedLedger}));
    }
    if (skippedDisk > 0) {
      parts.add(tf('成品已在磁盘 {n} 条', {'n': skippedDisk}));
    }
    if (failed > 0) parts.add(tf('失败 {n} 条', {'n': failed}));
    final msg = notes.isEmpty ? parts.join('，') : '${parts.join('，')}：${notes.first}';

    AppToast.show(
      context,
      msg,
      kind: failed > 0 ? AppToastKind.error : AppToastKind.success,
      duration: const Duration(seconds: 5),
      actionLabel: widget.onNavigate == null ? null : t('去下载管理'),
      // 必须落在**本模块的**路由上：跳到 X 或抖音那份下载管理，用户看到的
      // 是别家的队列（抖音页 2026-09-19 就是这么栽过一次）。
      onAction: widget.onNavigate == null
          ? null
          : () => widget.onNavigate!('bili-downloads'),
    );
  }

  /// 入队成功之后记一笔「在下」（等收口回调转 done）。
  Future<void> _markPending(
    BiliLedger ledger,
    BiliKeyGroup key,
    BiliEnqueueResult res,
    Media labeled,
  ) async {
    if (!biliKeyGroupUsable(key)) {
      AppLogger.log('BILI', '键组不完整，这条不记台账：${labeled.id}');
      return;
    }
    final ids = [res.videoLocalId, res.audioLocalId].whereType<String>().toList();
    final hash = ledger.hashOf(key);
    await ledger.markPending(
      [key],
      meta: {hash: (title: labeled.bili?.workTitle, author: labeled.userName)},
      taskIds: {hash: ids},
    );
  }

  /// durl 退化路径的音频占位：`url` 为空 + `chosen` 为空，正是协调器判
  /// 「没有第二条流」的那两个条件（见 `enqueueBiliMedia` 的 `single`）。
  Media _noStreamAudio(Media part) => Media(
        id: '${part.id}_audio',
        type: MediaType.audio,
        url: '',
        tweetId: part.tweetId,
        source: 'bili',
      );

  /// 失败原因只留**第一条**并且去重 —— 几十条分 P 撞同一个风控时，
  /// 提示条里不该出现三十遍同一句话（其余的都在日志里）。
  void _addNote(List<String> notes, String? why) {
    if (why == null || why.isEmpty) return;
    if (!notes.contains(why)) notes.add(why);
  }

  // ── 界面 ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(c),
        const SizedBox(height: 12),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildWebPane(c)),
              const SizedBox(width: 14),
              // 右侧面板比抖音那份宽一点：这里一行是「一个稿件 + 它的全部分 P」，
              // 标题要能读完，否则整批结果看不出是哪条稿件。
              SizedBox(width: 380, child: _buildSidePane(c)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(AppColors c) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _navBtn('back', Icons.arrow_back_rounded, t('后退'), _canBack),
          _navBtn('forward', Icons.arrow_forward_rounded, t('前进'), _canForward),
          _navBtn('reload', Icons.refresh_rounded, t('刷新'), true),
          _navBtn('home', Icons.home_rounded, t('B 站首页'), true),
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
                    hintText: t('粘贴 B 站链接，回车打开'),
                    hintStyle: TextStyle(fontSize: 12.5, color: c.textFaint),
                    icon: Icon(Icons.link_rounded, size: 15, color: c.textMuted),
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
    // 滚轮不接管：B 站主页的推荐流是页面自己滚的，我们只需要它加载完，
    // 不做「无限滚动抓下一页」那种事（那条路在抖音才有意义）。
    return Webview(ctrl);
  }

  Widget _buildSidePane(AppColors c) {
    final store = context.watch<BiliStore>();
    final cfg = context.watch<SettingsStore>().settings.bili;
    final groups = store.groups;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildLoginRow(c),
          const SizedBox(height: 10),
          _buildEntries(c, store),
          const SizedBox(height: 10),
          if (store.busy) _busyRow(c),
          if (store.error != null) _errorRow(c, store.error!),
          const SizedBox(height: 6),
          if (groups.isNotEmpty) _resultHeader(c, store, groups.length),
          Expanded(
            child: groups.isEmpty ? _emptyHint(c) : _buildList(c, store, groups),
          ),
          const SizedBox(height: 8),
          _buildDownloadBar(c, store, cfg),
        ],
      ),
    );
  }

  /// 登录态那一行 + 手动刷新。
  Widget _buildLoginRow(AppColors c) {
    final text = _loginChecking ? t('正在检测登录状态…') : biliLoginLineText(_login);
    final loggedIn = _login?.isLoggedIn ?? false;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: c.line, width: 0.8),
      ),
      child: Row(
        children: [
          Icon(
            loggedIn ? Icons.account_circle_rounded : Icons.account_circle_outlined,
            size: 16,
            color: loggedIn ? c.accentText : c.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: c.textStrong),
            ),
          ),
          IconButton(
            onPressed: _wvReady && !_loginChecking && !_working ? _checkLogin : null,
            tooltip: t('刷新登录状态'),
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            color: c.textMuted,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }

  /// 两个取列表的入口。
  Widget _buildEntries(AppColors c, BiliStore store) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _wvReady && !_working ? _fetchFeed : null,
                icon: const Icon(Icons.auto_awesome_motion_rounded, size: 16),
                label: Text(t('取主页推荐'), style: const TextStyle(fontSize: 12.5)),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ),
            if (store.items.isNotEmpty) ...[
              const SizedBox(width: 6),
              IconButton(
                onPressed: _working ? null : store.clear,
                tooltip: t('清除结果'),
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                color: c.textMuted,
                icon: const Icon(Icons.clear_all_rounded),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: c.surfaceSunken,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.line, width: 0.8),
                ),
                child: Center(
                  child: TextField(
                    key: const ValueKey('bili-link-field'),
                    controller: _link,
                    onSubmitted: (_) => _parseLink(),
                    style: TextStyle(fontSize: 12.5, color: c.textStrong),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintText: t('粘这条稿件的链接 / BV 号 / b23.tv 短链'),
                      hintStyle: TextStyle(fontSize: 12.5, color: c.textFaint),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              onPressed: _working ? null : _parseLink,
              tooltip: t('解析这条链接'),
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              color: c.accentText,
              icon: const Icon(Icons.search_rounded),
            ),
          ],
        ),
      ],
    );
  }

  Widget _busyRow(AppColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              valueColor: AlwaysStoppedAnimation(c.accent),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            t('正在忙…（取列表 / 取流 / 入队）'),
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _errorRow(AppColors c, String message) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: c.dangerSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 14, color: c.danger),
          const SizedBox(width: 7),
          Expanded(
            // 失败原因必须看得见：这一版把 `debugPrint` 都收进 AppLogger 了，
            // 界面上再不说清，用户就只能猜（这项目的一条明确纪律）。
            child: SelectableText(
              message,
              style: TextStyle(fontSize: 11.5, color: c.textStrong, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultHeader(AppColors c, BiliStore store, int groupCount) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(
            tf('{n} 个稿件', {'n': groupCount}),
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: c.textStrong,
            ),
          ),
          const Spacer(),
          Text(
            tf('已选 {n} / {total} 个分P', {
              'n': store.selected.length,
              'total': store.items.length,
            }),
            style: TextStyle(fontSize: 11.5, color: c.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _emptyHint(AppColors c) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.video_library_outlined, size: 30, color: c.textFaint),
            const SizedBox(height: 10),
            Text(
              t('还没有解析结果'),
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: c.textStrong,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              t('点「取主页推荐」看你登录后的推荐，或把一条稿件链接粘到上面再解析。'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: c.textMuted, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  /// 按 `store.groups` 渲染：一行稿件 + 它下面的分 P 行。
  Widget _buildList(AppColors c, BiliStore store, List<BiliWorkGroup> groups) {
    return ListView.builder(
      shrinkWrap: true,
      itemCount: groups.length,
      itemBuilder: (_, i) => _buildGroup(c, store, groups[i]),
    );
  }

  Widget _buildGroup(AppColors c, BiliStore store, BiliWorkGroup g) {
    final total = g.parts.length;
    final picked = store.selectedIn(g.key);
    final groupValue = picked == 0 ? false : (picked == total ? true : null);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => store.toggleGroup(g.key),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 4, 2, 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: groupValue,
                    tristate: true,
                    onChanged: (v) => store.toggleGroup(g.key, value: v),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: c.textStrong,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          // UP 主 + BV 号：BV 号必须露出来，「这条到底是不是我要的」
                          // 只有标题的时候经常分辨不了（同标题的多 P 稿件太常见）。
                          '${g.upName} · ${g.parts.first.tweetId ?? g.key}',
                          style: TextStyle(fontSize: 11, color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          for (final m in g.parts) _buildPartRow(c, store, m),
        ],
      ),
    );
  }

  Widget _buildPartRow(AppColors c, BiliStore store, Media m) {
    final badge = biliPartBadgeText(m);
    final clock = biliClockText(m.durationMs);

    return InkWell(
      onTap: () => store.toggle(m.id),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 3, 2, 3),
        child: Row(
          children: [
            Checkbox(
              value: store.selected.contains(m.id),
              onChanged: (v) => store.toggle(m.id, value: v),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            if (badge.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: c.surfaceSunken,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: c.line, width: 0.8),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: c.textMuted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                m.bili?.partTitle ?? m.tweetText ?? m.id,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: c.textNormal),
              ),
            ),
            if (clock.isNotEmpty)
              Text(
                clock,
                style: TextStyle(fontSize: 10.5, color: c.textFaint),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadBar(AppColors c, BiliStore store, BiliConfig cfg) {
    final has = store.items.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            TextButton(
              onPressed: has && !_working ? store.selectAll : null,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              ),
              child: Text(t('全部选中'), style: const TextStyle(fontSize: 11.5)),
            ),
            TextButton(
              onPressed: has && !_working ? store.selectNone : null,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              ),
              child: Text(t('全部取消'), style: const TextStyle(fontSize: 11.5)),
            ),
            const Spacer(),
            // 画质上限是「上限」不是保证：这句话在设置页里已经写过一遍，
            // 但用户真正按下下载的那一刻才是它起作用的时候。
            Text(
              tf('上限 {q}', {'q': t(cfg.quality.label)}),
              style: TextStyle(fontSize: 11, color: c.textFaint),
            ),
          ],
        ),
        const SizedBox(height: 6),
        FilledButton.icon(
          onPressed: has && !_working && store.chosen.isNotEmpty ? _download : null,
          icon: const Icon(Icons.download_rounded, size: 17),
          label: Text(
            store.chosen.isEmpty
                ? t('开始下载')
                : tf('下载选中的 {n} 个分P', {'n': store.chosen.length}),
            style: const TextStyle(fontSize: 13),
          ),
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
      ],
    );
  }
}
