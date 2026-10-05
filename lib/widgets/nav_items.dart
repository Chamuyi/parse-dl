import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// 一个导航项。
class NavItem {
  final String id;
  final String label;
  final IconData icon;

  const NavItem(this.id, this.label, this.icon);
}

/// 一个**模块**：侧边栏里一个「可点击展开的统一入口」+ 它下面的功能页。
///
/// 两个下载模块在侧边栏里是**并列的两行**，不是包在一个父项里 ——
/// 点某一行的标题就展开/收起它自己那一组，各管各的。
class NavGroup {
  /// 分组标识（'x' / 'douyin'），展开状态的持久化键
  final String id;

  /// 入口标题
  final String label;

  final IconData icon;

  /// 组内功能页。**数组顺序即展示顺序**。
  final List<NavItem> children;

  /// Dock 上代表这一组的**单字徽标**。
  ///
  /// 不复用 [icon]：X 模块的组图标是 `download_rounded`，跟组里
  /// 「下载管理」那一项**同一个图形**，摆在旁边反而分不清谁是谁。
  final String badge;

  const NavGroup(this.id, this.label, this.icon, this.children, this.badge);
}

/// 两个下载模块。这两个模块在功能与设置层面都保持独立。
const kNavGroups = <NavGroup>[
  NavGroup('x', 'X 下载', Icons.download_rounded, [
    NavItem('home', '主页', Icons.home_rounded),
    NavItem('download-management', '下载管理', Icons.download_rounded),
    NavItem('auto-task', '自动执行', Icons.bolt_rounded),
    NavItem('x-settings', 'X 下载设置', Icons.tune_rounded),
  ], 'X'),
  // 抖音模块的功能页与 X 模块**一一对应**（解析下载≈主页、下载管理、自动下载
  // ≈自动执行、设置），这样两个模块的导航结构一致，切模块不用重新学。
  // 注意 id 各自独立：两个「下载管理」是不同的导航项，激活态才不会互相点亮。
  NavGroup('douyin', '抖音解析下载', Icons.music_note_rounded, [
    NavItem('douyin', '解析下载', Icons.play_circle_outline_rounded),
    NavItem('douyin-downloads', '下载管理', Icons.download_rounded),
    NavItem('douyin-auto', '自动下载', Icons.bolt_rounded),
    NavItem('douyin-settings', '抖音设置', Icons.tune_rounded),
  ], '抖'),
];

/// 不属于任何模块的**全局**项（侧边栏里排两个模块下面）。
const kNavStandalone = <NavItem>[
  // 三条都叫「设置」时，Dock 形态下两个滑杆图标 + 相同气泡文字根本分不出
  // 点的是哪一个 —— 名字要自带归属。
  NavItem('settings', '全局设置', Icons.settings_rounded),
  NavItem('about', '关于', Icons.info_rounded),
];

/// 扁平的「全部导航项」= 两个模块的子项 + 全局项。
///
/// Dock（`widgets/dock.dart`）用它 —— 图标式导航没有展开层级，
/// 所以直接平铺，靠组间分隔线体现模块边界。
/// 保留这个名字，另一个原因是「当前页标题」等处也在用。
final kNavItems = <NavItem>[
  for (final g in kNavGroups) ...g.children,
  ...kNavStandalone,
];

/// 按 id 找导航项（找不到返回 null）。
NavItem? navItemById(String id) {
  for (final item in kNavItems) {
    if (item.id == id) return item;
  }
  return null;
}

/// 某个 id 属于哪个模块（全局项返回 null）。
NavGroup? navGroupOf(String id) {
  for (final g in kNavGroups) {
    for (final c in g.children) {
      if (c.id == id) return g;
    }
  }
  return null;
}

/// 兼容旧名字：Dock 早期把导航项叫 `DockItem` / `kDockItems`。
typedef DockItem = NavItem;
final kDockItems = kNavItems;

/// 导航项共用的尺寸常量。
///
/// 抽出来的目的：两种布局用**同一套数值**，避免出现
/// 「Dock 图标 18px、侧边栏图标 16px」这类不一致。
abstract final class NavMetrics {
  /// 图标方块边长 —— Dock 的图标格、侧边栏每行的图标格都用它
  static const double iconBox = 36;

