import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// 背景图导入 + 不透明度调节。
///
/// 用 file_picker 调系统选图对话框：
/// 直接读文件字节，不受 asset 协议白名单限制，
/// 只能读成 data URL 绕；Flutter 用 Image.file 直接读，没有这个问题。
class BackgroundPicker extends StatelessWidget {
  final String value;
  final double opacity;
  final ValueChanged<String> onChanged;
  final ValueChanged<double> onOpacityChanged;

  const BackgroundPicker({
    super.key,
    required this.value,
    required this.opacity,
    required this.onChanged,
    required this.onOpacityChanged,
  });

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择背景图片',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
    );
    final path = result?.files.single.path;
    if (path != null && path.isNotEmpty) onChanged(path);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line),
      ),
      child: value.isEmpty
          ? _EmptyState(onPick: _pick)
          : _LoadedState(
              path: value,
              opacity: opacity,
              onOpacityChanged: onOpacityChanged,
              onPick: _pick,
              onClear: () => onChanged(''),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final Future<void> Function() onPick;

  const _EmptyState({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Column(
      children: [
        const SizedBox(height: 6),
        Icon(Icons.wallpaper_rounded, size: 28, color: c.textFaint),
        const SizedBox(height: 10),
        Text(
          t('未设置背景图，可导入一张图片作为主界面背景'),
          style: TextStyle(fontSize: 12.5, color: c.textMuted),
        ),
        const SizedBox(height: 12),
        _OutlineButton(
          icon: Icons.folder_open_rounded,
          label: t('导入背景图片'),
          onTap: onPick,
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}

class _LoadedState extends StatelessWidget {
  final String path;
  final double opacity;
  final ValueChanged<double> onOpacityChanged;
  final Future<void> Function() onPick;
  final VoidCallback onClear;

  const _LoadedState({
    required this.path,
    required this.opacity,
    required this.onOpacityChanged,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final fileName = path.split(RegExp(r'[\\/]')).last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 128,
                height: 80,
                child: Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  cacheWidth: 384,
                  errorBuilder: (_, _, _) => Container(
                    color: c.surfaceSunken,
                    child: Icon(Icons.broken_image_outlined,
                        size: 20, color: c.textFaint),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          fileName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: c.textStrong,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _IconButton(
                        icon: Icons.close_rounded,
                        tooltip: t('移除背景图'),
                        onTap: onClear,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // 不透明度
                  Row(
                    children: [
                      Text(t('不透明度'),
                          style: TextStyle(fontSize: 12, color: c.textMuted)),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 12,
                            ),
                          ),
                          child: Slider(
                            min: 0.05,
                            max: 1.0,
                            value: opacity.clamp(0.05, 1.0),
                            activeColor: c.accent,
                            inactiveColor: c.line,
                            onChanged: onOpacityChanged,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 38,
                        child: Text(
                          '${(opacity * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 12,
                            color: c.textFaint,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: _OutlineButton(
            icon: Icons.folder_open_rounded,
            label: t('更换图片'),
            small: true,
            onTap: onPick,
          ),
        ),
      ],
    );
  }
}

class _OutlineButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
  final bool small;

  const _OutlineButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.small = false,
  });

  @override
  State<_OutlineButton> createState() => _OutlineButtonState();
}

class _OutlineButtonState extends State<_OutlineButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => widget.onTap(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(
            horizontal: widget.small ? 10 : 14,
            vertical: widget.small ? 5 : 8,
          ),
          decoration: BoxDecoration(
            color: _hover ? c.accentSoft : c.surfaceCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _hover ? c.accentLine : c.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon,
                  size: widget.small ? 13 : 15,
                  color: _hover ? c.accentText : c.textNormal),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: widget.small ? 12 : 13,
                  color: _hover ? c.accentText : c.textNormal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _IconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_IconButton> createState() => _IconButtonState();
}

class _IconButtonState extends State<_IconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: _hover ? c.surfaceCardHover : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: _hover ? c.textStrong : c.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
