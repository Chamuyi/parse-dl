import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/download_store.dart';
import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// 下载任务列表项。
///
/// 
/// 单行展示：缩略图 / 文件名 / 进度 / 状态 / 操作按钮。
class DownloadListItem extends StatelessWidget {
  final DownloadTask task;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onRetry;
  final VoidCallback? onRemove;
  final VoidCallback? onOpenFolder;

  const DownloadListItem({
    super.key,
    required this.task,
    this.onPause,
    this.onResume,
    this.onRetry,
    this.onRemove,
    this.onOpenFolder,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final isVideo = task.media.type.isVideo;
    final preview = task.media.previewUrl ?? task.media.url;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ① 缩略图
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 64,
              height: 64,
              child: preview.isNotEmpty
                  ? Image.network(
                      preview,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Container(color: c.surfaceSunken),
                      loadingBuilder: (_, child, p) => p == null
                          ? child
                          : Container(color: c.surfaceSunken),
                    )
                  : Container(
                      color: c.surfaceSunken,
                      alignment: Alignment.center,
                      child: Icon(
                        isVideo
                            ? Icons.play_circle_outline
                            : Icons.image_outlined,
                        color: c.textMuted,
                      ),
                    ),
            ),
          ),

          const SizedBox(width: 14),

          // ② 中间：文件名 + 进度 + 状态
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Tooltip(
                        message: task.fullPath,
                        waitDuration: const Duration(milliseconds: 300),
                        child: Text(
                          task.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: c.textStrong,
                            fontFamily: 'Consolas',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusBadge(status: task.status, colors: c),
                  ],
                ),
                const SizedBox(height: 6),
                _ProgressLine(task: task, colors: c),
                const SizedBox(height: 6),
                Row(
                  children: [
                    // 必须是 Expanded 而不是裸 Text：`_statusDetail` 在
                    // 「下载中」时回的是 `45.3% · 完整保存路径`，出错时回的是
                    // aria2 的原始报错 —— 两个都没有长度上限，路径稍长就把这一行
                    // 顶出去（测试里实测溢出 175px）。右侧字节数短且重要，
                    // 所以让它占固定宽、由左边截断。
                    Expanded(
                      child: Text(
                        _statusDetail(task),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: c.textMuted),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _humanBytes(task.downloadedBytes ?? 0) +
                          (task.totalBytes != null && task.totalBytes! > 0
                              ? ' / ${_humanBytes(task.totalBytes!)}'
                              : ''),
                      style: TextStyle(
                          fontSize: 12,
                          color: c.textMuted,
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          // ③ 操作
          _ActionButtons(
            status: task.status,
            onPause: onPause,
            onResume: onResume,
            onRetry: onRetry,
            onRemove: onRemove,
            onOpenFolder: onOpenFolder,
          ),
        ],
      ),
    );
  }

  String _statusDetail(DownloadTask t) {
    switch (t.status) {
      case DownloadStatus.pending:
        return '等待入队…';
      case DownloadStatus.waiting:
        return 'aria2 队列中…';
      case DownloadStatus.active:
        return '${t.progressPercent.toStringAsFixed(1)}% · ${t.saveDir}';
      case DownloadStatus.paused:
        return '已暂停';
      case DownloadStatus.complete:
        return '已完成 · ${DateFormat('HH:mm:ss').format(t.createdAt)}';
      case DownloadStatus.error:
        return t.errorMessage ?? '下载失败';
    }
  }

  String _humanBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 10 ? 0 : 1)} ${units[unit]}';
  }
}

// ── 进度条 ─────────────────────────────────────────────────

class _ProgressLine extends StatelessWidget {
  final DownloadTask task;
  final AppColors colors;
  const _ProgressLine({required this.task, required this.colors});

  @override
  Widget build(BuildContext context) {
    final percent = (task.progress / 1000).clamp(0.0, 1.0);
    final c = colors;

    return Stack(
      children: [
        Container(
          height: 4,
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        FractionallySizedBox(
          widthFactor: percent,
          child: Container(
            height: 4,
            decoration: BoxDecoration(
              color: task.status == DownloadStatus.error ? c.danger : c.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
    );
  }
}

// ── 状态徽章 ───────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final DownloadStatus status;
  final AppColors colors;
  const _StatusBadge({required this.status, required this.colors});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status) {
      DownloadStatus.pending => (
          '等待入队',
          colors.textMuted,
          Icons.schedule,
        ),
      DownloadStatus.waiting => (
          '队列中',
          colors.textMuted,
          Icons.schedule,
        ),
      DownloadStatus.active => (
          '下载中',
          colors.accent,
          Icons.sync,
        ),
      DownloadStatus.paused => (
          '已暂停',
          colors.warning,
          Icons.pause_circle_outline,
        ),
      DownloadStatus.complete => (
          '已完成',
          colors.success,
          Icons.check_circle_outline,
        ),
      DownloadStatus.error => (
          '失败',
          colors.danger,
          Icons.error_outline,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == DownloadStatus.active)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.4, color: color),
            )
          else
            Icon(icon, size: 10, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ── 操作按钮 ───────────────────────────────────────────────

class _ActionButtons extends StatelessWidget {
  final DownloadStatus status;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onRetry;
  final VoidCallback? onRemove;
  final VoidCallback? onOpenFolder;

  const _ActionButtons({
    required this.status,
    this.onPause,
    this.onResume,
    this.onRetry,
    this.onRemove,
    this.onOpenFolder,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final canPause = status == DownloadStatus.active ||
        status == DownloadStatus.waiting;
    final canResume = status == DownloadStatus.paused;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canPause)
          _IconAction(
            icon: Icons.pause_rounded,
            tooltip: t('暂停'),
            onTap: onPause,
          ),
        if (canResume)
          _IconAction(
            icon: Icons.play_arrow_rounded,
            tooltip: t('继续'),
            onTap: onResume,
          ),
        if (status == DownloadStatus.error)
          _IconAction(
            // 自动重试的 5 次额度用尽后任务就定在「错误」里了，
            // 没有这颗按钮的话用户除了「移除」再重新下一遍没有别的路。
            icon: Icons.refresh_rounded,
            tooltip: t('重试'),
            onTap: onRetry,
          ),
        if (status == DownloadStatus.complete)
          _IconAction(
            icon: Icons.folder_open_outlined,
            tooltip: t('打开文件夹'),
            onTap: onOpenFolder,
          ),
        _IconAction(
          icon: Icons.close_rounded,
          tooltip: t('移除'),
          color: c.textMuted,
          onTap: onRemove,
        ),
      ],
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;

  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return SizedBox(
      width: 30,
      height: 30,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 18, color: color ?? c.textNormal),
        onPressed: onTap,
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}