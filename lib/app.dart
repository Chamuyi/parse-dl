import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'l10n/l10n.dart';
import 'models/settings.dart';
import 'pages/about_page.dart';
import 'pages/auto_task_page.dart';
import 'pages/bili_batch_page.dart';
import 'pages/bili_page.dart';
import 'pages/dashboard_page.dart';
import 'pages/download_management_page.dart';
import 'pages/douyin_auto_page.dart';
import 'pages/douyin_page.dart';
import 'pages/homepage_page.dart';
import 'pages/settings_page.dart';
import 'services/app_logger.dart';
import 'services/app_state.dart';
import 'services/aria2_coordinator.dart';
import 'services/auto_task_store.dart';
import 'services/bili_batch_store.dart';
import 'services/bili_ledger.dart';
import 'services/bili_store.dart';
import 'services/creation_task_store.dart';
import 'services/download_store.dart';
import 'services/douyin_auto_store.dart';
import 'services/douyin_store.dart';
import 'services/homepage_store.dart';
import 'services/settings_store.dart';
import 'services/window_effect.dart';
import 'services/window_material_state.dart';
import 'theme/app_scroll_behavior.dart';
import 'theme/app_style.dart';
import 'theme/app_theme.dart';
import 'theme/window_material.dart';
import 'widgets/app_toast.dart';
import 'widgets/background_layer.dart';
import 'widgets/dock.dart';
import 'widgets/douyin_result_overlay.dart';
import 'widgets/sidebar_nav.dart';
import 'widgets/title_bar.dart';

/// 上一次已经下发到原生窗口的明暗（见 `build` 里那段说明）。
///
/// 用模块级变量而不是实例字段：`XDownloaderApp` 是 `StatelessWidget`。
/// 初值 null = 「还没下发过」，保证首帧一定会应用一次。
/// 上一次应用过的「材质/明暗」组合键（材质id/亮度名）。
///
/// 2026-10-19 从纯 Brightness 改成组合键：WinUI 风格会强制材质为 Mica，
/// 切风格时必须重新应用一次，否则窗口底还停在旧材质上。
String? _lastAppliedDark;

/// 应用版本号。
///
/// **规则**：公开基线起从 `1.0` 重新开始，每迭代一次 +0.1。
/// 改这里的同时要同步 `pubspec.yaml`、`installer/build_installer.py` 的 `VERSION`
/// 以及 `installer/解析下载器.nsi` 里 `!ifndef VERSION` 的兜底值。
const String kAppVersion = '1.3';

/// 「关于」页用到的全部常量。
///
/// 在这里集中声明，避免散落在多个文件里。
/// 协议名直接硬编码 GPL-3.0。
const _kAboutInfo = AboutInfo(
  name: '解析下载器',
  tagline: '批量下载 X、抖音与 B 站上的图片与视频',
  version: kAppVersion,
  author: '茶沐依',
  license: 'GPL-3.0',
);

/// 应用根组件。
///
/// 顶层结构：
///   ① 底色调层（材质生效时不铺任何东西）
///   ② 用户背景图
///   ③ 自绘标题栏
///   ④ 内容区
///   ⑤ 导航（悬浮 Dock 或常规侧边栏，由「设置 → 外观 → 导航形态」决定）
class XDownloaderApp extends StatelessWidget {
  final SettingsStore store;
  final AppState appState;
  final HomepageStore homepageStore;
  final DownloadStore downloadStore;
  final AutoTaskStore autoTaskStore;
  final CreationTaskStore creationTaskStore;
  final DouyinStore douyinStore;
  final DouyinAutoStore douyinAutoStore;
  final BiliStore biliStore;
  final BiliBatchStore biliBatchStore;
  final BiliLedger biliLedger;

  /// 启动落地页（导航 id），来自 `--page=<id>`；null = 默认落地页。
  /// 见 `_AppShell.initialRoute`。
  final String? initialRoute;

