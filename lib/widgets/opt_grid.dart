import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 预览稿的 **2×2 当前值网格** —— `.grid.g2` + `.opt` 的 Flutter 对应物。
///
/// 「所见即所得」的关键件：设置项把**当前值**直接摊在卡片上，一眼看完，
/// 不用逐个点开。设计稿 §2.1/§2.2 的每张卡都有它。
///
/// ### 规格出处（`tools/ui/_redesign/preview/app.css`）
///
/// ```
/// :157 .grid { display:grid; gap:8px; }
/// :158 .g2   { grid-template-columns: 1fr 1fr; }
/// :160 .opt  { padding:9px 11px; border-radius:9px; }
/// :161 .opt .k { font-size:10px; letter-spacing:.3px; opacity:.55; margin-bottom:3px; }
/// :162 .opt .v { font-size:12.5px; font-weight:550; display:flex; align-items:center; gap:6px; }
/// :163 .opt .v .c { margin-left:auto; opacity:.45; font-size:9px; }
/// ```
///
/// 方块底色用 `c.surfaceSunken` —— CSS 里 `.opt` 与 `.sw` / `.field` 同在
/// 「卡片内的凹陷块」一组（`:274` 那批 `border-radius:9px`），三套风格
/// 都从 `surfaceSunken` 取同一种凹陷关系，组件因此不判断风格。
///
/// ### 字重偏离：CSS 550 → [FontWeight.w500]
///
/// Flutter 的 `FontWeight` 只有 w100–w900 整百常量，没有 550（`w550`
/// 是编译期错误，不是"更精细的档位"）。仓库既有 79 处字重全部只用整百。
/// 规则取**向下整百**：550→w500、650→w600、680→w600。理由是这些半百值
/// 都用在「比正文稍重」的位置，而中文粗体取重一档（550→w600）会和真正的
/// 小标题糊成一层；取轻一档至少保住与 w400 正文的区分。
///
/// ### 交互：点值弹选择器
///
/// 预览稿是静态值 + 右侧那个 `▾`（`opacity:.45`）暗示可改。Flutter 里
/// 点整格弹出选择器：这就是 [showOptPicker]。S9a 阶段只做「能弹、能选、
/// 能回调」，S9b 再接真数据。
///
/// **泛型 `T`**：选项不限于字符串。S9b 的「画质 / 编码 / 主题模式」都是
/// 枚举，所以这里按 [OptItem] 的类型参数走，选中后回传强类型的值。
///
/// ### 2026-10-15：选择器改成**贴着那一格**弹（S9c 真机缺陷修复）
///
/// 真机反馈：「第三张图点击后，为什么内容是在最下面弹出来的」。
/// 原来的实现是 [showModalBottomSheet] —— 浮层从屏幕最底部滑上来，与被点
/// 的那一格隔着半个屏幕，视觉上断成两截。
///
/// 现在改用 [showGeneralDialog] + 按锚点 rect 定位的浮层：`OptGrid.build`
/// 把**被点那一格自己的 context** 传进来（经 `_rectOf` 取 rect），所以同屏
/// 有多个 OptGrid 时每一格都知道自己该贴谁。锚点缺省（外部调用方没传）时
/// 按屏幕中心落位，不会崩、也没有行为退化。
class OptGrid<T> extends StatelessWidget {
  /// 每一项的（键名, 当前值, 候选值）。键名已由调用方 `t()` 过。
  final List<OptItem<T>> items;

  /// 给了才能交互；null = 纯展示（预览稿里也有一些只读的当前值）。
  final void Function(OptItem<T> item, T value)? onChanged;

  /// **接管某一格的点击**，不再弹内置的 [showOptPicker]。
  ///
  /// 为什么需要它（2026-10-13 S9b 补的）：设置页的「窗口材质 / 导航形态 / 界面
  /// 语言 / 主题模式」四项各自有一个**带缩略图或分段的富选择器**
  /// （`MaterialPicker` / `NavLayoutPicker` / `_LocalePicker` / `_ThemeModePicker`），
  /// 它们不能被一串纯文本候选顶掉 —— `appearance_controls_test` 的四条判据
  /// （材质缩略图互异、语言与主题各是一组分段控件）正是钉在那些控件上的。
  /// 于是格子仍然平铺当前值（预览稿 `.opt` 的语义），点开时弹出的却是那一个
  /// 富选择器：同一格、同一份数据，只是候选列表长了图。
  ///
  /// 返回 true 表示「这一格我自己处理了」；false / 不返回则退回内置选择器。
  /// null = 全部走内置（S9a 以来的默认行为，未改动）。
  final bool Function(OptItem<T> item)? onTapCell;

