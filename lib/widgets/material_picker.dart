import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../theme/window_material.dart';

/// 档位的中文副标题 —— 参照物 XAML 里每格右侧的第二行文字。
///
/// **不能塞进 [WindowMaterial]**：`test/l10n_test.dart` 要求枚举的
/// label / description 是纯英文（含汉字会被判成漏翻），所以副标题在 UI 层
/// 用 `t('…')` 表达，逐档映射在这里。逐字照抄
/// `TubaWinUi3.WinUI3/Pages/SettingsPage.xaml:538/551/565/579`。
String materialSubtitleOf(WindowMaterial material) => switch (material) {
      WindowMaterial.mica => t('柔和云母'),
      WindowMaterial.micaAlt => t('层次云母'),
      WindowMaterial.acrylic => t('磨砂玻璃'),
      WindowMaterial.acrylicThin => t('更透亮的磨砂'),
    };

/// 一块 48×32 的材质预览 —— 四档的层数与 margin 各不相同。
///
/// 规格数据在 `theme/window_material.dart`（[materialPreviewSpecOf]）：
/// 那里是视觉令牌层，写死色值不会被色板棘轮拦；本组件只负责画。
class MaterialPreviewSwatch extends StatelessWidget {
  final WindowMaterial material;

  const MaterialPreviewSwatch({super.key, required this.material});

  @override
  Widget build(BuildContext context) {
    final spec = materialPreviewSpecOf(material);

    // RepaintBoundary：四格各自独立重绘（悬停只重绘一格），
    // 也让「四档预览是否真的不同」能在测试里逐格取像素。
    return RepaintBoundary(
      child: Container(
        width: 48,
        height: 32,
        decoration: BoxDecoration(
          color: spec.resolveBase(),
          borderRadius: BorderRadius.circular(4),
        ),
        child: spec.layers.isEmpty ? null : _nest(spec.layers, 0),
      ),
    );
  }

  /// 从外到内套 `Container(margin:)`；最内层不带 child，会撑满父约束。
  Widget _nest(List<MaterialPreviewLayer> layers, int i) {
    final layer = layers[i];
    return Container(
      margin: EdgeInsets.all(layer.margin),
      decoration: BoxDecoration(
        color: layer.color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: i + 1 < layers.length ? _nest(layers, i + 1) : null,
    );
  }
}

/// 窗口材质选择格 —— 2×2，照抄图吧工具箱「窗口材质」卡
/// （`TubaWinUi3.WinUI3/Pages/SettingsPage.xaml:520-583`）。
///
/// 规格逐值搬过来：
///   * 网格 RowSpacing / ColumnSpacing = 8，两行两列各占一等份；
///   * 每格 CornerRadius 8、BorderThickness **固定 2**、Padding 12,8 ——
///     选中只换边框颜色（强调色），未选中用次要描边，宽度不变；
///   * 悬停整格 Opacity 0.85（参照物 PointerEntered / PointerExited）；
///   * 格内横向排列、间距 8、整体居中：48×32 预览块 + 右侧两行 12px 文字。
class MaterialPicker extends StatelessWidget {
  final WindowMaterial value;
  final ValueChanged<WindowMaterial> onChanged;

  const MaterialPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 参照物是固定 2×2（`Grid` 两行两列各 `*`）。窄到两列放不下时退成
        // 一列 —— 同页的 NavLayoutPicker / AccentPicker 也是这个阈值行为，
        // 保证文字不被挤成一串省略号。
        final twoCol = constraints.maxWidth >= 300;
        final items = WindowMaterial.values;

        Widget tile(WindowMaterial m) => _MaterialTile(
              material: m,
              selected: m == value,
              onTap: () => onChanged(m),
            );

        if (!twoCol) {
          return Column(
            children: [
              for (var i = 0; i < items.length; i++)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: i == items.length - 1 ? 0 : 8,
                  ),
                  child: tile(items[i]),
                ),
            ],
          );
        }

        final rows = <List<WindowMaterial>>[
          for (var i = 0; i < items.length; i += 2)
            items.sublist(i, i + 2 <= items.length ? i + 2 : items.length),
        ];

        return Column(
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < rows[r].length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(child: tile(rows[r][i])),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _MaterialTile extends StatefulWidget {
  final WindowMaterial material;
  final bool selected;
  final VoidCallback onTap;

  const _MaterialTile({
    required this.material,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_MaterialTile> createState() => _MaterialTileState();
}

class _MaterialTileState extends State<_MaterialTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final m = widget.material;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          selected: widget.selected,
          label: tf('{label}（{desc}）', {
            'label': t(m.label),
            'desc': materialSubtitleOf(m),
          }),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: _hover ? 0.85 : 1,
            child: AnimatedContainer(
              key: ValueKey('material-tile-${m.id}'),
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: c.surfaceCard,
                borderRadius: BorderRadius.circular(8),
                // 边框宽度恒为 2，选中只换颜色 —— 否则选中时整格会跳一下。
                border: Border.all(
                  color: widget.selected ? c.accent : c.line,
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  MaterialPreviewSwatch(
                    key: ValueKey('material-preview-${m.id}'),
                    material: m,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t(m.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: c.textStrong,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          materialSubtitleOf(m),
                          maxLines: 1,
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
      ),
    );
  }
}