  const XDownloaderApp({
    super.key,
    this.initialRoute,
    required this.store,
    required this.appState,
    required this.homepageStore,
    required this.downloadStore,
    required this.autoTaskStore,
    required this.creationTaskStore,
    required this.douyinStore,
    required this.douyinAutoStore,
    required this.biliStore,
    required this.biliBatchStore,
    required this.biliLedger,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsStore>.value(value: store),
        ChangeNotifierProvider<AppState>.value(value: appState),
        ChangeNotifierProvider<HomepageStore>.value(value: homepageStore),
        ChangeNotifierProvider<DownloadStore>.value(value: downloadStore),
        ChangeNotifierProvider<AutoTaskStore>.value(value: autoTaskStore),
        ChangeNotifierProvider<CreationTaskStore>.value(
          value: creationTaskStore,
        ),
        ChangeNotifierProvider<DouyinStore>.value(value: douyinStore),
        ChangeNotifierProvider<DouyinAutoStore>.value(value: douyinAutoStore),
        // B 站的两个 app 级状态与抖音同构：解析结果仓库 + 下载台账。
        // `BiliLedger` **必须挂在树上而不是只挂在页面里**：
        // 「下载管理（B 站）」那一片历史直接 `watch<BiliLedger>()`，
        // 漏挂就是 ProviderNotFound。
        ChangeNotifierProvider<BiliStore>.value(value: biliStore),
        // 批量页的目标与进度：跑一半切页面不该丢（与抖音自动下载同构）。
        ChangeNotifierProvider<BiliBatchStore>.value(value: biliBatchStore),
        ChangeNotifierProvider<BiliLedger>.value(value: biliLedger),
      ],
      child: Consumer<SettingsStore>(
        builder: (context, s, _) {
          final appearance = s.settings.appearance;
          final brightness = _resolveBrightness(context, appearance.themeMode);

          // 设置写盘失败 / 日志开不起来：这两处的调用点太多（几十处开关），
          // 逐个加提示不现实，在根上兜一次 —— 不管从哪个入口出的错，用户都能
          // 看见一句话，而不是「开关翻过去了、重启又回到原值」。
          final notice = s.lastSaveError ?? AppLogger.lastError;
          if (notice != null) {
            s.lastSaveError = null;
            AppLogger.lastError = null;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              AppToast.show(context, notice, kind: AppToastKind.error);
            });
          }

          // 语言：这里是设置 → `l10n` 全局状态的唯一写入口。写在 build 里是
          // 有意的 —— 紧接着整个子树就用新值重建，不需要另设通知机制
          // （导航形态 `navLayout` 也是同一套做法，切换即时生效）。
          applyLocaleSetting(appearance.locale);
          systemLanguageCodes = [
            for (final l in WidgetsBinding.instance.platformDispatcher.locales)
              l.languageCode,
          ];
          final locale = activeLocale.flutterLocale;

          // 窗口外观的明暗跟着**应用明暗**走（`flutter_acrylic` 的 `dark`
          // 参数管的是系统绘制的标题栏/边框）。
          //
          // 2026-10-15 之前这件事在 `main.dart` 启动时做一次，且 `dark` 是按
          // 「材质是不是 mica」猜的 —— 浅色+Mica / 深色+亚克力两种组合都传反。
          // 现在挪到这里：① 明暗有唯一出处（`_resolveBrightness`）；
          // ② 用户切换明暗时窗口外观**跟着变**（原来切了不会变，得重启）。
          //
          // 只在变化时调用，避免每帧都打一次原生通道。用模块级变量而不是
          // 实例字段：`XDownloaderApp` 是 `StatelessWidget`（见类定义），
          // 存不了可变状态。
          // 材质直接读配置里的四档（mica / mica-alt / acrylic / acrylic-thin）。
          //
          // 这里曾写成 `visualStyle == AppStyle.winui ? mica : 配置值` ——
          // 那时还有四套风格，winui 想固定用 Mica。但 e5c4b6e 删掉另三套之后
          // `AppStyle` 只剩 winui 一个值，这个三元**恒取 mica 分支**：用户在
          // 设置里选的亚克力/细亚克力/Mica Alt 在启动路径上被静默覆盖成 Mica，
          // 界面里选什么都一样。现在按配置走，材质选择才真的生效。
          final effectiveMaterial = s.settings.appearance.windowMaterial;
          final materialKey = '${effectiveMaterial.id}/${brightness.name}';
          if (_lastAppliedDark != materialKey) {
            _lastAppliedDark = materialKey;
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              final r = await applyWindowMaterial(
                effectiveMaterial,
                dark: brightness == Brightness.dark,
              );
              // 材质**是否真的挂上了**决定窗口底该透明还是该铺不透明回退色
              // （见 `BackgroundLayer`）。这里必须回写：系统关掉「透明效果」
              // 时 `DwmSetWindowAttribute` 会失败，此时底若还透明，桌面就
              // 从窗口里透出来。
              windowMaterialAvailable.value = r.ok;
            });
          }

          return AppTheme(
            // 色板按「风格 + 亮度」取：三套风格各有自己的整套色彩令牌，
            // 不再是全局一套（风格切换时整个子树重建，色彩立刻跟着变）。
            colors: AppColors.of(
              appearance.visualStyle,
              brightness,
              accent: appearance.winUiAccent,
            ),
            brightness: brightness,
            // 界面风格：与 navLayout / locale 同一套做法 —— 从设置读，
            // 切换后整个子树重建，卡片材质立刻跟着变。
            style: appearance.visualStyle,
            // 滚动条一律不显示（用户 2026-10-15 裁定「彻底隐藏」：
            // 2fae366 那版只把系统默认样式换成预览稿那一档，但设置类页面
            // 内容常溢出视口，滚动时淡入的那条还是会被截图留下来）。
            //
            // 曾在这里挂过一层 `AppScrollbarTheme` 负责下发 8px/圆角 ——
            // 现在根本没有 `Scrollbar` 被创建，那层 InheritedWidget 与它的
            // 样式参数已无意义，一并删掉（见 `app_scroll_behavior.dart`）。
            child: MaterialApp(
              title: t('解析下载器'),
              debugShowCheckedModeBanner: false,
              // 滚动条「挂不挂」由 behavior 决定，「长什么样」由上面那层
              // `ScrollbarTheme` 决定（`MaterialScrollBehavior` 没有
              // `scrollbarTheme` 可覆写，SDK 只给到 `buildScrollbar`）。
              //
              // 不挂的话桌面端每个滚动容器都带一条系统默认样式的竖线 ——
              // 2026-10-15 真机上被指出「怎么有一个滑动的东西」。
              scrollBehavior: const AppScrollBehavior(),
              locale: locale,
              // 只声明这两档：系统语言是第三种时，Flutter 落到列表第一项（中文）。
              supportedLocales: const [Locale('zh'), Locale('en')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: _buildMaterialTheme(brightness, appearance.visualStyle),
              home: _AppShell(
                brightness: brightness,
                initialRoute: initialRoute,
              ),
            ),
          );
        },
      ),
    );
  }

  /// system → 跟随系统；否则取设置值
  Brightness _resolveBrightness(BuildContext context, ThemeMode2 mode) {
    switch (mode) {
      case ThemeMode2.light:
        return Brightness.light;
      case ThemeMode2.dark:
        return Brightness.dark;
      case ThemeMode2.system:
        return MediaQuery.platformBrightnessOf(context);
    }
  }

  ThemeData _buildMaterialTheme(Brightness brightness, AppStyle style) =>
      buildAppTheme(
        AppColors.of(style, brightness),
        brightness,
        // 按钮主题也按风格取令牌（与上面 AppColors.of 同源）。
        style: style,
      );
}

