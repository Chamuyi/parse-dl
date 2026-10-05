import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_logger.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import 'app_toast.dart';
import '../l10n/l10n.dart';

/// 「应用」设置区。
///
///  里的「记录日志文件」与「打开日志文件夹」。
class AppSection extends StatelessWidget {
  const AppSection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final settings = context.watch<SettingsStore>();
    final app = settings.settings.app;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              t('记录日志文件'),
              style: TextStyle(fontSize: 13.5, color: c.textStrong),
            ),
            subtitle: Text(
              t('开启后把 aria2 输出、X API 请求与错误写入本地日志（不影响应用速度）'),
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
            value: app.writeLogs,
            activeThumbColor: c.accent,
            onChanged: (v) => settings.setApp((a) => a.writeLogs = v),
          ),
        ),
        const SizedBox(height: 12),
        // 日志目录 / 打开文件夹 —— 外层「应用」分区已整体折叠，这里直接平铺
        Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: c.surfaceSunken,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.line, width: 0.6),
              ),
              child: FutureBuilder<Directory>(
                future: AppLogger.logsDirectory(),
                builder: (context, snap) {
                  final path = snap.hasData ? snap.data!.path : '加载中…';
                  return Text(
                    tf('日志目录：{path}', {'path': path}),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: c.textMuted,
                      fontFamily: 'Consolas',
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final path = await AppLogger.currentFilePath();
                      if (!await File(path).exists()) {
                        if (!context.mounted) return;
                        AppToast.show(context, t('今天还没有日志文件 —— 请先打开上面的开关，再操作一次'), kind: AppToastKind.error);
                        return;
                      }
                      await launchUrl(Uri.file(path));
                    } catch (e) {
                      if (!context.mounted) return;
                      AppToast.show(
                          context, tf('打开失败：{e}', {'e': e}),
                          kind: AppToastKind.error);
                    }
                  },
                  icon: const Icon(Icons.description_outlined, size: 16),
                  label: Text(t('查看日志'), style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    try {
                      final logsDir = await AppLogger.logsDirectory();
                      if (!await logsDir.exists()) {
                        await logsDir.create(recursive: true);
                      }
                      await launchUrl(Uri.directory(logsDir.path));
                    } catch (e) {
                      if (!context.mounted) return;
                      AppToast.show(
                          context, tf('打开失败：{e}', {'e': e}),
                          kind: AppToastKind.error);
                    }
                  },
                  icon: const Icon(Icons.folder_open_outlined, size: 16),
                  label: Text(t('打开文件夹'), style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
      ],
    );
  }
}