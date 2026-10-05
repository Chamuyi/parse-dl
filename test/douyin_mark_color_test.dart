import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/douyin_interceptor_js.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 页面上的黄框与右侧抓取结果的黄框必须是**同一个颜色**。
///
/// 用户就是靠"两边一样的框"来确认「列表里这条 = 页面上那条」：
///   * 页面上那圈是注入脚本 `markNode` 画的，色值写死在 JS 字符串里
///     （本项目的视觉取值 `#ffb600`，2px）；
///   * 右侧格子与浮层行勾上后描的是 `AppTheme.kMarkYellow`。
/// 两边各写一份，改了一边不会报错、只会让用户对不上 —— 所以钉成测试。
void main() {
  test('注入脚本描的黄框仍是 2px solid #ffb600', () {
    expect(
      kDouyinInterceptorJs,
      contains("el.style.border = '2px solid #ffb600'"),
      reason: 'JS 那边改了色值或粗细，Dart 侧的 kMarkYellow 要跟着改',
    );
  });

  test('Dart 侧 kMarkYellow 就是 JS 里那个 #ffb600', () {
    expect(kMarkYellow, const Color(0xFFFFB600));
  });
}
