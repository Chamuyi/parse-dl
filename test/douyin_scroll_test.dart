import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/douyin_scroll.dart';

/// 抖音页滚轮接管的测试。
///
/// 背景（实测结论，见 evidence/wheel-rootcause.log）：
///   `webview_windows` 的 `SendScroll` 把滚轮注入到客户区 **(0,0)**，
///   而抖音精选页真正能滚的容器 `DIV._bpJj4nI` 不在那个点上 → 一格都滑不动。
/// 所以这里自己接管：按**真实鼠标坐标**找可滚祖先，找不到了再兜底，
/// 并且**不做任何 `×6` 之类的坐标/倍数换算**（插件的换算也是错的）。
void main() {
  group('ScrollAccumulator：多格合并成一次滚动', () {
    test('累加后一次取走，并清零', () {
      final acc = ScrollAccumulator();
      acc.add(0, 53);
      acc.add(0, 53);
      acc.add(0, 53);

      final d = acc.take();
      expect(d.dy, 159);
      expect(d.dx, 0);
      expect(acc.hasPending, isFalse);
    });

    test('take 之后再次 take 是 0（不会重复滚）', () {
      final acc = ScrollAccumulator()..add(0, 100);
      acc.take();

      final again = acc.take();
      expect(again.dy, 0);
      expect(again.dx, 0);
    });

    test('水平与垂直各自独立累加', () {
      final acc = ScrollAccumulator()
        ..add(20, 0)
        ..add(0, 30)
        ..add(-5, 5);

      final d = acc.take();
      expect(d.dx, 15);
      expect(d.dy, 35);
    });

    test('正负方向都要能累加（往上滚是负值）', () {
      final acc = ScrollAccumulator()..add(0, -53);
      expect(acc.take().dy, -53);
    });

    test('clear 丢弃未消费的量', () {
      final acc = ScrollAccumulator()..add(0, 100);
      acc.clear();
      expect(acc.hasPending, isFalse);
      expect(acc.take().dy, 0);
    });

    test('add(0,0) 不算有待处理内容', () {
      final acc = ScrollAccumulator()..add(0, 0);
      expect(acc.hasPending, isFalse);
    });
  });

  group('buildScrollScript：用真实坐标，且不猜倍数', () {
    test('注入的是鼠标真实坐标，不是插件那样的 (0,0)', () {
      final js = buildScrollScript(dx: 0, dy: 100, x: 312, y: 400);

      expect(js, contains('x = 312'));
      expect(js, contains('y = 400'));
      expect(js, contains('elementFromPoint'));
    });

    test('滚动量按 CSS 像素原样使用，**不做 ×6 换算**', () {
      final js = buildScrollScript(dx: 0, dy: 100, x: 10, y: 10);

      expect(js, contains('dy = 100'));
      expect(js, isNot(contains('dy = 600')),
          reason: '插件的 6 倍换算会把一格滚成好几格，正是实测里的错乱来源');
    });

    test('向上遍历祖先找可滚容器，且**不设层数上限**', () {
      final js = buildScrollScript(dx: 0, dy: 100, x: 10, y: 10);

      expect(js, contains('parentElement'));
      expect(js, isNot(contains('depth')));
      expect(js, isNot(contains('i < 8')));
    });

    test('找不到可滚祖先时有兜底：页面上面积最大的可滚容器', () {
      final js = buildScrollScript(dx: 0, dy: 100, x: 10, y: 10);

      expect(js, contains('querySelectorAll'));
      expect(js, contains('getBoundingClientRect'));
    });

    test('最后兜底到 document.scrollingElement（普通网页）', () {
      final js = buildScrollScript(dx: 0, dy: 100, x: 10, y: 10);
      expect(js, contains('scrollingElement'));
    });

    test('水平滚动量也注入进去', () {
      final js = buildScrollScript(dx: -40, dy: 0, x: 10, y: 10);
      expect(js, contains('dx = -40'));
    });

    test('能判断「这个方向还能不能滚」（到底了不该再算命中）', () {
      final js = buildScrollScript(dx: 0, dy: 100, x: 10, y: 10);

      expect(js, contains('scrollHeight'));
      expect(js, contains('scrollTop'));
      expect(js, contains('clientHeight'));
    });

    test('小数被规整（不出现长长的浮点尾巴）', () {
      final js = buildScrollScript(dx: 0, dy: 53.3333333, x: 10, y: 10);
      expect(js, contains('dy = 53.33'));
    });

    test('返回的是可解析的 JSON 字符串（用于日志诊断）', () {
      final js = buildScrollScript(dx: 0, dy: 100, x: 10, y: 10);
      expect(js, contains('JSON.stringify'));
    });
  });

  group('ScrollOutcome：把页面回报的结果解析出来', () {
    test('正常回报：命中容器 + 实际滚动的像素', () {
      final o = ScrollOutcome.decode(
          '{"hit":"DIV._bpJj4nI","before":0,"after":600,"moved":600}');

      expect(o.hit, 'DIV._bpJj4nI');
      expect(o.moved, 600);
      expect(o.effective, isTrue);
      expect(o.error, isNull);
    });

    test('没滚动（moved=0）不算生效 —— 正是修复前的症状', () {
      final o = ScrollOutcome.decode('{"hit":"window","before":0,"after":0,"moved":0}');
      expect(o.effective, isFalse);
    });

    test('外层还套了一层引号的返回值也能解析（executeScript 的行为差异）', () {
      final o = ScrollOutcome.decode(
          '"{\\"hit\\":\\"DIV.x\\",\\"before\\":0,\\"after\\":100,\\"moved\\":100}"');

      expect(o.hit, 'DIV.x');
      expect(o.moved, 100);
    });

    test('页面脚本抛错时带回错误，而不是让 Dart 侧崩掉', () {
      final o = ScrollOutcome.decode('{"ok":false,"error":"boom"}');
      expect(o.error, 'boom');
      expect(o.effective, isFalse);
    });

    test('完全坏的返回值不抛异常', () {
      final o = ScrollOutcome.decode('not json at all');
      expect(o.error, isNotNull);
      expect(o.moved, 0);
    });

    test('空返回值不抛异常', () {
      final o = ScrollOutcome.decode('');
      expect(o.moved, 0);
      expect(o.effective, isFalse);
    });

    test('describe 给出可读的一行，便于写日志', () {
      final o = ScrollOutcome.decode('{"hit":"DIV.x","before":0,"after":120,"moved":120}');
      expect(o.describe, contains('DIV.x'));
      expect(o.describe, contains('120'));
    });
  });
}
