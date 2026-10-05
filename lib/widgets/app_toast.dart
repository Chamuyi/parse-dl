import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// 轻量提示条（Toast）。
///
/// **为什么不用 `SnackBar`：** `SnackBar` 恒锚定在 `Scaffold` 底部。
/// 本应用底部要么浮着 Dock、要么贴着内容区下沿，提示一出来就压在操作区上，
/// 用户的原话是「不要出现在最下面」。而且 `SnackBar` 由 `ScaffoldMessenger`
/// 管理，会在 Scaffold 内抢一层布局栈。
///
/// 这里改成 **`Overlay` 浮层**：
///   - 位置在**顶部、标题栏之下**（`kToastTopInset`），居中显示；
///   - `OverlayEntry` 不参与任何页面布局，**不会挤动/遮挡页面内容**
///     （页面尺寸在弹出前后完全不变，有 widget test 钉住）；
///   - 自带下落 + 淡入动画，支持一个可选的动作按钮（如「去下载管理」）。
///
/// 典型用法：
/// ```dart
/// AppToast.show(context, '已提交 12 个下载',
///     actionLabel: '去下载管理', onAction: () => onNavigate('download-management'));
/// ```
class AppToast {
  /// 距窗口顶部的距离。自绘标题栏高 44（见 `widgets/title_bar.dart`），
  /// 往下再留 12 的呼吸感，正好压在标题栏下方。
  static const double kToastTopInset = 56;

  /// 同时只保留一条：新的顶掉旧的，避免连续点击时叠成一摞。
  static OverlayEntry? _current;

  /// 弹一条提示。[duration] 内没有操作会自动消失。
  static void show(
    BuildContext context,
    String message, {
    AppToastKind kind = AppToastKind.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    dismiss();

    final overlay = Overlay.maybeOf(context, rootOverlay: true) ??
        Overlay.maybeOf(context);
    if (overlay == null) return;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _ToastView(
        message: message,
        kind: kind,
        actionLabel: actionLabel,
        onAction: onAction,
        duration: duration,
        onClosed: () {
          if (_current == entry) _current = null;
          if (entry.mounted) entry.remove();
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }

  /// 立刻收掉当前提示（没有就什么都不做）。
  static void dismiss() {
    final e = _current;
    _current = null;
    if (e != null && e.mounted) e.remove();
  }
}

/// 提示条的语义类型，只影响左侧图标与描边色。
enum AppToastKind {
  info(Icons.info_outline_rounded),
  success(Icons.check_circle_outline_rounded),
  error(Icons.error_outline_rounded);

  const AppToastKind(this.icon);
  final IconData icon;
}

class _ToastView extends StatefulWidget {
  final String message;
  final AppToastKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
  final VoidCallback onClosed;

  const _ToastView({
    required this.message,
    required this.kind,
    required this.actionLabel,
    required this.onAction,
    required this.duration,
    required this.onClosed,
  });

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _curve =
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);

  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _anim.forward();
    _timer = Timer(widget.duration, _close);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    try {
      await _anim.reverse();
    } catch (_) {
      // 反演期间 widget 可能已被移除
    }
    widget.onClosed();
  }

  void _runAction() {
    final cb = widget.onAction;
    unawaited(_close());
    cb?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final accent = switch (widget.kind) {
      AppToastKind.error => c.danger,
      AppToastKind.success => c.accent,
      AppToastKind.info => c.accent,
    };

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(top: AppToast.kToastTopInset),
          child: Align(
            alignment: Alignment.topCenter,
            child: FadeTransition(
              opacity: _curve,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, -0.35),
                  end: Offset.zero,
                ).animate(_curve),
                child: _card(c, accent),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(AppColors c, Color accent) {
    final label = widget.actionLabel;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Material(
        color: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 20),
          padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
          decoration: BoxDecoration(
            color: c.surfaceFloat,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accent.withValues(alpha: 0.42), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.kind.icon, size: 17, color: accent),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  widget.message,
                  style: TextStyle(
                      fontSize: 12.8, color: c.textStrong, height: 1.4),
                ),
              ),
              if (label != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _runAction,
                  style: TextButton.styleFrom(
                    foregroundColor: c.accentText,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(label,
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
              ],
              const SizedBox(width: 2),
              IconButton(
                onPressed: _close,
                tooltip: t('关闭'),
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 22, minHeight: 22),
                color: c.textMuted,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
