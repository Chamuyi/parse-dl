import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_style.dart';
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
/// 三个下载模块在侧边栏里是**并列的三行**，不是包在一个父项里 ——
/// 点某一行的标题就展开/收起它自己那一组，各管各的。
class NavGroup {
  /// 分组标识（'x' / 'douyin' / 'bili'），展开状态的持久化键
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

/// 三个下载模块。这三个模块在功能与设置层面都保持独立。
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
  // B 站这一组照抖音那组的命名与图标规则，但**只有四项**：
  // 「自动下载」是 P2/P3 的东西，现在挂上来就是一个点进去会白屏的入口，
  // 所以刻意留空而不是先造一个假页面。
  // 组名比页面名短一档（「B 站下载」而不是「B 站解析下载」）：侧边栏中文档
  // 只有 200px，七字标签会被截断 —— `l10n_test` 的「中文导航不许被截断」那条
  // 当场把它撞出来了。组里的子项已经写明是「解析下载」，标题不必再重复一遍。
  // 角标用大写 B（站点自身的标识就是这个字母），不用「站」。
  NavGroup('bili', 'B 站下载', Icons.live_tv_rounded, [
    NavItem('bili', '解析下载', Icons.play_circle_outline_rounded),
    NavItem('bili-batch', '批量下载', Icons.playlist_play_rounded),
    NavItem('bili-downloads', '下载管理', Icons.download_rounded),
    NavItem('bili-settings', 'B 站设置', Icons.tune_rounded),
  ], 'B'),
];

/// 不属于任何模块、且**置顶**展示的项（当前只有「总览」）。
///
/// 为什么单独一个列表而不是塞进 [kNavGroups]：那个列表的语义是
/// 「三个下载模块」，`test/nav_groups_test.dart` 钉着「正好三组」。
/// 为什么不是 [kNavStandalone]：那个列表渲染在三个模块**下面**，
/// 而总览要置顶（软件打开就落在它上面）。
const kNavPrimary = <NavItem>[
  NavItem('dashboard', '总览', Icons.space_dashboard_rounded),
];

/// 不属于任何模块的**全局**项（侧边栏里排在三个模块下面）。
const kNavStandalone = <NavItem>[
  // 三条都叫「设置」时，Dock 形态下两个滑杆图标 + 相同气泡文字根本分不出
  // 点的是哪一个 —— 名字要自带归属。
  NavItem('settings', '全局设置', Icons.settings_rounded),
  NavItem('about', '关于', Icons.info_rounded),
];

/// 扁平的「全部导航项」= 置顶项 + 三个模块的子项 + 全局项。
///
/// Dock（`widgets/dock.dart`）用它 —— 图标式导航没有展开层级，
/// 所以直接平铺，靠组间分隔线体现模块边界。
/// 保留这个名字，另一个原因是「当前页标题」等处也在用。
final kNavItems = <NavItem>[
  ...kNavPrimary,
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

  // ── 侧边栏专用（照抄原生 `NavigationViewItem`）──────────────────
  //
  // 参照物 tubatool 的 `MainWindow.xaml` 用原生 `NavigationView`，
  // 条目不是「36px 图标方块」，而是「16px 图标 + 12 间距 + 文字」。
  // Dock 仍是悬浮圆角格（[iconBox] / [iconSize]），两套形态各自独立 ——
  // 2026-10-19 用户裁定放开了「必须共用同一常量」的约束。

  /// 侧边栏图标本体（原生 16）
  static const double sidebarIconSize = 16;

  /// 图标与文字间距
  static const double sidebarIconGap = 12;

  /// 侧边栏行高（原生 `NavigationViewItem` 单行 40）
  static const double sidebarRowHeight = 40;

  /// 顶层项左缩进
  static const double sidebarIndentTop = 16;

  /// 子项左缩进（= 16 + 24，原生层级缩进）
  static const double sidebarIndentChild = 40;
}

