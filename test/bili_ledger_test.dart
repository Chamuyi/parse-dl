import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/app_logger.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/bili_ledger.dart';

/// B 站「已下载」台账测试。
///
/// 键组是 `['bili', bvid, cid]`（**不含画质/编码**，理由见 `bili_ledger.dart`
/// 的文件头）：一个稿件多个分 P，跳过与否按分 P 判。
///
/// 测试全部把数据目录指到 `Directory.systemTemp` 下的临时目录，
/// 不碰真实 `userdata`，`tearDown` 只删自己建的那个目录。
void main() {
  late Directory tmp;

  File ledgerFile() =>
      File('${AppPaths.configDir.path}${Platform.pathSeparator}'
          '${BiliLedger.fileName}');

  File tmpFile() => File('${ledgerFile().path}.tmp');

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('bili_ledger_test_');
    await AppPaths.init(exeDirOverride: tmp, fallbackOverride: tmp);
  });

  tearDown(() async {
    // 日志开关是被某个用例打开的话，sink 会占着文件句柄：
    // Windows 上句柄没关就删不掉整个临时目录。
    await AppLogger.dispose();
    await AppLogger.init(enabled: false);
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 正控制用的「磁盘上根本没有这个文件」：台账记的是内容标识，
  /// 下载目录压根不在数据目录里，所以这里断言的是「确实没有」。
  ///
  /// 这里**手搓键组**而不是走 [biliPartKey]，为的是让 `cid` 的真实类型
  /// （int / double / String）原样进到哈希里 —— 先 `.toString()` 就把
  /// 「数字归一化」这条性质测不到了。
  BiliKeyGroup key(String bvid, Object cid) =>
      {'ns': kBiliNamespace, 'bvid': bvid, 'cid': cid};

  group('键组 → hash_id（稳定序列化）', () {
    test('同一个键组乱序插入 map 得到同一个 hash_id', () {
      final a = <String, Object?>{'bvid': 'BV1xx411c7mD', 'cid': '123456', 'ns': 'bili'};
      final b = <String, Object?>{'cid': '123456', 'ns': 'bili', 'bvid': 'BV1xx411c7mD'};
      expect(biliHashId(a), biliHashId(b));
      expect(biliHashId(a), biliHashId(key('BV1xx411c7mD', '123456')));
    });

    test('不同键组得到不同 hash_id（正控制：不是恒等哈希）', () {
      expect(
        biliHashId(key('BV1xx411c7mD', '123456')),
        isNot(biliHashId(key('BV1xx411c7mD', '123457'))),
        reason: '同一稿件的另一个分 P 必须是另一条记录',
      );
      expect(
        biliHashId(key('BV1xx411c7mD', '123456')),
        isNot(biliHashId(key('BV1other', '123456'))),
        reason: '不同稿件的同一个 cid 也不能撞',
      );
      // 少一段 / 多一段都要算出别的东西，否则序列化在偷偷丢字段
      expect(
        biliHashId({'bvid': 'BV1x', 'cid': '1'}),
        isNot(biliHashId(key('BV1x', '1'))),
      );
    });

    test('hash_id 确实是「排序签名串的 md5」（外部算好的向量）', () {
      // 这两个摘要由 Python 的 hashlib 独立算出，签名串就是
      // `{"bvid":"..","cid":"..","ns":"bili"}`（键按字典序、值是字符串、UTF-8）。
      // 不钉这一条的话，「两次算出同一个值」的自洽测试就算哈希函数写错也永远绿。
      expect(biliHashId(key('BV1xx411c7mD', '123456')),
          '77a76c9860a34ddd09e2eceadbee9bf5');
      expect(biliHashId(key('BV1other', '9')),
          'fd853d5c9ea87a8745832f105b273574');
      expect(biliKeySignature(key('BV1other', '9')),
          '{"bvid":"BV1other","cid":"9","ns":"bili"}');
    });

    test('值转字符串：cid 传 int 与传 String 算出同一个 hash_id', () async {
      // 解析端从 JSON 拿到的是 int，从 URL 查询串拿到的是 String，
      // 归一化做不到就会让同一个分 P 有两个键（参照实现踩过）。
      expect(biliHashId(key('BV1x', 12345)), biliHashId(key('BV1x', '12345')));
      expect(biliHashId(key('BV1x', 12345.0)), biliHashId(key('BV1x', '12345')));
      expect(biliHashId(key('BV1x', '  12345 ')), biliHashId(key('BV1x', '12345')),
          reason: '两头空格是解析噪声，不是内容差异');
    });

    test('缺段的键组不可用：bvid 或 cid 为空时不给 hash', () {
      expect(biliKeyGroupUsable(biliPartKey(bvid: 'BV1x', cid: '1')), isTrue);
      expect(biliKeyGroupUsable(biliPartKey(bvid: null, cid: '1')), isFalse);
      expect(biliKeyGroupUsable(biliPartKey(bvid: 'BV1x', cid: '')), isFalse);
      expect(biliKeyGroupUsable(<String, Object?>{}), isFalse);
    });

    test('画质/编码不进键组：同一个分 P 换画质还是同一条记录', () async {
      // 「跳过已下载」判的是内容拿没拿到，不是拿了哪个流。
      final l = BiliLedger();
      await l.markDone([key('BV1x', '100')]);
      expect(l.contains(key('BV1x', '100')), isTrue);
      expect(l.doneCount, 1);
      // 用户口中的「换 1080P 再下一遍」由页面上的开关放行，不由台账记 8 个键
      expect(l.count, 1, reason: '画质变了也不该多出条目');
    });
  });

  group('pending / done 两段式', () {
    test('markPending 只算「在下」：拦得住重复，但不进历史', () async {
      final l = BiliLedger();
      await l.markPending([key('BV1x', '1')], taskIds: {
        biliHashId(key('BV1x', '1')): ['T1']
      });

      expect(l.count, 1);
      expect(l.contains(key('BV1x', '1')), isTrue,
          reason: 'contains 沿用抖音语义：pending 也算「处理过」，否则手快会重复提交');
      expect(l.doneCount, 0);
      expect(l.isDone(key('BV1x', '1')), isFalse);
      expect(l.stateOf(key('BV1x', '1')), BiliLedgerState.pending);
      expect(l.records, isEmpty, reason: '「已下载（B 站）」里不该看见还没下完的');
    });

    test('pending → markDone 才转已下载，并带上标题/UP 主', () async {
      final l = BiliLedger();
      final hash = biliHashId(key('BV1x', '1'));
      await l.markPending([key('BV1x', '1')], taskIds: {hash: ['T1']});

      await l.markDone([key('BV1x', '1')], meta: {
        hash: (title: '教程目录 P1', author: '某UP')
      });

      expect(l.stateOf(key('BV1x', '1')), BiliLedgerState.done);
      final r = l.records.single;
      expect(r.title, '教程目录 P1');
      expect(r.author, '某UP');
      expect(r.hashId, hash);
      expect(r.keyGroup['bvid'], 'BV1x', reason: '历史列表要说得出这是哪一条');
      expect(r.taskIds, isEmpty, reason: '下完了，旧任务 id 留着会被 advance 拿去撤销这条');
    });

    test('重复 markPending / markDone 幂等，不增加计数', () async {
      final l = BiliLedger();
      await l.markPending([key('BV1x', '1')]);
      await l.markPending([key('BV1x', '1')]);
      expect(l.count, 1);
      await l.markDone([key('BV1x', '1'), key('BV1x', '1')]);
      expect(l.count, 1);
      expect(l.doneCount, 1);
    });

    test('已经算已下载的不覆盖时间（历史时间 = 第一次拿到它的时间）', () async {
      final l = BiliLedger();
      await l.markDone([key('BV1x', '1')]);
      final first = l.records.single.at;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await l.markDone([key('BV1x', '1')]);

      expect(l.records.single.at, first);
    });

    test('缺段的键组被跳过，不留脏记录', () async {
      final l = BiliLedger();
      await l.markPending([biliPartKey(bvid: null, cid: '1'), key('BV1x', '1')]);
      await l.markDone([<String, Object?>{}]);

      expect(l.count, 1);
      expect(l.contains(biliPartKey(bvid: null, cid: '1')), isFalse);
    });

    test('变更才发通知（设置页那个计数靠它刷新）', () async {
      final l = BiliLedger();
      var notified = 0;
      l.addListener(() => notified++);

      await l.markPending([key('BV1x', '1')]);
      expect(notified, 1);
      await l.markPending([key('BV1x', '1')]);
      expect(notified, 1, reason: '没有变化不该惊动界面');
      await l.markDone([key('BV1x', '1')]);
      expect(notified, 2);
    });

    test('loaded 默认 false（load() 之前页面要先自查）', () {
      expect(BiliLedger().loaded, isFalse);
    });

    test('按分 P 计数：一个稿件两个 P 是两条记录', () async {
      final l = BiliLedger();
      await l.markDone([key('BV1x', '1'), key('BV1x', '2')]);
      expect(l.doneCount, 2);
      expect(l.isDone(key('BV1x', '1')), isTrue);
      expect(l.isDone(key('BV1x', '3')), isFalse);
    });
  });

  group('advance：按任务的实际结局推进', () {
    test('全部任务成功 → done；任一失败 → 撤掉记录好让下次重试', () async {
      final l = BiliLedger();
      final ok = key('BV1ok', '1');
      final bad = key('BV1bad', '2');
      await l.markPending([ok, bad], taskIds: {
        biliHashId(ok): ['T1', 'T2'],
        biliHashId(bad): ['T3'],
      });

      final changed = await l.advance(
        (id) => id == 'T3' ? BiliTaskState.failed : BiliTaskState.complete,
      );

      expect(changed, isTrue);
      expect(l.contains(bad), isFalse, reason: '没下成功的分 P 不该永久占住「已下载」');
      expect(l.doneCount, 1);
      expect(l.records.single.hashId, biliHashId(ok));
    });

    test('只有一部分任务成功 → 原样保持，不提前算已下载', () async {
      final l = BiliLedger();
      final k = key('BV1x', '1');
      await l.markPending([k], taskIds: {
        biliHashId(k): ['T1', 'T2']
      });

      final changed = await l.advance(
        (id) => id == 'T1' ? BiliTaskState.complete : BiliTaskState.running,
      );

      expect(changed, isFalse);
      expect(l.doneCount, 0);
      expect(l.stateOf(k), BiliLedgerState.pending);
    });

    test('任务表里查不到时不猜：保持在「在下」', () async {
      final l = BiliLedger();
      final k = key('BV1x', '1');
      await l.markPending([k], taskIds: {
        biliHashId(k): ['T1']
      });

      expect(await l.advance((_) => BiliTaskState.unknown), isFalse);
      expect(l.count, 1);
      expect(l.doneCount, 0);
    });

    test('attachTask 只给「在下」的记录续 id，不凭空造记录', () async {
      final l = BiliLedger();
      final k = key('BV1x', '1');
      await l.markPending([k], taskIds: {
        biliHashId(k): ['T1']
      });
      await l.attachTask(biliHashId(k), 'T2');
      await l.attachTask(biliHashId(key('BV1x', '9')), 'T9'); // 台账里没有这条

      final hash = biliHashId(k);
      final items =
          (jsonDecode(ledgerFile().readAsStringSync()) as Map)['items'] as Map;
      expect((items[hash] as Map)['f'], ['T1', 'T2'],
          reason: '续上的任务 id 也得落盘，否则重启后这条又查不到结局');
      expect(l.count, 1);

      // 旧任务被重试删掉（查不到）时，新任务成功就该转 done
      expect(
        await l.advance(
            (id) => id == 'T2' ? BiliTaskState.complete : BiliTaskState.unknown),
        isTrue,
      );
      expect(l.doneCount, 1);
    });
  });

  group('落盘：往返、version、容错', () {
    test('写出去的是带 version 的 v1 结构，读回来还是它', () async {
      final l = BiliLedger();
      await l.markDone([key('BV1x', '1')]);

      final raw = jsonDecode(ledgerFile().readAsStringSync()) as Map;
      expect(raw['version'], BiliLedger.kFormatVersion);
      expect(raw['version'], 1, reason: '起始版本是 B 站侧自己的语义，不撞抖音的 3');

      final b = BiliLedger();
      await b.load();
      expect(b.contains(key('BV1x', '1')), isTrue);
      expect(b.doneCount, 1);

      // 再写一次，version 仍然在（别让某次改动把它写丢）
      await b.markDone([key('BV1x', '2')]);
      expect(
          (jsonDecode(ledgerFile().readAsStringSync()) as Map)['version'], 1);
    });

    test('pending 与 done 都落盘，重新载入后状态一致，而且还推得动', () async {
      final l = BiliLedger();
      final p = key('BV1p', '1');
      final d = key('BV1d', '2');
      await l.markPending([p], taskIds: {
        biliHashId(p): ['T1', 'T2']
      }, meta: {
        biliHashId(p): (title: '在下', author: '作者A')
      });
      await l.markDone([d], meta: {
        biliHashId(d): (title: '已完', author: '作者B')
      });

      final reopened = BiliLedger();
      await reopened.load();

      expect(reopened.count, 2);
      expect(reopened.stateOf(p), BiliLedgerState.pending);
      expect(reopened.stateOf(d), BiliLedgerState.done);
      expect(reopened.records.single.author, '作者B');

      // 任务 id 也落盘了，所以重启后照样能推进（启动时兜底回写 pending 靠这个）
      expect(await reopened.advance((_) => BiliTaskState.complete), isTrue);
      expect(reopened.doneCount, 2);
      expect(reopened.stateOf(p), BiliLedgerState.done);

      final again = BiliLedger();
      await again.load();
      expect(again.doneCount, 2);
      expect((jsonDecode(ledgerFile().readAsStringSync()) as Map)['items'],
          isA<Map>());
    });

    test('done 不落状态字段，pending 才落（文件格式与抖音同习惯）', () async {
      final l = BiliLedger();
      await l.markPending([key('BV1p', '1')], taskIds: {
        biliHashId(key('BV1p', '1')): ['T1']
      });
      await l.markDone([key('BV1d', '2')]);

      final items =
          (jsonDecode(ledgerFile().readAsStringSync()) as Map)['items'] as Map;
      expect((items[biliHashId(key('BV1p', '1'))] as Map)['s'], 'pending');
      expect((items[biliHashId(key('BV1p', '1'))] as Map)['f'], ['T1']);
      expect((items[biliHashId(key('BV1d', '2'))] as Map).containsKey('s'),
          isFalse);
    });

    test('文件不存在 → 空台账，起得来', () async {
      expect(ledgerFile().existsSync(), isFalse);
      final l = BiliLedger();
      await l.load();
      expect(l.count, 0);
      expect(l.loaded, isTrue);
    });

    test('文件被写坏 → 当空台账起、不抛，并把原因写进日志文件', () async {
      // 日志文件由 AppLogger 决定开不开（用户的「记录日志文件」开关）。
      // 这里显式打开，才能验「损坏留了证据」这条要求。
      await AppLogger.init(enabled: true);
      AppPaths.configDir.createSync(recursive: true);
      ledgerFile().writeAsStringSync('{{{ 这不是 JSON');

      final l = BiliLedger();
      await l.load(); // 不该抛

      expect(l.count, 0);
      expect(l.loaded, isTrue);

      await AppLogger.flushForTest();
      final logFile = File(await AppLogger.currentFilePath());
      expect(logFile.existsSync(), isTrue);
      final log = logFile.readAsStringSync();
      expect(log, contains('BILI-LEDGER'));
      expect(log, contains('读不进去'));
      expect(log, isNot(contains('{{{')),
          reason: '日志只记原因，不回抄坏文件的内容');
    });

    test('空文件 / 顶层是数组 / version 不是 1 —— 都按空台账起', () async {
      for (final bad in ['', '[]', '{"version":2,"items":{}}', '{"version":1}']) {
        AppPaths.configDir.createSync(recursive: true);
        ledgerFile().writeAsStringSync(bad);
        final l = BiliLedger();
        await l.load();
        expect(l.count, 0, reason: '$bad 不该被认成台账');
        expect(l.loaded, isTrue);
      }
    });

    test('坏文件原样留着：不删、不改、不自愈', () async {
      AppPaths.configDir.createSync(recursive: true);
      const broken = '{"version":1,"items":'; // 半截 JSON
      ledgerFile().writeAsStringSync(broken);

      final l = BiliLedger();
      await l.load();

      expect(ledgerFile().readAsStringSync(), broken,
          reason: '损坏的台账由用户决定怎么处理，程序不许悄悄清掉');
      expect(tmpFile().existsSync(), isFalse);
    });

    test('单条记录形状不对只丢这一条', () async {
      final hash = biliHashId(key('BV1x', '1'));
      AppPaths.configDir.createSync(recursive: true);
      ledgerFile().writeAsStringSync(jsonEncode({
        'version': 1,
        'items': {
          hash: {'t': 5, 'text': '好记录'},
          'aabb': '不是对象',
          '': {'t': 1},
        },
      }));

      final l = BiliLedger();
      await l.load();
      expect(l.count, 1);
      expect(l.doneCount, 1);
      expect(l.records.single.at, 5);
      expect(l.contains(key('BV1x', '1')), isTrue);
    });
  });

  group('原子写与同进程并发', () {
    test('并发 markDone：最终记录数正确，且文件不是半截 JSON', () async {
      final l = BiliLedger();
      final groups = [for (var i = 0; i < 30; i++) key('BV1x', '$i')];

      // 故意不串行：真实链路里就是「批量入队」和「aria2 完成回调」同时在写。
      await Future.wait([
        for (final g in groups) l.markDone([g]),
      ]);

      expect(l.count, 30);
      final raw = ledgerFile().readAsStringSync();
      final decoded = jsonDecode(raw) as Map; // 半截 JSON 会在这里抛
      expect((decoded['items'] as Map).length, 30);
      expect(tmpFile().existsSync(), isFalse, reason: '改名成功的临时文件不该留下');

      final reopened = BiliLedger();
      await reopened.load();
      expect(reopened.count, 30);
      expect(reopened.doneCount, 30);
    });

    test('并发 pending + done 混合写也不丢记录', () async {
      final l = BiliLedger();
      await Future.wait([
        for (var i = 0; i < 10; i++) l.markPending([key('BV1p', '$i')]),
        for (var i = 0; i < 10; i++) l.markDone([key('BV1d', '$i')]),
      ]);

      expect(l.count, 20);
      expect(l.doneCount, 10);
      final reopened = BiliLedger();
      await reopened.load();
      expect(reopened.count, 20);
      expect(reopened.doneCount, 10);
    });

    test('写坏的旧文件会被下一次原子写盖掉，读回来是完整的', () async {
      AppPaths.configDir.createSync(recursive: true);
      ledgerFile().writeAsStringSync('{{{ 这不是 JSON');

      final l = BiliLedger();
      await l.load();
      await l.markDone([key('BV1x', '1')]);

      expect(jsonDecode(ledgerFile().readAsStringSync()), isA<Map>());
      final reopened = BiliLedger();
      await reopened.load();
      expect(reopened.doneCount, 1);
    });
  });

  group('红线：磁盘上文件还在不在，与台账无关', () {
    test('用户把文件移走后依然跳过', () async {
      // 台账里有一条 done，而它对应的下载文件在磁盘上根本不存在
      // （用户搬走了 / 删掉了）。这恰恰是用户想要的状态：别再下一次。
      final l = BiliLedger();
      await l.markDone([key('BV1moved', '7')], meta: {
        biliHashId(key('BV1moved', '7')): (title: '被我移走了', author: '某UP')
      });

      // 除了台账文件本身，数据目录里没有任何媒体文件 —— 没有任何东西可校验
      final onDisk = AppPaths.configDir
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toList();
      expect(onDisk, [BiliLedger.fileName]);
      expect(File(r'Z:\不存在的下载目录\BV1moved_p7.mp4').existsSync(), isFalse);

      // 重新载入（模拟重启）：还是 done，还是会被跳过
      final reopened = BiliLedger();
      await reopened.load();
      expect(reopened.doneCount, 1);
      expect(reopened.contains(key('BV1moved', '7')), isTrue);
      expect(reopened.stateOf(key('BV1moved', '7')), BiliLedgerState.done);
      expect(await reopened.advance((_) => BiliTaskState.unknown), isFalse,
          reason: 'advance 只看任务表，绝不看媒体文件在不在，所以动不了这条记录');
      expect(reopened.doneCount, 1);
    });

    test('历史误记不自愈：手改过的键组不会按 hash 重算回来', () async {
      // `k` 只是给人看的，判重只认 hash。手改 k 之后这条记录仍然按原 hash 存在 ——
      // 程序不批量修正历史（文件头第 3 条规矩）。
      final hash = biliHashId(key('BV1x', '1'));
      AppPaths.configDir.createSync(recursive: true);
      ledgerFile().writeAsStringSync(jsonEncode({
        'version': 1,
        'items': {
          hash: {
            'k': {'bvid': 'BV1被手改过', 'cid': '9999'},
            't': 7,
          },
        },
      }));

      final l = BiliLedger();
      await l.load();
      expect(l.count, 1);
      expect(l.doneCount, 1);
      expect(l.records.single.hashId, hash);
      expect(l.records.single.keyGroup['bvid'], 'BV1被手改过');
      expect(l.contains(key('BV1被手改过', '9999')), isFalse,
          reason: 'hash 没变，所以这条不会「自愈」成新键组');
    });

    test('drop 是删记录的唯一入口，删了才落盘', () async {
      final l = BiliLedger();
      await l.markDone([key('BV1a', '1'), key('BV1b', '2')]);

      await l.drop([key('BV1a', '1'), key('BV1不存在', '9')]);

      expect(l.contains(key('BV1a', '1')), isFalse);
      expect(l.contains(key('BV1b', '2')), isTrue);

      final reopened = BiliLedger();
      await reopened.load();
      expect(reopened.count, 1);
      expect(reopened.contains(key('BV1a', '1')), isFalse);
    });

    test('clear 返回是否真的落盘，台账清空后重开还是空的', () async {
      final l = BiliLedger();
      await l.markDone([key('BV1x', '1')]);
      expect(await l.clear(), isTrue);
      expect(l.count, 0);

      final reopened = BiliLedger();
      await reopened.load();
      expect(reopened.count, 0);

      var notified = 0;
      reopened.addListener(() => notified++);
      expect(await reopened.clear(), isTrue, reason: '本来就是空的直接成功');
      expect(notified, 0);
    });
  });

  group('条数上限', () {
    test('超过上限丢最旧的（不是按当前列表裁剪）', () async {
      final l = BiliLedger(maxRecords: 3);
      for (var i = 0; i < 4; i++) {
        await l.markDone([key('BV1x', '$i')]);
      }

      expect(l.count, 3);
      expect(l.contains(key('BV1x', '0')), isFalse, reason: '最旧的被丢掉');
      expect(l.contains(key('BV1x', '3')), isTrue);
    });
  });

  group('文件位置', () {
    test('与抖音台账同目录、另一个文件名', () {
      expect(BiliLedger.fileName, 'bili_downloaded.json');
      expect(BiliLedger.fileName, isNot('douyin_downloaded.json'));
      expect(AppPaths.configDir.path, AppPaths.root.path);
    });
  });

  group('台账里没有登录态', () {
    test('落盘内容与记录字段只有内容标识与展示元信息', () async {
      final l = BiliLedger();
      final k = key('BV1x', '1');
      await l.markPending([k], taskIds: {
        biliHashId(k): ['T1']
      }, meta: {
        biliHashId(k): (title: '标题', author: 'UP主')
      });
      await l.markDone([key('BV1y', '2')]);

      final raw = ledgerFile().readAsStringSync();
      for (final forbidden in ['cookie', 'SESSDATA', 'buvid', 'token', 'Dede']) {
        expect(raw.toLowerCase(), isNot(contains(forbidden.toLowerCase())),
            reason: '台账只存内容标识与必要元信息，$forbidden 不许出现在文件里');
      }
      // 正控制：这个断言不是空的，文件里确实有内容
      expect(raw, contains('BV1x'));
    });
  });
}
