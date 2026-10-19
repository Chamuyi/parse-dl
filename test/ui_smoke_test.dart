import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/pages/about_page.dart';
import 'package:parse_dl/pages/auto_task_page.dart';
import 'package:parse_dl/pages/bili_batch_page.dart';
import 'package:parse_dl/pages/dashboard_page.dart';
import 'package:parse_dl/pages/download_management_page.dart';
import 'package:parse_dl/pages/douyin_auto_page.dart';
import 'package:parse_dl/pages/homepage_page.dart';
import 'package:parse_dl/pages/settings_page.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/auto_task_store.dart';
import 'package:parse_dl/services/bili_batch_store.dart';
import 'package:parse_dl/services/bili_ledger.dart';
import 'package:parse_dl/services/creation_task_store.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_auto_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/services/homepage_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 逐屏冒烟测试 —— 把「审查每一处 UI」从人肉截图变成可反复跑的机器检查。
///
/// 为什么这么做：2026-09-24 用户要求「认真审查软件内每一处 UI」，但靠开窗口
/// 一屏屏截图，既看不见进度、也漏得多。而 Flutter 的 `RenderFlex overflow`
/// 在 widget 测试里**会直接让用例失败** —— 也就是说"文字撑破容器"这类问题
/// 根本不需要眼睛看，渲染一遍就暴露了。（`DownloadListItem` 那行溢出 175px
/// 就是这么被撞出来的，不是看出来的。）
///
/// ### 2026-10-15 扩成全矩阵：3 风格 × 2 明暗 × 13 页 × 3 尺寸
///
/// 原来这套只泵**一种**外观（`AppColors.dark` + `brightness: dark`，
/// 且不传 `style` → 落到默认 frosted）。于是「液体玻璃风格下卡片内容整片
/// 消失」那个真机缺陷**完整地穿过了这 39 条用例** —— 它只在 liquid 下出现。
///
/// 现在每个组合都做两件事：
///   1. `takeException()` 为空（不崩、不溢出）—— 原判据；
///   2. **内容真的被绘制**：数渲染图里的深色像素。卡片若被材质/边框盖住，
///      树上照样有 widget、语义层照样完整，但像素是空的（第 1 条判不出来）。
///
/// 三档尺寸：常规 1280×900、偏窄 1000×700、以及 `main.dart` 里设的窗口最小
/// 尺寸 880×620 —— 用户能把窗口拖到多小，就该测到多小。
///
/// **不测 DouyinPage / BiliPage**：它们要真的 WebView2 控件，pump 起来会卡在
/// 平台通道上。抖音那一屏改由注入脚本的诊断与 `douyin_page_results_test`
/// 覆盖，B 站那一屏由 `bili_page_test` 覆盖（那里只测右侧面板：WebView 起不来时
/// 左边落占位面板，右边照样渲染，不需要插件也能把列表与文案测到）。
void main() {
  late Directory tmp;
  late SettingsStore settings;
  late AppState appState;
  late DownloadStore downloads;
  late DouyinStore douyin;
  late HomepageStore homepage;
  late AutoTaskStore autoTasks;
  late CreationTaskStore creationTasks;
  late DouyinAutoStore douyinAuto;
  late BiliLedger biliLedger;
  late BiliBatchStore biliBatch;

  setUp(() async {
    AppPrefs.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('ui-smoke-');
    await AppPaths.init(exeDirOverride: tmp, fallbackOverride: tmp);
    settings = SettingsStore();
    appState = await AppState.restore();
    downloads = DownloadStore()..setSaveDir(tmp.path);
    douyin = DouyinStore();
    homepage = HomepageStore(appState);
    creationTasks = CreationTaskStore(
      appState: appState,
      coordinator: Aria2Coordinator.instance,
    );
    autoTasks = AutoTaskStore(
      appState: appState,
      homepageStore: homepage,
      creationTasks: creationTasks,
    );
    douyinAuto = DouyinAutoStore();
    // 「下载管理（B 站）」那个 Tab 的角标读 `BiliLedger`，树上没有它就直接抛
    // ProviderNotFound —— 与 `main.dart` 里必须挂上它是同一件事的两侧。
    biliLedger = BiliLedger();
    biliBatch = BiliBatchStore();
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// 塞一批**故意取长名字**的数据，并且要把**每种状态**都造出来。
  ///
  /// 第一版只塞了 `pending` 任务，结果整套用例是空的：状态详情那行只在
  /// 「下载中」才打印完整保存路径、只在「错误」才打印 aria2 原始报错，
  /// 而这两处才是会撑破容器的 —— 我把溢出改回去，测试照样全绿（反向对照
  /// 没抓到）。所以这里逐态造数据，空列表和没走到的分支都会把问题藏起来。
  void seed() {
    Media m(String id, MediaType type, String source) => Media(
          id: id,
          type: type,
          url: 'https://cdn.example.invalid/$id.mp4',
          source: source,
          tweetId: '1700000000000000000',
        );

    final longDir = r'G:\媒体下载\一个相当长的用户名目录名称\2026-09-24';
    final longName = '一个非常长的文件名用来试探这一行会不会撑破.mp4';

    downloads.addPending(m('x-active', MediaType.video, 'x'), longDir,
        fileName: longName);
    downloads.addPending(m('x-error', MediaType.image, 'x'), longDir,
        fileName: longName);
    downloads.addPending(m('x-done', MediaType.video, 'x'), longDir,
        fileName: longName);
    downloads.addPending(m('x-paused', MediaType.video, 'x'), longDir,
        fileName: longName);

    // 名字都一样，按顺序取：pending → active → error → complete → paused
    final all = downloads.tasks.toList();
    all[0].status = DownloadStatus.active;
    all[0].progress = 453;
    all[0].totalBytes = 512 * 1024 * 1024;
    all[0].downloadedBytes = 232 * 1024 * 1024;
    all[1].status = DownloadStatus.error;
    all[1].errorMessage =
        '下载失败：HTTP 响应状态码为 403 Forbidden，已重试 5 次仍失败（签名过期）';
    all[2].status = DownloadStatus.complete;
    all[3].status = DownloadStatus.paused;

    // B 站的一条分 P 落**两行**（视频流 + 音频流），名字都比 X 那批长，
    // 因为这两行才是「下载管理（B 站）」真正会画出来的形状。
    downloads.addPending(m('bi-v', MediaType.video, 'bili'), longDir,
        fileName: 'P03-一个非常长的分P标题用来试探这一行会不会撑破.video.m4s');
    downloads.addPending(m('bi-a', MediaType.audio, 'bili'), longDir,
        fileName: 'P03-一个非常长的分P标题用来试探这一行会不会撑破.audio.m4s');
    downloads.tasks.last.status = DownloadStatus.active;

    douyin.ingest([
      for (var i = 1; i <= 3; i++)
        Media(
          id: 'dy-$i',
          type: MediaType.image,
          url: 'https://cdn.example.invalid/dy-$i.jpg',
          source: 'douyin',
          tweetId: 'aweme-long',
          tweetText: '这是一条描述相当长的抖音作品，用来检查作品粒度那一行的换行与截断',
          userName: '一个很长的作者昵称',
        ),
    ]);
  }

  /// 渲染结果里深色像素的数量 —— 「内容真的被画出来了吗」的量化判据。
  ///
  /// 取图前先 `pump()`：`toImage()` 要求目标 RenderRepaintBoundary 已经 paint
  /// 过，否则会拿到 `NEEDS-PAINT` 的树并抛异常。
  Future<int> darkPixels(WidgetTester tester, Key key) async {
    await tester.pump();
    late final ui.Image image;
    await tester.runAsync(() async {
      final b = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      image = await b.toImage();
    });
    late final ByteData? bd;
    await tester.runAsync(() async {
      bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    });
    final bytes = bd!.buffer.asUint8List();
    var dark = 0;
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      // 深色 = 三个通道都压得很低。深色主题下正文/标题就是这类像素；
      // 浅色主题下则是图标与描边。无论哪套，只要内容真画出来了就不会是 0。
      if (bytes[i] < 90 && bytes[i + 1] < 90 && bytes[i + 2] < 90) dark++;
    }
    return dark;
  }

  final boundaryKey = const ValueKey('smoke-boundary');

  Future<void> render(
    WidgetTester tester,
    Size size,
    Widget page, {
    required AppStyle style,
    required Brightness brightness,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppTheme(
        colors: brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light,
        brightness: brightness,
        style: style,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsStore>.value(value: settings),
            ChangeNotifierProvider<AppState>.value(value: appState),
            ChangeNotifierProvider<HomepageStore>.value(value: homepage),
            ChangeNotifierProvider<DownloadStore>.value(value: downloads),
            ChangeNotifierProvider<AutoTaskStore>.value(value: autoTasks),
            ChangeNotifierProvider<CreationTaskStore>.value(
                value: creationTasks),
            ChangeNotifierProvider<DouyinStore>.value(value: douyin),
            ChangeNotifierProvider<DouyinAutoStore>.value(value: douyinAuto),
            ChangeNotifierProvider<BiliLedger>.value(value: biliLedger),
            ChangeNotifierProvider<BiliBatchStore>.value(value: biliBatch),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: RepaintBoundary(key: boundaryKey, child: page),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  const sizes = <String, Size>{
    '1280x900': Size(1280, 900),
    '1000x700': Size(1000, 700),
    '最小880x620': Size(880, 620),
  };

  /// 设置页的 `brightness` 参数跟着当前组合走。
  ///
  /// **2026-10-19 T6 实测澄清**：旧版这里写死 `Brightness.dark`，看起来像
  /// 「浅色档没测到设置页」，但实际**不是** —— `SettingsPage.brightness`
  /// 是个**死参数**：`lib/pages/settings_page.dart` 里它只被声明与接收
  /// （:96 / :112），**从未参与任何渲染**；设置页的真实明暗来自它内部
  /// `AppTheme.colorsOf(context)`，而 `AppTheme.brightness` 在下面 `render()`
  /// 里**已经按当前组合传了**。所以浅色档下设置页本来就是浅色渲染的。
  ///
  /// 把这里改成可变量是为了消除这个误导性的写死值（负控制实测：改回
  /// `Brightness.dark` 后 `ui_smoke_test` 仍全绿，证实它不影响渲染）。
  /// **真正的像素级盲区不在本文件**，而在 `card_content_painted_test.dart`
  /// 的深色档 —— 详见 `appearance_matrix_painted_test.dart` 顶部说明。
  Brightness pageBrightness = Brightness.dark;

  final pages = <String, Widget Function()>{
    '总览': () => DashboardPage(onNavigate: (_) {}),
    'X 主页': () => HomepagePage(onNavigate: (_) {}),
    'X 下载管理': () => const DownloadManagementPage(),
    '抖音下载管理': () => const DownloadManagementPage(feed: DownloadFeed.douyin),
    // 第三个队列：这一屏要求 `BiliLedger` 在树上（角标读它），漏挂会直接抛 ——
    // 冒烟测试顺手把「main.dart 接线」这件事钉住。
    'B 站下载管理': () => const DownloadManagementPage(feed: DownloadFeed.bili),
    '自动执行': () => const AutoTaskPage(),
    '抖音自动下载': () => const DouyinAutoPage(),
    // 批量页这一屏：WebView 在测试里起不来，走的正是那块「没有运行时」的占位面板，
    // 所以这里能验右侧面板在三种窗口尺寸下不撑破。
    'B 站批量下载': () => const BiliBatchPage(),
    '全局设置': () => SettingsPage(
        brightness: pageBrightness, onMaterialChanged: (_) async {}),
    'X 下载设置': () => SettingsPage(
        brightness: pageBrightness,
        onMaterialChanged: (_) async {},
        scope: SettingsScope.xDownload),
    '抖音设置': () => SettingsPage(
        brightness: pageBrightness,
        onMaterialChanged: (_) async {},
        scope: SettingsScope.douyin),
    'B 站设置': () => SettingsPage(
        brightness: pageBrightness,
        onMaterialChanged: (_) async {},
        scope: SettingsScope.bili),
    '关于': () => const AboutPage(
        info: AboutInfo(
            name: '解析下载器',
            tagline: '批量下载 X 与抖音上的图片与视频',
            version: '3.7',
            author: '茶沐依',
            license: 'GPL-3.0')),
  };

  // ── 主矩阵：13 页 × 3 风格 × 2 明暗 × 3 尺寸 = 234 组合 ──────────────
  for (final style in AppStyle.values) {
    for (final brightness in Brightness.values) {
      final combo = '${style.label}·${brightness == Brightness.dark ? '深色' : '浅色'}';
      for (final entry in pages.entries) {
        for (final size in sizes.entries) {
          testWidgets('${entry.key} @ $combo @ ${size.key} 不溢出、内容可见',
              (tester) async {
            seed();
            pageBrightness = brightness;
            await render(
              tester,
              size.value,
              entry.value(),
              style: style,
              brightness: brightness,
            );

            // ① 不崩、不溢出（原有判据）
            expect(tester.takeException(), isNull,
                reason: '${entry.key} 在 $combo / ${size.key} 下渲染出问题');

            // ② 内容真的被绘制（新增判据，抓「卡片被材质盖住」这类问题）
            final dark = await darkPixels(tester, boundaryKey);
            expect(
              dark,
              greaterThan(200),
              reason: '${entry.key} 在 $combo / ${size.key} 下渲染出的深色像素只有 '
                  '$dark 个 —— 页面内容疑似被材质或边框盖住（树上/语义层看不出来）',
            );
          });
        }
      }
    }
  }

  // ── 负控制：证明上面那条「内容可见」判据真的会判错 ──────────────────
  //
  // 手工复刻**修复前**的液体玻璃边框写法（顶边与三边不同色 →
  // `Border.isUniform == false`），它会让卡片子内容整片消失。若这条判据
  // 在它身上仍然是绿的，那说明「数深色像素」这个方法本身失效了。
  testWidgets('负控制：非 uniform 边框确实会让内容不可见', (tester) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const badBorder = Border(
      top: BorderSide(color: Color(0xF2FFFFFF)),
      left: BorderSide(color: Color(0xBFFFFFFF)),
      right: BorderSide(color: Color(0xBFFFFFFF)),
      bottom: BorderSide(color: Color(0xBFFFFFFF)),
    );
    expect(badBorder.isUniform, isFalse, reason: '前置：这个边框必须是非 uniform');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 400,
                height: 200,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0x81FFFFFF),
                    borderRadius: BorderRadius.circular(20),
                    border: badBorder,
                  ),
                  child: const Text(
                    '█',
                    style: TextStyle(fontSize: 80, color: Color(0xFF000000)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 非 uniform 边框下子树的 RenderObject 会停在 NEEDS-PAINT，`toImage()`
    // 直接抛异常而不是返回空图 —— 「取不到像素」本身就是内容没被绘制的证据。
    //
    // 这里用 `takeException()` 收走 Flutter 在渲染阶段记下的异常：直接
    // try/catch 包 `runAsync` 兜不住它（异常走的是 binding 的错误上报通道，
    // 会以「Multiple exceptions were detected」的形式让用例失败）。
    final dark = await darkPixels(tester, boundaryKey).catchError((_) => -1);
    tester.takeException(); // 收走渲染阶段记下的异常，避免污染用例结果

    // 阈值取 1000 而不是主判据的 200：正常页面量级在数千（见下方注释），
    // 非 uniform 边框只留下边框抗锯齿的几百个像素 —— 两者差一个数量级，
    // 1000 落在中间才真正分得开。
    expect(
      dark,
      lessThan(1000),
      reason: '负控制失败：非 uniform 边框这次竟然没让内容消失（实测 $dark）。'
          '若 Flutter 修了这个行为，可以简化主判据，但**不要**直接删掉它。',
    );
  });

  test('设置页默认语言是跟随系统（不因为加了语言入口就改默认）', () {
    expect(AppearanceSettings().locale.id, 'system');
  });
}
