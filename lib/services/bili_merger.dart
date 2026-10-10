/// B 站 DASH 分开的视频流 / 音频流合并（ffmpeg 封装层）。
///
/// **为什么需要这一层：** B 站 `playurl` 返回的是 DASH —— 视频与音频是两条
/// 独立的 `.m4s`，各自都**不是能单独播放的完整文件**。本项目的下载全靠随包
/// `aria2c`，它只按字节存文件、不懂容器，所以「下完两个文件」离「拿到一个能播的
/// mp4」还差一次容器级合并。这一层就是补那一步，也是全项目唯一调用 ffmpeg 的地方。
///
/// 做法对齐 [Aria2] 里那套随包外部二进制的规矩（见 `aria2.dart` 的
/// `_ensureSidecar` / `_startOnce`）：路径可注入、`Process.start` 起子进程、
/// stderr 收全并带进结果、退出码不当唯一判据。
///
/// **本期 ffmpeg 还不在 `assets/` 里**（随包是出包阶段的事），所以
/// [ffmpegPath] 传 null 时走 [defaultFfmpegPath]（exe 同级 `ffmpeg\ffmpeg.exe`），
/// 开发期可以把构造参数直接指到本机任何一份 ffmpeg。找不到时报可读失败，
/// 不返回 null、也不抛。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';

/// 日志 tag（与 `ARIA2` / `DOWNLOAD` 同一层叫法）。
const String kBiliMergeLogTag = 'FFMPEG';

/// 随包 ffmpeg 摆放的目录名（exe 同级）。
const String kFfmpegDirName = 'ffmpeg';

/// ffmpeg 可执行文件名。本应用只做 Windows 桌面，所以写死 `.exe`；
/// 但**目录分隔符一律走 [p.join]**，不把 `\` 写进代码。
const String kFfmpegExeName = 'ffmpeg.exe';

/// mp4 的 moov 前置标志。
///
/// 带 `+faststart` 时 ffmpeg 在收尾阶段把 moov box 改写到文件头，播放器不必
/// 先读完整个文件才能起播（合并完实测：moov 落在偏移 36，mdat 在 6910）。
const String kFfmpegMovflags = '+faststart';

/// 结果里最多带多少字符的 stderr（保留**尾部**）。
///
/// 刻意不截到「一眼看不完就砍」：ffmpeg 的根因总在最后几行（`Invalid data found
/// when processing input`、`Codec ... not recognized`），砍头部会连错误名都砍掉。
/// 全量原文同时进日志文件（见 [BiliMergeResult.stderr] 的写入处）。
const int kBiliMergeStderrKeepChars = 4000;

/// ffmpeg 没显式指定路径时的默认位置：**exe 同级的 `ffmpeg\ffmpeg.exe`**。
///
/// 出包阶段把 ffmpeg 放进安装目录的这个子目录里，运行时代码不用改。
/// 用 [Platform.resolvedExecutable] 而不是当前工作目录 —— 桌面应用的工作目录
/// 可能是快捷方式指的任何地方。
String defaultFfmpegPath() => p.join(
  p.dirname(Platform.resolvedExecutable),
  kFfmpegDirName,
  kFfmpegExeName,
);

/// 失败的哪一种。三种「没成功」的形状必须分开：界面要给出不同的下一步
/// （装 ffmpeg / 重试 / 换原始流），光一句「合并失败」等于没说。
enum BiliMergeFailure {
  /// 找不到 ffmpeg 可执行文件 —— 用户侧是「装包里没带 / 路径填错了」。
  ffmpegMissing,

  /// 子进程压根没起来，或起不来之后 IO 出异常 —— 拿不到可信的退出码。
  processError,

  /// ffmpeg 明确回了非 0 退出码（参数不对、流不认、目标被占用）。
  exitNonZero,

  /// 退出码是 0，但**没读到 `progress=end`** 就被结束了。
  ///
  /// 这种是「进程提前死了」的形状：被强杀、崩溃、或被外部工具掐断。它和
  /// [exitNonZero] 必须分开 —— 非 0 说明 ffmpeg 知道自己失败了，
  /// 而 0 + 没跑完说明它连收尾都没走到，产物几乎一定是废的。
  noEndProgress,