class _AppShell extends StatefulWidget {
  final Brightness brightness;

  /// 启动落地页（导航 id）。null = 用默认落地页 `dashboard`。
  ///
  /// 只为真机截图机制服务（`--page=<id>` 启动参数，见 `launchRouteFrom`）：
  /// 自动化点击走不通 —— Flutter 走原始输入通道，不认 `WM_LBUTTONDOWN`，
  /// 所以「导航到设置页再截图」这条路只能由应用自己在启动时落地。
  final String? initialRoute;

  const _AppShell({required this.brightness, this.initialRoute});

  @override
  State<_AppShell> createState() => _AppShellState();
}

/// 所有路由 id 的**权威清单**。
///
/// 为什么单独列一份而不是从 `kNavGroups` 推导：导航表是「界面上有哪些入口」，
/// 而这里是「树里可以同时活着哪些页面」——两者会分叉（设置页有四个 scope、
/// 首页/关于不在任何分组里）。**加页面时两处都要登记**：漏了这份清单，
/// 保活会静默退化成单页渲染（不崩，但切回来又是重建）。
///
/// 这份清单**只回答「这个 id 是不是一个页面」**，不承担顺序语义 ——
/// [IndexedStack] 的 children 顺序由 `_visited`（首次访问顺序）决定，
/// 原因见 `_visited` 的注释。
const List<String> kAppRoutes = [
  // 首页「总览」排在第一个：它是软件打开时的默认落地页
  // （`_AppShellState._routeId` / `_visited` 的初值都是它）。
  'dashboard',
  'home',
  'douyin',
  'douyin-downloads',
  'douyin-auto',
  'douyin-settings',
  'bili',
  'bili-batch',
  'bili-downloads',
  'bili-settings',
  'download-management',
  'auto-task',
  'x-settings',
  'settings',
  'about',
];

/// 保活栈的 children 顺序与当前下标 —— **纯函数**，`test/app_shell_keepalive_test.dart`
/// 直接钉住它（页面本体要真 WebView，widget 测试里起不来，但顺序是纯静态可判的）。
///
/// `children` 就是 `visited` 本身：**首次访问序、append-only**，这正是保活成立的
/// 前提 —— 已活页面的位置恒定，`IndexedStack` 按位置匹配 element 时必然复用同一个。
///
/// 返回 null 表示「不该走保活路径」（`current` 不在 [kAppRoutes] 里，或还没被访问过），
/// 调用方退回单页渲染。
({List<String> children, int index})? keepAliveStack(
  List<String> visited,
  String current,
) {
  if (!kAppRoutes.contains(current)) return null;
  final at = visited.indexOf(current);
  if (at < 0) return null;
  return (children: visited, index: at);
}

