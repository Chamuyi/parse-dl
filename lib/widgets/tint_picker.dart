import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// 色调预设。
///
/// 按色相顺序排列，每个色控制在中高明度、中等饱和度 ——
/// 因为最终会与主题底色混合（见 AppColors.tintFor），过饱和或过暗混出来会发脏。
const kTintPresets = <({String hex, String name})>[
  (hex: '#14b8a6', name: '青碧'),
  (hex: '#0ea5e9', name: '天青'),
  (hex: '#3b82f6', name: '蔚蓝'),
  (hex: '#6366f1', name: '靛蓝'),
  (hex: '#8b5cf6', name: '紫罗兰'),
  (hex: '#d946ef', name: '品红'),
  (hex: '#ec4899', name: '玫红'),
  (hex: '#f43f5e', name: '绯红'),
  (hex: '#f97316', name: '落日橘'),
  (hex: '#f59e0b', name: '琥珀'),
  (hex: '#10b981', name: '翡翠'),
  (hex: '#64748b', name: '石墨'),
];

/// 色调选择器：一排预设色 + 可展开的内嵌调色盘。
///
/// 调色盘是自己画的（饱和度/明度方区 + 色相条 + 色值输入），
/// 不依赖任何系统对话框 —— Flutter 自绘渲染没有旧版 WebView2 的弹层限制。
class TintPicker extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const TintPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<TintPicker> createState() => _TintPickerState();
}

class _TintPickerState extends State<TintPicker> {
  late HSVColor _hsv;
  late TextEditingController _hexCtrl;
  bool _expanded = false;

  static final _hexRe = RegExp(r'^#[0-9a-fA-F]{6}$');

  @override
  void initState() {
    super.initState();
    _hsv = _parse(widget.value);
    _hexCtrl = TextEditingController(text: _normalize(widget.value));
  }

  @override
  void didUpdateWidget(TintPicker old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      final hex = _normalize(widget.value);
      if (hex != _hexCtrl.text) {
        _hsv = _parse(widget.value);
        _hexCtrl.text = hex;
      }
    }
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  Color _color(String hex) {
    final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
    return v == null ? const Color(0xFF1D9BF0) : Color(0xFF000000 | v);
  }

  HSVColor _parse(String hex) => HSVColor.fromColor(_color(hex));

  String _normalize(String hex) {
    var h = hex.trim();
    if (!h.startsWith('#')) h = '#$h';
    return h.toUpperCase();
  }

  static String _toHex(Color c) {
    int ch(double v) => (v * 255).round().clamp(0, 255);
    return '#${ch(c.r).toRadixString(16).padLeft(2, '0')}'
            '${ch(c.g).toRadixString(16).padLeft(2, '0')}'
            '${ch(c.b).toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();
  }

  void _commitHsv(HSVColor hsv) {
    setState(() => _hsv = hsv);
    final hex = _toHex(hsv.toColor());
    _hexCtrl.text = hex;
    widget.onChanged(hex);
  }

  void _selectPreset(String hex) {
    final hsv = _parse(hex);
    setState(() => _hsv = hsv);
    _hexCtrl.text = _normalize(hex);
    widget.onChanged(hex.toLowerCase());
  }

