// 页面保活的回归判据。
//
// 钉住的是真机现象「切走再回来还停在当前页 / 顶部返回箭头点不动」的**代码侧成因**：
// 只要已访问页面的 State 被 dispose，切回来就是全新实例 —— 新实例 `_canBack`
// 初始恒为 false，WebView 也从起始页重新加载。
//
// 为什么不能只测「切回来还在」：IndexedStack 无论怎么排，当前页都在。要检出的是
// **位置漂移导致 element 复用失败**，所以判据是「已活页面有没有被 dispose」。
//
// **假页面必须每个路由一个独立类型**：真实 app 里 `bili` → `BiliPage`、
// `douyin` → `DouyinPage`，位置漂移时新旧类型不同 → element 复用失败 → dispose。
// 若测试里所有路由共用一个类型，Flutter 会把 element 原地改造成新 widget
// （同类型无 key 即可更新），dispose 根本不发生 —— 那样这个测试就是**恒绿**的，
// 检不出任何东西（本轮已实测：共用类型时负控制不变红）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/app.dart';

/// 记录页面 State 的生命周期。判据是 dispose 的有无，不是重建次数。
class _LifeLog {
  final List<String> events = [];
}

/// 可追踪页面的公共外壳 —— 只有 [id] 不同，类型各自独立。
abstract class _Tracked extends StatefulWidget {
  const _Tracked(this.log);
  final _LifeLog log;
  String get id;
}

abstract class _TrackedState<T extends _Tracked> extends State<T> {
  @override
  void initState() {
    super.initState();
    widget.log.events.add('init:${widget.id}');
  }

  @override
  void dispose() {
    widget.log.events.add('dispose:${widget.id}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.id);
}

// 四个路由各一个**独立类型**，与 app.dart 的 _pageFor 一一对应。
class _HomePage extends _Tracked {
  const _HomePage(super.log);
  @override
  String get id => 'home';
  @override
  State<_HomePage> createState() => _HomeState();
}

class _HomeState extends _TrackedState<_HomePage> {}

class _BiliPage extends _Tracked {
  const _BiliPage(super.log);
  @override
  String get id => 'bili';
  @override
  State<_BiliPage> createState() => _BiliState();
}

class _BiliState extends _TrackedState<_BiliPage> {}

class _DouyinPage extends _Tracked {
  const _DouyinPage(super.log);
  @override
  String get id => 'douyin';
  @override
  State<_DouyinPage> createState() => _DouyinState();
}

class _DouyinState extends _TrackedState<_DouyinPage> {}

class _BatchPage extends _Tracked {
  const _BatchPage(super.log);
  @override
  String get id => 'bili-batch';
  @override
  State<_BatchPage> createState() => _BatchState();
}

class _BatchState extends _TrackedState<_BatchPage> {}

/// 路由 → 页面。**类型必须互不相同**（与 app.dart 的 `_pageFor` 同构）。
Widget _pageFor(String id, _LifeLog log) => switch (id) {
      'home' => _HomePage(log),
      'bili' => _BiliPage(log),
      'douyin' => _DouyinPage(log),
      'bili-batch' => _BatchPage(log),
      _ => throw ArgumentError('测试没为 $id 准备页面类型'),
    };

/// 用**生产代码的 `keepAliveStack`** 渲染，不在这里复刻一份算法。
Future<void> _pumpShell(
  WidgetTester tester,
  List<String> visited,
  String current,
  _LifeLog log,
) async {
  final stack = keepAliveStack(visited, current);
  if (stack == null) {
    await tester.pumpWidget(MaterialApp(home: _pageFor(current, log)));
    return;
  }
  await tester.pumpWidget(MaterialApp(
    home: IndexedStack(
      index: stack.index,
      sizing: StackFit.expand,
      children: [for (final id in stack.children) _pageFor(id, log)],
    ),
  ));
}

void main() {
  group('保活栈的顺序', () {
    test('children 就是 visited 本身（首次访问序，append-only）', () {
      final visited = ['home', 'bili', 'douyin'];
      final s = keepAliveStack(visited, 'douyin')!;
      expect(s.children, visited, reason: '顺序被改过 → 位置会漂');
      expect(s.index, 2);
    });

    test('乱序访问：先 B 站后抖音，B 站的位置不许变', () {
      // 清单序是 home,douyin,...,bili —— 若按清单过滤，bili 会从 1 漂到 2。
      final s = keepAliveStack(['home', 'bili', 'douyin'], 'douyin')!;
      expect(s.children.indexOf('bili'), 1,
          reason: 'bili 位置漂了 → IndexedStack 位置匹配失败 → State 被 dispose');
      expect(s.index, 2);
    });

    test('正控制：没访问过的路由不返回栈（退回单页渲染）', () {
      expect(keepAliveStack(['home'], 'bili'), isNull);
    });

    test('负控制：清单外的 id 也返回 null（漏登记时不许整屏空白）', () {
      expect(keepAliveStack(['home', 'bili'], 'bili-nope'), isNull);
    });
  });

  group('真渲染：已访问页面不被 dispose', () {
    testWidgets('先 B 站后抖音，切走 B 站后它仍然活着', (tester) async {
      final log = _LifeLog();
      await _pumpShell(tester, ['home', 'bili'], 'bili', log);
      expect(log.events, contains('init:bili'));
      log.events.clear();

      // 用户去开抖音 —— 这是旧算法下 bili 被 dispose 的那一刻
      await _pumpShell(tester, ['home', 'bili', 'douyin'], 'douyin', log);
      expect(log.events, isNot(contains('dispose:bili')),
          reason: 'bili 被销毁 → 真机上表现为「切回来还停在起始页、返回键点不动」');
      // ignore: avoid_print
      print('切到抖音后的事件: ${log.events}');

      // 切回 B 站：不许重建
      log.events.clear();
      await _pumpShell(tester, ['home', 'bili', 'douyin'], 'bili', log);
      expect(log.events, isNot(contains('init:bili')), reason: '重建了 → 保活没生效');
      expect(log.events, isNot(contains('dispose:bili')));
    });

    testWidgets('多页来回切换：已访问页全程不被销毁', (tester) async {
      final log = _LifeLog();
      final visited = ['home'];
      await _pumpShell(tester, visited, 'home', log);
      for (final id in ['bili', 'douyin', 'bili-batch', 'home', 'douyin', 'bili']) {
        if (!visited.contains(id)) visited.add(id);
        log.events.clear();
        await _pumpShell(tester, visited, id, log);
        final disposes =
            log.events.where((e) => e.startsWith('dispose:')).toList();
        expect(disposes, isEmpty,
            reason: '切到 $id 时销毁了 $disposes —— 保活应全程成立');
      }
    });
  });
}
