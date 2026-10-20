import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'l10n/l10n.dart';
import 'services/app_logger.dart';
import 'services/app_paths.dart';
import 'services/app_state.dart';
import 'services/aria2_coordinator.dart';
import 'services/auto_task_store.dart';
import 'services/bili_batch_store.dart';
import 'services/bili_ledger.dart';
import 'services/bili_additional_runner.dart';
import 'services/bili_api.dart';
import 'services/bili_ledger_bridge.dart';
import 'services/bili_store.dart';
import 'services/creation_task_store.dart';
import 'services/download_store.dart';
import 'services/douyin_auto_store.dart';
import 'services/douyin_ledger_bridge.dart';
import 'services/douyin_store.dart';
import 'services/douyin_webview_env.dart';
import 'services/homepage_store.dart';
import 'services/settings_store.dart';
import 'services/shutdown_guard.dart';
import 'services/x_api.dart';
import 'theme/winui_accent.dart';
import 'widgets/liquid_glass.dart';

/// 启动流程：
///   1. 读设置（决定主题与材质）
///   2. 读应用状态（持久化的 cookie 与搜索历史）
///   3. 初始化窗口管理器 → 建无边框透明窗口
///   4. 应用 Windows 材质（Mica / 亚克力）
///   5. runApp
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // **必须在任何 HttpClient 创建之前**。
  // 让所有 dart:io 的 HttpClient（含 Image.network 的缩略图/头像）都能走代理 ——
  // Flutter 不像 WebView 那样自动读系统代理。
  HttpOverrides.global = ProxyHttpOverrides();

  // ── 数据目录 ──────────────────────────────────────────────
  // **必须在任何 store / 日志之前**。数据跟着软件走：
  // 优先 exe 同级的 `userdata\`，不再往 C 盘的 %APPDATA% 写；
  // 首次启动还会把旧目录的数据迁移过来（含抖音登录态，否则要重新扫码）。
  await AppPaths.init();

  final store = SettingsStore();
  await store.load();

  final appState = await AppState.restore();

  // ── 代理同步 ──────────────────────────────────────────────
  // Dart 的 HttpClient 既不读 Windows「Internet 选项」里的系统代理，
  // 也不读环境变量 —— 必须显式注入 findProxy，
  // 否则在需要代理的网络环境下会抛 HandshakeException。
  var lastProxySig = '';
  var lastAriaProxy = '';
  Future<void> syncProxy({bool force = false}) async {
    final p = store.settings.proxy;
    final sig = '${p.enable}|${p.useSystem}|${p.url}';
    if (!force && sig == lastProxySig) return;
    lastProxySig = sig;

    // ① 给自己（GraphQL / REST）与全局 HttpClient（图片）设代理
    await appState.api.applyProxy(
      enable: p.enable,
      useSystem: p.useSystem,
      url: p.url,
    );

    // ② aria2 也要显式设代理 —— 原版就是这么做的
    //    （`useResolvedProxyUrl` → `aria2.updateProxy`）。
    //    不设的话下载会全部报 "Network problem ... did not properly respond"。
    final ariaProxy = appState.api.effectiveProxyUrl ?? '';
    if (ariaProxy != lastAriaProxy || force) {
      lastAriaProxy = ariaProxy;
      await Aria2Coordinator.instance.updateProxy(ariaProxy);
      AppLogger.log(
          'APP', 'aria2 代理 = ${ariaProxy.isEmpty ? "直连" : ariaProxy}');
    }
  }

  // ── 日志初始化 ────────────────────────────────────────────
  var lastWriteLogs = store.settings.app.writeLogs;
  await AppLogger.init(enabled: lastWriteLogs);

  // 数据目录落在哪、有没有回退 —— 这两件事必须留痕。
  // 用户遇到「设置没了 / 又要重新扫码登录」时，全靠这几行定位。
  AppLogger.log('APP', '数据目录 = ${AppPaths.root.path}');
  if (AppPaths.usingFallback) {
    AppLogger.log('APP', '注意：${AppPaths.fallbackReason}');
  }

  // 设置变化时同步代理与日志开关
  store.addListener(() {
    unawaited(syncProxy());
    final w = store.settings.app.writeLogs;
    if (w != lastWriteLogs) {
      lastWriteLogs = w;
      unawaited(AppLogger.init(enabled: w));
    }
  });

  final homepageStore = HomepageStore(appState);
  final downloadStore = DownloadStore();
  // 下载目录：settings.json 才是持久化来源。
  // DownloadStore 的字段只存在内存里，不在这里同步的话，
  // 重启后设置页会显示为空（用户看到的就是「选完目录关掉程序就被清空」）。
  if (store.settings.download.saveDirBase.isNotEmpty) {
    downloadStore.setSaveDir(store.settings.download.saveDirBase);
  }

  // 读回上次的任务表。**必须在 bootstrap 之前** ——
  // bootstrap 结束时会调 reconcile()，用 aria2 会话（gid 不变）与这份任务表对账。
  await downloadStore.load();

  // aria2 在后台启动 —— 失败也不阻塞 UI（启动失败会让 coordinator.booted=false，
  // 所有 enqueueMedia 调用直接被忽略，等下次重启应用）
  final coordinator = Aria2Coordinator.instance;
  await coordinator.bootstrap(
    store: downloadStore,
    settings: store,
  );

  // 注意顺序：必须在 bootstrap **之后**才同步代理，
  // 因为 Aria2Coordinator.updateProxy 在未就绪时会直接返回（no-op）。
  await syncProxy();
  AppLogger.log('APP', '解析下载器启动；代理=${appState.api.findProxyRule ?? "直连"}');

  // 原版是每秒轮询系统代理（`usePollSystemProxyUrl`）；这里降到 15 秒 ——
  // 保证「先开软件、后开代理软件」时也能自动跟上，又不至于频繁读注册表。
  Timer.periodic(const Duration(seconds: 15), (_) {
    final p = store.settings.proxy;
    if (!p.enable || !p.useSystem) return;
    unawaited(syncProxy(force: true));
  });

  // 创建任务队列：主页「开始下载」与「自动执行」都只往这里登记任务，
  // 真正的翻页 + 入队在后台串行跑（原版 creationTasks 的做法）。
  final creationTaskStore = CreationTaskStore(
    appState: appState,
    coordinator: coordinator,
  );

  final autoTaskStore = AutoTaskStore(
    appState: appState,
    homepageStore: homepageStore,
    creationTasks: creationTaskStore,
  );

  // 异步加载自动执行的名单预设（AppPrefs），不阻塞窗口启动
  unawaited(autoTaskStore.loadPresets());

  // 抖音页的抓取结果仓库。挂在 app 级而不是页面 State 里 ——
  // 切页面会重建页面 State，放里面的话刚抓到的一批结果就没了。
  final douyinStore = DouyinStore();
  // 「跳过已下载」依赖台账，启动就读一次（设置页要显示已记录条数）
  await douyinStore.ledger.load();

  // 台账按任务的**实际结局**推进：入队只写「在下」，全部成功才算已下载，
  // 失败的撤掉记录以便下次重试。这里挂在任务表上而不是只挂 aria2 的完成事件 ——
  // 事件会丢（进程在完成前退出、上次会话的任务被 `--input-file` 读回来时已经
  // 是完成态），启动时推一次就能把这些补上。
  bindLedgerToDownloads(douyinStore.ledger, downloadStore);

  // 失败重试会**换任务 id**（旧任务从任务表里删掉再重新提交），所以要把它续到
  // 台账那条「在下」记录上 —— 不续的话该作品永远查不到自己的结局。
  coordinator.onTaskSubmitted = (m, localId) {
    final id = m.tweetId;
    if (id == null || id.isEmpty || m.source != 'douyin') return;
    unawaited(douyinStore.ledger.attachTask(id, localId));
  };

  // 抖音「自动下载」的目标与进度。挂 app 级：切走页面不丢进度。
  // 真正需要页面持有的只有 WebviewController（见 DouyinAutoPage）。
  final douyinAutoStore = DouyinAutoStore();

  // B 站：解析结果仓库与下载台账，挂 app 级同上（切页面不丢刚解析出来的一批）。
  // 台账必须在 runApp 之前读一次 —— 「跳过已下载」与下载管理页那个
  // 「已下载（B 站）」的角标数字都靠它，晚读一步就是空台账启动。
  final biliLedger = BiliLedger();
  await biliLedger.load();
  final biliStore = BiliStore();
  // 批量页的目标与进度同样挂 app 级：跑一半切页面不丢。
  final biliBatchStore = BiliBatchStore();

  // 合并结局 → 台账转 done。**这是唯一的转 done 入口**。
  bindBiliLedgerToSettled(coordinator, biliLedger);

  // B 站附加文件（弹幕 / 字幕 / 封面 / 章节 / 元数据）的装配点。
  //
  // 这一层只认「取数口」，编排逻辑在 `bili_additional_runner.dart` 里。
  // **凭据不进 aria2 那条红线也在这里守住**：这些请求全走 Dart 侧，
  // 一次都不经过下载器（下载器的 per-task header 会被 --save-session 明文写进
  // 会话文件）。
  //
  // ⚠️ **`useSharedPageTransport()` 这一行不能省。** 本对象在启动时装配，
  // 而 WebView 是页面级创建的 —— 少了它，附加文件会一直走匿名 `dart:io`，
  // 表现为**登录了也报「字幕：接口没返回任何一条」**（2026-10-11 真机撞上）。
  // 页面就绪时会把页内口登记到 `BiliPageTransportRegistry`，本对象随即用上。
  final biliApiForFiles = BiliApi()..useSharedPageTransport();
  coordinator.biliAdditional = ({
    required cfg,
    required saveDir,
    required outBase,
    required video,
  }) => biliProduceAdditional(
    cfg: cfg,
    saveDir: saveDir,
    outBase: outBase,
    video: video,
    deps: BiliAdditionalDeps(
      signedData: (path, params) =>
          biliApiForFiles.getSignedData(path, params, what: path),
      plainData: (path, params) =>
          biliApiForFiles.getRawData(path, params, what: path),
      jsonAtUrl: biliApiForFiles.jsonAtUrl,
      bytesAtUrl: biliApiForFiles.bytesAtUrl,
      danmakuSegment: (cid, segmentIndex) => biliApiForFiles.danmakuSegment(
        cid: cid,
        segmentIndex: segmentIndex,
      ),
    ),
  );

  // 内嵌浏览器环境：必须赶在任何 WebviewController 创建之前，
  // 且全局只能初始化一次（用户数据目录定了就不能再改）。
  await prepareDouyinWebViewEnvironment();

  // 液体玻璃 Stage B 的着色器预热：**不 await**，让首帧不等磁盘 I/O。
  // 预热只填 `_program` 程序缓存，组件侧行为不变；失败静默走 Stage A。
  unawaited(LiquidGlassSurface.warmUp());

  // Windows 系统强调色（「跟随系统」档用）。**不 await** —— 读注册表是子进程
  // 调用，绝不能让窗口等它。读失败时 `WinUiAccent.system` 自动回退到官方蓝。
  unawaited(readSystemAccentColor());

  await windowManager.ensureInitialized();

  if (Platform.isWindows) {
    await acrylic.Window.initialize();
  }

  // 不再是 const：窗口标题要按当前语言查表。
  // 注意这是**启动时**定的一次 —— 运行中切语言不会改 OS 层标题，
  // 但窗口是无边框自绘标题栏，OS 标题只在任务栏悬停时露出来，下次启动即正确。
  // **尺寸不要再乘 devicePixelRatio**（2026-10-20 真机实测纠正）。
  //
  // `b392b47` 曾在这里写 `* dpr`，理由是「runner 按逻辑像素建窗、而
  // window_manager 按物理像素设尺寸，两边口径不一致」。**该判断是错的**，
  // 结果是 DPR 被乘了两次：
  //
  //   1280 × 1.25(runner) × 1.25(这里) = 2000 物理像素
  //
  // 实测证据（本机 DPR 1.25、屏幕 2560×1440、工作区 2560×1400）：
  //   带 `* dpr`  → 窗口 2000×1437，底边 y=1419 **超出工作区底 1400 共 19px**，
  //                  底部被任务栏切掉（用户报「为什么默认启动的这么大」）。
  //   去掉 `* dpr` → 窗口 1600×1150，完整落在工作区内。
  //
  // `WindowOptions.size` 的语义是**逻辑像素**，window_manager 自己会按
  // `pixel_ratio_` 换算（插件源码 `window_manager.cpp` 里 `pixel_ratio_`
  // 在 `WM_CREATE` 与 `WM_DPICHANGED` 两处赋值）。所以这里给设计稿逻辑值即可。
  final windowOptions = WindowOptions(
    size: const Size(_kWindowWidth, _kWindowHeight),
    minimumSize: const Size(_kMinWindowWidth, _kMinWindowHeight),
    center: true,
    // 无边框：标题栏由我们自己画
    titleBarStyle: TitleBarStyle.hidden,
    // 透明：让 Windows 材质能透出来
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    title: t('解析下载器'),
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  // 退出钩子：关窗时先收掉 aria2c 子进程、落盘任务表，再真正销毁窗口。
  // 没有它的话 aria2c 会变成孤儿进程继续跑（实测出现过，会让下次启动再也下不动）。
  await ShutdownGuard.install(downloadStore: downloadStore);

  // 窗口材质**不在这里应用**：`flutter_acrylic` 的 `dark` 参数要的是
  // 「应用当前的明暗」，而明暗由 `themeMode` + 系统亮度共同决定
  // （`app.dart` 的 `_resolveBrightness`）—— 这里还没有 BuildContext，
  // 算不出系统亮度。改由 `app.dart` 的 build 里统一应用，顺带让
  // 「切换明暗」也能即时反映到窗口外观（2026-10-15 修）。

  runApp(XDownloaderApp(
    initialRoute: launchRouteFrom(args, kAppRoutes),
    store: store,
    appState: appState,
    homepageStore: homepageStore,
    downloadStore: downloadStore,
    autoTaskStore: autoTaskStore,
    creationTaskStore: creationTaskStore,
    douyinStore: douyinStore,
    douyinAutoStore: douyinAutoStore,
    biliStore: biliStore,
    biliBatchStore: biliBatchStore,
    biliLedger: biliLedger,
  ));
}

