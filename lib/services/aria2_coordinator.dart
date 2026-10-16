import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/bili_config.dart';
import '../models/douyin_config.dart';
import '../models/media.dart';
import 'app_logger.dart';
import 'aria2.dart';
import 'bili_api.dart';
import 'bili_additional.dart';
import 'bili_download_plan.dart';
import 'bili_merger.dart';
import 'douyin_ledger.dart';
import 'download_store.dart';
import 'file_name_template.dart';
import 'settings_store.dart';
import 'template_source.dart';

/// 一个媒体入队的结果。
///
/// 用枚举而不是 `null` 来区分「跳过」，因为自动执行需要把
/// 「已存在跳过」与「aria2 没起来」分开统计（原版是 skipCount）。
enum EnqueueOutcome {
  /// 已提交给 aria2
  queued,

  /// 按模板算出来的文件已存在，被 `sameFileSkip` 跳过
  skippedExisting,

  /// aria2 未就绪（启动失败 / 还没 bootstrap）
  notReady,

  /// aria2 **明确拒绝**了这次入队（`addUri` 抛错）。
  ///
  /// 必须与 [queued] 严格分开 —— 早前的写法在 catch 里照样返回 `queued`，
  /// 于是：失败任务停在 `pending`（下载管理页把它划进「下载中」，用户看不到失败）、
  /// 统计把失败算成成功、抖音台账还把没提交成功的作品标成「已下载」。
  rejected,

  /// 手动重试**没能把旧任务从引擎里移掉**，因此没有新建任务。
  ///
  /// 只有 [Aria2Coordinator.retryTask] 会给出这一档（入队路径不会有）。
  /// 必须与 [rejected] 分开：这条是「压根没往引擎投新任务」，那句是「投了但被拒」，
  /// 混在一起就等于告诉用户「引擎拒绝了你」，而真正的原因是旧任务还挂着。
  /// 之所以不硬投：旧行删不掉时再 `_submit` 一次，同一个媒体就变成两行
  /// ——「错误」里那条还在、「下载中」又冒出一条（2026-10-04 用户真机报的）。
  removeFailed,
}

/// 入队结果：本地任务 id + 结局。
typedef EnqueueResult = ({String? localId, EnqueueOutcome outcome});

/// 手动重试的结果。
///
/// 比 [EnqueueResult] 多一个 [message]：[EnqueueOutcome.removeFailed] 时，
/// 光靠枚举说不出「为什么移不掉」，要把 `remove` 拿到的引擎原文带给界面
/// （与 × 那条路径同一个口径）。
typedef RetryResult =
    ({String? localId, EnqueueOutcome outcome, String? message});

/// B 站一条分 P 的入队结果。
///
/// **刻意不给 [EnqueueOutcome] 新增「需要凭据」那一格。** 指令里给了两个选项
/// （新增枚举值 / 带 message），这里选 message，理由是可枚举的结局在界面侧
/// 有四处**穷尽 switch**（`douyin_page.dart` 的下载统计、`homepage_page.dart`
/// 的创建任务、`download_management_page.dart` 的重试文案、以及
/// `douyin_auto_page.dart` 的计数），加一格就得同时改那四个文件 ——
/// 而这一期的改动范围钉在协调器 + 任务表两个文件上。
/// 枚举值不够用时 message 本来就是给用户看的那句话（`rejected` 走的就是这条路）。
typedef BiliEnqueueResult = ({
  /// queued / rejected / notReady / skippedExisting 四条老结局照旧
  EnqueueOutcome outcome,

  /// 视频流那一行的本地 id（`rejected` 时也带着 —— 失败的任务也要能反查）
  String? videoLocalId,

  /// 音频流那一行的本地 id；durl 退化路径（单文件）时是 null
  String? audioLocalId,

  /// 合并产物的完整路径；不合并 / durl 时就是那条单文件的落盘路径
  String? outPath,

  /// 给用户看的补充说明（需要凭据、只进去一半等）。null = 一切正常
  String? message,
});

/// B 站一条分 P **收口**时的结局种类。
enum BiliSettleKind {
  /// 两条流都下完并且合并成功（产物 `<base>.mp4` 已就位、音频行已收掉）。
  /// durl 退化路径的那一条完整 mp4 也归这一档 —— 对用户来说结局是同一个。
  merged,

  /// 流都下完了，但按设置**没有**合并（`mergeAfterDownload = false`）：
  /// 两行留在「已完成」，界面上就该写「这是裸流」。
  streamsKept,

  /// 合并失败：两条原始流与两个文件**都保留**，原因与可复现命令行进日志。
  mergeFailed,
}

/// B 站一条分 P 收口时回给页面的东西。
///
/// 为什么要回调而不是让页面自己轮任务表：台账的 `markDone` 必须卡在
/// **「合并成功之后」**那一刻 —— 入队时记 = 把没到手的分 P 标成已下载，
/// 之后开着「跳过已下载」就永远不再重下它（抖音那边就栽过这个）。
/// 页面只有这里能同时拿到「收口了」+「收口成什么样」+「该记哪个分 P」。
typedef BiliSettleInfo = ({
  BiliSettleKind kind,
  String outBase,
  String saveDir,

  /// 视频流那侧的 Media（`bili.bvid` / `bili.cid` 是台账键组的来源）
  Media media,

  /// 给用户看的一句话（失败时是原因）
  String message,

  /// 合并失败时 ffmpeg 的可复现命令行；其余情形 null
  String? commandLine,
});

/// 失败后自动重试的次数。 里的
/// `ariaRetryCountRemains: 5`。
///
/// 注意这是**换源用尽之后**的原地重试次数：候选下载地址还有剩余时，
/// 优先换源（见 [decideRetry]），不消耗这个额度。
const int kAriaRetryTimes = 5;

/// 自动重新提交**之前**要等多久（指数退避的基数）。
const Duration kRetryBackoffBase = Duration(milliseconds: 800);

/// 指数退避的封顶值 —— 再失败也不会等超过它。
const Duration kRetryBackoffCap = Duration(seconds: 12);

/// 一条任务最多被**自动**重新提交几次（换源与原地重试共用这个额度）。
///
/// `decideRetry` 本身已经分别限制了换源次数（候选地址条数）和原地重试次数
/// （[kAriaRetryTimes]），但两者相加没有上限：候选地址来自解析结果，
/// 源站给几条就是几条。这条硬上限才是「一条任务最多制造几次子进程调用」的
/// 那个上限，也是单测要钉住的那个「不再重试」的界。
const int kMaxAutoResubmits = 8;

/// 纯函数：第 [resubmits] 次自动重新提交前等多久（从 0 起计）。
///
/// 800ms → 1.6s → 3.2s → 6.4s → 12.8s(封顶 12s) ……
/// 为什么必须有：改之前失败后是**零等待**重新 `addUri`，于是一条源站已经
/// 404 的媒体会在几十毫秒内把换源 + 原地重试的额度全部烧光，每次都产生
/// 一次 RPC + 两行日志；开机时几十个这种任务一起跑，就是日志刷屏的来源。
Duration retryBackoffDelay(int resubmits) {
  if (resubmits <= 0) return kRetryBackoffBase;
  if (resubmits >= 10) return kRetryBackoffCap; // 移位前先封顶，避免溢出
  final d = kRetryBackoffBase * (1 << resubmits);
  return d > kRetryBackoffCap ? kRetryBackoffCap : d;
}

/// 一条任务已经自动重新提交过几次。
///
/// 不需要新字段：换源用掉的下标（`attempt`）和原地重试扣掉的额度
/// （`kAriaRetryTimes - retryRemains`）都已经落在任务表里，加起来就是
/// 已用次数 —— 重启后恢复的任务也接着算，不会把额度重置成满的。
int autoResubmitsUsed(DownloadTask t) =>
    t.attempt + (kAriaRetryTimes - t.retryRemains).clamp(0, kAriaRetryTimes);

/// 抖音下载必须带的来源页。**不是可选项** —— 见 [_requestOptions]。
const String kDouyinReferer = 'https://www.douyin.com/';

/// 请求用的浏览器 UA。抖音 CDN 对空 UA 也会拦。
const String kBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// 一次失败之后该怎么办。
enum RetryAction {
  /// 换到下一条候选下载地址（参照实现的「正在尝试同源其它下载地址」）
  switchSource,

  /// 用同一个地址再试一次（网络抖动）
  retrySame,

  /// 放弃，标记失败
  giveUp,
}

/// 纯函数：一次下载失败后如何继续。
///
/// **顺序刻意是「先换源、再原地重试」，与参照实现一致。**
/// 抖音的失败绝大多数属于「这条 CDN 地址本身不可用」（403 来源校验、
/// 签名过期、节点故障），换一条地址就好；原地重试同一个失效地址
/// 只会白等 —— 这既是效率问题，也是「抖音下载总失败」的观感来源。
///
/// [attempt] 是已经用到的候选下标（从 0 起）；
/// [permanent] 表示错误像 404/403 这类不可能靠重试恢复的。
RetryAction decideRetry({
  required int attempt,
  required int candidateCount,
  required int retryRemains,
  required bool permanent,
}) {
  if (attempt + 1 < candidateCount) return RetryAction.switchSource;
  if (!permanent && retryRemains > 0) return RetryAction.retrySame;
  return RetryAction.giveUp;
}

/// 明显不可能靠**原地重试**恢复的错误（资源不存在 / 无权限）。
///
/// 只用于挡掉「同一个地址再试 5 次」；**换源不受影响** ——
/// 因为同一个作品在另一条 CDN 地址上完全可能是好的（抖音 403 就是如此）。
/// 原版不做这层判断，会对 404 也白重试 5 次。
///
/// 注意它**不覆盖**「0 字节空响应」：那种情况由 `_handleFailure(forcePermanent:)`
/// 直接声明为永久失败。公开为顶层函数是为了让这段纯逻辑能被单测钉住。
final RegExp _permanentError = RegExp(
  r'(404|403|410)|Not Found|Forbidden|resource not found',
  caseSensitive: false,
);

bool isPermanentDownloadError(String msg) => _permanentError.hasMatch(msg);

/// 一次移除的结局。
enum RemoveOutcome {
  /// aria2 已确认移除（或本地根本没有 gid 可通知），本地行也删掉了
  removed,

  /// aria2 **明确回答「没有这条 GID」** —— 引擎侧本来就没有它了。
  ///
  /// 目标状态已达成，所以本地行照删，界面只给一句信息、不算错误。
  alreadyGone,

  /// RPC 连不通 / 超时 / 其它异常：本地行**保留**，界面对应弹错误。
  ///
  /// 这一档绝不能并进 [alreadyGone]：那种情况下 aria2 可能还在写同一个文件。
  failed,
}

/// 移除结果。[message] 只在 [RemoveOutcome.failed] 时有值（给用户看的原因）。
typedef RemoveResult = ({RemoveOutcome outcome, String? message});

/// aria2「这儿没有这条 GID」的 fault 形状。
///
/// 真机原文（2026-10-02，「错误」Tab 里一条早就失败的任务，× 点不掉）：
/// `Bad state: aria2 调用 aria2.remove 失败：GID e9b5ca82854c8163 is not found`。
/// 大小写一并容错，但**结构必须完整**（GID + 十六进制串 + is not found），
/// 单一个 "not found" 不算 —— 源站的 404 也带 Not Found，那不代表引擎没有这条任务。
///
/// 第二种措辞 `Active Download not found for GID#<hex>` 是 2026-10-04 用仓库自带的
/// `assets/aria2c.exe`（1.37.0）实测出来的：对**已完成 / 已失败落到 stopped / 已被
/// forceRemove** 的任务调 `aria2.remove`，回的都是这一句（`errorCode=1`，
/// RpcMethodImpl.cc:417），而**已暂停**的任务 `remove` 是直接成功的。
/// 也就是说它代表「这条已经不在活跃队列里了，引擎不会再写它的文件」——
/// 正是用户点不到的那批「错误」行的状态。缺了它，这些行的 remove 会被误判成真失败，
/// 旧行删不掉，重试就变成两行（本轮 bug 的直接原因）。
///
/// 同格式串里还有 `No active download for GID#%s`、`Could not remove download
/// result of GID#%s` 等，实测**不**来自 remove/forceRemove，所以不收 ——
/// 判据宁可窄：拿不准就留行、报错。
final RegExp _unknownGidFault = RegExp(
  r'\bGID\s+[0-9a-fA-F]{1,64}\s+is not found\b'
  r'|\bActive\s+Download\s+not\s+found\s+for\s+GID\s*#[0-9a-fA-F]{1,64}\b'
  r'|\bunknown gid\b',
  caseSensitive: false,
);

/// 纯函数：aria2 抛回来的错误**是否明确表示这个 GID 不存在**。
///
/// 判据刻意求窄 —— 只认 [_unknownGidFault] 里那两种「引擎实测会发的 GID 不存在」
/// 格式串，其余一概当失败：`404 Not Found`（源站没有资源）、连不通、超时、别的
/// faultCode 都不能算，否则就把 aria2 仍在下载的任务从界面上抹掉 —— 正是早前修掉的
/// 修掉的那条静默失败。拿不准时留在列表里让用户能重试，比假装成功安全。
///
/// 公开为顶层函数是为了让这条判据正反两面都能被单测钉住
/// （`test/remove_unknown_gid_test.dart` 带双向负控制）。
bool isUnknownGidFault(Object e) => _unknownGidFault.hasMatch('$e');

