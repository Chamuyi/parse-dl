import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/field_row.dart';
import 'package:parse_dl/widgets/hero_banner.dart';
import 'package:parse_dl/widgets/opt_grid.dart';
import 'package:parse_dl/widgets/page_header.dart';
import 'package:parse_dl/widgets/quick_grid.dart';
import 'package:parse_dl/widgets/section_card.dart';
import 'package:parse_dl/widgets/stat_grid.dart';
import 'package:parse_dl/widgets/status_badge.dart';
import 'package:parse_dl/widgets/sub_section.dart';
import 'package:parse_dl/widgets/switch_row.dart';

/// S9a 预览稿组件层的判据（2026-10-13）。
///
/// 这 10 个组件是 S9b/S9c 全页重排的地基：一旦被改回自创样式（图标方块页头、
/// 3 列统计、2 列快捷卡、两态同色徽章…），要在这里立刻变红，而不是等到真机
/// 截图才发现。每条判据都配过一次「把被测特征改错 → 实测变红 → 改回」的负
/// 控制（过程记录在 S9a 交付说明里）。
///
/// 渲染环境固定 [AppColors.dark] + [Brightness.dark]（与
/// `test/visual_tokens_test.dart` 同一套）：深色是默认落地观感，浅色差异由
/// 色板自身回答，组件不该判风格。
///
/// 两条本仓已知坑：`testWidgets` 体内不做真实异步 I/O；组件测试一律
/// `pump()`（页面级 `pumpAndSettle` 会被持续调度帧挂死）。
void main() {
  /// 把待测组件挂进 `AppTheme` + `MaterialApp` 的最小可渲染环境。
  Future<void> pumpInApp(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(900, 900);
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

  /// 取页面里唯一网格的列数。列数是「预览稿平铺几列」的直接判据，
  /// 比数一行的元素个数稳（元素个数还受 wrap/滚动影响）。
  int crossAxisCountOf(WidgetTester tester) {
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate = grid.gridDelegate;
    expect(delegate, isA<SliverGridDelegateWithFixedCrossAxisCount>());
    return (delegate as SliverGridDelegateWithFixedCrossAxisCount)
        .crossAxisCount;
  }

  /// 某个徽章文案的前景色。
  Color badgeFgOf(WidgetTester tester, String text) {
    final widget = tester.widget<Text>(
      find.descendant(
        of: find.byType(StatusBadge),
        matching: find.text(text),
      ),
    );
    return widget.style!.color!;
  }

  // ── PageHeader ──────────────────────────────────────────────────────────

  testWidgets('PageHeader 渲染标题与副题，且子树内没有任何 Icon', (tester) async {
    await pumpInApp(
      tester,
      const PageHeader(title: '设置', subtitle: '全局与各平台'),
    );

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('全局与各平台'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(PageHeader), matching: find.byType(Icon)),
      findsNothing,
      reason: '页头是纯文字（预览稿 .head），图标方块已被 2026-10-13 真机裁定移除',
    );
  });

  testWidgets('PageHeader.trailing 渲染传入控件', (tester) async {
    await pumpInApp(
      tester,
      const PageHeader(title: '设置', trailing: Text('已登录')),
    );

    expect(
      find.descendant(
        of: find.byType(PageHeader),
        matching: find.text('已登录'),
      ),
      findsOneWidget,
    );
  });

  // ── SwitchRow ───────────────────────────────────────────────────────────

  testWidgets('SwitchRow 点击后 onChanged 收到 true', (tester) async {
    bool? got;
    await pumpInApp(
      tester,
      SwitchRow(
        label: '自动更新',
        subtitle: '启动时检查新版本',
        value: false,
        onChanged: (v) => got = v,
      ),
    );

    expect(got, isNull, reason: '还没点，不该有回调');
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(got, isTrue);
  });

  // ── OptGrid ─────────────────────────────────────────────────────────────

  testWidgets('OptGrid 点格子弹出选择器，选另一项后回调收到 (item, 新值)', (tester) async {
    OptItem<String>? gotItem;
    String? gotValue;
    const items = <OptItem<String>>[
      OptItem<String>(label: '画质上限', value: '1080P', options: ['1080P', '4K']),
      OptItem<String>(label: '编码', value: 'AVC', options: ['AVC', 'HEVC']),
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('4K'), findsOneWidget, reason: '点格子应弹出候选列表');

    await tester.tap(find.text('4K'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(gotValue, '4K');
    expect(gotItem?.label, '画质上限');

    // S9b 修掉了这条缺陷：弹层容器从带底色的 `DecoratedBox` 换成 `Material`
    // （SDK `list_tile.dart` 的 `_debugCheckBackgroundIsHidden` 会拿最近的
    // 有底色祖先判「ListTile 的底色与水波纹被挡」）。原来这里吞掉那个断言并
    // 反向断言「异常必须还在」—— 组件修好后它就会红、提示删掉。现已删除。
    // 下面这条是**新的正向判据**：整个交互链跑完，一帧异常都不许有。
    expect(
      tester.takeException(),
      isNull,
      reason: '弹层已换 Material 容器，ListTile 遮挡断言不该再报',
    );
  });

  // ── StatusBadge ─────────────────────────────────────────────────────────

  testWidgets('StatusBadge 四态前景色两两不同', (tester) async {
    const texts = ['已完成', '运行中', '等待中', '失败'];
    await pumpInApp(
      tester,
      const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusBadge(kind: StatusKind.done, text: '已完成'),
          StatusBadge(kind: StatusKind.run, text: '运行中'),
          StatusBadge(kind: StatusKind.wait, text: '等待中'),
          StatusBadge(kind: StatusKind.err, text: '失败'),
        ],
      ),
    );

    final fgs = texts.map((s) => badgeFgOf(tester, s)).toList();
    for (var i = 0; i < fgs.length; i++) {
      for (var j = i + 1; j < fgs.length; j++) {
        expect(
          fgs[i],
          isNot(fgs[j]),
          reason: '第 ${i + 1} 态（${texts[i]}）与第 ${j + 1} 态（${texts[j]}）'
              '前景色相同 —— 四态必须靠颜色分开',
        );
      }
    }
  });

  testWidgets('StatusBadge 文案原样渲染', (tester) async {
    await pumpInApp(
      tester,
      const StatusBadge(kind: StatusKind.done, text: '已登录'),
    );

    expect(find.text('已登录'), findsOneWidget);
  });

  // ── SectionCard ─────────────────────────────────────────────────────────

  testWidgets('SectionCard 卡头左侧标题与右侧灰字都在', (tester) async {
    await pumpInApp(
      tester,
      const SectionCard(
        title: '下载',
        trailing: '已选 4 / 9',
        child: Text('卡片内容'),
      ),
    );

    expect(find.text('下载'), findsOneWidget);
    expect(find.text('已选 4 / 9'), findsOneWidget);
    expect(find.text('卡片内容'), findsOneWidget);
  });

  // ── SubSection ──────────────────────────────────────────────────────────

  testWidgets('SubSection 传什么显示什么（不做二次翻译）', (tester) async {
    await pumpInApp(
      tester,
      const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SubSection('命名模板'),
          SubSection('Naming template'),
        ],
      ),
    );

    expect(find.text('命名模板'), findsOneWidget);
    expect(find.text('Naming template'), findsOneWidget);
  });

  // ── StatGrid / QuickGrid ────────────────────────────────────────────────

  testWidgets('StatGrid 是 4 列（预览稿 .stats repeat(4,1fr)）', (tester) async {
    await pumpInApp(
      tester,
      const StatGrid(
        cells: [
          StatCell(key: '进行中', value: '2', unit: '个'),
          StatCell(key: '已完成', value: '18', unit: '个', sub: '今天 +3'),
          StatCell(key: '下载台账', value: '24', unit: '条'),
          StatCell(key: '磁盘占用', value: '1.8', unit: 'GB'),
        ],
      ),
    );

    expect(crossAxisCountOf(tester), 4);
  });

  testWidgets('QuickGrid 是 3 列（预览稿 .quick repeat(3,1fr)）', (tester) async {
    await pumpInApp(
      tester,
      QuickGrid(
        cells: [
          for (var i = 0; i < 6; i++)
            QuickCell(
              icon: Icons.play_arrow,
              title: '入口 $i',
              sub: '副题 $i',
            ),
        ],
      ),
    );

    expect(crossAxisCountOf(tester), 3);
  });

  // ── HeroBanner ──────────────────────────────────────────────────────────

  testWidgets('HeroBanner 渲染 badge / title / subtitle / pills', (tester) async {
    await pumpInApp(
      tester,
      // 非 const：`AppColors.dark.success` 是自定义类的字段访问，
      // Dart 的常量求值不接受它出现在 const 表达式里。
      HeroBanner(
        badge: 'X',
        title: '解析下载',
        subtitle: '粘贴链接开始解析',
        pills: [
          HeroPill('已登录', dotColor: AppColors.dark.success),
          HeroPill('v1.0.0'),
        ],
      ),
    );

    expect(find.text('X'), findsOneWidget);
    expect(find.text('解析下载'), findsOneWidget);
    expect(find.text('粘贴链接开始解析'), findsOneWidget);
    expect(find.text('已登录'), findsOneWidget);
    expect(find.text('v1.0.0'), findsOneWidget);
  });

  testWidgets('HeroBanner large 变体走 hero2 档（标题 19）', (tester) async {
    await pumpInApp(
      tester,
      const HeroBanner(
        badge: '解',
        title: '总览',
        subtitle: '统计与快捷入口',
        large: true,
      ),
    );

    final title = tester.widget<Text>(find.text('总览'));
    expect(title.style?.fontSize, 19);
    expect(find.text('解'), findsOneWidget);
  });

  // ── FieldRow ────────────────────────────────────────────────────────────

  testWidgets('FieldRow 按钮点击触发回调', (tester) async {
    var taps = 0;
    await pumpInApp(
      tester,
      FieldRow(
        value: r'C:\Users\me\Downloads',
        buttons: [
          FieldButton('打开', onPressed: () => taps++),
          FieldButton('复制', onPressed: () {}),
        ],
      ),
    );

    expect(taps, 0, reason: '还没点，不该有回调');
    await tester.tap(find.text('打开'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('FieldRow danger 按钮文字色取 c.danger 槽位', (tester) async {
    await pumpInApp(
      tester,
      FieldRow(
        value: '••••••••',
        mono: true,
        prefix: '@',
        buttons: [
          FieldButton('退出登录', danger: true, ghost: true, onPressed: () {}),
        ],
      ),
    );

    final label = tester.widget<Text>(find.text('退出登录'));
    expect(label.style?.color, AppColors.dark.danger);
  });
}