  void _onHexInput(String raw) {
    var t = raw.trim();
    if (!t.startsWith('#')) t = '#$t';
    if (_hexRe.hasMatch(t)) {
      final c = _color(t);
      setState(() => _hsv = HSVColor.fromColor(c));
      widget.onChanged(t.toLowerCase());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final current = widget.value.toLowerCase();
    final isPreset =
        kTintPresets.any((p) => p.hex.toLowerCase() == current);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 预设色 + 自定义按钮 ──────────────────────────────
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final p in kTintPresets)
              _Swatch(
                color: _color(p.hex),
                label: p.name,
                selected: current == p.hex.toLowerCase(),
                onTap: () => _selectPreset(p.hex),
              ),

            // 自定义：展开调色盘，未选中预设色时显示当前自定义色
            _Swatch(
              color: isPreset ? null : _hsv.toColor(),
              label: t('自定义调色盘'),
              selected: !isPreset,
              isCustom: true,
              expanded: _expanded,
              onTap: () => setState(() => _expanded = !_expanded),
            ),
          ],
        ),

        // ── 当前色值 ────────────────────────────────────────
        const SizedBox(height: 12),
        Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: _hsv.toColor(),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.lineSoft),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 108,
              height: 30,
              child: TextField(
                controller: _hexCtrl,
                onChanged: _onHexInput,
                maxLength: 7,
                style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'Consolas',
                  color: c.textStrong,
                ),
                decoration: InputDecoration(
                  counterText: '',
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  hintText: '#1D9BF0',
                  hintStyle: TextStyle(fontSize: 12.5, color: c.textFaint),
                  filled: true,
                  fillColor: c.surfaceSunken,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.accent, width: 1),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                t('点左侧调色盘按钮展开取色，或直接输入色值'),
                style: TextStyle(fontSize: 12, color: c.textFaint),
              ),
            ),
          ],
        ),

        // ── 内嵌调色盘 ──────────────────────────────────────
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _ColorPalette(
                    hsv: _hsv,
                    onChanged: _commitHsv,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// 单个色块
class _Swatch extends StatefulWidget {
  final Color? color;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool isCustom;
  final bool expanded;

  const _Swatch({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
    this.isCustom = false,
    this.expanded = false,
  });

  @override
  State<_Swatch> createState() => _SwatchState();
}

class _SwatchState extends State<_Swatch> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    Widget inner;
    if (widget.isCustom) {
      // 未展开且无自定义色时，用彩虹渐变提示「这里是调色盘」
      inner = Container(
        decoration: BoxDecoration(
          color: widget.color,
          gradient: widget.color == null
              ? const SweepGradient(colors: [
                  Color(0xFFF43F5E),
                  Color(0xFFF59E0B),
                  Color(0xFF10B981),
                  Color(0xFF0EA5E9),
                  Color(0xFF6366F1),
                  Color(0xFFD946EF),
                  Color(0xFFF43F5E),
                ])
              : null,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(
          widget.expanded
              ? Icons.keyboard_arrow_up_rounded
              : Icons.colorize_rounded,
          size: 15,
          color: Colors.white,
          shadows: const [
            Shadow(color: Color(0x8C000000), blurRadius: 3, offset: Offset(0, 1)),
          ],
        ),
      );
    } else {
      inner = Container(
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: BorderRadius.circular(9),
        ),
      );
    }

    return Tooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            transform: Matrix4.diagonal3Values(
              _hover ? 1.1 : 1.0,
              _hover ? 1.1 : 1.0,
              1,
            ),
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: widget.selected ? c.accent : c.lineSoft,
                width: widget.selected ? 2 : 1,
              ),
              boxShadow: widget.selected
                  ? [BoxShadow(color: c.accentGlow, blurRadius: 12)]
                  : null,
            ),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: inner,
            ),
          ),
        ),
      ),
    );
  }
}

/// 内嵌调色盘：饱和度/明度方区 + 色相条
class _ColorPalette extends StatelessWidget {
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  const _ColorPalette({required this.hsv, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.lineSoft),
      ),
      child: Column(
        children: [
          // 饱和度 / 明度 方区
          SizedBox(
            height: 150,
            child: LayoutBuilder(
              builder: (context, cons) => GestureDetector(
                onPanDown: (d) => _pickSV(d.localPosition, cons.biggest),
                onPanUpdate: (d) => _pickSV(d.localPosition, cons.biggest),
                child: CustomPaint(
                  size: Size(cons.maxWidth, 150),
                  painter: _SVPainter(hue: hsv.hue),
                  child: Align(
                    alignment: Alignment(
                      hsv.saturation * 2 - 1,
                      hsv.value * 2 - 1,
                    ),
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x80000000),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // 色相条
          SizedBox(
            height: 22,
            child: LayoutBuilder(
              builder: (context, cons) => GestureDetector(
                onPanDown: (d) => _pickHue(d.localPosition, cons.maxWidth),
                onPanUpdate: (d) => _pickHue(d.localPosition, cons.maxWidth),
                child: CustomPaint(
                  size: Size(cons.maxWidth, 22),
                  painter: _HuePainter(),
                  child: Align(
                    alignment: Alignment(hsv.hue / 180.0 - 1, 0),
                    child: Container(
                      width: 6,
                      height: 22,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: const Color(0x66000000)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _pickSV(Offset pos, Size size) {
    final s = (pos.dx / size.width).clamp(0.0, 1.0);
    final v = (pos.dy / size.height).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(s).withValue(v));
  }

  void _pickHue(Offset pos, double width) {
    final h = (pos.dx / width).clamp(0.0, 1.0) * 360.0;
    onChanged(hsv.withHue(h));
  }
}

class _SVPainter extends CustomPainter {
  final double hue;
  _SVPainter({required this.hue});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));

    // 底色：当前色相的全饱和色
    canvas.drawRRect(
      rrect,
      Paint()..color = HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
    );
    // 白色横向渐变（饱和度）
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.white, Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    // 黑色纵向渐变（明度）
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Colors.black],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SVPainter old) => old.hue != hue;
}

class _HuePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    const hues = <Color>[
      Color(0xFFFF0000),
      Color(0xFFFFFF00),
      Color(0xFF00FF00),
      Color(0xFF00FFFF),
      Color(0xFF0000FF),
      Color(0xFFFF00FF),
      Color(0xFFFF0000),
    ];
    canvas.drawRRect(
      rrect,
      Paint()..shader = const LinearGradient(colors: hues).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_HuePainter old) => false;
}
