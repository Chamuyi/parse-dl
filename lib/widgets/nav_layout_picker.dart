import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../theme/window_material.dart';

/// 导航形态选择器。
///
/// 两张卡片并列，左侧是一张**微缩示意图**（一眼看出导航在窗口里的位置与形状），
/// 右侧是名称与说明，选中时套主题色描边并发光 —— 与窗口材质选择器同一套视觉语言。
class NavLayoutPicker extends StatelessWidget {
  final NavLayout value;
  final ValueChanged<NavLayout> onChanged;

  const NavLayoutPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 窄屏一列，宽屏两列（阈值与材质选择器一致）
        final twoCol = constraints.maxWidth >= 520;
        final items = NavLayout.values;

        if (!twoCol) {
          return Column(
            children: [
              for (final l in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _LayoutTile(
                    layout: l,
                    selected: l == value,
                    onTap: () => onChanged(l),
                  ),
                ),
            ],
          );
        }

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final l in items)
              SizedBox(
                width: (constraints.maxWidth - 10) / 2,
                child: _LayoutTile(
                  layout: l,
                  selected: l == value,
                  onTap: () => onChanged(l),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LayoutTile extends StatefulWidget {
  final NavLayout layout;
  final bool selected;
  final VoidCallback onTap;

  const _LayoutTile({
    required this.layout,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_LayoutTile> createState() => _LayoutTileState();
}

class _LayoutTileState extends State<_LayoutTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final selected = widget.selected;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          selected: selected,
          label: tf('{label}（{desc}）', {
            'label': t(widget.layout.label),
            'desc': t(widget.layout.description),
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(10),
            decoration: selected
                ? selectedDecoration(c)
                : BoxDecoration(
                    color: _hover ? c.surfaceCardHover : c.surfaceCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _hover ? c.lineStrong : c.line,
                      width: 1,
                    ),
                  ),
            child: Row(
              children: [
                _LayoutPreview(layout: widget.layout),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              t(widget.layout.label),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                color: c.textStrong,
                              ),
                            ),
                          ),
                          if (selected) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.check_rounded,
                                size: 13, color: c.accentText),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t(widget.layout.description),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: c.textMuted),
                      ),
                    ],
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

/// 微缩示意图：一个「窗口」+ 导航所在位置的色块。
///
/// 只画位置关系，不画具体图标 —— 用户一眼就能分辨
/// 「贴底一条」与「贴左一列」的区别，这才是这个选项的关键差异。
class _LayoutPreview extends StatelessWidget {
  final NavLayout layout;

  const _LayoutPreview({required this.layout});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Container(
      width: 64,
      height: 44,
      decoration: BoxDecoration(
        // 窗口底色：比卡片更深一层，模拟「窗口里的一块屏幕」
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            // 标题栏位置的细条（两种形态都有，说明导航在标题栏之下）
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(height: 6, color: c.lineSoft),
            ),

            if (layout == NavLayout.dock)
              // 底部居中一条悬浮导航
              Positioned(
                left: 12,
                right: 12,
                bottom: 5,
                child: Container(
                  height: 11,
                  decoration: BoxDecoration(
                    color: c.surfaceFloat,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: c.line),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _TinySquare(active: true),
                      SizedBox(width: 2),
                      _TinySquare(),
                      SizedBox(width: 2),
                      _TinySquare(),
                    ],
                  ),
                ),
              )
            else
              // 左侧通高一列
              Positioned(
                left: 0,
                top: 6,
                bottom: 0,
                child: Container(
                  width: 15,
                  decoration: BoxDecoration(
                    color: c.surfaceFloat,
                    border: Border(right: BorderSide(color: c.line)),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      SizedBox(height: 4),
                      _TinySquare(active: true, wide: true),
                      SizedBox(height: 2),
                      _TinySquare(wide: true),
                      SizedBox(height: 2),
                      _TinySquare(wide: true),
                    ],
                  ),
                ),
              ),

            // 内容区示意（几条占位横线），表明导航没有压住内容
            Positioned(
              left: layout == NavLayout.dock ? 8 : 22,
              right: 8,
              top: 14,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 3,
                    width: 26,
                    decoration: BoxDecoration(
                      color: c.lineStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    height: 3,
                    width: 34,
                    decoration: BoxDecoration(
                      color: c.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 示意图里的一个「导航项」小方块
class _TinySquare extends StatelessWidget {
  final bool active;
  final bool wide;

  const _TinySquare({this.active = false, this.wide = false});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Container(
      width: wide ? 7 : 5,
      height: 5,
      decoration: BoxDecoration(
        color: active ? c.accent : c.lineStrong,
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
  }
}
