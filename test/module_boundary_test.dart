import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/models/download_filter.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/user.dart';
import 'package:parse_dl/pages/download_management_page.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/creation_task_store.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/nav_items.dart';

/// 两个模块的边界：界面各说各的话，任务队列各看各的。
///
/// 与 `platform_terms_test.dart` 的分工：那份只管**模板变量表**；
/// 这份管导航文案、各模块独占文件的界面文案、以及共用的「下载管理」页
/// 在两个 feed 下到底渲染了什么。
///
/// 「界面文案」的判据是**源码里的字符串字面量**（跳过注释后提取）——
/// 注释里解释「为什么和 X 侧分开」是允许提到对方的，界面上不行。

/// X 下载模块独占的文件
const _xOnlyFiles = [
  'lib/pages/homepage_page.dart',
  'lib/pages/auto_task_page.dart',
  'lib/widgets/download_section.dart',
  'lib/widgets/template_row.dart',
  'lib/widgets/account_section.dart',
  'lib/widgets/proxy_section.dart',
  'lib/services/x_api.dart',
  'lib/services/homepage_store.dart',
  'lib/services/auto_task_store.dart',
  'lib/services/creation_task_store.dart',
  'lib/services/twitter_time.dart',
];

/// 抖音模块独占的文件
const _douyinOnlyFiles = [
  'lib/pages/douyin_page.dart',
  'lib/pages/douyin_auto_page.dart',
  'lib/widgets/douyin_section.dart',
  'lib/services/douyin_store.dart',
  'lib/services/douyin_parser.dart',
  'lib/services/douyin_source.dart',
  'lib/services/douyin_scroll.dart',
  'lib/services/douyin_filter.dart',
  'lib/services/douyin_ledger.dart',
  'lib/services/douyin_auto_store.dart',
  'lib/models/douyin_config.dart',
  'lib/models/douyin_auto_task.dart',
];

/// X 侧界面里不能出现的说法
const _xForbidden = ['抖音', '作品', 'aweme', 'douyin'];

/// 抖音侧界面里不能出现的说法
const _douyinForbidden = ['推文', '帖子', 'tweet', 'twitter'];

/// 取源码里的**字符串字面量**内容（注释、标识符都不算）。
List<String> stringLiterals(String src) {
  final out = <String>[];
  final sb = StringBuffer();
  var i = 0;
  final n = src.length;
  var inRawString = false;

  bool isIdent(int cu) =>
      (cu >= 0x41 && cu <= 0x5A) ||
      (cu >= 0x61 && cu <= 0x7A) ||
      (cu >= 0x30 && cu <= 0x39) ||
      cu == 0x5F; // _

  // 跳掉一段插值：`${m.tweetText}` 里的 `tweetText` 是标识符，不是界面文案，
  // 不该参与术语检测。
  void skipInterpolation() {
    if (i + 1 < n && src[i + 1] == '{') {
      var depth = 0;
      while (i < n) {
        final ch = src[i];
        if (ch == '{') depth++;
        if (ch == '}') {
          depth--;
          if (depth == 0) {
            i++;
            return;
          }
        }
        i++;
      }
      return;
    }
    i++; // 裸 $
    while (i < n && isIdent(src.codeUnitAt(i))) {
      i++;
    }
  }

  while (i < n) {
    final c = src[i];
    // 行注释：跳到行尾
    if (c == '/' && i + 1 < n && src[i + 1] == '/') {
      while (i < n && src[i] != '\n') {
        i++;
      }
      continue;
    }
    // 块注释：跳到 */
    if (c == '/' && i + 1 < n && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < n && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      final triple = i + 2 < n && src[i + 1] == c && src[i + 2] == c;
      inRawString = i > 0 && (src[i - 1] == 'r' || src[i - 1] == 'R');
      i += triple ? 3 : 1;
      sb.clear();
      while (i < n) {
        final ch = src[i];
        if (!inRawString && ch == r'$') {
          skipInterpolation();
          continue;
        }
        if (!inRawString && ch == '\\') {
          // 转义：收下下一个字符本体，跳过反斜杠
          if (i + 1 < n) {
            final nx = src[i + 1];
            sb.write(nx == 'n' ? '\n' : nx);
            i += 2;
            continue;
          }
        }
        final ends = triple
            ? (ch == c && i + 2 < n && src[i + 1] == c && src[i + 2] == c)
            : (ch == c || ch == '\n');
        if (ends) {
          i += triple ? 3 : 1;
          break;
        }
        sb.write(ch);
        i++;
      }
      out.add(sb.toString());
      continue;
    }
    i++;
  }
  return out;
}

/// 收集 [files] 里出现的对方术语：返回「文件 → 违规文案」列表。
List<String> _scan(List<String> files, List<String> forbidden) {
  final hits = <String>[];
  for (final path in files) {
    final f = File(path);
    if (!f.existsSync()) {
      hits.add('$path 不存在（文件改名后请同步本测试的清单）');
      continue;
    }
    for (final lit in stringLiterals(f.readAsStringSync())) {
      for (final term in forbidden) {
        if (lit.toLowerCase().contains(term.toLowerCase())) {
          hits.add('$path: 「${lit.replaceAll('\n', '⏎')}」含「$term」');
        }
      }
    }
  }
  return hits;
}