/// 启动时的保活栈初值 —— **纯函数**，`test/launch_route_test.dart` 直接钉住它。
///
/// 抽出理由：`--page=<id>` 只允许改**初值**，而初值由两个字段共同决定，
/// 少改一个就静默退化：`keepAliveStack` 要求「当前页在已访问列表里」，
/// 只改 `route` 会让首帧退回单页渲染，保活在第一个页面上就失效（不崩，
/// 所以肉眼与日志都看不出来）。把两字段的联动收在一个纯函数里，判据才钉得住。
///
/// [requested] 为 null 或不在 [kAppRoutes] 里时原样返回 —— 启动路径不能因为
/// 一个拼错的参数改变行为。
({String route, List<String> visited}) launchStack(
  String? requested,
  String defaultRoute,
  List<String> defaultVisited,
) {
  if (requested == null || !kAppRoutes.contains(requested)) {
    return (route: defaultRoute, visited: defaultVisited);
  }
  // 目标页排在最前：它此刻就是当前页，必须在已访问列表里。
  if (requested == defaultRoute || defaultVisited.contains(requested)) {
    return (route: requested, visited: defaultVisited);
  }
  return (route: requested, visited: <String>[requested, ...defaultVisited]);
}

class _AppShellState extends State<_AppShell> {
  /// 当前选中的页面（导航 id）。
  ///
  /// **初值必须是 `dashboard`**：它是软件打开时的落地页。改这里的同时
  /// [_visited] 的初值也要跟着改（否则首帧 `keepAliveStack` 找不到
  /// `dashboard` → 退回单页渲染，保活在第一个页面上就失效）。
  String _routeId = 'dashboard';

  /// **已经打开过的**路由，**按首次访问顺序**排列 —— 这就是保活的依据。
  ///
  /// 为什么要保活：三个解析页里都嵌着 WebView2，而 WebView2 的画面由
  /// `webview_windows` 通过 `_reportSurfaceSize()` 把 Flutter 的布局尺寸上报给
  /// 它的 CompositionController（0.4.0 走 `Texture` 合成，**不是**原生子窗口）。
  /// 以前 `_buildPage` 是「当前路由 → new 一个页面」的 switch，切走即
  /// `dispose()`、WebView 随之销毁；切回来是全新实例 —— 用户看到的是
  /// 「切回来没刷新、还停在当前页面」（其实是**重新加载了同一个起始页**），
  /// 以及「返回按钮点不动」（新实例的 `_canBack` 初始恒为 `false`）。
  ///
  /// **顺序为什么必须是「首次访问序」而不能是「清单序」**：[IndexedStack] 的
  /// children 是**按位置**匹配 element 的（位置相同且 `runtimeType` 相同才复用）。
  /// 若按 [kAppRoutes] 过滤出存活列表，先开 B 站、再开抖音时 `bili` 的位置会从
  /// 1 漂到 2 —— 位置 1 的类型从 `BiliPage` 变成 `DouyinPage`，两边都找不到能
  /// 复用的 element，`BiliPage` 的 State 被 **dispose**，保活静默失效（真机现象
  /// 与没修时一模一样）。按访问顺序 append-only 则每个页面的位置**恒定**，
  /// 切回来必然复用同一个 element。回归判据见 `test/app_shell_keepalive_test.dart`。
  ///
  /// 保活的代价是 WebView 常驻内存，所以**只保活访问过的**：没点进去过的路由
  /// 仍然不构造（启动时不会一次性建出三个 WebView）。
  ///
  /// 初值 = 落地页 `dashboard`：首帧它已经是「当前页」，必须同时在已访问列表里，
  /// 否则 `keepAliveStack` 返回 null、退回单页渲染。
  final List<String> _visited = ['dashboard'];

  /// 抖音浮层的跨层句柄。
  ///
  /// **为什么由外壳层持有**：浮层要盖住左侧导航栏，就必须挂在这一层的 `Stack`
  /// 里（见 `build` 的注释）；而浮层的开关点（右侧面板那颗 ⤢）在页面内部。
  /// 页面构造时把它自己那份句柄交上来，外壳层订阅它、据此渲染 —— 两侧共用
  /// 一个可变对象，不会出现「页面以为开着、外壳以为关着」。
  ///
  /// 惰性创建：没访问过抖音页时它是 null，浮层不渲染。
  DouyinOverlayController? _douyinOverlay;

  /// 浮层的开关/进行中状态变了就重建本层 —— 遮罩挂在 `build` 的树上，
  /// 不重建就永远不出现。
  void _onDouyinOverlayChanged() => setState(() {});

