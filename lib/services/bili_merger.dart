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
/// **随包的 ffmpeg 在 `assets/ffmpeg.exe`，但 Flutter 的 asset 不能直接执行**，
/// 所以 [BiliMerger.resolvePath] 按两处找：先安装目录同级 `ffmpeg\ffmpeg.exe`
/// （出包放进去的那份），没有就从 bundle 释放一份到 userdata —— 与 [Aria2]
/// 释放 `aria2c.exe` 同一套路。两处都没有时报可读失败，不返回 null、也不抛。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'app_paths.dart';

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

/// 随包 ffmpeg 在 bundle 里的 asset 键（与 `pubspec.yaml` 的声明一致）。
const String kBiliFfmpegAssetKey = 'assets/ffmpeg.exe';

/// 读 bundle 资源的那一层。**刻意做成可注入的 typedef**：单测里没有 asset
/// bundle，`rootBundle.load` 直接抛，注入一份假字节才能验到「释放」这一步。
typedef BiliAssetLoader = Future<ByteData> Function(String key);

/// ffmpeg 没显式指定路径时的**第一处**：exe 同级的 `ffmpeg\ffmpeg.exe`。
///
/// 出包时把 ffmpeg 放进安装目录的这个子目录里，装好的那份优先。
/// 用 [Platform.resolvedExecutable] 而不是当前工作目录 —— 桌面应用的工作目录
/// 可能是快捷方式指的任何地方。
///
/// ⚠️ 但**不能只靠这一处**：开发实例（`build\...\Debug\`）与没跑过出包脚本的
/// 环境都没有这个子目录，而 2026-10-11 之前全项目没有任何一处会把
/// `assets/ffmpeg.exe` 落到盘上 —— 于是每一次 B 站合并都稳定报 `ffmpegMissing`，
/// 成品出不来。兜底见 [sidecarFfmpegPath] 与 [BiliMerger.resolvePath]。
String defaultFfmpegPath() => p.join(
  p.dirname(Platform.resolvedExecutable),
  kFfmpegDirName,
  kFfmpegExeName,
);

/// ffmpeg 的**第二处**：userdata 里从 bundle 释放出来的那一份。
///
/// 与 `aria2c.exe` 同一个落点（见 `aria2.dart` 的 `_ensureSidecar`）——
/// 安装目录可能只读（Program Files），userdata 一定可写。
String sidecarFfmpegPath() => p.join(AppPaths.configDir.path, kFfmpegExeName);

/// 用户在设置里指定的 ffmpeg 目录 → 该目录下**可能**的 exe 全路径候选，按优先序。
///
/// 为什么要给多个候选：完整构建的压缩包里层级是 `<解压目录>\bin\ffmpeg.exe`，
/// 而有人会把 exe 直接拷到外面。让用户去指到"exe 那一层"很容易指错一层，
/// 所以**目录里直接有、或下一层 `bin\` 里有，两种都认**。
///
/// 纯函数（不碰盘）：是否真存在由调用方逐个 `File.exists` 判 —— 这样这条
/// 候选顺序能被单测钉住，不必造真目录。
List<String> ffmpegCandidatesIn(String dir) {
  final d = dir.trim();
  if (d.isEmpty) return const [];
  return [
    p.join(d, kFfmpegExeName),
    p.join(d, 'bin', kFfmpegExeName),
  ];
}

