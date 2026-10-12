// 抖音详情浮层「覆盖范围」的回归判据 —— 本轮要求：盖到**外壳层**。
//
// 演变过程（三层，逐次被真机反馈顶上来）：
//   ① 最初浮层挂在页面左侧网页区里 → 只盖住网页，右侧抓取面板露在外面；
//   ② P6（a629679）把页面内的 Stack 提到「包住整个 Row」→ 右侧面板也盖住了，
//      但**左侧导航栏仍露在遮罩外**；
//   ③ 本轮（P6b）把浮层提到**外壳层**：挂在 `app.dart` 里与导航 `Row` 同层的
//      那个 Stack 上 —— 用户 2026-10-12 的原话是「不是覆盖在网页上，是覆盖在
//      **软件表面**」，预览稿 `app.css:708-714` 的口径同样是铺满整个窗口。
//
// 判据为什么是**源码结构**：浮层是 `Positioned.fill`，它铺满的是「自己所在的那个
// Stack」—— 覆盖范围完全由**它挂在哪一层**决定。而 widget 测试里起不来真的
// WebView2（会挂死整条用例），所以钉住结构事实，再用真渲染补两条行为判据
// （遮罩可关 / 铺满整层）。
//
// 扫描前一律先剥注释：注释里出现组件名不该让判据变绿或变红。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/douyin_result_overlay.dart';
import 'package:provider/provider.dart';

