import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media.dart';
import '../services/download_store.dart';
import '../services/file_name_template.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import 'template_row.dart';
import 'app_toast.dart';
import '../l10n/l10n.dart';

/// 「下载」设置区。
///
///  里的下载设置：
///   - 保存路径（系统选目录）
///   - 文件夹模板（%USER_SCREEN_NAME%/%POST_ID%）
///   - 文件名模板（%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%）
///   - 跳过相同文件
///
/// 模板变量语法与原版完全一致（`%VAR%`，带参写作 `%VAR,t=32%`），
/// 下方「可用变量」点一下就插进当前光标所在的输入框，并即时给出「输出示例」。
class DownloadSection extends StatefulWidget {
  const DownloadSection({super.key});

  @override
  State<DownloadSection> createState() => _DownloadSectionState();
}

class _DownloadSectionState extends State<DownloadSection> {
  late final TextEditingController _dirTpl;
  late final TextEditingController _nameTpl;
  late final TextEditingController _saveDir;

  final FocusNode _dirFocus = FocusNode();
  final FocusNode _nameFocus = FocusNode();

  /// 自动保存的去抖计时器（避免每敲一个字符就写一次磁盘）
  Timer? _debounce;

  static const _defaultNameTpl =
      '%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%';

  /// 模板预览用的示例媒体（同原版 EXAMPLE_* 常量）
  /// 模板预览用的示例媒体（**X 语境**：一条推文里的图片）。
  final Media _example = xExampleMedia();

  @override
  void initState() {
    super.initState();
    final d = context.read<SettingsStore>().settings.download;
    _dirTpl = TextEditingController(text: d.dirTemplate);
    _nameTpl = TextEditingController(text: d.fileNameTemplate);
    final store = context.read<DownloadStore>();
    // 优先内存值，其次 settings 里的持久化值 —— 否则重启后这里显示为空
    _saveDir = TextEditingController(
      text: store.defaultSaveDir.isNotEmpty
          ? store.defaultSaveDir
          : d.saveDirBase,
    );

    _dirTpl.addListener(_onTemplateChanged);
    _nameTpl.addListener(_onTemplateChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _dirTpl.dispose();
    _nameTpl.dispose();
    _saveDir.dispose();
    _dirFocus.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  /// 模板改了 → 刷新「输出示例」+ 去抖落盘。
  ///
  /// 自动保存很重要：点变量插入后忘了按「保存模板」的话，
  /// 下载时用的还是旧模板（这正是之前「文件名没按模板走」的诱因之一）。
  void _onTemplateChanged() {
    if (mounted) setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      context.read<SettingsStore>().setDownload((d) {
        d.dirTemplate = _dirTpl.text.trim();
        d.fileNameTemplate = _nameTpl.text.trim();
      });
    });
  }

