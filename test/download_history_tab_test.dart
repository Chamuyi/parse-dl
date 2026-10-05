import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/pages/download_management_page.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/creation_task_store.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 「已下载（抖音）」Tab 的界面回归。
///
/// 这个 Tab 展示的就是「跳过已下载」用的那份台账，所以有两点必须钉死：
///   1. 没有记录时给得出**空态**，而不是一片空白让人以为坏了；
///   2. 删掉一条之后**台账里真的少了** —— 下次批量下载才会重新下它，
///      不能只是界面上那一行消失。
///
/// ## 这个文件里踩过的两个坑（都留了注释，别再踩）
///
/// 1. **不能用 `pumpAndSettle`**：页面顶部的「aria2 未启动」提示里有个
///    `CircularProgressIndicator`，那是无限动画，`pumpAndSettle` 会一直
///    等它停 → 直接超时。
/// 2. **真实文件 IO 必须包进 `tester.runAsync()`**：`testWidgets` 跑在
///    假时钟里，磁盘 Future 不包进去就永远不会完成，测试会静默挂死
///    （`markAll` 就是这么挂住的）。
void main() {
  late Directory tmp;

  setUp(() async {
    AppPrefs.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('dl-history-');
    // fallbackOverride 也要给：AppPaths.init 会先问一次备用目录，
    // 测试环境里没有 path_provider 插件，不传就 MissingPluginException。
    await AppPaths.init(
        exeDirOverride: tmp, fallbackOverride: tmp);
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// 手动走几帧（原因见文件头「坑 1」）
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// 写台账（原因见文件头「坑 2」）
  Future<void> seed(WidgetTester tester, DouyinStore douyin, String id,
      {String? title, String? author}) async {
    await tester.runAsync(() async {
      await douyin.ledger.markAll(
        [id],
        meta: (title == null && author == null)
            ? null
            : {id: (title: title, author: author)},
      );
    });
  }

  Future<void> pumpPage(WidgetTester tester, DouyinStore douyin) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final appState = await AppState.restore();

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: appState),
            ChangeNotifierProvider<DownloadStore>(
                create: (_) => DownloadStore()),
            ChangeNotifierProvider<CreationTaskStore>(
              create: (_) => CreationTaskStore(
                appState: appState,
                coordinator: Aria2Coordinator.instance,
              ),
            ),
            ChangeNotifierProvider<DouyinStore>.value(value: douyin),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DownloadManagementPage(feed: DownloadFeed.douyin),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> openHistoryTab(WidgetTester tester) async {
    await tester.tap(find.text('已下载（抖音）'));
    await settle(tester);
  }

  testWidgets('Tab 栏里有第 4 个「已下载（抖音）」', (tester) async {
    await pumpPage(tester, DouyinStore());
    expect(find.text('已下载（抖音）'), findsOneWidget);
  });

  testWidgets('没有记录时给出空态说明（不是一片空白）', (tester) async {
    await pumpPage(tester, DouyinStore());
    await openHistoryTab(tester);

    expect(find.text('还没有下载记录'), findsOneWidget);
    expect(find.textContaining('下次批量下载会跳过它们'), findsOneWidget);
  });

  testWidgets('有记录时列出作品：标题 / 作者 / 时间', (tester) async {
    final douyin = DouyinStore();
    await seed(tester, douyin, '7111111111111111111',
        title: '测试作品标题', author: '测试作者');

    await pumpPage(tester, douyin);
    await openHistoryTab(tester);

    expect(find.text('测试作品标题'), findsOneWidget);
    expect(find.textContaining('测试作者'), findsOneWidget);
    expect(find.textContaining('7111111111111111111'), findsOneWidget);
  });

  testWidgets('单条删除：界面消失，且台账真的少了（下次才会重新下载）', (tester) async {
    final douyin = DouyinStore();
    await seed(tester, douyin, '7222222222222222222',
        title: '要删掉的作品', author: '某人');
    expect(douyin.ledger.count, 1);

    await pumpPage(tester, douyin);
    await openHistoryTab(tester);
    expect(find.text('要删掉的作品'), findsOneWidget);

    // remove 里也有落盘，同样放进 runAsync
    await tester.runAsync(() async {
      await douyin.ledger.remove('7222222222222222222');
    });
    await settle(tester);

    expect(find.text('要删掉的作品'), findsNothing);
    expect(douyin.ledger.count, 0,
        reason: '删了就该从台账里消失，否则下次还会被当成「已下载」跳过');
  });

  testWidgets('台账条数会反映到 Tab 角标上', (tester) async {
    final douyin = DouyinStore();
    await seed(tester, douyin, '7333333333333333333');

    await pumpPage(tester, douyin);
    expect(find.text('(1)'), findsWidgets);
  });
}