  /// 图标本体大小
  static const double iconSize = 18;

  /// 激活指示点直径
  static const double dot = 4;

  /// 导航项圆角
  static const double radius = 12;
}

/// 导航项容器装饰 —— **两种布局共用这一个函数**。
///
/// 激活态直接取 [selectedDecoration]（与材质卡片、分段控件同一套画法）；
/// 悬停态 = 略亮的卡片底色；键盘焦点态 = 一圈高亮描边；其余 = 全透明。
/// 因为两边都走这里，激活/悬停/聚焦的观感不可能不一致。
///
/// 焦点框为什么用 [AppColors.accentText] 而不是 `accent`：焦点框要在**两种背景**
/// 上都过 WCAG 的 3:1（非文本对比度）。`accent` #1D9BF0 压在暗色卡片 #4C4C4C 上
/// 只有 2.85，而 `accentText`（暗 #57B9FF / 浅 #0F6FA8）在暗卡片上 3.99、
/// 在浅卡片 #EDEDED 上 4.64，两端都够。
/// 描边宽度恒为 1px（未聚焦时是透明描边），否则切换瞬间文字会跳格。
BoxDecoration navItemDecoration(
  AppColors c, {
  required bool active,
  required bool hover,
  bool focused = false,
}) {
  if (focused) {
    // 焦点框 = 1px 描边 + 向外撑 1.5px 的硬边。单圈 1px 在 125% 缩放下只有
    // 1 物理像素，深色壁纸上几乎看不见；spread 不占布局，不会把文字挤走。
    final ring = Border.all(color: c.accentText, width: 1);
    final hardGlow = [
      BoxShadow(color: c.accentText, blurRadius: 0, spreadRadius: 1.5),
    ];
    if (active) {
      // 既选中又被聚焦：底色仍走 selectedDecoration（全应用选中底色只有那一个
      // 出处），这里只把描边与柔光换成焦点框。
      return selectedDecoration(c, radius: NavMetrics.radius)
          .copyWith(border: ring, boxShadow: hardGlow);
    }
    return BoxDecoration(
      color: hover ? c.surfaceCardHover : Colors.transparent,
      borderRadius: BorderRadius.circular(NavMetrics.radius),
      border: ring,
      boxShadow: hardGlow,
    );
  }
  if (active) return selectedDecoration(c, radius: NavMetrics.radius);
  return BoxDecoration(
    color: hover ? c.surfaceCardHover : Colors.transparent,
    borderRadius: BorderRadius.circular(NavMetrics.radius),
    // 不激活也留一圈**透明**描边：描边要占 1px，省掉会让文字在悬停瞬间跳格
    border: Border.all(color: Colors.transparent, width: 1),
  );
}

/// 让一个导航项**能被 Tab 走到、能用 Enter/Space 触发**。
///
/// 侧边栏与 Dock 的行原本是 `MouseRegion + GestureDetector` —— 鼠标能用，
/// 但键盘完全走不到（实测连按 14 次 Tab，焦点一次都没进过导航区），
/// 也就是纯键盘用户**连页面都切不了**。这里补上 Focus 节点与按键激活，
/// 并把「有没有焦点」交给调用方去画焦点框。
class NavFocusable extends StatefulWidget {
  final String focusLabel;
  final VoidCallback onTap;

  /// 语义标签（读屏用），与原来的 `Semantics(label:)` 一致
  final String? semanticLabel;
  final Widget Function(BuildContext context, bool focused) builder;

  const NavFocusable({
    super.key,
    required this.focusLabel,
    required this.onTap,
    required this.builder,
    this.semanticLabel,
  });

  @override
  State<NavFocusable> createState() => _NavFocusableState();
}

class _NavFocusableState extends State<NavFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      debugLabel: widget.focusLabel,
      onFocusChange: (v) {
        if (v != _focused) setState(() => _focused = v);
      },
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter ||
            k == LogicalKeyboardKey.space) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: widget.semanticLabel == null
          // 调用方自带更精确的 Semantics（比如分组标题要报"已展开/已收起"）时，
          // 这里不再套第二层 button，免得读屏念两遍。
          ? widget.builder(context, _focused)
          : Semantics(
              button: true,
              label: widget.semanticLabel,
              onTap: widget.onTap,
              child: widget.builder(context, _focused),
            ),
    );
  }
}

