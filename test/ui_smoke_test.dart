import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/pages/about_page.dart';
import 'package:parse_dl/pages/auto_task_page.dart';
import 'package:parse_dl/pages/download_management_page.dart';
import 'package:parse_dl/pages/douyin_auto_page.dart';
import 'package:parse_dl/pages/homepage_page.dart';
import 'package:parse_dl/pages/settings_page.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/auto_task_store.dart';
import 'package:parse_dl/services/creation_task_store.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_auto_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/services/homepage_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 逐屏冒烟测试 —— 把「审查每一处 UI」从人肉截图变成可反复跑的机器检查。
///
/// 为什么这么做：2026-09-24 用户要求「认真审查软件内每一处 UI」，但靠我开窗口
/// 一屏屏截图，既看不见进度、也漏得多。而 Flutter 的 `RenderFlex overflow`
/// 在 widget 测试里**会直接让用例失败** —— 也就是说"文字撑破容器"这类问题
/// 根本不需要眼睛看，渲染一遍就暴露了。（`DownloadListItem` 那行溢出 175px
/// 就是这么被撞出来的，不是看出来的。）
///
/// 三档尺寸：常规 1280×900、偏窄 1000×700、以及 `main.dart` 里设的窗口最小
/// 尺寸 880×620 —— 用户能把窗口拖到多小，就该测到多小。
///
/// 每个用例的名字就是「页面 × 尺寸」，跑一次即得问题清单。
///
/// **不测 DouyinPage**：它要真的 WebView2 控件，pump 起来会卡在平台通道上。
/// 那一屏改由注入脚本的诊断与 `douyin_page_results_test` 覆盖。
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

  setUp(() async {
    AppPrefs.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('ui-smoke-');
    await AppPaths.init(
        exeDirOverride: tmp, fallbackOverride: tmp);
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

  Future<void> render(WidgetTester tester, Size size, Widget page) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
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
          ],
          child: MaterialApp(home: Scaffold(body: page)),
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

  final pages = <String, Widget Function()>{
    'X 主页': () => HomepagePage(onNavigate: (_) {}),
    'X 下载管理': () => const DownloadManagementPage(),
    '抖音下载管理': () => const DownloadManagementPage(feed: DownloadFeed.douyin),
    '自动执行': () => const AutoTaskPage(),
    '抖音自动下载': () => const DouyinAutoPage(),
    '全局设置': () => SettingsPage(
        brightness: Brightness.dark, onMaterialChanged: (_) async {}),
    'X 下载设置': () => SettingsPage(
        brightness: Brightness.dark,
        onMaterialChanged: (_) async {},
        scope: SettingsScope.xDownload),
    '抖音设置': () => SettingsPage(
        brightness: Brightness.dark,
        onMaterialChanged: (_) async {},
        scope: SettingsScope.douyin),
    '关于': () => const AboutPage(
        info: AboutInfo(
            name: '解析下载器',
            tagline: '批量下载 X 与抖音上的图片与视频',
            version: '3.7',
            author: '茶沐依',
            license: 'GPL-3.0')),
  };

  for (final entry in pages.entries) {
    for (final size in sizes.entries) {
      testWidgets('${entry.key} @ ${size.key} 不溢出、不崩', (tester) async {
        seed();
        await render(tester, size.value, entry.value());
        expect(tester.takeException(), isNull,
            reason: '${entry.key} 在 ${size.key} 下渲染出问题');
      });
    }
  }

  test('设置页默认语言是跟随系统（不因为加了语言入口就改默认）', () {
    expect(AppearanceSettings().locale.id, 'system');
  });
}
