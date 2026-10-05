import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/download_filter.dart';
import '../models/media.dart';
import '../services/app_state.dart';
import '../services/auto_task_store.dart';
import '../services/homepage_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/app_toast.dart';
import '../l10n/l10n.dart';

/// 自动执行页：批量处理一组用户 ID。
///
/// 状态都在 `AutoTaskStore` 里，
/// 切走页面不丢进度，回到本页即可看到实时状态。
class AutoTaskPage extends StatefulWidget {
  const AutoTaskPage({super.key});

  @override
  State<AutoTaskPage> createState() => _AutoTaskPageState();
}

class _AutoTaskPageState extends State<AutoTaskPage> {
  // 分页状态（本地，不影响 store）
  int _page = 1;
  int _pageSize = 12;

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
        withData: false,  // 桌面端选文件后用 path 读，不要预加载到内存
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      final path = picked.path;
      if (path == null) return;

      // 桌面端 file_picker 不直接给文本内容，自己用 File 读
      String content;
      try {
        content = await File(path).readAsString();
      } catch (e) {
        if (!mounted) return;
        AppToast.show(context, tf('读取文件失败：{e}', {'e': e}),
            kind: AppToastKind.error);
        return;
      }

      if (!mounted) return;
      final store = context.read<AutoTaskStore>();
      store.setRawText(content);
      store.setFileName(picked.name);

      // 摘要
      final lines = content
          .split(RegExp(r'\r?\n'))
          .where((l) => l.trim().isNotEmpty)
          .length;
      AppToast.show(context, tf('已读取 {n} 行有效名单', {'n': lines}),
          kind: AppToastKind.success);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, tf('选择文件失败：{e}', {'e': e}),
          kind: AppToastKind.error);
    }
  }

  Future<void> _onStart() async {
    final store = context.read<AutoTaskStore>();
    final err = await store.start();
    if (!mounted) return;
    if (err != null) {
      AppToast.show(context, err, kind: AppToastKind.error);
    } else {
      setState(() => _page = 1);
      AppToast.show(context, t('批量任务已启动，可切到下载管理查看进度'), kind: AppToastKind.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final store = context.watch<AutoTaskStore>();
    final appState = context.watch<AppState>();
    final parsed = store.parsed;

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 24),
      children: [
        // ① 顶部告警
        if (store.running)
          _Alert(
            color: c.accent,
            icon: Icons.info_outline,
            text: t('批量任务正在后台执行，切换到其他页面也不会中断，回来即可继续查看进度。'),
          ),
        if (!appState.isLoggedIn)
          _Alert(
            color: c.danger,
            icon: Icons.warning_amber_outlined,
            text: t('尚未登录 X 账号，请先在【设置】中登录后再执行批量任务。'),
          ),

        // ② 名单来源
        AppCard(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle('名单来源', colors: c),
              const SizedBox(height: 12),
              _FilePickerRow(
                fileName: store.fileName,
                disabled: store.running,
                onPick: _pickFile,
              ),
              const SizedBox(height: 10),
              _RawTextArea(
                value: store.rawText,
                disabled: store.running,
                onChanged: (v) => context.read<AutoTaskStore>().setRawText(v),
              ),
              const SizedBox(height: 8),
              _ParseSummary(
                ids: parsed.ids,
                skipped: parsed.skipped,
                colors: c,
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // ④ 历史预设（持久化名单）
        _PresetsSection(store: store, colors: c),

        const SizedBox(height: 14),

        // ③ 下载配置（与主页共用）
        AppCard(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle('下载配置（与主页共用）', colors: c),
              const SizedBox(height: 14),
              _DownloadConfigForm(),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // ④ 执行设置
        AppCard(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle('执行设置', colors: c),
              const SizedBox(height: 14),
              _ExecutionSettings(),
              const SizedBox(height: 16),
              _ActionButtons(
                running: store.running,
                paused: store.paused,
                canStart: !store.running &&
                    appState.isLoggedIn &&
                    parsed.ids.isNotEmpty,
                onStart: _onStart,
                onTogglePause: () => context.read<AutoTaskStore>().togglePause(),
                onStop: () => context.read<AutoTaskStore>().stop(),
                onClear: () => context.read<AutoTaskStore>().clearList(),
              ),
              if (store.list.isNotEmpty) ...[
                const SizedBox(height: 18),
                _ProgressBar(items: store.list),
                const SizedBox(height: 8),
                _TaskTable(
                  items: store.list,
                  page: _page,
                  pageSize: _pageSize,
                  onPageChanged: (p) {
                    setState(() {
                      _page = p;
                    });
                  },
                  onPageSizeChanged: (ps) {
                    setState(() {
                      _pageSize = ps;
                      _page = 1;
                    });
                  },
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 12),

        Text(
          t('说明：任务创建后会进入后台队列串行执行，实际下载进度请到【下载管理】查看。'),
          style: TextStyle(fontSize: 12.5, color: c.textMuted),
        ),
      ],
    );
  }
}

// ── 子组件 ─────────────────────────────────────────────────

class _Alert extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;
  const _Alert({required this.color, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.6),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 13, color: color))),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final AppColors colors;
  const _SectionTitle(this.text, {required this.colors});

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.textStrong));
  }
}

