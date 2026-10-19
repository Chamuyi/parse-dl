import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';
import 'nav_items.dart';

/// 底部悬浮 Dock —— 形态照抄参照物 `NavigationView` 的 **Top 形态**（水平导航条）。
///
/// 结构：Logo | 分隔线 | 导航图标（顺序严格等于 `kNavItems`）。
/// 条目几何逐值取自参照物同一仓库的官方复刻
/// `tubatool/website-winui3/src/components/WinNavigationView.vue`：
/// 条目 40 高 / 图标 16 / 圆角 4 / 选中无底色 / 贴底 3×2 强调色横条。
///
/// **导航项集合与顺序、图标格、激活装饰、分隔线全部来自 `nav_items.dart`**，
/// 与常规侧边栏（`widgets/sidebar_nav.dart`）共享同一套实现与同一份
/// `kNavItems` —— 两种导航**展示完全相同的页面与顺序**（既有约束）。
/// 差异只在**形态**：Dock = 顶部条（贴底横条 + 无选中底色），
/// 侧边栏 = 左侧栏（贴左缘竖条 + `SubtleFillColorSecondary` 底色）。
/// 这两套形态在原生的 `NavigationViewPaneDisplayMode` 里就是 `Top` 与 `Left`
/// （参照物 `MainWindow.xaml.cs:883-885` 在这两者间切换）。
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
      // 上下各 2 = 参照物条目 `margin: 2px 4px` 的垂直那一半
      // （`WinNavigationView.vue:3237`）；左右各 8 是浮条自身的内缘留白
      // （原生 Top 导航条整体 `margin: 0 4px`，但那是通栏条、不是浮条，
      // 本项无对应值，沿用改造前的 8）。条目的横向 4 由 [_DockIcon] 自己带。
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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

          // 分隔线逐值照参照物 Top 形态 `.win-nav-item-separator`：
          // 高 24、外边距左 3 右 4（`WinNavigationView.vue:3278-3285`）。
          const NavDivider(
            axis: Axis.vertical,
            length: 24,
            margin: EdgeInsets.only(left: 3, right: 4),
          ),

          // ⓪ 置顶项（总览）—— 不属于任何模块，软件打开就落在它上面。
          //    Dock 是图标式导航，这里直接平铺在三个模块之前。
          for (final item in kNavPrimary)
            _DockIcon(
              item: item,
              active: item.id == currentRouteId,
              showDot: false,
              onTap: () => onSelect(item.id),
            ),

          // 分隔线逐值照参照物 Top 形态 `.win-nav-item-separator`：
          // 高 24、外边距左 3 右 4（`WinNavigationView.vue:3278-3285`）。
          const NavDivider(
            axis: Axis.vertical,
            length: 24,
            margin: EdgeInsets.only(left: 3, right: 4),
          ),

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
            // 分隔线逐值照参照物 Top 形态 `.win-nav-item-separator`：
            // 高 24、外边距左 3 右 4（`WinNavigationView.vue:3278-3285`）。
            const NavDivider(
              axis: Axis.vertical,
              length: 24,
              margin: EdgeInsets.only(left: 3, right: 4),
            ),
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

    // 条目外边距逐值照参照物 Top 形态：`.win-nav-item` 是
    // `height: 40px; margin: 2px 4px`（`WinNavigationView.vue:3235-3237`）。
    // 本 Dock 的条目是纯图标格（无文字），条目宽 = 图标格 40，
    // 于是条目之间自然得到 4 + 4 = 8px 的横向间距；垂直那 2px 由 Dock 的
    // 外层 padding 统一承担（首尾条目也一样有）。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
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
                // Stack：图标格决定本块尺寸，激活横条贴它的**底边内侧**、不占布局 ——
                // 这样整块与 Logo(28) 在 Row 里 center 对齐后完全同心。
                // 若让横条占布局，图标会被顶高，与 Logo 对不齐。
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
                      // Top 形态的选中项**无底色**，标记由下面那条贴底横条承担
                      // （`WinNavigationView.vue:3337-3340`）。
                      activeFill: false,
                      // macOS 式：悬停放大并上浮（数值刻意收小，避免图标乱跳）
                      hoverTransform:
                          Matrix4.translationValues(0, _hover ? -3 : 0, 0) *
                          Matrix4.diagonal3Values(
                            _hover ? 1.06 : 1.0,
                            _hover ? 1.06 : 1.0,
                            1,
                          ),
                    ),

                    // 激活横条：**贴条目底边内侧 4px**（`bottom: 4px`），宽度等于
                    // 条目宽、高 3px、圆角 2px —— 逐值照参照物 Top 形态的
                    // `.win-nav-indicator`（`WinNavigationView.vue:3195-3198` +
                    // `:3219-3224`）。它替代了原先浮在图标下方 7px 的圆点：
                    // 原生 Top 形态没有圆点，标记只有这一条横线。
                    // 始终占位（用 opacity 切显隐），切换激活项时 Dock 高度不跳动。
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 4,
                      child: NavIndicatorBar(active: widget.active),
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

  /// 识别色：按各平台自己的品牌色 —— X 蓝、抖音红、B 站粉。
  ///
  /// **三组都要登记**：漏一个不会报错，它会静默落到下面那个兜底灰，
  /// 而灰色徽标在 Dock 上跟「没有归属」长得一样（B 站这组就漏过一轮）。
  static const Map<String, Color> _tints = {
    'x': Color(0xFF4A90F0),
    'douyin': Color(0xFFFE2C55),
    'bili': Color(0xFFFB7299),
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
