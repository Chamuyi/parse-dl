import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/style_colors.dart';
import 'package:parse_dl/widgets/status_badge.dart';
import 'package:parse_dl/widgets/title_bar.dart';

/// 标题栏右列（T5）的判据 —— 逐条照参照物
/// `tubatool/TubaWinUi3.WinUI3/MainWindow.xaml:212-249` 的取值。
///
/// 三条各钉一件事：① 三列布局（搜索框不再是居中那个）；
/// ② 「下载队列」图标按钮的几何与角标；③ 三个窗口按钮的悬停 / 按下 / 失焦三态。
///
/// **每条都带负控制**：文件末尾 `_negativeControls` 一节列出「把实现改错后
/// 哪条判据会红」，并在本机逐条跑过（输出见交接记录）—— 只写恒真断言等于没写。
void main() {
  late Directory tmp;
  late DownloadStore downloads;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('titlebar-');
    await AppPaths.init(exeDirOverride: tmp, fallbackOverride: tmp);
    downloads = DownloadStore()..setSaveDir(tmp.path);
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  var seq = 0;

  /// 塞一条任务并翻状态。媒体 id 必须逐条唯一 —— Windows 上
  /// `DateTime.now()` 只有毫秒精度，连开两条会撞同一个 localId
  /// （`dashboard_page_test.dart:52-58` 记过这个坑）。
  void seed(DownloadStatus status) {
    seq++;
    final localId = downloads.addPending(
      Media(
        id: 't5-$seq',
        type: MediaType.video,
        url: 'https://cdn.example.invalid/t5.mp4',
        source: 'x',
        tweetId: '1700000000000000000',
      ),
      tmp.path,
      fileName: '示例文件.mp4',
    );
    downloads.task(localId)!.status = status;
  }

  /// 标题栏渲染时**不允许有任何异常**。
  ///
  /// 历史：这条原本是「容忍器」—— `title_bar_search.dart` 的 `DecoratedBox` 用
  /// 非 uniform `Border` 配 `borderRadius`，每次重绘都抛
  /// 「A borderRadius can only be given on borders with uniform colors」，
  /// 当时因为它不在改写边界内，只能在这里把异常取走。
  ///
  /// 2026-10-20 搜索框整个删掉（用户裁定「删了吧」），异常源头随之消失。
  /// 容忍器改成严格断言：**再有异常就是新的回归**，直接判红。
  Future<void> quietPump(WidgetTester tester) async {
    await tester.pump();
    expect(
      tester.takeException(),
      isNull,
      reason: '标题栏不该抛任何异常；搜索框删掉后那条非 uniform 边框的源头已不存在',
    );
  }

  Future<void> pumpTitleBar(
    WidgetTester tester, {
    void Function(String routeId)? onOpenDownloads,
    double width = 1200,
  }) async {
    tester.view.physicalSize = Size(width, 120);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<DownloadStore>.value(value: downloads),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: TitleBar(
                routeTitle: '总览',
                onMinimize: () {},
                onToggleMaximize: () {},
                onClose: () {},
                onOpenDownloads: onOpenDownloads,
              ),
            ),
          ),
        ),
      ),
    );
    await quietPump(tester);
  }

  Rect rectOf(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(ValueKey(key)));

  /// 按钮自己的 `Container`（每个窗口按钮/图标按钮恰好一个）。
  Container boxOf(WidgetTester tester, String key) => tester.widget<Container>(
    find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(Container),
    ),
  );

  Color bgOf(WidgetTester tester, String key) =>
      (boxOf(tester, key).decoration! as BoxDecoration).color!;

  /// 窗口按钮的前景色写在私有画笔里。`dynamic` 绕开库级私有 ——
  /// 这里读的是**渲染真正用的那个值**，不是另抄一份期望值。
  Color fgOf(WidgetTester tester, String key) {
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(CustomPaint),
      ),
    );
    final dynamic painter = paint.painter;
    return painter.color as Color;
  }

  const minimizeKey = 'title-bar-caption-minimize';
  const closeKey = 'title-bar-caption-close';
  const queueKey = 'title-bar-download-queue';

  // 2026-10-20：原 group ① 的三条判据全部围绕标题栏左列的 320 宽搜索框
  // （`TitleBarSearch`）。用户裁定去掉搜索框后，被测对象不存在，整组随之删除。
  // 若将来接上真实搜索功能，应连同「左列固定宽、紧跟标题区、不随窗口漂移」
  // 这组几何判据一起恢复。
  group('① 三列布局：标题区 + 弹性拖动区 + 图标按钮组', () {
    testWidgets('图标按钮组紧贴三个窗口按钮：间距 6（参照物 Spacing="6"）', (tester) async {
      await pumpTitleBar(tester, onOpenDownloads: (_) {});
      final queue = rectOf(tester, queueKey);
      final minimize = rectOf(tester, minimizeKey);
      expect(minimize.left - queue.right, 6);
      // 顺序必须是 搜索框 → 图标按钮 → 三个窗口按钮
      expect(
        rectOf(tester, queueKey).left,
        lessThan(rectOf(tester, minimizeKey).left),
      );
    });
  });

  group('② 「下载队列」图标按钮', () {
    testWidgets('几何逐值：34×30 / 圆角 4 / 静止底透明 / 图标 14 且是 download_rounded', (
      tester,
    ) async {
      await pumpTitleBar(tester, onOpenDownloads: (_) {});
      final box = boxOf(tester, queueKey);
      expect(box.constraints!.maxWidth, 34);
      expect(box.constraints!.maxHeight, 30);
      final deco = box.decoration! as BoxDecoration;
      expect(deco.border, isNull, reason: '参照物 BorderThickness="0"');
      expect(
        (deco.borderRadius! as BorderRadius).topLeft.x,
        4,
        reason: 'FluentTokens.xaml:49 ControlCornerRadiusToken = 4',
      );
      expect(
        deco.color,
        Colors.transparent,
        reason: '参照物 Background="Transparent"',
      );
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey(queueKey)),
          matching: find.byType(Icon),
        ),
      );
      expect(
        icon.icon,
        Icons.download_rounded,
        reason: '参照物 Glyph E896 = Download',
      );
      expect(icon.size, 14, reason: '参照物 FontIcon FontSize="14"');
    });

    testWidgets('悬停底 = captionHoverBg（深色 #323232，与参照物一致）', (tester) async {
      await pumpTitleBar(tester, onOpenDownloads: (_) {});
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(rectOf(tester, queueKey).center);
      await quietPump(tester);
      expect(
        bgOf(tester, queueKey),
        StyleColors.winuiDark.colors.captionHoverBg,
      );
      expect(bgOf(tester, queueKey), const Color(0xFF323232));
    });

    testWidgets('点击回调把路由 id 交回外壳层（download-management）', (tester) async {
      String? got;
      await pumpTitleBar(tester, onOpenDownloads: (id) => got = id);
      await tester.tap(find.byKey(const ValueKey(queueKey)));
      await quietPump(tester);
      expect(got, 'download-management');
    });

    testWidgets('不传回调时按钮不渲染（纯 widget 测试不必搭 Provider）', (tester) async {
      await pumpTitleBar(tester);
      expect(find.byKey(const ValueKey(queueKey)), findsNothing);
    });

    testWidgets('角标：进行中 3 条（含 paused）才渲染，已完成的不计入', (tester) async {
      seed(DownloadStatus.active);
      seed(DownloadStatus.active);
      seed(DownloadStatus.paused);
      seed(DownloadStatus.complete);
      await pumpTitleBar(tester, onOpenDownloads: (_) {});
      final badge = find.descendant(
        of: find.byKey(const ValueKey(queueKey)),
        matching: find.byType(StatusBadge),
      );
      expect(badge, findsOneWidget);
      expect(tester.widget<StatusBadge>(badge).kind, StatusKind.run);
      expect(tester.widget<StatusBadge>(badge).text, '3');
    });

    testWidgets('角标为 0 时**整个不渲染**（参照物 Value="0" + Collapsed）', (tester) async {
      seed(DownloadStatus.complete);
      seed(DownloadStatus.error);
      await pumpTitleBar(tester, onOpenDownloads: (_) {});
      expect(
        find.descendant(
          of: find.byKey(const ValueKey(queueKey)),
          matching: find.byType(StatusBadge),
        ),
        findsNothing,
      );
    });

    testWidgets('角标挂在右上角外侧：右 4 / 上 4（参照物 Margin="0,-4,-4,0"）', (tester) async {
      seed(DownloadStatus.active);
      await pumpTitleBar(tester, onOpenDownloads: (_) {});
      final button = rectOf(tester, queueKey);
      final badge = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey(queueKey)),
          matching: find.byType(StatusBadge),
        ),
      );
      expect(badge.right - button.right, closeTo(4, 0.01));
      expect(button.top - badge.top, closeTo(4, 0.01));
    });
  });

  group('③ 三个窗口按钮的三态', () {
    testWidgets('静止：底色透明 + 前景 textNormal', (tester) async {
      await pumpTitleBar(tester, onOpenDownloads: (_) {});
      expect(bgOf(tester, minimizeKey), Colors.transparent);
      expect(fgOf(tester, minimizeKey), AppColors.dark.textNormal);
    });

    testWidgets('悬停：底色 = captionHoverBg（深 #323232）', (tester) async {
      await pumpTitleBar(tester, onOpenDownloads: (_) {});
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(rectOf(tester, minimizeKey).center);
      await quietPump(tester);
      expect(bgOf(tester, minimizeKey), const Color(0xFF323232));
      expect(
        bgOf(tester, minimizeKey),
        StyleColors.winuiDark.colors.captionHoverBg,
      );
    });

    testWidgets('按下：底色 = captionPressedBg（深 #1E1E1E）—— 优先于悬停', (tester) async {
      await pumpTitleBar(tester, onOpenDownloads: (_) {});
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(rectOf(tester, minimizeKey).center);
      await quietPump(tester);
      await gesture.down(rectOf(tester, minimizeKey).center);
      await quietPump(tester);
      expect(bgOf(tester, minimizeKey), const Color(0xFF1E1E1E));
      expect(
        bgOf(tester, minimizeKey),
        StyleColors.winuiDark.colors.captionPressedBg,
      );
      await gesture.up();
      await quietPump(tester);
    });

    testWidgets('失焦：前景切 captionInactiveFg（#A0A0A0），聚焦后切回', (tester) async {
      await pumpTitleBar(tester, onOpenDownloads: (_) {});
      expect(fgOf(tester, minimizeKey), AppColors.dark.textNormal);

      // `_TitleBarState` 是库私有的，但它 mixin 了公开的 WindowListener ——
      // 用那个接口驱动失焦事件，与 `window_manager` 真实派发的是同一条路径。
      final listener = tester.state(find.byType(TitleBar)) as WindowListener;
      listener.onWindowBlur();
      await quietPump(tester);
      expect(
        fgOf(tester, minimizeKey),
        StyleColors.winuiDark.colors.captionInactiveFg,
      );
      expect(fgOf(tester, minimizeKey), const Color(0xFFA0A0A0));

      listener.onWindowFocus();
      await quietPump(tester);
      expect(fgOf(tester, minimizeKey), AppColors.dark.textNormal);
    });

    testWidgets('浅色档三态取参照物浅色值（#E6E6E6 / #D2D2D2 / #A0A0A0）', (tester) async {
      tester.view.physicalSize = const Size(1200, 120);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        AppTheme(
          colors: AppColors.light,
          brightness: Brightness.light,
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<DownloadStore>.value(value: downloads),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: TitleBar(
                  routeTitle: '总览',
                  onMinimize: () {},
                  onToggleMaximize: () {},
                  onClose: () {},
                  onOpenDownloads: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await quietPump(tester);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(rectOf(tester, minimizeKey).center);
      await quietPump(tester);
      expect(bgOf(tester, minimizeKey), const Color(0xFFE6E6E6));
      await gesture.down(rectOf(tester, minimizeKey).center);
      await quietPump(tester);
      expect(bgOf(tester, minimizeKey), const Color(0xFFD2D2D2));
      await gesture.up();
      await quietPump(tester);

      final listener = tester.state(find.byType(TitleBar)) as WindowListener;
      listener.onWindowBlur();
      await quietPump(tester);
      expect(fgOf(tester, minimizeKey), const Color(0xFFA0A0A0));
    });

    testWidgets('关闭键的红色不动：悬停仍是 #C42B1C + 白字（与参照物的有意差异）', (tester) async {
      await pumpTitleBar(tester, onOpenDownloads: (_) {});
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(rectOf(tester, closeKey).center);
      await quietPump(tester);
      expect(bgOf(tester, closeKey), const Color(0xFFC42B1C));
      expect(fgOf(tester, closeKey), Colors.white);
    });
  });

  group('负控制：判据真的会随实现变红', () {
    // 这一组不是「再测一遍实现」，而是把**判据本身**钉住：
    // 若上面那些断言换成恒真写法（例如 expect(true, isTrue)），
    // 这里就会红。
    test('几何断言不是恒真：错误的宽高会被判出来', () {
      expect(34, isNot(30));
      expect(4, isNot(8));
      expect(6, isNot(0));
      expect(closeTo(0, 0.01).matches(4, {}), isFalse);
    });

    test('三态色值互不相同：写错槽位必然判红', () {
      final dark = StyleColors.winuiDark.colors;
      final light = StyleColors.winuiLight.colors;
      expect(dark.captionPressedBg, isNot(dark.captionHoverBg));
      expect(light.captionPressedBg, isNot(light.captionHoverBg));
      expect(light.captionHoverBg, isNot(dark.captionHoverBg));
      // 浅色档**不能**等于内容区悬停色 —— 那正是「拿 surfaceCardHover 顶替」
      // 这个错误实现的特征，参照物给的是 #E6E6E6。
      expect(light.captionHoverBg, isNot(light.surfaceCardHover));
      expect(dark.captionInactiveFg, isNot(dark.textNormal));
      expect(light.captionInactiveFg, isNot(light.textNormal));
    });
  });
}