class _FilePickerRow extends StatelessWidget {
  final String fileName;
  final bool disabled;
  final VoidCallback onPick;
  const _FilePickerRow({
    required this.fileName,
    required this.disabled,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: c.surfaceSunken,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.line, width: 0.6),
            ),
            child: Text(
              fileName.isEmpty
                  ? '每行一个用户 ID，支持：纯ID / @ID / 主页链接 / 带行号'
                  : fileName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13.5,
                  color: fileName.isEmpty ? c.textMuted : c.textStrong),
            ),
          ),
        ),
        const SizedBox(width: 10),
        FilledButton.tonalIcon(
          onPressed: disabled ? null : onPick,
          icon: const Icon(Icons.upload_file_outlined, size: 18),
          label: Text(t('选择 txt 文件'), style: TextStyle(fontSize: 13.5)),
        ),
      ],
    );
  }
}

class _RawTextArea extends StatefulWidget {
  final String value;
  final bool disabled;
  final ValueChanged<String> onChanged;

  const _RawTextArea({
    required this.value,
    required this.disabled,
    required this.onChanged,
  });

  @override
  State<_RawTextArea> createState() => _RawTextAreaState();
}

class _RawTextAreaState extends State<_RawTextArea> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _RawTextArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _ctrl.text) {
      _ctrl.text = widget.value;
      _ctrl.selection = TextSelection.collapsed(offset: widget.value.length);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line, width: 0.6),
      ),
      child: TextField(
        controller: _ctrl,
        enabled: !widget.disabled,
        onChanged: widget.onChanged,
        maxLines: 5,
        style: TextStyle(
            fontSize: 13,
            color: c.textStrong,
            fontFamily: 'Consolas'),
        decoration: InputDecoration(
          hintText:
              t('也可以直接粘贴，每行一个：\nexample_user\n@sample_media_01\nhttps://x.com/demo_handle'),
          hintStyle: TextStyle(fontSize: 12.5, color: c.textMuted),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(12),
        ),
      ),
    );
  }
}

class _ParseSummary extends StatelessWidget {
  final List<String> ids;
  final int skipped;
  final AppColors colors;
  const _ParseSummary(
      {required this.ids, required this.skipped, required this.colors});