/// 取一段源码里从 `from` 开始、按括号配对走到闭合的那一段。
///
/// 不用 `indexOf` 找下一个函数之类的边界 —— 那样算出来的片段会跨到别的函数里
/// （2026-10-12 在 bili_page_test 里踩过，混进了别的函数正文导致误判）。
String balanced(String src, int from, String open, String close) {
  final start = src.indexOf(open, from);
  expect(start, greaterThan(-1), reason: '找不到起始 $open');
  var depth = 0;
  for (var i = start; i < src.length; i++) {
    if (src[i] == open) depth++;
    if (src[i] == close) {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  fail('$open / $close 没有配对');
}

/// 剥掉 `//` 与 `/* */` 注释，字符串字面量原样保留。
///
/// **必须有**：源码扫描判据若把注释也算进去，就会「注释里提一句组件名 → 判据变绿」
/// 或「注释里解释旧结构 → 负控制误红」。这里按引号状态机走，避免把 URL 里的
/// `https://` 当成行注释起点（本仓库的源码里到处是 URL）。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final ch = src[i];
    if (ch == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length &&
          !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    if (ch == "'" || ch == '"') {
      // 原样抄走整个字面量（含转义）；三引号也一并吃掉。
      final triple = i + 2 < src.length && src[i + 1] == ch && src[i + 2] == ch;
      final quote = triple ? ch * 3 : ch;
      out.write(quote);
      i += quote.length;
      while (i < src.length) {
        if (src[i] == r'\') {
          out.write(src[i]);
          i++;
          if (i < src.length) {
            out.write(src[i]);
            i++;
          }
          continue;
        }
        if (src.startsWith(quote, i)) {
          out.write(quote);
          i += quote.length;
          break;
        }
        out.write(src[i]);
        i++;
      }
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

/// 某个类体内第一个 `build` 的完整函数体（已剥注释）。
String buildBodyOf(String src, String classHeader) {
  final at = src.indexOf(classHeader);
  expect(at, greaterThan(-1), reason: '找不到 $classHeader，测试要跟着改');
  final buildAt = src.indexOf('Widget build(BuildContext context) {', at);
  expect(buildAt, greaterThan(-1), reason: '$classHeader 里找不到 build');
  return balanced(src, buildAt, '{', '}');
}

/// 从 `classHeader` 起，**最内层**那个直接包住 [needle] 的 `Stack(...)` 片段。
String innermostStackHolding(String body, String needle) {
  final stackAt = 'Stack('.allMatches(body).map((m) => m.start).toList();
  expect(stackAt, isNotEmpty, reason: '这段源码里没有 Stack');
  String? hit;
  for (final at in stackAt) {
    final region = balanced(body, at, '(', ')');
    if (region.contains(needle)) hit = region; // 越靠后越内层
  }
  expect(hit, isNotNull, reason: '没有任何 Stack 包住 $needle');
  return hit!;
}

void main() {
  final appSrc = stripComments(File('lib/app.dart').readAsStringSync());
  final pageSrc = stripComments(File('lib/pages/douyin_page.dart').readAsStringSync());
  final ovlSrc = stripComments(
    File('lib/widgets/douyin_result_overlay.dart').readAsStringSync(),
  );

  group('判据①：浮层挂在外壳层（lib/app.dart）', () {
    test('浮层与 SidebarNav 处在同一层 Stack 之内', () {
      final body = buildBodyOf(appSrc, 'class _AppShellState');

      // 「同一层」= 包住 SidebarNav 的那个**最内层** Stack 同时包住浮层。
      // 浮层若退回页面内部，它就不会出现在这个 Stack 里。
      final stack = innermostStackHolding(body, 'SidebarNav');
      expect(stack, contains('DouyinResultOverlay'),
          reason: '包住 SidebarNav 的 Stack 里没有浮层 → 遮罩盖不到左侧导航栏');

      // 这一层还要包住导航与内容并排的那个 Row，否则它包的不是「外壳」。
      expect(stack, contains('Row('),
          reason: '这层 Stack 里没有导航与内容并排的 Row');

      // 覆盖范围 = 侧边栏 + 主内容区，**标题栏不在内**（预览稿 .app 的范围）。
      expect(stack, isNot(contains('TitleBar')),
          reason: '标题栏被圈进浮层那一层了 —— 范围超出预览稿口径');
    });

    test('浮层是这一层 Stack 的直接子节点，不在 Row 里面', () {
      final body = buildBodyOf(appSrc, 'class _AppShellState');
      final stack = innermostStackHolding(body, 'SidebarNav');
      final row = balanced(stack, stack.indexOf('Row('), '(', ')');

      // Row 里面才是 `if (useSidebar) SidebarNav(...)` —— 浮层若挂进这里，
      // Dock 形态（没有侧边栏）下它就只能盖住内容区，铺不满整宽。
      expect(row, contains('if (useSidebar)'));
      expect(row, contains('SidebarNav'));
      expect(row, isNot(contains('DouyinResultOverlay')),
          reason: '浮层被塞进 Row 里了 → Dock 形态下铺不满整宽（判据④）');
    });

    test('浮层由外壳层的开关状态决定渲染', () {
      final body = buildBodyOf(appSrc, 'class _AppShellState');
      expect(body, contains('_douyinOverlay'),
          reason: '外壳层没有持有浮层句柄 → 开关点还在页面里，两侧会各说各话');
      expect(appSrc, contains('isOpen'),
          reason: '外壳层没有读浮层的开关状态');
    });
  });

  group('判据②（负控制）：页面不再自己渲染浮层', () {
    test('douyin_page.dart 的 build 里不再出现浮层', () {
      final body = buildBodyOf(pageSrc, 'class _DouyinPageState');
      expect(body, isNot(contains('DouyinResultOverlay')),
          reason: '页面仍在渲染浮层 → 退回旧结构，遮罩只盖得到内容区');
      expect(body, isNot(contains('Positioned.fill')),
          reason: '页面 build 里还有 Positioned.fill —— 浮层没搬干净');
      expect(body, isNot(contains('Stack(')),
          reason: '页面 build 里还有 Stack —— 浮层那一层没搬走');
    });

    test('浮层的实现函数与私有类已整体迁出页面', () {
      for (final gone in [
        '_buildResultOverlay',
        '_buildPanelHeader',
        '_buildGroupRow',
        '_buildEnqueueButton',
        '_DownloadedRibbon',
        '_TypeChip',
        '_StatRow',
      ]) {
        expect(pageSrc, isNot(contains(gone)),
            reason: '$gone 还留在页面里 —— 搬移不完整');
      }
      // 反过来：新文件里必须真有这些东西（证明上一条不是因为「两边都没有」而恒绿）
      for (final moved in [
        'class DouyinResultOverlay',
        'class DownloadedRibbon',
        'class TypeChip',
        'class StatRow',
        'class DouyinCoverImage',
        'class DouyinEnqueueButton',
      ]) {
        expect(ovlSrc, contains(moved), reason: '$moved 没搬进新文件');
      }
    });

    test('正控制：浮层本体仍是 Positioned.fill（否则铺不满）', () {
      final body = buildBodyOf(ovlSrc, 'class _DouyinResultOverlayState');
      expect(body, contains('Positioned.fill'),
          reason: '浮层不是 Positioned.fill → 它不会铺满所在的那一层');
    });

    test('正控制：跨层共享的开关只有一份（句柄由外壳层持有）', () {
      expect(ovlSrc, contains('class DouyinOverlayController'));
      expect(pageSrc, contains('DouyinOverlayController'),
          reason: '页面没接外壳传来的句柄 → 开关状态无处可写');
      expect(appSrc, contains('DouyinOverlayController'),
          reason: '外壳层没持有句柄 → 浮层永远不渲染');
    });
  });

  group('判据③：遮罩可关（真渲染）', () {
    Future<void> pump(WidgetTester tester, VoidCallback onClose) async {
      await tester.pumpWidget(
        AppTheme(
          colors: AppColors.dark,
          brightness: Brightness.dark,
          child: MaterialApp(
            home: ChangeNotifierProvider<DouyinStore>.value(
              value: DouyinStore(),
              child: Scaffold(
                body: Stack(
                  children: [
                    const Positioned.fill(child: ColoredBox(color: Colors.blue)),
                    DouyinResultOverlay(
                      onClose: onClose,
                      enqueueing: false,
                      onEnqueue: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('点遮罩（面板左侧空白）关掉浮层', (tester) async {
      var closed = 0;
      await pump(tester, () => closed++);
      // 面板靠右、宽 560；x=10 必然落在遮罩上
      await tester.tapAt(const Offset(10, 300));
      await tester.pump();
      expect(closed, 1, reason: '点遮罩没关掉浮层 —— 用户会被困在浮层里');
    });

    testWidgets('点 ✕ 关掉浮层', (tester) async {
      var closed = 0;
      await pump(tester, () => closed++);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(closed, 1, reason: '点 ✕ 没关掉浮层');
    });

    testWidgets('负控制：两条关闭路径真的各触发一次（不是恒真）', (tester) async {
      var closed = 0;
      await pump(tester, () => closed++);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(closed, 1);
      await tester.tapAt(const Offset(10, 300));
      await tester.pump();
      expect(closed, 2);
      // 面板内部的空白不该关闭（点在被吃掉的那一层上）
      await tester.tapAt(const Offset(700, 300));
      await tester.pump();
      expect(closed, 2, reason: '面板内空白也关掉了浮层 —— 点击被穿透了');
    });
  });

  group('判据④：Dock 形态下同样铺满整宽（真渲染）', () {
    testWidgets('浮层铺满它所在的那一层：宽高 = 整层宽高', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var closed = 0;
      await tester.pumpWidget(
        AppTheme(
          colors: AppColors.dark,
          brightness: Brightness.dark,
          child: MaterialApp(
            home: ChangeNotifierProvider<DouyinStore>.value(
              value: DouyinStore(),
              child: Scaffold(
                body: Stack(
                  children: [
                    DouyinResultOverlay(
                      onClose: () => closed++,
                      enqueueing: false,
                      onEnqueue: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final size = tester.getSize(find.byType(DouyinResultOverlay));
      expect(size.width, 1200,
          reason: '浮层没铺满整宽 → 遮罩边上会露出没盖住的一栏');
      expect(size.height, 800, reason: '浮层没铺满整高');

      // 左边缘（Dock 形态下就是内容区的最左边）也必须在遮罩里 ——
      // 这条同时证明「铺满」不是只铺了右半边。
      await tester.tapAt(const Offset(2, 400));
      await tester.pump();
      expect(closed, 1, reason: '左边缘点不到遮罩 → 那一侧没被盖住');
    });
  });
}
