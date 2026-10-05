import 'download_filter.dart';
import 'user.dart';

/// 「创建下载任务」的执行状态。
///
///  里的 `'waiting' | 'active'`。
enum CreationStatus {
  /// 在队列里排队（原版 `'waiting'`）
  waiting,

  /// 正在翻页 + 入队（原版 `'active'`）
  active,
}

/// 一个「创建下载任务」。
///
/// 这是**一次爬取动作**的载体：
/// 记录了「爬谁、按什么过滤条件爬、爬到多少了」。与 `DownloadTask` 的区别是
/// 一个 CreationTask 会派生出**很多** DownloadTask（每张图 / 每个视频一个）。
///
/// 原版把这类任务放在 download store 里、由下载管理页展示进度：
/// 主页点「开始下载」只是 `createCreationTask(user, filter)` 登记一下就返回，
/// 真正的翻页与入队在后台串行执行。
class CreationTask {
  /// 本地 id（原版用 nanoid）
  final String id;

  /// 要爬的用户
  final TwitterUser user;

  /// 过滤条件（日期范围 / 媒体类型 / 下载源）。
  /// **创建时快照一份** —— 之后用户在界面上改过滤条件不影响已创建的任务
  /// （原版注释：配置仅影响本次创建的任务）。
  final DownloadFilter filter;

  CreationStatus status;

  /// 已发送给 aria2 的媒体数（原版 `completeCount`）
  int completeCount;

  /// 已跳过的媒体数。原版把两种情况合并计入：
  ///   1. 被日期范围 / 媒体类型过滤掉的；
  ///   2. 文件名已存在且开了「跳过相同文件」开关的。
  int skipCount;

  /// 被 aria2 **明确拒绝**的媒体数（入队失败）。
  ///
  /// 原版没有这一项 —— 它把入队失败也算进 `completeCount`，界面上的
  /// 「已发送」因此会说谎。失败详情在下载管理页的「失败」Tab 里逐条可见。
  int failCount;

  /// 已翻页次数（原版没有，方便排查）
  int pages;

  /// 失败原因；null 表示没出错
  String? error;

  /// 用户点了「取消」
  bool cancelled;

  CreationTask({
    required this.id,
    required this.user,
    required this.filter,
    this.status = CreationStatus.waiting,
    this.completeCount = 0,
    this.skipCount = 0,
    this.failCount = 0,
    this.pages = 0,
    this.error,
    this.cancelled = false,
  });

  bool get isActive => status == CreationStatus.active;

  /// 列表里显示的名字：优先昵称，其次 @screenName。
  String get displayName {
    final name = user.name;
    if (name != null && name.isNotEmpty) return name;
    final sn = user.screenName;
    if (sn != null && sn.isNotEmpty) return '@$sn';
    return '未知用户';
  }
}