  @override
  Widget build(BuildContext context) {
    final preview = ids.take(8).join('、');
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 13, color: colors.textMuted),
        children: [
          TextSpan(text: t('已解析 ')),
          TextSpan(
              text: '${ids.length}',
              style: TextStyle(
                  color: colors.accent, fontWeight: FontWeight.w600)),
          TextSpan(text: t(' 个有效用户 ID')),
          if (skipped > 0) ...[
            TextSpan(text: t('，另有 ')),
            TextSpan(text: '$skipped', style: TextStyle(color: colors.danger)),
            TextSpan(text: t(' 行无法识别已跳过')),
          ],
          if (ids.isNotEmpty) ...[
            const TextSpan(text: '：'),
            TextSpan(
                text: '$preview${ids.length > 8 ? ' …' : ''}',
                style: TextStyle(color: colors.textNormal)),
          ],
        ],
      ),
    );
  }
}

class _DownloadConfigForm extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final hp = context.watch<HomepageStore>();
    final filter = hp.filter;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 日期范围
        _FieldLabel('日期范围', colors: c),
        const SizedBox(height: 6),
        _DateRangeRow(filter: filter),
        const SizedBox(height: 14),

        // 媒体类型
        _FieldLabel('媒体类型', colors: c),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in MediaType.values)
              _Chip(
                label: switch (t) {
                  MediaType.image => '照片',
                  MediaType.video => '视频',
                  MediaType.animatedGif => 'GIF',
                  // X 侧没有音频（`MediaType.audio` 是抖音 BGM 用的），
                  // 这里给它一个中性标签即可 —— 自动执行的筛选面板不涉及它。
                  MediaType.audio => '音频',
                },
                selected: filter.mediaTypes.contains(t),
                onTap: () {
                  final next = Set<MediaType>.from(filter.mediaTypes);
                  if (next.contains(t)) {
                    next.remove(t);
                  } else {
                    next.add(t);
                  }
                  hp.setFilter(filter.copyWith(mediaTypes: next));
                },
              ),
          ],
        ),
        const SizedBox(height: 14),

        // 下载源
        _FieldLabel('下载源', colors: c),
        const SizedBox(height: 4),
        Text(
          t('帖子能下载到更早的推文，但爬取速度较慢；媒体可能下载不到更早的推文，但爬取速度更快。'),
          style: TextStyle(fontSize: 12, color: c.textMuted),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _Chip(
              label: t('帖子'),
              selected: filter.source == DownloadSource.tweets,
              onTap: () => hp.setFilter(
                  filter.copyWith(source: DownloadSource.tweets)),
            ),
            const SizedBox(width: 6),
            _Chip(
              label: t('媒体'),
              selected: filter.source == DownloadSource.medias,
              onTap: () => hp.setFilter(
                  filter.copyWith(source: DownloadSource.medias)),
            ),
          ],
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  final AppColors colors;
  const _FieldLabel(this.text, {required this.colors});
  @override
  Widget build(BuildContext context) => Text(text,
      style: TextStyle(fontSize: 13, color: colors.textStrong));
}

