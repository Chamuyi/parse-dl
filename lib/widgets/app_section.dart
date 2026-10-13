import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_logger.dart';
import '../services/settings_store.dart';
import 'app_toast.dart';
import 'field_row.dart';
import 'switch_row.dart';
import '../l10n/l10n.dart';

/// 「应用」设置区的**卡内容** —— 卡头「应用」由设置页的 `SectionCard` 提供。
///
/// 2026-10-13 S9b 平铺改造：整块从「自绘 `SwitchListTile` + 自绘路径块 +
/// 自绘按钮行」换成预览稿那三种组件（`app.css` 的 `.sw` / `.row .field .btn`）：
///
/// ```
/// :203 .sw  { display:flex; align-items:center; gap:9px; padding:9px 11px; }
/// :130 .row { display:flex; gap:8px; margin-bottom:10px; align-items:center; }
/// ```
///
/// **数据绑定一字未改**：写日志仍是 `app.writeLogs`，启动检查更新仍是
/// `app.autoCheckUpdate`，目录仍由 [AppLogger.logsDirectory] 现算 ——
/// 换的只是承载它们的行。
///
/// 预览稿这一张卡是「两条 `sw` + 一行 `field` + 一个『打开』按钮」。本应用比
/// 预览稿多一个动作：日志**既能开文件夹、也能直接开今天那个文件**，两个都要留
/// （关掉任一等于少一条排障路径），所以 [FieldRow] 上挂两枚按钮而不是一枚。
class AppSection extends StatelessWidget {
  const AppSection({super.key});

  /// 打开日志文件夹 —— 目录不存在时先建出来，否则资源管理器会弹「找不到」。
  Future<void> _openFolder(BuildContext context) async {
    try {
      final logsDir = await AppLogger.logsDirectory();
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }
      await launchUrl(Uri.directory(logsDir.path));
    } catch (e) {
      if (!context.mounted) return;
      AppToast.show(context, tf('打开失败：{e}', {'e': e}),
          kind: AppToastKind.error);
    }
  }

  /// 打开今天那一个日志文件。
  ///
  /// 文件不存在时给一句能照做的话，而不是把「文件不存在」的异常抛给用户 ——
  /// 开关没开时这个文件本来就不会有。
  Future<void> _openFile(BuildContext context) async {
    try {
      final path = await AppLogger.currentFilePath();
      if (!await File(path).exists()) {
        if (!context.mounted) return;
        AppToast.show(
            context, t('今天还没有日志文件 —— 请先打开上面的开关，再操作一次'),
            kind: AppToastKind.error);
        return;
      }
      await launchUrl(Uri.file(path));
    } catch (e) {
      if (!context.mounted) return;
      AppToast.show(context, tf('打开失败：{e}', {'e': e}),
          kind: AppToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final app = settings.settings.app;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchRow(
          label: t('写日志到文件'),
          subtitle: t('开启后把 aria2 输出、X API 请求与错误写入本地日志（不影响应用速度）'),
          value: app.writeLogs,
          onChanged: (v) => settings.setApp((a) => a.writeLogs = v),
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('启动时检查更新'),
          subtitle: t('启动后自动查一次新版本；关掉则只能手动检查'),
          value: app.autoCheckUpdate,
          onChanged: (v) => settings.setApp((a) => a.autoCheckUpdate = v),
        ),
        const SizedBox(height: 10),
        // 日志目录：路径是**异步**算出来的（要问 AppPaths），所以外面套一层
        // FutureBuilder —— 未就绪时给一句「加载中…」而不是闪一个空字段。
        FutureBuilder<Directory>(
          future: AppLogger.logsDirectory(),
          builder: (context, snap) {
            final path = snap.hasData ? snap.data!.path : t('加载中…');
            return FieldRow(
              value: path,
              mono: true,
              buttons: [
                FieldButton(t('打开文件夹'), onPressed: () => _openFolder(context)),
                FieldButton(t('查看日志'),
                    ghost: true, onPressed: () => _openFile(context)),
              ],
            );
          },
        ),
      ],
    );
  }
}
