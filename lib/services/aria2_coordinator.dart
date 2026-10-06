import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/douyin_config.dart';
import '../models/media.dart';
import 'app_logger.dart';
import 'aria2.dart';
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
  @visibleForTesting
  Aria2Coordinator.withAria2(Aria2 aria) : _aria = aria;

  final Aria2 _aria;

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

  /// 每次**真正**把一条媒体投给 aria2 并被接受后回调一次（`localId` 是任务表里的 id）。
  ///
  /// 为什么需要：首次入队之外的另一个调用点是**失败重试**（`_handleFailure`），
  /// 那里会 `store.remove()` 掉旧任务、用**新的 localId** 重新提交。抖音台账记的是
  /// 任务 id，不续上这个新 id，那条作品就永远查不到自己的结局 —— 既不算已下载、
  /// 也不会被撤销。由 `main()` 接线到 `DouyinLedger.attachTask`。
  void Function(Media media, String localId)? onTaskSubmitted;

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

    // 并发数（参照实现的 `limit`，默认 4）是全局选项，启动时先落一次，
    // 免得用户上次改过的值在重启后失效。
    await applyConcurrency(settings.settings.douyin.concurrency);
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
        case AriaStatus.waiting:
          final progress = remote.totalSize > 0
              ? (remote.completeSize * 1000 ~/ remote.totalSize)
              : 0;
          store.updateProgress(gid, progress.clamp(0, 1000), remote.totalSize,
              downloaded: remote.completeSize);
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
    final out = customOut ?? _renderFileName(nameTpl, media, douyin: douyin);

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
    );

    try {
      final gid = await _aria.addUri(
        url,
        dir: saveDir,
        out: out,
        options: _requestOptions(media),
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
  Map<String, String>? _requestOptions(Media media) {
    if (media.source != 'douyin') return null;
    return const {'referer': kDouyinReferer, 'user-agent': kBrowserUserAgent};
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
    fallback: _defaultDownloadDir(),
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
  static String _renderFileName(
    String template,
    Media media, {
    required DouyinConfig? douyin,
  }) {
    if (template.trim().isEmpty) {
      return douyin == null
          ? media.safeFileName
          : douyinFilenamify(media.safeFileName);
    }
    return douyin == null
        ? resolveVariables(template, media).trim()
        : resolveDouyinFileName(template, media);
  }

  static String? _cached;
  String _defaultDownloadDir() {
    if (_cached != null) return _cached!;
    String path;
    try {
      // path_provider 在 Windows 上返回 Roaming AppData；下载目录更友好
      // 用 Platform.environment 拿 USERPROFILE/Pictures 或 Downloads
      final home = Platform.environment['USERPROFILE'] ?? '.';
      // 优先选 Downloads；不存在就让 aria2 自己创建
      final dl = Directory('$home\\Downloads\\解析下载器');
      path = dl.path;
    } catch (_) {
      path = '.';
    }
    _cached = path;
    return path;
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
        retryRemains: kAriaRetryTimes, attempt: 0);
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

  /// 拉一次所有活跃任务的进度。
  Future<void> _pollActive() async {
    final store = _store;
    if (store == null || !_booted) return;
    final gids = store.activeGids();
    if (gids.isEmpty) return;
    try {
      final results = await _aria.tellStatusBatch(gids);
      results.forEach((gid, task) {
        final progress = task.totalSize > 0
            ? (task.completeSize * 1000 ~/ task.totalSize)
            : 0;
        store.updateProgress(gid, progress.clamp(0, 1000), task.totalSize,
            downloaded: task.completeSize);
      });
    } catch (e) {
      // 单次失败忽略，下次再试
      debugPrint('[Aria2Coordinator] progress poll: $e');
    }
  }

  void _onStart(String gid) {
    // 启动事件本身就是「已被 aria2 接受」；首次入队时的 markActive 已在
    // enqueueMedia 里做了。但**从暂停里恢复**没有别的地方会翻状态，
    // 界面会一直停在「已暂停」，所以这里按 gid 纠正一次。
    final localId = _store?.localIdForGid(gid);
    if (localId != null) _store?.markResumed(localId);
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
    try {
      await _aria.remove(gid);
    } catch (_) {}
    store.remove(t.localId);
    await _submit(t.media, t.saveDir, t.fileName,
        retryRemains: retryRemains, attempt: attempt);
  }

  /// 把「本地任务表里已经没有、却仍在 aria2 会话里」的死任务摘掉。
  ///
  /// 不摘的话它会永远留在 `aria2.session` 里：每次 `--input-file` 读回 →
  /// 立刻失败 → 再被 `--save-session` 写回去。界面上看不到它（本地行早没了），
  /// 用户没有任何办法处置它。
  Future<void> _dropOrphanGid(String gid, String msg) async {
    AppLogger.log('ARIA2', '本地任务表里没有 gid=$gid，按死任务从 aria2 摘掉'
        '（不留在会话里等下次开机重跑）：$msg');
    try {
      await _aria.remove(gid);
    } catch (e) {
      // 摘不掉就留着下次，但不能假装成功 —— 留下一行原因。
      AppLogger.log('ARIA2', '死任务 gid=$gid 没能摘掉：$e');
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