class _DateRangeRow extends StatelessWidget {
  final DownloadFilter filter;
  const _DateRangeRow({required this.filter});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final hp = context.read<HomepageStore>();
    final fmt = DateFormat('yyyy-MM-dd');
    final label = (filter.dateFrom == null && filter.dateTo == null)
        ? '不限'
        : '${filter.dateFrom != null ? fmt.format(filter.dateFrom!) : '不限'}  ~  ${filter.dateTo != null ? fmt.format(filter.dateTo!) : '不限'}';

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final preset in _presets())
          _Chip(
            label: preset.$1,
            selected: preset.$2(filter.dateFrom, filter.dateTo),
            onTap: () =>
                hp.setFilter(filter.copyWith(dateFrom: preset.$3, dateTo: preset.$4)),
          ),
        const SizedBox(width: 6),
        ActionChip(
          label: Text(label, style: TextStyle(fontSize: 12.5, color: c.textStrong)),
          onPressed: () async {
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2006),
              lastDate: DateTime.now(),
              initialDateRange: (filter.dateFrom != null && filter.dateTo != null)
                  ? DateTimeRange(start: filter.dateFrom!, end: filter.dateTo!)
                  : null,
            );
            if (picked != null) {
              hp.setFilter(filter.copyWith(
                dateFrom: picked.start,
                dateTo: DateTime(picked.end.year, picked.end.month, picked.end.day, 23, 59, 59),
              ));
            }
          },
        ),
      ],
    );
  }

  List<(String, bool Function(DateTime?, DateTime?), DateTime?, DateTime?)>
      _presets() {
    final now = DateTime.now();
    return [
      ('不限',
          (f, t) => f == null && t == null,
          null,
          null),
      ('最近 7 天',
          (f, t) => _isAround(f, now.subtract(const Duration(days: 7)), 1) && _isToday(t),
          now.subtract(const Duration(days: 7)),
          now),
      ('最近 1 个月',
          (f, t) => _isAround(f, now.subtract(const Duration(days: 30)), 1) && _isToday(t),
          now.subtract(const Duration(days: 30)),
          now),
      ('最近 1 年',
          (f, t) => _isAround(f, now.subtract(const Duration(days: 365)), 2) && _isToday(t),
          now.subtract(const Duration(days: 365)),
          now),
    ];
  }

  bool _isAround(DateTime? a, DateTime b, int toleranceDays) {
    if (a == null) return false;
    return a.year == b.year && a.month == b.month && (a.day - b.day).abs() <= toleranceDays;
  }

  bool _isToday(DateTime? t) {
    if (t == null) return false;
    final n = DateTime.now();
    return t.year == n.year && t.month == n.month && t.day == n.day;
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? c.accent.withValues(alpha: 0.16) : c.surfaceSunken,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? c.accent.withValues(alpha: 0.6) : c.line,
            width: 0.6,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            color: selected ? c.accent : c.textNormal,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _ExecutionSettings extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final store = context.watch<AutoTaskStore>();

    return Wrap(
      spacing: 16,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _NumberField(
          label: t('每个账号间隔（秒）'),
          value: store.intervalSec,
          min: 0,
          max: 600,
          disabled: store.running,
          onChanged: (v) => context.read<AutoTaskStore>().setIntervalSec(v),
          colors: c,
        ),
        _NumberField(
          label: t('单个加载超时（秒）'),
          value: store.timeoutSec,
          min: 10,
          max: 1800,
          disabled: store.running,
          onChanged: (v) => context.read<AutoTaskStore>().setTimeoutSec(v),
          colors: c,
        ),
        _CheckRow(
          label: t('失败后继续下一个'),
          value: store.skipOnError,
          disabled: store.running,
          onChanged: (v) =>
              context.read<AutoTaskStore>().setSkipOnError(v),
          colors: c,
        ),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final bool disabled;
  final ValueChanged<int> onChanged;
  final AppColors colors;
  const _NumberField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.disabled,
    required this.onChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: colors.textStrong)),
        const SizedBox(width: 8),
        SizedBox(
          width: 90,
          child: TextField(
            enabled: !disabled,
            controller: TextEditingController(text: '$value')
              ..selection = TextSelection.collapsed(offset: '$value'.length),
            onSubmitted: (s) {
              final v = int.tryParse(s.trim()) ?? value;
              onChanged(v.clamp(min, max));
            },
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: colors.textStrong),
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              filled: true,
              fillColor: colors.surfaceSunken,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: colors.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: colors.line),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  final String label;
  final bool value;
  final bool disabled;
  final ValueChanged<bool> onChanged;
  final AppColors colors;
  const _CheckRow({
    required this.label,
    required this.value,
    required this.disabled,
    required this.onChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: disabled ? null : () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value
                  ? Icons.check_box_outlined
                  : Icons.check_box_outline_blank,
              size: 16,
              color: value
                  ? colors.accent
                  : (disabled ? colors.textFaint : colors.textMuted),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    color: disabled ? colors.textFaint : colors.textStrong)),
          ],
        ),
      ),
    );
  }
}

