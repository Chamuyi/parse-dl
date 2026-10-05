import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../theme/window_material.dart';

/// 窗口材质选择器。
///
/// 对应原设置页里的四材质 + 纯色卡片。
/// 每张卡片左侧是材质预览色板（跟随当前明暗取色），右侧是名称与说明，
/// 选中时套一圈主题色描边并发光。
class MaterialPicker extends StatelessWidget {
  final WindowMaterial value;
  final Brightness brightness;
  final ValueChanged<WindowMaterial> onChanged;

  const MaterialPicker({
    super.key,
    required this.value,
    required this.brightness,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽屏两列，窄屏一列
        final twoCol = constraints.maxWidth >= 520;
        final items = WindowMaterial.values;

        if (!twoCol) {
          return Column(
            children: [
              for (final m in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _MaterialTile(
                    material: m,
                    selected: m == value,
                    brightness: brightness,
                    onTap: () => onChanged(m),
                  ),
                ),
            ],
          );
        }

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final m in items)
              SizedBox(
                width: (constraints.maxWidth - 10) / 2,
                child: _MaterialTile(
                  material: m,
                  selected: m == value,
                  brightness: brightness,
                  onTap: () => onChanged(m),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MaterialTile extends StatefulWidget {
  final WindowMaterial material;
  final bool selected;
  final Brightness brightness;
  final VoidCallback onTap;

  const _MaterialTile({
    required this.material,
    required this.selected,
    required this.brightness,
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
    final selected = widget.selected;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
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
              _PreviewSwatch(
                material: widget.material,
                brightness: widget.brightness,
              ),
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
                            t(widget.material.label),
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
                      t(widget.material.description),
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
    );
  }
}

/// 材质缩略图：一小块「桌面壁纸 + 盖在上面的材质薄片」。
///
/// 之前是「两个灰条加一个点」，五种材质画得一模一样，最该用图说话的
/// 细微差别完全没表达出来。现在把三件真实的差异画出来：
///   - **透出多少壁纸**（[WindowMaterial.seeThrough]）：纯色全遮死，
///     细亚克力几乎全透；
///   - **磨砂**（[WindowMaterial.blur]）：亚克力系会把背后的壁纸糊掉，
///     再撒一层颗粒；
///   - **分层**（[WindowMaterial.layered]）：Mica Alt 特有的那道上下接缝。
/// 薄片四周各留 4px 不盖，露出壁纸原样当参照物，透不透才看得出来。
class _PreviewSwatch extends StatelessWidget {
  final WindowMaterial material;
  final Brightness brightness;

  const _PreviewSwatch({
    required this.material,
    required this.brightness,
  });

  @override
  Widget build(BuildContext context) {
    final sheet = material.previewFor(brightness);
    final opacity = 1 - material.seeThrough;
    // 磨砂颗粒的浓淡跟着模糊程度走：细亚克力比亚克力更透亮，颗粒也更细
    final grain = (material.blur / 3.2).clamp(0.0, 1.0);

    final sheetBody = Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: sheet.withValues(alpha: opacity)),
        ),
        // Mica Alt：下半截那层更实，露出接缝
        if (material.layered)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 13,
            child: ColoredBox(
              color: sheet.withValues(alpha: (opacity + 0.18).clamp(0.0, 1.0)),
            ),
          ),
        // 磨砂：斜向的一道反光 + 颗粒
        if (grain > 0)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.18 * grain),
                    Colors.white.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.6],
                ),
              ),
            ),
          ),
        if (grain > 0)
          Positioned.fill(child: CustomPaint(painter: _FrostPainter(grain))),
      ],
    );

    return SizedBox(
      width: 64,
      height: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            // 壁纸：斜向双色 + 右上角一团亮光，透不透、糊没糊全看这两样
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF6C4BB0),
                      const Color(0xFF1E6E8C),
                      const Color(0xFFD9A441),
                    ],
                    stops: const [0, 0.62, 1],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.85),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            // 材质薄片
            Positioned.fill(
              left: 4,
              top: 4,
              right: 4,
              bottom: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                // 只有亚克力系才真的糊，其余三种不必多挂一层 BackdropFilter
                child: material.blur > 0
                    ? BackdropFilter(
                        filter: ImageFilter.blur(
                          sigmaX: material.blur,
                          sigmaY: material.blur,
                        ),
                        child: sheetBody,
                      )
                    : sheetBody,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 磨砂颗粒。用固定伪随机数，保证同一张缩略图每次画出来的点阵完全一样。
class _FrostPainter extends CustomPainter {
  final double intensity;

  _FrostPainter(this.intensity);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.14 * intensity);
    var seed = 20260930;
    int next() {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      return seed;
    }

    final count = (size.width * size.height / 11 * intensity).round();
    for (var i = 0; i < count; i++) {
      canvas.drawCircle(
        Offset(
          (next() % 1000) / 1000 * size.width,
          (next() % 1000) / 1000 * size.height,
        ),
        0.6,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_FrostPainter oldDelegate) =>
      oldDelegate.intensity != intensity;
}
