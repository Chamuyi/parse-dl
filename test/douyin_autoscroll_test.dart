import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/douyin_auto_store.dart';
import 'package:parse_dl/services/douyin_scroll.dart';

/// 自动滚动加载更多（对齐参照实现的「自动加载」）的状态机测试。
///
/// 这一块的**风险不在滚动本身，而在什么时候停**：
/// 停不下来会一直发请求（限流 / 验证码），太早停又抓不满。
/// 所以把决策逻辑抽成纯状态机，用测试把停止条件钉死。
void main() {
  group('DouyinAutoScroller：停止条件', () {
    test('start 之后处于运行态，stop 之后不再运行', () {
      final a = DouyinAutoScroller();
      expect(a.running, isFalse);

      a.start();
      expect(a.running, isTrue);
      expect(a.stopReason, isNull);

      a.stop();
      expect(a.running, isFalse);
      expect(a.stopReason, AutoScrollStopReason.stopped);
    });

    test('内容一直在长 → 一直继续，直到到达轮次上限', () {
      final a = DouyinAutoScroller(maxRounds: 5)..start();

      var height = 1000.0;
      for (var i = 0; i < 10; i++) {
        final more = a.onRoundResult(height);
        if (!more) break;
        height += 500;
      }

      expect(a.rounds, 5);
      expect(a.running, isFalse);
      expect(a.stopReason, AutoScrollStopReason.reachedMaxRounds);
    });

    test('连续几轮不增长 → 判定到底了，自动停', () {
      final a = DouyinAutoScroller(maxRounds: 50, stallLimit: 3)..start();

      // 第 1 轮建立基准高度
      expect(a.onRoundResult(2000), isTrue);
      // 之后三轮都没有增长
      expect(a.onRoundResult(2000), isTrue);
      expect(a.onRoundResult(2000), isTrue);
      expect(a.onRoundResult(2000), isFalse);

      expect(a.running, isFalse);
      expect(a.stopReason, AutoScrollStopReason.noGrowth);
    });

    test('中途又长高了，停滞计数会重置（不能一次没长就判死）', () {
      final a = DouyinAutoScroller(maxRounds: 50, stallLimit: 3)..start();

      a.onRoundResult(1000);
      a.onRoundResult(1000);
      a.onRoundResult(1000); // 已经停滞 2 次
      expect(a.onRoundResult(1800), isTrue, reason: '长高了就该继续');

      expect(a.stalls, 0);
      // 再确认还能继续跑
      expect(a.onRoundResult(1800), isTrue);
      expect(a.running, isTrue);
    });

    test('高度只有极小的抖动（1px 内）仍算停滞', () {
      final a = DouyinAutoScroller(maxRounds: 50, stallLimit: 2)..start();

      a.onRoundResult(1000);
      a.onRoundResult(1000.4);
      expect(a.onRoundResult(1000.8), isFalse);
      expect(a.stopReason, AutoScrollStopReason.noGrowth);
    });

    test('停掉之后再来结果也不会计数', () {
      final a = DouyinAutoScroller(maxRounds: 3)..start();
      a.stop();
      final before = a.rounds;

      expect(a.onRoundResult(9999), isFalse);
      expect(a.rounds, before);
    });

    test('出错时也能停（页面脚本抛异常 / WebView 没了）', () {
      final a = DouyinAutoScroller()..start();
      a.stop(AutoScrollStopReason.error);
      expect(a.stopReason, AutoScrollStopReason.error);
      expect(a.running, isFalse);
    });

    test('默认容忍 6 轮无增长 —— 翻页慢时不该误判到底', () {
      // 作者主页翻下一页要发一次游标请求，网稍慢就超过 2 秒。原来 3 轮
      // （2.1 秒）会把「还在加载」误判成「到底了」，表现是作品多的号
      // 只抓到前几十条。误判到底的代价远大于多等几轮。
      final a = DouyinAutoScroller(maxRounds: 200)..start();
      a.onRoundResult(5000); // 第一轮确实长高了，之后高度不再变
      for (var i = 0; i < 5; i++) {
        expect(
          a.onRoundResult(5000),
          isTrue,
          reason: '第 ${i + 2} 轮还没到容忍度，应当继续',
        );
      }
      expect(a.running, isTrue);
      expect(a.onRoundResult(5000), isFalse);
      expect(a.stopReason, AutoScrollStopReason.noGrowth);
    });

    test('默认轮数 20，界面档位最高给到 100（约 1800 条作品）', () {
      expect(DouyinAutoScroller().maxRounds, 20);
      expect(DouyinAutoStore.kRoundChoices.last, 100);
    });

    test('重复 start 不会重置进度（防手抖连点）', () {
      final a = DouyinAutoScroller(maxRounds: 10)..start();
      a.onRoundResult(1000);
      a.onRoundResult(2000);
      expect(a.rounds, 2);

      a.start();
      expect(a.rounds, 2);
    });

    test('start 会清掉上一次的停止原因', () {
      final a = DouyinAutoScroller(maxRounds: 1)..start();
      a.onRoundResult(1000); // 到达轮次上限，自动停
      expect(a.stopReason, isNotNull);

      a.start();
      expect(a.stopReason, isNull);
      expect(a.running, isTrue);
    });

    test('describe 给出可读摘要（界面上的「已滚 N 次」）', () {
      final a = DouyinAutoScroller(maxRounds: 4)..start();
      a.onRoundResult(1000);
      a.onRoundResult(2000);

      expect(a.describe, contains('2'));
    });
  });

  group('buildAutoScrollScript：滚到可滚容器底部触发加载', () {
    test('直接滚到底（scrollHeight）', () {
      final js = buildAutoScrollScript();
      expect(js, contains('scrollHeight'));
    });

    test('优先找页面里面积最大的可滚容器（抖音精选就是这种结构）', () {
      final js = buildAutoScrollScript();
      expect(js, contains('querySelectorAll'));
      expect(js, contains('getBoundingClientRect'));
    });

    test('找不到容器时退回文档本身', () {
      final js = buildAutoScrollScript();
      expect(js, contains('scrollingElement'));
    });

    test('回报 scrollHeight 供状态机判断有没有新内容', () {
      final js = buildAutoScrollScript();
      expect(js, contains('JSON.stringify'));
    });
  });

  group('AutoScrollReport：解析页面回报', () {
    test('正常回报', () {
      final r = AutoScrollReport.decode(
          '{"ok":true,"hit":"DIV.x","scrollHeight":4340,"moved":600}');
      expect(r.scrollHeight, 4340);
      expect(r.moved, 600);
      expect(r.error, isNull);
    });

    test('坏数据不崩', () {
      final r = AutoScrollReport.decode('nonsense');
      expect(r.scrollHeight, 0);
      expect(r.error, isNotNull);
    });

    test('空回报不崩', () {
      final r = AutoScrollReport.decode(null);
      expect(r.scrollHeight, 0);
    });
  });
}
