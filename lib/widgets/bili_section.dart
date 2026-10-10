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

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final settings = context.watch<SettingsStore>();
    final b = settings.settings.bili;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [

        // ① 画质上限
        _label(
          c,
          t('画质上限'),
          t('这里是「上限」而不是保证：B 站会按你账号的实际权限（大会员、付费稿件）'
              '把拿不到的高阶档位直接裁掉，所以选了「1080P 60帧」也可能只下到 '
              '1080P。这是 B 站和本项目另两个模块最大的行为差异 —— 那里档位由平台'
              '返回的候选决定，这里还要多过一道账号权限，选高了不会报错，只会安静地'
              '退回能拿到的那一档。'),
        ),
        _dropdown<BiliQuality>(
          value: b.quality,
          items: [
            for (final q in BiliQuality.values)
              DropdownMenuItem(value: q, child: Text(t(q.label))),
          ],
          onChanged: (v) => _set((q) => q.quality = v),
        ),

        // ② 编码偏好
        const SizedBox(height: 16),
        _label(
          c,
          t('编码偏好'),
          t('同一档画质 B 站通常同时给 H.264 / HEVC / AV1 三条流。选哪条'
              '不影响清晰度，只影响体积和播放器兼容性 —— HEVC / AV1 同画质更小，'
              '但老播放器与部分剪辑软件不认；「自动（兼容性优先）」挑哪边都能播的'
              '那条。这条同样只是偏好：稿件没有该编码的流时会退回其它编码，'
              '画质上限那套账号裁档的规则对这里一样成立。'),
        ),
        _dropdown<BiliCodec>(
          value: b.codec,
          items: [
            for (final e in BiliCodec.values)
              DropdownMenuItem(value: e, child: Text(t(e.label))),
          ],
          onChanged: (v) => _set((q) => q.codec = v),
        ),

        // ③ 合并
        const SizedBox(height: 8),
        _switch(
          c,
          t('下载完成后合并'),
          t('B 站的视频流和音频流是分开的两个文件，下完是两个 .m4s，'
              '各自都不能单独播放 —— 必须先用 ffmpeg 合成一个 .mp4 才能看，'
              '所以默认开着。留这个开关只有一种用途：合并要用的 ffmpeg 被安全软件'
              '拦下时，先拿到原始流自己处理，总比什么都拿不到强。'),
          b.mergeAfterDownload,
          (v) => _set((q) => q.mergeAfterDownload = v),
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

        // ④ 下载
        const SizedBox(height: 6),
        _switch(
          c,
          t('跳过已下载的分 P'),
          t('按「BV 号 + 分 P 内容 ID」记账：下过的分 P 不再重下。'
              '记的是台账而不是磁盘上的文件，所以把文件移走、甚至删掉，'
              '也仍然算下过 —— 想重下要么关掉这个开关，要么清掉记录。'),
          b.skipDownloaded,
          (v) => _set((q) => q.skipDownloaded = v),
        ),

        // ⑤ 排序
        const SizedBox(height: 6),
        _switch(
          c,
          t('同一稿件的分 P 排在一起'),
          t('一个稿件的多个分 P 会占连续位置，跨稿件的才交错。'
              '关闭后严格按抓取顺序入队。'),
          b.groupByWork,
          (v) => _set((q) => q.groupByWork = v),
        ),

        // ⑥ 并发数
        const SizedBox(height: 16),
        _label(
          c,
          t('并发数'),
          t('aria2 同时下载的任务数上限（默认 4）。这是那一个下载进程的全局上限，'
              '不是只作用于 B 站的队列 —— 调大它，同时在下的别的内容也会一起挤这'
              '几个槽位。'),
        ),
        _dropdown<int>(
          value: b.concurrency,
          items: [
            for (final n in const [1, 2, 3, 4, 5, 6, 8, 10, 12, 16])
              DropdownMenuItem(value: n, child: Text('$n')),
          ],
          onChanged: (v) => _set((q) => q.concurrency = v),
        ),

        // ⑦ 自定义文本
        const SizedBox(height: 16),
        _label(
          c,
          t('自定义文本'),
          t('模板变量 %CUSTOM_TEXT% 的输出内容，可用来给文件名加前缀、标注批次等。'
              '留空时这个变量就是空串。'),
        ),
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

        // ⑧ 保存与命名 —— 对齐另两个模块的设置，但**三个模块各自独立**
        const SizedBox(height: 22),
        Divider(height: 1, color: c.line),
        const SizedBox(height: 18),
        _label(
          c,
          t('保存与命名'),
          t('B 站下载存到哪个根目录、往下怎么建子文件夹、文件叫什么名字，'
              '都由下面这几项决定。可用变量都是 B 站语义的：%WORK_TITLE% 作品标题、'
              '%PART_TITLE% 分P标题、%P% 分P序号、%BVID% BV 号、'
              '%UP_NAME% UP 主昵称、%QUALITY% 画质、%CODEC% 编码格式等。'),
        ),

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
          t('启用保存文件夹'),
          t('开启：按下面的「文件夹模板」建子目录再存；'
              '关闭：忽略文件夹模板，文件全部平铺在保存根目录里'),
          b.enableSaveFolder,
          (v) => _set((q) => q.enableSaveFolder = v),
        ),
        const SizedBox(height: 18),

        // 启用模版：一键填入一套现成组合
        _label(
          c,
          t('启用模版'),
          t('从现成组合里挑一套，一键填进下面两个模板框；之后仍可手动微调，'
              '改过之后这里会显示「自定义」。'),
        ),
        _dropdown<String>(
          value: _presetIdOf(b),
          items: [
            for (final p in kBiliTemplatePresets)
              DropdownMenuItem(value: p.id, child: Text(t(p.label))),
            DropdownMenuItem(
              value: kBiliCustomPresetId,
              child: Text(t('自定义（已手动修改）')),
            ),
          ],
          onChanged: _applyPreset,
        ),
        const SizedBox(height: 18),

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

  // ── 小积木（与抖音分区同一套字号与间距，不另立规格）────────────

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