/// 失败的哪一种。三种「没成功」的形状必须分开：界面要给出不同的下一步
/// （装 ffmpeg / 重试 / 换原始流），光一句「合并失败」等于没说。
enum BiliMergeFailure {
  /// 找不到 ffmpeg 可执行文件 —— 两处都没有（安装目录那份没放、bundle 里也
  /// 释放不出来）。用户侧是「包没带全 / 路径填错了 / 目录不可写」。
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
/// 一条要塞进成品的内封字幕轨。
///
/// 路径由调用方解析成绝对路径再交进来 —— 合并层不该知道保存目录的拼法，
/// 也不该知道 `BiliEmbeddedTrack` 那套契约（它只吃路径和两个标签）。
typedef BiliSubtitleInput = ({String path, String title, String lang});

class BiliMerger {
  /// [ffmpegPath] 为 null 时走 [resolvePath]：先 exe 同级 `ffmpeg\`，
  /// 再把 bundle 里那份释放到 userdata。注入它就是为了指到本机任何一份 ffmpeg。
  ///
  /// [commandPrefix] 生产为空；单测传 `['cmd.exe', '/c']` 指到一个假批处理上
  /// （本应用只跑 Windows，前缀是给测试留的唯一缝隙，见 [merge]）。
  ///
  /// [loadAsset] 是读 bundle 的那一层，单测里必须注入 —— 测试环境没有 asset
  /// bundle，`rootBundle.load` 直接抛。
  ///
  /// 字段刻意不叫 `_ffmpegPath`：命名参数 `ffmpegPath` 与同名私有字段直接赋值会
  /// 同时触发 `prefer_initializing_formals` 与 `unnecessary_this`，而
  /// `this._ffmpegPath` 这种初始化形式在 Dart 里又是非法的（命名参数不能对应私有
  /// 字段）。换个字段名把两条 lint 一起绕开，参数名保持任务指定的 `ffmpegPath`。
  BiliMerger({
    String? ffmpegPath,
    this.userDir,
    this.commandPrefix = const [],
    BiliAssetLoader? loadAsset,
  }) : _pathOverride = ffmpegPath,
       _loadAsset = loadAsset ?? rootBundle.load;

  final String? _pathOverride;
  final BiliAssetLoader _loadAsset;

  /// 用户在设置里指定的 ffmpeg 目录（见 `BiliConfig.ffmpegDir`）。空 = 不指定。
  ///
  /// 指定了就**优先于随包那份**：用户装完整版是为了拿到白名单构建没有的能力
  /// （h264/hevc 编码、ffprobe、字幕滤镜），我们不能拿随包那份把他顶掉。
  ///
  /// 公开可写（不是私有字段 + setter）：[setUserDir] 要能同时清掉解析缓存，
  /// 而命名参数那条路只需要赋值。两者分工写清楚，别在外部直接改这个字段。
  String? userDir;

  /// 设置页改了目录之后热更新，免得要重启应用。[resolvePath] 的结果会跟着重算。
  void setUserDir(String? dir) {
    final next = (dir ?? '').trim();
    if (next == (userDir ?? '')) return;
    userDir = next.isEmpty ? null : next;
    _resolving = null;
    _resolved = null;
  }

  /// 解析结果的两级缓存：[_resolving] 让并发请求只释放一次文件，
  /// [_resolved] 是给同步取值用的。
  Future<String>? _resolving;
  String? _resolved;

  /// 加在 ffmpeg 可执行文件**之前**的 argv（只用于测试）。
  final List<String> commandPrefix;

  /// 本次实际使用的 ffmpeg 路径。
  ///
  /// **没跑过 [resolvePath] 之前它就是「注入值或安装目录那份」，不做存在性判断**；
  /// 解析过之后会带上释放出来的 userdata 路径。argv 必须由 [merge] 在
  /// [resolvePath] **之后**再拼，否则拼进去的是没解析过的那个位置。
  String get ffmpegPath => _pathOverride ?? _resolved ?? defaultFfmpegPath();

  /// 真正要用的那一份在哪：**安装目录优先，其次 userdata 里释放出来的那份**，
  /// 两处都没有就把 bundle 里的 `assets/ffmpeg.exe` 写到 userdata。
  ///
  /// 为什么必须有这一步：Flutter 的 asset 是打进 bundle 的，**不能直接执行**，
  /// 而 NSIS 出包脚本里压根没有 ffmpeg（2026-10-11 实测：装机版目录与开发实例
  /// 都没有 `ffmpeg\` 子目录）。少了兜底，每一次 B 站合并都会稳定报
  /// `ffmpegMissing`，成品一个也出不来。
  ///
  /// 释放失败不抛：回一个不存在的路径，让 [merge] 照原样给那句可读的
  /// 「没找到 ffmpeg」。
  Future<String> resolvePath() => _resolving ??= _resolve();

