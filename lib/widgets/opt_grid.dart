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
class OptGrid<T> extends StatelessWidget {
  /// 每一项的（键名, 当前值, 候选值）。键名已由调用方 `t()` 过。
  final List<OptItem<T>> items;

  /// 给了才能交互；null = 纯展示（预览稿里也有一些只读的当前值）。
  final void Function(OptItem<T> item, T value)? onChanged;

  const OptGrid({super.key, required this.items, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return GridView.count(
      // 嵌入卡片内部，不能自己滚 —— 外层页面负责滚动。
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      // 内容实测高约 53px（k 行 14 + 3 + v 行 18 + 上下 padding 18）；
      // 400px 宽的 pane 每格 196，196 / 3.0 ≈ 65 留一行余量防截断。
      childAspectRatio: 3.0,
      children: [
        for (final item in items)
          _OptCell<T>(
            colors: c,
            item: item,
            onTap: onChanged == null
                ? null
                : () async {
                    final picked = await showOptPicker<T>(
                      context,
                      title: item.label,
                      options: item.options,
                      current: item.value,
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

  const _OptCell({
    required this.colors,
    required this.item,
    this.onTap,
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
                      _labelOf(item.value),
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

/// 「当前值 + 候选列表」—— [OptGrid] 点值后弹出的选择器。
///
/// 返回选中的值；取消 / 点遮罩返回 null（调用方据此不改任何东西）。
///
/// **为什么是 bottom sheet 而不是 dropdown**：应用的 dropdown 展开层取色是
/// `Theme.of(context).canvasColor`（SDK `dropdown.dart:341`），而这个项目的
/// 窗口是透出身材质 + `scaffoldBackgroundColor: transparent` 的 ——
/// dropdown 的菜单会变成一块与卡片无关的实色面板，在毛玻璃上很突兀
/// （2026-10-11 真机撞过同一个毛病，`app_theme.dart:330` 记着）。
/// bottom sheet 自己管底色，与其余浮层一致。
Future<T?> showOptPicker<T>(
  BuildContext context, {
  required String title,
  required T current,
  List<T> options = const [],
  OptLabelOf<T>? labelOf,
}) async {
  final c = AppTheme.colorsOf(context);
  final list = options.isEmpty ? <T>[current] : options;
  String label(T v) => labelOf == null ? v.toString() : labelOf(v);

  final picked = await showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    // 内容短，别让 sheet 拖到半屏 —— 候选值大多是四五个短词。
    constraints: const BoxConstraints(maxWidth: 460),
    builder: (ctx) => Container(
      decoration: BoxDecoration(
        color: c.surfaceFloat,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
        border: Border.all(color: c.line),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: c.textStrong,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 0.5, color: c.line),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final opt in list)
                    ListTile(
                      dense: true,
                      title: Text(
                        label(opt),
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