  /// 当前值的展示文本。null = `toString()`（对 String 恰好就是自身）。
  ///
  /// 枚举走 `toString()` 会印出 `BiliQuality.q1080` 这种带类名的串，所以
  /// 调用方要么传本函数，要么把 [OptItem] 建成「显示串 + 值」两层。
  final OptLabelOf<T>? labelOf;

  const OptGrid({
    super.key,
    required this.items,
    this.onChanged,
    this.onTapCell,
    this.labelOf,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return GridView(
      // 嵌入卡片内部，不能自己滚 —— 外层页面负责滚动。
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      // **高度固定，不按宽高比**（2026-10-15 修）。
      //
      // 原来用 `GridView.count(childAspectRatio: 3.0)` —— 那是个按**栏宽**
      // 算高度的比例：格子宽 196 时高 65（合适），但同一个组件放进整页宽的
      // 模块设置页（格子宽约 486）时高度就变成 162，格子里只有顶上一条有字、
      // 下面全是空白。真机上就是这么被看出来的。
      //
      // 格子的高度本来就该由**内容**决定（k 行 14 + 间距 3 + v 行 18 +
      // 上下 padding 18 ≈ 53），与栏宽无关，所以改成固定 `mainAxisExtent`。
      // 内容实测 53px，给 66px 留一行余量（与原来 400px 栏宽下的取值一致）。
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        mainAxisExtent: 66,
      ),
      children: [
        for (final item in items)
          _OptCell<T>(
            colors: c,
            item: item,
            label: labelOf == null ? null : labelOf!(item.value),
            onTap: onChanged == null
                ? null
                : () async {
                    // 富选择器优先：调用方自己弹（材质 / 导航 / 语言 / 主题）。
                    if (onTapCell != null && onTapCell!(item)) return;
                    final picked = await showOptPicker<T>(
                      context,
                      title: item.label,
                      options: item.options,
                      current: item.value,
                      labelOf: labelOf,
                      // **被点那一格自己的 context** —— 同屏多个 OptGrid
                      // （B 站页三个、抖音页两个）时，锚点必须由它提供，
                      // 不能取页面上随便一格。
                      anchorRect: _rectOf(context),
                    );
                    if (picked != null) onChanged!(item, picked);
                  },
          ),
      ],
    );
  }
}

/// 网格里的一格：键名 + 当前值 + chevron。
class OptItem<T> {
  /// 键名（如「画质上限」）。已 `t()` 过。
  final String label;

  /// 当前值。同时是选择器里的"当前项"。
  final T value;

  /// 候选值。点格子时整份交给 [showOptPicker]。
  final List<T> options;

  const OptItem({
    required this.label,
    required this.value,
    this.options = const [],
  });
}

class _OptCell<T> extends StatelessWidget {
  final AppColors colors;
  final OptItem<T> item;
  final VoidCallback? onTap;

  /// 已算好的展示文本（[OptGrid.labelOf] 的产物）。null = 退回 `toString()`。
  final String? label;