  @override
  void initState() {
    super.initState();
    // 启动即落到指定页（`--page=<id>`）。只改**初值**：之后用户点导航
    // 照样走 `_setRoute`，两者不冲突。
    // 只在参数**真的**指向别处时才动初值，默认路径一个字节都不碰。
    if (widget.initialRoute == null) return;
    final start = launchStack(widget.initialRoute, _routeId, _visited);
    if (start.route == _routeId) return;
    _routeId = start.route;
    _visited
      ..clear()
      ..addAll(start.visited);
  }

  @override
  void dispose() {
    _douyinOverlay?.removeListener(_onDouyinOverlayChanged);
    super.dispose();
  }

  void _setRoute(String id) {
    // 换页时关掉抖音浮层 —— 它是**当前页面**的抓取结果，跟着页面走
    // （预览稿 `render()` 里切路由时同样把 `overlayOpen` 置回 false，
    // 否则浮层会跨页留在别的模块上）。放在 setState 之外：句柄自己会通知本层重建。
    _douyinOverlay?.setOpen(false);
    setState(() {
      _routeId = id;
      if (!_visited.contains(id)) _visited.add(id);
    });
  }

  /// 抖音浮层句柄 —— 惰性创建，并挂上本层的监听。
  ///
  /// 创建时机就是「抖音页被构造」的那一刻（[IndexedStack] 首次把它建出来）：
  /// 页面拿到它之后才能把「展开详情」与入队入口写进去。
  DouyinOverlayController _ensureDouyinOverlay() {
    final existing = _douyinOverlay;
    if (existing != null) return existing;
    final created = DouyinOverlayController()
      ..addListener(_onDouyinOverlayChanged);
    _douyinOverlay = created;
    return created;
  }

