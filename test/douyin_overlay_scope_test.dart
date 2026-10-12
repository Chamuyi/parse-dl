// 抖音详情浮层「覆盖范围」的回归判据。
//
// 真机要求（2026-10-12 用户明确）：浮层要盖住**整个软件表面**，不是只盖住
// 左侧的网页区。原先 `Stack` 只包住左侧 `Expanded`，而浮层是 `Positioned.fill`
// —— 它只铺满自己所在的那个 Stack，于是右侧 268px 的抓取面板与工具栏露在外面。
//
// 判据是**源码结构**而不是渲染结果：浮层是 `Positioned.fill`，它的覆盖范围由
// 它挂在哪个 Stack 决定。widget 测试里起不来真的 WebView2（会挂死整条用例），
// 所以钉住「Stack 包住了整个 Row」这个结构事实。
//
// 判据强度已用负控制验证：把 Stack 改回只包左侧时，本文件会红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

void main() {
  final src = File('lib/pages/douyin_page.dart').readAsStringSync();

  group('抖音浮层的覆盖范围', () {
    test('build() 里的 Stack 包住了整个 Row（含右侧抓取面板）', () {
      // 定位 build 方法
      final buildAt = src.indexOf('Widget build(BuildContext context) {');
      expect(buildAt, greaterThan(-1), reason: '找不到 build，测试要跟着改');

      // 取 build 的完整函数体
      final body = balanced(src, buildAt, '{', '}');

      // 判据 1：Stack 的直接子节点里要同时有 Row 与浮层
      final stackAt = body.indexOf('Stack(');
      expect(stackAt, greaterThan(-1), reason: 'build 里没有 Stack');
      final stack = balanced(body, stackAt, '(', ')');

      expect(stack, contains('Row('),
          reason: 'Stack 里没有 Row —— 浮层只能盖住自己那一栏，盖不到整个内容区');
      expect(stack, contains('_buildResultOverlay'),
          reason: 'Stack 里没有浮层 —— 它被挂到别处去了，覆盖范围会不对');

      // 判据 2：**抓取面板必须在 Stack 里面**（这是本条的核心）
      expect(stack, contains('_buildCapturePane'),
          reason: '_buildCapturePane 不在 Stack 里 → 浮层盖不住右侧抓取面板');
    });

    test('负控制：抓取面板**不再**被包在只含网页的那个内层 Stack 里', () {
      // 反向断言：如果实现退回旧结构，会有两个嵌套 Stack（外层包左侧、内层在左侧里），
      // 且 _buildCapturePane 在外层 Stack 之外。这里断言那种形状不存在。
      final buildAt = src.indexOf('Widget build(BuildContext context) {');
      final body = balanced(src, buildAt, '{', '}');

      final stackCount = 'Stack('.allMatches(body).length;
      expect(stackCount, 1,
          reason: 'build 里出现了 $stackCount 个 Stack —— 旧的嵌套结构回来了？'
              '（外层只包左侧时，_buildCapturePane 会在 Stack 之外）');
    });

    test('正控制：浮层本身仍是 Positioned.fill（否则铺不满）', () {
      final ovlAt = src.indexOf('Widget _buildResultOverlay(');
      expect(ovlAt, greaterThan(-1));
      final ovl = balanced(src, ovlAt, '{', '}');
      expect(ovl, contains('Positioned.fill'),
          reason: '浮层不是 Positioned.fill → 它不会铺满 Stack');
    });

    test('正控制：浮层仍可关闭（点遮罩 / 点 ✕）', () {
      final ovlAt = src.indexOf('Widget _buildResultOverlay(');
      final ovl = balanced(src, ovlAt, '{', '}');
      expect(ovl, contains('_panelOpen = false'),
          reason: '浮层没有关闭路径 —— 提层时把 onTap 改坏了');
    });
  });
}