  const _OptCell({
    required this.colors,
    required this.item,
    this.onTap,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.3,
                  color: c.textMuted.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label ?? _labelOf(item.value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        // CSS `.opt .v` 是 550，向下取整百（见类文档）
                        fontWeight: FontWeight.w500,
                        color: c.textStrong,
                      ),
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 6),
                    // CSS `:163` `.opt .v .c { margin-left:auto; opacity:.45; font-size:9px; }`
                    // —— 预览稿用的是字符 ▾，这里换 Material 的展开箭头，
                    // 同一个「可改」的语义（图标是框架资源，不引入写死色值）。
                    Icon(Icons.expand_more,
                        size: 14, color: c.textMuted.withValues(alpha: 0.45)),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选项的展示文本。null = 用 `toString()`（对 String 恰好就是自身）。
typedef OptLabelOf<T> = String Function(T value);

String _labelOf<T>(T v) => v.toString();

/// 某一格在**屏幕坐标**里的矩形（宽高都返回 0 表示「取不到」）。
///
/// 只在手势回调里调用（此时 layout 已完成）。`_OptCell` 自己那层 context
/// 指向 `Container`，拿到的是格子的 rect；取不到（元素已卸载 / 刚重建）
/// 就返回 0×0，调用方据此退回屏幕中心，绝不抛。
Rect _rectOf(BuildContext context) {
  final ro = context.findRenderObject();
  if (ro is! RenderBox) return Rect.zero;
  final size = ro.size;
  final topLeft = ro.localToGlobal(Offset.zero);
  return Rect.fromLTWH(topLeft.dx, topLeft.dy, size.width, size.height);
}

/// 浮层相对锚点的落位结果（私有小工具，见 [showOptPicker]）。
class _AnchorPlacement {
  const _AnchorPlacement({required this.left, required this.top, required this.availableHeight});

  final double left;
  final double top;
  final double availableHeight;
}

/// 贴格浮层的定位：优先落在锚点**下方**，下方不够且上方更宽裕时翻到上方，
/// 两边都不够时退回贴着锚点（面板自身可滚 + 高度受限，永不溢出屏幕）。
///
/// [screen] 是 `MediaQuery.sizeOf(context)`，[anchor] 是被点格子的屏幕 rect。
_AnchorPlacement _placeAnchored({
  required Size screen,
  required Rect anchor,
  required double panelWidth,
  required double sheetMaxHeight,
  required double gap,
  required double bottomMargin,
}) {
  final hasAnchor = anchor.width > 0 && anchor.height > 0;
  // 缺省锚点（外部调用方没传，或 context 已失效）：退到屏幕中心，
  // 行为等价于「一个居中的浮层」，不崩也不算视觉退化。
  final cx = hasAnchor ? anchor.center.dx : screen.width / 2;
  final cy = hasAnchor ? anchor.center.dy : screen.height / 2;

  double clampLeft() =>
      cx.clamp(panelWidth / 2, math.max(screen.width - panelWidth / 2, panelWidth / 2)) -
      panelWidth / 2;

  final below = screen.height - (cy + anchor.height / 2) - gap - bottomMargin;
  // 高度必须 ≤ sheetMaxHeight，用完整判定而不是简单截断，否则当
  // below < sheetMaxHeight 但按 anchor 高度算出来的值 > sheetMaxHeight 时
  // 面板会顶破屏幕底部（2026-10-15 撞过：面板超出 viewport 后 tester 取不到
  // 自己的面板 rect，判据跟着 flake）。
  final belowH = math.min(below, sheetMaxHeight);
  if (belowH >= _kOptPickerMinHeight) {
    return _AnchorPlacement(left: clampLeft(), top: cy + anchor.height / 2 + gap, availableHeight: belowH);
  }

  final above = (cy - anchor.height / 2) - gap - bottomMargin;
  final aboveH = math.min(above, sheetMaxHeight);
  if (aboveH >= _kOptPickerMinHeight) {
    // 面板底边贴在锚点上方 gap 处 → top = 锚点顶边 - gap - 面板高。
    return _AnchorPlacement(
      left: clampLeft(),
      top: (cy - anchor.height / 2) - gap - aboveH,
      availableHeight: aboveH,
    );
  }

  // 上下都放不下：贴着锚点下方、只给一屏内剩下那么多高度，面板内部滚动。
  final fallbackH = math.max(_kOptPickerMinHeight, screen.height - bottomMargin - gap);
  return _AnchorPlacement(
    left: clampLeft(),
    top: math.min(cy + anchor.height / 2 + gap, math.max(bottomMargin, screen.height - fallbackH - bottomMargin)),
    availableHeight: fallbackH,
  );
}

/// 面板高度下限：低于它就不值得翻到锚点上/下方之外的位置（候选值大多是
/// 四五个短词，十几个就够放下）。
const double _kOptPickerMinHeight = 56;

/// 浮层与屏幕底部的安全边距。
const double _kOptPickerBottomMargin = 12;

/// 浮层与被点格子之间的间隙。
const double _kOptPickerGap = 6;

/// 「当前值 + 候选列表」—— [OptGrid] 点值后弹出的选择器。
///
/// 返回选中的值；取消 / 点遮罩返回 null（调用方据此不改任何东西）。
///
/// **为什么是自绘浮层而不是 dropdown / bottom sheet**：应用的 dropdown 展开层
/// 取色是 `Theme.of(context).canvasColor`（SDK `dropdown.dart:341`），而这个
/// 项目的窗口是透出身材质 + `scaffoldBackgroundColor: transparent` 的 ——
/// dropdown 的菜单会变成一块与卡片无关的实色面板，在毛玻璃上很突兀
/// （2026-10-11 真机撞过同一个毛病，`app_theme.dart:330` 记着）。自绘浮层
/// 自己管底色，与其余浮层一致。
///
/// ### 2026-10-15 从 bottom sheet 改为贴格浮层（真机反馈）
///
/// 原来用 [showModalBottomSheet]：浮层从屏幕最底部滑上来，与被点的那一格
/// 隔着半个屏幕。现在 [showGeneralDialog]（`barrierDismissible: true` +
/// 半透明遮罩 + 淡入轻缩放过渡），内容用 [Align] 按 [anchorRect] 定位 ——
/// 见 [_placeAnchored]。
///
/// 观察到的现状：面板观感（`Material(color: c.surfaceFloat)` + 圆角 +
/// [ListTile] + `c.accentText` 选型高亮与末尾对勾）、导航语义（点候选
/// `Navigator.pop(ctx, opt)` 带回值、点遮罩/返回键返回 null）、
/// `BoxConstraints(maxWidth: 460)` 的宽度上限全部保留。
///
/// ### 容器是 `Material` 而不是 `DecoratedBox`（S9b 修）
///
/// 原来用带底色的 `DecoratedBox` 包住列表，SDK 的 [ListTile] 在 debug 下会报
/// 「ListTile background color or ink splashes may be invisible」
/// （`list_tile.dart` 的 `_debugCheckBackgroundIsHidden`）：它向上找最近的
/// 有底色祖先，找到一个就断定「ListTile 自己的底色与水波纹会被挡掉」。
/// 这条判断本身没错 —— ListTile 的底色与水波纹确实画在最近的 `Material` 上。
/// 按 SDK 给的提示换成本 `Material`（`color` 就是原来那个底色）之后，
/// ListTile 的最近 Material 祖先就是它自己那层，遮挡消失、水波纹也真的落在
/// 这块面板上。`Material` 同时承担圆角裁切（`clipBehavior`），不再需要
/// `DecoratedBox` 的 border 补边。
Future<T?> showOptPicker<T>(
  BuildContext context, {
  required String title,
  required T current,
  List<T> options = const [],
  OptLabelOf<T>? labelOf,
  Rect? anchorRect,
}) async {
  final c = AppTheme.colorsOf(context);
  final list = options.isEmpty ? <T>[current] : options;
  String label(T v) => labelOf == null ? v.toString() : labelOf(v);

  final picked = await showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // 遮罩取色板的 `scrim` 槽位：**它必须压暗背景**。
    //
    // 2026-10-15 真机撞过反例：这里原先写的是 `c.textMuted.withValues(alpha: .55)`，
    // 而深色主题的 `textMuted` 是 #BCBCBC 的浅灰 —— 55% 浅灰盖上去，整个界面
    // 罩成一层发白的雾。实测同一块侧栏平均亮度 44.4 → 126.8（2.86 倍），
    // 与「把背景退下去」正好相反，用户一眼就看出不对。
    //
    // 也不能写 `Colors.black`：`visual_tokens_test` 的棘轮只豁免 `lib/theme/`
    // 内的写死色值（本文件 S9b 阶段为同一个原因栽过一次）。所以取槽位。
    barrierColor: c.scrim,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (ctx, _, _) {
      final screen = MediaQuery.sizeOf(ctx);
      final media = MediaQuery.of(ctx);
      // 面板自身可滚、且不溢出屏幕：高度受「锚点邻域」和整屏各夹一次，
      // 取更紧的那个，底部再留安全边距。
      final sheetMaxHeight = math.max(
        _kOptPickerMinHeight,
        math.min(media.size.height / 2 + 80, media.size.height - _kOptPickerBottomMargin),
      );
      final placement = _placeAnchored(
        screen: screen,
        anchor: anchorRect ?? Rect.zero,
        panelWidth: math.min(460.0, screen.width),
        sheetMaxHeight: sheetMaxHeight,
        gap: _kOptPickerGap,
        bottomMargin: _kOptPickerBottomMargin,
      );

      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(
            left: placement.left,
            top: placement.top,
            right: math.max(0.0, screen.width - placement.left - math.min(460.0, screen.width)),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 460,
              maxHeight: placement.availableHeight,
            ),
            child: Material(
              color: c.surfaceFloat,
              clipBehavior: Clip.antiAlias,
              borderRadius: const BorderRadius.all(Radius.circular(14)),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: c.textStrong,
                        ),
                      ),
                    ),
                    Divider(height: 1, thickness: 0.5, color: c.line),
                    Flexible(
                      child: ListView(
                        key: const ValueKey('_optPickerBody'),
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        children: [
                          for (final opt in list)
                            ListTile(
                              dense: true,
                              title: Text(
                                label(opt),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: opt == current || _same(opt, current)
                                      ? c.accentText
                                      : c.textNormal,
                                  fontWeight:
                                      opt == current || _same(opt, current)
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                ),
                              ),
                              trailing: opt == current || _same(opt, current)
                                  ? Icon(Icons.check, size: 16, color: c.accentText)
                                  : null,
                              onTap: () => Navigator.pop(ctx, opt),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, animation, _, child) {
      final eased = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: eased,
        child: ScaleTransition(
          // 缩放支点固定左上：与浮层「从被点那格长出来」的方向一致。
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(eased),
          alignment: Alignment.topLeft,
          child: child,
        ),
      );
    },
  );
  return picked;
}

/// 泛型相等判断：枚举是单例，`==` 即可；但 `T` 可能是不可比较的类型，
/// 用 `identical` 兜一次能省掉调用方为每个选项实现 `==`。
bool _same<T>(T a, T b) {
  try {
    return a == b;
  } catch (_) {
    return identical(a, b);
  }
}
