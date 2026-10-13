import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/bili_config.dart';
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

/// 文件名模板的展开入口 —— 「输出示例」和真实落盘名字必须走同一个函数，
/// 否则预览看着对、下出来的名字不一样。
typedef BiliFileNameResolver = String Function(String template, Media media);

/// B 站文件名展开的当前实现。
///
/// **这一期直接用模板引擎的 [resolveVariables]**（逐个变量净化，走 X 侧那套
/// 「非法字符换 `!`」）。B 站自己的**整串清洗**入口 —— 与抖音侧
/// `resolveDouyinFileName` 同位置的那一层 —— 由集成方补；补上之后只替换这
/// 一个常量，本文件与「输出示例」都不用动。
///
/// 之所以现在没有整串清洗：抖音那套（`douyinFilenamify`）的规则是照抖音自己的
/// 参照物定的（保留集、下划线归并、200 上限），B 站照抄会把 B 站的名字洗成
/// 另一个样子。宁可先只做变量展开，也不要拿错的那套规则冒充对的。
const BiliFileNameResolver kBiliFileNameResolver = _biliFileNamePreview;

String _biliFileNamePreview(String template, Media media) =>
    resolveVariables(template, media);

/// 「B 站」设置区 —— 「B 站解析下载设置」这一页的分区内容。
///
/// 每一项的落点（形状对齐 `douyin_section.dart`，用户在三页之间不用换脑子）：
///
/// | 设置项 | 控件 |
/// |---|---|
/// | 画质上限 8 档 | [BiliQuality] 下拉 |
/// | 编码偏好 4 档 | [BiliCodec] 下拉 |
/// | 下载完合并成单文件 | 开关 + ffmpeg 缺失提示 |
/// | 跳过已下载 `skipDownloaded` | 开关 |
/// | 同稿件分 P 排在一起 `groupByWork` | 开关 |
/// | 并发数 `concurrency` | 下拉（与抖音同一组取值） |
/// | 自定义文本 `customText` | 输入框（`%CUSTOM_TEXT%`） |
/// | 保存根目录 / 启用保存文件夹 / 两个模板 | 与抖音同一段布局 |
///
/// **和另两个模块最不一样的一点**：这里前两项是「上限 / 偏好」，不是「就会拿到这个」。
/// B 站的 `playurl` 会按账号权限把拿不到的档位裁掉，所以说明文字必须把这件事写在
/// 控件旁边 —— 只在文档里写，用户看不到，然后来报 bug。
///
/// **刻意不做的事**：
///   * 不探测 ffmpeg、不探测账号 —— [ffmpegAvailable] 由外部传进来；
///   * 不读下载台账 —— 台账归 B 站模块自己，这里只说明它的语义；
///   * 不碰 aria2 协调器 —— 并发的即时下发由集成方接（与抖音同一条
///     `Aria2Coordinator.applyConcurrency`）。协调器是带 `Timer.periodic` 的单例，
///     在 widget 测试里构造它会挂死整条用例，所以这一层的调用点宁可留空。
class BiliSection extends StatefulWidget {
  const BiliSection({super.key, this.ffmpegAvailable});

  /// 随包的 ffmpeg 能不能用。`null` = 还没探测出来，此时不给提示。
  ///
  /// 探测属于下载合并层（要真的拉一次子进程问版本），本组件只渲染结论。
  final bool? ffmpegAvailable;

  @override
  State<BiliSection> createState() => _BiliSectionState();
}

class _BiliSectionState extends State<BiliSection> {
  late final TextEditingController _customText;
  late final TextEditingController _dirTpl;
  late final TextEditingController _nameTpl;
  late final TextEditingController _saveDir;

  /// 外挂 ffmpeg 目录（空 = 用随包那份）。
  late final TextEditingController _ffmpegDir;

  final FocusNode _dirFocus = FocusNode();
  final FocusNode _nameFocus = FocusNode();

  /// 模板预览用的示例媒体（**B 站语境**：一条 12 分 P 稿件的第 3 P）。
  ///
  /// 必须是多 P：`%P%` 在单 P 时按空处理，用单 P 样例预览的话 `<P%P%>` 整段会
  /// 消失，用户在设置页里根本看不出补零有没有生效。
  final Media _example = biliExampleMedia();

