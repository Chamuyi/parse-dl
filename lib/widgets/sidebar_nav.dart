import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';
import 'nav_items.dart';

/// 常规样式的左侧竖向侧边栏。
///
/// **与 [Dock] 的关系**：展示同一组导航项（[kNavItems]），并且复用
/// [NavIconBox] / [navItemDecoration] / [NavIndicatorDot] / [NavRunningDot] /
/// [NavDivider]，因此两种导航的图标尺寸、激活底色、描边、发光、悬停反馈、
/// 运行红点、分隔线**完全同源**，只差排布方向：
///
///   Dock：   Logo  ─  5 个图标      ← 横向一行，浮在窗口底部中央
///   侧边栏： logo / 5 行          ← 纵向一列，贴左侧通高
///
/// 顺序也刻意保持一致（Logo → 分隔线 → 导航项），
/// 所以用户在两者之间切换时不会「重新找一遍」。
///
/// **与 Dock 的唯一有意差异**：侧边栏每行始终显示文字标签，
/// 因此不再挂悬停气泡（否则等于把同一个名字显示两遍）。
/// Dock 是图标式、没有文字，才需要气泡补足信息。
class SidebarNav extends StatelessWidget {
  final String currentRouteId;
  final void Function(String id) onSelect;
  final bool taskRunning;

  /// 某个模块入口当前是否展开（key = `NavGroup.id`）
  final bool Function(String groupId) isGroupExpanded;

  /// 点击模块标题行 —— 切换**它自己那一个**模块的展开状态
  final void Function(String groupId) onToggleGroup;

  /// 侧边栏外框宽度（含左右 padding）。
  ///
  /// **按语言分叉是有意为之**：中文标签最长也就「抖音解析下载」七个字，
  /// 200px 刚好；英文同一批标签是 'Douyin Downloads' / 'Download Manager'，
  /// 200px 会把每一行都截成 `X Downloa…`（2026-09-20 真机截图证实）。
  /// 让英文档宽 52px，比把两种语言一起撑宽、中文档留一片空白划算。
  /// 刻意仍是**固定值**而不是按内容自适应：`nav_layout_test` 钉着
  /// 「切换激活项不得改变宽高」。
  ///
  /// 240 不够：组标题那行还要给右侧箭头留 18px，`Douyin Downloads` 当时
  /// 仍被截成 `Douyin Downloa…`（2026-09-24 真机截图）。现在由
  /// `l10n_test` 里的「没有一条导航被截断」测着，改宽度不会再靠肉眼。
  static double get width => inEnglish ? 252 : 200;

