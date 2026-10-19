// 启动落地页参数（`--page=<id>`）的回归判据。
//
// 存在理由：真机截图必须先停在目标页，而自动化点击走不通（Flutter 走原始
// 输入通道，WM_LBUTTONDOWN 不认）。有了这个参数，截图脚本可以纯后台跑：
// 启动即落地 → PrintWindow 截图 → 全程不激活窗口。
//
// 两条判据链，各自带负控制：
//   ① launchRouteFrom —— 参数解析的接受/拒绝边界；
//   ② launchStack    —— 初值联动（当前页 + 已访问列表必须一起改）。
//      这条才是真机保活不失效的前提，只测①测不出来。
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/app.dart';
import 'package:parse_dl/main.dart';

void main() {
  group('launchRouteFrom（参数解析）', () {
    test('接受 --page=settings', () {
      expect(launchRouteFrom(['--page=settings'], kAppRoutes), 'settings');
    });

    test('接受 --page settings（空格分隔）', () {
      expect(launchRouteFrom(['--page', 'settings'], kAppRoutes), 'settings');
    });

    test('无参数时回落到 null（默认落地页）', () {
      expect(launchRouteFrom(<String>[], kAppRoutes), isNull);
    });

    test('与其他参数混排时仍能取到', () {
      expect(
        launchRouteFrom(['--verbose', '--page=bili-batch', '--x'], kAppRoutes),
        'bili-batch',
      );
    });

    // 负控制：未知 id 必须被拒。若实现只取参数、不校验清单，
    // 这条会拿到 'nope' 并判红 —— 证明校验确实在起作用。
    test('负控制：未知 id 被拒', () {
      expect(launchRouteFrom(['--page=nope'], kAppRoutes), isNull);
    });

    // 负控制：--page 在末尾且没有值，不能越界、也不该抛错。
    test('负控制：--page 缺值时被拒', () {
      expect(launchRouteFrom(['--page'], kAppRoutes), isNull);
    });

    test('空值被拒', () {
      expect(launchRouteFrom(['--page='], kAppRoutes), isNull);
    });
  });

  group('launchStack（初值联动）', () {
    List<String> defaults() => ['dashboard'];

    test('指定 settings 时当前页跟着变', () {
      final s = launchStack('settings', 'dashboard', defaults());
      expect(s.route, 'settings');
    });

    test('指定 settings 时它同时进入已访问列表', () {
      // 这条是保活的前提：漏了它首帧 keepAliveStack 返回 null。
      final s = launchStack('settings', 'dashboard', defaults());
      expect(s.visited, contains('settings'));
    });

    // 真机语义判据：算出的 (当前页, 已访问) 必须真的能走保活路径。
    // 直接调 keepAliveStack —— 与 app.dart build 里用的同一个函数。
    test('算出的初值真能走保活路径（不是单页退化）', () {
      final s = launchStack('settings', 'dashboard', defaults());
      final stack = keepAliveStack(s.visited, s.route);
      expect(stack, isNotNull);
      expect(stack!.index, s.visited.indexOf('settings'));
    });

    // 负控制：不传参数时必须还是默认落地页，且列表原样。
    // 若 launchStack 无条件改路由，这条会判红。
    test('负控制：不传时仍是 dashboard，列表不变', () {
      final s = launchStack(null, 'dashboard', defaults());
      expect(s.route, 'dashboard');
      expect(s.visited, ['dashboard']);
    });

    // 负控制：非法 id 不得改变任何东西。
    test('负控制：非法 id 被忽略', () {
      final s = launchStack('nope', 'dashboard', defaults());
      expect(s.route, 'dashboard');
      expect(s.visited, ['dashboard']);
    });

    test('目标就是默认落地页时不重复插入', () {
      final s = launchStack('dashboard', 'dashboard', defaults());
      expect(s.visited, ['dashboard']);
    });

    test('目标已在列表里时不重复插入', () {
      final s = launchStack('settings', 'dashboard', ['dashboard', 'settings']);
      expect(s.visited.where((e) => e == 'settings').length, 1);
    });

    test('不修改传入的列表（避免共享可变状态）', () {
      final d = defaults();
      launchStack('settings', 'dashboard', d);
      expect(d, ['dashboard']);
    });
  });
}