  /// 文本框 → 设置的落盘去抖（避免每敲一个字符写一次 settings.json）
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsStore>();
    final b = settings.settings.bili;
    _customText = TextEditingController(text: b.customText);
    _dirTpl = TextEditingController(text: b.dirTemplate);
    _nameTpl = TextEditingController(text: b.fileNameTemplate);
    _ffmpegDir = TextEditingController(text: b.ffmpegDir);
    // 没自己设过时，先把框子显示成「这一趟实际会落到哪」，而不是留一个
    // 看起来什么都没配的空白 —— 真正的回退规则在 resolveSaveBase 里。
    // B 站自己那一层的优先级（bili.saveDirBase → 会话目录 → X 的根目录）
    // 由集成方在 resolveSaveBase 里补，这里先按「没填就沿用既有那条链」显示。
    _saveDir = TextEditingController(
      text: b.saveDirBase.isNotEmpty
          ? b.saveDirBase
          : resolveSaveBase(
              sessionSaveDir: context.read<DownloadStore>().defaultSaveDir,
              xSaveDirBase: settings.settings.download.saveDirBase,
              fallback: '',
            ),
    );
    for (final c in [_customText, _dirTpl, _nameTpl]) {
      c.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _customText.dispose();
    _dirTpl.dispose();
    _nameTpl.dispose();
    _saveDir.dispose();
    _ffmpegDir.dispose();
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
    context.read<SettingsStore>().setBili((b) {
      b.customText = _customText.text.trim();
      b.dirTemplate = _dirTpl.text.trim();
      b.fileNameTemplate = _nameTpl.text.trim();
    });
  }

  Future<void> _set(void Function(BiliConfig b) mutate) =>
      context.read<SettingsStore>().setBili(mutate);

