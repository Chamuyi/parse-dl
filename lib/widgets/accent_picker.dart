import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../theme/winui_accent.dart';

/// 强调色选择器 —— WinUI 风格下三选一（2026-10-19 用户裁定）。
///
/// 每张卡片直接画出**该档强调色的真实色块**（浅深两套各一半），
/// 而不是三个写着名字的灰块 —— 选颜色这件事必须所见即所得。
///
/// 只在 [AppStyle.winui] 下显示：另三套风格各有自己的强调色令牌，
/// 不读这个设置。
class AccentPicker extends StatelessWidget {
  final WinUiAccent value;
  final ValueChanged<WinUiAccent> onChanged;

  const AccentPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoCol = constraints.maxWidth >= 520;
        final items = WinUiAccent.values;
        if (!twoCol) {
          return Column(
            children: [
              for (final a in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _AccentTile(
                    accent: a,
                    selected: a == value,
                    onTap: () => onChanged(a),
                  ),
                ),
            ],
          );
        }
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final a in items)
              SizedBox(
                width: (constraints.maxWidth - 10) / 2,
                child: _AccentTile(
                  accent: a,
                  selected: a == value,
                  onTap: () => onChanged(a),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AccentTile extends StatelessWidget {
  final WinUiAccent accent;
  final bool selected;
  final VoidCallback onTap;

  const _AccentTile({
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final light = accent.colorsFor(Brightness.light);
    final dark = accent.colorsFor(Brightness.dark);
    // 「跟随系统」未解析出系统色时，实际显示的就是 Windows 蓝 ——
    // 缩略图必须跟着显示同一个色，否则用户在挑一个不存在的颜色。
    final showing = accent == WinUiAccent.system &&
        WinUiAccent.resolvedSystemColor == null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: selected
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: c.accent.withValues(alpha: 0.10),
                  border: Border.all(
                    color: c.accent.withValues(alpha: 0.55),
                    width: 1.5,
                  ),
                )
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.line),
                ),
          child: Row(
            children: [
              // 双色块：左浅右深，一眼看出这套强调色在两种主题下的样子
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 44,
                  height: 32,
                  child: Row(
                    children: [
                      Expanded(child: ColoredBox(color: light.accent)),
                      Expanded(child: ColoredBox(color: dark.accent)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      t(accent.label),
                      style: TextStyle(
                        color: c.textStrong,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      showing ? t('跟随系统（未取到，当前为 Windows 蓝）') : t(accent.description),
                      style: TextStyle(color: c.textMuted, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded, size: 18, color: c.accent),
            ],
          ),
        ),
      ),
    );
  }
}