class _ActionButtons extends StatelessWidget {
  final bool running;
  final bool paused;
  final bool canStart;
  final VoidCallback onStart;
  final VoidCallback onTogglePause;
  final VoidCallback onStop;
  final VoidCallback onClear;

  const _ActionButtons({
    required this.running,
    required this.paused,
    required this.canStart,
    required this.onStart,
    required this.onTogglePause,
    required this.onStop,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: canStart ? onStart : null,
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: Text(t('开始执行'), style: TextStyle(fontSize: 13.5)),
        ),
        OutlinedButton.icon(
          onPressed: running ? onTogglePause : null,
          icon: Icon(paused ? Icons.play_arrow : Icons.pause, size: 16),
          label: Text(t(paused ? '继续' : '暂停'),
              style: const TextStyle(fontSize: 13.5)),
        ),
        OutlinedButton.icon(
          onPressed: running ? onStop : null,
          icon: const Icon(Icons.stop_rounded, size: 16),
          label: Text(t('停止'), style: TextStyle(fontSize: 13.5)),
        ),
        OutlinedButton.icon(
          onPressed: running ? null : onClear,
          icon: const Icon(Icons.clear_all_rounded, size: 16),
          label: Text(t('清空结果'), style: TextStyle(fontSize: 13.5)),
        ),
      ],
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final List<AutoTaskItem> items;
  const _ProgressBar({required this.items});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final finished =
        items.where((i) => i.status == AutoTaskStatus.done || i.status == AutoTaskStatus.fail).length;
    final percent =
        items.isEmpty ? 0 : ((finished / items.length) * 100).round();
    final success =
        items.where((i) => i.status == AutoTaskStatus.done).length;
    final fail =
        items.where((i) => i.status == AutoTaskStatus.fail).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: items.isEmpty ? 0 : finished / items.length,
            minHeight: 6,
            backgroundColor: c.surfaceSunken,
            valueColor: AlwaysStoppedAnimation(c.accent),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          tf('共 {n} 个 · 成功 {ok} · 失败 {fail} · 完成 {percent}%', {
            'n': items.length,
            'ok': success,
            'fail': fail,
            'percent': percent,
          }),
          style: TextStyle(fontSize: 12.5, color: c.textMuted),
        ),
      ],
    );
  }
}

class _TaskTable extends StatelessWidget {
  final List<AutoTaskItem> items;
  final int page;
  final int pageSize;
  final ValueChanged<int> onPageChanged; // (page, pageSize)
  final ValueChanged<int> onPageSizeChanged;