  /// 选保存根目录 —— 只写 B 站自己这一份，不动另外两个模块的设置。
  Future<void> _pickSaveDir() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    if (mounted) setState(() => _saveDir.text = result);
    await _set((b) => b.saveDirBase = result);
  }

  /// 选外挂 ffmpeg 所在目录 —— 空串表示改回「用随包那份」。
  ///
  /// 只记目录，不改 [BiliConfig.ffmpegDir] 之外的任何东西：真正生效靠
  /// `Aria2Coordinator` 监听设置变化后把它同步给 `BiliMerger.setUserDir`。
  Future<void> _pickFfmpegDir() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;
    if (mounted) setState(() => _ffmpegDir.text = result);
    await _set((b) => b.ffmpegDir = result);
  }

  /// 清空外挂目录 = 回到随包那份。
  Future<void> _clearFfmpegDir() async {
    if (mounted) setState(() => _ffmpegDir.text = '');
    await _set((b) => b.ffmpegDir = '');
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final settings = context.watch<SettingsStore>();
    final b = settings.settings.bili;

    // 卡「画质与编码」的网格（预览稿 `bili-settings:637-638` 的
    // `opts([['画质上限',…],['编码偏好',…],['并发数',…],['下载完合并',…]])`）。
    //
    // 分派用**下标**：label 已 `t()` 过，英文档下不再是中文原文，拿它当 key
    // 会在切语言时静默失配。「下载完合并」在预览稿里也是一格 `opts`，
    // 但本应用里它带一条 ffmpeg 缺失提示（`bili_section_test` 钉着），
    // 所以那一格做成只读当前值，真正的开关在网格下面单独一行 ——
    // 开关配提示，比一个点开只有「是 / 否」的格子更直白。
    final gridItems = <OptItem<Object>>[
      OptItem<Object>(
        label: t('画质上限'),
        value: b.quality,
        options: BiliQuality.values,
      ),
      OptItem<Object>(
        label: t('编码偏好'),
        value: b.codec,
        options: BiliCodec.values,
      ),
      OptItem<Object>(
        label: t('并发数'),
        value: b.concurrency,
        options: const [1, 2, 3, 4, 5, 6, 8, 10, 12, 16],
      ),
      OptItem<Object>(
        label: t('下载完合并'),
        value: b.mergeAfterDownload,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ① 画质与编码
        OptGrid<Object>(
          items: gridItems,
          labelOf: _optLabel,
          onChanged: (item, v) => _applyOpt(gridItems.indexOf(item), v),
        ),
        // 画质上限的语义说明 —— 「上限」不是「保证」这件事必须写在控件旁边
        // （只在文档里写、用户看不到，然后来报 bug）。
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            t('这里是「上限」而不是保证：B 站会按你账号的实际权限（大会员、付费稿件）'
                '把拿不到的高阶档位直接裁掉，所以选了「1080P 60帧」也可能只下到 '
                '1080P。选高了不会报错，只会安静地退回能拿到的那一档。'),
            style: TextStyle(fontSize: 11.5, color: c.textMuted, height: 1.5),
          ),
        ),

        // ② 合并开关（预览稿把它也画成一格 opts，这里保留为开关 + 提示）
        const SizedBox(height: 8),
        SwitchRow(
          label: t('下载完成后合并'),
          subtitle: t('B 站的视频流和音频流是分开的两个文件，下完是两个 .m4s，'
              '各自都不能单独播放 —— 必须先用 ffmpeg 合成一个 .mp4 才能看，'
              '所以默认开着。留这个开关只有一种用途：合并要用的 ffmpeg 被安全软件'
              '拦下时，先拿到原始流自己处理，总比什么都拿不到强。'),
          value: b.mergeAfterDownload,
          onChanged: (v) => _set((q) => q.mergeAfterDownload = v),
        ),
        // 探测是下载合并层的事（要真起子进程问版本），这里只负责把结论说出来。
        if (b.mergeAfterDownload && widget.ffmpegAvailable == false)
          _hint(
            c,
            Icons.warning_amber_rounded,
            c.warning,
            t('当前环境找不到可用的 ffmpeg，合并这一步会失败：'
                '下完只会得到两个不能单独播放的 .m4s 文件。'),
          ),

        // ③ 容器与合并（预览稿 `:639-640`）
        SubSection(t('容器与合并')),
        OptGrid<Object>(
          items: [
            OptItem<Object>(
              label: t('容器'),
              value: b.container,
              options: BiliContainer.values,
            ),
            OptItem<Object>(
              label: t('限速'),
              value: b.speedLimitKbps,
              options: const [0, 256, 512, 1024, 2048, 4096, 8192],
            ),
          ],
          labelOf: _optLabel,
          onChanged: (item, v) => _applyContainerOpt(item, v),
        ),
        const SizedBox(height: 8),
        // 外挂 ffmpeg 目录（`b.ffmpegDir`）—— 预览稿那一格画的是路径本身，
        // 这里用 `.row .field .btn`：路径 + 「选择」，清空走字段右侧的叉。
        FieldRow(
          value: b.ffmpegDir.isEmpty ? t('（空 = 用自带那份）') : b.ffmpegDir,
          mono: true,
          buttons: [
            FieldButton(t('选择'), onPressed: _pickFfmpegDir),
            if (b.ffmpegDir.isNotEmpty)
              FieldButton(
                t('改回用自带那份'),
                ghost: true,
                danger: true,
                onPressed: _clearFfmpegDir,
              ),
          ],
        ),

        // ④ 下载（原「跳过已下载 / 排序」两项，预览稿把它们并进了各自的选项组）
        const SizedBox(height: 8),
        SwitchRow(
          label: t('跳过已下载的分 P'),
          subtitle: t('按「BV 号 + 分 P 内容 ID」记账：下过的分 P 不再重下。'
              '记的是台账而不是磁盘上的文件，所以把文件移走、甚至删掉，'
              '也仍然算下过 —— 想重下要么关掉这个开关，要么清掉记录。'),
          value: b.skipDownloaded,
          onChanged: (v) => _set((q) => q.skipDownloaded = v),
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('同一稿件的分 P 排在一起'),
          subtitle: t('一个稿件的多个分 P 会占连续位置，跨稿件的才交错。'
              '关闭后严格按抓取顺序入队。'),
          value: b.groupByWork,
          onChanged: (v) => _set((q) => q.groupByWork = v),
        ),

        // ⑤ 附加文件（预览稿 `:641-647`）
        SubSection(t('附加文件')),
        SwitchRow(
          label: t('保存弹幕'),
          subtitle: t('转 ASS 后可内封'),
          value: b.saveDanmaku,
          onChanged: (v) => _set((q) => q.saveDanmaku = v),
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('保存字幕'),
          subtitle: t('按语言筛可选；ASS 格式才能内封进 MKV'),
          value: b.saveSubtitle,
          onChanged: (v) => _set((q) => q.saveSubtitle = v),
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('保存封面'),
          subtitle: t('原图存成 `<base>.封面.png`'),
          value: b.saveCover,
          onChanged: (v) => _set((q) => q.saveCover = v),
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('保存章节'),
          subtitle: t('绝大多数稿件没有分段章节，没有时一个参数都不多加'),
          value: b.saveChapter,
          onChanged: (v) => _set((q) => q.saveChapter = v),
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('保存元数据'),
          subtitle: t('nfo 给媒体库读，会多取一次标签；json 是我们自己那份解析结果'),
          value: b.saveMetadata,
          onChanged: (v) => _set((q) => q.saveMetadata = v),
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('把字幕内封进容器'),
          subtitle: t('只在 MKV 下可用 —— 前提是开了合并、且字幕格式是 ASS'),
          value: b.embedSubtitleTrack,
          onChanged: (v) => _set((q) => q.embedSubtitleTrack = v),
        ),

        // ⑥ 字幕样式（预览稿 `:648-649`，抄 B 站播放器定义）
        SubSection(t('字幕样式')),
        // 弹幕样式的四档取值：字体 / 字号 / 不透明度 / 底部边距 —— 都在
        // 「下载选项」对话框里编辑（那是它原本的入口，也是唯一能预览的地方）。
        // 这里平铺**当前值**，点开去那一处改，不另起一套控件。
        OptGrid<String>(
          items: [
            OptItem<String>(label: t('字体'), value: b.danmakuFontFace),
            OptItem<String>(label: t('字号'), value: '${b.danmakuFontSize}'),
            OptItem<String>(label: t('不透明度'), value: '${b.danmakuOpacity}%'),
            OptItem<String>(label: t('底部边距'), value: '${b.danmakuMarginV} px'),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            t('这四项在 B 站解析页的「下载选项」里改 —— 那里能即时看到排版效果。'),
            style: TextStyle(fontSize: 11.5, color: c.textFaint),
          ),
        ),

        // ⑦ 自定义文本（`%CUSTOM_TEXT%`）
        SubSection(t('自定义文本')),
        TextField(
          controller: _customText,
          style: TextStyle(fontSize: 13, color: c.textStrong),
          cursorColor: c.accent,
          decoration: InputDecoration(
            hintText: t('例如：追番清单'),
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

        // ⑧ 保存与命名 —— 三个模块各自独立，不能因为预览稿没画这一段就删
        SubSection(t('保存与命名')),
        FieldRow(
          value: _saveDir.text.isEmpty ? t('默认（exe 同级）') : _saveDir.text,
          mono: true,
          buttons: [FieldButton(t('选择'), onPressed: _pickSaveDir)],
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: t('启用保存文件夹'),
          subtitle: t('开启：按下面的「文件夹模板」建子目录再存；'
              '关闭：忽略文件夹模板，文件全部平铺在保存根目录里'),
          value: b.enableSaveFolder,
          onChanged: (v) => _set((q) => q.enableSaveFolder = v),
        ),
        const SizedBox(height: 8),
        OptGrid<String>(
          items: [
            OptItem<String>(
              label: t('启用模版'),
              value: _presetIdOf(b),
              options: [
                for (final p in kBiliTemplatePresets) p.id,
                kBiliCustomPresetId,
              ],
            ),
          ],
          labelOf: _presetLabel,
          onChanged: (_, v) => _applyPreset(v),
        ),

        // ⑨ 命名模板（预览稿 `:650-658`）
        SubSection(t('命名模板')),
        TemplateRow(
          label: t('文件夹模板'),
          hint: kBiliDefaultDirTemplate,
          controller: _dirTpl,
          focusNode: _dirFocus,
          enabled: b.enableSaveFolder,
          emptyHint: b.enableSaveFolder
              ? t('留空则直接存到保存目录下')
              : t('「启用保存文件夹」已关闭 —— 文件全部平铺在保存目录下'),
          onUseDefault: () => _dirTpl.text = kBiliDefaultDirTemplate,
          example: (!b.enableSaveFolder || _dirTpl.text.trim().isEmpty)
              ? ''
              : resolveVariables(_dirTpl.text, _example).trim(),
          onPickVar: (token) => _insertToken(token, isDir: true),
          vars: kBiliTemplateVars,
          varHint:
              t('提示：文件夹模板建议只用「作品 / UP 主」这一级的变量；'
                  '%MEDIA_INDEX%、%EXT% 这类逐文件的变量会让每个文件各建一个文件夹。'
                  '分 P 想挤进同一个目录就别在这里放 %P%。'),
        ),

        const SizedBox(height: 16),

        TemplateRow(
          label: t('文件模板'),
          hint: kBiliDefaultFileNameTemplate,
          controller: _nameTpl,
          focusNode: _nameFocus,
          emptyHint: t('留空则不按模板命名 —— 兜底名字由下载层决定，点「填入默认」恢复'),
          onUseDefault: () => _nameTpl.text = kBiliDefaultFileNameTemplate,
          // 预览走 kBiliFileNameResolver —— 和下载侧同一个入口，见上面那段注释
          example: _nameTpl.text.trim().isEmpty
              ? ''
              : kBiliFileNameResolver(_nameTpl.text, _example),
          onPickVar: (token) => _insertToken(token, isDir: false),
          vars: kBiliTemplateVars,
        ),

        const SizedBox(height: 6),
        Text(
          t('改动会自动保存'),
          style: TextStyle(fontSize: 11.5, color: c.textFaint),
        ),
      ],
    );
  }

  /// 网格里某一格选中新值 → 落到对应字段。
  ///
  /// 下标与 `gridItems` 的构造顺序一一对应（label 是译文，不能当 key）。
  /// 「下载完合并」那一格没有 `options`（只读），所以它不会被走到这里。
  Future<void> _applyOpt(int index, Object value) async {
    switch (index) {
      case 0:
        await _set((q) => q.quality = value as BiliQuality);
      case 1:
        await _set((q) => q.codec = value as BiliCodec);
      case 2:
        await _set((q) => q.concurrency = value as int);
    }
  }

  /// 「容器与合并」那张网格的分派（容器 / 限速）。
  Future<void> _applyContainerOpt(OptItem<Object> item, Object value) async {
    if (value is BiliContainer) {
      await _set((q) => q.container = value);
      return;
    }
    if (value is int) await _set((q) => q.speedLimitKbps = value);
  }

  /// 枚举格子的显示文本（走各枚举自己的 `label`，与旧下拉里的文案逐字相同）。
  String _optLabel(Object v) => switch (v) {
    BiliQuality q => t(q.label),
    BiliCodec e => t(e.label),
    BiliContainer k => t(k.label),
    int n => n == 0 ? t('不限') : '$n KB/s',
    bool on => t(on ? '是' : '否'),
    _ => '$v',
  };

  /// 「启用模版」那一格的显示文本：预设 id → 该预设的标签。
  String _presetLabel(String id) {
    if (id == kBiliCustomPresetId) return t('自定义（已手动修改）');
    return t(kBiliTemplatePresets.firstWhere((p) => p.id == id).label);
  }

  /// 应用「启用模版」预设 —— 两个模板框一起换掉。
  ///
  /// 不直接写 settings：文本框的监听器会去抖落盘，避免连点几次写多次磁盘。
  void _applyPreset(String id) {
    if (id == kBiliCustomPresetId) return; // 「自定义」不是可选项
    final p = kBiliTemplatePresets.firstWhere((e) => e.id == id);
    _dirTpl.text = p.dirTemplate;
    _nameTpl.text = p.fileNameTemplate;
  }

  /// 当前模板匹配哪个预设；都不匹配就是「自定义」。
  String _presetIdOf(BiliConfig b) {
    for (final p in kBiliTemplatePresets) {
      if (p.dirTemplate == b.dirTemplate &&
          p.fileNameTemplate == b.fileNameTemplate) {
        return p.id;
      }
    }
    return kBiliCustomPresetId;
  }

  /// 把 `%VAR%` 插到**指定**模板框的光标处（与另两个模块的设置页同一套行为）。
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

  // ── 小积木 ────────────────────────────────────────────────────
  //
  // S9b 平铺改造后，原先的 `_label` / `_dropdown` / `_switch` 三个自绘积木
  // 已被共享组件（OptGrid / SwitchRow / SubSection）取代并删除 —— 留着它们
  // 会让「同一页里两套字号与间距」复活，正是 S9 要消灭的东西。

  /// 一行挂在某个选项下面的小字（图标 + 文案），用来放「必须说的事」。
  Widget _hint(AppColors c, IconData icon, Color color, String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 11.5, color: color, height: 1.5),
          ),
        ),
      ],
    ),
  );
}
