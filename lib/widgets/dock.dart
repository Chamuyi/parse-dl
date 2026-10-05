import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';
import 'nav_items.dart';

/// 底部悬浮 Dock（类 macOS）。
///
/// 结构：Logo | 分隔线 | 5 个导航图标。
/// 交互细节：图标悬停放大上浮 + 气泡标签 + 激活态蓝底与下方指示点。
///
/// **导航项、图标格、激活装饰、指示点、分隔线全部来自 `nav_items.dart`**，
/// 与常规侧边栏（`widgets/sidebar_nav.dart`）共享同一套实现，
/// 因此两种导航的布局语言与交互反馈天然一致。
///
/// **布局注意（曾出过 bug）**：
/// 1. Row 必须 `CrossAxisAlignment.center`。之前用 `.end` 是**底部对齐**，
///    而导航图标那一列因下方还有「激活指示点」、整体比 Logo(28) 高，
///    结果 Logo 视觉上沉到 Dock 底部，与图标不在同一条水平线上。
/// 2. 悬停气泡（label）必须**不参与布局**：曾把它放在图标上方的 Column 里，
///    即使 `AnimatedOpacity(opacity: 0)` 也照样占 ~31px 高度 —— Dock 被撑到 90px 高，
///    顶部还留出一大块空白。现在改用 [Tooltip]（走 Overlay 渲染，既不占布局
///    也不会被 AppFloat 的 ClipRRect 裁掉）。
class Dock extends StatelessWidget {
  final String currentRouteId;
  final void Function(String id) onSelect;
  final bool taskRunning;

  const Dock({
    super.key,
    required this.currentRouteId,
    required this.onSelect,
    this.taskRunning = false,
  });

  @override
  Widget build(BuildContext context) {
    return AppFloat(
      radius: 12,
      // 底部留 10px：容纳浮在图标下方 7px 的激活指示点（它不占 Row 布局）
      padding: const EdgeInsets.only(left: 8, right: 8, top: 6, bottom: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // 必须 center —— 见类文档第 1 条（用 end 会让 Logo 沉底）
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Logo
          ClipRRect(
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
          ),

          const NavDivider(axis: Axis.vertical, length: 24),

          // 两个下载模块的图标。Dock 是图标式导航、没有展开层级，
          // 所以直接平铺，靠**组间分隔线** + 每组开头的**单字徽标**
          // 体现「两个模块各自独立」—— 光有分隔线时，两组图标长得几乎一样
          // （都有下载管理 / 闪电 / 齿轮），得先数位置才知道哪组是谁。
          for (final g in kNavGroups) ...[
            _GroupBadge(group: g),
            const SizedBox(width: 5),
            for (final item in g.children)
              _DockIcon(
                item: item,
                active: item.id == currentRouteId,
                // 只有「自动执行」在后台跑任务时显示红点
                showDot: taskRunning && item.id == 'auto-task',
                onTap: () => onSelect(item.id),
              ),
            const NavDivider(axis: Axis.vertical, length: 24),
          ],

          // 全局项（设置 / 关于）—— 不属于任何模块
          for (final item in kNavStandalone)
            _DockIcon(
              item: item,
              active: item.id == currentRouteId,
              showDot: false,
              onTap: () => onSelect(item.id),
            ),
        ],
      ),
    );
  }
}

class _DockIcon extends StatefulWidget {
  final NavItem item;
  final bool active;
  final bool showDot;
  final VoidCallback onTap;

  const _DockIcon({
    required this.item,
    required this.active,
    required this.showDot,
    required this.onTap,
  });

  @override
  State<_DockIcon> createState() => _DockIconState();
}

class _DockIconState extends State<_DockIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: t(widget.item.label),
        // 悬停即可触发（默认要等 500ms，对 Dock 来说太迟钝）
        waitDuration: const Duration(milliseconds: 120),
        // 气泡显示在图标上方（Dock 在窗口底部，下方没有空间）
        preferBelow: false,
        verticalOffset: 8,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: c.surfaceFloat,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.line),
          // Tooltip 默认带 Material 阴影，这里换成更贴合浮层的轻阴影
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        textStyle: TextStyle(fontSize: 12, color: c.textStrong),
        child: NavFocusable(
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
                // Stack：图标本体决定本块尺寸（36×36），指示点浮在正下方不占布局 ——
                // 这样整块与 Logo(28) 在 Row 里 center 对齐后完全同心。
                // 若让指示点占布局，图标会被顶高 3.5px，与 Logo 对不齐。
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    NavIconBox(
                      item: widget.item,
                      active: widget.active,
                      hover: _hover,
                      focused: focused,
                      showDot: widget.showDot,
                      // macOS 式：悬停放大并上浮（数值刻意收小，避免图标乱跳）
                      hoverTransform:
                          Matrix4.translationValues(0, _hover ? -3 : 0, 0) *
                          Matrix4.diagonal3Values(
                            _hover ? 1.06 : 1.0,
                            _hover ? 1.06 : 1.0,
                            1,
                          ),
                    ),

                    // 激活指示点：浮在图标正下方 7px（靠 AppFloat 的底部 padding 容纳），
                    // 始终占位显示（用 opacity 切显隐），避免激活切换时 Dock 高度跳动
                    Positioned(
                      bottom: -7,
                      child: NavIndicatorDot(active: widget.active),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 模块徽标 —— Dock 上代表「这一组属于哪个模块」的单字方块。
///
/// 刻意**不**复用组的 `icon`：X 模块的组图标是 `download_rounded`，跟组里
/// 「下载管理」那一项是同一个图形，两个挨着放反而分不清谁是谁。
class _GroupBadge extends StatelessWidget {
  const _GroupBadge({required this.group});

  final NavGroup group;

  /// 识别色：X 用蓝（与全局 accent 同族），抖音用它的品牌红。
  static const Map<String, Color> _tints = {
    'x': Color(0xFF4A90F0),
    'douyin': Color(0xFFFE2C55),
  };

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tf('{label} 模块', {'label': t(group.label)}),
      child: Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _tints[group.id] ?? const Color(0xFF7A869A),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          group.badge,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            height: 1.05,
          ),
        ),
      ),
    );
  }
}