  const SidebarNav({
    super.key,
    required this.currentRouteId,
    required this.onSelect,
    required this.isGroupExpanded,
    required this.onToggleGroup,
    this.taskRunning = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: AppFloat(
        radius: 16,
        // 与 Dock 同一套内边距语言
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Logo —— 与 Dock 的第一个元素同源、同尺寸
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Center(child: _SidebarLogo()),
            ),

            const NavDivider(axis: Axis.horizontal),

            // 导航区。展开后条目可能超出高度，所以这里可滚动。
            Expanded(
              // 左侧留 12px：容纳浮在行外左侧的激活指示点
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ① 两个下载模块 —— 每个模块是**一个可点击展开的入口**，
                      //    点标题行展开/收起它自己，两个模块互不影响。
                      for (final g in kNavGroups) ...[
                        _SidebarGroupHeader(
                          group: g,
                          expanded: isGroupExpanded(g.id),
                          // 当前页就在这个模块里 → 标题行也高亮
                          activeInGroup: navGroupOf(currentRouteId)?.id == g.id,
                          onTap: () => onToggleGroup(g.id),
                        ),
                        if (isGroupExpanded(g.id))
                          for (final item in g.children)
                            _SidebarNavRow(
                              item: item,
                              active: item.id == currentRouteId,
                              // 只有「自动执行」在后台跑任务时显示红点
                              showDot: taskRunning && item.id == 'auto-task',
                              indented: true,
                              onTap: () => onSelect(item.id),
                            ),
                      ],

                      const NavDivider(axis: Axis.horizontal),

                      // ② 全局项（设置 / 关于）—— 不属于任何模块
                      for (final item in kNavStandalone)
                        _SidebarNavRow(
                          item: item,
                          active: item.id == currentRouteId,
                          showDot: false,
                          onTap: () => onSelect(item.id),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一个模块的标题行 —— 它本身就是「统一入口」：
/// 点一下展开、再点一下收起，展开/收起只由这一行控制。
class _SidebarGroupHeader extends StatefulWidget {
  final NavGroup group;
  final bool expanded;

  /// 当前页是否就在这个模块里（是的话标题行也跟着高亮）
  final bool activeInGroup;

  final VoidCallback onTap;

  const _SidebarGroupHeader({
    required this.group,
    required this.expanded,
    required this.activeInGroup,
    required this.onTap,
  });

  @override
  State<_SidebarGroupHeader> createState() => _SidebarGroupHeaderState();
}

class _SidebarGroupHeaderState extends State<_SidebarGroupHeader> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final color = widget.activeInGroup
        ? c.accent
        : navIconColor(c, active: false, hover: _hover);

    return NavFocusable(
      focusLabel: 'nav-group:${widget.group.id}',
      onTap: widget.onTap,
      builder: (context, focused) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Semantics(
            button: true,
            expanded: widget.expanded,
            label: tf('{label}节点，{hint}', {
              'label': t(widget.group.label),
              'hint': t(widget.expanded ? '点击收起' : '点击展开'),
            }),
            child: Container(
              height: NavMetrics.iconBox + 4,
              margin: const EdgeInsets.symmetric(vertical: 1),
              padding: const EdgeInsets.only(left: 8, right: 6),
              // 标题行本身不用激活底色：激活是子项的事，
              // 这里只靠**文字/图标变色 + 箭头方向**表达状态，避免一行亮两层。
              decoration: navItemDecoration(
                c,
                active: false,
                hover: _hover,
                focused: focused,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: NavMetrics.iconBox,
                    height: NavMetrics.iconBox,
                    child: Icon(
                      widget.group.icon,
                      size: NavMetrics.iconSize,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t(widget.group.label),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                  // 展开时箭头朝下，收起时朝右
                  AnimatedRotation(
                    turns: widget.expanded ? 0 : -0.25,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: c.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 侧边栏顶部的 Logo —— 与 Dock 的 Logo 同尺寸、同圆角、同兜底图标。
class _SidebarLogo extends StatelessWidget {
  const _SidebarLogo();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.asset(
        'assets/logo.png',
        width: 28,
        height: 28,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: const Color(0xFF1D9BF0),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.download_rounded,
            color: Colors.white,
            size: 16,
          ),
        ),
      ),
    );
  }
}

/// 侧边栏的一行：图标格 + 文字标签，激活指示点浮在行外左侧。
class _SidebarNavRow extends StatefulWidget {
  final NavItem item;
  final bool active;
  final bool showDot;
  final VoidCallback onTap;

  /// 是否是模块子项（缩进一格，视觉上从属于上面的模块标题行）
  final bool indented;

  const _SidebarNavRow({
    required this.item,
    required this.active,
    required this.showDot,
    required this.onTap,
    this.indented = false,
  });

  @override
  State<_SidebarNavRow> createState() => _SidebarNavRowState();
}

class _SidebarNavRowState extends State<_SidebarNavRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return NavFocusable(
      focusLabel: 'nav:${widget.item.id}',
      onTap: widget.onTap,
      builder: (context, focused) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Semantics(
            button: true,
            selected: widget.active,
            label: tf(widget.active ? '切换到{label}（当前）' : '切换到{label}', {
              'label': t(widget.item.label),
            }),
            // Stack：指示点浮在行外左侧，不参与布局 ——
            // 与 Dock 用「图标下方浮点」的思路一致，切换激活项时列表不跳动。
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 整行激活底色（比 Dock 的图标格更宽，因为横排要包住文字）
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  height: NavMetrics.iconBox + 4,
                  margin: const EdgeInsets.symmetric(vertical: 1),
                  padding: EdgeInsets.only(
                    left: widget.indented ? 22 : 8,
                    right: 10,
                  ),
                  // 悬停时轻微右移，对应 Dock 的「上浮」——同为方向性位移反馈
                  transform: Matrix4.translationValues(_hover ? 2 : 0, 0, 0),
                  decoration: navItemDecoration(
                    c,
                    active: widget.active,
                    hover: _hover,
                    focused: focused,
                  ),
                  child: Row(
                    children: [
                      // 图标格：尺寸与红点位置都复用共享实现，只是这里
                      // **不带自身底色**（底色已经由上面整行的 container 提供），
                      // 否则会出现「激活底色套激活底色」的框中框。
                      SizedBox(
                        width: NavMetrics.iconBox,
                        height: NavMetrics.iconBox,
                        child: NavIconContent(
                          item: widget.item,
                          active: widget.active,
                          hover: _hover,
                          showDot: widget.showDot,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          t(widget.item.label),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: widget.active
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: navIconColor(
                              c,
                              active: widget.active,
                              hover: _hover,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // 激活指示点：浮在行外左侧（Dock 里它浮在图标下方）
                Positioned(
                  left: -9,
                  top: 0,
                  bottom: 0,
                  child: Center(child: NavIndicatorDot(active: widget.active)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