  Future<void> _pickSaveDir() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    setState(() {
      _saveDir.text = result;
    });
    // 同时写入 store + settings，coordinator 用 store.defaultSaveDir
    if (!mounted) return;
    final store = context.read<DownloadStore>();
    final settings = context.read<SettingsStore>();
    store.setSaveDir(result);
    await settings.setDownload((d) => d.saveDirBase = result);
  }

  Future<void> _save() async {
    _debounce?.cancel();
    final settings = context.read<SettingsStore>();
    await settings.setDownload((d) {
      d.dirTemplate = _dirTpl.text.trim();
      d.fileNameTemplate = _nameTpl.text.trim();
    });
    if (!mounted) return;
    AppToast.show(context, t('已保存模板'), kind: AppToastKind.success);
  }

  /// 把 `%VAR%` 插到**指定**模板框的光标处。
  ///
  /// 目标由「点的是哪一个字段的变量表」直接决定，不再依赖焦点状态 ——
  /// 每个字段各有一份可用变量表（对齐原版 `FileNameTemplateInput`）。
  void _insertToken(String token, {required bool isDir}) {
    final ctrl = isDir ? _dirTpl : _nameTpl;
    final sel = ctrl.selection;
    final text = ctrl.text;
    final start = sel.start >= 0 && sel.start <= text.length
        ? sel.start
        : text.length;
    final end = sel.end >= 0 && sel.end <= text.length ? sel.end : text.length;
    ctrl.value = TextEditingValue(
      text: text.replaceRange(start, end, token),
      selection: TextSelection.collapsed(offset: start + token.length),
    );
    final label = isDir ? '文件夹模板' : '文件名模板';
    AppToast.show(
        context,
        tf('已插入 {token} 到「{target}」', {'token': token, 'target': t(label)}),
        kind: AppToastKind.info);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final settings = context.watch<SettingsStore>();
    final dl = settings.settings.download;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ① 保存路径
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _saveDir,
                readOnly: true,
                style: TextStyle(
                  fontSize: 13,
                  color: c.textStrong,
                  fontFamily: 'Consolas',
                ),
                decoration: InputDecoration(
                  hintText: t('留空则使用 %USERPROFILE%\\Downloads\\解析下载器'),
                  hintStyle: TextStyle(fontSize: 12, color: c.textFaint),
                  filled: true,
                  fillColor: c.surfaceSunken,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.line),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.tonalIcon(
              onPressed: _pickSaveDir,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: Text(t('选择'), style: TextStyle(fontSize: 13.5)),
            ),
          ],
        ),
        const SizedBox(height: 18),

        // ②③ 两个模板字段（各自带一份可用变量表）。
        //     外层「下载」分区已经整体折叠，这里不再套第二层折叠。
        TemplateRow(
          label: t('文件夹模板'),
          hint: '%USER_NAME%_%USER_SCREEN_NAME%',
          controller: _dirTpl,
          focusNode: _dirFocus,
          // 文件夹模板可以为空（全部平铺在保存目录下）
          emptyHint: '留空则直接存到保存目录下',
          onUseDefault: () => _dirTpl.text = '%USER_SCREEN_NAME%',
          example: _dirTpl.text.trim().isEmpty
              ? ''
              : resolveVariables(_dirTpl.text, _example).trim(),
          onPickVar: (t) => _insertToken(t, isDir: true),
          vars: kXTemplateVars,
          // 路径是「一组文件共用一个文件夹」，逐文件变量会把每条媒体拆成独立目录
          varHint:
              '提示：文件夹模板建议只用「用户 / 推文」级变量；'
              '%MEDIA_INDEX%、%EXT%、%MEDIA_ID% 等逐文件变量会让每条媒体各建一个文件夹。',
        ),

        const SizedBox(height: 16),

        // 文件名模板（同样自带一份可用变量表）
        TemplateRow(
          label: t('文件名模板'),
          hint: '%POST_TIME%_%USER_NAME%_%USER_SCREEN_NAME%_%CONTENT%_%EXT%',
          controller: _nameTpl,
          focusNode: _nameFocus,
          emptyHint: '留空则使用「媒体ID_时间戳.扩展名」',
          onUseDefault: () => _nameTpl.text = _defaultNameTpl,
          example: _nameTpl.text.trim().isEmpty
              ? ''
              : resolveVariables(_nameTpl.text, _example).trim(),
          onPickVar: (t) => _insertToken(t, isDir: false),
          vars: kXTemplateVars,
        ),

        const SizedBox(height: 16),

        // ④ 跳过相同文件
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              t('跳过同名文件'),
              style: TextStyle(fontSize: 13.5, color: c.textStrong),
            ),
            subtitle: Text(
              t('按模板算出的完整路径已存在则跳过，不重新下载'),
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
            value: dl.sameFileSkip,
            activeThumbColor: c.accent,
            onChanged: (v) => settings.setDownload((d) => d.sameFileSkip = v),
          ),
        ),

        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              t('模板改动会自动保存'),
              style: TextStyle(fontSize: 11.5, color: c.textFaint),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text(t('保存模板'), style: TextStyle(fontSize: 13.5)),
            ),
          ],
        ),
      ],
    );
  }
}
