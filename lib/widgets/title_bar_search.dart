import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';

/// 标题栏里的搜索框 —— 照抄参照物 `MainWindow.xaml:107-113` 的
/// `AutoSuggestBox`（宽 320、垂直居中、左侧放大镜、占位文案
/// 「搜索工具、设置...」）。
///
/// ### 为什么放在标题栏里
///
/// WinUI 3 的 `TitleBar` 控件就是**允许把内容放进标题栏**的（`TitleBar.Content`），
/// 图吧工具箱正是这么用的：窗口标题行本身就是一条功能区，搜索、队列、
/// 更新等全局入口全在这里。这也是它一眼就能被认成 WinUI 的原因之一 ——
/// 标题栏不是一条「只有最小化/关闭」的细带。
///
/// ### 取值
///
/// * 宽度 320（参照物 `<ColumnDefinition Width="320" />`）
/// * 高度 32（`AutoSuggestBox` 默认单行高度）
/// * 圆角 4（官方 `ControlCornerRadius`）
/// * 底色 `controlFillColorDefault`：深色 6% 白 / 浅色 4% 黑
/// * 描边 `controlStrokeColorDefault`：深色 7% 白 / 浅色 6% 黑
/// * 底边 1px 略深（`controlStrokeColorSecondary`），这是 WinUI 输入框的标志
class TitleBarSearch extends StatefulWidget {
  const TitleBarSearch({super.key, this.onChanged, this.onSubmitted});

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<TitleBarSearch> createState() => _TitleBarSearchState();
}

class _TitleBarSearchState extends State<TitleBarSearch> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    // **一律走色板语义槽位**，不内联色值 —— `visual_tokens_test` 的色板棘轮
    // 会把新文件里手写的颜色字面量判红（注释里也不行，正则不剥注释）。
    // 这三个槽位就是官方 `controlFillColorDefault` /
    // `controlStrokeColorDefault` / `controlStrokeColorSecondary` 的对应物：
    //   controlFill   = 官方 controlFillColorDefault（深 6% 白 / 浅 70% 白，**半透明**）
    //   lineSoft      = 常规描边
    //   line          = 底边那一档略深的描边
    //
    // **2026-10-20 修**：原先用 surfaceSunken（不透明实色）。标题栏现在会透出
    // 窗口材质，实测材质是 (82,79,70)，而不透明深灰是 (28,28,28) —— 两者叠在
    // 一起就是一块「黑洞」，用户报「最上面怎么一块黑色」。
    // 官方输入框底色是半透明的，压在材质上只做轻微提亮，不会打出暗块。
    final fill = c.controlFill;
    final stroke = c.lineSoft;
    final bottomStroke = c.line;

    return SizedBox(
      width: 320,
      height: 32,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(4),
          border: Border(
            top: BorderSide(color: stroke),
            left: BorderSide(color: stroke),
            right: BorderSide(color: stroke),
            // 输入框底边比其余三边深一档（WinUI 的控件描边规范）。
            bottom: BorderSide(color: _focused ? c.accent : bottomStroke),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 10),
            Icon(Icons.search_rounded, size: 16, color: c.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Center(
                heightFactor: 1.0,
                child: TextField(
                controller: _controller,
                focusNode: _focus,
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
                cursorColor: c.accent,
                // 单行、垂直居中：Row 里没有默认高度，必须显式约束，
                // 否则 TextField 按 intrinsic 高度撑开、文字被裁掉（实测只剩一条空框）。
                textAlignVertical: TextAlignVertical.center,
                style: TextStyle(fontSize: 13, height: 1.0, color: c.textStrong),
                decoration: InputDecoration(
                  // **不能用 isCollapsed**：它会连行高一起收掉，实测 TextField
                  // 只剩 13px 高，占位文字被压成一条看不见的线。
                  // isDense + 显式 contentPadding 才是正确的单行写法。
                  isDense: true,
                  border: InputBorder.none,
                  hintText: t('搜索设置与页面'),
                  hintStyle: TextStyle(
                    fontSize: 13,
                    height: 1.0,
                    color: c.textMuted,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}
