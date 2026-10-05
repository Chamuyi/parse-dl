/// 「自动下载」里的一个目标 —— 以及它跑到哪一步了。
///
/// 与 X 模块的「自动执行」对应：那边批量处理一组**用户 ID**，这边批量处理一组
/// **抖音链接**（作者主页 / 作品 / 合集 / 短链 / 纯作品 ID）。
/// 差别在于抖音没有「按用户取全部作品」的接口，只能真的打开页面往下滚，
/// 所以每个目标的耗时更长，状态也要更细一点，用户才知道它在干嘛。
library;

import '../l10n/l10n.dart';

/// 一个目标的状态机。
///
/// 顺序即推进顺序：`waiting → opening → collecting → downloading → done`；
/// 中途可能落到 `empty`（页面打开但没抓到作品）或 `failed`。
enum DouyinAutoStatus {
  waiting('等待'),
  opening('打开页面'),
  collecting('收集作品'),
  downloading('提交下载'),
  done('完成'),
  empty('没收集到'),
  failed('失败');

  const DouyinAutoStatus(this.label);

  /// 列表里显示的短标签
  final String label;

  /// 已经跑完了（不管成没成）—— 用于「已完成 N/M」的统计。
  bool get isSettled =>
      this == DouyinAutoStatus.done ||
      this == DouyinAutoStatus.empty ||
      this == DouyinAutoStatus.failed;

  /// 算「成功」的两种：真下到了东西、或者确认这个页面本来就没有新东西。
  bool get isOk =>
      this == DouyinAutoStatus.done || this == DouyinAutoStatus.empty;
}

/// 一个待处理的目标。
///
/// 字段都是可变的：跑批过程中原地更新，界面靠 [DouyinAutoStore.refresh] 重画。
/// 不做成不可变对象是为了避免每滚一轮就重建整个列表 —— 一个目标可能滚几十轮。
class DouyinAutoTask {
  DouyinAutoTask({required this.input, required this.url})
    : label = douyinTargetLabel(url);

  /// 用户写的原始那一行（可能夹着分享口令、表情、前后缀）
  final String input;

  /// 归一化后的地址（真正拿去打开的）
  final String url;

  /// 列表里显示的短标签
  final String label;

  DouyinAutoStatus status = DouyinAutoStatus.waiting;

  /// 收集到的作品数（一个图集算一条，与参照实现口径一致）
  int awemeCount = 0;

  /// 收集到的媒体条数（图集展开后，一个图集可能是好几张图）
  int mediaCount = 0;

  /// 确认提交给 aria2 的媒体条数
  int queued = 0;

  /// 被「已下载」台账跳过的作品数
  int skippedDownloaded = 0;

  /// 轮数用尽了还没判定到底 —— 这个号的作品可能没翻完。
  ///
  /// 必须让界面说出来：批量跑的时候，用户看到「下载 N 个」会以为抓全了。
  bool incomplete = false;

  /// 失败原因（只在 [status] 为 failed 时有值）
  String? error;

  /// 回到初始状态，准备重跑。
  void reset() {
    status = DouyinAutoStatus.waiting;
    awemeCount = 0;
    mediaCount = 0;
    queued = 0;
    skippedDownloaded = 0;
    incomplete = false;
    error = null;
  }

  void setStatus(DouyinAutoStatus s) {
    status = s;
  }

  void fail(String message) {
    status = DouyinAutoStatus.failed;
    error = message;
  }

  /// 一行摘要，列表右侧显示。
  String get summary {
    switch (status) {
      case DouyinAutoStatus.waiting:
        return '排队中';
      case DouyinAutoStatus.opening:
        return '打开中…';
      case DouyinAutoStatus.collecting:
        return tf('已抓到 {n} 个作品', {'n': awemeCount});
      case DouyinAutoStatus.downloading:
        return tf('提交 {q} / {total}',
            {'q': queued, 'total': mediaCount - skippedDownloaded});
      case DouyinAutoStatus.done:
        final parts = <String>[tf('下载 {n} 个', {'n': queued})];
        if (skippedDownloaded > 0) {
          parts.add(tf('跳过 {n} 个已下载', {'n': skippedDownloaded}));
        }
        if (incomplete) parts.add(t('轮数用尽，可能没翻完'));
        return parts.join(t('，'));
      case DouyinAutoStatus.empty:
        return skippedDownloaded > 0
            ? tf('都是已下载的（跳过 {n} 个）', {'n': skippedDownloaded})
            : t('这个页面上没抓到作品');
      case DouyinAutoStatus.failed:
        return error ?? '失败';
    }
  }
}

/// 目标在列表里的短标签 —— 只取最有辨识度的一段。
///
/// 抖音的 sec_uid 有 50 多个字符，整条铺在列表里会把状态挤没；
/// 截断后再带上类型前缀（作者 / 作品 / 图文），用户一眼能认出是哪一类。
String douyinTargetLabel(String url) {
  String cut(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final host = uri.host;
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();

  if (segs.length >= 2) {
    final kind = segs[0];
    final id = segs[1];
    return switch (kind) {
      'user' => '作者 · ${cut(id, 12)}',
      'video' => '作品 · $id',
      'note' => '图文 · $id',
      'collection' => '合集 · ${cut(id, 12)}',
      'share' => '分享 · ${cut(id, 12)}',
      _ => '$kind · ${cut(id, 12)}',
    };
  }
  if (segs.isNotEmpty) return '$host/${segs.first}';
  return host.isEmpty ? url : host;
}