  Future<String> _resolve() async {
    final override = _pathOverride;
    if (override != null) return _resolved = override;

    // ① 用户在设置里指定的目录**最优先**：他装完整版就是为了拿到随包那份没有的
    //    能力（h264/hevc 编码、ffprobe、字幕滤镜），不能被随包那份顶掉。
    //    目录里直接有、或下一层 `bin\` 里有，两种都认（完整构建解压后就带 bin）。
    final userDir = this.userDir;
    if (userDir != null && userDir.isNotEmpty) {
      for (final cand in ffmpegCandidatesIn(userDir)) {
        if (await File(cand).exists()) {
          AppLogger.log(kBiliMergeLogTag, '用外部 ffmpeg：$cand');
          return _resolved = cand;
        }
      }
      // 指了目录但里面没有 —— 如实记一行，然后**继续往下找**。
      // 不在这里失败：用户可能只是把路径填错了，随包那份仍然能用，
      // 直接报「找不到」等于把他本来就有的能力也弄没了。
      AppLogger.log(
        kBiliMergeLogTag,
        '设置里的 ffmpeg 目录里没有 ffmpeg.exe（试过 ${ffmpegCandidatesIn(userDir).join(" 与 ")}），改用随包那份',
      );
    }

    final installed = defaultFfmpegPath();
    if (await File(installed).exists()) return _resolved = installed;
    // 整段都在 try 里：[sidecarFfmpegPath] 要读 AppPaths，而它可能还没 init
    // （单测、以及任何在 main() 之前就被构造出来的合并器）。
    try {
      final sidecar = sidecarFfmpegPath();
      if (await File(sidecar).exists()) return _resolved = sidecar;
      final data = await _loadAsset(kBiliFfmpegAssetKey);
      final f = File(sidecar);
      await f.create(recursive: true);
      await f.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      AppLogger.log(kBiliMergeLogTag, '随包 ffmpeg 已释放到 $sidecar');
      return _resolved = sidecar;
    } catch (e) {
      AppLogger.log(kBiliMergeLogTag, '释放随包 ffmpeg 没成，按找不到处理：$e');
      return _resolved = installed;
    }
  }

  /// ffmpeg 在不在。**只查文件存在，不跑一次 `-version`** ——
  /// 给设置页当「ffmpeg 没找到，合并会失败」的提示用。注意它不等于「能跑」：
  /// 被安全软件拦下时这里仍返回 true，真判据是 [merge] 的返回值。
  ///
  /// ⚠️ 它会**触发一次释放**（第一次调用时把 bundle 里那 10 MB 写到 userdata）。
  /// 这是有意的：提示条不该在能自愈的事情上报警，而代价只是一次性的落盘。
  Future<bool> get available async => File(await resolvePath()).exists();

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
    String outPath, {
    List<BiliSubtitleInput> subtitleTracks = const [],
    String? chapterPath,
    bool? faststart,
  }) {
    // 没显式给就按产物扩展名定：`+faststart` 只有 mp4 认，
    // 交给调用方去推早晚会漏一处（比如重启重建那条路径）。
    final wantFaststart = faststart ?? outPath.toLowerCase().endsWith('.mp4');
    final args = <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-i',
      videoPath,
      '-i',
      audioPath,
    ];
    // 输入顺序决定后面所有 `-map` 的索引，别在中途插东西。
    for (final t in subtitleTracks) {
      args.addAll(['-i', t.path]);
    }
    if (chapterPath != null) args.addAll(['-i', chapterPath]);

