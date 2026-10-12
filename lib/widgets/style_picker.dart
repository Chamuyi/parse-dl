import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_style.dart';
import '../theme/app_theme.dart';

/// 界面风格选择器。
///
/// 三张卡片并排，每张左侧是一块**材质缩略图** —— 把该风格真正会画出来的东西
/// 画出来（圆角大小、背后糊没糊、有没有渐变面和内缘亮环），而不是三张长得
/// 一样的灰块配文字。选中时套 [selectedDecoration]，与窗口材质、导航形态
/// 两个选择器同一套视觉语言。
class StylePicker extends StatelessWidget {
  final AppStyle value;
  final ValueChanged<AppStyle> onChanged;

  const StylePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽屏两列、窄屏一列（阈值与材质选择器一致）
        final twoCol = constraints.maxWidth >= 520;
        final items = AppStyle.values;

        if (!twoCol) {
          return Column(
            children: [
              for (final s in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _StyleTile(
                    style: s,
                    selected: s == value,
                    onTap: () => onChanged(s),
                  ),
                ),
            ],
          );
        }

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final s in items)
              SizedBox(
                width: (constraints.maxWidth - 10) / 2,
                child: _StyleTile(
                  style: s,
                  selected: s == value,
                  onTap: () => onChanged(s),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StyleTile extends StatefulWidget {
  final AppStyle style;
  final bool selected;
  final VoidCallback onTap;

  const _StyleTile({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_StyleTile> createState() => _StyleTileState();
}

class _StyleTileState extends State<_StyleTile> {
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
            'label': t(widget.style.label),
            'desc': t(widget.style.description),
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
                _StylePreview(style: widget.style),
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
                              t(widget.style.label),
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
                        t(widget.style.description),
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

/// 风格缩略图：一块「背景 + 按该风格材质画出的卡片」。
///
/// 三件事必须**看得出来**，否则这张图就白画了：
///   - **圆角**：液体玻璃 ×1.25，另两套 ×1.0（同一条 16 的基准半径下
///     12 / 9.6 的差别一眼可辨）；
///   - **模糊**：磨砂与液体玻璃真的对背景做高斯模糊，陶土是实心面不做；
///   - **渐变面与内缘亮环**：只有液体玻璃有。
///
/// 缩略图里卡片的基准半径取 9.6，×1.25 = 12 —— 差值刻意放大到看得见的量级，
/// 因为在 64×44 的方寸里，16 与 20 的差别本来就该被夸张一点。
class _StylePreview extends StatelessWidget {
  final AppStyle style;

  const _StylePreview({required this.style});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final s = AppSurface.of(style);
    final brightness = AppTheme.of(context).brightness;

    final cardColor = s.resolveCardColor(c.surfaceCard, c.surfaceSolid);
    final r = 9.6 * s.radiusScale;

    final sheet = Container(
      decoration: BoxDecoration(
        color: s.gradient ? null : cardColor,
        gradient: s.gradient
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [s.gradientTop(cardColor), cardColor],
              )
            : null,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(
          color: s.rim ? s.rimColor(brightness) : c.line,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: s.shadowAlphaFor(brightness)),
            blurRadius: s.shadowBlur / 4,
            offset: Offset(0, s.shadowY / 4),
          ),
        ],
      ),
      // 卡片上放两条内容示意线，免得缩略图看起来只是一块色板
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 18,
            height: 3,
            decoration: BoxDecoration(
              color: c.textStrong.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: 26,
            height: 3,
            decoration: BoxDecoration(
              color: c.textMuted.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );

    return SizedBox(
      width: 64,
      height: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            // 背景：斜向双色 + 右上角一团亮光。糊没糊、透多少，全看它。
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: kPreviewWallpaper,
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
            // 卡片本体：只有 blur > 0 的风格才真的糊背景
            Positioned.fill(
              left: 6,
              top: 6,
              right: 6,
              bottom: 6,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(r),
                child: s.blur > 0
                    ? BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: s.blur, sigmaY: s.blur),
                        child: sheet,
                      )
                    : sheet,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
