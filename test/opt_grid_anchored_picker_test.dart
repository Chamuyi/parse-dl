import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/opt_grid.dart';

/// 贴格选择器的判据（2026-10-15，真机反馈「第三张图点击后，为什么内容是
/// 在最下面弹出来的」）。
///
/// 钉四件事：
///   1. **正判据**：点格子 → 面板从**被点那一格**附近弹出，而不是屏幕最底部；
///   2. **同屏多网格**：锚点必须来自被点的那一格，不能取页面上随便一格；
///   3. 点候选 → 关闭并回传该值（选中链没被改坏）；
///   4. 点遮罩 → 返回 null、浮层收起（取消链没被改坏）；
///   5. 候选超长 → 面板高度受限 + 内部滚动，不溢出屏幕。
///
/// **负控制**（本地验证，不进提交）：把 `showOptPicker` 的定位 top 临时推到
/// 屏幕高度之外（等价于退回 `showModalBottomSheet` 的落位形态），第 1、2、5
/// 条实测全部变红（面板中心距被点格子 1436–1471px）。改回贴格形态后重新
/// 全绿 —— 这几条不是恒真。实现文件里不留任何负控制开关。
/// ──────────────────────────────────────────────────────────────────────

/// 命中选择器本体的 finder：`_optPickerBody` 是 `showOptPicker` 浮层里
/// 那个 list body 的 key（面板必现，且不受候选条数影响）。
final Finder _bodyFinder = find.byKey(const ValueKey('_optPickerBody'));

/// 空回调：只用 OptGrid 的可交互性（有 onChanged 才挂 onTap），不关心结果。
void _ignore(OptItem<String> item, String value) {}