  /// `progress=end` 读到了、退出码也是 0，但产物不存在或是 0 字节。
  ///
  /// 单看退出码会判成功。`aria2_coordinator` 里「aria2 回 200 但正文 0 字节」
  /// 是同一个坑：外部进程说好成功了，还得自己验一次货。
  badProduct,
}

/// ffmpeg `-progress pipe:1` 输出里**一行**解析出来的进度点。
@immutable
class BiliProgressPoint {
  const BiliProgressPoint({this.outTimeUs, this.totalSize, this.ended = false});

  /// 已写出的媒体时长，**微秒**。取 `out_time_us` 或 `out_time_ms`，见
  /// [parseFfmpegProgressLine] 里那条单位陷阱。
  final int? outTimeUs;

  /// 已写出的字节数（`total_size`）。
  final int? totalSize;

  /// `progress=end` —— ffmpeg 说「我走到收尾了」。
  final bool ended;
}

/// 纯函数：把 ffmpeg `-progress` 的一行 `key=value` 解析成进度点。
///
/// 只认 `out_time_us` / `out_time_ms` / `total_size` / `progress` 四个 key，
/// 其余（空行、`frame=`、`speed=1.32e+03x`、`out_time=00:00:05.106939` 这种
/// 不是整数的）一律返回 null。**值为 `N/A` 时不当成 0**，直接当没有。
///
/// **`out_time_ms` 这个名字是误导的，它的值实际是微秒。** 参照实现踩过这个坑，
/// 本次用真 ffmpeg 9.0.1 复验过：5.106939 秒的素材，`out_time_us` 与
/// `out_time_ms` 打出来**都是** `5106939`。按字面把 `out_time_ms` 当毫秒用，
/// 时长与进度会凭空再放大 1000 倍。所以这里两个 key 都按微秒读，
/// 并且不区分优先级 —— 真到二者不同时以逐行到达的顺序为准，两者本就同值。
BiliProgressPoint? parseFfmpegProgressLine(String line) {
  final s = line.trim();
  final i = s.indexOf('=');
  if (s.isEmpty || i <= 0) return null;
  final key = s.substring(0, i);
  final value = s.substring(i + 1).trim();
  if (key == 'progress') return BiliProgressPoint(ended: value == 'end');
  if (key != 'total_size' && key != 'out_time_us' && key != 'out_time_ms') {
    return null;
  }
  final n = int.tryParse(value);
  if (n == null) return null; // `N/A` 之类
  if (key == 'total_size') return BiliProgressPoint(totalSize: n);
  return BiliProgressPoint(outTimeUs: n);
}

/// 把 argv 拼成**可直接粘回 cmd 重跑**的一行（失败时带进结果做取证用）。
///
/// 只在含空格的参数外面加一对引号：**不做内部引号翻倍** —— Windows 的路径里
/// 本来就不允许出现 `"`，那是永远走不到的死分支。这条串是给人看、给人复制的，
/// 不再被 shell 解一层。生产路径没有前缀，拼出来就是
/// 「ffmpeg.exe -hide_banner … out.mp4」这一条。
String formatFfmpegCommand(List<String> argv) =>
    argv.map(_quoteArg).join(' ');

String _quoteArg(String a) => a.contains(' ') ? '"$a"' : a;

/// 一次合并的结果。
///
/// **刻意不抛异常**：失败以 [ok] = false + [failure] + [message] 的形状返回，
/// 因为「ffmpeg 没装」这类失败是可预期的日常状态（安全软件把随包二进制拦掉的
/// 概率不低），调用方要的是提示文案而不是崩。
@immutable
class BiliMergeResult {
  const BiliMergeResult({
    required this.ok,
    required this.commandLine,
    this.failure,
    this.message = '',
    this.stderr = '',
    this.mediaDuration = Duration.zero,
  });

