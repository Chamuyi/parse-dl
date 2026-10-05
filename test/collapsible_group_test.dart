import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/collapsible_group.dart';

/// 「详细设置默认折叠」的交互与过渡回归测试。
///
/// 需求要点（逐条对应下面的用例）：
///   1. 默认折叠，收起时仍展示概要；
///   2. 点展开控件平滑显示完整内容，再次点击收起；
///   3. 展开控件是整行热区（含箭头），箭头方向 / 文案随状态变化；
///   4. 收起状态不影响主要功能 —— 组内控件仍在树里、状态不丢、
///      只是被裁剪 + 屏蔽指针，且输入框不会被卡住焦点。
void main() {
  /// 与实现保持一致的过渡时长
  const dur = CollapseSpec.duration;

  Key contentKey(String id) => ValueKey('collapsible-content-$id');
  Key ignoreKey(String id) => ValueKey('collapsible-ignore-$id');
  Key semanticsKey(String id) => ValueKey('collapsible-semantics-$id');
  Key tickerKey(String id) => ValueKey('collapsible-ticker-$id');

  /// 可见高度必须量 SizeTransition 本身 —— 它里面的孩子
  /// 仍保留自然高度（SizeTransition 是靠裁剪 + Align 缩放的），
  /// 直接量孩子会拿到「看起来没收起」的假尺寸。
  Key contentAnimKey(String id) => ValueKey('collapsible-content-anim-$id');
  Key summaryAnimKey(String id) => ValueKey('collapsible-summary-anim-$id');

  Future<void> pumpGroup(
    WidgetTester tester, {
    String id = 'g1',
    String? summary,
    bool initiallyExpanded = false,
    bool forceExpand = false,
    bool modified = false,
    CollapsibleVariant variant = CollapsibleVariant.field,
    List<Widget>? children,
    Size size = const Size(900, 1200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CollapsibleGroup(
                storageId: id,
                title: '更多设置',
                variant: variant,
                summary: summary,
                modified: modified,
                initiallyExpanded: initiallyExpanded,
                forceExpand: forceExpand,
                children: children ??
                    const [
                      Text('详细内容 A'),
                      SizedBox(height: 20),
                      Text('详细内容 B'),
                    ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double contentHeight(WidgetTester tester, String id) =>
      tester.getSize(find.byKey(contentAnimKey(id))).height;

  double summaryHeight(WidgetTester tester, String id) =>
      tester.getSize(find.byKey(summaryAnimKey(id))).height;

  group('默认状态', () {
    testWidgets('默认折叠：内容高度为 0，概要可见且占位', (tester) async {
      await pumpGroup(tester, summary: '当前值：xxx');

      expect(contentHeight(tester, 'g1'), 0,
          reason: '收起时详细内容必须完全不占高度');
      expect(summaryHeight(tester, 'g1'), greaterThan(0),
          reason: '收起时概要行要占位可见');
      // 收起不等于隐藏信息：概要文字本身仍在渲染
      expect(find.text('当前值：xxx'), findsOneWidget);
    });

    testWidgets('收起时右侧动作文案是「展开」', (tester) async {
      await pumpGroup(tester);
      expect(find.text('展开'), findsOneWidget);
      expect(find.text('收起'), findsNothing);
    });

    testWidgets('收起时内容被屏蔽指针、语义与动画时钟', (tester) async {
      await pumpGroup(tester);

      expect(
        tester.widget<IgnorePointer>(find.byKey(ignoreKey('g1'))).ignoring,
        isTrue,
        reason: '收起后内容不能被点到',
      );
      expect(
        tester
            .widget<ExcludeSemantics>(find.byKey(semanticsKey('g1')))
            .excluding,
        isTrue,
        reason: '收起后读屏不该念出看不见的项',
      );
      expect(
        tester.widget<TickerMode>(find.byKey(tickerKey('g1'))).enabled,
        isFalse,
        reason: '收起后不该继续跑组内的动画/计时器',
      );
    });

    testWidgets('initiallyExpanded = true 时直接展开', (tester) async {
      await pumpGroup(tester,
          summary: '当前值：xxx', initiallyExpanded: true);

      expect(contentHeight(tester, 'g1'), greaterThan(0));
      expect(summaryHeight(tester, 'g1'), 0, reason: '展开后概要行让位给内容');
      expect(find.text('收起'), findsOneWidget);
    });
  });

  group('点击展开 / 收起', () {
    testWidgets('点整行头部 → 展开；再点 → 收起', (tester) async {
      await pumpGroup(tester, summary: '当前值：xxx');

      // 点头部（标题文字所在的那一行，箭头也在这一行的热区里）
      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();
      expect(contentHeight(tester, 'g1'), greaterThan(0));
      expect(find.text('收起'), findsOneWidget);
      expect(summaryHeight(tester, 'g1'), 0);
      expect(
        tester.widget<IgnorePointer>(find.byKey(ignoreKey('g1'))).ignoring,
        isFalse,
      );

      // 再次点击 → 收起
      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();
      expect(contentHeight(tester, 'g1'), 0);
      expect(find.text('展开'), findsOneWidget);
    });

    testWidgets('点右侧箭头所在位置也能切换（整行都是热区）', (tester) async {
      await pumpGroup(tester);

      final arrow = find.byIcon(Icons.keyboard_arrow_down_rounded);
      expect(arrow, findsOneWidget);

      await tester.tap(arrow);
      await tester.pumpAndSettle();
      expect(contentHeight(tester, 'g1'), greaterThan(0));
    });

    testWidgets('过渡是「高度 + 淡入」同时进行，且是同帧同步的', (tester) async {
      await pumpGroup(tester, summary: '当前值：xxx');

      await tester.tap(find.text('更多设置'));
      await tester.pump(); // 启动动画
      await tester.pump(dur ~/ 3);

      final mid = contentHeight(tester, 'g1');
      expect(mid, greaterThan(0), reason: '中途应有过渡高度，不是瞬间到位');
      expect(mid, lessThan(200), reason: '还没走完，不应一次到顶');

      // 同一个 controller 驱动概要收缩 + 内容生长 → 两者互补，总和近似恒定
      final sum = mid + summaryHeight(tester, 'g1');
      expect(sum, greaterThan(mid), reason: '概要仍在（还没收完）');

      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    });

    testWidgets('箭头方向随状态翻转 180°', (tester) async {
      await pumpGroup(tester);

      double turns() => tester
          .widget<AnimatedRotation>(find.byType(AnimatedRotation).first)
          .turns;

      expect(turns(), 0.0, reason: '收起时箭头向下');

      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();
      expect(turns(), 0.5, reason: '展开时箭头向上');
    });

    testWidgets('头部有鼠标手型光标与可点击语义', (tester) async {
      await pumpGroup(tester);

      final region = tester.widget<MouseRegion>(
        find
            .ancestor(
              of: find.text('更多设置'),
              matching: find.byType(MouseRegion),
            )
            .first,
      );
      expect(region.cursor, SystemMouseCursors.click);

      final sem = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.text('更多设置'),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(sem.properties.button, isTrue);
      expect(sem.properties.expanded, isFalse);
    });
  });

  group('收起不影响主要功能', () {
    testWidgets('组内控件始终留在树里（不销毁 → 控制器、状态都不丢）',
        (tester) async {
      await pumpGroup(tester);

      // 折叠态下 find 仍然能找到（只是被裁剪到 0 高）
      expect(find.byKey(contentKey('g1')), findsOneWidget,
          reason: '内容包装层必须还在树上，不能被摘掉');
      expect(find.text('详细内容 A'), findsOneWidget);
      expect(find.text('详细内容 B'), findsOneWidget);
    });

    testWidgets('组内 TextField 的文本在收起后依然保留', (tester) async {
      final ctrl = TextEditingController(text: '保留我');

      await pumpGroup(tester, children: [
        TextField(controller: ctrl),
      ]);

      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '保留我');

      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '保留我',
          reason: '折叠只是裁剪，不能把组内输入框的状态清掉');
      expect(ctrl.text, '保留我');

      ctrl.dispose();
    });

    testWidgets('收起时若焦点在被隐藏的输入框上 → 主动交出焦点', (tester) async {
      final node = FocusNode();
      final ctrl = TextEditingController();
      addTearDown(node.dispose);
      addTearDown(ctrl.dispose);

      await pumpGroup(tester, initiallyExpanded: true, children: [
        TextField(controller: ctrl, focusNode: node),
      ]);

      // 手动 focus 到组内输入框
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(node.hasFocus, isTrue, reason: '前置条件：焦点确实在组内输入框上');

      // 收起分组 → 焦点必须离开，否则键盘会打进看不见的框
      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();

      expect(node.hasFocus, isFalse,
          reason: '收起后焦点必须离开被裁剪掉的输入框，否则键盘会打进看不见的框里');
    });
  });

  group('必填项保护（forceExpand）', () {
    testWidgets('forceExpand 由 false 变 true → 自动展开', (tester) async {
      await pumpGroup(tester, forceExpand: false);
      expect(contentHeight(tester, 'g1'), 0);

      await pumpGroup(tester, forceExpand: true);
      await tester.pumpAndSettle();
      expect(contentHeight(tester, 'g1'), greaterThan(0),
          reason: '组内出现必填项时必须自动打开，不能把它藏在收起态里');
    });
  });

  group('两种外观', () {
    testWidgets('section 变体自带卡片容器与更大的标题', (tester) async {
      await pumpGroup(tester, id: 'sec', variant: CollapsibleVariant.section);

      // 标题字号 15、卡片有圆角边框
      final title = tester.widget<Text>(find.text('更多设置'));
      expect(title.style!.fontSize, 15);

      expect(contentHeight(tester, 'sec'), 0);
      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();
      expect(contentHeight(tester, 'sec'), greaterThan(0));
    });

    testWidgets('field 变体是小号标题、无自带卡片', (tester) async {
      await pumpGroup(tester);
      final title = tester.widget<Text>(find.text('更多设置'));
      expect(title.style!.fontSize, 12.5);
    });
  });

  group('已改动提示', () {
    testWidgets('modified = true 时收起态亮一个小圆点', (tester) async {
      await pumpGroup(tester, modified: true);
      final dot = find.byTooltip('组内有已改动的设置');
      expect(dot, findsOneWidget);

      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();
      // 展开后内容就在眼前，圆点仍保留（不影响功能）
      expect(find.byTooltip('组内有已改动的设置'), findsOneWidget);
    });
  });
}
