import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// 展开 / 收起的统一过渡参数。
///
/// 集中在一处，避免各分区各写一套时长与曲线（曾经出现过
/// 一处 160ms、一处 300ms，同一页里手感不一致）。
abstract final class CollapseSpec {
  /// 240ms：足够看清内容「从哪长出来」，又不至于等它。
  static const Duration duration = Duration(milliseconds: 240);

  /// 展开缓出、收起缓入 —— 收尾都变慢，不会「啪」地停住。
  static const Curve expandCurve = Curves.easeOutCubic;
  static const Curve collapseCurve = Curves.easeInCubic;

  /// 头部悬停高亮的时长（比展开动画短，跟手感走）
  static const Duration hoverDuration = Duration(milliseconds: 150);
}

/// 展开控件的两种外观。
enum CollapsibleVariant {
  /// **字段组**：分区内部的小号「更多设置 ▾」行。
  /// 用于把同一分区里的详细项收起来（外观的色调/背景图、下载的模板等）。
  field,

  /// **整区**：沿用分区标题那一行的样式，整块折叠。
  /// 用于「高级」这类整体都属于详细内容的卡片。
  section,
}

/// 可折叠分组：收起时只留一行头部 + 一行概要，点击后平滑展开。
///
/// ## 交互规格
///
/// | 项 | 规格 |
/// |---|---|
/// | **触发方式** | 整行头部都是点击热区（含箭头）；鼠标移上去有高亮底色 + 手型光标；键盘可用 Tab 聚焦后回车/空格 |
/// | **默认状态** | **收起**（[initiallyExpanded] 默认 `false`）；折叠态仍显示一行概要，写明组内当前值 |
/// | **再次点击** | 收起并回到同一行头部；展开态箭头向上、收起态向下 |
/// | **过渡效果** | 高度 + 淡入同时进行，240ms、easeOutCubic / easeInCubic；概要行与内容严格同步（共用同一个 controller，不存在「先长高再淡入」的错帧） |
/// | **展开后布局** | 内容在头部下方原地展开，**顶部对齐向下生长**（`axisAlignment: -1.0`），下方内容顺移，不遮挡、不覆盖 |
/// | **收起后的可用性** | 1) 概要行写明当前值；2) `modified` 为真时头部亮一个小圆点，提示「组内有已改动项」；3) 组内容**始终保留在树里**（只裁剪不销毁）→ 控制器、监听、自动保存逻辑照常工作 |
///
/// **为什么只裁剪不销毁**：组里的输入框控制器由各自的父 State 持有，
/// 一旦从树上摘除，`AccountSection` 会走 `dispose → initState`，
/// 未保存的 cookie、验证状态与「自动读剪贴板」副作用都会被重放一次。
/// 所以折叠只做视觉裁剪，功能链路完全不受影响。
class CollapsibleGroup extends StatefulWidget {
  /// 展开状态的存储键（`PageStorage`）：
  /// 切换页面不丢，**重启回到默认收起**。同一页里不能重复。
  final String storageId;

  final CollapsibleVariant variant;
  final String title;

  /// 头部左侧图标（`field` 变体默认用 `tune_rounded`）
  final IconData? icon;

  /// 收起时显示的一行概要 —— **把组内当前值写出来**，
  /// 让「收起」只是省地方，而不是把信息藏起来。
  final String? summary;

  /// 组内是否存在「非默认」设置：收起时在标题旁点一个品牌色小圆点。
  final bool modified;

  /// 默认是否展开。需求要求默认折叠，所以只有整区（`section`）在需要时才传 true。
  final bool initiallyExpanded;

  /// 条件成立时**自动展开**。
  ///
  /// 用于「原本收起、但现在变成必填」的字段：例如代理地址在
  /// 「启用代理 + 不使用系统代理」时就必需，此时自动把分组打开，
  /// 保证收起状态不会把必需项藏起来。
  final bool forceExpand;

  /// 收起 / 展开时右侧的动作文案
  final String expandLabel;
  final String collapseLabel;

  final List<Widget> children;

