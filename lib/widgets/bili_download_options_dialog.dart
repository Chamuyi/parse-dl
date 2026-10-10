/// B 站「下载选项」弹窗 —— 点下载之后、投队列之前那一屏。
///
/// **它的语义只有一条**：这里改的东西**只作用于这一批**。
/// 关掉弹窗返回的是 [BiliConfig] 的覆盖副本，调用方拿它跑完就丢；
/// 只有点了「同步为默认」才写进 `settings.json`。做成这样是因为
/// 「这批想要 MKV」和「以后都想要 MKV」是两件不同的事，
/// 混在一起的后果是用户随手一试就把自己的默认设置改坏了。
///
/// 三页签的形状照外部参照实现，但**只放这一期真能兑现的格子**：
/// 保存目录与两套命名模板仍在设置页 —— 那是「这批存到哪」的另一件事，
/// 塞进临时弹窗反而容易误改持久设置。
library;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/bili_config.dart';
import '../theme/app_theme.dart';

/// 用户在这个弹窗里的三种收尾。
enum BiliOptionsAction { confirm, confirmAndSync, cancel }

class BiliOptionsResult {
  const BiliOptionsResult(this.action, this.config);

  final BiliOptionsAction action;

  /// 这一批要照它下的一份配置。`cancel` 时是 null（调用方本来就不会用）。
  final BiliConfig? config;
}

/// B 站常见的字幕语言码。B 站自己回的是 BCP-47（`zh-CN`、`ai-es`…），
/// 这里按**人工字幕**那一套列，AI 字幕由「仅人工字幕」那个开关管，不进这张表。
const List<(String, String)> kBiliSubtitleLangChoices = [
  ('zh-CN', '中文'),
  ('en', 'English'),
  ('ja', '日本語'),
  ('ko', '한국어'),
  ('es', 'Español'),
  ('fr', 'Français'),
  ('de', 'Deutsch'),
  ('ru', 'Русский'),
];

Future<BiliOptionsResult> showBiliDownloadOptions(
  BuildContext context,
  BiliConfig current,
) async {
  final r = await showDialog<BiliOptionsResult>(
    context: context,
    // 弹窗里改的是 `_c` 这份副本，交出去的是**它**而不是 current ——
    // 在弹窗外面再拼一次结果就会拿到没改过的配置，表现是「改了没生效」。
    builder: (_) => _BiliOptionsDialog(current),
  );
  return r ?? const BiliOptionsResult(BiliOptionsAction.cancel, null);
}

class _BiliOptionsDialog extends StatefulWidget {
  const _BiliOptionsDialog(this.initial);

  final BiliConfig initial;

  @override
  State<_BiliOptionsDialog> createState() => _BiliOptionsDialogState();
}

