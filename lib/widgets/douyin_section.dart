import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/douyin_config.dart';
import '../services/aria2_coordinator.dart';
import '../models/media.dart';
import '../services/douyin_store.dart';
import '../services/download_store.dart';
import '../services/file_name_template.dart';
import '../services/settings_store.dart';
import '../services/template_source.dart';
import '../theme/app_theme.dart';
import 'field_row.dart';
import 'opt_grid.dart';
import 'sub_section.dart';
import 'switch_row.dart';
import 'template_row.dart';
import 'app_toast.dart';
import '../l10n/l10n.dart';

/// 「抖音」设置区 —— 「下载设置」这一整组选项。
///
/// 每一项的落点：
///
/// | 设置项 | 控件 |
/// |---|---|
/// | 下载源 6 档 | [DouyinSource] 下拉 |
/// | 质量优先策略 4 档 | [DouyinQualityMode] 下拉（仅质量优先两档可见） |
/// | 图片格式（默认 webp / 其它格式优先 jpg） | [DouyinImageFormat] 下拉 |
/// | 并发数 `limit` | [DouyinConfig.concurrency] |
/// | 跳过已下载 `skipDownloaded` | 开关 + 台账条数 + 清除按钮 |
/// | 视频时长范围 `timeRange` | 开关 + 上下限（**秒**） |
/// | 自定义文本 `customText` | 输入框（`%CUSTOM_TEXT%`） |
/// | 输出 HTML 统计报告 / 攒内存打 ZIP / 用文件系统 API | **不做** —— 那是浏览器环境本身的限制（写不了任意目录），桌面端用 aria2 直接落盘 |
///
/// 三项额外的开关（滤低画质 / 排除 ByteVC1 / 附带 BGM / 实况图 / 按作品）
/// 在平台返回里是散落在各处的隐含行为，这里显式给出来，默认值经实测校准。
class DouyinSection extends StatefulWidget {
  const DouyinSection({super.key});

  @override
  State<DouyinSection> createState() => _DouyinSectionState();
}

class _DouyinSectionState extends State<DouyinSection> {
  late final TextEditingController _minSec;
  late final TextEditingController _maxSec;
  late final TextEditingController _customText;
  late final TextEditingController _dirTpl;
  late final TextEditingController _nameTpl;
  late final TextEditingController _saveDir;

  final FocusNode _dirFocus = FocusNode();
  final FocusNode _nameFocus = FocusNode();

  /// 模板预览用的示例媒体（**抖音语境**：一条竖屏视频作品）。
  final Media _example = douyinExampleMedia();