  const CollapsibleGroup({
    super.key,
    required this.storageId,
    required this.title,
    required this.children,
    this.variant = CollapsibleVariant.field,
    this.icon,
    this.summary,
    this.modified = false,
    this.initiallyExpanded = false,
    this.forceExpand = false,
    this.expandLabel = '展开',
    this.collapseLabel = '收起',
  });

  @override
  State<CollapsibleGroup> createState() => _CollapsibleGroupState();
}

class _CollapsibleGroupState extends State<CollapsibleGroup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// 0 = 收起，1 = 展开
  late final Animation<double> _t;

  /// 反向：概要行的高度因子（展开过程中同步收缩到 0）
  late final Animation<double> _reverseT;

  late bool _expanded;
  bool _hover = false;

  /// `didChangeDependencies` 会跑多次，只恢复一次
  bool _restored = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
    _controller = AnimationController(
      vsync: this,
      duration: CollapseSpec.duration,
      value: _expanded ? 1 : 0,
    );
    _t = CurvedAnimation(
      parent: _controller,
      curve: CollapseSpec.expandCurve,
      reverseCurve: CollapseSpec.collapseCurve,
    );
    _reverseT = ReverseAnimation(_t);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    // 恢复「本次会话内」的展开状态：切换页面回来时保持原样，重启后回到默认收起。
    final stored = PageStorage.maybeOf(context)?.readState(
      context,
      identifier: widget.storageId,
    );
    // forceExpand（组内含必填项）优先于记忆值 —— 不能把必填的东西藏在收起态里。
    final target = widget.forceExpand
        ? true
        : (stored is bool ? stored : _expanded);
    if (target != _expanded) {
      _expanded = target;
      _controller.value = target ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(CollapsibleGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 出现的瞬间才自动展开；用户之后手动收起就不再强行打开。
    if (widget.forceExpand && !oldWidget.forceExpand) {
      _setExpanded(true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _persist(bool value) {
    // 必填态（forceExpand）下不记忆：收起与否交给那个条件本身决定，
    // 否则「手动收起 → 切走再回来」会与「必填就得打开」互相打架。
    if (widget.forceExpand) return;
    PageStorage.maybeOf(context)?.writeState(
      context,
      value,
      identifier: widget.storageId,
    );
  }

  void _toggle() => _setExpanded(!_expanded);

  void _setExpanded(bool value) {
    if (value == _expanded) return;
    setState(() => _expanded = value);
    if (value) {
      _controller.forward();
    } else {
      _controller.reverse();
      _releaseFocusInside();
    }
    _persist(value);
  }

  /// 收起时若焦点正落在被隐藏的输入框上，先把焦点交出去 ——
  /// 否则键盘输入会继续送进一个看不见的框里。
  void _releaseFocusInside() {
    final focused = FocusManager.instance.primaryFocus;
    final ctx = focused?.context;
    if (ctx == null) return;
    var mine = false;
    ctx.visitAncestorElements((element) {
      if (element.widget is _CollapsibleContent) {
        mine = true;
        return false;
      }
      return true;
    });
    if (mine) focused?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(c),
        if (widget.summary != null)
          // 概要行与内容共用同一个 controller → 一个收缩、一个生长，同帧同步
          SizeTransition(
            // 键挂在 SizeTransition 上：它是「裁剪后的可见高度」，
            // 而里面的孩子仍保留自然高度（测试断言要用这个键，别用孩子）。
            key: ValueKey('collapsible-summary-anim-${widget.storageId}'),
            sizeFactor: _reverseT,
            alignment: Alignment.topCenter,
            child: _buildSummary(c, widget.summary!),
          ),
        SizeTransition(
          key: ValueKey('collapsible-content-anim-${widget.storageId}'),
          sizeFactor: _t,
          alignment: Alignment.topCenter,
          child: FadeTransition(
            opacity: _t,
            child: _CollapsibleContent(
              key: ValueKey('collapsible-content-${widget.storageId}'),
              id: widget.storageId,
              ignorePointer: !_expanded,
              excludeSemantics: !_expanded,
              tickerEnabled: _expanded,
              child: Padding(
                padding: EdgeInsets.only(
                  top: widget.variant == CollapsibleVariant.field ? 10 : 18,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: widget.children,
                ),
              ),
            ),
          ),
        ),
      ],
    );

    if (widget.variant == CollapsibleVariant.section) {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.surfaceCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.line),
        ),
        child: body,
      );
    }
    return body;
  }

  // ── 头部 ────────────────────────────────────────────────────

  Widget _buildHeader(AppColors c) {
    final isSection = widget.variant == CollapsibleVariant.section;

    return Semantics(
      button: true,
      expanded: _expanded,
      label:
          '${widget.title}，${_expanded ? '已展开，点击收起' : '已收起，点击展开'}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          // 悬停高亮比文字宽 10px（左右各 10）向外铺开 ——
          // 用 Stack + 负偏移来画，而不是给容器加负 margin
          // （AnimatedContainer 的 margin 不允许为负，会直接断言失败）。
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: -10,
                right: -10,
                top: 0,
                bottom: 0,
                child: AnimatedContainer(
                  duration: CollapseSpec.hoverDuration,
                  decoration: BoxDecoration(
                    color: _hover ? c.surfaceCardHover : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      widget.icon ??
                          (isSection
                              ? Icons.settings_rounded
                              : Icons.tune_rounded),
                      size: isSection ? 17 : 15,
                      color: c.accentText,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isSection ? 15 : 12.5,
                          fontWeight:
                              isSection ? FontWeight.w600 : FontWeight.w500,
                          color: c.textStrong,
                        ),
                      ),
                    ),
                    if (widget.modified) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: t('组内有已改动的设置'),
                        waitDuration: const Duration(milliseconds: 300),
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: c.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        // collapseLabel 只有裸中文默认值（从没调用方传过）→ 在这里翻；
                        // expandLabel 各调用方传的已是 t('展开设置')，不能再套一层。
                        _expanded ? t(widget.collapseLabel) : widget.expandLabel,
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 11.5, color: c.textFaint),
                      ),
                    ),
                    const SizedBox(width: 2),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: CollapseSpec.duration,
                      curve: _expanded
                          ? CollapseSpec.expandCurve
                          : CollapseSpec.collapseCurve,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: _expanded ? c.accentText : c.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummary(AppColors c, String text) {
    final leftPad = widget.variant == CollapsibleVariant.section ? 25.0 : 23.0;
    return Padding(
      padding: EdgeInsets.only(left: leftPad, right: 4, top: 2, bottom: 2),
      child: Text(
        text,
        key: ValueKey('collapsible-summary-${widget.storageId}'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: c.textFaint, height: 1.5),
      ),
    );
  }
}