void main() {
  group('导航文案不串台', () {
    test('X 模块的四个导航项里没有抖音说法', () {
      final x = kNavGroups.firstWhere((g) => g.id == 'x');
      for (final c in x.children) {
        for (final term in _xForbidden) {
          expect(c.label.toLowerCase(), isNot(contains(term)),
              reason: 'X 模块导航项「${c.label}」不该出现「$term」');
        }
      }
    });

    test('抖音模块的四个导航项里没有 X 说法', () {
      final d = kNavGroups.firstWhere((g) => g.id == 'douyin');
      for (final c in d.children) {
        for (final term in _douyinForbidden) {
          expect(c.label.toLowerCase(), isNot(contains(term)),
              reason: '抖音模块导航项「${c.label}」不该出现「$term」');
        }
      }
    });

    test('两个模块各有独立的下载管理与自动任务入口', () {
      // 结构一一对应，但 id 必须各自独立，否则激活态会互相点亮
      final x = kNavGroups.firstWhere((g) => g.id == 'x');
      final d = kNavGroups.firstWhere((g) => g.id == 'douyin');
      expect(x.children.length, d.children.length);
      expect(d.children.map((c) => c.id), [
        'douyin',
        'douyin-downloads',
        'douyin-auto',
        'douyin-settings',
      ]);
      for (final g in kNavGroups) {
        for (final c in g.children) {
          expect(navItemById(c.id)?.label, c.label);
        }
      }
      expect(navGroupOf('douyin-downloads')?.id, 'douyin');
      expect(navGroupOf('download-management')?.id, 'x');
    });

    test('抖音页里的页面内跳转只能落在抖音自己的路由上', () {
      // 2026-09-19 真机 bug：抖音下载完点提示上的「去下载管理」，
      // 跳过去看到的却是 X 的任务列表 —— 因为路由 id 写成了
      // `download-management`。这类串台光看文案扫不出来，得扫跳转目标。
      final re = RegExp(
        r"""onNavigate[?!]*\.?(?:call)?\(\s*['"]([^'"]+)['"]""",
      );
      final src = File('lib/pages/douyin_page.dart').readAsStringSync();
      final targets = re.allMatches(src).map((m) => m.group(1)!).toList();
      expect(
        targets,
        isNotEmpty,
        reason: '一条跳转都没扫到 —— 先确认这个正则还跟得上源码写法',
      );
      for (final t in targets) {
        expect(
          navGroupOf(t)?.id,
          'douyin',
          reason: '抖音页跳到了「$t」，那是 X 模块的路由',
        );
      }
    });
  });

  group('模块独占文件的界面文案不串台', () {
    test('X 侧文件的字符串字面量里没有抖音说法', () {
      expect(_scan(_xOnlyFiles, _xForbidden), isEmpty);
    });

    test('抖音侧文件的字符串字面量里没有 X 说法', () {
      expect(_scan(_douyinOnlyFiles, _douyinForbidden), isEmpty);
    });

    test('字面量提取器跳过注释与插值、认得转义', () {
      const src = "/// 注释里的 '假文案'\n"
          "const a = '真文案'; // 尾注 '也是假的'\n"
          "const b = \"跨行\\n还有 TWITTER 字样\";\n"
          "const c = '\${m.tweetText} 视频 \${x}';";
      expect(stringLiterals(src), [
        '真文案',
        '跨行\n还有 TWITTER 字样',
        // 插值里的 tweetText 不算文案，只留下字面片段
        ' 视频 ',
      ]);
    });
  });

  group('下载管理：两个模块各看各的队列', () {
    late Directory tmp;
    late DownloadStore store;
    late DouyinStore douyin;
    late AppState appState;
    late CreationTaskStore creationTasks;

    setUp(() async {
      AppPrefs.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('module-boundary-');
      await AppPaths.init(
          exeDirOverride: tmp, fallbackOverride: tmp);
      store = DownloadStore();
      douyin = DouyinStore();
      appState = await AppState.restore();
      creationTasks = CreationTaskStore(
        appState: appState,
        coordinator: Aria2Coordinator.instance,
      );
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Media media(String id, String source) => Media(
          id: id,
          type: MediaType.video,
          url: 'https://example.invalid/$id.mp4',
          source: source,
        );

    /// 放任务会让 [DownloadStore] 起 2 秒的去抖落盘定时器；不跑过它，
    /// 测试结束时会报「A Timer is still pending」。
    Future<void> flushSave(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
    }

    Future<WidgetTester> pump(
      WidgetTester tester,
      DownloadFeed feed,
    ) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        AppTheme(
          colors: AppColors.dark,
          brightness: Brightness.dark,
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<AppState>.value(value: appState),
              ChangeNotifierProvider<DownloadStore>.value(value: store),
              ChangeNotifierProvider<CreationTaskStore>.value(
                  value: creationTasks),
              ChangeNotifierProvider<DouyinStore>.value(value: douyin),
            ],
            child: MaterialApp(home: Scaffold(body: DownloadManagementPage(feed: feed))),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await flushSave(tester);
      return tester;
    }

    /// 页面上所有可见文字（用于断言「这一侧根本看不到对方的字样」）
    List<String> visibleTexts(WidgetTester tester) => find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .toList();

    testWidgets('X 侧不渲染抖音任务，也没有抖音历史 Tab', (tester) async {
      store.addPending(media('x-1', 'x'), r'F:\dl\x', fileName: 'x-file.mp4');
      store.addPending(
          media('d-1', 'douyin'), r'F:\dl\d', fileName: 'douyin-file.mp4');

      await pump(tester, DownloadFeed.x);

      expect(find.text('x-file.mp4'), findsOneWidget);
      expect(find.text('douyin-file.mp4'), findsNothing);
      expect(find.text('已下载（抖音）'), findsNothing);
      for (final t in visibleTexts(tester)) {
        for (final term in _xForbidden) {
          expect(t.toLowerCase(), isNot(contains(term)),
              reason: 'X 的下载管理页面上出现了「$term」：$t');
        }
      }
    });

    testWidgets('抖音侧只渲染抖音任务，但有作品下载历史 Tab', (tester) async {
      store.addPending(media('x-1', 'x'), r'F:\dl\x', fileName: 'x-file.mp4');
      store.addPending(
          media('d-1', 'douyin'), r'F:\dl\d', fileName: 'douyin-file.mp4');

      await pump(tester, DownloadFeed.douyin);

      expect(find.text('douyin-file.mp4'), findsOneWidget);
      expect(find.text('x-file.mp4'), findsNothing);
      expect(find.text('已下载（抖音）'), findsOneWidget);
      for (final t in visibleTexts(tester)) {
        for (final term in _douyinForbidden) {
          expect(t.toLowerCase(), isNot(contains(term)),
              reason: '抖音的下载管理页面上出现了「$term」：$t');
        }
      }
    });

    testWidgets('空队列的引导语只提本模块的页面名', (tester) async {
      await pump(tester, DownloadFeed.x);
      expect(find.textContaining('主页或自动执行页'), findsOneWidget);
      expect(find.textContaining('解析下载页'), findsNothing);

      await pump(tester, DownloadFeed.douyin);
      expect(find.textContaining('解析下载页或自动下载页'), findsOneWidget);
      expect(find.textContaining('自动执行页'), findsNothing);
    });

    testWidgets('角标数字 = 列表里真的有的行数（创建中不许再混进角标）',
        (tester) async {
      store.addPending(media('x-1', 'x'), r'F:\dl\x', fileName: 'x1.mp4');
      store.addPending(media('x-2', 'x'), r'F:\dl\x', fileName: 'x2.mp4');
      store.addPending(media('d-1', 'douyin'), r'F:\dl\d', fileName: 'd1.mp4');
      for (final t in store.tasks) {
        t.status = DownloadStatus.active;
      }
      // 队列里挂一个「创建中」的抓取任务 —— 它显示在上方区块，不该进角标
      creationTasks.create(
        const TwitterUser(name: '测试用户', screenName: 'testuser'),
        const DownloadFilter(),
      );

      await pump(tester, DownloadFeed.x);
      expect(find.text('x1.mp4'), findsOneWidget);
      expect(find.text('x2.mp4'), findsOneWidget);
      expect(find.text('d1.mp4'), findsNothing);
      // TabButton 把名字和数字渲染成两个 Text；「下载中」这三个字还会出现在
      // 列表项的状态里，所以只断言那个数字角标
      expect(find.text('(2)'), findsOneWidget,
          reason: 'X 侧角标 = 2 条 X 任务；把创建中的 1 个算进来就是 (3)');
      expect(find.text('(3)'), findsNothing);

      await pump(tester, DownloadFeed.douyin);
      expect(find.text('d1.mp4'), findsOneWidget);
      expect(find.text('(1)'), findsOneWidget);
    });

    testWidgets('「清空已完成」不会动另一个模块的任务', (tester) async {
      store.addPending(media('x-1', 'x'), r'F:\dl\x', fileName: 'x.mp4');
      store.addPending(media('d-1', 'douyin'), r'F:\dl\d', fileName: 'd.mp4');
      // 直接置为已完成：这一步在真实链路里由 aria2 事件驱动，测试不想起进程
      for (final t in store.tasks) {
        t.status = DownloadStatus.complete;
      }

      await pump(tester, DownloadFeed.x);
      expect(find.text('清空已完成'), findsOneWidget);

      await tester.tap(find.text('清空已完成'));
      await tester.pump();
      await flushSave(tester);

      expect(store.tasks.length, 1, reason: 'X 侧的「清空已完成」只该清掉 X 的任务');
      expect(store.tasks.single.media.source, 'douyin');
    });
  });
}