/// 从一批入队结果里，按作品归出**确认进入 aria2 队列**的任务 id 与展示元数据。
///
/// 台账只能记这些。早前的写法是「整批里成功数 > 0 → 把 `batch.awemeIds` 整批
/// 写进台账」，于是被 aria2 拒绝的作品也被标成已下载；用户开着「跳过已下载」时，
/// 这些作品会被永久静默跳过。
///
/// 注意交出去的是**任务 id 而不是「已下载」结论**：入队成功离文件到手还差一次
/// 下载，那一步由 [DouyinLedger.advance] 按任务结局推进（的改动）。
///
/// 没有 `tweetId` 的条目（X 的媒体走的是另一条路径）不会进结果集。
Map<String, DouyinQueuedAweme> queuedTasksByAweme(
  Iterable<({Media media, String? localId, EnqueueOutcome outcome})> results,
) {
  final out = <String, DouyinQueuedAweme>{};
  for (final r in results) {
    if (r.outcome != EnqueueOutcome.queued) continue;
    final id = r.media.tweetId;
    if (id == null || id.isEmpty) continue;
    final prev = out[id];
    out[id] = (
      taskIds: [
        ...?prev?.taskIds,
        if (r.localId != null) r.localId!,
      ],
      title: prev?.title ?? r.media.tweetText,
      author: prev?.author ?? r.media.userName,
    );
  }
  return out;
}

/// B 站「一条分 P = 视频流行 + 音频流行」的配对记录。
///
/// **为什么放在协调器里而不是 `Media` / `DownloadTask` 上**：`Media` 只有
/// 一条下载候选链（`url` + `altUrls` + `chosen`），X 与抖音全部路径都按它走；
/// 为 B 站把它改成「装两条流」会牵连所有下载路径。配对是**下载链路此刻的
/// 编排状态**（谁和谁要合成一个文件），归持有下载链路的这一层管正好，
/// 也刻意只在进程内存在 —— 重启后的重建见 [_rebuildBiliPairs]。
///
/// **刻意不存 localId，只存 base 名**：任务行会被换 id —— 失败自动重试
/// （[_resubmitAfterBackoff]）与手动重试（[retryTask]）都是「删旧行 + 重新
/// `_submit`」，那一步会给出**新的 localId**、但 `saveDir` 与 `fileName` 原样沿用
/// （见 [retryTask] 里那段「沿用当初解析好的那份」）。按 id 记配对的话，
/// 一次重试就把它变成孤儿，两条流永远等不齐；按名字找行则两条路径都不用补锅。
class _BiliPair {
  _BiliPair({
    required this.outBase,
    required this.saveDir,
    required this.merge,
    this.single = false,
    this.cfg,
    this.video,
    this.container = BiliContainer.mp4,
  });

  /// 成品容器。跟着入队那批的配置走；重启重建时取**当前设置**那一份
  /// （和 `merge` 一样的取舍，理由见 [_rebuildBiliPairs]）。
  final BiliContainer container;

  /// 投这一批时**实际生效**的那份配置（可能来自下载选项弹窗的本批覆盖）。
  /// null = 不知道（重启重建时设置被换过），此时附加文件那一步整个跳过。
  final BiliConfig? cfg;

  /// 视频侧那条 `Media`：附加文件要的 cid / 时长 / 封面全在里面（`bili.cid`、
  /// `durationMs`、`previewUrl`）。刻意不再拆一份出来 —— 拆了就有第二个真源，
  /// 而 `bili_page.dart` 那段逐字段重建 `BiliMeta` 的地方会把它静默丢掉。
  final Media? video;

  /// 合并前跑出来的附加文件结果（字幕轨、章节中间文件、没拿到的东西）。
  BiliAdditionalOutcome? additional;

  /// 不含扩展名的 base 名。三个名字（`.video.m4s` / `.audio.m4s` / `.mp4`）
  /// 全部由它派生，见 `bili_download_plan.dart` 的那组 `biliXxxName()`。
  final String outBase;
  final String saveDir;

  /// 这条要不要合并。入队时取 `BiliConfig.mergeAfterDownload`；
  /// 重启重建时取的是**当前设置**里那一份（当初的开关值没落盘，
  /// 也不给 `DownloadTask` 加字段）—— 这是明知要说清的取舍，见 [_rebuildBiliPairs]。
  final bool merge;

  /// true = 这一条压根只有一行（durl 退化路径给的就是完整 mp4）。
  ///
  /// 必须与「两条流、但音频行被用户删掉了」**分开**：前者一行下完就是成品，
  /// 后者是不能合（缺一路输入）。靠「查不到音频行」去推断会把后者判成前者，
  /// 于是那一行会被标成已合并、界面上报一个不存在的成品。
  final bool single;

  String get videoName => biliVideoStreamName(outBase);
  String get audioName => biliAudioStreamName(outBase);
  String get mergedName => biliMergedName(outBase, container);
  String get mergedPath => p.join(saveDir, mergedName);
  String get videoPath => p.join(saveDir, videoName);
  String get audioPath => p.join(saveDir, audioName);

  /// 已经排过 / 正在跑合并 —— 挡住「两条流的完成事件各触发一次合并」。
  bool mergeStarted = false;

  /// 已经收口（成功、或按设置不合并），不再重复通知。
  /// 合并**失败**时刻意不置 true：用户补好 ffmpeg 或重下其中一条之后还得能再合一次。
  bool settled = false;

  /// 按（目录 + 文件名）找回任务行。同名多行（重复入队留下的）取**最新**那条。
  DownloadTask? taskFor(DownloadStore store, String fileName) {
    DownloadTask? found;
    for (final t in store.tasks) {
      if (t.fileName != fileName || t.saveDir != saveDir) continue;
      if (found == null || t.createdAt.isAfter(found.createdAt)) found = t;
    }
    return found;
  }

  /// 配对表的键。目录也要进来：同一个 base 名可以落在不同目录里
  /// （文件夹模板按 UP 主分目录时，两个 UP 主的同名分 P 就是两个 base），
  /// 只用 base 当键会把它们并成一条，然后互相当对方的另一条流。
  String get key => '$saveDir|$outBase';
}

/// aria2 ↔ DownloadStore 之间的桥接器。
///
/// 职责：
///   1. 启动时一次性拉起 aria2c 子进程（`bootstrap()`），并暴露单例。
///   2. 把 aria2 的 5 类事件（start/pause/stop/complete/error）翻译成
///      `DownloadStore` 的状态变更。
///   3. 把进度反馈（按 gid 周期 tellStatus）写回 DownloadTask。
///   4. 提供「添加下载」「暂停」「继续」「删除」等高层动作。
///
/// **为什么单独做一层：** aria2 与 store 各自独立。aria2 只管 RPC，
///  store 只管本地状态；中间需要一个翻译层，否则 store 要被迫感知 aria2 协议细节。
class Aria2Coordinator {
  static Aria2Coordinator? _instance;
  static Aria2Coordinator get instance => _instance ??= Aria2Coordinator._();

  /// 单测用：把 [instance] 换成注入过假传输层的协调器（传 null 还原成懒建）。
  ///
  /// 下载管理页直接读 `Aria2Coordinator.instance`，没有别的缝隙 —— 不装这一个就
  /// 没法在 widget 测试里点真实的「×」，只能测到协调器的返回值、测不到用户看到的
  /// 那条提示到底是红色错误还是信息。
  @visibleForTesting
  static set instanceForTest(Aria2Coordinator? c) => _instance = c;

  Aria2Coordinator._() : _aria = Aria2();

  /// 单测用：注入假的传输层（跳过真实的 aria2c 进程与 WebSocket）。
  ///
  /// 只替换传输层 —— [bootstrap] 里的 store 绑定、事件订阅、并发下发
  /// 仍走生产代码路径，这样 `_submit` 的成功 / 失败两条分支都能被钉住
  /// （原报告 §7 指出的测试盲区）。
  ///
  /// [biliMerger] 同样只为测试留的缝隙：合并是「起真 ffmpeg 子进程」的事，
  /// 单测里要钉住的是「什么时候调、带哪三个路径、成/败各怎么收口」，
  /// 用一个假 merger 记调用就够，不该把真进程拉起来。
  /// 刻意做成**实例注入**而不是全局可换的单例 —— 换全局会把并发跑的
  /// 其他测试文件一起污染。
  @visibleForTesting
  Aria2Coordinator.withAria2(Aria2 aria, {BiliMerger? biliMerger})
      : _aria = aria {
    if (biliMerger != null) _biliMerger = biliMerger;
  }

  final Aria2 _aria;

  /// B 站 DASH 合并器。默认就是随包 ffmpeg 那一份（`BiliMerger()` 内部
  /// 已有全局串行闸门，多分 P 一起下完也不会并发起多个 ffmpeg）。
  ///
  /// 用户在设置里指定了外挂目录时，[BiliMerger.userDir] 会被同步成那个目录 ——
  /// 见 [_syncBiliFfmpegDir]。
  BiliMerger _biliMerger = BiliMerger();

  /// 设置变化的订阅标记：外挂 ffmpeg 目录改了要立刻生效。
  ///
  /// 用 bool 而不是存 `addListener` 的返回值 —— 那个方法返回 `void`，
  /// 拿不到可取消的句柄。协调器是进程级单例，与 SettingsStore 同生命周期，
  /// 不需要在别处反注册（真需要时得换成 `ChangeNotifier` 的显式解绑）。
  bool _settingsHooked = false;

  /// 把设置里的 `ffmpegDir` 同步给合并器。
  ///
  /// 幂等，可以随便调：目录没变时 `setUserDir` 自己会 early-return，
  /// 解析缓存也不会被无谓清掉。
  void _syncBiliFfmpegDir() {
    final dir = _settings?.settings.bili.ffmpegDir ?? '';
    _biliMerger.setUserDir(dir.isEmpty ? null : dir);
  }

  /// B 站的配对表（进程内）。键 = `saveDir|outBase`，见 [_BiliPair.key]。
  final Map<String, _BiliPair> _biliPairs = {};

  StreamSubscription? _startSub;
  StreamSubscription? _pauseSub;
  StreamSubscription? _stopSub;
  StreamSubscription? _completeSub;
  StreamSubscription? _errorSub;

  Timer? _progressPoll;

  /// 正在等退避 / 正在处理失败的 gid。
  ///
  /// aria2 的引擎级重试会对同一个 gid 连发多个 error 事件，加了等待之后
  /// 这些事件会并发落到「重新提交」上 —— 不挡住就是「越退避、提交次数越多」。
  final Set<String> _retryScheduled = {};

  DownloadStore? _store;
  SettingsStore? _settings;

  /// 附加文件的产出钩子，由装配层（`main.dart`）注进来。null = 只出成品。
  ///
  /// 这一层缺席或失败都**不该波及主产物**：合并照常、收口照常，缺的样目走
  /// `missing` 回到文案里。
  BiliAdditionalProduce? biliAdditional;

  /// 每次**真正**把一条媒体投给 aria2 并被接受后回调一次（`localId` 是任务表里的 id）。
  ///
  /// 为什么需要：首次入队之外的另一个调用点是**失败重试**（`_handleFailure`），
  /// 那里会 `store.remove()` 掉旧任务、用**新的 localId** 重新提交。抖音台账记的是
  /// 任务 id，不续上这个新 id，那条作品就永远查不到自己的结局 —— 既不算已下载、
  /// 也不会被撤销。由 `main()` 接线到 `DouyinLedger.attachTask`。
  void Function(Media media, String localId)? onTaskSubmitted;

  /// B 站一条分 P **收口**时回调一次（合并成功 / 决定不合并 / 合并失败）。
  ///
  /// 时序是这个回调存在的全部理由：台账的 `markDone` 只能在**合并成功之后**调，
  /// 不是入队时 —— 入队时文件还没到手，那时候记账等于把没下载完的分 P 标成
  /// 「已下载」，用户下次开着「跳过已下载」就再也下载不到它。
  /// 接线方式照 [onTaskSubmitted]（`main()` 里挂一次）。
  void Function(BiliSettleInfo info)? onBiliSettled;

  bool _booted = false;
  bool get booted => _booted;

  /// 已经走过退出流程 —— 退避等待期间用它挡住「应用都要关了还入队」。
  bool _closed = false;

  /// 单测用：换掉退避时长的算法（生产路径就是 [retryBackoffDelay]）。
  ///
  /// 之所以要做成实例字段而不是直接调用：单测把返回改成 `Duration.zero`
  /// 就能在几毫秒里跑完整个「退避 → 重新提交 → 再失败」的链路，
  /// 同时把「每次请求了多长的间隔」记下来断言它逐次变大。
  @visibleForTesting
  Duration Function(int resubmits) backoffFor = retryBackoffDelay;

  /// 给界面用的就绪信号。
  ///
  /// 为什么不只用 `booted`：它是个普通 bool，翻了没人重建界面。实测把随包的
  /// `aria2c.exe` 改名让引擎根本起不来，主页截图与正常状态**一模一样** ——
  /// 用户要一路点到下载、看着任务全部失败才知道出事了。
  static final ValueNotifier<bool> engineReady = ValueNotifier(false);

