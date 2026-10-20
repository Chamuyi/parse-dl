import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/l10n.dart';
import '../services/download_store.dart';
import '../theme/app_style.dart';
import '../theme/app_theme.dart';
import 'status_badge.dart';

/// 标题栏里的图标按钮几何 —— 逐值照抄参照物
/// `tubatool/TubaWinUi3.WinUI3/MainWindow.xaml:230-248` 的
/// `DownloadQueueButton`：
///
/// | 量 | 值 | 出处 |
/// |---|---|---|
/// | 宽 × 高 | 34 × 30 | `:233` `Width="34" Height="30"` |
/// | 圆角 | 4 | `Styles/FluentTokens.xaml:49` `ControlCornerRadiusToken`（= 我方 `shape.optCellRadius`） |
/// | 边框 | 0 | `:235` `BorderThickness="0"` |
/// | 静止底 | 透明 | `:236` `Background="Transparent"` |
/// | 图标 | 14 | `:239` 的 `FontIcon FontSize="14"` |
/// | 与相邻按钮间距 | 6 | `:216` `Spacing="6"` |
const Size _kIconButtonSize = Size(34, 30);
const double _kIconButtonRadius = 4;
const double _kIconButtonGap = 6;

/// 「进行中」的判定 —— 与首页 `dashboard_page.dart:236-240` 的 `_isRunning`
/// 是**同一套状态集合**（待下载 / 下载中 / 排队中 / 已暂停）。
///
/// 两处各留一份是因为那个函数是 `dashboard_page.dart` 的库私有（Dart 的 `_`
/// 只在同一 library 内可见），跨文件引用不到 —— 口径必须一起改，否则首页说
/// 「3 个进行中」而标题栏角标显示 2 的时候没人能解释。
bool _isRunning(DownloadTask t) =>
    t.status == DownloadStatus.pending ||
    t.status == DownloadStatus.active ||
    t.status == DownloadStatus.waiting ||
    t.status == DownloadStatus.paused;

/// 自绘标题栏。窗口是无边框的（titleBarStyle: hidden），
/// 所以标题栏、拖动、三个窗口按钮都由这里负责。
///
/// 三个按钮的图标**全部用同一套自绘几何**（10×10 画布、1px 描边），
/// 保证笔画粗细与视觉尺寸完全一致 —— 混用字体图标和手绘 SVG 会两者不一致，
/// 导致三个按钮看着不齐。
///
/// ### 2026-10-19 T5：标题栏右列照抄参照物
///
/// 参照物的 `TitleBar.Content` 是**三列** `320 / * / Auto`
/// （`MainWindow.xaml:103-107`）：左列固定 320 的搜索框、中列弹性空白、
/// 右列 `StackPanel Spacing="6"` 的按钮组。我方此前是
/// `Spacer + 搜索框 + Spacer`（居中），属于布局差异，这里改成同一套三列。
///
/// 参照物右列第一个按钮是「新手教程」（`MainWindow.xaml:217-228`）——
/// **不抄**：我方 `lib/` 与 `lib/l10n/` 对该功能零命中，照抄等于新增功能。
class TitleBar extends StatefulWidget {
  final String routeTitle;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;

  /// 「下载队列」图标按钮点下去要跳到的路由 id。
  ///
  /// 由 `app.dart` 注入 `_setRoute` —— 标题栏自己不认识路由表，与
  /// `DashboardPage.onNavigate` 是同一个分工。为 null 时该按钮**不渲染**：
  /// 纯 widget 测试里不必为了它先搭一套 Provider 树。
  final void Function(String routeId)? onOpenDownloads;

  const TitleBar({
    super.key,
    required this.routeTitle,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
    this.onOpenDownloads,
  });

