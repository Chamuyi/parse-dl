import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/pages/download_management_page.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/auto_task_store.dart';
import 'package:parse_dl/services/creation_task_store.dart';
import 'package:parse_dl/services/douyin_auto_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/services/homepage_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 「错误」Tab 上那枚一键重试的显示规则。
///
/// 批量重试本身走的是单条重试同一个 `retryTask`（有 `download_retry_test` 盯着），
/// 这里只钉"什么时候能按、按了说几次" —— 因为最容易出的错是**按钮常驻但没用**，
/// 或者在别的 Tab 上冒出来。
void main() {
  late Directory tmp;
  late SettingsStore settings;
  late AppState appState;
  late DownloadStore downloads;
  late HomepageStore homepage;
  late DouyinStore douyin;
  late CreationTaskStore creationTasks;
  late AutoTaskStore autoTasks;
  late DouyinAutoStore douyinAuto;

  setUp(() async {
    AppPrefs.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('retry-all-');
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

  tearDown(() {
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {/* Windows 句柄未释放，留给系统临时目录 */}
    }
  });

  void seedErrors(int n) {
    for (var i = 0; i < n; i++) {
      downloads.addPending(
        Media(
          id: 'err-$i',
          type: MediaType.video,
          url: 'https://cdn.example.invalid/err-$i.mp4',
          source: 'x',
          tweetId: 'tw-$i',
        ),
        tmp.path,
        fileName: 'err-$i.mp4',
      );
    }
    for (final t in downloads.tasks) {
      if (t.status == DownloadStatus.pending) {
        t.status = DownloadStatus.error;
        t.errorMessage = '403 Forbidden';
      }
    }
  }

  Future<void> render(WidgetTester tester, DownloadFeed feed) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppTheme(
      colors: AppColors.dark,
      brightness: Brightness.dark,
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsStore>.value(value: settings),
          ChangeNotifierProvider<AppState>.value(value: appState),
          ChangeNotifierProvider<HomepageStore>.value(value: homepage),
          ChangeNotifierProvider<DownloadStore>.value(value: downloads),
          ChangeNotifierProvider<DouyinStore>.value(value: douyin),
          ChangeNotifierProvider<CreationTaskStore>.value(value: creationTasks),
          ChangeNotifierProvider<AutoTaskStore>.value(value: autoTasks),
          ChangeNotifierProvider<DouyinAutoStore>.value(value: douyinAuto),
        ],
        child: MaterialApp(
          home: Scaffold(body: DownloadManagementPage(feed: feed)),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('错误 Tab 上按失败条数标数量', (tester) async {
    seedErrors(3);
    await render(tester, DownloadFeed.x);
    downloads.setCurrentTab('错误');
    await tester.pump();
    expect(find.text('重试全部（3）'), findsOneWidget);
  });

  testWidgets('没有失败项时按钮置灰，而不是消失', (tester) async {
    await render(tester, DownloadFeed.x);
    downloads.setCurrentTab('错误');
    await tester.pump();
    final button = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('重试全部（0）'),
        matching: find.bySubtype<ButtonStyleButton>(),
      ),
    );
    expect(button.onPressed, isNull, reason: '0 条时必须灰掉，点了没反应像坏了');
  });

  testWidgets('「下载中」Tab 不出现这枚按钮', (tester) async {
    seedErrors(2);
    await render(tester, DownloadFeed.x);
    downloads.setCurrentTab('下载中');
    await tester.pump();
    expect(find.textContaining('重试全部'), findsNothing);
  });

  testWidgets('抖音侧的下载管理同样有这枚按钮', (tester) async {
    seedErrors(1);
    await render(tester, DownloadFeed.douyin);
    downloads.setCurrentTab('错误');
    await tester.pump();
    // 上面 seedErrors 造的是 source=x 的任务，抖音侧按 source 过滤后应当是 0 条
    expect(find.text('重试全部（0）'), findsOneWidget);
  });
}