  const _TaskTable({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.onPageChanged,
    required this.onPageSizeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final totalPages = (items.length / pageSize).ceil().clamp(1, 9999);
    final start = (page - 1) * pageSize;
    final end = (start + pageSize).clamp(0, items.length);
    final slice = items.sublist(start.clamp(0, items.length), end);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 每页大小切换
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            spacing: 6,
            children: [
              Text(t('每页'), style: TextStyle(fontSize: 12, color: c.textMuted)),
              for (final n in const [10, 20, 50, 100])
                InkWell(
                  onTap: () => onPageSizeChanged(n),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '$n',
                      style: TextStyle(
                        fontSize: 12,
                        color: pageSize == n ? c.accent : c.textMuted,
                        fontWeight:
                            pageSize == n ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // 表头
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(width: 36, child: Text('#', style: _h(c))),
              Expanded(child: Text(t('用户 ID'), style: _h(c))),
              SizedBox(width: 90, child: Text(t('状态'), style: _h(c))),
              Expanded(child: Text(t('说明'), style: _h(c))),
            ],
          ),
        ),
        const SizedBox(height: 4),
        ...slice.map((it) {
          final i = items.indexOf(it);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(width: 36, child: Text('${i + 1}', style: _b(c))),
                Expanded(
                  child: Text(it.id,
                      style: TextStyle(
                          fontSize: 13,
                          color: c.textStrong,
                          fontFamily: 'Consolas')),
                ),
                SizedBox(width: 90, child: _StatusBadge(status: it.status, colors: c)),
                Expanded(
                  // 统计摘要（已加入 / 跳过 / 过滤 / 页数）比较长，加 tooltip 看全
                  child: Tooltip(
                    message: it.message ?? '-',
                    child: Text(
                      it.message ?? '-',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: c.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 8),
        // 分页
        Row(
          children: [
            Text(
              tf('第 {from}-{to} 条 / 共 {total}',
                  {'from': start + 1, 'to': end, 'total': items.length}),
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: page > 1 ? () => onPageChanged(page - 1) : null,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
            ),
            Text('$page / $totalPages',
                style: TextStyle(fontSize: 12, color: c.textMuted)),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: page < totalPages
                  ? () => onPageChanged(page + 1)
                  : null,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ],
    );
  }

  TextStyle _h(AppColors c) =>
      TextStyle(fontSize: 12, color: c.textMuted, fontWeight: FontWeight.w600);
  TextStyle _b(AppColors c) => TextStyle(fontSize: 12, color: c.textMuted);
}

class _StatusBadge extends StatelessWidget {
  final AutoTaskStatus status;
  final AppColors colors;
  const _StatusBadge({required this.status, required this.colors});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status) {
      AutoTaskStatus.pending => ('等待中', colors.textMuted, Icons.schedule),
      AutoTaskStatus.loading => ('加载中', colors.accent, Icons.sync),
      AutoTaskStatus.done => ('已创建任务', colors.success, Icons.check_circle_outline),
      AutoTaskStatus.fail => ('失败', colors.danger, Icons.error_outline),
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
          if (status == AutoTaskStatus.loading)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.4, color: color),
            )
          else
            Icon(icon, size: 10, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ── 历史名单预设（持久化到 AppPrefs）────────────────────

/// 历史名单预设区：列出已保存到本地的名单，
/// 可一键加载、重命名、删除；当前内容也可保存为新预设。
class _PresetsSection extends StatelessWidget {
  final AutoTaskStore store;
  final AppColors colors;

  const _PresetsSection({required this.store, required this.colors});

  @override
  Widget build(BuildContext context) {
    final presets = store.presets;
    final activeId = store.activePresetId;
    final c = colors;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题 + 「保存当前」按钮
          Row(
            children: [
              Icon(Icons.history_rounded, size: 16, color: c.accent),
              const SizedBox(width: 8),
              Text(
                t('历史名单'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: c.textStrong,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '（${presets.length}）',
                style: TextStyle(fontSize: 12, color: c.textFaint),
              ),
              const Spacer(),
              if (store.rawText.trim().isNotEmpty)
                TextButton.icon(
                  onPressed: () => _saveDialog(context),
                  icon: Icon(Icons.bookmark_add_outlined,
                      size: 14, color: c.accent),
                  label: Text(t('保存当前'),
                      style: TextStyle(fontSize: 12.5, color: c.accent)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),

          if (presets.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              decoration: BoxDecoration(
                color: c.surfaceSunken,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.bookmark_border_rounded,
                      size: 16, color: c.textFaint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t('还没有保存的名单。粘贴或导入名单后，点「保存当前」即可加入历史。'),
                      style: TextStyle(fontSize: 12.5, color: c.textMuted),
                    ),
                  ),
                ],
              ),
            )
          else
            // 列表
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in presets)
                  _PresetChip(
                    preset: p,
                    active: p.id == activeId,
                    onLoad: () => store.loadPreset(p.id),
                    onRename: () => _renameDialog(context, p),
                    onDelete: () async {
                      final ok = await _confirmDelete(context, p);
                      if (ok == true) await store.deletePreset(p.id);
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _saveDialog(BuildContext context) async {
    final c = AppTheme.colorsOf(context);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surfaceCard,
        title: Text(t('保存为预设'), style: TextStyle(color: c.textStrong)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: c.textStrong),
          decoration: InputDecoration(
            labelText: '名称（可留空，自动用当前时间）',
            labelStyle: TextStyle(color: c.textMuted),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(t('保存')),
          ),
        ],
      ),
    );
    if (name == null) return;
    if (!context.mounted) return;
    final saved = await store.saveAsPreset(name);
    if (!context.mounted) return;
    final entry = saved.entry;
    if (!saved.ok || entry == null) {
      AppToast.show(context, t('保存失败：名单为空，或预设文件写入出错'),
          kind: AppToastKind.error);
      return;
    }
    AppToast.show(context, tf('已保存到历史：{name}', {'name': entry.name}),
        kind: AppToastKind.success);
  }

  Future<void> _renameDialog(BuildContext context, PresetEntry preset) async {
    final c = AppTheme.colorsOf(context);
    final controller = TextEditingController(text: preset.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surfaceCard,
        title: Text(t('重命名'), style: TextStyle(color: c.textStrong)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: c.textStrong),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(t('确定')),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    if (!context.mounted) return;
    await store.renamePreset(preset.id, newName);
  }

  Future<bool> _confirmDelete(BuildContext context, PresetEntry preset) async {
    final c = AppTheme.colorsOf(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surfaceCard,
        title: Text(tf('删除「{name}」？', {'name': preset.name}),
            style: TextStyle(color: c.textStrong)),
        content: Text(t('该预设只删除历史记录，不影响当前名单。'),
            style: TextStyle(color: c.textMuted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: c.danger),
            child: Text(t('删除')),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

/// 单个预设条目。点击 = 加载；右侧 PopupMenu = 加载/重命名/删除。
class _PresetChip extends StatelessWidget {
  final PresetEntry preset;
  final bool active;
  final VoidCallback onLoad;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _PresetChip({
    required this.preset,
    required this.active,
    required this.onLoad,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final createdAt = preset.createdAt;
    final dateLabel =
        '${createdAt.year.toString().padLeft(4, "0")}-'
        '${createdAt.month.toString().padLeft(2, "0")}-'
        '${createdAt.day.toString().padLeft(2, "0")} '
        '${createdAt.hour.toString().padLeft(2, "0")}:'
        '${createdAt.minute.toString().padLeft(2, "0")}';

    return InkWell(
      onTap: onLoad,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? c.accentSoft : c.surfaceSunken,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? c.accentLine : c.line,
            width: active ? 1.2 : 0.6,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
              size: 14,
              color: active ? c.accent : c.textMuted,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    preset.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: c.textStrong,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tf('{n} 个 · {date}',
                        {'n': preset.lineCount, 'date': dateLabel}),
                    style: TextStyle(fontSize: 11, color: c.textMuted),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              padding: EdgeInsets.zero,
              tooltip: t('操作'),
              icon:
                  Icon(Icons.more_horiz_rounded, size: 14, color: c.textMuted),
              color: c.surfaceCard,
              onSelected: (v) {
                if (v == 'load') onLoad();
                if (v == 'rename') onRename();
                if (v == 'delete') onDelete();
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'load',
                  child: Row(children: [
                    Icon(Icons.download_outlined,
                        size: 14, color: c.textNormal),
                    const SizedBox(width: 6),
                    Text(t('加载'), style: TextStyle(color: c.textStrong)),
                  ]),
                ),
                PopupMenuItem(
                  value: 'rename',
                  child: Row(children: [
                    Icon(Icons.edit_outlined,
                        size: 14, color: c.textNormal),
                    const SizedBox(width: 6),
                    Text(t('重命名'), style: TextStyle(color: c.textStrong)),
                  ]),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(children: [
                    Icon(Icons.delete_outline_rounded,
                        size: 14, color: c.danger),
                    const SizedBox(width: 6),
                    Text(t('删除'), style: TextStyle(color: c.danger)),
                  ]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}