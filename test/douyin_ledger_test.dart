import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/douyin_ledger.dart';
import 'package:parse_dl/services/douyin_store.dart';

/// 「已下载」台账测试（v2：带时间戳的下载历史）。
///
/// **粒度是作品（`aweme_id`）而不是文件** —— 这是参照实现的既定语义：
/// 一条图文里少下了一张图，整条作品也会算已下载。本项目沿用同一粒度，
/// 这样「跳过已下载 N 个」的数字才和参照实现对得上。
///
/// v2 相对 v1 的三点变化：
///   1. 记录**下载时间**（以及标题/作者），这样「下载历史」才是有用的列表；
///   2. 向下兼容读 v1 的 `{"<id>": true}`（老用户的记录不作废）；
///   3. **不再按「当前列表」裁剪**（那会让历史凭空消失），改成按条数上限丢最旧。
void main() {
  late Directory tmp;

  /// 把数据目录指到临时目录，这样 `load()` / 落盘都能真实跑
  Future<void> useTempDataDir() async {
    tmp = Directory.systemTemp.createTempSync('ledger_test_');
    await AppPaths.init(
      exeDirOverride: tmp,
      fallbackOverride: tmp,
    );
  }

  File ledgerFile() =>
      File('${AppPaths.configDir.path}${Platform.pathSeparator}'
          '${DouyinLedger.fileName}');

  setUp(useTempDataDir);

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('标记与查询', () {
    test('markAll 后 contains 为真', () async {
      final l = DouyinLedger();
      expect(l.count, 0);
      expect(l.contains('w1'), isFalse);

      await l.markAll(['w1', 'w2']);
      expect(l.count, 2);
      expect(l.contains('w1'), isTrue);
      expect(l.contains('w2'), isTrue);
      expect(l.contains('w3'), isFalse);
    });

    test('containsMedia 直接吃 tweetId，空 / null 一律 false', () async {
      final l = DouyinLedger();
      await l.markAll(['w1']);
      expect(l.containsMedia('w1'), isTrue);
      expect(l.containsMedia('w2'), isFalse);
      expect(l.containsMedia(''), isFalse);
      expect(l.containsMedia(null), isFalse);
    });

    test('重复标记不增加计数（幂等）', () async {
      final l = DouyinLedger();
      await l.markAll(['w1']);
      await l.markAll(['w1', 'w1']);
      expect(l.count, 1);
    });

    test('空字符串被忽略（避免脏数据占位）', () async {
      final l = DouyinLedger();
      await l.markAll(['', 'w1']);
      expect(l.count, 1);
      expect(l.contains(''), isFalse);
    });

    test('变更会触发通知（设置页那个计数靠它刷新）', () async {
      final l = DouyinLedger();
      var notified = 0;
      l.addListener(() => notified++);

      await l.markAll(['w1']);
      expect(notified, 1);

      // 没有新增时不通知
      await l.markAll(['w1']);
      expect(notified, 1);

      await l.markAll(['w2']);
      expect(notified, 2);
    });

    test('loaded 默认 false（load() 之前页面要先自查）', () {
      expect(DouyinLedger().loaded, isFalse);
    });
  });

  group('v2：下载历史（时间 + 标题 + 作者）', () {
    test('markAll 带上元数据后，records 里能读到标题/作者/时间', () async {
      final l = DouyinLedger();
      await l.markAll(
        ['w1'],
        meta: {
          'w1': (title: '第一条作品', author: '小茶'),
        },
      );

      final r = l.records.single;
      expect(r.awemeId, 'w1');
      expect(r.title, '第一条作品');
      expect(r.author, '小茶');
      expect(r.at, isNotNull);
      expect(r.time, isNotNull);
    });

    test('没给元数据也要保留记录（只差标题作者）', () async {
      final l = DouyinLedger();
      await l.markAll(['w1']);

      final r = l.records.single;
      expect(r.awemeId, 'w1');
      expect(r.title, isNull);
      expect(r.at, isNotNull, reason: '时间戳由台账自己打');
    });

    test('records 按时间从新到旧', () async {
      final l = DouyinLedger();
      await l.markAll(['old']);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await l.markAll(['new']);

      expect(l.records.map((r) => r.awemeId).toList(), ['new', 'old']);
    });

    test('重复标记不会把时间刷掉（历史时间应当是第一次下载的时间）', () async {
      final l = DouyinLedger();
      await l.markAll(['w1']);
      final first = l.records.single.at;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await l.markAll(['w1']);

      expect(l.records.single.at, first);
    });
  });

  group('落盘格式与向下兼容', () {
    test('落盘是带 version 的 v3 结构', () async {
      final l = DouyinLedger();
      await l.markAll(
        ['w1'],
        meta: {
          'w1': (title: '标题', author: '作者'),
        },
      );
      await l.load();

      final raw = ledgerFile().readAsStringSync();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      expect(j['version'], DouyinLedger.kFormatVersion);
      final items = j['items'] as Map<String, dynamic>;
      expect(items.keys, contains('w1'));
      expect((items['w1'] as Map)['text'], '标题');
      expect((items['w1'] as Map)['user'], '作者');
      expect((items['w1'] as Map)['t'], isA<int>());
    });

    test('重新 load 能读回完整记录（真往返）', () async {
      final a = DouyinLedger();
      await a.markAll(
        ['w1'],
        meta: {
          'w1': (title: '标题', author: '作者'),
        },
      );

      final b = DouyinLedger();
      await b.load();

      expect(b.count, 1);
      expect(b.contains('w1'), isTrue);
      final r = b.records.single;
      expect(r.title, '标题');
      expect(r.author, '作者');
      expect(r.at, a.records.single.at);
    });

    test('兼容 v1 的 {"<id>": true}（老用户记录不作废）', () async {
      AppPaths.configDir.createSync(recursive: true);
      ledgerFile().writeAsStringSync('{"w1":true,"w2":true,"bad":false}');

      final l = DouyinLedger();
      await l.load();

      expect(l.contains('w1'), isTrue);
      expect(l.contains('w2'), isTrue);
      expect(l.contains('bad'), isFalse, reason: 'false 不算已下载');
      expect(l.records.length, 2);
      expect(l.records.first.at, isNull, reason: 'v1 没有时间信息，如实留空');
    });

    test('v1 记录在下一次写入时被升级成 v3', () async {
      AppPaths.configDir.createSync(recursive: true);
      ledgerFile().writeAsStringSync('{"w1":true}');

      final l = DouyinLedger();
      await l.load();
      await l.markAll(['w2']);
      await l.load();

      final j = jsonDecode(ledgerFile().readAsStringSync()) as Map<String, dynamic>;
      expect(j['version'], DouyinLedger.kFormatVersion);
      expect((j['items'] as Map).keys, containsAll(['w1', 'w2']));
    });

    test('坏数据整份丢弃，且不抛异常', () async {
      AppPaths.configDir.createSync(recursive: true);
      ledgerFile().writeAsStringSync('{{{ 这不是 JSON');

      final l = DouyinLedger();
      await l.load();

      expect(l.count, 0);
      expect(l.loaded, isTrue);
    });
  });

  group('remove / clear（历史记录的删除入口）', () {
    test('remove 删掉一条并通知', () async {
      final l = DouyinLedger();
      await l.markAll(['w1', 'w2']);
      var notified = 0;
      l.addListener(() => notified++);

      await l.remove('w1');

      expect(l.contains('w1'), isFalse);
      expect(l.contains('w2'), isTrue);
      expect(notified, 1);
    });

    test('remove 不存在的 id 不发通知', () async {
      final l = DouyinLedger();
      await l.markAll(['w1']);
      var notified = 0;
      l.addListener(() => notified++);

      await l.remove('不存在');
      expect(notified, 0);
    });

    test('remove 会落盘（下次 load 不会复活）', () async {
      final l = DouyinLedger();
      await l.markAll(['w1', 'w2']);
      await l.remove('w1');

      final b = DouyinLedger();
      await b.load();
      expect(b.contains('w1'), isFalse);
      expect(b.contains('w2'), isTrue);
    });

    test('清空所有标记', () async {
      final l = DouyinLedger();
      await l.markAll(['w1', 'w2']);

      await l.clear();
      expect(l.count, 0);
      expect(l.contains('w1'), isFalse);
      expect(l.records, isEmpty);
    });

    test('本来就是空的时候直接返回，不发通知', () async {
      final l = DouyinLedger();
      var notified = 0;
      l.addListener(() => notified++);

      await l.clear();
      expect(notified, 0);
    });
  });

  group('上限：只丢最旧，不再按当前列表裁剪', () {
    test('超过上限时丢最旧的记录', () async {
      final l = DouyinLedger(maxRecords: 3);
      await l.markAll(['a']);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await l.markAll(['b']);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await l.markAll(['c']);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await l.markAll(['d']);

      expect(l.count, 3);
      expect(l.contains('a'), isFalse, reason: '最旧的被丢掉');
      expect(l.contains('d'), isTrue);
    });

    test('切换列表不会删掉历史（v1 的 prune 行为已移除）', () async {
      final l = DouyinLedger();
      await l.markAll(['w1', 'w2', 'w3']);

      // 这里曾经会调用 prune({'w1'})，把 w2/w3 抹掉
      expect(l.contains('w2'), isTrue);
      expect(l.contains('w3'), isTrue);
    });
  });

  group('与 DouyinStore 的联动', () {
    Media post(String id, String tweetId, {String? text, String? user}) => Media(
          id: id,
          type: MediaType.video,
          url: 'https://x/$id.mp4',
          source: 'douyin',
          tweetId: tweetId,
          tweetText: text,
          userName: user,
        );

    test('isDownloaded 判的是「作品」而不是「某一条媒体」', () async {
      final s = DouyinStore();
      s.ingest([post('a1', 'wa'), post('a2', 'wa'), post('b1', 'wb')]);

      await s.ledger.markAll(['wa']);

      expect(s.isDownloaded(s.items.firstWhere((m) => m.id == 'a1')), isTrue);
      expect(s.isDownloaded(s.items.firstWhere((m) => m.id == 'a2')), isTrue,
          reason: '同一作品的第二张图也算已下载');
      expect(s.isDownloaded(s.items.firstWhere((m) => m.id == 'b1')), isFalse);
    });

    test('入队只记「在下」，任务全部成功后才进历史，并带上标题/作者', () async {
      final s = DouyinStore();
      s.ingest([post('a1', 'wa', text: '作品文案', user: '某作者')]);

      // 页面那边是 `ledger.markQueued(queuedTasksByAweme(outcomes))`，
      // 元数据由入队结果带进来 —— 这里按同一形状喂。
      await s.ledger.markQueued({
        'wa': (taskIds: ['T1'], title: '作品文案', author: '某作者'),
      });
      expect(s.ledger.records, isEmpty, reason: '还在下，不该出现在「已下载」里');
      expect(s.isDownloaded(s.items.first), isTrue,
          reason: '但在下的作品要拦住重复入队');

      await s.ledger.advance((_) => DouyinTaskState.complete);

      final r = s.ledger.records.single;
      expect(r.awemeId, 'wa');
      expect(r.title, '作品文案');
      expect(r.author, '某作者');
    });

    test('refreshLedgerView 会把通知转发出去（网格角标重画）', () {
      final s = DouyinStore();
      var notified = 0;
      s.addListener(() => notified++);
      s.refreshLedgerView();
      expect(notified, 1);
    });

    test('clear() 只清抓取结果，不动台账', () async {
      final s = DouyinStore();
      s.ingest([post('a1', 'wa')]);
      await s.ledger.markAll(['wa']);

      s.clear();
      expect(s.count, 0);
      expect(s.ledger.contains('wa'), isTrue,
          reason: '清空列表不应该让「已下载」记录消失');
    });
  });

  group('v3：入队只算「在下」，下完才算已下载', () {
    test('markQueued 不进历史，但拦得住重复入队', () async {
      final l = DouyinLedger();
      await l.markQueued({
        'w1': (taskIds: ['T1', 'T2'], title: '标题', author: '作者'),
      });

      expect(l.contains('w1'), isTrue, reason: '在下的作品再点一次会重复提交，得拦住');
      expect(l.count, 1);
      expect(l.doneCount, 0);
      expect(l.records, isEmpty,
          reason: '「已下载（抖音）」里不该看见还没下完的');
    });

    test('只有一部分任务成功 → 原样保持，不提前算已下载', () async {
      final l = DouyinLedger();
      await l.markQueued({
        'w1': (taskIds: ['T1', 'T2'], title: null, author: null),
      });

      final changed = await l.advance(
        (id) =>
            id == 'T1' ? DouyinTaskState.complete : DouyinTaskState.running,
      );

      expect(changed, isFalse);
      expect(l.doneCount, 0);
    });

    test('全部任务成功 → 转已下载并进历史', () async {
      final l = DouyinLedger();
      await l.markQueued({
        'w1': (taskIds: ['T1', 'T2'], title: '标题', author: '作者'),
      });

      expect(await l.advance((_) => DouyinTaskState.complete), isTrue);
      expect(l.doneCount, 1);
      expect(l.records.single.awemeId, 'w1');
      expect(l.records.single.title, '标题');
    });

    test('回归：下载失败的作品不会永久占住「已下载」', () async {
      final l = DouyinLedger();
      await l.markQueued({
        'good': (taskIds: ['T8'], title: null, author: null),
        'bad': (taskIds: ['T9'], title: null, author: null),
      });

      await l.advance(
        (id) => id == 'T9' ? DouyinTaskState.failed : DouyinTaskState.complete,
      );

      expect(l.contains('bad'), isFalse, reason: '撤掉记录，下次刷到同一作品能重试');
      expect(l.doneCount, 1);
      expect(l.records.single.awemeId, 'good');
    });

    test('续上新任务 id 后，被重试删掉的旧任务不再阻碍判定', () async {
      final l = DouyinLedger();
      await l.markQueued({
        'w1': (taskIds: ['T1'], title: null, author: null),
      });
      await l.attachTask('w1', 'T2');

      // T1 已被 store.remove（任务表里查不到），T2 才是这次真正在下的
      await l.advance(
        (id) =>
            id == 'T2' ? DouyinTaskState.complete : DouyinTaskState.unknown,
      );

      expect(l.doneCount, 1);
      expect(l.records.single.awemeId, 'w1');
    });

    test('attachTask 只给已「在下」的作品续 id，不凭空造记录', () async {
      final l = DouyinLedger();
      await l.markAll(['d']);
      await l.attachTask('d', 'T9');
      await l.attachTask('never-queued', 'T9');

      expect(l.count, 1, reason: '已下完的或台账里没有的，都不该被这次提交改写');
      expect(l.records.single.awemeId, 'd');
    });

    test('任务表里查不到时不猜：保持在「在下」', () async {
      final l = DouyinLedger();
      await l.markQueued({
        'w1': (taskIds: ['T1'], title: null, author: null),
      });

      final changed = await l.advance((_) => DouyinTaskState.unknown);

      expect(changed, isFalse);
      expect(l.count, 1);
      expect(l.doneCount, 0);
    });

    test('重试换了任务 id 之后按新的判，旧的失败不再拖累这条作品', () async {
      final l = DouyinLedger();
      await l.markQueued({
        'w1': (taskIds: ['T1'], title: null, author: null),
      });
      await l.advance((_) => DouyinTaskState.failed);
      expect(l.contains('w1'), isFalse);

      await l.markQueued({
        'w1': (taskIds: ['T2'], title: null, author: null),
      });
      expect(await l.advance((_) => DouyinTaskState.complete), isTrue);
      expect(l.doneCount, 1);
    });

    test('落盘往返：pending 与 done 都能原样读回，重启后还推得动', () async {
      final l = DouyinLedger();
      await l.markQueued({
        'p': (taskIds: ['T1', 'T2'], title: '在下', author: '作者A'),
      });
      await l.markAll(['d'], meta: {'d': (title: '已完', author: '作者B')});

      final reopened = DouyinLedger();
      await reopened.load();
      expect(reopened.doneCount, 1);
      expect(reopened.records.single.awemeId, 'd');

      await reopened.advance((_) => DouyinTaskState.complete);
      expect(reopened.doneCount, 2, reason: '任务 id 也落盘了，重启后照样能推进');

      final again = DouyinLedger();
      await again.load();
      expect(again.doneCount, 2);
    });

    test('读入 v2 台账：没有状态字段的记录一律算已下载', () async {
      ledgerFile().writeAsStringSync(jsonEncode({
        'version': 2,
        'items': {
          'w1': {'t': 1, 'text': '老记录', 'user': '老作者'},
          'w2': <String, Object?>{},
        },
      }));

      final l = DouyinLedger();
      await l.load();

      expect(l.count, 2);
      expect(l.doneCount, 2,
          reason: 'v2 那批本来就是「已下载」语义，不能因为升级就作废');
      expect(l.records.map((r) => r.awemeId), containsAll(['w1', 'w2']));
    });

    test('写出去的是 v3，done 不带多余的状态字段', () async {
      final l = DouyinLedger();
      await l.markQueued({
        'p': (taskIds: ['T1'], title: null, author: null),
      });
      await l.markAll(['d']);

      final raw = jsonDecode(ledgerFile().readAsStringSync()) as Map;
      expect(raw['version'], 3);
      final items = raw['items'] as Map;
      expect((items['p'] as Map)['s'], 'pending');
      expect((items['p'] as Map)['f'], ['T1']);
      expect((items['d'] as Map).containsKey('s'), isFalse);
    });
  });
}
