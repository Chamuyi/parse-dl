import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media.dart';
import '../services/download_store.dart';
import '../services/file_name_template.dart';
import '../services/settings_store.dart';
import '../services/template_source.dart';
import '../theme/app_theme.dart';
import 'app_toast.dart';
import 'field_row.dart';
import 'opt_grid.dart';
import 'sub_section.dart';
import 'switch_row.dart';
import 'template_row.dart';
import '../l10n/l10n.dart';

/// 「下载」设置区的**卡内容**（X 模块）—— 卡头「下载」由设置页的
/// `SectionCard` 提供。
///
/// 预览稿（`index.html` :460-470）这张卡是：
///
/// ```
/// .grid.g2   保存路径 / 同名文件 / 并发数 / 限速
/// .sec       命名模板
/// tpl        文件夹模板 + 文件名模板
/// ```
///
/// 2026-10-13 S9b 平铺改造：原来「一个自绘目录行 + 两张模板 + 一个
/// `SwitchListTile` + 一行保存按钮」，现在收成预览稿那套：
///
/// * **保存路径 / 同名文件** —— 用 [FieldRow] 与 [SwitchRow]（原来那两样
///   各是一段自绘控件）；
/// * **并发数 / 限速** —— 预览稿这两格是「当前值 + 点开改」，本应用里
///   并发数是**全局**的（aria2 的 `max-concurrent-downloads`，写在抖音那一页
///   的 `concurrency` 上，X 页没有第二份），限速同理只有 B 站的 per-task 一份。
///   所以这两格在这里做成**只读当前值**（`OptGrid` 不给 `onChanged`），
///   值取自真正生效的那一份配置，并在副题里点明它归谁管 —— 平铺时摆一个
///   点不动又不说明出处的格子，比不摆更糟。
/// * **模板** —— 仍是 [TemplateRow]（自带可用变量表与「输出示例」，预览稿的
///   `tpl()` 也是这三件套），只是上面多了一行 [SubSection]「命名模板」。
///
/// 数据绑定一字未改：目录仍写 `download.saveDirBase` **并且**同步
/// `DownloadStore.setSaveDir`（协调器读的是后者），模板仍去抖落
/// `dirTemplate` / `fileNameTemplate`，跳过同名文件仍是 `sameFileSkip`。
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
    final settings = context.watch<SettingsStore>();
    final dl = settings.settings.download;
    // 并发数 / 限速的**真正出处**：并发读抖音那一份（X 与抖音共用同一个
    // aria2 进程的全局并发），限速读 B 站那一份（per-task，只有它存了）。
    final concurrency = settings.settings.douyin.concurrency;
    final speedLimit = settings.settings.bili.speedLimitKbps;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ① 保存路径（预览稿 `:461` 的 `.opt` 之一，这里用 `.row .field .btn`）
        //
        // 留空时显示**实际会落到的那个目录**（`defaultDownloadDir()`），不是
        // 一句「默认」描述 —— 2026-10-15 用户拿资源管理器核对，发现原来写的
        // 「默认（exe 同级）」与实际落点对不上。显示端与协调器共用同一个函数，
        // 路径以后再改也不会重新漂移。
        FieldRow(
          value: _saveDir.text.isEmpty
              ? defaultDownloadDir()
              : _saveDir.text,
          mono: true,
          buttons: [
            FieldButton(t('选择'), onPressed: _pickSaveDir),
          ],
        ),
        const SizedBox(height: 8),

        // ② 同名文件（预览稿 `:461` 的「同名文件 = 跳过」）
        SwitchRow(
          label: t('同名文件'),
          subtitle: t('按模板算出的完整路径已存在则跳过，不重新下载'),
          value: dl.sameFileSkip,
          onChanged: (v) => settings.setDownload((d) => d.sameFileSkip = v),
        ),
        const SizedBox(height: 8),

        // ③④ 全局并发 / 限速 —— 只读当前值 + 出处说明（见类文档）
        OptGrid<String>(
          items: [
            OptItem<String>(
              label: t('全局并发'),
              value: '$concurrency',
            ),
            OptItem<String>(
              label: t('限速'),
              value: speedLimit > 0 ? '$speedLimit KB/s' : t('不限'),
            ),
          ],
        ),
        // 这两项的编辑入口不在本页（分属另外两个模块的设置页），点不动就要说清去哪改。
        //
        // 措辞**不点名平台**：本文件是 X 模块的独占文件，
        // `test/module_boundary_test.dart` 的「X 侧文件的字符串字面量里没有抖音说法」
        // 会扫出这里的每个字面量 —— 界面上出现另一个模块的名字就是术语串台。
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            t('这两项由下载引擎统一管理，编辑入口在各自模块的设置页。'),
            style: TextStyle(
              fontSize: 11.5,
              color: AppTheme.colorsOf(context).textFaint,
            ),
          ),
        ),

        // ⑤ 命名模板（预览稿 `:462` 的 `.sec`）
        SubSection(t('命名模板')),

        TemplateRow(
          // 这一行绑的是 `_dirTpl`（文件夹模板）—— 标签不能写成「文件名模板」，
          // 否则页面上两行同名，用户分不清哪个管文件夹、哪个管文件
          // （2026-10-13 S9b 平铺改造时写错，被 template_vars_test 抓到）。
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

        const SizedBox(height: 10),

        // ⑥ 保存模板（模板本身已去抖自动保存，这个按钮是「立刻落盘」的显式入口）
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              t('模板改动会自动保存'),
              style: TextStyle(
                fontSize: 11.5,
                color: AppTheme.colorsOf(context).textFaint,
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text(t('保存模板'), style: const TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      ],
    );
  }
}
