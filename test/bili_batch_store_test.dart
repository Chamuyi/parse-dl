import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_batch_runner.dart';
import 'package:parse_dl/services/bili_batch_store.dart';
import 'package:parse_dl/services/bili_link.dart';

/// 批量页的状态层：只测「有哪些目标 / 每个跑到哪一步 / 汇总怎么说」。
///
/// 页面本体嵌 WebView2，不在 widget 测试里构造（与 `bili_page_test` 同一个理由）；
/// 而跑批的循环需要真接口，也不在这里测 —— 这里钉的是**解析与状态机**，
/// 也就是最容易在界面上「点了没反应」的那一层。
void main() {
  group('一行一个目标：认得出什么', () {
    BiliBatchTarget one(String line) {
      final p = parseBiliTargets(line);
      expect(p.rejected, isEmpty, reason: '「$line」不该被拒：$p');
      return p.targets.single;
    }

    test('UP 主主页链接 → space 目标，mid 从路径来', () {
      final t = one('https://space.bilibili.com/224900/video');
      expect(t.ref.list?.kind, BiliListKind.space);
      expect(t.ref.list?.mid, 224900);
    });

    test('合集与系列链接按 type 分流，不靠猜', () {
      expect(
        one('https://space.bilibili.com/224900/lists/3202069?type=season')
            .ref
            .list
            ?.kind,
        BiliListKind.season,
      );
      expect(
        one('https://space.bilibili.com/224900/lists/3202069?type=series')
            .ref
            .list
            ?.kind,
        BiliListKind.series,
      );
    });

    test('播放页那种只给 sid 的链接 → unknown（要接口才能判）', () {
      final t = one('https://www.bilibili.com/list/224900?sid=3202069');
      expect(t.ref.list?.kind, BiliListKind.unknown);
      expect(t.ref.list?.sid, 3202069);
    });

    test('单条稿件：完整链接、裸 BV、av 号三种写法都收', () {
      for (final line in [
        'https://www.bilibili.com/video/BV1uzas6vEBB',
        'BV1uzas6vEBB',
        'av123456',
      ]) {
        final t = one(line);
        expect(t.ref.list, isNull, reason: '稿件链接不该被当成列表：$line');
        expect(t.ref.bvid != null || t.ref.aid != null, isTrue);
      }
    });

    test('b23.tv 短链先收下，标成待展开', () {
      final t = one('https://b23.tv/abc123');
      expect(t.ref.needsExpand, isTrue);
    });

    test('本期不做的形态进 rejected，不进目标（番剧 / 直播间 / 专栏）', () {
      final p = parseBiliTargets('''
https://www.bilibili.com/bangumi/play/ep123456
https://live.bilibili.com/12345
https://www.bilibili.com/read/cv1234
''');
      expect(p.targets, isEmpty);
      expect(p.rejected, hasLength(3));
    });

    test('正控制：把 BV 号打乱一位就认不出来（不是「什么都算稿件」）', () {
      final p = parseBiliTargets('BV1uzas6vEBO');
      expect(p.targets, isEmpty);
      expect(p.rejected, hasLength(1));
    });

    test('空行与首尾空格忽略；同一个目标写两遍只留一行', () {
      final p = parseBiliTargets('''

  https://space.bilibili.com/224900
https://space.bilibili.com/224900/video

''');
      expect(p.targets, hasLength(1), reason: '同一个主页的两种写法是同一个目标');
    });

    test('同一条稿件既写链接又写 BV 号也只留一行', () {
      final p = parseBiliTargets('''
https://www.bilibili.com/video/BV1uzas6vEBB
BV1uzas6vEBB
''');
      expect(p.targets, hasLength(1));
    });

    test('超出上限的行不排进目标，但**要数出来**', () {
      final text = List.generate(
        BiliBatchStore.kMaxTargets + 7,
        (i) => 'av${100000 + i}',
      ).join('\n');
      final p = parseBiliTargets(text);
      expect(p.targets, hasLength(BiliBatchStore.kMaxTargets));
      expect(p.truncated, 7);
    });
  });

  group('状态机', () {
    test('setRawText 解析一次；运行中不接受改文本', () {
      final s = BiliBatchStore();
      s.setRawText('BV1uzas6vEBB\nBV1pzeH6REr7');
      expect(s.total, 2);
      expect(s.hasTargets, isTrue);

      s.start();
      s.setRawText('BV15ihs6CErg');
      expect(s.total, 2, reason: '跑一半换列表会让下标错位');
      expect(s.current?.input, 'BV1uzas6vEBB');
    });

    test('start 把每个目标重置成等待，并从头开始', () {
      final s = BiliBatchStore();
      s.setRawText('BV1uzas6vEBB\nBV1pzeH6REr7');
      s.mark(s.targets.first, BiliBatchStatus.done);
      s.start();
      expect(s.targets.every((t) => t.status == BiliBatchStatus.waiting), isTrue);
      expect(s.currentIndex, 0);
      expect(s.running, isTrue);
    });

    test('advance 推到下一个；越界之后 current 为空', () {
      final s = BiliBatchStore();
      s.setRawText('BV1uzas6vEBB\nBV1pzeH6REr7');
      s.start();
      s.advance();
      expect(s.currentIndex, 1);
      s.advance();
      expect(s.current, isNull);
    });

    test('stop 只把 running 放下来，循环靠它退出；finish 是收尾那一步', () {
      final s = BiliBatchStore();
      s.setRawText('BV1uzas6vEBB');
      s.start();
      s.stop();
      expect(s.running, isFalse);
      // 正控制：start 之后 running 必须是 true，否则这条 stop 是空断言
      s.start();
      expect(s.running, isTrue);
      s.finish();
      expect(s.running, isFalse);
    });

    test('mark 带上失败原因；reset 把它清掉', () {
      final s = BiliBatchStore();
      s.setRawText('BV1uzas6vEBB');
      final t = s.targets.single;
      s.mark(t, BiliBatchStatus.failed, error: '接口 412');
      expect(t.error, '接口 412');
      s.start();
      expect(t.error, isNull, reason: '重跑一批不能留着上一批的失败原因');
    });

    test('汇总把各目标加起来：认出 / 提交 / 台账跳过 / 不支持', () {
      final s = BiliBatchStore();
      s.setRawText('BV1uzas6vEBB\nBV1pzeH6REr7');
      final a = s.targets.first;
      final b = s.targets.last;
      a.collected = 30;
      a.skippedUnsupported = 2;
      a.truncated = 5;
      a.run = BiliRunTally()
        ..queued = 10
        ..skippedLedger = 4
        ..failed = 1;
      b.collected = 7;
      b.run = BiliRunTally()..queued = 6;
      expect(s.totalCollected, 37);
      expect(s.totalQueued, 16);
      expect(s.totalLedgerSkipped, 4);
      expect(s.totalUnsupported, 2);
      // truncated 是「每个列表自己截掉几条」，界面在那一行上显示，不进全局汇总
      expect(a.truncated, 5);
    });

    test('settledCount 把 done 与 failed 都算进去；allSettled 才有收尾文案', () {
      final s = BiliBatchStore();
      s.setRawText('BV1uzas6vEBB\nBV1pzeH6REr7');
      s.mark(s.targets.first, BiliBatchStatus.done);
      expect(s.settledCount, 1);
      expect(s.allSettled, isFalse);
      s.mark(s.targets.last, BiliBatchStatus.failed);
      expect(s.settledCount, 2);
      expect(s.failedCount, 1);
      expect(s.allSettled, isTrue);
    });

    test('档位与「全部 P」的开关都通知监听者', () {
      final s = BiliBatchStore();
      var hits = 0;
      s.addListener(() => hits++);
      s.setMaxWorks(30);
      s.setAllParts(true);
      expect(s.maxWorks, 30);
      expect(s.allParts, isTrue);
      expect(hits, 2);
      // 正控制：设成同一个值不该再通知
      s.setMaxWorks(30);
      s.setAllParts(true);
      expect(hits, 2);
    });
  });

  group('下载计数的合并', () {
    test('absorb 把四条计数与去重后的原因并进来', () {
      final a = BiliRunTally()
        ..queued = 2
        ..skippedDisk = 1
        ..addNote('要大会员');
      final b = BiliRunTally()
        ..queued = 5
        ..failed = 3
        ..addNote('要大会员')
        ..addNote('412');
      a.absorb(b);
      expect(a.queued, 7);
      expect(a.skippedDisk, 1);
      expect(a.failed, 3);
      expect(a.notes, ['要大会员', '412'], reason: '同一个原因不该在提示里出现两遍');
      expect(a.touched, 11);
    });
  });
}