class _BiliOptionsDialogState extends State<_BiliOptionsDialog>
    with SingleTickerProviderStateMixin {
  late final BiliConfig _c = widget.initial.copyWith();
  late final TabController _tabs = TabController(length: 3, vsync: this);

  /// 弹窗里改过哪些格子。没改过时「同步为默认」按下去等于把原样再写一遍，
  /// 用户看不出差别，还以为自己改了设置。
  bool get _dirty {
    final a = _c.toJson(), b = widget.initial.toJson();
    for (final k in a.keys) {
      if ('${a[k]}' != '${b[k]}') return true;
    }
    return false;
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _put(void Function(BiliConfig) mutate) => setState(() => mutate(_c));

  void _pop(BiliOptionsAction action) =>
      Navigator.pop(context, BiliOptionsResult(action, _c));

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return AlertDialog(
      title: Text(t('下载选项')),
      content: SizedBox(
        width: 680,
        height: 520,
        child: Column(
          children: [
            TabBar(
              controller: _tabs,
              tabs: [Tab(text: t('媒体设置')), Tab(text: t('附加文件')), Tab(text: t('下载设置'))],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [_media(c), _additional(c), _download(c)],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _pop(BiliOptionsAction.cancel),
          child: Text(t('取消')),
        ),
        TextButton(
          onPressed: () => _pop(BiliOptionsAction.confirmAndSync),
          child: Text(t('同步为默认并下载')),
        ),
        FilledButton(
          onPressed: () => _pop(BiliOptionsAction.confirm),
          child: Text(_dirty ? t('开始下载') : t('按默认开始下载')),
        ),
      ],
    );
  }

  // ── ① 媒体设置 ──────────────────────────────────────────────

  Widget _media(AppColors c) => _scroll([
    _label(c, t('画质上限'), t('是「上限」不是保证：B 站会按账号权限把拿不到的高阶档裁掉。')),
    _drop<BiliQuality>(
      value: _c.quality,
      items: [for (final q in BiliQuality.values) (q, t(q.label))],
      onChanged: (v) => _put((x) => x.quality = v),
    ),
    _label(c, t('编码偏好'), t('不影响清晰度，只影响体积与播放器兼容性。')),
    _drop<BiliCodec>(
      value: _c.codec,
      items: [for (final e in BiliCodec.values) (e, t(e.label))],
      onChanged: (v) => _put((x) => x.codec = v),
    ),
    _label(c, t('容器'), t('MP4 兼容性最好；只有 MKV 装得下内封字幕轨。')),
    _drop<BiliContainer>(
      value: _c.container,
      items: [for (final e in BiliContainer.values) (e, t(e.label))],
      onChanged: (v) => _put((x) => x.container = v),
    ),
    _switch(
      c,
      t('下载完成后合并'),
      t('关掉就留两条 .m4s 裸流，它们各自都不能单独播放。'),
      _c.mergeAfterDownload,
      (v) => _put((x) => x.mergeAfterDownload = v),
    ),
    _switch(
      c,
      t('内封字幕轨'),
      t('把 ass 作为一条字幕轨塞进成品，而不是只留侧文件。'),
      _c.embedSubtitleTrack,
      (v) => _put((x) => x.embedSubtitleTrack = v),
    ),
    ..._embedWarnings(c, forDanmaku: false),
  ]);

  /// 内封的前提缺哪几条，就**原话摆出来**。
  ///
  /// 参照实现在这里是「条件不满足就静默跳过」：用户勾了内封，成品里却什么都没有，
  /// 也没人告诉他为什么。开关置灰却不说明，和静默跳过只差一层窗户纸。
  List<Widget> _embedWarnings(AppColors c, {required bool forDanmaku}) {
    final missing = _c.embedBlockReason(forDanmaku: forDanmaku);
    if (missing == null) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 15, color: c.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: () {
                // 单独一句 t(...) 而不是塞进插值里：漏翻扫描器读不到
                // 字符串插值里的 t()，那条 key 就会被判成英文表里的孤儿条目。
                final head = t('内封现在还差');
                return Text(
                  '$head：${missing.join('、')}',
                  style: TextStyle(fontSize: 12, color: c.textMuted),
                );
              }(),
            ),
          ],
        ),
      ),
    ];
  }

  // ── ② 附加文件 ──────────────────────────────────────────────

  Widget _additional(AppColors c) => _scroll([
    _note(c, t('附加文件不影响成品：缺了哪样会写在那一行的完成提示上，不静默。')),
    _switch(
      c,
      t('弹幕'),
      t('按视频时间每 6 分钟一段取回，长稿件就是几十个请求，这里限了并发。'),
      _c.saveDanmaku,
      (v) => _put((x) => x.saveDanmaku = v),
    ),
    if (_c.saveDanmaku) ...[
      _drop<BiliDanmakuFormat>(
        value: _c.danmakuFormat,
        items: [for (final e in BiliDanmakuFormat.values) (e, t(e.label))],
        onChanged: (v) => _put((x) => x.danmakuFormat = v),
      ),
      if (_c.danmakuFormat == BiliDanmakuFormat.ass) ..._danmakuStyle(c),
      ..._embedWarnings(c, forDanmaku: true),
    ],
    _switch(
      c,
      t('字幕'),
      t('人工字幕匿名一般拿不到；一条都没有时会在完成行上写出来。'),
      _c.saveSubtitle,
      (v) => _put((x) => x.saveSubtitle = v),
    ),
    if (_c.saveSubtitle) ...[
      _drop<BiliSubtitleFormat>(
        value: _c.subtitleFormat,
        items: [for (final e in BiliSubtitleFormat.values) (e, t(e.label))],
        onChanged: (v) => _put((x) => x.subtitleFormat = v),
      ),
      _label(c, t('只要这几种语言'), t('一条都不选 = 不筛选，平台给几条取几条。')),
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final (code, name) in kBiliSubtitleLangChoices)
            FilterChip(
              label: Text(name, style: const TextStyle(fontSize: 12)),
              selected: _c.subtitleLangs.contains(code),
              onSelected: (on) => _put((x) => x.subtitleLangs = [
                ...x.subtitleLangs.where((e) => e != code),
                if (on) code,
              ]),
            ),
        ],
      ),
      _switch(
        c,
        t('仅人工字幕'),
        t('AI 生成的那条语言码带 ai- 前缀，与人工字幕同名，只有前缀能分。'),
        _c.subtitleManualOnly,
        (v) => _put((x) => x.subtitleManualOnly = v),
      ),
    ],
    _switch(c, t('封面'), null, _c.saveCover, (v) => _put((x) => x.saveCover = v)),
    if (_c.saveCover)
      _drop<BiliCoverFormat>(
        value: _c.coverFormat,
        items: [for (final e in BiliCoverFormat.values) (e, t(e.label))],
        onChanged: (v) => _put((x) => x.coverFormat = v),
      ),
    _switch(
      c,
      t('章节'),
      t('绝大多数稿件没有分段章节，没有时一个参数都不多加。'),
      _c.saveChapter,
      (v) => _put((x) => x.saveChapter = v),
    ),
    _switch(
      c,
      t('元数据'),
      t('nfo 给媒体库读，会多取一次标签；json 是我们自己那份解析结果。'),
      _c.saveMetadata,
      (v) => _put((x) => x.saveMetadata = v),
    ),
    if (_c.saveMetadata)
      _drop<BiliMetadataFormat>(
        value: _c.metadataFormat,
        items: [for (final e in BiliMetadataFormat.values) (e, t(e.label))],
        onChanged: (v) => _put((x) => x.metadataFormat = v),
      ),
    _label(c, t('弹幕与字幕撞名时'), t('两族都是 ass 时会抢同一条字幕轨，这里定谁在前。')),
    _drop<BiliTrackPriority>(
      value: _c.trackPriority,
      items: [for (final e in BiliTrackPriority.values) (e, t(e.label))],
      onChanged: (v) => _put((x) => x.trackPriority = v),
    ),
  ]);

  List<Widget> _danmakuStyle(AppColors c) => [
    _label(c, t('字体'), null),
    _text(
      c,
      value: _c.danmakuFontFace,
      hint: t('弹幕字体'),
      onChanged: (v) => _put((x) => x.danmakuFontFace = v.trim()),
    ),
    _stepper(c, t('字号'), _c.danmakuFontSize, 10, 60, (v) => _put((x) => x.danmakuFontSize = v)),
    _stepper(c, t('不透明度'), _c.danmakuOpacity, 10, 100, (v) => _put((x) => x.danmakuOpacity = v), suffix: '%'),
    _stepper(c, t('底部边距'), _c.danmakuMarginV, 0, 200, (v) => _put((x) => x.danmakuMarginV = v)),
  ];

  // ── ③ 下载设置 ──────────────────────────────────────────────

  Widget _download(AppColors c) => _scroll([
    _label(c, t('限速'), t('只限这一批的每条任务，0 = 不限。F 盘是 USB 盘时能避免下载把盘打满。')),
    _stepper(c, t('每条任务限速'), _c.speedLimitKbps, 0, 51200, (v) => _put((x) => x.speedLimitKbps = v), step: 64, suffix: 'KB/s'),
    _label(c, t('并发数'), null),
    _drop<int>(
      value: _c.concurrency,
      items: [for (final n in const [1, 2, 3, 4, 6, 8]) (n, '$n')],
      onChanged: (v) => _put((x) => x.concurrency = v),
    ),
    _switch(
      c,
      t('跳过已下载'),
      t('按「稿件 + 分 P」认，换画质重下也算已下载。'),
      _c.skipDownloaded,
      (v) => _put((x) => x.skipDownloaded = v),
    ),
    _switch(
      c,
      t('同稿件分 P 排在一起'),
      null,
      _c.groupByWork,
      (v) => _put((x) => x.groupByWork = v),
    ),
    _label(c, t('自定义文本'), t('填了它，%CUSTOM_TEXT% 才会展开出东西。')),
    _text(
      c,
      value: _c.customText,
      hint: t('自定义文本内容'),
      onChanged: (v) => _put((x) => x.customText = v.trim()),
    ),
  ]);

  // ── 本地控件 ────────────────────────────────────────────────

  Widget _scroll(List<Widget> kids) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(4, 14, 12, 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids),
  );

  Widget _label(AppColors c, String title, String? hint) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textStrong)),
        if (hint != null)
          Text(hint, style: TextStyle(fontSize: 12, height: 1.4, color: c.textMuted)),
      ],
    ),
  );

  Widget _note(AppColors c, String text) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: c.accentSoft,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: TextStyle(fontSize: 12, height: 1.4, color: c.textMuted)),
  );

  Widget _drop<T>({
    required T value,
    required List<(T, String)> items,
    required ValueChanged<T> onChanged,
  }) => DropdownButtonFormField<T>(
    initialValue: value,
    isExpanded: true,
    items: [for (final (v, label) in items) DropdownMenuItem(value: v, child: Text(label))],
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
  );

  Widget _switch(
    AppColors c,
    String title,
    String? hint,
    bool value,
    ValueChanged<bool> onChanged,
  ) => SwitchListTile.adaptive(
    contentPadding: EdgeInsets.zero,
    dense: true,
    value: value,
    title: Text(title, style: const TextStyle(fontSize: 13)),
    subtitle: hint == null
        ? null
        : Text(hint, style: TextStyle(fontSize: 11.5, height: 1.35, color: c.textMuted)),
    onChanged: onChanged,
  );

  Widget _text(
    AppColors c, {
    required String value,
    required String hint,
    required ValueChanged<String> onChanged,
  }) => TextField(
    controller: TextEditingController(text: value)..selection = TextSelection.collapsed(offset: value.length),
    style: TextStyle(fontSize: 13, color: c.textStrong),
    decoration: InputDecoration(hintText: hint, isDense: true),
    onChanged: onChanged,
  );

  Widget _stepper(
    AppColors c,
    String title,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged, {
    int step = 1,
    String? suffix,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(title, style: const TextStyle(fontSize: 13))),
        IconButton(
          onPressed: value > min ? () => onChanged((value - step).clamp(min, max)) : null,
          icon: const Icon(Icons.remove, size: 16),
          tooltip: t('减少'),
        ),
        SizedBox(
          width: 64,
          child: Text(
            '$value${suffix ?? ''}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        IconButton(
          onPressed: value < max ? () => onChanged((value + step).clamp(min, max)) : null,
          icon: const Icon(Icons.add, size: 16),
          tooltip: t('增加'),
        ),
      ],
    ),
  );
}