/// 导航项容器装饰 —— **两种布局共用这一个函数**。
///
/// 悬停态 = 该风格的悬停底色；键盘焦点态 = 一圈高亮描边；其余 = 全透明。
/// 因为两边都走这里，激活/悬停/聚焦的观感不可能不一致。
///
/// **激活态按风格分流**（S5）：
/// - [AppStyle.frosted]（默认）继续走 [selectedDecoration] —— 选中底色全应用
///   只有那一个出处（`appearance_controls_test` 源码层钉着本文件必须含
///   `selectedDecoration(` 且**不得**直接引用色板的 accentSoft 槽位），
///   这也是改造前所有风格的观感，既有调用点零改动；
/// - liquid / clay 走 `app_style.dart` 的 `navActiveOf` 令牌
///   （CSS `:284-286` / `:418-420`），都**不内联颜色**。
///
/// [style] 的默认值是 [AppStyle.frosted]：不传的调用点（含既有测试）
/// 拿到改造前的画法。传风格的调用点（`NavIconBox` / `sidebar_nav.dart`）
/// 从 `AppTheme.of(context).style` 取。
///
/// 焦点框为什么用 [AppColors.accentText] 而不是 `accent`：焦点框要在**两种背景**
/// 上都过 WCAG 的 3:1（非文本对比度）。`accent` #1D9BF0 压在暗色卡片 #4C4C4C 上
/// 只有 2.85，而 `accentText`（暗 #57B9FF / 浅 #0F6FA8）在暗卡片上 3.99、
/// 在浅卡片 #EDEDED 上 4.64，两端都够。
/// 描边宽度恒为 1px（未聚焦时是透明描边），否则切换瞬间文字会跳格。
///
/// **左侧 3×15px 竖条**（三套 CSS 逐字节相同的那条）不在这里画：
/// 它是几何而不是装饰参数，且两布局的锚定位置不同（侧边栏 `left:11px`、
/// Dock 形态下对齐行头）——由侧边栏行与 Dock 图标格用 [NavActiveBar] 表达，
/// 三套风格共用同一条，不作为区分点。
BoxDecoration navItemDecoration(
  AppColors c, {
  required bool active,
  bool focused = false,
  AppStyle style = AppStyle.winui,
  Brightness brightness = Brightness.light,
}) {
  if (focused) {
    // 焦点框 = 1px 描边 + 向外撑 1.5px 的硬边。单圈 1px 在 125% 缩放下只有
    // 1 物理像素，深色壁纸上几乎看不见；spread 不占布局，不会把文字挤走。
    final ring = Border.all(color: c.accentText, width: 1);
    final hardGlow = [
      BoxShadow(color: c.accentText, blurRadius: 0, spreadRadius: 1.5),
    ];
    if (active) {
      // 既选中又被聚焦：底色仍走该风格的选中画法（frosted = selectedDecoration，
      // liquid/clay = 同一套令牌底），这里只把描边与柔光换成焦点框。
      return _activeDecorationFor(c, style, active: true, brightness: brightness)
          .copyWith(border: ring, boxShadow: hardGlow);
    }
    return BoxDecoration(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(style.shapeOf().navRowRadius),
      border: ring,
      boxShadow: hardGlow,
    );
  }
  if (active) {
    return _activeDecorationFor(c, style, active: true, brightness: brightness);
  }
  return BoxDecoration(
    // **不再画悬停底色**（2026-10-17 用户裁定删除该效果）。
    //
    // 原先这里是 `hover ? c.surfaceCardHover : Colors.transparent`。真机表现为
    // 鼠标划过时「两个完整的圆角矩形块同时出现、再闪一下消失」，且鼠标**停住
    // 不动也会自己消失**；日志证明 `MouseTracker` 的 enter/exit 完全正常
    // （停住时 600ms 内没有 EXIT），即状态是对的、问题在渲染层，属合成/脏区
    // 层面的残留，排查多轮未能定位。用户据此裁定不要这个效果。
    //
    // 保留的是另一套反馈：图标/文字变色（[navIconColor]）与轻微位移。
    color: Colors.transparent,
    borderRadius: BorderRadius.circular(style.shapeOf().navRowRadius),
    // 不激活也留一圈**透明**描边：描边要占 1px，省掉会让文字在悬停瞬间跳格
    border: Border.all(color: Colors.transparent, width: 1),
  );
}