    args.addAll(['-map', '0:v:0', '-map', '1:a:0']);
    for (var k = 0; k < subtitleTracks.length; k++) {
      args.addAll(['-map', '${2 + k}:0']);
    }
    args.addAll(['-c', 'copy']);
    if (subtitleTracks.isNotEmpty) {
      // 字幕轨原样封进去，不转格式：转 ass↔srt 要的是编码器，
      // 而这里只想要「同一条字节流换个容器」。
      args.addAll(['-c:s', 'copy']);
      for (var k = 0; k < subtitleTracks.length; k++) {
        final t = subtitleTracks[k];
        // `s:` 后面是**流限定符**，写法是「类型:序号」，所以这里要有两个冒号：
        // `-metadata:s:s0` 被 ffmpeg 判成 `Trailing garbage at the end of a
        // stream specifier: s0`，整条合并命令直接退出（2026-10-11 真机撞实）。
        final spec = '-metadata:s:s:$k';
        args.addAll([spec, 'title=${t.title}']);
        // 空语言码比不写更糟（播放器菜单里会出现一个非法的 Language 标签），
        // 所以空串就整条不写。
        if (t.lang.isNotEmpty) {
          args.addAll([spec, 'language=${t.lang}']);
        }
      }
    }
    // +faststart 是 mp4 的事。matroska 不认这个键，塞过去只会换一句没人看的告警。
    if (wantFaststart) args.addAll(['-movflags', kFfmpegMovflags]);
    args.addAll(['-progress', 'pipe:1', outPath]);
    return args;
  }

  /// 完整 argv（前缀在最前）。
  List<String> buildCommand(
    String videoPath,
    String audioPath,
    String outPath, {
    List<BiliSubtitleInput> subtitleTracks = const [],
    String? chapterPath,
    bool? faststart,
  }) =>
      [
        ...commandPrefix,
        ffmpegPath,
        ...mergeArgs(
          videoPath,
          audioPath,
          outPath,
          subtitleTracks: subtitleTracks,
          chapterPath: chapterPath,
          faststart: faststart,
        ),
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
    List<BiliSubtitleInput> subtitleTracks = const [],
    String? chapterPath,
    void Function(double p)? onProgress,
  }) =>
      _withGate(
        () => _mergeOnce(
          videoPath: videoPath,
          audioPath: audioPath,
          outPath: outPath,
          subtitleTracks: subtitleTracks,
          chapterPath: chapterPath,
          onProgress: onProgress,
        ),
      );

  Future<BiliMergeResult> _mergeOnce({
    required String videoPath,
    required String audioPath,
    required String outPath,
    List<BiliSubtitleInput> subtitleTracks = const [],
    String? chapterPath,
    void Function(double p)? onProgress,
  }) async {
    // 先定位二进制，再拼 argv：buildCommand 里的第一项取自 [ffmpegPath]，
    // 而释放出来的那份只有 resolvePath 跑完才知道 —— 顺序反了就把一个
    // 不存在的路径拼进了命令行。
    await resolvePath();
    final argv = buildCommand(
      videoPath,
      audioPath,
      outPath,
      subtitleTracks: subtitleTracks,
      chapterPath: chapterPath,
    );
    final commandLine = formatFfmpegCommand(argv);

    // ① 先确认二进制在不在。少了这一步，Process.start 只会给一句
    //   「CreateProcess ... 系统找不到指定的文件」，用户看不出是路径问题。
    if (!await File(ffmpegPath).exists()) {
      // 第二处只有在 AppPaths 已 init 时才说得出路径（单测里它没 init，
      // 而 sidecarFfmpegPath() 会抛 —— 一句失败提示不该把异常顶出来）。
      final where = AppPaths.ready
          ? '找过两处：安装目录的 ${defaultFfmpegPath()}，以及 userdata 里的 '
                '${sidecarFfmpegPath()}（后者本该由随包资源自动释放）。'
          : '随包资源里的那一份也没能释放出来。';
      return _failure(
        BiliMergeFailure.ffmpegMissing,
        '没找到 ffmpeg（$ffmpegPath）。B 站下的是 DASH 分开的两条流，'
        '视频流和音频流各自都不能单独播放，必须先合并成 mp4。$where',
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