/// 图标颜色 —— 两种布局共用。
Color navIconColor(AppColors c, {required bool active, required bool hover}) {
  if (active) return c.accentText;
  return hover ? c.textStrong : c.textMuted;
}

/// 分组分隔线 —— Dock 是竖向短分隔线，侧边栏是横向分隔线，
/// 同属「分组标记」，因此共用这一个实现，只有轴向与长度不同。
///
/// [length] 为 null 表示占满交叉轴（侧边栏用）。
class NavDivider extends StatelessWidget {
  final Axis axis;
  final double? length;

  const NavDivider({super.key, required this.axis, this.length});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final vertical = axis == Axis.vertical;

    return Container(
      width: vertical ? 1 : (length ?? double.infinity),
      height: vertical ? (length ?? double.infinity) : 1,
      margin: vertical
          ? const EdgeInsets.symmetric(horizontal: 4)
          : const EdgeInsets.symmetric(vertical: 6),
      color: c.line,
    );
  }
}

/// 「后台任务运行中」红点 —— Dock 与侧边栏共用。
///
/// 调用方负责用 `Positioned` 决定位置（Dock 在图标右上角、侧边栏在图标右上角，
/// 相对的是同一个 36×36 图标格，所以位置也一致）。
class NavRunningDot extends StatelessWidget {
  const NavRunningDot({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: const BoxDecoration(
        color: Color(0xFFF87171),
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Color(0xE6F87171), blurRadius: 6)],
      ),
    );
  }
}

/// 激活指示点 —— Dock 与侧边栏共用。
///
/// 两种布局里它都**浮在导航项之外、不参与布局**（Dock 在图标下方、
/// 侧边栏在图标左侧），所以用 [AnimatedOpacity] 切显隐而不是增删节点，
/// 这样切换激活项时容器尺寸不会跳动。
class NavIndicatorDot extends StatelessWidget {
  final bool active;

  const NavIndicatorDot({super.key, required this.active});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return AnimatedOpacity(
      opacity: active ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      child: Container(
        width: NavMetrics.dot,
        height: NavMetrics.dot,
        decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
      ),
    );
  }
}

/// 图标本体 + 可选运行红点，**不含底色**。
///
/// Dock 与侧边栏共用。红点固定在 36×36 格子内的右上角，
/// 而两种布局的图标格都是 36×36，所以红点位置天然一致。
class NavIconContent extends StatelessWidget {
  final NavItem item;
  final bool active;
  final bool hover;
  final bool showDot;

  const NavIconContent({
    super.key,
    required this.item,
    required this.active,
    required this.hover,
    required this.showDot,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(
          item.icon,
          size: NavMetrics.iconSize,
          color: navIconColor(c, active: active, hover: hover),
        ),
        if (showDot) const Positioned(right: 6, top: 6, child: NavRunningDot()),
      ],
    );
  }
}

/// 36×36 图标格 —— **自带激活底色/描边/发光**。
///
/// Dock 用它作为导航项本体（图标格本身就是可点区域）。
/// 侧边栏不用它：那边是「整行」作为可点区域与激活底色，
/// 图标只放无底色的 [NavIconContent]，避免出现「框中框」。
class NavIconBox extends StatelessWidget {
  final NavItem item;
  final bool active;
  final bool hover;
  final bool showDot;

  /// 键盘焦点：由外层 [NavFocusable] 传下来，只影响画法
  final bool focused;

  /// Dock 的悬停效果是「上浮 + 放大」，由调用方注入 transform。
  final Matrix4? hoverTransform;

  const NavIconBox({
    super.key,
    required this.item,
    required this.active,
    required this.hover,
    required this.showDot,
    this.focused = false,
    this.hoverTransform,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      transform: hoverTransform,
      width: NavMetrics.iconBox,
      height: NavMetrics.iconBox,
      decoration: navItemDecoration(
        c,
        active: active,
        hover: hover,
        focused: focused,
      ),
      child: NavIconContent(
        item: item,
        active: active,
        hover: hover,
        showDot: showDot,
      ),
    );
  }
}