  /// 合并成功（并且**产物已验过货**）。只有 true 时原始流才被删掉。
  final bool ok;

  /// 失败种类；[ok] 为 true 时是 null。
  final BiliMergeFailure? failure;

  /// 给用户看的一句话。失败时是原因，成功时通常为空（只有清理附注）。
  ///
  /// **刻意不提供「message + stderr」拼好的现成串**：怎么排（换行还是同行、
  /// 中英之间隔什么）是界面说了算的事，本层不知道它要落进 Toast 还是弹窗，
  /// 更不该没有条件地写死一个 `\n`。两个字段各给各的，排版交给调用方。
  final String message;

  /// 本次真实执行的完整命令行（含参数前缀）。失败时靠它复现取证。
  final String commandLine;

  /// 子进程 stderr 的尾部（至多 [kBiliMergeStderrKeepChars] 字符）。
  /// 空串表示子进程没写 stderr。
  final String stderr;

  /// ffmpeg 报回来的产出媒体时长（`out_time_*`，微秒精度）。
  /// 没读到就是 [Duration.zero]。
  final Duration mediaDuration;
}

/// B 站 DASH 合并器。
///
/// 用法（下载链路里）：
/// ```dart
/// final r = await BiliMerger().merge(
///   videoPath: v, audioPath: a, outPath: mp4, onProgress: (p) => ...);
/// if (!r.ok) { /* 显示 r.displayMessage，两条 .m4s 仍在原地 */ }
/// ```
class BiliMerger {
  /// [ffmpegPath] 为 null 时用 [defaultFfmpegPath]（exe 同级 `ffmpeg\`）。
  ///
  /// [commandPrefix] 生产为空；单测传 `['cmd.exe', '/c']` 指到一个假批处理上
  /// （本应用只跑 Windows，前缀是给测试留的唯一缝隙，见 [merge]）。
  ///
  /// 字段刻意不叫 `_ffmpegPath`：命名参数 `ffmpegPath` 与同名私有字段直接赋值会
  /// 同时触发 `prefer_initializing_formals` 与 `unnecessary_this`，而
  /// `this._ffmpegPath` 这种初始化形式在 Dart 里又是非法的（命名参数不能对应私有
  /// 字段）。换个字段名把两条 lint 一起绕开，参数名保持任务指定的 `ffmpegPath`。
  BiliMerger({String? ffmpegPath, this.commandPrefix = const []})
      : _pathOverride = ffmpegPath;

  final String? _pathOverride;

  /// 加在 ffmpeg 可执行文件**之前**的 argv（只用于测试）。
  final List<String> commandPrefix;

  /// 本次实际使用的 ffmpeg 路径（注入值或默认值，**不做存在性判断**）。
  String get ffmpegPath => _pathOverride ?? defaultFfmpegPath();

  /// ffmpeg 在不在。**只查文件存在，不跑一次 `-version`** ——
  /// 给设置页当「ffmpeg 没找到，合并会失败」的提示用，代价是一次磁盘 stat，
  /// 不联网也不下载。注意它不等于「能跑」：被安全软件拦下时这里仍返回 true，
  /// 真判据是 [merge] 的返回值。
  Future<bool> get available => File(ffmpegPath).exists();

  // ── 全局并发闸门 ──────────────────────────────────────────
  //
  // **同一时刻只允许 1 个 ffmpeg 进程**，第二个请求排队而不是报错。
  // 理由与参照实现一致：合并是 CPU + IO 双密集，而本项目的下载目标常常在
  // 机械盘上；aria2 那边已经按并发数（默认 4）在写盘了，再让多个 ffmpeg 同时
  // 读写同一块盘会互相抢头程，总数不会变快，只会把两条都拖成「看起来卡住」。
  //
  // 做法与 `aria2_coordinator` 里的「同一个 gid 不能并发重提」（`_retryScheduled`）
  // 同一个味道：一个静态 Future 链 + 两个计数，不引第三方信号量库。
  // Dart 单 isolate，计数只在事件循环里改，不需要锁。
  static Future<void> _gate = Future<void>.value();
  static int _running = 0;
  static int _waiting = 0;