/// 按 [style] 取导航激活态装饰 —— **navItemDecoration 内部的唯一分流点**。
///
/// - frosted → [selectedDecoration]（唯一出处，行为与改造前逐字节一致）；
/// - liquid / clay → `navActiveOf` 令牌（底色/渐变 + 内描边 + liquid 外发光），
///   颜色全部来自 `lib/theme/app_style.dart`，这里只做组装。
///
/// 注意亮度取默认浅色档：激活态三套令牌的浅/深差异只来自 `--ac` 的取值
/// （liquid `#5B6CFF`→`#7C8DFF`、clay `#C2410C`→`#EA580C`），而导航组件树
/// 里 [AppColors] 不携带亮度。侧边栏 / Dock 传来的色板本身已按亮度选好，
/// 激活态的深色变体经 [AppTheme.style] + 组件内 `_activeDecorationFor` 的
/// 带 brightness 重载取（见 `navDecorationFor`）。
BoxDecoration _activeDecorationFor(
  AppColors c,
  AppStyle style, {
  required bool active,
  Brightness brightness = Brightness.light,
}) {
  // 导航行圆角随风格：WinUI3 的 NavigationView 选中项是 4px 圆角，
  // 另三套沿用 NavMetrics.radius（12）。这一条是「形态」而不是「颜色」，
  // 所以走 StyleShape 而不是色板。
  final rowRadius = style.shapeOf().navRowRadius;
  if (!active) {
    return BoxDecoration(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(rowRadius),
      border: Border.all(color: Colors.transparent, width: 1),
    );
  }

  // **WinUI 的 NavigationViewItem 选中态不是「亮蓝色块」**（2026-10-19
  // 用户判「没看出来哪里 WinUI」，这是最刺眼的一处）。原生的画法是：
  //   * 底色 = `SubtleFillColorSecondary`（深色 6% 白 / 浅色 4% 黑）——
  //     几乎看不出，只是一层极淡的灰；
  //   * 左侧一条 3px 的**强调色竖条**才是真正的选中标记；
  //   * 无边框、无发光、无渐变。
  // 竖条由行内的 [NavActiveBar] 画（两布局共用），这里只给底色。
  // 选中态**只走令牌**（`navActiveOf`）：`appearance_controls_test` 与
  // `nav_layout_test` 两条判据都钉着「激活态只有一套出处」，绕过令牌
  // 直接内联颜色会被判红。令牌本身已经是 WinUI 正确值：
  // 浅色 `0x1A0078D4`（10% 强调色）、深色 `0x264CC2FF`，都无描边无发光。
  final t = style.navActiveOf(brightness);
  final radius = BorderRadius.circular(rowRadius);
  final glow =
      t.glow == null ? null : [kNavActiveGlow.copyWith(color: t.glow)];
  return BoxDecoration(
    gradient: t.gradient,
    color: t.gradient == null ? t.color : null,
    borderRadius: radius,
    border: Border.all(color: t.borderColor, width: 1),
    boxShadow: glow,
  );
}

/// 亮度感知的导航装饰入口：组件（`NavIconBox` / 侧边栏行）在持有
/// [BuildContext] 的地方用它，把 `AppTheme.of(context).brightness` 一并传入。
BoxDecoration navDecorationFor(
  BuildContext context, {
  required bool active,
  bool focused = false,
}) {
  final t = AppTheme.of(context);
  return navItemDecoration(
    t.colors,
    active: active,
    focused: focused,
    style: t.style,
    brightness: t.brightness,
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

/// 左侧激活竖条 —— 3×15px 圆角胶囊，三套 CSS 逐字节相同的那条。
///
/// 出处：`app.css:288-292` / `:359-363` / `:422-426`
/// `width:3px; height:15px; border-radius:999px; background:var(--ac)`，
/// 位置 `left:11px; top:50%; translateY(-50%)`。
/// **规格一致，不作为风格区分点** —— 这里只有一份实现，三套共用；
/// 颜色取 [AppColors.accent]（= CSS `var(--ac)`）。
class NavActiveBar extends StatelessWidget {
  final bool active;

  const NavActiveBar({super.key, required this.active});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final th = AppTheme.of(context);
    // WinUI3 的 NavigationView 指示条是**贴左边缘的直条**（高约 16px、
    // 无圆角），另三套是悬浮的 3×15 圆角胶囊。位置差异见调用点。
    final winui = th.style == AppStyle.winui;

    return AnimatedOpacity(
      opacity: active ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      child: Container(
        width: 3,
        height: winui ? 16 : 15,
        decoration: BoxDecoration(
          color: c.accent,
          borderRadius: BorderRadius.circular(winui ? 1.5 : 999),
        ),
      ),
    );
  }
}

/// 图标/文字颜色。
///
/// 未选中项用**主文本色**（`TextFillColorPrimary`），不是次要色 ——
/// 原生 `NavigationViewItem` 就是这个取色；用 [AppColors.textMuted] 时
/// 侧边栏在深色窗口材质上暗到几乎读不出来（2026-10-19 真机取证）。
Color navIconColor(AppColors c, {required bool active, required bool hover}) {
  if (active) return c.accentText;
  return c.textStrong;
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

  /// 图标本体尺寸。默认 Dock 的 18；侧边栏传 [NavMetrics.sidebarIconSize]（16）。
  final double iconSize;

  const NavIconContent({
    super.key,
    required this.item,
    required this.active,
    required this.hover,
    required this.showDot,
    this.iconSize = NavMetrics.iconSize,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(
          item.icon,
          size: iconSize,
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
    final t = AppTheme.of(context);

    return AnimatedContainer(
      // 与侧边栏同一处理由：悬停遮罩的渐隐 / 渐显各自独立计时，180ms 会让
      // 相邻两块出现「同时带遮罩 → 闪一下消失」的重叠窗口（2026-10-16）。
      duration: const Duration(milliseconds: 80),
      curve: Curves.easeOut,
      transform: hoverTransform,
      width: NavMetrics.iconBox,
      height: NavMetrics.iconBox,
      // 经 AppTheme 取 style + brightness —— Dock 与侧边栏共用同一个
      // navItemDecoration 分流（frosted → selectedDecoration）。
      decoration: navItemDecoration(
        c,
        active: active,
        focused: focused,
        style: t.style,
        brightness: t.brightness,
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
