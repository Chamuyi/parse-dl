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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [

        // ① 下载源
        _label(
          c,
          '下载源',
          '决定一条视频从哪个地址下载。「质量优先」两档会按「质量优先策略」'
              '给全部候选码率打分后取第一名（三个分量加权，权重见实现里的 '
              'kDouyinQualityWeights）；'
              '「仅音频」下载的是该作品的背景音乐，不是从视频里抽音轨。',
        ),
        _dropdown<DouyinSource>(
          value: d.source,
          items: [
            for (final s in DouyinSource.values)
              DropdownMenuItem(value: s, child: Text(t(s.label))),
          ],
          onChanged: (v) => _set((q) => q.source = v),
        ),

        // ② 质量优先策略（只有「质量优先」两档才需要）
        if (d.source.needsQualityMode) ...[
          const SizedBox(height: 16),
          _label(
            c,
            '质量优先策略',
            '「自动」按 分辨率 0.4 / 码率 0.4 / 帧率 0.2 打分，其余三档把'
                '所选指标提到 0.7 权重。注意：任一变体缺分辨率、码率或帧率时'
                '直接判 0 分 —— 刻意保留的行为，改动它会让某些作品换到另一个清晰度版本。',
          ),
          _dropdown<DouyinQualityMode>(
            value: d.qualityMode,
            items: [
              for (final m in DouyinQualityMode.values)
                DropdownMenuItem(value: m, child: Text(t(m.label))),
            ],
            onChanged: (v) => _set((q) => q.qualityMode = v),
          ),
        ],

        // ③ 图片格式
        const SizedBox(height: 16),
        _label(
          c,
          '图片格式',
          '抖音图集会下发多个镜像地址（扩展名可能不同）。'
              '「其它格式优先」把非 webp 的镜像排到前面 —— 只改顺序、'
              '不改 URL，这样不会破坏 CDN 的签名校验。',
        ),
        _dropdown<DouyinImageFormat>(
          value: d.imageFormat,
          items: [
            for (final f in DouyinImageFormat.values)
              DropdownMenuItem(value: f, child: Text(t(f.label))),
          ],
          onChanged: (v) => _set((q) => q.imageFormat = v),
        ),

        // ④ 候选过滤
        const SizedBox(height: 8),
        _switch(
          c,
          '滤掉低画质档位',
          '排除档位名里带 low 的候选（如 low_720p）',
          d.filterLowQuality,
          (v) => _set((q) => q.filterLowQuality = v),
        ),
        _switch(
          c,
          '排除 ByteVC1 编码',
          'ByteVC1 是抖音自有编码，体积小但兼容性差（部分播放器/剪辑软件打不开）',
          d.filterByteVc1,
          (v) => _set((q) => q.filterByteVc1 = v),
        ),

        // ⑤ 图文作品附加内容
        const SizedBox(height: 6),
        _switch(
          c,
          '下载实况图的配对视频',
          '图文作品里的实况图（Live Photo）会额外下一个同名视频，'
              '与静态图共用序号，落盘后按 `_1.jpg` / `_1.mp4` 配对',
          d.includeLivePhoto,
          (v) => _set((q) => q.includeLivePhoto = v),
        ),
        _switch(
          c,
          '附带下载 BGM',
          '图文作品额外下一份背景音乐（按地址在本批内去重）',
          d.includeBgm,
          (v) => _set((q) => q.includeBgm = v),
        ),

        // ⑥ 已下载台账
        const SizedBox(height: 6),
        _switch(
          c,
          '跳过已下载作品',
          '按**作品**粒度记账：一条作品下过任意一个文件，整条就跳过',
          d.skipDownloaded,
          (v) => _set((q) => q.skipDownloaded = v),
        ),
        _ledgerRow(c),

        // ⑦ 排序
        const SizedBox(height: 6),
        _switch(
          c,
          '同一作品的媒体排在一起',
          '关闭后严格按抓取顺序入队',
          d.groupByAweme,
          (v) => _set((q) => q.groupByAweme = v),
        ),

        // ⑧ 时长范围
        const SizedBox(height: 6),
        _switch(
          c,
          '按视频时长筛选',
          '**只作用于视频本身时长**（图片不受影响），单位秒；'
              '默认 0~300 秒',
          d.timeRangeEnabled,
          (v) => _set((q) => q.timeRangeEnabled = v),
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

        // ⑨ 并发数
        const SizedBox(height: 16),
        _label(
          c,
          '并发数',
          'aria2 同时下载的任务数上限（参照实现的 limit，默认 4）。'
              '这是全局选项，X 的下载同样生效。',
        ),
        _dropdown<int>(
          value: d.concurrency,
          items: [
            for (final n in const [1, 2, 3, 4, 5, 6, 8, 10, 12, 16])
              DropdownMenuItem(value: n, child: Text('$n')),
          ],
          onChanged: _setConcurrency,
        ),

        // ⑩ 自定义文本
        const SizedBox(height: 16),
        _label(
          c,
          '自定义文本',
          '模板变量 %CUSTOM_TEXT% 的输出内容（参照实现的「自定义文本」组件）。'
              '可用来给文件名加前缀、标注批次等。',
        ),
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
        // ⑪ 保存与命名 —— 对齐 X 下载的设置，但**两个模块各自独立**
        const SizedBox(height: 22),
        Divider(height: 1, color: c.line),
        const SizedBox(height: 18),
        _label(
          c,
          '保存与命名',
          '抖音下载存到哪个根目录、往下怎么建子文件夹、文件叫什么名字，都由下面这几项决定。'
              '可用变量都是抖音语义的：%AUTHOR% 作者、%AWEME_ID% 作品 ID、'
              '%DESCRIPTION% 作品描述、%CREATE_TIME% 创建时间等。',
        ),

        // 保存路径—— 此前抖音侧没有这一项，抖音的下载一直落在
        // 别处设的根目录上。留空时仍沿用那条旧规则，见 resolveSaveBase。
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

        _switch(
          c,
          '启用保存文件夹',
          '开启：按下面的「文件夹模板」建子目录再存；'
              '关闭：忽略文件夹模板，文件全部平铺在保存根目录里',
          d.enableSaveFolder,
          (v) => _set((q) => q.enableSaveFolder = v),
        ),
        const SizedBox(height: 18),

        // 启用模版：一键填入一套现成组合
        _label(
          c,
          '启用模版',
          '从现成组合里挑一套，一键填进下面两个模板框；之后仍可手动微调，'
              '改过之后这里会显示「自定义」。',
        ),
        _dropdown<String>(
          value: _presetIdOf(d),
          items: [
            for (final p in kDouyinTemplatePresets)
              DropdownMenuItem(value: p.id, child: Text(t(p.label))),
            DropdownMenuItem(
              value: kDouyinCustomPresetId,
              child: Text(t('自定义（已手动修改）')),
            ),
          ],
          onChanged: _applyPreset,
        ),
        const SizedBox(height: 18),

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
        Text(t('改动会自动保存'), style: TextStyle(fontSize: 11.5, color: c.textFaint)),
      ],
    );
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

  Widget _label(AppColors c, String title, String desc) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            color: c.textStrong,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          desc,
          style: TextStyle(fontSize: 12.5, color: c.textMuted, height: 1.5),
        ),
      ],
    ),
  );

  Widget _dropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required void Function(T) onChanged,
  }) {
    final c = AppTheme.colorsOf(context);
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      dropdownColor: c.surfaceSolid,
      style: TextStyle(fontSize: 13, color: c.textStrong),
      icon: Icon(Icons.expand_more_rounded, size: 18, color: c.textMuted),
      decoration: InputDecoration(
        filled: true,
        fillColor: c.surfaceSunken,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
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
      items: items,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Widget _switch(
    AppColors c,
    String title,
    String subtitle,
    bool value,
    void Function(bool) onChanged,
  ) => Material(
    type: MaterialType.transparency,
    child: SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: TextStyle(fontSize: 13.5, color: c.textStrong)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: c.textMuted, height: 1.4),
      ),
      value: value,
      activeThumbColor: c.accent,
      onChanged: onChanged,
    ),
  );

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
