import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/aria2.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/download_list_item.dart';

/// 「错误任务要能重试」+「提示统一在顶部」。
///
/// 前者：自动重试 5 次额度耗尽后任务就定在「错误」Tab，列表行上只有
/// 「移除」—— 用户唯一的出路是删掉再重新下一遍。
/// 后者：抖音侧早就用顶部的 `AppToast` 了，X 侧还留着 19 处底部
/// `SnackBar`，同一个动作在两个模块里提示位置和样式都不一样。

/// 假传输层：只数 addUri 调了几次，不启动真实 aria2c。
class _FakeAria2 extends Aria2 {
  int addCount = 0;
  final List<String> removedGids = [];

  @override
  Future<void> bootstrap() async {}

  @override
  Future<String> addUri(
    String url, {
    required String dir,
    required String out,
    Map<String, String>? options,
  }) async {
    addCount++;
    return 'gid-$addCount';
  }

  @override
  Future<void> remove(String gid) async => removedGids.add(gid);
}

/// DownloadListItem 读 AppTheme.colorsOf，必须包一层才能渲染
Widget _host(Widget child) => AppTheme(
      colors: AppColors.dark,
      brightness: Brightness.dark,
      child: MaterialApp(home: Scaffold(body: child)),
    );

Media _media({String source = 'x'}) => Media(
      id: 'm1',
      type: MediaType.image,
      url: 'https://cdn.example.com/m1.jpg',
      source: source,
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jxxzq_retry_test_');
  });
  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('手动重试', () {
    test('重试会重新提交、额度给满、候选地址从第一条重来', () async {
      final aria = _FakeAria2();
      final c = Aria2Coordinator.withAria2(aria);
      final store = DownloadStore()..setSaveDir(tmp.path);
      await c.bootstrap(store: store, settings: SettingsStore());

      final first = await c.enqueueMedia(_media());
      expect(first.outcome, EnqueueOutcome.queued);
      expect(aria.addCount, 1);

      // 模拟自动重试耗尽后的样子：额度 0 + 错误态
      final t = store.task(first.localId!)!;
      t.retryRemains = 0;
      t.attempt = 3;
      store.markErrorByGid(t.aria2Gid!, '403 Forbidden');
      expect(store.tasksByStatuses({DownloadStatus.error}), hasLength(1));

      final again = await c.retryTask(t.localId);

      expect(again.outcome, EnqueueOutcome.queued);
      expect(aria.addCount, 2, reason: '真的又投了一次给 aria2');
      expect(aria.removedGids, contains('gid-1'), reason: '旧的失败任务要从 aria2 里清掉');
      expect(store.tasks.where((x) => x.status == DownloadStatus.error), isEmpty,
          reason: '列表里不该再留着那条错误');

      final fresh = store.task(again.localId!)!;
      expect(fresh.retryRemains, kAriaRetryTimes, reason: '额度必须给满，否则点一次立刻又失败');
      expect(fresh.attempt, 0, reason: '候选地址从第一条重新试');
      expect(fresh.fileName, t.fileName, reason: '沿用当初解析好的文件名，不重套模板');
      expect(fresh.saveDir, t.saveDir);
    });

    test('抖音任务重试仍按抖音那条规则（不会被当成 X 任务）', () async {
      final aria = _FakeAria2();
      final c = Aria2Coordinator.withAria2(aria);
      final store = DownloadStore()..setSaveDir(tmp.path);
      await c.bootstrap(store: store, settings: SettingsStore());

      final r = await c.enqueueMedia(_media(source: 'douyin'));
      final t = store.task(r.localId!)!;
      store.markErrorByGid(t.aria2Gid!, 'timeout');

      final again = await c.retryTask(t.localId);
      expect(store.task(again.localId!)!.media.source, 'douyin');
    });

    test('任务已被移除时重试不炸', () async {
      final aria = _FakeAria2();
      final c = Aria2Coordinator.withAria2(aria);
      final store = DownloadStore()..setSaveDir(tmp.path);
      await c.bootstrap(store: store, settings: SettingsStore());

      final r = await c.retryTask('不存在的id');
      expect(r.outcome, isNot(EnqueueOutcome.queued));
      expect(aria.addCount, 0);
    });
  });

  group('列表行的重试按钮', () {
    DownloadTask task(DownloadStatus status) => DownloadTask(
          localId: 'l1',
          aria2Gid: 'g1',
          media: _media(),
          saveDir: r'D:\demo\dl',
          fileName: 'a.jpg',
          status: status,
        );

    testWidgets('错误态有「重试」，点了会回调', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_host(DownloadListItem(
        task: task(DownloadStatus.error),
        onRetry: () => tapped++,
      )));

      expect(find.byTooltip('重试'), findsOneWidget);
      await tester.tap(find.byTooltip('重试'));
      expect(tapped, 1);
    });

    testWidgets('已完成态不给重试按钮（只给打开文件夹）', (tester) async {
      await tester.pumpWidget(_host(DownloadListItem(
        task: task(DownloadStatus.complete),
        onRetry: () {},
      )));

      expect(find.byTooltip('重试'), findsNothing);
      expect(find.byTooltip('打开文件夹'), findsOneWidget);
    });
  });

  group('提示位置统一', () {
    test('lib 下不再出现底部 SnackBar，一律走顶部 AppToast', () {
      final bad = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final rel = f.path.replaceAll('\\', '/');
        // 组件自己那一个文件当然要定义 SnackBar 之外的东西
        if (rel.endsWith('widgets/app_toast.dart')) continue;
        final src = f.readAsStringSync();
        if (src.contains('showSnackBar') || src.contains('SnackBar(')) {
          bad.add(rel);
        }
      }
      expect(bad, isEmpty,
          reason: '出现了底部 SnackBar —— 提示应统一用 AppToast（顶部、样式一致）');
    });
  });
}