  /// 启动 aria2 子进程，并把事件流接到 store。
  ///
  /// 必须在 SettingsStore + DownloadStore 都构造好之后调用。
  Future<void> bootstrap({
    required DownloadStore store,
    required SettingsStore settings,
  }) async {
    if (_booted) return;
    _store = store;
    _settings = settings;

    // 外挂 ffmpeg 目录：启动时同步一次，并在设置变化时跟着走
    // （改完就能用，不必重启应用）。
    _syncBiliFfmpegDir();
    if (!_settingsHooked) {
      _settingsHooked = true;
      settings.addListener(_syncBiliFfmpegDir);
    }

    try {
      await _aria.bootstrap();
      AppLogger.log('ARIA2', 'aria2c 已启动');
    } catch (e) {
      debugPrint('[Aria2Coordinator] 启动失败：$e');
      AppLogger.log('ARIA2', 'aria2c 启动失败：$e');
      // 启动失败不抛 —— UI 上允许提示，但不要让整个应用崩
      return;
    }

    // 事件订阅
    _startSub = _aria.onDownloadStart.listen(_onStart);
    _pauseSub = _aria.onDownloadPause.listen(_onPause);
    _stopSub = _aria.onDownloadStop.listen(_onPause);
    _completeSub = _aria.onDownloadComplete.listen(_onComplete);
    _errorSub = _aria.onDownloadError.listen(_onError);

    // 进度轮询：每 1s 把活跃任务的进度从 aria2 拉回来
    _progressPoll = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollActive(),
    );

    _booted = true;
    engineReady.value = true;

    // 与上次退出时的任务表对账：aria2 用 `--input-file` 读回会话后 **gid 不变**
    // （实测），所以本地任务按 gid 就能找回自己。
    await reconcile();

    // 重启之后把 B 站的流配对**按文件名重建**回来。
    // 放在 `reconcile()` 之后：那一步会把「aria2 说完成」的行落成 complete，
    // 重建时才能一眼看出这对流是「都下完了等合并」还是「只回来一条」。
    _rebuildBiliPairs();

    // 并发数（参照实现的 `limit`，默认 4）是全局选项，启动时先落一次，
    // 免得用户上次改过的值在重启后失效。
    await applyConcurrency(settings.settings.douyin.concurrency);

