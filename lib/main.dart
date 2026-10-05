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
import 'services/creation_task_store.dart';
import 'services/download_store.dart';
import 'services/douyin_auto_store.dart';
import 'services/douyin_ledger_bridge.dart';
import 'services/douyin_store.dart';
import 'services/douyin_webview_env.dart';
import 'services/homepage_store.dart';
import 'services/settings_store.dart';
import 'services/shutdown_guard.dart';
import 'services/window_effect.dart';
import 'services/x_api.dart';

/// 启动流程：
///   1. 读设置（决定主题与材质）
///   2. 读应用状态（持久化的 cookie 与搜索历史）
///   3. 初始化窗口管理器 → 建无边框透明窗口
///   4. 应用 Windows 材质（Mica / 亚克力）
///   5. runApp
Future<void> main() async {
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

  // 内嵌浏览器环境：必须赶在任何 WebviewController 创建之前，
  // 且全局只能初始化一次（用户数据目录定了就不能再改）。
  await prepareDouyinWebViewEnvironment();

  await windowManager.ensureInitialized();

  if (Platform.isWindows) {
    await acrylic.Window.initialize();
  }

  // 不再是 const：窗口标题要按当前语言查表。
  // 注意这是**启动时**定的一次 —— 运行中切语言不会改 OS 层标题，
  // 但窗口是无边框自绘标题栏，OS 标题只在任务栏悬停时露出来，下次启动即正确。
  final windowOptions = WindowOptions(
    size: Size(1280, 920),
    minimumSize: Size(880, 620),
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

  await applyWindowMaterial(store.settings.appearance.windowMaterial);

  runApp(XDownloaderApp(
    store: store,
    appState: appState,
    homepageStore: homepageStore,
    downloadStore: downloadStore,
    autoTaskStore: autoTaskStore,
    creationTaskStore: creationTaskStore,
    douyinStore: douyinStore,
    douyinAutoStore: douyinAutoStore,
  ));
}