  @override
  State<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<TitleBar> with WindowListener {
  bool _maximized = false;

  /// 窗口是否处于激活（有焦点）态。
  ///
  /// **初值 true**：应用刚起来时窗口就是激活的。反过来的初值会让每次冷启动
  /// 先闪一帧「失焦灰」再被 `onWindowFocus` 纠正。
  bool _focused = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _sync();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _sync() async {
    final m = await windowManager.isMaximized();
    if (mounted && m != _maximized) setState(() => _maximized = m);
  }

  @override
  void onWindowMaximize() => _sync();

  @override
  void onWindowUnmaximize() => _sync();

  /// 失焦 / 聚焦：三个窗口按钮的前景在失焦时切 `captionInactiveFg`
  /// （参照物 `BuiltinWindowHelper.cs:166` 的 `ButtonInactiveForegroundColor`）。
  ///
  /// 只在**值真的变了**时才 setState：`window_manager` 在拖动、连续点击时
  /// 会重复派发同一个事件，无条件赋值会让整条标题栏白白重建。
  @override
  void onWindowFocus() {
    if (_focused) return;
    setState(() => _focused = true);
  }

  @override
  void onWindowBlur() {
    if (!_focused) return;
    setState(() => _focused = false);
  }

  @override
  Widget build(BuildContext context) {
    final th = AppTheme.of(context);
    final c = th.colors;
    final shape = th.style.shapeOf();

    // WinUI3：标题栏与侧栏**同色连成一片**（Windows 11 的 NavigationView 就是
    // 这样 —— 标题栏不是一条独立色带，而是窗口 chrome 的延续）。另三套沿用
    // 既有画法：surfaceSolid 85%（浅色 = 浅灰，深色 = 深灰；早先用 surfaceCard
    // 在深色下是白色 5.5% 的白雾，与深色底不协调，故为实色）。
    final side = th.style.sidebarOf(th.brightness);
    final titleColor = shape.titleBarTintedLikeSidebar && side.gradient == null
        ? side.color
        : c.surfaceSolid.withValues(alpha: 0.85);

    // 「下载队列」角标上的数字：进行中的任务条数。
    //
    // 读 `DownloadStore.tasks` 的真实数据，不写死 —— 参照物那个角标
    // （`MainWindow.xaml:240-246`）同样是真值，初始 `Value="0"` 且
    // `Visibility="Collapsed"`。用 `select` 而不是 `watch`：整棵
    // 标题栏只在**这个数字**变时才重建，进度百分比每帧刷新不会带着标题栏一起动。
    final runningTasks = context.select<DownloadStore, int>(
      (s) => s.tasks.where(_isRunning).length,
    );

    return Container(
      height: shape.titleBarHeight,
      decoration: BoxDecoration(
        color: titleColor,
        border: Border(bottom: BorderSide(color: c.lineSoft, width: 1)),
      ),
      child: Row(
        children: [
          // 左侧：Logo + 标题 + 当前页（整块可拖动）
          //
          // **不包 `Expanded`**：包了它就会和下面的弹性空白平分剩余宽度，
          // 搜索框被推到栏中间（真机实测：1280 逻辑宽下搜索框左边界落在
          // 551 而不是紧随标题区的 ~200）—— 那就不是参照物的三列
          // `320 / * / Auto` 了（`MainWindow.xaml:103-107`）。
          // 自然宽度 + 中间那段 `Expanded` 才是三列语义。
          DragToMoveArea(
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.asset(
                      'assets/logo.png',
                      width: 18,
                      height: 18,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: c.accent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Icon(
                          Icons.download_rounded,
                          color: Colors.white,
                          size: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    t('解析下载器'),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: c.textStrong,
                    ),
                  ),
                  if (widget.routeTitle.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      '/',
                      style: TextStyle(fontSize: 12.5, color: c.textFaint),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.routeTitle,
                      style: TextStyle(fontSize: 12.5, color: c.textMuted),
                    ),
                  ],
                ],
              ),
            ),
          ),

          if (shape.titleBarHeight >= 48) ...[
            // **搜索框已移除**（2026-10-20 用户裁定「删了吧」）。
            //
            // 原先是照抄参照物 `MainWindow.xaml:109-119` 的左列 `AutoSuggestBox`
            // （固定 320 宽）。但它**从来没接上功能**：`const TitleBarSearch()`
            // 没传 `onChanged`/`onSubmitted`，打字和回车都没有任何反应 ——
            // 一个能点却没反应的输入框比不放更糟。
            //
            // 要恢复的话：得接上真实的搜索路由，而不是只把外观摆回去。

            // 中列：弹性空白（参照物第二列 `Width="*"`），把右侧按钮组推到最右。
            // 这段空白同时是**拖动区**：标题区收窄成自然宽度后，栏中间那一大片
            // 若不可拖，用户会以为窗口卡住了（Win11 的标题栏整条都能拖）。
            Expanded(child: DragToMoveArea(child: const SizedBox.expand())),

            // 右列：图标按钮组（参照物第三列 `Width="Auto"`，
            // 组内 `Spacing="6"`，`MainWindow.xaml:212-249`）
            if (widget.onOpenDownloads != null) ...[
              _TitleBarIconButton(
                key: const ValueKey('title-bar-download-queue'),
                label: '下载队列',
                icon: Icons.download_rounded,
                badgeCount: runningTasks,
                onTap: () => widget.onOpenDownloads!('download-management'),
              ),
              const SizedBox(width: _kIconButtonGap),
            ],
          ],

          // 右侧：三个窗口按钮，flush 排布
          _CaptionButton(
            key: const ValueKey('title-bar-caption-minimize'),
            label: '最小化',
            painter: (p, color) => p.minimize(color),
            onTap: widget.onMinimize,
            focused: _focused,
          ),
          _CaptionButton(
            key: const ValueKey('title-bar-caption-maximize'),
            label: _maximized ? '还原' : '最大化',
            painter: (p, color) =>
                _maximized ? p.restore(color) : p.maximize(color),
            onTap: widget.onToggleMaximize,
            focused: _focused,
          ),
          _CaptionButton(
            key: const ValueKey('title-bar-caption-close'),
            label: '关闭',
            painter: (p, color) => p.close(color),
            onTap: widget.onClose,
            danger: true,
            focused: _focused,
          ),
        ],
      ),
    );
  }
}