    // 会话文件里读回来的**排队中**死任务也要摘（见 [_purgeOrphanSessionTasks]）：
    // 只靠 error 事件的话，它们会一直卡在队列里占着并发槽 —— 界面看不到它
    // （本地早就没有那一行），要等 `--lowest-speed-limit` 把它判成 Too slow
    // 才轮到 error，一个僵尸白占一到两分钟。
    await _purgeOrphanSessionTasks();
  }

  /// 扫描轮数上限（防呆；正常 2~3 轮就收敛）。
  static const int _kPurgeMaxRounds = 6;

  /// 每轮之间留给引擎做状态迁移（`waiting` → `active`、`remove` → `stopped`）。
  static const Duration _kPurgeRoundGap = Duration(milliseconds: 200);

  /// 开机扫一遍：把「aria2 会话里有、本地任务表里没有」的任务摘掉。
  ///
  /// 为什么要主动扫（2026-10-16）：`_handleFailure` 只在引擎**报 error** 时摘
  /// 僵尸，而 `--input-file` 读回的死任务先落在 `waiting`（引擎要去重试它才会
  /// 失败），那批 waiting 的僵尸永远走不到 error 那条路。另外从会话读回来就已经
  /// 是 `complete` / `error` 的那些不会再发任何事件，也只能在开机时扫一遍。
  ///
  /// **`tellActive` 同样必须扫**（2026-10-16 二次取证）：还有一类僵尸既不在
  /// waiting 也不在 stopped —— 读回后它直接进 active 去握手，握手挂住时
  /// `--lowest-speed-limit` 判不出来（真机取样 `totalLength=0`、`downloadSpeed=0`、
  /// `connections=1`，47 秒后仍是 `active`），于是它**永远不会**发 error 事件，
  /// `tellWaiting` / `tellStopped` 里也都查不到它，可退出时它照样被
  /// `--save-session` 写回 —— 每次开机复活一次。并发数为 1 时它独占唯一那个槽，
  /// 整个下载队列就此堵死。摘它要走 `remove`（它还在队列里），
  /// [_dropOrphanGid] 的两手顺序正好对得上。
  ///
  /// **一轮也扫不干净**：并发槽一空出来，引擎立刻把 `waiting` 里的下一条提升进
  /// `active`（真机日志里 `开始下载 gid=…` 就夹在清理行之间），等轮到扫 waiting
  /// 时那几条已经不在了。所以反复扫到「本轮一个**没见过的** gid 都没扫到」为止；
  /// 顺手把新 gid 记进 [handled]，同一批不会被反复重摘。
  ///
  /// 代价是开机时每轮三次 RPC（都只取 gid 列表）；**没有僵尸时只跑一轮就返回**，
  /// 用户完全感觉不到。**任何一步失败都只记日志** —— 它是一次尽力而为的清理，
  /// 不能拖住启动。
  Future<void> _purgeOrphanSessionTasks() async {
    final store = _store;
    if (store == null || !_booted) return;
    final scanned = <String>{};
    final handled = <String>{};
    var totalDropped = 0;
    var rounds = 0;
    for (var round = 1; round <= _kPurgeMaxRounds; round++) {
      rounds = round;
      var fresh = 0;
      for (final (label, fetch) in <(String, Future<List<String>> Function())>[
        ('aria2 活跃任务', _aria.tellActiveGids),
        ('aria2 等待队列', _aria.tellWaitingGids),
        ('aria2 已停任务', _aria.tellStoppedGids),
      ]) {
        List<String> gids;
        try {
          gids = await fetch();
        } catch (e) {
          AppLogger.log('ARIA2', '开机清理：读 $label 失败（跳过这一批）：$e');
          continue;
        }
        scanned.addAll(gids);
        var dropped = 0;
        for (final gid in gids) {
          // 本地表里有它 → 是用户看得见的任务，一律不动。
          if (store.taskByGid(gid) != null) continue;
          await _dropOrphanGid(gid, '开机清理：$label 里读回的会话残留');
          dropped++;
          if (handled.add(gid)) fresh++;
        }
        if (dropped > 0) {
          AppLogger.log('ARIA2', '开机清理：$label 里摘掉 $dropped 条会话残留'
              '（共扫到 ${gids.length} 条）');
        }
      }
      totalDropped += fresh;
      if (fresh == 0) break;
      await Future<void>.delayed(_kPurgeRoundGap);
    }
    if (totalDropped > 0) {
      // 摘完立刻落盘：退出那次保存靠不住（见 [Aria2.saveSession] 的说明），
      // 不落盘这批僵尸下次开机会从会话里原样读回来。
      await _saveSessionAfterPurge();
    }
    if (scanned.isNotEmpty) {
      AppLogger.log(
        'ARIA2',
        '开机清理完成：扫到 ${scanned.length} 条引擎侧任务，'
        '摘掉 $totalDropped 条会话残留（$rounds 轮）',
      );
    }
  }

  /// 把清理结果落盘；失败只记日志 —— 它只是「让这次清理立刻生效」，
  /// 没落盘也就退回「下次开机再摘一遍」，不能拖住启动。
  Future<void> _saveSessionAfterPurge() async {
    try {
      await _aria.saveSession();
      AppLogger.log('ARIA2', '开机清理：已把清理后的会话落盘');
    } catch (e) {
      AppLogger.log('ARIA2', '开机清理：会话落盘失败（下次开机再摘一遍）：$e');
    }
  }

  /// 重启对账：把**从任务表恢复出来的任务**与 aria2 的实际状态对齐。
  ///
  /// 对不上号时分两种处理，都不能让它继续挂在「下载中」：
  ///   - 文件已经在磁盘上且有内容 → 判定完成（别让用户重下一遍）；
  ///   - 文件也不在 → 标记失败并说明原因。
  Future<void> reconcile() async {
    final store = _store;
    if (store == null || !_booted) return;

    final restored = store.tasks
        .where((t) => t.aria2Gid != null && !t.status.isTerminal)
        .toList(growable: false);
    if (restored.isEmpty) return;

    var completed = 0;
    var lost = 0;

    for (final t in restored) {
      final gid = t.aria2Gid!;
      AriaTask? remote;
      try {
        remote = await _aria.tellStatus(gid);
      } catch (_) {
        remote = null; // aria2 不认识这个 gid
      }

      if (remote == null) {
        if (await _fileHasContent(t.fullPath)) {
          store.markComplete(gid);
          unawaited(biliStreamFinished(t.localId));
          completed++;
        } else {
          store.markErrorByGid(gid, '重启后未能恢复该任务（aria2 会话里已不存在）');
          lost++;
        }
        continue;
      }

      switch (remote.status) {
        case AriaStatus.complete:
          // 与 _onCompleteAsync 同一口径：0 字节不算成功
          if (await _fileHasContent(t.fullPath)) {
            store.markComplete(gid);
            // 重启对账判定完成的 B 站裸流也要走一次配对检查
            // （[_rebuildBiliPairs] 在 `bootstrap` 里排在 `reconcile` 之后，
            // 所以这里这一次只是把「aria2 说下完了」的行落成完成态，
            // 真正决定合不合的是它那一步）。
            unawaited(biliStreamFinished(t.localId));
            completed++;
          } else {
            store.markErrorByGid(gid, '服务器返回空内容（0 字节）');
          }
        case AriaStatus.error:
          store.markErrorByGid(
            gid,
            remote.error.isEmpty ? '未知错误' : remote.error,
          );
        case AriaStatus.paused:
          store.markPaused(t.localId);
        case AriaStatus.removed:
          store.markErrorByGid(gid, '任务已从 aria2 中移除');
        case AriaStatus.active:
          store.updateProgress(gid, _progressOf(remote), remote.totalSize,
              downloaded: remote.completeSize);
        case AriaStatus.waiting:
          // **排队中不是「下载中」**（2026-10-16 修）：此前两者共用一条分支，
          // 于是引擎里几百条 waiting 全被显示成「下载中 0%」。位次这一轮不查
          // （对账只跑一次，`_pollActive` 接手后会把「前面还有 N 条」补上）。
          store.updateProgress(gid, _progressOf(remote), remote.totalSize,
              downloaded: remote.completeSize);
          store.markWaiting(gid);
      }
    }

    AppLogger.log('ARIA2', '重启对账：$completed 个判定完成、$lost 个未能恢复');
  }

  /// 文件存在且不是空文件 —— 用来判断「这个任务其实已经下好了」。
  static Future<bool> _fileHasContent(String path) async {
    try {
      return await File(path).length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// 把一个 Media 加入 aria2 队列。store 会自动得到 gid 绑定。
  ///
  /// **文件名与文件夹都按用户设置的模板生成**（原版
  /// `download.ts::prepareDownloadTask` 的做法）：
  ///   - 文件夹 = `saveDirBase` + `resolveVariables(dirTemplate, media)`
  ///   - 文件名 = `resolveVariables(fileNameTemplate, media)`
  /// 模板为空时退回 `media.safeFileName`。
  ///
  /// 返回入队结果（[EnqueueResult]）：`localId` 用于反查，`outcome` 说明结局。
  Future<EnqueueResult> enqueueMedia(
    Media media, {
    String? customOut,
    DouyinConfig? douyin,
  }) async {
    if (!_booted) {
      debugPrint('[Aria2Coordinator] aria2 未就绪');
      AppLogger.log('DOWNLOAD', 'aria2 未就绪，无法入队：${media.id}');
      return (localId: null, outcome: EnqueueOutcome.notReady);
    }
    final store = _store;
    final settings = _settings;
    if (store == null || settings == null) {
      return (localId: null, outcome: EnqueueOutcome.notReady);
    }

    final dl = settings.settings.download;
    final baseDir = _resolveSaveDir(store, settings, douyin: douyin);

    // 模板来源：X 下载用全局的「下载」设置；抖音解析下载用它自己那一份，
    // 两个模块的命名规则因此互不干扰（`douyin == null` 即 X 侧调用）。
    //
    // 抖音的「启用保存文件夹」关掉时，**忽略文件夹模板** ——
    // 文件全部平铺在保存根目录里（这是用户明确的语义）。
    final tpl = pickTemplates(download: dl, douyin: douyin);
    final dirTpl = tpl.dirTemplate;
    final nameTpl = tpl.fileNameTemplate;

    // ① 文件夹模板 —— 解析结果里的 `/` 会被拆成多级目录
    //   （`resolveVariables` 只净化「变量值」，模板里的 `/` 原样保留）
    //
    // **抖音侧这里也仍用逐变量清洗，不换成整串清洗** —— 参照实现那套白名单
    // 会把 `/` 也换成 `_`，而 `/` 在我们的文件夹模板里是层级分隔符。
    final dirName = dirTpl.trim().isEmpty
        ? ''
        : resolveVariables(dirTpl, media).trim();
    final saveDir = _joinTemplateDir(baseDir, dirName);

    // ② 文件名模板。抖音侧要过参照实现那套**整串**清洗（换 `_` + 白名单 +
    //   压连续下划线 + 截 200），否则和参照实现下出来的名字对不上。
    //
    // ②′ 再过一道**全路径 260 保护**（三个模块共用这一处）：模板能拼出 200 码元
    //   的中文名，配上两级模板目录和保存根目录就越过 Windows 的 `MAX_PATH`。
    //   跨过去的表现不是报错，是 aria2 建文件失败、或那文件在资源管理器里
    //   打不开也删不掉 —— 所以宁可在入队前把名字裁短，并留一行日志说明裁过。
    final rawOut = customOut ?? _renderFileName(nameTpl, media, douyin: douyin);
    final out = clampNameForFullPath(saveDir, rawOut);
    if (out != rawOut) {
      AppLogger.log('DOWNLOAD', '路径超 260，文件名已裁短：'
          '${rawOut.length} → ${out.length} 码元（目录 ${saveDir.length}）');
    }

    // 确保目录存在
    try {
      await Directory(saveDir).create(recursive: true);
    } catch (_) {}

    // ③ 同名跳过（原版在入队前查一次文件是否存在）
    final fullPath = p.join(saveDir, out);
    AppLogger.log('DOWNLOAD', '解析路径：$fullPath');
    if (dl.sameFileSkip && await File(fullPath).exists()) {
      AppLogger.log('DOWNLOAD', '跳过（文件已存在）：$fullPath');
      return (localId: null, outcome: EnqueueOutcome.skippedExisting);
    }

    return _submit(media, saveDir, out, retryRemains: kAriaRetryTimes);
  }

  /// 真正把任务投给 aria2 并在 store 里登记。
  ///
  /// `enqueueMedia` 与「失败自动重试」共用这一段 —— 原版重试时同样是重新
  /// `addUri`，只是沿用递减过的 `ariaRetryCountRemains`。
  ///
  /// [attempt] 选第几条候选下载地址（0 = 首选）。换源重试时递增，
  /// 语义同参照实现的「正在尝试同源其它下载地址」。
  Future<EnqueueResult> _submit(
    Media media,
    String saveDir,
    String out, {
    required int retryRemains,
    int attempt = 0,
    int? speedLimitKbps,
  }) async {
    final store = _store;
    if (store == null) {
      return (localId: null, outcome: EnqueueOutcome.notReady);
    }

    final candidates = media.downloadCandidates;
    final index = candidates.isEmpty
        ? 0
        : attempt.clamp(0, candidates.length - 1);
    final url = candidates.isEmpty ? media.downloadUrl : candidates[index];

    final localId = store.addPending(
      media,
      saveDir,
      fileName: out,
      retryRemains: retryRemains,
      attempt: index,
      speedLimitKbps: speedLimitKbps,
    );

    try {
      final gid = await _aria.addUri(
        url,
        dir: saveDir,
        out: out,
        options: _requestOptions(media, speedLimitKbps: speedLimitKbps),
      );
      store.markActive(localId, gid);
      onTaskSubmitted?.call(media, localId);
      return (localId: localId, outcome: EnqueueOutcome.queued);
    } catch (e) {
      // 入队失败：任务**只有 localId**（还没有 gid），必须按 localId 标记，
      // 并且如实返回 rejected —— 调用方（抖音页 / 主页 / 创建任务）据此
      // 统计失败、且不把这批作品写进「已下载」台账。
      final msg = 'aria2 拒绝任务：$e';
      store.markErrorByLocalId(localId, msg);
      AppLogger.log('DOWNLOAD', '入队失败（$out）：$msg');
      return (localId: localId, outcome: EnqueueOutcome.rejected);
    }
  }

  /// 把 B 站一条分 P 的**两条 DASH 流**投给 aria2，并登记配对。
  ///
  /// 命名契约（`bili_download_plan.dart` 里那三个函数是唯一定义处）：
  ///   - 视频流那行 `<outBase>.video.m4s`
  ///   - 音频流那行 `<outBase>.audio.m4s`
  ///   - 合并产物   `<outBase>.mp4`
  /// 两条流走的都是既有的 [_submit]，所以**两行都是正常可见的任务行**：
  /// 用户看得见「音频流」的进度，也才能单独重试它（合并失败时这是唯一的出路）。
  ///
  /// [audioMedia] 没有流（`url` 空或 `chosen` 为空）时按 **durl 退化路径**处理：
  /// 那是 `playurl` 不给 dash、只给一个完整 mp4 的老稿件，投一条、不建配对，
  /// 合并这一步整段跳过。
  ///
  /// **需要凭据的流不在这里想办法。** 取不到就是取不到，如实回一句
  /// [BiliEnqueueResult.message]；绝不把 cookie 塞进 header ——
  /// per-task header 会被 `--save-session` 原样写进磁盘（实测见 [_requestOptions]）。
  Future<BiliEnqueueResult> enqueueBiliMedia(
    Media videoMedia,
    Media audioMedia,
    String outBase,
    BiliConfig cfg,
  ) async {
    if (!_booted) {
      AppLogger.log('BILI', 'aria2 未就绪，无法入队：${videoMedia.id}');
      return (
        outcome: EnqueueOutcome.notReady,
        videoLocalId: null,
        audioLocalId: null,
        outPath: null,
        message: '下载引擎还没起来（aria2 未就绪），请稍后重试',
      );
    }
    final store = _store;
    final settings = _settings;
    if (store == null || settings == null) {
      return (
        outcome: EnqueueOutcome.notReady,
        videoLocalId: null,
        audioLocalId: null,
        outPath: null,
        message: '下载模块还没初始化完',
      );
    }

    var base = outBase.trim();
    if (base.isEmpty) {
      AppLogger.log('BILI', 'base 名为空，拒绝入队：${videoMedia.id}');
      return (
        outcome: EnqueueOutcome.rejected,
        videoLocalId: null,
        audioLocalId: null,
        outPath: null,
        message: '算不出这条分 P 的文件名（模板展开结果是空的）。',
      );
    }
    if (videoMedia.url.isEmpty) {
      // 没有可下地址只有一种来源：选流没选出东西，而 B 站只在
      // 「要登录 / 要大会员」时才不给流。这句话必须原样带给用户，
      // 而不是让他对着一个「失败」的红条猜为什么。
      AppLogger.log('BILI', '没有可下载的视频流，拒绝入队：$base');
      return (
        outcome: EnqueueOutcome.rejected,
        videoLocalId: null,
        audioLocalId: null,
        outPath: null,
        message: '这条分 P 没取到可下载的流。更高画质 / 更高编码通常需要'
            '登录或大会员凭据，本期不支持带凭据下载。',
      );
    }

    final dl = settings.settings.download;
    final saveDir = _joinTemplateDir(
      _resolveBiliSaveDir(store, settings, cfg),
      // 文件夹模板照抖音那条路：关掉「启用保存文件夹」就平铺。
      cfg.enableSaveFolder
          ? resolveVariables(cfg.dirTemplate, videoMedia).trim()
          : '',
    );
    // 全路径 260 保护：B 站一条分 P 会派生三个名字（`.video.m4s` / `.audio.m4s`
    // / 成品 `.mp4`）。压的是 **base**，不是压派生名再反推 —— 反过来做会踩坑：
    // `biliBaseNameFromFileName('x.video.m4s')` 只剥得掉 `.m4s`，剩下 `x.video`
    // 再当 base 用，名字就一路加长下去了。
    // 附加后缀的字符数问 `biliVideoStreamName` 自己拿，不在这里写死 `.video.m4s`。
    final suffixLen = biliVideoStreamName('a').length - 1;
    final maxBaseLen = kWindowsMaxPath - kPathSlack - saveDir.length - 1 - suffixLen;
    if (base.length > maxBaseLen) {
      AppLogger.log('BILI', '路径超 260，base 已裁短：'
          '${base.length} → ${maxBaseLen.clamp(1, base.length)} 码元'
          '（目录 ${saveDir.length}）');
      base = base.substring(0, maxBaseLen.clamp(1, base.length));
    }
    // durl 退化路径的判据是「音频侧压根没有流」。刻意不用 `!cfg.mergeAfterDownload`
    // 当判据 —— 那是「用户不想合」，这是「没有东西可合」，两件事不能混：
    // 关掉合并开关时，DASH 仍然要投两条（留下两个裸流是用户明确要的）。
    final single = audioMedia.url.isEmpty || audioMedia.chosen == null;
    final pair = _BiliPair(
      outBase: base,
      saveDir: saveDir,
      merge: cfg.mergeAfterDownload && !single,
      single: single,
      cfg: cfg,
      video: videoMedia,
      container: cfg.container,
    );

    try {
      await Directory(saveDir).create(recursive: true);
    } catch (_) {}

    // 同名跳过（与 [enqueueMedia] 同一条口径）：B 站要看的是**成品**在不在，
    // 而不是裸流在不在 —— 上次只下完视频流就崩了，这次必须能接着把音频流下回来。
    if (dl.sameFileSkip && await File(pair.mergedPath).exists()) {
      AppLogger.log('BILI', '跳过（成品已存在）：${pair.mergedPath}');
      return (
        outcome: EnqueueOutcome.skippedExisting,
        videoLocalId: null,
        audioLocalId: null,
        outPath: pair.mergedPath,
        message: '文件已经在磁盘上，没有重复下载：${pair.mergedName}',
      );
    }

    // 0 是「不限」，这时候**干脆不传这个 option** —— 传 `0K` 虽然语义相同，
    // 但会让 session 文件里凭空多出一堆没用的字段。
    final limit = cfg.speedLimitKbps > 0 ? cfg.speedLimitKbps : null;

    final v = await _submit(
      videoMedia,
      saveDir,
      single ? pair.mergedName : pair.videoName,
      retryRemains: kAriaRetryTimes,
      speedLimitKbps: limit,
    );
    if (v.outcome != EnqueueOutcome.queued) {
      return (
        outcome: v.outcome,
        videoLocalId: v.localId,
        audioLocalId: null,
        outPath: pair.mergedPath,
        message: '视频流没能进下载队列',
      );
    }
    String? audioId;
    if (!single) {
      final a = await _submit(
        audioMedia,
        saveDir,
        pair.audioName,
        retryRemains: kAriaRetryTimes,
        speedLimitKbps: limit,
      );
      if (a.outcome != EnqueueOutcome.queued) {
        // 只进去一半：**不回滚视频那条**（它正在下，删掉等于把已到手的字节扔掉），
        // 两行都留在界面上，用户重试音频那一行就能接上。
        AppLogger.log('BILI', '音频流入队失败（视频流已在队列里）：$base');
        return (
          outcome: a.outcome,
          videoLocalId: v.localId,
          audioLocalId: a.localId,
          outPath: pair.mergedPath,
          message: '音频流没能进下载队列（视频流那条已经在里面了）。'
              '重试这一条即可，两条都下完才会合并。',
        );
      }
      audioId = a.localId;
    }

    _biliPairs[pair.key] = pair;
    AppLogger.log(
      'BILI',
      single
          ? 'B 站分 P 已入队（durl 单文件，不需要合并）：${pair.mergedPath}'
          : 'B 站分 P 两条流已入队：${pair.videoName} + ${pair.audioName}'
                ' → ${pair.mergedName}'
                '${cfg.mergeAfterDownload ? '' : '（按设置不合并，留裸流）'}',
    );
    return (
      outcome: EnqueueOutcome.queued,
      videoLocalId: v.localId,
      audioLocalId: audioId,
      outPath: pair.mergedPath,
      message: cfg.mergeAfterDownload || single
          ? null
          : '按设置没有合并，留下的是两个 .m4s 裸流（都不能单独播放）。',
    );
  }

  /// B 站的保存根目录。
  ///
  /// 优先级与 [resolveSaveBase] 完全同一条（自己那份 > 会话记的 > X 下载设的 >
  /// 兜底），只是把「自己那一头的 `saveDirBase`」换成 [BiliConfig] 的。
  /// 没有给 `resolveSaveBase` 加一个 `bili` 参数：它的签名同时被 X 与抖音两条路
  /// 用着，而这一期的改动范围钉在协调器 + 任务表两个文件上。
  String _resolveBiliSaveDir(
    DownloadStore store,
    SettingsStore settings,
    BiliConfig cfg,
  ) {
    final own = cfg.saveDirBase.trim();
    if (own.isNotEmpty) return own;
    return resolveSaveBase(
      sessionSaveDir: store.defaultSaveDir,
      xSaveDirBase: settings.settings.download.saveDirBase,
      fallback: defaultDownloadDir(),
    );
  }

  /// 「一条 B 站流下完了」之后要做的事 —— 所有完成落点都汇到这里。
  ///
  /// 公开（而不是私有）的原因要说清：**这一层没有别的缝隙**。
  /// `Aria2` 的事件流是私有 `StreamController`（`_downloadComplete` 那五个），
  /// 注入假的传输层也发不出 `onDownloadComplete` 事件，所以「两条都完成才合并」
  /// 这条最要紧的时序想被单测钉住，就只能由外面直接调这个方法。
  /// 生产路径依旧是三处在调它：[_onCompleteAsync]（aria2 的完成事件）、
  /// [reconcile]（重启对账判定完成）、[retryTask]（磁盘上已经有文件）。
  Future<void> biliStreamFinished(String localId) async {
    final store = _store;
    if (store == null) return;
    final t = store.task(localId);
    if (t == null || t.status != DownloadStatus.complete) return;
    // X 与抖音的完成也走这个方法（它们共用 [_onCompleteAsync]），但配对表里
    // 只有 B 站的条目 —— 先按来源挡掉，省得每条 X 图片下完都去扫一遍表。
    if (t.media.source != 'bili') return;
    final pairs = _pairsForTask(t, store);
    for (final pair in pairs) {
      await _settleOneBiliPair(pair, store);
    }
  }

  /// 这个任务行属于哪（几）条配对。按 (目录, 文件名) 认，不按 id —— 理由见
  /// [_BiliPair] 顶上那段「失败重试会换 id」。
  ///
  /// 顺带清理：两条流都不在任务表里了（被用户删掉）的配对从表里忘掉，
  /// 否则一个长批跑下来这张表只会一直变大。
  List<_BiliPair> _pairsForTask(DownloadTask t, DownloadStore store) {
    final out = <_BiliPair>[];
    for (final pair in _biliPairs.values.toList(growable: false)) {
      if (pair.saveDir != t.saveDir) continue;
      if (t.fileName == pair.videoName ||
          t.fileName == pair.audioName ||
          (pair.single && t.fileName == pair.mergedName)) {
        out.add(pair);
        continue;
      }
      if (pair.taskFor(store, pair.videoName) == null &&
          pair.taskFor(store, pair.audioName) == null) {
        _biliPairs.remove(pair.key);
      }
    }
    return out;
  }

  /// 合并之前把附加文件取回来落盘。
  ///
  /// 三条判据都得成立，否则一个请求都不发：这一批的配置知道、这一 P 的
  /// `cid` 拿得到、用户确实勾了至少一种附加文件。
  ///
  /// **失败不许拖垮合并**：主产物完好就算下载成功（台账红线），缺的那几样
  /// 走 `missing` 回到收口文案里，用户看得见。参照实现这里是静默跳过的。
  Future<void> _produceAdditional(_BiliPair pair, {required bool merging}) async {
    final produce = biliAdditional;
    final cfg = pair.cfg;
    final video = pair.video;
    if (produce == null ||
        cfg == null ||
        video == null ||
        video.bili?.cid == null ||
        !biliAsksForAnything(cfg)) {
      return;
    }
    // 没开合并这一条不是用户选的，是这一对压根只有一个文件（durl 退化路径）或
    // 他关了合并 —— 那内封的前提就不成立，用改过的副本让 embedBlockReason 给出
    // 真实的原因，而不是报一句「要开合并」却明明是别的缘故。
    final effective = merging ? cfg : cfg.copyWith(mergeAfterDownload: false);
    try {
      pair.additional = await produce(
        cfg: effective,
        saveDir: pair.saveDir,
        outBase: pair.outBase,
        video: video,
      );
      final missing = pair.additional!.missing;
      if (missing.isNotEmpty) {
        AppLogger.log('BILI', '附加文件缺项（${pair.outBase}）：${missing.join('、')}');
      }
    } catch (e) {
      AppLogger.log('BILI', '附加文件这一步整个失败了（成品不受影响）：$e');
      pair.additional = const BiliAdditionalOutcome(
        tracks: [],
        written: [],
        missing: ['附加文件没跑起来'],
      );
    }
  }

  /// 章节那份 ffmetadata 是给 ffmpeg 当输入用的中间文件，**不是交付物**。
  /// 删不掉只记日志：成品已经合好了，不能因为一个临时文件留在盘上就把成功改判成失败。
  Future<void> _dropChapterScratch(_BiliPair pair) async {
    final scratch = pair.additional?.chapterMetadataPath;
    if (scratch == null) return;
    try {
      final f = File(scratch);
      if (await f.exists()) await f.delete();
    } catch (e) {
      AppLogger.log('BILI', '章节中间文件没删掉（成品不受影响）：$scratch —— $e');
    }
  }

  /// 把缺的附加文件写在**完成的那一行**上。
  ///
  /// 收口 message 今天只有失败分支会被读（台账桥接就是那么写的），
  /// 所以「部分成功」必须另找一个界面真的在读的落点，否则等于没说。
  void _writeAdditionalNote(_BiliPair pair, DownloadStore store) {
    final missing = pair.additional?.missing;
    if (missing == null || missing.isEmpty) return;
    final row = pair.taskFor(store, pair.mergedName);
    if (row == null) return;
    store.markNote(row.localId, '没拿到：${missing.join('、')}');
  }

  /// 「勾了但没拿到」要出现在收口文案里，只进日志等于用户看不见。
  String _additionalNote(_BiliPair pair) {
    final missing = pair.additional?.missing;
    if (missing == null || missing.isEmpty) return '';
    return '（没拿到：${missing.join('、')}）';
  }

  /// 一条配对收口：够不齐就等着，够齐就合（或按设置留裸流）。
  Future<void> _settleOneBiliPair(_BiliPair pair, DownloadStore store) async {
    if (pair.settled || pair.mergeStarted) return;

    if (pair.single) {
      // durl 退化路径：那一条本身就是成品，没有什么可等的。
      pair.settled = true;
      await _produceAdditional(pair, merging: false);
      _biliPairs.remove(pair.key);
      AppLogger.log('BILI', 'B 站分 P 完成（单文件，无需合并）：${pair.mergedPath}');
      _notifyBili(pair, BiliSettleKind.merged,
          '已下载完成：${pair.mergedName}${_additionalNote(pair)}');
      return;
    }

    final video = pair.taskFor(store, pair.videoName);
    final audio = pair.taskFor(store, pair.audioName);
    if (video == null || audio == null) {
      // 只回来一条：**不猜、也不合**（缺音频合出来是个 0 秒空壳）。
      // 留在表里等另一条 —— 用户把那一行重试成功就会再走到这里。
      final missing = video == null ? pair.videoName : pair.audioName;
      AppLogger.log('BILI', '配对还缺一条流（$missing 不在任务表里），先不合并：${pair.outBase}');
      return;
    }
    if (video.status != DownloadStatus.complete ||
        audio.status != DownloadStatus.complete) {
      return; // 另一条还在下
    }

    await _produceAdditional(pair, merging: pair.merge);

    if (!pair.merge) {
      pair.settled = true;
      _biliPairs.remove(pair.key);
      AppLogger.log('BILI', '两条流都下完了，按设置**不**合并：${pair.videoName} + ${pair.audioName}');
      _notifyBili(
        pair,
        BiliSettleKind.streamsKept,
        '两条裸流都已下载（没开合并，它们各自都不能单独播放）'
        '${_additionalNote(pair)}。',
      );
      return;
    }
    await _mergeBiliPair(pair, store, video: video, audio: audio);
  }

  /// 真去起一次 ffmpeg。
  Future<void> _mergeBiliPair(
    _BiliPair pair,
    DownloadStore store, {
    required DownloadTask video,
    required DownloadTask audio,
  }) async {
    pair.mergeStarted = true;
    final outPath = pair.mergedPath;

    // 产物已经在（上次合完了但没走到改行名，或用户自己放过同名文件）：
    // 再合一次会覆盖成品，所以直接按成功收口，只把两行收干净。
    if (await _fileHasContent(outPath)) {
      AppLogger.log('BILI', '合并产物已存在，不重复合，只把两行收口：$outPath');
      _finalizeBiliMerge(pair, store);
      return;
    }
    if (!await _fileHasContent(pair.videoPath) ||
        !await _fileHasContent(pair.audioPath)) {
      pair.mergeStarted = false;
      AppLogger.log('BILI', '合并前发现裸流文件不在磁盘上，保持未合并：${pair.outBase}');
      _notifyBili(
        pair,
        BiliSettleKind.mergeFailed,
        '合并没做成：磁盘上找不到两条裸流文件（被移走或删掉了？）。'
        '重新下载这一条分 P 即可。',
        commandLine: null,
      );
      return;
    }

    AppLogger.log(
      'BILI',
      '开始合并：${pair.videoName} + ${pair.audioName} → ${pair.mergedName}',
    );
    final extra = pair.additional;
    // MP4 装不下 ass（实测：整个文件写不出来，不是掉一条轨那么轻），
    // 所以这一层就是最后一道闸：容器不是 MKV 时把轨丢在门外，
    // 并且**不静默** —— 把原因挂到缺项里，让完成那一行说清楚。
    var tracks = extra?.tracks ?? const <BiliEmbeddedTrack>[];
    if (tracks.isNotEmpty && pair.container != BiliContainer.mkv) {
      AppLogger.log(
        'BILI',
        '容器是 ${pair.container.id}，装不下内封轨，这 ${tracks.length} 条只留侧文件：${pair.outBase}',
      );
      pair.additional = BiliAdditionalOutcome(
        tracks: const [],
        written: extra!.written,
        missing: [...extra.missing, '内封轨要 MKV 容器'],
        chapterMetadataPath: extra.chapterMetadataPath,
      );
      tracks = const [];
    }
    final r = await _biliMerger.merge(
      videoPath: pair.videoPath,
      audioPath: pair.audioPath,
      outPath: outPath,
      subtitleTracks: [
        for (final t in tracks)
          (
            path: p.join(pair.saveDir, t.fileName),
            title: t.title,
            lang: t.iso639,
          ),
      ],
      chapterPath: extra?.chapterMetadataPath,
    );

    if (r.ok) {
      _finalizeBiliMerge(pair, store);
      await _dropChapterScratch(pair);
      _writeAdditionalNote(pair, store);
      AppLogger.log('BILI', '合并成功：$outPath${r.message.isEmpty ? '' : '（${r.message}）'}');
      _notifyBili(
        pair,
        BiliSettleKind.merged,
        '已合并为 ${pair.mergedName}${_additionalNote(pair)}',
      );
      return;
    }

    // 失败：**两条原始流与两个文件一律保留**，界面上两行都还是 `.m4s`。
    // 合并失败不是下载失败 —— 字节都到手了，把行标成错误反而会让用户重下一遍。
    // `mergeStarted` 放回去，让「重试其中一条流」或界面上的再次合并还能走到这里。
    pair.mergeStarted = false;
    AppLogger.log(
      'FFMPEG',
      'B 站合并失败（${r.failure?.name}）：${r.message}\n'
      '  可复现命令：${r.commandLine}\n'
      '  stderr 摘要：${r.stderr}',
    );
    _notifyBili(
      pair,
      BiliSettleKind.mergeFailed,
      '合并失败：${r.message}',
      commandLine: r.commandLine,
    );
  }

  /// 合并成功之后收口两行：视频行改叫 `<base>.mp4`，音频行删掉。
  ///
  /// 音频行走 [DownloadStore.remove]（只删本地行）而**不是**协调器那个会先问
  /// aria2 的 [remove]：`BiliMerger` 成功时已经把两条 `.m4s` 文件删了，
  /// 这时候要是 RPC 一失败就「保留行不动」，界面上会永远留着一行指向
  /// 一个已经不存在于磁盘的文件 —— 那是比多留一行更糟的静默不一致。
  void _finalizeBiliMerge(_BiliPair pair, DownloadStore store) {
    pair.settled = true;
    _biliPairs.remove(pair.key);
    final video = pair.taskFor(store, pair.videoName);
    final audio = pair.taskFor(store, pair.audioName);
    if (video != null) {
      final renamed = store.renameTaskFile(video.localId, pair.mergedName);
      AppLogger.log(
        'BILI',
        renamed
            ? '视频行的名字已改成成品：${pair.videoName} → ${pair.mergedName}'
            : '视频行改名没成（行已不在了？）：${pair.videoName}',
      );
    }
    if (audio != null) {
      store.remove(audio.localId);
      AppLogger.log('BILI', '音频行已收掉（裸流文件被合并器删掉了）：${pair.audioName}');
    }
  }

  /// 把收口结局回给页面（台账 `markDone` 的时序就挂在这里）。
  void _notifyBili(
    _BiliPair pair,
    BiliSettleKind kind,
    String message, {
    String? commandLine,
  }) {
    final cb = onBiliSettled;
    final store = _store;
    if (cb == null || store == null) return;
    // 两条名字都要查：合并成功那条路是**先改完行名再回调**的，
    // 这时候视频行已经叫 `<base>.mp4` 了 —— 只按 `.video.m4s` 找就会找不到，
    // 于是「合并成功」这个最重要的信号永远发不出去，台账永远转不成 done。
    final video =
        pair.taskFor(store, pair.videoName) ?? pair.taskFor(store, pair.mergedName);
    final media = video?.media;
    if (media == null) return; // 视频行没了就没有记账对象，别拿空键组去写台账
    cb((
      kind: kind,
      outBase: pair.outBase,
      saveDir: pair.saveDir,
      media: media,
      message: message,
      commandLine: commandLine,
    ));
  }

  /// 重启之后按**文件名**把配对重建回来。
  ///
  /// 选了哪条策略、为什么：**重建**，而不是「只记一句日志，两行永远停在
  /// 已完成（未合并）」。后者的问题是它把补救整个推回给用户 —— 磁盘上明明躺着
  /// 能合成品的两条流，界面上却是两个点开来放不了的文件，而用户唯一能做的
  /// 操作是把这一条分 P 重下一遍。
  ///
  /// 凭什么是文件名：三个名字都由同一个 base 派生，base 又是模板算出来的，
  /// 所以「同一个目录里的 `X.video.m4s` 与 `X.audio.m4s`」必然出自同一条分 P。
  /// 刻意**不去读 `Media` 里的配对字段**：`Media.toJson` 不写 `chosen` / `variants`
  /// （见 `media.dart` 里那段「刻意不写」的理由），重启后这两样都是空的，
  /// 能靠的只有名字 —— 这也正是配对不进 `Media`、不进 `DownloadTask` 的代价，
  /// 写在这里是为了让下一个读这段的人知道这笔账是明算过的。
  ///
  /// 「当初开没开合并」没有落盘，所以重建时读**当前设置**里的
  /// `bili.mergeAfterDownload`。取舍说清：用户在下完之后关掉合并再重启，
  /// 这两条会按关掉后的语义留着当裸流，而不是被合出一个他现在不想要的文件。
  ///
  /// 只回来一条（另一行被删了 / 那条本来就失败）时**如实记一行日志**并保持
  /// 「已完成（未合并）」—— 不假装它能自己长回来。
  ///
  /// durl 退化路径那种「一行就是成品」的 `bili` 任务不在这里重建：
  /// 它没有配对状态要恢复（文件已经在磁盘上了），重启后也不需要这里补一次
  /// 收口通知 —— 台账侧本来就有 [BiliLedger.advance] 那条「不看事件顺序、
  /// 拿任务表对一遍就能纠正」的路，页面启动时推一次即可。
  void _rebuildBiliPairs() {
    final store = _store;
    if (store == null) return;

    final biliCfg = _settings?.settings.bili;
    final merge = biliCfg?.mergeAfterDownload ?? true;
    final rebuilt = <String, _BiliPair>{};
    var videoSide = 0;
    var audioSide = 0;

    for (final t in store.tasks) {
      if (t.media.source != 'bili') continue;
      final isVideo = t.fileName.endsWith('.video.m4s');
      final isAudio = !isVideo && t.fileName.endsWith('.audio.m4s');
      if (!isVideo && !isAudio) continue;
      final outBase = isVideo
          ? t.fileName.substring(
              0, t.fileName.length - '.video.m4s'.length)
          : t.fileName.substring(
              0, t.fileName.length - '.audio.m4s'.length);
      final key = '${t.saveDir}|$outBase';
      final pair = rebuilt.putIfAbsent(
        key,
        () => _BiliPair(
          outBase: outBase,
          saveDir: t.saveDir,
          merge: merge,
          cfg: biliCfg,
          container: biliCfg?.container ?? BiliContainer.mp4,
          // 时长、封面、cid 都跟着 media 一起存过盘，重启后仍然拿得回来 ——
          // 这是「上次没来得及出附加文件」这一格还能补上的前提。
          video: t.media,
        ),
      );
      if (isVideo) {
        videoSide++;
      } else {
        audioSide++;
      }
      // 已经有同名兄弟（重复入队留下的）：`taskFor` 会自己挑最新那条，
      // 这里不用管，配对照样认得出来。
      _biliPairs[key] = pair;
    }

    if (rebuilt.isEmpty) return;
    AppLogger.log(
      'FFMPEG',
      '重启后按文件名重建了 B 站裸流配对：$videoSide 条视频流 / $audioSide 条音频流'
          '（共 ${rebuilt.length} 组）',
    );

    // 两条都已经在「已完成」的配对，立刻走一次收口（合并或留裸流）；
    // 还没下完的那些由后续的完成事件自己走到 [_settleOneBiliPair]。
    for (final pair in rebuilt.values) {
      final v = pair.taskFor(store, pair.videoName);
      final a = pair.taskFor(store, pair.audioName);
      if (v == null || a == null) {
        AppLogger.log(
          'FFMPEG',
          '配对不全，保持未合并：${pair.outBase} —— '
          '${v == null ? pair.videoName : pair.audioName} 那一行不在任务表里'
          '（上次没下完或被删了），需要重新下载这一条分 P。',
        );
        continue;
      }
      unawaited(_settleOneBiliPair(pair, store));
    }
  }

  /// 单任务请求头。
  ///
  /// **抖音必须补 Referer。** 实测（2026-09-14）：同一条作品的多个
  /// `play_addr` 里，`v26-web.douyinvod.com` 上的地址**不带 Referer 直接 403**，
  /// 带上 `Referer: https://www.douyin.com/` 才返回 206；而 `v11-weba` 上的
  /// 地址不带也放行 —— 也就是说**能不能下载取决于分到哪个 CDN 节点**，
  /// 这正解释了「有时能下、多数时候下不动」。
  ///
  /// 在页面里 `fetch()` 不会有这个问题，浏览器自动带上
  /// Referer / Origin / cookie；aria2 是站外进程，必须显式补。
  /// 这里用**单任务**选项而不是全局 `changeGlobalOption`，
  /// 避免把来源头污染给 X 的下载。
  ///
  /// **B 站只补 Referer + User-Agent，刻意不带 Cookie。**
  /// 2026-10-10 用随包的 `aria2c.exe` 1.37.0 实测：`addUri` 传的 per-task
  /// `header` 会被 `--save-session` **逐条原样写进会话文件**，本项目那个会话文件
  /// 在 `userdata` 里、每 30 秒落一次盘 —— 实测片段就是
  /// `header=Cookie: SESSDATA=…` 明文躺在盘上。
  /// （另外那条「完成后就不写了」的现象别当结论：任务**完成后** aria2 确实不再
  /// 持久化这一条，所以在完成之后去读会话文件会拿到 0 字节，那只说明「这一条已经
  /// 从会话里掉了」，不说明「从来没写过）。）
  ///
  /// 结论：**登录态一律不许经过 aria2 这一层。** 需要凭据才能取的流这一期不支持，
  /// 由 `planBiliStreams()` 返回可读原因（见 [BiliEnqueueResult.message]），
  /// 而不是想办法把 cookie 递过去。
  Map<String, String>? _requestOptions(
    Media media, {
    int? speedLimitKbps,
  }) {
    switch (media.source) {
      case 'douyin':
        return const {
          'referer': kDouyinReferer,
          'user-agent': kBrowserUserAgent,
        };
      case 'bili':
        // 键名按 aria2 的选项写法（小写），值复用接口层那一份常量 ——
        // 页面取流、下载器取流用的是同一个 UA/Referer，才不会出
        // 「页面能播、下载 403」这种极难归因的组合。
        //
        // 限速也挂在这里：它是 per-task option，不是 header，写进
        // `aria2.session` 只是一个数字，不碰「凭据不许落盘」那条线。
        return {
          'referer': kBiliReferer,
          'user-agent': kBiliUserAgent,
          if (speedLimitKbps != null && speedLimitKbps > 0)
            'max-download-limit': '${speedLimitKbps}K',
        };
    }
    return null; // X 不需要来源头
  }

  /// 解析保存根目录。规则见 [resolveSaveBase]（纯函数，可单测）。
  String _resolveSaveDir(
    DownloadStore store,
    SettingsStore settings, {
    DouyinConfig? douyin,
  }) => resolveSaveBase(
    douyin: douyin,
    sessionSaveDir: store.defaultSaveDir,
    xSaveDirBase: settings.settings.download.saveDirBase,
    fallback: defaultDownloadDir(),
  );

  /// 把文件夹模板的解析结果拼到保存根目录下。
  ///
  /// 模板里可以写 `%USER_SCREEN_NAME%/%POST_ID%` 生成多级目录 ——
  /// 段列表交给 `parseDirSegments()`（在 file_name_template.dart 里，可单测）。
  static String _joinTemplateDir(String baseDir, String dirName) {
    final segments = parseDirSegments(dirName);
    if (segments.isEmpty) return baseDir;
    return p.joinAll([baseDir, ...segments]);
  }

  /// 按平台渲染最终文件名。
  ///
  /// 抖音侧走 [resolveDouyinFileName]（拼好整串再按参照实现那套清洗），
  /// X 侧保持原有的逐变量净化 —— 两套规则不同（换 `_` 还是 `!`、要不要压
  /// 连续下划线），混用会让两边的文件名都对不上各自的参照物。
  ///
  /// **B 站选了「逐变量净化」这一条（[resolveVariables]），不是整串清洗。**
  /// 三条理由，按分量排：
  ///  1. **预览必须与落盘同源。** 设置页 B 站分区的「输出示例」用的就是
  ///     `bili_section.dart` 里的 `kBiliFileNameResolver`，而那个常量此刻就是
  ///     `resolveVariables`；那个文件自己也写了「输出示例和真实落盘名字必须走
  ///     同一个函数，否则预览看着对、下出来的名字不一样」。下载侧换成另一套
  ///     清洗，用户看到的示例立刻开始说谎。
  ///  2. **整串清洗那套的规则是照抖音的参照物定的**（保留集 `- . @ ： _`、
  ///     连续下划线归并、200 上限）。B 站照抄会把 B 站的名字洗成谁都没参照的
  ///     样子 —— `bili_section.dart` 里已经写了这句话，这里执行它。
  ///  3. **`/` 会被整串清洗吃掉。** 它在文件夹模板里是层级分隔符
  ///     （`%UP_NAME%/%WORK_TITLE%`），抖音侧已经踩过这个坑；B 站的文件夹模板
  ///     同样走 [_joinTemplateDir]，一律不许整串清洗碰它。
  ///
  /// 落点是 [biliOutBase]：B 站的 base 名从这里出来，再补 `.video.m4s` /
  /// `.audio.m4s` / `.mp4` 三种后缀，所以模板里 `%EXT%` 那段必须剥掉
  /// （见 [biliBaseNameFromFileName]）。
  static String _renderFileName(
    String template,
    Media media, {
    required DouyinConfig? douyin,
    BiliConfig? bili,
  }) {
    if (template.trim().isEmpty) {
      return douyin == null
          ? media.safeFileName
          : douyinFilenamify(media.safeFileName);
    }
    if (bili != null) return resolveVariables(template, media).trim();
    return douyin == null
        ? resolveVariables(template, media).trim()
        : resolveDouyinFileName(template, media);
  }

  /// B 站那条分 P 的**不含扩展名**的 base 名（页面与 [enqueueBiliMedia] 都用它）。
  ///
  /// 为什么不直接复用 [resolveVariables]：B 站一个分 P 落的是三个名字
  /// （视频流 / 音频流 / 合并产物），base 只能算一次、三处共用；
  /// 而默认模板 `<P%P%->%PART_TITLE%-%QUALITY%-%CODEC%%EXT%` 自带 `%EXT%`，
  /// 不剥掉就会下出 `冬天-1080P.m4s.video.m4s` 这种名字。
  static String biliOutBase(String template, Media media, BiliConfig cfg) {
    final full = _renderFileName(template, media, douyin: null, bili: cfg);
    return biliBaseNameFromFileName(full);
  }

  /// 暂停一条任务。
  ///
  /// 失败一定要落进日志文件：这里原先只 `debugPrint`，而 debugPrint 不写
  /// `AppLogger` 的日志文件 —— 用户点「暂停」没反应时，除了重跑一遍
  /// 开发者版没有任何办法知道为什么（2026-09-24 报的「暂停后无法继续」）。
  /// **返回给用户看的原因**，`null` 表示成功。
  ///
  /// 以前失败只进日志：用户点「暂停」后界面照旧显示「下载中」、进度照走，
  /// 而他以为是自己没点到。`resume` 不需要这个 —— 它失败时会把任务标成
  /// 错误态，界面上看得见。
  Future<String?> pause(String localId) async {
    final gid = _store?.gidFor(localId);
    if (gid == null) {
      AppLogger.log('ARIA2', 'pause 跳过：$localId 还没有 gid（尚未入队或已被移除）');
      return '这条任务还没进入下载队列，暂时无法暂停';
    }
    try {
      await _aria.pause(gid);
      // **成功就立刻自己回写状态，不能只等事件。** aria2 对「还在排队（waiting）」
      // 的任务执行 pause 时只是把它从队列摘掉，**不发 onDownloadPause 也不发
      // onDownloadStop**。只等事件回写的后果（2026-10-06 真机）：765 条排队任务
      // 已经被 aria2 停住，界面却还全是「下载中 0%」，而工具栏的「全部继续」
      // 要本地存在 paused 才渲染 —— 用户既看不到「已暂停」，也没有任何按钮能把
      // 它们放回队列，整条队列看起来就是卡死了。
      _store?.markPaused(localId);
      AppLogger.log('ARIA2', 'pause 已发送 gid=$gid（$localId）');
      return null;
    } catch (e) {
      // 「GID#… cannot be paused now」多半不是失败：它已经不在可暂停的位置上了
      // （早就是 paused）。按 aria2 的真实状态收口，别把已经达成的目标报成失败 ——
      // 那会在界面上留下一堆红色「暂停失败」，而用户要的效果其实已经生效。
      final remote = await _remoteStatus(gid);
      if (remote == AriaStatus.paused) {
        _store?.markPaused(localId);
        AppLogger.log('ARIA2', 'pause 被拒但 aria2 侧已是 paused，按已暂停收口 '
            'gid=$gid（$localId）：$e');
        return null;
      }
      if (remote == AriaStatus.removed || remote == null) {
        // 引擎侧已经没有这条了：落到「错误」，界面才会给出可用的「重试」，
        // 而不是留一颗点了必然失败的「继续」。
        _store?.markErrorByGid(gid, '无法暂停：aria2 已不再认这条任务（$e）');
        AppLogger.log('ARIA2', 'pause 时 aria2 侧状态=${remote ?? '查不到'}，'
            '已按失败落到错误态 gid=$gid（$localId）：$e');
        return null;
      }
      AppLogger.log('ARIA2',
          'pause 失败 gid=$gid（$localId）：$e（aria2 侧仍为 ${remote.name}）');
      return '暂停失败：$e';
    }
  }

  /// 问一次 aria2 某条任务的真实状态；gid 已不被认识时返回 `null`。
  Future<AriaStatus?> _remoteStatus(String gid) async {
    try {
      return (await _aria.tellStatus(gid)).status;
    } catch (_) {
      return null;
    }
  }

  /// 继续一条已暂停的任务。
  ///
  /// aria2 的 `unpause` **只对 `paused` 状态有效**：任务若是被 `stop` 掉的
  /// （出错、重试、或重启后从 session 恢复成 stopped），`unpause` 会直接报错。
  /// 而 `DownloadStore.markPaused` 是 `onDownloadPause` 与 `onDownloadStop`
  /// **共用**的（见 `_onPause`），于是界面上显示「已暂停」、aria2 那边其实是
  /// 「已停止」—— 点继续就必然没反应。先把两边状态都记下来再定修法。
  Future<void> resume(String localId) async {
    final gid = _store?.gidFor(localId);
    if (gid == null) {
      AppLogger.log('ARIA2', 'resume 跳过：$localId 没有 gid');
      return;
    }
    final before = await _statusOf(gid);
    try {
      await _aria.unpause(gid);
      // 不等 onDownloadStart —— aria2 也可能把任务放回 waiting 而不重发 start，
      // 那样界面会一直卡在「已暂停」。
      _store?.markResumed(localId);
      AppLogger.log('ARIA2', 'resume 已发送 gid=$gid（$localId），'
          '发送前 aria2 侧状态=$before');
    } catch (e) {
      // 续不上就是续不上：把任务落到「错误」，界面才会给出可用的「重试」，
      // 而不是留着一颗点了没反应的「继续」。
      AppLogger.log('ARIA2', 'resume 失败 gid=$gid（$localId）：$e '
          '—— aria2 侧状态=$before，已按失败处理');
      _store?.markErrorByGid(gid, '无法继续：aria2 已不再认这条任务（$e）');
    }
  }

  /// 问 aria2 某条任务此刻的真实状态；查不到就回错误说明。
  Future<String> _statusOf(String gid) async {
    try {
      final t = await _aria.tellStatus(gid);
      return '${t.status.name}${t.error.isEmpty ? '' : ' error=${t.error}'}';
    } catch (e) {
      return '查不到（可能已被 aria2 移除）：$e';
    }
  }

  /// 移除一条任务。
  ///
  /// aria2 那边**真的**移除失败时不删本地行：以前两边都吞掉，行从界面上消失了，
  /// 而 aria2 还在往同一个文件写 —— 下次入队这条会被判「已存在跳过」，
  /// 用户既看不到任务也不知道文件为什么迟迟不出来。
  ///
  /// 但「aria2 明确说没有这条 GID」不属于这种失败：引擎侧已经没有它了，目标状态
  /// 本来就已达成。把它当失败会让那条死任务永远删不掉（再点 × 还是同一个错，
  /// 2026-10-02 用户真机就是这么报的）。
  Future<RemoveResult> remove(String localId) async {
    final gid = _store?.gidFor(localId);
    if (gid != null) {
      try {
        await _aria.remove(gid);
      } catch (e) {
        if (isUnknownGidFault(e)) {
          AppLogger.log('ARIA2', 'remove：aria2 已不认 gid=$gid（$localId），'
              '按「引擎侧已清理」处理：$e');
          _store?.remove(localId);
          return const (outcome: RemoveOutcome.alreadyGone, message: null);
        }
        AppLogger.log('ARIA2', 'remove 失败 gid=$gid（$localId）：$e');
        return (
          outcome: RemoveOutcome.failed,
          message: '没能从下载引擎里移除，任务先留在列表里：$e',
        );
      }
    }
    _store?.remove(localId);
    return const (outcome: RemoveOutcome.removed, message: null);
  }

  /// 手动重试一个已失败的任务 —— 「错误」Tab 里那颗重试按钮。
  ///
  /// 和自动重试的区别：**额度给满、候选地址从第一条重来**。自动重试是
  /// `decideRetry` 按剩余额度递进，走到 giveUp 时额度已经空了，不重置的话
  /// 手点一次会立刻失败回去，看起来像"按钮没反应"。
  ///
  /// 落盘路径沿用任务里**当初解析好的那份**（saveDir + fileName），不重套模板：
  /// 否则用户中途改过命名模板，一次重试会把文件写到另一个目录去。
  Future<RetryResult> retryTask(String localId) async {
    final store = _store;
    final t = store?.task(localId);
    if (store == null || t == null) {
      return (
        localId: null,
        outcome: EnqueueOutcome.notReady,
        message: null
      );
    }
    if (!_booted) {
      AppLogger.log('ARIA2', '手动重试被拒（aria2 未就绪）：${t.fileName}');
      return (
        localId: null,
        outcome: EnqueueOutcome.notReady,
        message: null
      );
    }
    AppLogger.log('ARIA2', '手动重试：${t.fileName}');
    // **先看磁盘，再决定要不要投**。用户真机报的现象：错误列表里那条其实文件
    // 已经下好了，点重试又下一个一模一样的，目录里落出一串 `xxx.1.jpg`。
    // 入队路径有 `sameFileSkip` 这道查（见 enqueueMedia），但重试路径以前没有 ——
    // 它直接 `_submit`，等于绕过了用户自己勾的那个开关。
    //
    // 只认「不是半成品」的情况：aria2 没下完时会留一个 `<文件名>.aria2` 控制文件，
    // 那种必须照常重下，不能当成已完成放过去。
    // `sameFileSkip` 关着就一切照旧 —— 那是用户明确要的"已存在也重下"。
    final dl = _settings?.settings.download;
    final fullPath = p.join(t.saveDir, t.fileName);
    if (dl != null && dl.sameFileSkip && await File(fullPath).exists() &&
        !await File('$fullPath.aria2').exists()) {
      final size = await File(fullPath).length();
      store.markCompleteByLocalId(localId, totalBytes: size);
      // 重试命中「磁盘上已经有了」也算一条流下完 —— B 站的配对要在这里也问一次，
      // 否则「视频流早就下完、只剩音频流失败」那种局面重下完音频也不会去合。
      unawaited(biliStreamFinished(localId));
      AppLogger.log('ARIA2',
          '手动重试跳过（文件已在磁盘上，不再下一次）：$fullPath（$size 字节）');
      return (
        localId: localId,
        outcome: EnqueueOutcome.skippedExisting,
        message: null,
      );
    }
    // 顺序是「先把旧任务从引擎里清掉，再投新的」。这里**不能忽略 remove 的结局**：
    // 移不掉时（RPC 不通、超时、其它 fault）本地行会留在「错误」里，此时照样
    // `_submit` 就变成同一个媒体两行 —— 用户看到的正是这个（2026-10-04 真机报的：
    // 点重试只是又推了一遍，旧错误行还在）。
    //
    // 也不能改成「移不掉就直接删本地表」：那种情况下 aria2 很可能还挂着同一个文件，
    // 界面上消失后它继续写，下次入队这条又被判「已存在跳过」—— 就是早前修掉的
    // 那条静默失败。所以宁可不动：留行 + 把原因回给界面。
    //
    // `RemoveOutcome.alreadyGone`（引擎明确回「没有这条 GID」）不受影响：目标状态
    // 早就达成，照常重试。
    final rm = await remove(localId);
    if (rm.outcome == RemoveOutcome.failed) {
      AppLogger.log('ARIA2',
          '手动重试中止（旧任务没能从引擎移除，不新建以免重复）：${t.fileName} —— ${rm.message}');
      return (
        localId: localId,
        outcome: EnqueueOutcome.removeFailed,
        message: '重试已取消 —— ${rm.message}',
      );
    }
    final r = await _submit(t.media, t.saveDir, t.fileName,
        retryRemains: kAriaRetryTimes,
        attempt: 0,
        // 限速跟着这一行走：手动重试不该把用户设过的限速悄悄放回全速。
        speedLimitKbps: t.speedLimitKbps);
    return (localId: r.localId, outcome: r.outcome, message: null);
  }

  /// 把代理下发给 aria2。**返回给用户看的原因**，`null` 表示一切正常。
  ///
  /// 以前返回 void：引擎没起来时是静默 no-op、`changeGlobalOption` 抛错也只进
  /// 日志，而设置页无论如何都弹「已保存」—— 用户以为代理生效了，实际没有。
  Future<String?> updateProxy(String proxyUrl) async {
    if (!_booted) return '下载引擎还没起来，代理设置暂时没生效';

    // 用户配了代理、但代理软件压根没在跑时，aria2 会把**每一个**任务都跑成
    // `Network problem has occurred. cause:No connection could be made because
    // the target machine actively refused it.` —— 用户看到的现象就是
    // 「下载全失败」，却无从知道根因是代理没启动（实测踩到）。
    // 这里探一次 TCP 连通性：连不上就本次直连，并把原因留给 UI 提示。
    var effective = proxyUrl;
    String? note;
    if (effective.isNotEmpty && !await isProxyReachable(effective)) {
      _proxyWarning = '代理 $effective 连不上，本次已临时改为直连';
      AppLogger.log('ARIA2', _proxyWarning!);
      note = _proxyWarning;
      effective = '';
    } else {
      _proxyWarning = null;
    }

    try {
      await _aria.updateProxy(effective);
      AppLogger.log(
        'ARIA2',
        'all-proxy = ${effective.isEmpty ? "(空 → 直连)" : effective}',
      );
      return note;
    } catch (e) {
      debugPrint('[Aria2Coordinator] updateProxy 失败: $e');
      AppLogger.log('ARIA2', 'updateProxy 失败：$e');
      return '代理设置没能下发到下载引擎：$e';
    }
  }

  /// 最近一次代理探测的异常说明；null 表示没有异常。
  ///
  /// UI（抖音页下载提示）会把它附在结果后面，让「下载失败」不再是黑盒。
  String? get proxyWarning => _proxyWarning;
  String? _proxyWarning;

  /// 设置 aria2 的最大同时下载数（参照实现的「并发数」）。
  ///
  /// 这是**全局**选项，X 的下载同样受益 —— 参照实现的 `limit` 也是全局的。
  /// 入队前调用即可（幂等，值没变也照样下发一次，代价只是一次 RPC）。
  Future<void> applyConcurrency(int value) async {
    if (!_booted) return;
    final n = value.clamp(1, 16);
    try {
      await _aria.updateConcurrency(n);
      AppLogger.log('ARIA2', 'max-concurrent-downloads = $n');
    } catch (e) {
      debugPrint('[Aria2Coordinator] applyConcurrency 失败: $e');
      AppLogger.log('ARIA2', 'applyConcurrency 失败：$e');
    }
  }

  /// 探测代理是否真的在监听（纯 TCP connect，不发言）。
  ///
  /// 只做「有没有人接」这一件事：能连上不代表代理一定可用，
  /// 但连不上就一定不可用 —— 足够用来避免把死代理填进 `all-proxy`。
  ///
  /// **端口必须显式写出来。** `Uri.port` 会替 http/https 补上默认端口
  /// （80 / 443），于是 `http://127.0.0.1` 会被当成 127.0.0.1:80 ——
  /// 本机但凡跑了个 web 服务，一个无端口的「代理地址」就会被判为可用。
  /// 代理地址不写端口本来就是无意义的，这里直接拒掉。
  static Future<bool> isProxyReachable(
    String proxyUrl, {
    Duration timeout = const Duration(milliseconds: 700),
  }) async {
    final uri = Uri.tryParse(proxyUrl);
    final host = uri?.host ?? '';
    final port = (uri?.hasPort ?? false) ? uri!.port : 0;
    if (host.isEmpty || port <= 0) return false;
    try {
      final s = await Socket.connect(host, port, timeout: timeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 千分比的进度（aria2 的精度），没有总长时是 0。
  static int _progressOf(AriaTask t) =>
      t.totalSize > 0 ? (t.completeSize * 1000 ~/ t.totalSize).clamp(0, 1000) : 0;

  /// 问一次 aria2 的等待队列，返回 gid → 排在它前面还有几条（0 = 下一个轮到它）。
  ///
  /// 失败返回空表：位次只是给界面看的补充信息，拿不到就只显示「队列中」，
  /// 不能因为这一次 RPC 把整轮进度轮询判失败。
  Future<Map<String, int>> _queuedPositions() async {
    try {
      final gids = await _aria.tellWaitingGids();
      return {for (var i = 0; i < gids.length; i++) gids[i]: i};
    } catch (e) {
      debugPrint('[Aria2Coordinator] tellWaiting: $e');
      return const {};
    }
  }

  /// 拉一次所有活跃任务的进度。
  Future<void> _pollActive() async {
    final store = _store;
    if (store == null || !_booted) return;
    final gids = store.activeGids();
    if (gids.isEmpty) return;
    try {
      final results = await _aria.tellStatusBatch(gids);
      // 「排队中」与「下载中」按引擎的**真实状态**分开写回（2026-10-16 修）：
      // 此前两者一起走 active 分支，界面只剩「下载中 0%」一种样子，用户看不出
      // 队列是在往前挪还是整个卡死。位次只在真有排队任务时才去问（队列空时白问）。
      final queued = results.values.any((t) => t.status == AriaStatus.waiting)
          ? await _queuedPositions()
          : const <String, int>{};
      results.forEach((gid, task) {
        store.updateProgress(gid, _progressOf(task), task.totalSize,
            downloaded: task.completeSize);
        // 实时速度走 aria2 的 `downloadSpeed`（字节/秒），**不在这里用两次
        // 进度采样现场估算**：估算值在切源重投、暂停恢复、连接刚建立时都会
        // 给出没有意义的数，而引擎本来就是逐帧算好这个值的。
        store.updateSpeed(gid, task.speedBytesPerSec);
        switch (task.status) {
          case AriaStatus.waiting:
            store.markWaiting(gid, aheadCount: queued[gid]);
          case AriaStatus.active:
            // 引擎已经开始下了 —— 把「排队中」翻回「下载中」。只认 paused 的
            // `markResumed` 管不到这一档，漏了它就永远停在「队列中」。
            final localId = store.localIdForGid(gid);
            if (localId != null) store.markDownloading(localId);
          case _:
            // 暂停 / 完成 / 失败由事件回写，这一轮不动它们。
            break;
        }
      });
    } catch (e) {
      // 单次失败忽略，下次再试
      debugPrint('[Aria2Coordinator] progress poll: $e');
    }
  }

  void _onStart(String gid) {
    // 启动事件本身就是「已被 aria2 接受」；首次入队时的 markActive 已在
    // enqueueMedia 里做了。但**从暂停里恢复**没有别的地方会翻状态，
    // 界面会一直停在「已暂停」——「从队列里被取出来开始下」也是同一回事，
    // 所以这里按 gid 纠正一次（两种来源都由 `markDownloading` 收口）。
    final localId = _store?.localIdForGid(gid);
    if (localId != null) _store?.markDownloading(localId);
    AppLogger.log('ARIA2', '开始下载 gid=$gid');
  }

  void _onPause(String gid) {
    final localId = _store?.localIdForGid(gid);
    if (localId == null) return;
    _store?.markPaused(localId);
  }

  void _onComplete(String gid) {
    unawaited(_onCompleteAsync(gid));
  }

  /// 下载完成 —— **先验一次「文件不是 0 字节」再算成功**。
  ///
  /// 为什么需要：抖音的部分 CDN 节点会**正常回 200/206 但正文为空**
  /// （签名过期时尤其常见），aria2 认为任务成功、UI 显示「已完成」，
  /// 用户拿到的是一个 0 字节的坏文件 —— 比明确报错还难排查。
  /// 参照实现因为是在页面里 `fetch()` 后自己读响应体，天然能发现空响应；
  /// aria2 只管字节流，必须在这里补一道。
  Future<void> _onCompleteAsync(String gid) async {
    final store = _store;
    final localId = store?.localIdForGid(gid);
    if (store == null || localId == null) return;
    final t = store.taskByGid(gid);
    if (t == null) return;

    int size = -1;
    try {
      size = await File(t.fullPath).length();
    } catch (_) {
      // 读不到就当没检查 —— 不能让「文件系统抖动」把成功的下载判成失败
    }

    if (size == 0) {
      AppLogger.log('ARIA2', '下载完成但文件是 0 字节，按失败处理：${t.fileName}');
      // 空响应重试同一个地址基本没用 → 只换源，不原地重试
      await _handleFailure(gid, '服务器返回空内容（0 字节）', forcePermanent: true);
      return;
    }

    AppLogger.log('ARIA2', '下载完成 gid=$gid${size > 0 ? '（$size 字节）' : ''}');
    store.markComplete(gid);
    // B 站的一条分 P 要**两条流都到位**才谈得上合并，这里问一次。
    // 不 await：完成事件是串行处理的，合并却要起 ffmpeg 子进程（快则几百毫秒、
    // 慢则几秒），把它挂在事件回调上会把后面所有任务的完成处理一起堵住。
    unawaited(biliStreamFinished(localId));
  }

  void _onError(String gid) {
    unawaited(_onErrorAsync(gid));
  }

  Future<void> _onErrorAsync(String gid) async {
    // aria2 的 error 事件不带错误描述，需要 tellStatus 一次拿 message
    String msg;
    try {
      final task = await _aria.tellStatus(gid);
      msg = task.error.isEmpty ? '未知错误' : task.error;
    } catch (e) {
      msg = 'aria2 错误: $e';
    }
    AppLogger.log('ARIA2', '下载失败 gid=$gid：$msg');
    await _handleFailure(gid, msg);
  }

  /// 失败处理 —— **先换源、换完再原地重试、都不行才标记失败**
  /// （对齐参照实现「正在尝试同源其它下载地址」→「所有下载地址都不可用」）。
  ///
  /// 原版是「remove 掉旧任务 → 重新 prepareDownloadTask → 再 addUri」，
  /// 并把 `ariaRetryCountRemains - 1` 带进新任务；这里多了一层换源。
  /// [forcePermanent] 用于「换源还有意义、原地重试没意义」的失败
  /// （0 字节空响应就是这类）—— 它只挡掉 [RetryAction.retrySame]。
  ///
  /// **两次改动：**
  ///   - 重新提交前先按 [backoffFor] 指数退避，并且换源 + 原地重试**合用**
  ///     [kMaxAutoResubmits] 这一份额度 —— 以前是零等待，一条死任务在几十毫秒内
  ///     就能把额度烧光，开机时几十条一起烧就是日志刷屏与网络风暴。
  ///   - 本地任务表里查不到的 gid **不再放着不管**：它是上次会话
  ///     `--save-session` 里带回来的死任务，用户界面已经没有入口能删它，
  ///     于是每次开机都重跑一遍再失败一次（实测同一批任务在 2026-10-02 的
  ///     四次开机里各失败一次）。这里摘掉它，让它从会话文件里消失。
  ///
  /// 两者都**不改**「失败必须让用户看得见」：走到上限就是 `markErrorByGid`
  /// （任务落在「错误」Tab，带原始错误说明），而不是静默丢弃或报成功。
  Future<void> _handleFailure(
    String gid,
    String msg, {
    bool forcePermanent = false,
  }) async {
    final store = _store;
    if (store == null) return;
    // aria2 的引擎级重试会对同一个 gid 连发多个 error 事件。退避把等待时间
    // 拉长了，不挡住的话每个事件都会排一次「重新提交」—— 越退避越放大。
    if (!_retryScheduled.add(gid)) return;
    try {
      final t = store.taskByGid(gid);
      if (t == null) {
        await _dropOrphanGid(gid, msg);
        return;
      }

      final candidates = t.media.downloadCandidates;
      final action = decideRetry(
        attempt: t.attempt,
        candidateCount: candidates.length,
        retryRemains: t.retryRemains,
        permanent: forcePermanent || isPermanentDownloadError(msg),
      );
      final used = autoResubmitsUsed(t);

      switch (action) {
        case RetryAction.switchSource:
          await _resubmitAfterBackoff(
            t,
            gid,
            attempt: t.attempt + 1,
            retryRemains: t.retryRemains,
            used: used,
            label: '换源重试（第 ${t.attempt + 2}/${candidates.length} 条地址）',
            msg: msg,
          );

        case RetryAction.retrySame:
          await _resubmitAfterBackoff(
            t,
            gid,
            attempt: t.attempt,
            retryRemains: t.retryRemains - 1,
            used: used,
            label: '原地重试（剩余 ${t.retryRemains - 1} 次）',
            msg: msg,
          );

        case RetryAction.giveUp:
          if (used >= kMaxAutoResubmits) {
            AppLogger.log(
              'ARIA2',
              '自动重试到上限（已重新提交 $used 次），标记失败：'
                  '${t.fileName}（$msg）',
            );
          } else {
            AppLogger.log(
              'ARIA2',
              '放弃重试，标记失败：${t.fileName}'
                  '（已试 ${t.attempt + 1}/${candidates.length} 条地址；$msg）',
            );
          }
          store.markErrorByGid(gid, msg);
      }
    } finally {
      _retryScheduled.remove(gid);
    }
  }

  /// 退避之后再重新提交一次（换源 / 原地重试共用）。
  ///
  /// 等待期间任务可能被用户移除或应用正在退出，所以醒来后**先验一次 gid 还在**
  /// 再动手 —— 否则会把用户刚删掉的死任务又投回 aria2。
  Future<void> _resubmitAfterBackoff(
    DownloadTask t,
    String gid, {
    required int attempt,
    required int retryRemains,
    required int used,
    required String label,
    required String msg,
  }) async {
    final store = _store;
    if (store == null) return;
    if (used >= kMaxAutoResubmits) {
      AppLogger.log(
        'ARIA2',
        '自动重试到上限（已重新提交 $used 次），标记失败：${t.fileName}（$msg）',
      );
      store.markErrorByGid(gid, msg);
      return;
    }
    final delay = backoffFor(used);
    AppLogger.log(
      'ARIA2',
      '$label：${t.fileName} ← $msg'
          '（第 ${used + 1}/$kMaxAutoResubmits 次，等待 ${delay.inMilliseconds}ms）',
    );
    await Future<void>.delayed(delay);
    if (_closed || store.taskByGid(gid) == null) {
      AppLogger.log('ARIA2', '退避等待期间任务已不在，取消重新提交：${t.fileName}');
      return;
    }
    // 先把旧 gid 从引擎里清掉。这里**不能**再写成 `catch (_) {}`：重投的场景
    // 就是「这条任务刚失败」，它此刻多半已经停下，而 `aria2.remove` 对已停下的
    // gid 必然回 `Active Download not found`（真机原文，2026-10-16）。异常被吞
    // 掉 → 失败无日志、无补救 → 旧 gid 留在 aria2 会话里，是「33 个文件放大成
    // 261 个任务」的放大器。现在按 ① 同一套语义分两手：remove → 失败记日志 →
    // forceRemove → 仍不行再清一次结果条目。
    final removeError = await _tryRemove(gid);
    if (removeError != null) {
      AppLogger.log('ARIA2', '重投前移除旧任务失败 gid=$gid（${t.fileName}）：'
          '$removeError —— 旧 gid 若留在引擎里会重复下载，继续兜底清理');
      final forceError = await _tryForceRemove(gid);
      if (forceError != null) {
        AppLogger.log('ARIA2', 'forceRemove 旧任务也失败 gid=$gid：$forceError');
      }
      final resultError = await _tryRemoveDownloadResult(gid);
      if (resultError != null) {
        AppLogger.log('ARIA2', '清理旧任务结果条目也失败 gid=$gid：$resultError');
      }
    }
    store.remove(t.localId);
    await _submit(t.media, t.saveDir, t.fileName,
        retryRemains: retryRemains,
        attempt: attempt,
        // 换源重投是同一条任务的继续，不是新任务 —— 限速必须原样带上。
        speedLimitKbps: t.speedLimitKbps);
  }

  /// 把「本地任务表里已经没有、却仍在 aria2 会话里」的死任务摘掉。
  ///
  /// 不摘的话它会永远留在 `aria2.session` 里：每次 `--input-file` 读回 →
  /// 立刻失败 → 再被 `--save-session` 写回去。界面上看不到它（本地行早没了），
  /// 用户没有任何办法处置它。
  ///
  /// **必须按状态分两手摘**（2026-10-16 修）。死任务此刻多半已经停下
  /// （`error` / `complete` / `removed`），而 `aria2.remove` **只作用于还在
  /// 队列里**的 gid，对它一律回 `Active Download not found for GID#…` ——
  /// 旧实现因此是「检测到了、永远摘不掉」，同一个 gid 在日志里被反复刷
  /// （真机 05:33:17 / 05:33:37 / 05:33:57 三次）。
  /// 已停下的任务只能靠 `aria2.removeDownloadResult` 清掉结果条目；
  /// 反过来它也只认已停下的 gid，对还在排队的那批无效（回
  /// `Could not remove download result`）。所以**先 remove、失败再
  /// removeDownloadResult**，两条都失败才记一行日志。
  Future<void> _dropOrphanGid(String gid, String msg) async {
    AppLogger.log('ARIA2', '本地任务表里没有 gid=$gid，按死任务从 aria2 摘掉'
        '（不留在会话里等下次开机重跑）：$msg');
    final firstError = await _tryRemove(gid);
    if (firstError == null) return;
    // 走到这里说明它已经不在队列里了（stopped）—— 摘结果条目的那一手才对得上。
    final secondError = await _tryRemoveDownloadResult(gid);
    if (secondError == null) return;
    AppLogger.log('ARIA2', '死任务 gid=$gid 没能摘掉：'
        'remove=$firstError；removeDownloadResult=$secondError');
  }

  /// 摘僵尸第一手：`aria2.remove`（只对**还在队列里**的 gid 有效）。
  /// 成功返回 null，失败把异常原样交回给调用方决定下一步。
  Future<Object?> _tryRemove(String gid) async {
    try {
      await _aria.remove(gid);
      return null;
    } catch (e) {
      return e;
    }
  }

  /// 摘僵尸第二手：`aria2.removeDownloadResult`（只对**已停下**的 gid 有效）。
  Future<Object?> _tryRemoveDownloadResult(String gid) async {
    try {
      await _aria.removeDownloadResult(gid);
      return null;
    } catch (e) {
      return e;
    }
  }

  /// 兜底：`aria2.forceRemove`（不等优雅收尾；仍只对**队列里**的 gid 有效）。
  Future<Object?> _tryForceRemove(String gid) async {
    try {
      await _aria.forceRemove(gid);
      return null;
    } catch (e) {
      return e;
    }
  }

  /// 退出清理：注销事件订阅并停掉 aria2c。返回「确认子进程已经不在」。
  Future<bool> dispose() async {
    _closed = true;
    _startSub?.cancel();
    _pauseSub?.cancel();
    _stopSub?.cancel();
    _completeSub?.cancel();
    _errorSub?.cancel();
    _progressPoll?.cancel();
    return _aria.dispose();
  }
}