  /// 点击模块标题行 —— 切换**该模块自己**的展开状态并落盘。
  ///
  /// 只动被点的那个模块，另一个模块的展开状态不受影响
  /// （需求：「展开收起以该统一入口为交互主体」）。
  void _toggleNavGroup(String groupId) {
    context.read<SettingsStore>().setAppearance(
      (a) => a.toggleNavGroup(groupId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appearance = context.select<SettingsStore, AppearanceSettings>(
      (s) => s.settings.appearance,
    );
    // 「自动执行」在后台跑任务时，两种导航的红点都应亮起
    final taskRunning = context.select<AutoTaskStore, bool>((s) => s.running);

    // 导航形态来自设置；`context.select` 保证设置一变这里立即重建 ——
    // 所以「切换后界面即时生效」是天然成立的，不需要额外通知机制。
    final useSidebar = appearance.navLayout == NavLayout.sidebar;

    // 内容区**必须透明**（2026-10-19 用户裁定「照抄图吧」）。
    //
    // 这里曾有一层 `opaqueShell`：WinUI 风格时给内容区铺一块不透明实色
    // （`AppColors.solidFor`），理由是「WinUI 是不透明应用面」。那个理由
    // 站不住 —— 参照物 `tubatool/TubaWinUi3.WinUI3/MainWindow.xaml:279-281`
    // 恰恰把内容区背景显式改成了 `Transparent`：
    //
    //     <NavigationView.Resources>
    //         <SolidColorBrush x:Key="NavigationViewContentBackground" Color="Transparent" />
    //     </NavigationView.Resources>
    //
    // 它这么做是因为 Flutter/WinUI 画的不透明像素会把 DWM 画的材质**整个
    // 盖住**：那一层实色 + `BackgroundLayer` 的实色底，两层叠起来之后四档
    // 材质（mica / mica-alt / acrylic / acrylic-thin）在真机上是四张一模一样
    // 的图。删掉这层，材质才真的透得上来。
    //
    // 文字可读性由**卡片**保证（`AppCard` 等承载文字的组件保持不透明），
    // 不是靠给内容区铺底。

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // ① + ② 底色调与背景图
          Positioned.fill(
            child: BackgroundLayer(
              appearance: appearance,
              brightness: widget.brightness,
            ),
          ),

          // ③④⑤ 标题栏 + 内容 +（侧边栏形态时）左侧导航
          Column(
            children: [
              TitleBar(
                routeTitle: _titleOf(_routeId),
                onMinimize: () => _windowAction('minimize'),
                onToggleMaximize: () => _windowAction('maximize'),
                onClose: () => _windowAction('close'),
              ),
              // 下载引擎没起来时全程挂着这条 —— 挂在根布局是为了覆盖所有页面，
              // 用户不管在哪个界面点下载，都不会以为程序一切正常。
              ValueListenableBuilder<bool>(
                valueListenable: Aria2Coordinator.engineReady,
                builder: (context, ready, _) => ready
                    ? const SizedBox.shrink()
                    : _EngineDownBanner(colors: AppTheme.colorsOf(context)),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Row(
                      // 让侧边栏通高（否则它只会按内容高度收缩）
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (useSidebar)
                          Padding(
                            // WinUI：侧栏贴边通栏（从标题栏底铺到窗口底）；
                            // 另三套是浮在壁纸上的玻璃卡，四周留白。
                            padding: AppTheme.of(context).style == AppStyle.winui
                                ? EdgeInsets.zero
                                : const EdgeInsets.fromLTRB(16, 14, 0, 16),
                            child: SidebarNav(
                              currentRouteId: _routeId,
                              onSelect: _setRoute,
                              // 展开状态来自设置：点标题行切换、写回设置、下次启动保持
                              isGroupExpanded: appearance.isNavGroupExpanded,
                              onToggleGroup: _toggleNavGroup,
                              taskRunning: taskRunning,
                            ),
                          ),
                        // **内容区在材质可用时必须透明**（2026-10-19 真机取证）。
                        //
                        // 这里原先无条件铺 `surfaceBase`（深 #202020 / 浅 #F3F3F3，
                        // 完全不透明）。后果：`material_matrix.ps1` 实测四档材质
                        // **两两像素差全为 0** —— 四张一模一样的图，因为不透明底
                        // 把 DWM 画的材质整个盖住了。参照物正是因此把
                        // `NavigationViewContentBackground` 显式设为 `Transparent`
                        // （`MainWindow.xaml:279-281`）。
                        //
                        // 材质不可用（旧系统 / 合成器异常）时才铺回不透明兜底色，
                        // 否则文字没有底、读不清。
                        Expanded(
                          child: ValueListenableBuilder<bool>(
                            valueListenable: windowMaterialAvailable,
                            builder: (context, matOk, _) => ColoredBox(
                              color: matOk
                                  ? Colors.transparent
                                  : AppTheme.of(context).colors.surfaceBase,
                              child: _buildContent(context, useSidebar),
                            ),
                          ),
                        ),
                      ],
                    ),

                    // 抖音「抓取结果」浮层 —— 挂在**导航与内容之上**的这一层。
                    //
                    // 浮层是 `Positioned.fill`，它铺满的是**自己所在的那个 Stack**。
                    // 挂在页面内部（a629679 那版）时页面被 `ClipRect` + `Padding`
                    // 包着，浮层永远溢不出内容区，左侧导航栏一直露在遮罩外 ——
                    // 用户 2026-10-12 的原话是「不是覆盖在网页上，是覆盖在**软件
                    // 表面**」，预览稿的口径同样是铺满整个窗口（含侧边栏）。
                    //
                    // 挂在这里之后：侧边栏（或 Dock 形态下的内容区）与主内容区一起
                    // 被盖住；标题栏与底部 Dock 在这一层**之外**，照旧不被盖 ——
                    // 预览稿里浮层的范围就是 `.app`（侧边栏 + 主区），标题栏不在内。
                    //
                    // 宽度不依赖导航形态：这一层是 `Column` 直接子 `Expanded` 的
                    // 全宽，侧边栏形态下它与侧边栏并排、Dock 形态下没有侧边栏，
                    // 两种形态都铺满整宽。
                    if (_douyinOverlay?.isOpen ?? false)
                      DouyinResultOverlay(
                        onClose: () => _douyinOverlay?.setOpen(false),
                        enqueueing: _douyinOverlay!.enqueueing,
                        onEnqueue: () => _douyinOverlay?.onEnqueue?.call(),
                      ),
                  ],
                ),
              ),
            ],
          ),