/// 窗口默认尺寸（**逻辑像素**，运行时乘 devicePixelRatio 变成物理像素）。
///
/// 1280×920 / 最小 880×620 与设计稿一致；`test/ui_smoke_test.dart` 的三档
/// 视口（1280×900 / 1000×700 / 880×620）也按这套逻辑尺寸取。
const double _kWindowWidth = 1280;
const double _kWindowHeight = 920;
const double _kMinWindowWidth = 880;
const double _kMinWindowHeight = 620;

/// 从启动参数里取出落地页 id：`--page=<id>`（也接受 `--page <id>`）。
///
/// **为什么需要它**：真机截图必须先停在目标页，而自动化点击这条路走不通 ——
/// Flutter 走原始输入通道，`WM_LBUTTONDOWN` 一律不认，导航不过去。
/// 让应用自己在启动时落地，则截图脚本可以完全后台跑（不碰前台、不抢焦点）。
///
/// 非法或缺失一律返回 null，回落到默认落地页 —— 启动路径不能因为
/// 一个拼错的参数就异常。
String? launchRouteFrom(List<String> args, List<String> known) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String? value;
    if (a.startsWith('--page=')) {
      value = a.substring('--page='.length);
    } else if (a == '--page' && i + 1 < args.length) {
      value = args[i + 1];
    }
    if (value == null || value.isEmpty) continue;
    return known.contains(value) ? value : null;
  }
  return null;
}