void main() {
  /// 把待测网格挂进 `AppTheme` + `MaterialApp` 的最小可渲染环境。
  ///
  /// 表面取 1280×900：这是 `ui_smoke_test` 的常规档尺寸，格子与浮层的
  /// 距离关系在真机上就是这一档。
  Future<void> pumpInApp(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pump();
  }

  /// 一个 2×2 的 OptGrid：第二格故意放在**下方**（网格高约 140），这样
  /// 「贴格」与「贴屏幕底」两个落位在数值上差得足够远，不会被阈值糊过去。
  Widget buildGrid() {
    const items = <OptItem<String>>[
      OptItem<String>(label: '第一格', value: 'A', options: ['A', 'A2']),
      OptItem<String>(label: '第二格', value: 'B', options: ['B', 'B2', 'B3']),
    ];
    return const OptGrid<String>(items: items, onChanged: _ignore);
  }

  // ── 正判据：浮层贴被点那一格弹出，不是从屏幕最底部上来 ─────────────────

  testWidgets('点格子 → 面板从被点那格附近弹出，而不是屏幕最底部', (tester) async {
    await pumpInApp(tester, buildGrid());

    final cell = tester.getRect(find.text('第二格'));
    await tester.tap(find.text('第二格'));
    await tester.pumpAndSettle();

    expect(
      _bodyFinder,
      findsOneWidget,
      reason: '点格子必须弹出选择器（浮层本体由 _optPickerBody 标识）',
    );

    final panel = tester.getRect(_bodyFinder);
    final screen = tester.getRect(find.byType(MaterialApp));

    // ① 面板顶边贴着格子底边：距离不超过 gap + 一个标题行的高度。
    expect(
      cell.bottom - panel.top,
      lessThan(60),
      reason: '面板顶边应紧接被点格子底边（gap 6 + 标题行约 40），'
          '实测 cell.bottom=${cell.bottom}, panel.top=${panel.top}',
    );

    // ② 面板中心落在格子所在的垂直邻域内（格子高 66，邻域放宽到 200px）。
    expect(
      (panel.center.dy - cell.center.dy).abs(),
      lessThan(200),
      reason: '面板中心应停在格子附近，而不是被甩到屏幕另一端',
    );

    // ③ 反向钉住「不从屏幕最底部上来」：面板绝不允许贴住屏幕底边。
    //    bottom sheet 形态下面板 bottom == screen.bottom，这条必然红。
    expect(
      screen.bottom - panel.bottom,
      greaterThan(24),
      reason: '原缺陷：showModalBottomSheet 让面板从屏幕最底部滑上来 —— '
          '面板底边距屏幕底边仅 ${screen.bottom - panel.bottom}px',
    );

    // ④ 面板不许溢出屏幕（含底部安全边距）。
    expect(panel.bottom, lessThanOrEqualTo(screen.bottom));
    expect(panel.top, greaterThanOrEqualTo(screen.top));
  });

  testWidgets('同屏多个 OptGrid：点第一张网格的第二格，面板贴那一格而不是另一张的',
      (tester) async {
    // 两张网格上下排：第一张在上（y≈0），第二张在下（y≈400+）。
    // 点击**第一张**的第二格，面板必须落在第一张附近；若锚点取错成
    // 第二张的格子，面板会被拉到屏幕下半部分，这条会红。
    const itemsA = <OptItem<String>>[
      OptItem<String>(label: 'A1', value: 'A1', options: ['A1', 'A1b']),
      OptItem<String>(label: 'A2', value: 'A2', options: ['A2', 'A2b']),
    ];
    const itemsB = <OptItem<String>>[
      OptItem<String>(label: 'B1', value: 'B1', options: ['B1', 'B1b']),
      OptItem<String>(label: 'B2', value: 'B2', options: ['B2', 'B2b']),
    ];

    await pumpInApp(
      tester,
      const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OptGrid<String>(items: itemsA, onChanged: _ignore),
          SizedBox(height: 400),
          OptGrid<String>(items: itemsB, onChanged: _ignore),
        ],
      ),
    );

    final cellA2 = tester.getRect(find.text('A2').last);
    final cellB2 = tester.getRect(find.text('B2').last);
    expect(cellB2.top, greaterThan(cellA2.bottom + 300),
        reason: '前置条件：两张网格必须隔得足够开，否则这条判据分不出锚点对错');

    // 点格子里的**当前值**（.last = 值行那一个 Text，键名行那个是灰色小字）。
    await tester.tap(find.text('A2').last);
    await tester.pumpAndSettle();
    expect(_bodyFinder, findsOneWidget);

    final panel = tester.getRect(_bodyFinder);
    expect(
      (panel.center.dy - cellA2.center.dy).abs(),
      lessThan(200),
      reason: '面板应贴第一张网格的 A2；若锚点错取 B2，'
          '面板中心与 A2 相距 ${panel.center.dy - cellA2.center.dy}px',
    );
  });

  // ── 回归：选中 / 取消两条原有交互链 ──────────────────────────────────

  testWidgets('点候选 → 弹层关闭并回传该值（onChanged 收到新值）', (tester) async {
    OptItem<String>? gotItem;
    String? gotValue;
    const items = <OptItem<String>>[
      OptItem<String>(label: '画质上限', value: '1080P', options: ['1080P', '4K']),
    ];

    await pumpInApp(
      tester,
      OptGrid<String>(
        items: items,
        onChanged: (item, value) {
          gotItem = item;
          gotValue = value;
        },
      ),
    );

    await tester.tap(find.text('1080P'));
    await tester.pumpAndSettle();
    expect(find.text('4K'), findsOneWidget, reason: '候选应出现在浮层里');

    await tester.tap(find.text('4K'));
    await tester.pumpAndSettle();

    expect(gotValue, '4K');
    expect(gotItem?.label, '画质上限');
    expect(find.text('4K'), findsNothing, reason: '选完浮层要收起来，不许挂在屏上');
  });

  testWidgets('点遮罩 → 返回 null，值不变（不改任何东西）', (tester) async {
    String? gotValue;
    const items = <OptItem<String>>[
      OptItem<String>(label: '画质上限', value: '1080P', options: ['1080P', '4K']),
    ];

    await pumpInApp(
      tester,
      OptGrid<String>(
        items: items,
        onChanged: (_, value) => gotValue = value,
      ),
    );

    await tester.tap(find.text('1080P'));
    await tester.pumpAndSettle();
    expect(find.text('4K'), findsOneWidget);

    // 点浮层以外的区域（遮罩）：tester.tapAt 直接打坐标，避开浮层本体。
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    expect(gotValue, isNull, reason: '点遮罩是「取消」，不该改任何值');
    expect(find.text('4K'), findsNothing, reason: '点遮罩必须关掉浮层');
  });

  testWidgets('候选很长时面板自身可滚，且不溢出屏幕', (tester) async {
    // 30 条候选：远超一屏可用高度，面板必须内部滚动 + 高度受限。
    const longOptions = <String>[
      '候选一号', '候选二号', '候选三号', '候选四号', '候选五号',
      '候选六号', '候选七号', '候选八号', '候选九号', '候选十号',
      '候选十一号', '候选十二号', '候选十三号', '候选十四号', '候选十五号',
      '候选十六号', '候选十七号', '候选十八号', '候选十九号', '候选二十号',
      '候选二十一号', '候选二十二', '候选二十三', '候选二十四', '候选二十五',
      '候选二十六', '候选二十七', '候选二十八', '候选二十九', '候选三十',
    ];
    const items = <OptItem<String>>[
      OptItem<String>(label: '长列表', value: '候选一', options: longOptions),
    ];

    await pumpInApp(tester, const OptGrid<String>(items: items, onChanged: _ignore));

    final cell = tester.getRect(find.text('长列表'));
    await tester.tap(find.text('长列表'));
    await tester.pumpAndSettle();

    final panel = tester.getRect(_bodyFinder);
    final screen = tester.getRect(find.byType(MaterialApp));

    expect(
      panel.bottom,
      lessThanOrEqualTo(screen.bottom),
      reason: '超长候选列表也不许把面板顶出屏幕（面板 maxHeight 生效）',
    );
    expect(
      panel.bottom - cell.top,
      lessThan(900),
      reason: '面板高度必须受限：cell.top=${cell.top}, panel.bottom=${panel.bottom}',
    );
    // 面板内部出现滚动视图（内容装不下时内部滚）。
    expect(
      find.descendant(of: _bodyFinder, matching: find.byType(Scrollable)),
      findsWidgets,
      reason: '列表超长时面板内部应可滚，而不是撑破屏幕',
    );
  });
}