          // 底部 Dock（只在 Dock 形态下渲染，浮在内容之上）
          if (!useSidebar)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: Dock(
                  currentRouteId: _routeId,
                  onSelect: _setRoute,
                  taskRunning: taskRunning,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 内容区。
  ///
  /// 底部留白随导航形态变化：Dock 是**浮**在内容之上的，必须留出 104px
  /// 否则最后一屏内容会被 Dock 压住；侧边栏是**占位**布局，不遮挡内容，
  /// 所以底部只需常规留白。
  Widget _buildContent(BuildContext context, bool useSidebar) {
    // WinUI3 的内容区是**纯平面**：贴着侧栏分隔线开始，只有内容内边距，
    // 没有「浮在壁纸上的大卡片」那层留白。另三套保留改造前的 24/32 边距。
    final winui = AppTheme.of(context).style == AppStyle.winui;
    return ClipRect(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1440),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              useSidebar ? (winui ? 28 : 24) : 32,
              winui ? 8 : 0,
              32,
              useSidebar ? 32 : 104,
            ),
            child: _buildPage(context),
          ),
        ),
      ),
    );
  }

  /// 按当前路由渲染页面 —— **保活版**。
  ///
  /// 只把**访问过的**路由放进 [IndexedStack]：访问过的留在树里 → 切走不
  /// `dispose` → WebView 不销毁、历史与滚动位置都在；没访问过的不构造 →
  /// 启动时不会一次建出三个 WebView。
  ///
  /// **children 必须按 `_visited`（首次访问序）排，不能按 [kAppRoutes] 过滤** ——
  /// 前者是 append-only，已活页面的位置恒定；后者会让位置随「又访问了谁」漂移，
  /// 位置一漂 element 就复用不上、State 被 dispose。详见 `_visited` 的注释。
  ///
  /// **为什么用 `IndexedStack`**：它把非当前项的绘制与命中测试都跳过
  /// （`RenderIndexedStack` 只覆写 `paintStack` / `hitTestChildren`，**不覆写
  /// `performLayout`**），而 `webview_windows` 的 `_reportSurfaceSize()` 读的是
  /// `RenderBox.size` —— 所以非当前页的尺寸**保持不变**、不会缩成 0，切回来时
  /// WebView 的尺寸上报是对的。同时它不引入额外的 RenderObject 包装
  /// （用 `_VisibilityScope` 传递可见性），`Positioned` 这类 ParentDataWidget
  /// 仍能正确作用。
  ///
  /// 为什么不是「记住网址、切回来重载」：那样切回要重新加载几秒，且页面上的
  /// 临时状态（弹幕列表、滚动位置、正在播放的位置）全丢；保活则原样留着。
  Widget _buildPage(BuildContext context) {
    // 当前路由不在清单里（加页面时漏登记就会这样）→ 退回不保活的单页渲染，
    // 至少别整屏空白。
    final stack = keepAliveStack(_visited, _routeId);
    if (stack == null) return _pageFor(context, _routeId);

    return IndexedStack(
      index: stack.index,
      sizing: StackFit.expand,
      children: [
        for (final id in stack.children) _pageFor(context, id),
      ],
    );
  }

  /// 单个路由 → 页面组件。**只有这里知道路由与页面的对应关系**。
  Widget _pageFor(BuildContext context, String id) {
    switch (id) {
      case 'dashboard':
        // 首页「总览」：默认落地页，快捷开始用 `_setRoute` 跳到各模块
        return DashboardPage(onNavigate: _setRoute);
      case 'home':
        return HomepagePage(onNavigate: _setRoute);
      case 'douyin':
        // 浮层挂在外壳层，开关由这一层持有 —— 把句柄交给页面，
        // 页面只有权改「开/关」和写进入队入口，渲染位置仍在外壳。
        return DouyinPage(
          onNavigate: _setRoute,
          overlay: _ensureDouyinOverlay(),
        );
      case 'bili':
        return BiliPage(onNavigate: _setRoute);
      case 'bili-batch':
        // 批量页：多行目标 → 列表接口翻到尽 → 逐条稿件投队列
        return BiliBatchPage(onNavigate: _setRoute);
      case 'download-management':
        return const DownloadManagementPage();
      case 'douyin-downloads':
        // 抖音模块的「下载管理」：同一个页面，但 feed 决定它只列抖音的任务、
        // 并多出「已下载（抖音）」这个作品粒度历史 Tab。X 那边反过来看不到
        // 抖音的任务，也看不到这个 Tab —— 两个模块的界面各说各的话。
        return const DownloadManagementPage(feed: DownloadFeed.douyin);
      case 'bili-downloads':
        // B 站那份：只列 source == 'bili' 的任务行，历史 Tab 是「已下载（B 站）」
        // 这个**分 P 粒度**的那本台账（与抖音的作品粒度台账不同文件、不同键）。
        return const DownloadManagementPage(feed: DownloadFeed.bili);
      case 'douyin-auto':
        // 抖音模块的「自动下载」（对应 X 模块的「自动执行」）
        return const DouyinAutoPage();
      case 'auto-task':
        return const AutoTaskPage();
      case 'x-settings':
        // X 下载模块自己的设置（原设置页的「下载」分区）
        return _settingsPage(SettingsScope.xDownload);
      case 'douyin-settings':
        // 抖音解析下载模块自己的设置（原设置页的「抖音」分区）
        return _settingsPage(SettingsScope.douyin);
      case 'bili-settings':
        // B 站解析下载模块自己的设置
        return _settingsPage(SettingsScope.bili);
      case 'settings':
        return _settingsPage(SettingsScope.global);
      case 'about':
        return AboutPage(info: _kAboutInfo);
      default:
        // 不应到达：所有路由都已迁移。
        return _PagePlaceholder(
          routeId: id,
          colors: AppTheme.colorsOf(context),
        );
    }
  }

  /// 四个设置入口共用这一个页面组件，只是 `scope` 不同。
  ///
  /// 材质回调只有「全局设置」那一页真的会用到（外观分区只在 global 渲染），
  /// 但四个入口都必须把它传全 —— 以前每个 case 复制一遍这段异步块，
  /// 加第四个模块时就是第四份副本，而这段里的每条注释都是踩坑写下的。
  ///
  /// `onNavigate` 同理只给全局设置页用（它的「分模块设置」要跳到三个模块的
  /// 设置页），但四个入口都传全：模块设置页自己不需要跨页跳转，传了也不读。
  Widget _settingsPage(SettingsScope scope) => SettingsPage(
    brightness: widget.brightness,
    onMaterialChanged: _applyMaterial,
    scope: scope,
    onNavigate: _setRoute,
  );

  /// 把窗口材质真正落到原生窗口上。
  ///
  /// 这个函数特意把失败原因算好了交回界面（系统关掉「透明效果」时
  /// 只能提示用户，程序无法代劳）—— 以前三处调用点把返回值丢了。
  ///
  /// `dark` 取**应用当前的实际明暗**（`AppTheme.of(context).brightness`）：
  /// 它描述窗口外观（系统绘制的标题栏/边框）的明暗，与选哪种材质无关。
  /// 2026-10-15 之前这里按「材质是不是 mica」猜明暗，浅色+Mica 与
  /// 深色+亚克力两种组合都传反了。
  Future<void> _applyMaterial(WindowMaterial m) async {
    final r = await applyWindowMaterial(
      m,
      dark: AppTheme.of(context).brightness == Brightness.dark,
    );
    // 窗口底按这个值在「透明（材质透出）」与「不透明回退色」之间二选一。
    windowMaterialAvailable.value = r.ok;
    if (!r.ok && mounted) {
      // 用 State.context：build 的参数 context 会被 lint 认为与
      // State.mounted 无关（异步间隙后无法证明它还活着）。
      AppToast.show(context, r.message, kind: AppToastKind.error);
    }
  }

  /// 标题栏上当前页的名字。
  ///
  /// 每条分支各自过 `t()`：`test/l10n_test.dart` 靠扫 `t('…')` 字面量来保证
  /// 英文表覆盖齐全，整串外面再套一个 `t(switch …)` 它就扫不到了。
  String _titleOf(String id) => switch (id) {
    'dashboard' => t('总览'),
    'home' => t('主页'),
    'download-management' => t('下载管理'),
    'auto-task' => t('自动执行'),
    'x-settings' => t('X 下载设置'),
    'douyin' => t('解析下载'),
    'douyin-downloads' => t('下载管理'),
    'douyin-auto' => t('自动下载'),
    'douyin-settings' => t('抖音解析下载设置'),
    // B 站那一项的导航标签与抖音同字（都叫「解析下载」），所以标题栏
    // 必须带模块名，否则切过去看不出自己在哪一个模块里。
    'bili' => t('B 站解析下载'),
    'bili-batch' => t('B 站批量下载'),
    'bili-downloads' => t('下载管理'),
    'bili-settings' => t('B 站解析下载设置'),
    'settings' => t('设置'),
    'about' => t('关于'),
    _ => '',
  };

  Future<void> _windowAction(String action) async {
    switch (action) {
      case 'minimize':
        await windowManager.minimize();
      case 'maximize':
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      case 'close':
        await windowManager.close();
    }
  }
}

/// 页面占位：等各页面迁移完成后替换为真实页面。
/// 下载引擎（aria2c）没能启动时的常驻提示条。
///
/// 为什么必须有它：引擎挂掉时以前界面毫无异常 —— `booted` 只让入队静默失败，
/// 用户看到的是「点了下载没反应」或「任务全部失败」，却没有任何地方说明根因。
/// 实测把随包的 `aria2c.exe` 改名让引擎起不来，主页截图与正常状态一模一样。
class _EngineDownBanner extends StatelessWidget {
  const _EngineDownBanner({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: colors.dangerSoft,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 15, color: colors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t('下载引擎没能启动，下载会失败。请重启应用；若反复出现，可在「全局设置 → 应用」打开日志后再试一次。'),
              style: TextStyle(fontSize: 12.5, color: colors.textStrong),
            ),
          ),
        ],
      ),
    );
  }
}

class _PagePlaceholder extends StatelessWidget {
  final String routeId;
  final AppColors colors;

  const _PagePlaceholder({required this.routeId, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Text(
        tf('页面「{route}」迁移中', {'route': routeId}),
        style: TextStyle(color: colors.textMuted, fontSize: 14),
      ),
    );
  }
}