/// 读 Windows「个性化 → 颜色」里的强调色，供 [WinUiAccent.system] 用。
///
/// 来源：`HKCU\\Software\\Microsoft\\Windows\\DWM` 的 `ColorizationColor`，
/// 形如 `0xC4D8E4F0`（**AABBGGRR**，注意是 BGR 序不是 RGB）。
///
/// **失败一律静默**：读不到就什么都不设，`WinUiAccent.system` 会自动回退到
/// Windows 官方蓝（见 `winui_accent.dart`）。绝不能因为读注册表失败就影响
/// 启动 —— 用户设置了「跟随系统」不该看到任何异常。
Future<void> readSystemAccentColor() async {
  if (!Platform.isWindows) return;
  try {
    final r = await Process.run('reg', [
      'query',
      r'HKCU\\Software\\Microsoft\\Windows\\DWM',
      '/v',
      'ColorizationColor',
    ]);
    if (r.exitCode != 0) return;
    final m = RegExp(r'0x([0-9a-fA-F]{8})').firstMatch(r.stdout.toString());
    if (m == null) return;
    final v = int.parse(m.group(1)!, radix: 16);
    // AABBGGRR -> 0xFFRRGGBB（系统色自带 alpha，这里统一按不透明用）
    final bb = (v >> 16) & 0xFF;
    final gg = (v >> 8) & 0xFF;
    final rr = v & 0xFF;
    WinUiAccent.setSystemColor(Color.fromARGB(0xFF, rr, gg, bb));
    final hex = rr.toRadixString(16).padLeft(2, '0') +
        gg.toRadixString(16).padLeft(2, '0') +
        bb.toRadixString(16).padLeft(2, '0');
    AppLogger.log('APP', '系统强调色 = #$hex');
  } catch (_) {
    // 读不到就用官方蓝，不打扰用户
  }
}