  /// 文本框 → 设置的落盘去抖（避免每敲一个字符写一次 settings.json）
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsStore>();
    final d = settings.settings.douyin;
    _minSec = TextEditingController(text: '${d.timeStartSec}');
    _maxSec = TextEditingController(text: '${d.timeEndSec}');
    _customText = TextEditingController(text: d.customText);
    _dirTpl = TextEditingController(text: d.dirTemplate);
    _nameTpl = TextEditingController(text: d.fileNameTemplate);
    // 没自己设过时，先把框子显示成「这一趟实际会落到哪」，而不是留一个
    // 看起来什么都没配的空白 —— 真正的回退规则在 resolveSaveBase 里。
    _saveDir = TextEditingController(
      text: d.saveDirBase.isNotEmpty
          ? d.saveDirBase
          : resolveSaveBase(
              sessionSaveDir: context.read<DownloadStore>().defaultSaveDir,
              xSaveDirBase: settings.settings.download.saveDirBase,
              fallback: '',
            ),
    );
    for (final c in [_minSec, _maxSec, _customText, _dirTpl, _nameTpl]) {
      c.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _minSec.dispose();
    _maxSec.dispose();
    _customText.dispose();
    _dirTpl.dispose();
    _nameTpl.dispose();
    _saveDir.dispose();
    _dirFocus.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _flushText);
  }

  void _flushText() {
    if (!mounted) return;
    final min = int.tryParse(_minSec.text.trim());
    final max = int.tryParse(_maxSec.text.trim());
    context.read<SettingsStore>().setDouyin((d) {
      if (min != null && min >= 0) d.timeStartSec = min;
      if (max != null && max >= 0) d.timeEndSec = max;
      d.customText = _customText.text.trim();
      d.dirTemplate = _dirTpl.text.trim();
      d.fileNameTemplate = _nameTpl.text.trim();
    });
  }

  Future<void> _set(void Function(DouyinConfig d) mutate) =>
      context.read<SettingsStore>().setDouyin(mutate);

  /// 选保存根目录 —— 只写抖音自己这一份，不动另一侧的设置。
  Future<void> _pickSaveDir() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    if (mounted) setState(() => _saveDir.text = result);
    await _set((d) => d.saveDirBase = result);
  }

  /// 改并发数后立刻同步给 aria2（否则要等下次启动才生效）。
  ///
  /// `applyConcurrency` 在 aria2 未启动时是 no-op，所以设置页的
  /// widget test 里随便调用都安全。
  Future<void> _setConcurrency(int v) async {
    await _set((d) => d.concurrency = v);
    if (!mounted) return;
    await Aria2Coordinator.instance.applyConcurrency(v);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final settings = context.watch<SettingsStore>();
    final d = settings.settings.douyin;

    // 卡「下载源与质量」的 2×2 网格（预览稿 `douyin-settings:537-538` 的
    // `opts([['下载源',…],['质量优先策略',…],['图片格式',…],['并发数',…]])`）。
    //
    // 「质量优先策略」只在下载源是质量优先那两档时才成为一项 —— 预览稿是静态
    // 截图，四格恒在；本应用里这一项对另外四档下载源毫无作用，摆一个点了也不
    // 生效的格子属于假控件，所以它按条件进出网格（格数在 3 / 4 之间变）。
    //
    // 分派用**下标**而不是 `item.label`：label 已 `t()` 过，英文档下不再是
    // 中文原文，拿它当 key 会在切语言时静默失配。下标由下面这张列表自己钉住。
    final gridItems = <OptItem<Object>>[
      OptItem<Object>(
        label: t('下载源'),
        value: d.source,
        options: DouyinSource.values,
      ),
      if (d.source.needsQualityMode)
        OptItem<Object>(
          label: t('质量优先策略'),
          value: d.qualityMode,
          options: DouyinQualityMode.values,
        ),
      OptItem<Object>(
        label: t('图片格式'),
        value: d.imageFormat,
        options: DouyinImageFormat.values,
      ),
      OptItem<Object>(
        label: t('并发数'),
        value: d.concurrency,
        options: const [1, 2, 3, 4, 5, 6, 8, 10, 12, 16],
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ① 下载源与质量
        OptGrid<Object>(
          items: gridItems,
          labelOf: _optLabel,
          onChanged: (item, v) => _applyOpt(gridItems.indexOf(item), v),
        ),
        // 下载源那一项的语义说明（原来挂在自绘下拉标题下面）。
        // 平铺后格子只有键名与当前值，说明集中放这一条 —— 删掉它等于把
        // 「质量优先」到底怎么算分这件事从界面上抹掉。
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            t('下载源决定一条视频从哪个地址下载：「质量优先」两档按 分辨率 0.4 / '
                '码率 0.4 / 帧率 0.2 给全部候选打分后取第一名；「仅音频」下的是'
                '该作品的背景音乐，不是从视频里抽音轨。'),
            style: TextStyle(fontSize: 11.5, color: c.textMuted, height: 1.5),
          ),
        ),

        // ② 筛选（预览稿 `:539-543`）
        SubSection(t('筛选')),
        SwitchRow(
          label: t('滤掉低画质档位'),
          subtitle: t('排除档位名里带 low 的候选（如 low_720p）'),
          value: d.filterLowQuality,
          onChanged: (v) => _set((q) => q.filterLowQuality = v),
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('排除 ByteVC1 编码'),
          subtitle: t('ByteVC1 是抖音自有编码，体积小但兼容性差（部分播放器/剪辑软件打不开）'),
          value: d.filterByteVc1,
          onChanged: (v) => _set((q) => q.filterByteVc1 = v),
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('下载实况图的配对视频'),
          subtitle: t('图文作品里的实况图（Live Photo）会额外下一个同名视频，'
              '与静态图共用序号，落盘后按 `_1.jpg` / `_1.mp4` 配对'),
          value: d.includeLivePhoto,
          onChanged: (v) => _set((q) => q.includeLivePhoto = v),
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('附带下载 BGM'),
          subtitle: t('图文作品额外下一份背景音乐（按地址在本批内去重）'),
          value: d.includeBgm,
          onChanged: (v) => _set((q) => q.includeBgm = v),
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('按视频时长筛选'),
          subtitle: t('**只作用于视频本身时长**（图片不受影响），单位秒；默认 0~300 秒'),
          value: d.timeRangeEnabled,
          onChanged: (v) => _set((q) => q.timeRangeEnabled = v),
        ),
        if (d.timeRangeEnabled) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _numField(c, _minSec, '下限（秒）')),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('~', style: TextStyle(color: c.textMuted)),
              ),
              Expanded(child: _numField(c, _maxSec, '上限（秒）')),
            ],
          ),
        ],

        // ③ 批量与去重（预览稿 `:544-547`）
        SubSection(t('批量与去重')),
        SwitchRow(
          label: t('跳过已下载作品'),
          subtitle: t('按**作品**粒度记账：一条作品下过任意一个文件，整条就跳过'),
          value: d.skipDownloaded,
          onChanged: (v) => _set((q) => q.skipDownloaded = v),
        ),
        const SizedBox(height: 8),
        _ledgerRow(c),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('同一作品的媒体排在一起'),
          subtitle: t('关闭后严格按抓取顺序入队'),
          value: d.groupByAweme,
          onChanged: (v) => _set((q) => q.groupByAweme = v),
        ),

        // ④ 保存与命名 —— 对齐 X 下载的设置，但**两个模块各自独立**。
        //    预览稿的抖音设置页没有这一段（那是三套皮肤并列展示时的静态稿），
        //    本应用里抖音有自己的保存根目录与两个模板，不能因为预览稿没画就删。
        SubSection(t('保存与命名')),
        FieldRow(
          value: _saveDir.text.isEmpty ? defaultDownloadDir() : _saveDir.text,
          mono: true,
          buttons: [FieldButton(t('选择'), onPressed: _pickSaveDir)],
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('启用保存文件夹'),
          subtitle: t('开启：按下面的「文件夹模板」建子目录再存；'
              '关闭：忽略文件夹模板，文件全部平铺在保存根目录里'),
          value: d.enableSaveFolder,
          onChanged: (v) => _set((q) => q.enableSaveFolder = v),
        ),
        const SizedBox(height: 8),
        // 启用模版：一键填入一套现成组合 —— 候选是一串预设 id，
        // 与「图片格式」那类枚举同形，所以也用 OptGrid 一格。
        OptGrid<String>(
          items: [
            OptItem<String>(
              label: t('启用模版'),
              value: _presetIdOf(d),
              options: [
                for (final p in kDouyinTemplatePresets) p.id,
                kDouyinCustomPresetId,
              ],
            ),
          ],
          labelOf: _presetLabel,
          onChanged: (_, v) => _applyPreset(v),
        ),

        // ⑤ 自定义文本（`%CUSTOM_TEXT%`）
        SubSection(t('自定义文本')),
        TextField(
          controller: _customText,
          style: TextStyle(fontSize: 13, color: c.textStrong),
          cursorColor: c.accent,
          decoration: InputDecoration(
            hintText: t('例如：抖音收藏'),
            hintStyle: TextStyle(fontSize: 12, color: c.textFaint),
            filled: true,
            fillColor: c.surfaceSunken,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 11,
            ),
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
              borderSide: BorderSide(color: c.accent, width: 1.4),
            ),
          ),
        ),

        // ⑥ 命名模板（预览稿 `:548-556`）
        SubSection(t('命名模板')),
        TemplateRow(
          label: t('文件夹模板'),
          hint: '%AUTHOR%',
          controller: _dirTpl,
          focusNode: _dirFocus,
          enabled: d.enableSaveFolder,
          emptyHint: d.enableSaveFolder
              ? '留空则直接存到保存目录下'
              : '「启用保存文件夹」已关闭 —— 文件全部平铺在保存目录下',
          onUseDefault: () => _dirTpl.text = '%AUTHOR%',
          example: (!d.enableSaveFolder || _dirTpl.text.trim().isEmpty)
              ? ''
              : resolveVariables(_dirTpl.text, _example).trim(),
          onPickVar: (t) => _insertToken(t, isDir: true),
          vars: kDouyinTemplateVars,
          varHint:
              '提示：文件夹模板建议只用「作者 / 作品」级变量；'
              '%MEDIA_INDEX%、%EXT% 这类逐文件变量会让每条媒体各建一个文件夹。',
        ),

        const SizedBox(height: 16),

        TemplateRow(
          label: t('文件模板'),
          hint: kDouyinDefaultFileNameTemplate,
          controller: _nameTpl,
          focusNode: _nameFocus,
          emptyHint: '留空则使用「媒体ID_时间戳.扩展名」',
          onUseDefault: () => _nameTpl.text = kDouyinDefaultFileNameTemplate,
          // 预览必须走和下载**同一条**渲染路径，否则"输出示例"看着对、
          // 下出来的名字不一样
          example: _nameTpl.text.trim().isEmpty
              ? ''
              : resolveDouyinFileName(_nameTpl.text, _example),
          onPickVar: (t) => _insertToken(t, isDir: false),
          vars: kDouyinTemplateVars,
        ),

        const SizedBox(height: 6),
        Text(t('改动会自动保存'),
            style: TextStyle(fontSize: 11.5, color: c.textFaint)),
      ],
    );
  }

  /// 网格里某一格选中新值 → 落到对应字段。
  ///
  /// 下标与上面 `gridItems` 的构造顺序一一对应（见那里的注释：不能用 label 当
  /// key，label 是译文）。`needsQualityMode` 为假时列表短一格，所以质量优先
  /// 那一档的判定放在 `d.source` 上重算一次，而不是靠固定下标。
  Future<void> _applyOpt(int index, Object value) async {
    final d = context.read<SettingsStore>().settings.douyin;
    final hasQuality = d.source.needsQualityMode;
    // 有「质量优先策略」时下标 1 是它；没有时下标 1 是「图片格式」。
    final i = hasQuality ? index : index + 1;
    switch (i) {
      case 0:
        await _set((q) => q.source = value as DouyinSource);
      case 1:
        await _set((q) => q.qualityMode = value as DouyinQualityMode);
      case 2:
        await _set((q) => q.imageFormat = value as DouyinImageFormat);
      case 3:
        await _setConcurrency(value as int);
    }
  }

  /// 枚举格子的显示文本（走各枚举自己的 `label`，与旧下拉里的文案逐字相同）。
  String _optLabel(Object v) => switch (v) {
    DouyinSource s => t(s.label),
    DouyinQualityMode m => t(m.label),
    DouyinImageFormat f => t(f.label),
    _ => '$v',
  };

  /// 「启用模版」那一格的显示文本：预设 id → 该预设的标签。
  String _presetLabel(String id) {
    if (id == kDouyinCustomPresetId) return t('自定义（已手动修改）');
    return t(kDouyinTemplatePresets.firstWhere((p) => p.id == id).label);
  }

  /// 应用「启用模版」预设 —— 两个模板框一起换掉。
  ///
  /// 不直接写 settings：文本框的监听器会去抖落盘，避免连点几次写多次磁盘。
  void _applyPreset(String id) {
    if (id == kDouyinCustomPresetId) return; // 「自定义」不是可选项
    final p = kDouyinTemplatePresets.firstWhere((e) => e.id == id);
    _dirTpl.text = p.dirTemplate;
    _nameTpl.text = p.fileNameTemplate;
  }

  /// 当前模板匹配哪个预设；都不匹配就是「自定义」。
  String _presetIdOf(DouyinConfig d) {
    for (final p in kDouyinTemplatePresets) {
      if (p.dirTemplate == d.dirTemplate &&
          p.fileNameTemplate == d.fileNameTemplate) {
        return p.id;
      }
    }
    return kDouyinCustomPresetId;
  }

  /// 把 `%VAR%` 插到**指定**模板框的光标处（与 X 下载设置页同一套行为）。
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
    AppToast.show(
        context,
        tf('已插入 {token} 到「{target}」',
            {'token': token, 'target': t(isDir ? '文件夹模板' : '文件模板')}),
        kind: AppToastKind.info);
  }
  // ── 小积木 ────────────────────────────────────────────────

  Widget _numField(
    AppColors c,
    TextEditingController ctrl,
    String label,
  ) => TextField(
    controller: ctrl,
    keyboardType: TextInputType.number,
    style: TextStyle(fontSize: 13, color: c.textStrong, fontFamily: 'Consolas'),
    cursorColor: c.accent,
    decoration: InputDecoration(
      labelText: label,
      labelStyle: TextStyle(fontSize: 12.5, color: c.textMuted),
      filled: true,
      fillColor: c.surfaceSunken,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
        borderSide: BorderSide(color: c.accent, width: 1.4),
      ),
    ),
  );

  /// 台账概况 + 「清除下载记录」。
  ///
  /// 用 `AnimatedBuilder` 直接监听台账 —— `DouyinStore` 不会把
  /// `ledger` 的变更转发出去，`context.select` 在这里收不到通知。
  Widget _ledgerRow(AppColors c) {
    final store = context.read<DouyinStore>();
    return AnimatedBuilder(
      animation: store.ledger,
      builder: (context, _) {
        final n = store.ledger.count;
        return Row(
          children: [
            Icon(Icons.fact_check_outlined, size: 14, color: c.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                n == 0 ? '还没有下载记录' : '已记录 $n 个作品',
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
            ),
            TextButton(
              onPressed: n == 0
                  ? null
                  : () async {
                      final cleared = await store.ledger.clear();
                      if (!context.mounted) return;
                      AppToast.show(
                        context,
                        cleared
                            ? t('已清除抖音下载记录')
                            : t('清除失败：记录文件写入出错，记录还在'),
                        kind: cleared
                            ? AppToastKind.success
                            : AppToastKind.error,
                      );
                    },
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: c.danger,
              ),
              child: Text(t('清除下载记录'), style: TextStyle(fontSize: 12.5)),
            ),
          ],
        );
      },
    );
  }
}