  /// 闸门状态：正在跑 ffmpeg 的合并数（单测观察用）。
  @visibleForTesting
  static int get runningCountForTest => _running;

  /// 闸门状态：已经排队、还没拿到进程的合并数（单测观察用）。
  @visibleForTesting
  static int get waitingCountForTest => _waiting;

  static Future<T> _withGate<T>(Future<T> Function() body) async {
    final prev = _gate;
    final done = Completer<void>();
    // 闸门只认「上一段结束了」，不认它成功还是失败：一次合并抛错也不能把
    // 后面的合并永久卡死（`done` 在 finally 里无条件 complete）。
    _gate = done.future;
    _waiting++;
    try {
      await prev;
    } finally {
      _waiting--;
    }
    _running++;
    try {
      return await body();
    } finally {
      _running--;
      if (!done.isCompleted) done.complete();
    }
  }

  /// 合并用的固定参数（参照实现那套）。
  ///
  /// - `-loglevel error`：进度走 `-progress pipe:1`（stdout），stderr 只留错误，
  ///   两者不会混在一条流里互相咬。
  /// - `-y`：目标是「视频流 + 音频流 → 成品」，重跑覆盖同名产物是期望行为；
  ///   不覆盖的话 ffmpeg 会问一句 stdin 然后卡死。
  /// - `-map 0:v:0 -map 1:a:0`：只取第一个输入的视频轨、第二个输入的音频轨。
  ///   **必须显式 map**：B 站的视频流里有时还带一条字幕/元数据轨，不 map 会
  ///   把两条输入的所有流都塞进产物。
  /// - `-c copy`：不重编码。这也是随包那份裁剪版 ffmpeg 能干活的前提 ——
  ///   它的 `--enable-encoder` 白名单里**没有** x264 / aac，只有
  ///   `mjpeg/png/flac/libmp3lame/ass`；而 `-c copy` 只用到 demuxer(mov/mp4)
  ///   与 muxer(mp4)，两样都在。
  /// - `-movflags +faststart`：见 [kFfmpegMovflags]。
  List<String> mergeArgs(
    String videoPath,
    String audioPath,
    String outPath,
  ) =>
      [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        videoPath,
        '-i',
        audioPath,
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-c',
        'copy',
        '-movflags',
        kFfmpegMovflags,
        '-progress',
        'pipe:1',
        outPath,
      ];

  /// 完整 argv（前缀在最前）。
  List<String> buildCommand(
    String videoPath,
    String audioPath,
    String outPath,
  ) =>
      [
        ...commandPrefix,
        ffmpegPath,
        ...mergeArgs(videoPath, audioPath, outPath),
      ];

  /// 把 [videoPath] + [audioPath] 合并成 [outPath]（单个 mp4）。
  ///
  /// **成功判据是三件事同时成立**：读到 `progress=end` **且** 退出码 0 **且**
  /// 产物存在且非 0 字节。只看退出码不够 —— 见 [BiliMergeFailure.badProduct]
  /// 与 [BiliMergeFailure.noEndProgress]，两种形状各有真实来源。
  ///
  /// 成功才删两条原始流；**失败时原始流一律保留**（用户还能拿裸流自己处理，
  /// 这正是 `BiliConfig.mergeAfterDownload` 那个开关存在的理由）。失败时结果里
  /// 带可复现的命令行与 stderr 摘要，同时全部写进日志文件 ——
  /// 「失败只进 debugPrint 就等于无法复现取证」是本项目的一条纪律。
  ///
  /// [onProgress] 收到 0.0~1.0 且**单调不减**。分母用的是「两条输入流的字节数」
  /// 而不是总时长：本方法的签名里没有时长，而 `-c copy` 下产物字节数几乎等于
  /// 输入字节数之和，用 `total_size` 算比例既准又不用多起一次进程去探测时长。
  /// `out_time_*` 仍然解析（见 [parseFfmpegProgressLine] 的微秒陷阱），
  /// 但它进的是 [BiliMergeResult.mediaDuration] 与日志，不参与比例。
  Future<BiliMergeResult> merge({
    required String videoPath,
    required String audioPath,
    required String outPath,
    void Function(double p)? onProgress,
  }) =>
      _withGate(
        () => _mergeOnce(
          videoPath: videoPath,
          audioPath: audioPath,
          outPath: outPath,
          onProgress: onProgress,
        ),
      );

