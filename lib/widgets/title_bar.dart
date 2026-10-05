import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';

/// 自绘标题栏。窗口是无边框的（titleBarStyle: hidden），
/// 所以标题栏、拖动、三个窗口按钮都由这里负责。
///
/// 三个按钮的图标**全部用同一套自绘几何**（10×10 画布、1px 描边），
/// 保证笔画粗细与视觉尺寸完全一致 —— 混用字体图标和手绘 SVG 会两者不一致，
/// 导致三个按钮看着不齐。
class TitleBar extends StatefulWidget {
  final String routeTitle;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;

  const TitleBar({
    super.key,
    required this.routeTitle,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
  });

  @override
  State<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<TitleBar> with WindowListener {
  bool _maximized = false;

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

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Container(
      height: 44,
      decoration: BoxDecoration(
        // 用 surfaceSolid 主题实色 + 75% alpha —— 浅色模式 = 浅灰，深色模式 = 深灰。
        // 之前用 surfaceCard 在深色模式下是白色 5.5%（白雾），alpha 0.75 后还是浅色，
        // 跟深色背景不协调。
        color: c.surfaceSolid.withValues(alpha: 0.85),
        border: Border(bottom: BorderSide(color: c.lineSoft, width: 1)),
      ),
      child: Row(
        children: [
          // 左侧：Logo + 标题 + 当前页（整块可拖动）
          Expanded(
            child: DragToMoveArea(
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
          ),

          // 右侧：三个窗口按钮，flush 排布
          _CaptionButton(
            label: '最小化',
            painter: (p, color) => p.minimize(color),
            onTap: widget.onMinimize,
          ),
          _CaptionButton(
            label: _maximized ? '还原' : '最大化',
            painter: (p, color) =>
                _maximized ? p.restore(color) : p.maximize(color),
            onTap: widget.onToggleMaximize,
          ),
          _CaptionButton(
            label: '关闭',
            painter: (p, color) => p.close(color),
            onTap: widget.onClose,
            danger: true,
          ),
        ],
      ),
    );
  }
}

/// 单个窗口按钮。尺寸对齐 Win11 标题栏按钮比例（46×32）。
class _CaptionButton extends StatefulWidget {
  final String label;
  final void Function(_IconPainter, Color) painter;
  final VoidCallback onTap;
  final bool danger;

  const _CaptionButton({
    required this.label,
    required this.painter,
    required this.onTap,
    this.danger = false,
  });

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    final bg = _hover
        ? (widget.danger ? const Color(0xFFC42B1C) : c.surfaceCardHover)
        : Colors.transparent;
    final fg = _hover && widget.danger ? Colors.white : c.textNormal;

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
            width: 46,
            height: 32,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
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