/// 折叠内容的包装层：负责在收起时屏蔽指针 / 语义 / 动画时钟。
///
/// 单独成类是为了让 [CollapsibleGroup] 能在收起时
/// 沿祖先链认出「焦点是否落在自己肚子里」。
class _CollapsibleContent extends StatelessWidget {
  final String id;
  final Widget child;
  final bool ignorePointer;
  final bool excludeSemantics;
  final bool tickerEnabled;

  const _CollapsibleContent({
    super.key,
    required this.id,
    required this.child,
    required this.ignorePointer,
    required this.excludeSemantics,
    required this.tickerEnabled,
  });

  @override
  Widget build(BuildContext context) {
    // 三层各带一个键：测试要能确定地拿到「我这一层」，
    // 而不是靠 ancestor 去猜哪一个才是本组件加的。
    return IgnorePointer(
      key: ValueKey('collapsible-ignore-$id'),
      ignoring: ignorePointer,
      child: ExcludeSemantics(
        key: ValueKey('collapsible-semantics-$id'),
        excluding: excludeSemantics,
        // 收起时不跑里面的动画/计时器，省电也避免「看不见的地方在动」
        child: TickerMode(
          key: ValueKey('collapsible-ticker-$id'),
          enabled: tickerEnabled,
          child: child,
        ),
      ),
    );
  }
}
