import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'l10n/l10n.dart';
import 'models/settings.dart';
import 'pages/about_page.dart';
import 'pages/auto_task_page.dart';
import 'pages/download_management_page.dart';
import 'pages/douyin_auto_page.dart';
import 'pages/douyin_page.dart';
import 'pages/homepage_page.dart';
import 'pages/settings_page.dart';
import 'services/app_logger.dart';
import 'services/app_state.dart';
import 'services/aria2_coordinator.dart';
import 'services/auto_task_store.dart';
import 'services/creation_task_store.dart';
import 'services/download_store.dart';
import 'services/douyin_auto_store.dart';
import 'services/douyin_store.dart';
import 'services/homepage_store.dart';
import 'services/settings_store.dart';
import 'services/window_effect.dart';
import 'theme/app_theme.dart';
import 'theme/window_material.dart';
import 'widgets/app_toast.dart';
import 'widgets/background_layer.dart';
import 'widgets/dock.dart';
import 'widgets/sidebar_nav.dart';
import 'widgets/title_bar.dart';

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
  tagline: '批量下载 X 与抖音上的图片与视频',
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

  const XDownloaderApp({
    super.key,
    required this.store,
    required this.appState,
    required this.homepageStore,
    required this.downloadStore,
    required this.autoTaskStore,
    required this.creationTaskStore,
    required this.douyinStore,
    required this.douyinAutoStore,
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

          return AppTheme(
            colors: brightness == Brightness.dark
                ? AppColors.dark
                : AppColors.light,
            brightness: brightness,
            child: MaterialApp(
              title: t('解析下载器'),
              debugShowCheckedModeBanner: false,
              locale: locale,
              // 只声明这两档：系统语言是第三种时，Flutter 落到列表第一项（中文）。
              supportedLocales: const [Locale('zh'), Locale('en')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: _buildMaterialTheme(brightness),
              home: _AppShell(brightness: brightness),
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

  ThemeData _buildMaterialTheme(Brightness brightness) {
    final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: 'Microsoft YaHei',
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Colors.transparent,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: c.accent,
            brightness: brightness,
          ).copyWith(
            primary: c.accent,
            surface: c.surfaceSolid,
            onSurface: c.textStrong,
          ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
  }
}

class _AppShell extends StatefulWidget {
  final Brightness brightness;

  const _AppShell({required this.brightness});

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  /// 当前选中的页面（导航 id）。
  String _routeId = 'home';

  void _setRoute(String id) => setState(() => _routeId = id);

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
                child: Row(
                  // 让侧边栏通高（否则它只会按内容高度收缩）
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (useSidebar)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 0, 16),
                        child: SidebarNav(
                          currentRouteId: _routeId,
                          onSelect: _setRoute,
                          // 展开状态来自设置：点标题行切换、写回设置、下次启动保持
                          isGroupExpanded: appearance.isNavGroupExpanded,
                          onToggleGroup: _toggleNavGroup,
                          taskRunning: taskRunning,
                        ),
                      ),
                    Expanded(child: _buildContent(context, useSidebar)),
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
    return ClipRect(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1440),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              useSidebar ? 24 : 32,
              0,
              32,
              useSidebar ? 32 : 104,
            ),
            child: _buildPage(context),
          ),
        ),
      ),
    );
  }

  /// 按当前路由渲染页面。
  Widget _buildPage(BuildContext context) {
    switch (_routeId) {
      case 'home':
        return HomepagePage(onNavigate: _setRoute);
      case 'douyin':
        return DouyinPage(onNavigate: _setRoute);
      case 'download-management':
        return const DownloadManagementPage();
      case 'douyin-downloads':
        // 抖音模块的「下载管理」：同一个页面，但 feed 决定它只列抖音的任务、
        // 并多出「已下载（抖音）」这个作品粒度历史 Tab。X 那边反过来看不到
        // 抖音的任务，也看不到这个 Tab —— 两个模块的界面各说各的话。
        return const DownloadManagementPage(feed: DownloadFeed.douyin);
      case 'douyin-auto':
        // 抖音模块的「自动下载」（对应 X 模块的「自动执行」）
        return const DouyinAutoPage();
      case 'auto-task':
        return const AutoTaskPage();
      case 'x-settings':
        // X 下载模块自己的设置（原设置页的「下载」分区）
        return SettingsPage(
          brightness: widget.brightness,
          onMaterialChanged: (m) async {
            // 这个函数特意把失败原因算好了交回界面（系统关掉「透明效果」时
            // 只能提示用户，程序无法代劳）—— 以前三处调用点把返回值丢了。
            final r = await applyWindowMaterial(m);
            if (!r.ok && mounted) {
              // 用 State.context：build 的参数 context 会被 lint 认为与
              // State.mounted 无关（异步间隙后无法证明它还活着）。
              AppToast.show(this.context, r.message, kind: AppToastKind.error);
            }
          },
          scope: SettingsScope.xDownload,
        );
      case 'douyin-settings':
        // 抖音解析下载模块自己的设置（原设置页的「抖音」分区）
        return SettingsPage(
          brightness: widget.brightness,
          onMaterialChanged: (m) async {
            // 这个函数特意把失败原因算好了交回界面（系统关掉「透明效果」时
            // 只能提示用户，程序无法代劳）—— 以前三处调用点把返回值丢了。
            final r = await applyWindowMaterial(m);
            if (!r.ok && mounted) {
              // 用 State.context：build 的参数 context 会被 lint 认为与
              // State.mounted 无关（异步间隙后无法证明它还活着）。
              AppToast.show(this.context, r.message, kind: AppToastKind.error);
            }
          },
          scope: SettingsScope.douyin,
        );
      case 'settings':
        return SettingsPage(
          brightness: widget.brightness,
          onMaterialChanged: (m) async {
            // 这个函数特意把失败原因算好了交回界面（系统关掉「透明效果」时
            // 只能提示用户，程序无法代劳）—— 以前三处调用点把返回值丢了。
            final r = await applyWindowMaterial(m);
            if (!r.ok && mounted) {
              // 用 State.context：build 的参数 context 会被 lint 认为与
              // State.mounted 无关（异步间隙后无法证明它还活着）。
              AppToast.show(this.context, r.message, kind: AppToastKind.error);
            }
          },
        );
      case 'about':
        return AboutPage(info: _kAboutInfo);
      default:
        // 不应到达：所有路由都已迁移。
        return _PagePlaceholder(
          routeId: _routeId,
          colors: AppTheme.colorsOf(context),
        );
    }
  }

  /// 标题栏上当前页的名字。
  ///
  /// 每条分支各自过 `t()`：`test/l10n_test.dart` 靠扫 `t('…')` 字面量来保证
  /// 英文表覆盖齐全，整串外面再套一个 `t(switch …)` 它就扫不到了。
  String _titleOf(String id) => switch (id) {
    'home' => t('主页'),
    'download-management' => t('下载管理'),
    'auto-task' => t('自动执行'),
    'x-settings' => t('X 下载设置'),
    'douyin' => t('解析下载'),
    'douyin-downloads' => t('下载管理'),
    'douyin-auto' => t('自动下载'),
    'douyin-settings' => t('抖音解析下载设置'),
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