/// 标题栏里的图标按钮 —— 参照物 `MainWindow.xaml:230-248` 的
/// `DownloadQueueButton`（几何取值见文件头的常量注释）。
class _TitleBarIconButton extends StatefulWidget {
  final String label;
  final IconData icon;

  /// 角标上的数字。`0` 时角标整个不渲染 —— 与参照物初始
  /// `Value="0" Visibility="Collapsed"` 同义（`:241-243`）。
  final int badgeCount;
  final VoidCallback onTap;

  const _TitleBarIconButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  State<_TitleBarIconButton> createState() => _TitleBarIconButtonState();
}

class _TitleBarIconButtonState extends State<_TitleBarIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context).colors;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Semantics(
          label: t(widget.label),
          button: true,
          child: Container(
            width: _kIconButtonSize.width,
            height: _kIconButtonSize.height,
            decoration: BoxDecoration(
              // 悬停底走 captionHoverBg（与三个窗口按钮**同一个**槽位）：
              // 参照物那套按钮配色本来就是整条标题栏共用一份
              // （`BuiltinWindowHelper.cs:141-167`），同一条栏里两个悬停色
              // 是肉眼可见的不一致。浅色下它是 #E6E6E6，而内容区的
              // surfaceCardHover 是 #F7F7F7 —— 照抄就不能拿后者顶替。
              color: _hover ? c.captionHoverBg : Colors.transparent,
              borderRadius: BorderRadius.circular(_kIconButtonRadius),
            ),
            // `Clip.none`：角标按参照物 `Margin="0,-4,-4,0"` 外扩 4px，
            // 默认的 `Clip.hardEdge` 会把它裁掉一半。
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // `Positioned.fill`：图标铺满整个 34×30 再居中。不给它定位时
                // Stack 会按「最大非定位子」收缩，图标的位置会随角标宽度漂移。
                Positioned.fill(
                  child: Center(
                    child: Icon(widget.icon, size: 14, color: c.textNormal),
                  ),
                ),
                if (widget.badgeCount > 0)
                  Positioned(
                    top: -4,
                    right: -4,
                    // 形态复用 StatusBadge：它已经接了 shape.badgeRadius /
                    // badgePadH / badgePadV（WinUI3 = 4px 圆角小矩形，正是
                    // 参照物 InfoBadge 的形状），不必再造一个胶囊。
                    child: StatusBadge(
                      kind: StatusKind.run,
                      text: '${widget.badgeCount}',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个窗口按钮。尺寸对齐 Win11 标题栏按钮比例（46×48，见 `StyleShape`）。
///
/// ### 三态（2026-10-19 T5）
///
/// 悬停 / 按下 / 失焦照抄参照物 `BuiltinWindowHelper.cs:141-167`：
/// hover 底 `captionHoverBg`（深 #323232 / 浅 #E6E6E6）、
/// pressed 底 `captionPressedBg`（深 #1E1E1E / 浅 #D2D2D2）、
/// 失焦前景 `captionInactiveFg`（#A0A0A0）。
///
/// **关闭键的红色不动**：参照物那套 `ButtonHover*` 是整条标题栏共用一份的，
/// 但 Windows 11 上关闭键历来单独变红，我方既有的红底画法照旧 —— 这一处是
/// 与参照物的**有意差异**，不是漏抄。
class _CaptionButton extends StatefulWidget {
  final String label;
  final void Function(_IconPainter, Color) painter;
  final VoidCallback onTap;
  final bool danger;

  /// 窗口当前是否激活。失焦时前景切 `captionInactiveFg`。
  final bool focused;

  const _CaptionButton({
    super.key,
    required this.label,
    required this.painter,
    required this.onTap,
    this.danger = false,
    this.focused = true,
  });

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final th = AppTheme.of(context);
    final c = th.colors;
    final shape = th.style.shapeOf();

    // 三态优先级：按下 > 悬停 > 静止。
    // **先判 pressed**：按下时指针必然还在按钮里，所以 `_hover` 一定也是
    // true，顺序反过来的话按下底永远显示不出来（判据 `title_bar_caption_states_test`
    // 就是钉这个的）。
    final Color bg;
    if (widget.danger && (_hover || _pressed)) {
      // 本文件唯一一处写死色值，`visual_tokens_test.dart:40` 已登记预算 = 1
      bg = const Color(0xFFC42B1C);
    } else if (_pressed) {
      bg = c.captionPressedBg;
    } else if (_hover) {
      bg = c.captionHoverBg;
    } else {
      bg = Colors.transparent;
    }

    final fg = widget.danger && (_hover || _pressed)
        ? Colors.white
        : (widget.focused ? c.textNormal : c.captionInactiveFg);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        // 按下后把指针拖出按钮再松开，收不到 onTapUp —— 不在这里清掉的话
        // 按下底会一直卡住。
        _pressed = false;
      }),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: Semantics(
          label: t(widget.label),
          button: true,
          child: Container(
            width: shape.captionWidth,
            height: shape.captionHeight,
            margin: EdgeInsets.symmetric(horizontal: shape.captionMargin),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(shape.captionRadius),
            ),
            // 关键：必须 Center，否则 CustomPaint 的 10×10 画在容器左上角看不到
            child: Center(
              child: SizedBox(
                width: 10,
                height: 10,
                child: CustomPaint(
                  painter: _CallbackPainter(widget.painter, fg),
                  size: const Size(10, 10),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CallbackPainter extends CustomPainter {
  final void Function(_IconPainter, Color) fn;
  final Color color;

  _CallbackPainter(this.fn, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    fn(_IconPainter(canvas, color), color);
  }

  @override
  bool shouldRepaint(_CallbackPainter old) =>
      old.color != color || old.fn != fn;
}

/// 统一的图标几何：全部画在 10×10 的逻辑画布上，1px 描边。
class _IconPainter {
  final Canvas canvas;
  final Color color;

  _IconPainter(this.canvas, this.color);

  Paint get _stroke => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1
    ..strokeCap = StrokeCap.butt
    ..isAntiAlias = true;

  /// 最小化：一条水平线
  void minimize(Color _) {
    canvas.drawLine(const Offset(0, 5), const Offset(10, 5), _stroke);
  }

  /// 最大化：圆角矩形
  void maximize(Color _) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0.5, 0.5, 9, 9),
        const Radius.circular(1.5),
      ),
      _stroke,
    );
  }

  /// 还原：两个错位的圆角矩形，表达「叠层窗口」
  void restore(Color _) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0.5, 3.5, 6, 6),
        const Radius.circular(1.5),
      ),
      _stroke,
    );
    final path = Path()
      ..moveTo(2.5, 3.5)
      ..lineTo(2.5, 2.5)
      ..arcToPoint(const Offset(4, 1), radius: const Radius.circular(1.5))
      ..lineTo(8.5, 1)
      ..arcToPoint(const Offset(10, 2.5), radius: const Radius.circular(1.5))
      ..lineTo(10, 7)
      ..arcToPoint(const Offset(8.5, 8.5), radius: const Radius.circular(1.5))
      ..lineTo(7, 8.5);
    canvas.drawPath(path, _stroke);
  }

  /// 关闭：一个 X
  void close(Color _) {
    canvas.drawLine(const Offset(0.5, 0.5), const Offset(9.5, 9.5), _stroke);
    canvas.drawLine(const Offset(9.5, 0.5), const Offset(0.5, 9.5), _stroke);
  }
}