  Future<BiliMergeResult> _mergeOnce({
    required String videoPath,
    required String audioPath,
    required String outPath,
    void Function(double p)? onProgress,
  }) async {
    final argv = buildCommand(videoPath, audioPath, outPath);
    final commandLine = formatFfmpegCommand(argv);

    // ① 先确认二进制在不在。少了这一步，Process.start 只会给一句
    //   「CreateProcess ... 系统找不到指定的文件」，用户看不出是路径问题。
    if (!await File(ffmpegPath).exists()) {
      return _failure(
        BiliMergeFailure.ffmpegMissing,
        '没找到 ffmpeg（$ffmpegPath）。B 站下的是 DASH 分开的两条流，'
        '视频流和音频流各自都不能单独播放，必须先合并成 mp4。',
        commandLine,
        '',
      );
    }

    // 两条输入流的字节数：既是进度分母，也是日志里那句「输入多大」。
    // 读不到算 -1，交给后面的判据去区分（不存在 / 打不开都拦不住 ffmpeg 自己报错）。
    final inBytes = await _size(videoPath) + await _size(audioPath);
    AppLogger.log(
      kBiliMergeLogTag,
      '开始合并 → $outPath（输入 $inBytes 字节）',
    );

    // ② 起进程。**不设 workingDirectory**：三条路径都按调用方给的原文交给
    //   ffmpeg，改工作目录会让相对路径指向别处（`aria2.dart` 那边设它是因为
    //   aria2 要按相对路径读写自己的会话文件）。
    //   生产路径 argv.first 就是 ffmpeg.exe；测试路径 argv.first 是 cmd.exe，
    //   由 `/c` 去起那份假批处理（`Process.start` 直接起 `.bat` 在本机其实也
    //   跑得通 —— Dart 走的是关联 cmd 的那条路 —— 前缀只是为了让测试可控）。
    final Process proc;
    try {
      proc = await Process.start(argv.first, argv.skip(1).toList());
    } catch (e) {
      return _failure(
        BiliMergeFailure.processError,
        'ffmpeg 进程没能启动：$e',
        commandLine,
        '',
      );
    }

    // ③ 收两条流。stdout = `-progress pipe:1` 的 key=value，逐行解析；
    //   stderr = 错误原文，收全再解码。
    //   **stdout 用 UTF-8、stderr 用系统编码**：ffmpeg 自己按 UTF-8 输出，
    //   而 `cmd.exe` 的错误（路径带空格之类）按系统 ANSI 代码页输出，
    //   用 UTF-8 解 stderr 会得到一串乱码、看不出根因。
    var sawEnd = false;
    var lastP = 0.0;
    int? outTimeUs;
    final stderrBytes = <int>[];

    final carry = StringBuffer();
    final stdoutDone = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
          carry.write(chunk);
          final text = carry.toString();
          final cut = text.lastIndexOf('\n');
          if (cut < 0) return;
          carry
            ..clear()
            ..write(text.substring(cut + 1));
          for (final line in text.substring(0, cut).split('\n')) {
            final point = parseFfmpegProgressLine(line);
            if (point == null) continue;
            if (point.outTimeUs != null) outTimeUs = point.outTimeUs;
            if (point.ended) sawEnd = true;
            // 未到 end 的一律压在 1.0 之前：`total_size` 到了输入字节数也不代表
            // ffmpeg 写完 moov，这时候报 100% 是在骗界面。
            final raw = point.totalSize == null || inBytes <= 0
                ? null
                : (point.totalSize! / inBytes).clamp(0.0, 0.9999);
            final next = point.ended ? 1.0 : raw;
            if (next != null && next > lastP) {
              lastP = next;
              onProgress?.call(next);
            }
          }
        })
        .asFuture<void>();
    final stderrDone = proc.stderr.listen(stderrBytes.addAll).asFuture<void>();

    int? exitCode;
    Object? runError;
    try {
      exitCode = await proc.exitCode;
      // 进程退了之后再收尾：管道里可能还压着最后一块（含 `progress=end`），
      // 抢先判定就会把它读成「没跑到 end」。
      await stdoutDone;
      await stderrDone;
    } catch (e) {
      runError = e;
    }
    final stderrText = runError == null
        ? _decodeStderr(stderrBytes)
        : '${_decodeStderr(stderrBytes)}\n(读取子进程输出时异常：$runError)';

    if (runError != null) {
      return _failure(
        BiliMergeFailure.processError,
        '合并过程中子进程读取异常：$runError',
        commandLine,
        stderrText,
        mediaDuration: _durationOf(outTimeUs),
      );
    }

    final code = exitCode ?? -1;
    final out = File(outPath);
    final outExists = await out.exists();
    final outSize = outExists ? await _size(outPath) : -1;
    final duration = _durationOf(outTimeUs);

    // ④ 三种失败形状按「谁知道得更多」排序：非 0 退出码是 ffmpeg 自己判的失败，
    //   比「没读到 end」更具体，所以先报它。三条分支都先过一次 [_cleanupOnFailure]
    //   （只删 0 字节产物，原始流一律保留）。
    if (code != 0) {
      await _cleanupOnFailure(outExists, outSize, outPath);
      return _failure(
        BiliMergeFailure.exitNonZero,
        'ffmpeg 退出码 $code（合并失败）。两条原始流已保留。',
        commandLine,
        stderrText,
        mediaDuration: duration,
      );
    }
    if (!sawEnd) {
      await _cleanupOnFailure(outExists, outSize, outPath);
      return _failure(
        BiliMergeFailure.noEndProgress,
        'ffmpeg 没跑到收尾就退出了（读到退出码 0，但全程没有 progress=end）。'
        '通常是进程被强杀或中途崩溃，两条原始流已保留。',
        commandLine,
        stderrText,
        mediaDuration: duration,
      );
    }
    if (!outExists || outSize <= 0) {
      await _cleanupOnFailure(outExists, outSize, outPath);
      return _failure(
        BiliMergeFailure.badProduct,
        outExists
            ? 'ffmpeg 报成功，但产物是 0 字节（$outPath）。两条原始流已保留。'
            : 'ffmpeg 报成功，但产物并不存在（$outPath）。两条原始流已保留。',
        commandLine,
        stderrText,
        mediaDuration: duration,
      );
    }

    // ⑤ 成功：清掉两条原始流。0 字节的产物在上面已经拦下，这里只可能删掉
    //   「看起来像成品」的东西，所以失败路径里的清理规则见 [_cleanupOnFailure]。
    final note = await _deleteStreams(videoPath, audioPath, outPath);
    AppLogger.log(
      kBiliMergeLogTag,
      '合并完成：$outPath（$outSize 字节，媒体时长 ${duration.inMilliseconds}ms）'
      '${note.isEmpty ? '' : ' —— $note'}',
    );
    return BiliMergeResult(
      ok: true,
      commandLine: commandLine,
      message: note,
      stderr: _tail(stderrText),
      mediaDuration: duration,
    );
  }

  BiliMergeResult _failure(
    BiliMergeFailure kind,
    String message,
    String commandLine,
    String stderrText, {
    Duration mediaDuration = Duration.zero,
  }) {
    AppLogger.log(
      kBiliMergeLogTag,
      '合并失败（${kind.name}）：$message\n'
      '命令行：$commandLine\n'
      'stderr：${_tail(stderrText)}',
    );
    return BiliMergeResult(
      ok: false,
      failure: kind,
      message: message,
      commandLine: commandLine,
      stderr: _tail(stderrText),
      mediaDuration: mediaDuration,
    );
  }

  /// `out_time_*` → [Duration]。值已经是**微秒**（见 [parseFfmpegProgressLine]），
  /// 直接给 [Duration.microseconds]，不许再乘 1000。
  static Duration _durationOf(int? us) =>
      us == null || us <= 0 ? Duration.zero : Duration(microseconds: us);

  /// 失败时的清理：**只删确实存在、且 0 字节的产物**，其余一律留着。
  ///
  /// 为什么删 0 字节：那种文件对下游只有坏处 —— 下载侧的「同名跳过」和
  /// 重启对账都会把它当成「已经下好了」（`aria2_coordinator` 里 0 字节空响应
  /// 被判成功的坑是同一回事），而它一点内容都没有，不算现场。
  /// 为什么留**非空**残片：那是取证材料（能看出合并在第几秒断的），删了就没得查。
  /// 为什么单独传 [exists]：产物压根没被创建时不该去 delete 一波，
  /// 那只会往日志里留一条没意义的「没能删掉」。
  /// 原始流在**任何**失败分支都不许动。
  static Future<void> _cleanupOnFailure(
    bool exists,
    int size,
    String outPath,
  ) async {
    if (!exists || size != 0) return;
    try {
      await File(outPath).delete();
      AppLogger.log(kBiliMergeLogTag, '已删掉 0 字节的无效产物：$outPath');
    } catch (e) {
      AppLogger.log(kBiliMergeLogTag, '0 字节产物没能删掉：$outPath —— $e');
    }
  }

  /// 成功后删两条原始流，返回给用户看的附注（一切正常时为空串）。
  ///
  /// **先比一次「是不是同一个文件」**：调用方把 [outPath] 写成视频流自己的路径
  /// 并非不可能（同名覆盖），那时候再删一次就是把刚合好的成品删掉。
  /// Windows 路径大小写不敏感，所以按小写化的规范路径比。
  Future<String> _deleteStreams(
    String videoPath,
    String audioPath,
    String outPath,
  ) async {
    final kept = <String>[];
    final notes = <String>[];
    for (final path in [videoPath, audioPath]) {
      if (_sameFile(path, outPath)) {
        kept.add(path);
        continue;
      }
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        notes.add('$path 没能删掉（$e）');
      }
    }
    if (kept.isNotEmpty) {
      notes.add('原始流与产物同路径，为避免删掉成品已保留：${kept.join('、')}');
    }
    return notes.join('；');
  }

  static bool _sameFile(String a, String b) {
    try {
      return p.canonicalize(a).toLowerCase() == p.canonicalize(b).toLowerCase();
    } catch (_) {
      return a == b;
    }
  }

  static Future<int> _size(String path) async {
    try {
      final n = await File(path).length();
      return n < 0 ? 0 : n; // 异常值当空文件，别让 -1 参与求和（见 inBytes 的判据）
    } catch (_) {
      // 不存在 / 打不开（被占用、 ACL 拒绝、路径非法）都回 0：
      // **刻意不用 -1** —— 进度分母是「视频流 + 音频流」两笔相加，
      // 回 -1 会让 `inBytes <= 0` 的守卫被另一条的正常大小抵掉（-1+1000=999），
      // 于是 1000/999 算出一个 >1 的进度。文件在不在另有真判据：
      // ffmpeg 自己会报错（[BiliMergeResult.stderr]），产物存不存在由 [_size]
      // 之外的 existsSync 语义在成功分支里把关。
      return 0;
    }
  }

  static String _decodeStderr(List<int> bytes) {
    if (bytes.isEmpty) return '';
    try {
      return systemEncoding.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static String _tail(String s) {
    final t = s.trimRight();
    if (t.length <= kBiliMergeStderrKeepChars) return t;
    return '…（前面省略 ${t.length - kBiliMergeStderrKeepChars} 字符）'
        '${t.substring(t.length - kBiliMergeStderrKeepChars)}';
  }
}
