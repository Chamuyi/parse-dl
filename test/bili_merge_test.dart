import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/bili_merger.dart';

/// 假 ffmpeg（批处理）要造出的产物形状。
enum FakeProduct {
  /// 压根不创建产物（ffmpeg 连输出文件都没打开就失败的样子）
  none,

  /// 创建一个 0 字节的产物（ffmpeg 报了 success 但没写进任何数据）
  empty,

  /// 创建一个有内容的产物
  bytes,
}

/// `cmd /c` 起脚本对路径的两条前提（本机实测）：不许有**空格**（后面还跟着参数时
/// cmd 会切词，脚本一行都不执行），也不许有**引号字符**（那种路径在 Windows 上根本
/// 非法）。先失败并说明原因，比让一串用例莫名其妙地红要好 —— 所以做成顶层函数，
/// `setUp` 与 `fakeFfmpeg` 都能用（Dart 的局部函数不能先用后声明）。
void assertCmdSafe(String path, String what) {
  if (path.isEmpty) return;
  if (path.contains(' ') || path.contains('"')) {
    throw StateError('$what 的路径不适合走 cmd /c'
        '（空格或引号会让批处理**完全不执行**）：$path\n'
        '这是测试运行环境的问题（临时目录带空格），不是合并器的缺陷。');
  }
}

/// B 站 DASH 合并层（`lib/services/bili_merger.dart`）的回归测试。
///
/// **不依赖真 ffmpeg，也不联网。** 用 `Directory.systemTemp` 里的批处理脚本冒充
/// ffmpeg：按测试要求 echo 出 `-progress pipe:1` 的那几行、造出需要的产物形状
/// （不存在 / 0 字节 / 有内容）、并以指定退出码结束。
///
/// 三条成功判据（`progress=end` / 退出码 0 / 产物非 0 字节）各拆一条用例打穿，
/// 每条失败路径都断言**两条原始流仍在**（负控制：任何「失败也删流」的实现都会
/// 在这里红）—— 那是用户唯一还能自己处理的东西，误删比报错误导得多。
///
/// 关于「怎么把 .bat 当一个进程起」，本机 Dart 3.13.3 实测到三条事实，
/// 早先注释里写错的两条已按实测改正：
///   - `commandPrefix: ['cmd.exe', '/c']` 是任务指定的起法，本文件大部分用例用它；
///   - **直接 `Process.start(bat, …)` 也能跑**（实测退出码与 stdout 都拿得到，
///     Dart 起 .bat 走的是关联 cmd 的那条路）—— 所以另有一条用例走**空前缀**，
///     把生产真正用的那条形状也覆盖掉；
///   - 但 `cmd /c "<带空格的路径.bat>" <后续参数…>` **会失败**：cmd 剥外层引号后
///     把首个 token 当命令名，实测 rc=1 且脚本**一行都不执行**（连 echo 到计数
///     文件的副作用都没有）。同一份脚本不带后续参数时能跑，所以坑只出现在
///     「脚本后面还要传参数」的场合 —— 正是 merge 的场合。假脚本因此必须放在
///     无空格路径下，[assertCmdSafe] 把这条前提钉住；否则整个 suite 会静默退化成
///     「进程压根没跑」，只剩一串断言不到点的红。
/// 路径里带 `"` 的场合不用担心：Windows 连这种文件都创建不出来
/// （实测 `CreateFile` errno 123「文件名、目录名或卷标语法不正确」）。
void main() {
  const prefix = ['cmd.exe', '/c'];
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bili-merge-');
    assertCmdSafe(tmp.path, '临时目录');
  });

  tearDown(() async {
    // 只清本文件自己建的目录。刚跑完 cmd 子进程时句柄可能还没松，
    // 删一次失败就重试两回 —— 不然这里会变成偶发红。
    for (var i = 0; i < 3 && tmp.existsSync(); i++) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  });

  // ── 脚手架 ────────────────────────────────────────────────

  /// 造一条「原始流」文件，内容 [bytes] 字节（既是 ffmpeg 的输入，也是进度分母）。
  File stream(String name, int bytes) =>
      File('${tmp.path}\\$name')..writeAsBytesSync(List.filled(bytes, 7));

  String pathOf(String name) => '${tmp.path}\\$name';

  /// 造一个冒充 ffmpeg 的批处理，返回它的路径。
  ///
  /// 产物路径 / 计数文件路径都**硬编码进脚本内容**：合并器不给子进程注入环境变量
  /// （生产不需要），所以没有别的传参通道。
  ///
  /// [outPaths] 可以不止一条 —— 闸门那条用例里两个 merge 共用一份脚本，
  /// 两边都得看到自己的产物。
  ///
  /// 脚本按 CRLF 写字节：实测 LF-only 的批处理在这台机子上也能跑，但 cmd 对
  /// LF 脚本不作保证，这里不赌。脚本里用 `>>"file" echo X`（重定向写在前面）
  /// 这种写法，避开 `echo …4>>file` 被 cmd 读成「句柄 4 重定向」的经典坑
  /// —— 产物路径正好以 `.mp4` 结尾，撞上那个坑。
  Future<String> fakeFfmpeg({
    required String name,
    required List<String> outPaths,
    List<String> progress = const [],
    int exitCode = 0,
    FakeProduct product = FakeProduct.bytes,
    String? markerPath,
    bool hold = false,
    String stderrText = '',
  }) async {
    final batPath = '${tmp.path}\\$name';
    assertCmdSafe(batPath, '假 ffmpeg 脚本');
    assertCmdSafe(markerPath ?? '', '计数文件');
    for (final p in outPaths) {
      assertCmdSafe(p, '产物路径');
    }

    final lines = <String>['@echo off'];
    if (markerPath != null) {
      lines
        ..add('>>"$markerPath" echo START')
        ..add('>>"$markerPath" echo ARGS=%*');
    }
    // ~1 秒的占位：闸门那条要能看出「有没有重叠」
    if (hold) lines.add('ping -n 2 127.0.0.1 >nul');
    lines.addAll(progress.map((l) => 'echo $l'));
    if (stderrText.isNotEmpty) lines.add('echo $stderrText 1>&2');
    for (final p in outPaths) {
      switch (product) {
        case FakeProduct.none:
          break;
        case FakeProduct.empty:
          lines.add('type nul > "$p"');
          break;
        case FakeProduct.bytes:
          lines.add('> "$p" echo merged-payload-bytes');
          break;
      }
    }
    if (markerPath != null) lines.add('>>"$markerPath" echo END');
    lines.add('exit /b $exitCode');
    // 脚本内容与路径都是 ASCII，按 codeUnits 写不会掉字符
    File(batPath).writeAsBytesSync('${lines.join('\r\n')}\r\n'.codeUnits,
        flush: true);
    return batPath;
  }

  /// 读计数文件的行（cmd 的 echo 会带尾随空格，逐行 trim）。
  List<String> markerLines(String path) => File(path)
      .readAsLinesSync()
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  // ── 纯函数：进度解析 ───────────────────────────────────────
  group('parseFfmpegProgressLine（单位陷阱）', () {
    test('out_time_us 与 out_time_ms 都按微秒读，值不乘 1000', () {
      expect(parseFfmpegProgressLine('out_time_us=5106939')!.outTimeUs, 5106939);
      // **`out_time_ms` 这个名字是误导的**：真 ffmpeg 9.0.1 实测 5.106939 秒的
      // 素材，out_time_us 与 out_time_ms 打出来都是 5106939。
      // 按字面当毫秒用，时长与进度会凭空多 1000 倍。
      expect(parseFfmpegProgressLine('out_time_ms=5106939')!.outTimeUs, 5106939);
    });

    test('total_size / progress=end 认得，end 之外不算结束', () {
      expect(parseFfmpegProgressLine('total_size=1019009')!.totalSize, 1019009);
      expect(parseFfmpegProgressLine('progress=end')!.ended, isTrue);
      expect(parseFfmpegProgressLine('progress=continue')!.ended, isFalse);
      expect(parseFfmpegProgressLine('progress=continue')!.outTimeUs, isNull);
    });

    test('非进度行与 N/A 一律 null（不许当成 0）', () {
      expect(parseFfmpegProgressLine(''), isNull);
      expect(parseFfmpegProgressLine('frame=  149'), isNull);
      expect(parseFfmpegProgressLine('fps=0.00'), isNull);
      expect(parseFfmpegProgressLine('speed=1.32e+03x'), isNull);
      // 带冒号的时钟串不是整数，不能和 out_time_us 混起来
      expect(parseFfmpegProgressLine('out_time=00:00:05.106939'), isNull);
      expect(parseFfmpegProgressLine('out_time_us=N/A'), isNull);
      expect(parseFfmpegProgressLine('total_size=N/A'), isNull);
      expect(parseFfmpegProgressLine('=5'), isNull);
    });

    test('容忍行尾 \\r 与前后空格（ffmpeg / cmd 的输出都是 \\r\\n）', () {
      expect(parseFfmpegProgressLine('  progress=end\r\n')!.ended, isTrue);
      expect(parseFfmpegProgressLine(' out_time_us=7 \r')!.outTimeUs, 7);
    });
  });

  // ── 纯函数：命令行组装 ─────────────────────────────────────
  group('命令行组装', () {
    test('固定参数逐字对齐参照实现（双 map、copy、faststart、progress pipe）', () {
      final argv = BiliMerger(ffmpegPath: r'C:\ff\ffmpeg.exe')
          .buildCommand(r'D:\v.m4s', r'D:\a.m4s', r'D:\out.mp4');
      expect(argv, [
        r'C:\ff\ffmpeg.exe',
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        r'D:\v.m4s',
        '-i',
        r'D:\a.m4s',
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-c',
        'copy',
        '-movflags',
        '+faststart',
        '-progress',
        'pipe:1',
        r'D:\out.mp4',
      ]);
    });

    test('命令行里不出现任何编码器名（随包那份构建没有 x264 / aac 编码器）', () {
      final joined = BiliMerger(ffmpegPath: 'f')
          .buildCommand('v', 'a', 'o')
          .join(' ')
          .toLowerCase();
      for (final codec in ['libx264', 'aac', 'hevc', 'av1', 'libmp3lame']) {
        expect(joined, isNot(contains(codec)), reason: '$codec 意味着要重编码');
      }
      expect(joined, contains('-c copy'));
    });

    test('拼接只做「含空格就加引号」，不做内部引号翻倍', () {
      // 生产 argv 只可能是 exe / 纯选项 / Windows 路径，而 `"` 是路径非法字符
      // （实测带它的文件连创建都会失败），永远进不到这里 —— 翻倍那条分支不可达，
      // 已删。本断言钉住现在的形状。
      expect(formatFfmpegCommand(['a', 'b c', 'd']), 'a "b c" d');
      final tricky = r'z"b';
      expect(tricky, isNot(contains(' ')), reason: '无空格就不加引号');
      expect(formatFfmpegCommand([tricky]), tricky);
      expect(formatFfmpegCommand([tricky]), isNot(contains('""')));
    });

    test('测试前缀排在可执行文件之前', () {
      final line = BiliMerger(
        ffmpegPath: r'C:\a b\ffmpeg.exe',
        commandPrefix: prefix,
      ).buildCommand('v', 'a', 'o');
      expect(line.first, 'cmd.exe');
      expect(line[1], '/c');
      expect(line[2], r'C:\a b\ffmpeg.exe');
      expect(formatFfmpegCommand(line), startsWith('cmd.exe /c "C:\\a b\\'));
    });

    test('默认路径是 exe 同级 ffmpeg/ffmpeg.exe，分隔符走 Platform', () {
      final s = Platform.pathSeparator;
      expect(defaultFfmpegPath(), endsWith('$s$kFfmpegDirName$s$kFfmpegExeName'));
    });
  });

  // ── merge：成功 ───────────────────────────────────────────
  group('内封字幕轨与章节的命令拼接', () {
    final m = BiliMerger(ffmpegPath: r'C:\ffmpeg\ffmpeg.exe');
    BiliSubtitleInput t(String path, {String title = '字幕', String lang = ''}) =>
        (path: path, title: title, lang: lang);

    test('不传新参数时，命令与改造前逐字相同', () {
      expect(
        m.mergeArgs(r'D:\v.m4s', r'D:\a.m4s', r'D:\out.mp4'),
        [
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-i',
          r'D:\v.m4s',
          '-i',
          r'D:\a.m4s',
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
          r'D:\out.mp4',
        ],
        reason: '这一条是「既有链路没被容器/内封改造碰坏」的唯一证据',
      );
    });

    test('一条字幕轨：输入排在音视频之后，-map 用的是 2', () {
      final args = m.mergeArgs('v', 'a', 'o.mkv', subtitleTracks: [
        t(r'D:\x.字幕.中文.ass', lang: 'chi'),
      ]);
      expect(args, containsAllInOrder(['-i', r'D:\x.字幕.中文.ass']));
      expect(args, containsAllInOrder(['-map', '0:v:0', '-map', '1:a:0', '-map', '2:0']));
      expect(args, containsAllInOrder(['-metadata:s:s:0', 'language=chi']));
      expect(args, contains('-c:s'));
    });

    test('两条轨 + 章节：索引按输入顺序排，章节不占 -map', () {
      final args = m.mergeArgs(
        'v',
        'a',
        'o.mkv',
        subtitleTracks: [t('s0.ass'), t('s1.ass')],
        chapterPath: 'chap.txt',
      );
      // 输入顺序：0=v 1=a 2=s0 3=s1 4=chap
      expect(
        args.where((x) => x.endsWith('.ass') || x == 'v' || x == 'a' || x == 'chap.txt').toList(),
        ['v', 'a', 's0.ass', 's1.ass', 'chap.txt'],
      );
      expect(args, containsAllInOrder(['-map', '2:0', '-map', '3:0']));
      expect(args, containsAllInOrder(['-metadata:s:s:0', 'title=字幕']));
      expect(args, containsAllInOrder(['-metadata:s:s:1', 'title=字幕']));
      // 少一个冒号的写法 ffmpeg 会整条拒掉（真机实测），别让它回潮
      expect(args.where((a) => a.startsWith('-metadata:s:s') && !a.contains('s:s:')), isEmpty);
      // 实测结论（Q6d）：章节是被 muxer 从输入本身吸进去的，
      // `-map_metadata` 对章节既不必需也不充分，还会换掉全局 metadata 的来源。
      expect(args, isNot(contains('-map_metadata')));
    });

    test('语言码为空时不写 language，但 title 照写', () {
      final args = m.mergeArgs('v', 'a', 'o.mkv', subtitleTracks: [t('d.ass')]);
      expect(args.any((x) => x.startsWith('language=')), isFalse);
      expect(args, contains('title=字幕'), reason: '弹幕墙没有语言概念，但轨道名还得有');
    });

    test('产物是 mkv 时不带 -movflags（那是 mp4 的键）', () {
      expect(m.mergeArgs('v', 'a', 'o.mkv'), isNot(contains('-movflags')));
      expect(m.mergeArgs('v', 'a', 'o.mp4'), contains(kFfmpegMovflags));
      expect(m.mergeArgs('v', 'a', 'o.MKV'), isNot(contains('-movflags')),
          reason: '扩展名判据不许只对小写生效');
    });
  });

  group('merge：成功路径', () {
    test('进度单调不减到 1.0、产物在、两条原始流被删', () async {
      final v = stream('v.m4s', 1000);
      final a = stream('a.m4s', 1000);
      final out = pathOf('out.mp4');
      final bat = await fakeFfmpeg(
        name: 'ok.bat',
        outPaths: [out],
        progress: const [
          // 真 ffmpeg 一个块里发多个 key，字节数逐块变大
          'out_time_us=1000000',
          'total_size=500', // 500 / 2000 = 0.25
          'out_time_ms=3000000', // 微秒 → 3 秒（不是 3000 秒）
          'total_size=1500', // 0.75
          'progress=end',
        ],
      );

      final seen = <double>[];
      final r = await BiliMerger(ffmpegPath: bat, commandPrefix: prefix).merge(
        videoPath: v.path,
        audioPath: a.path,
        outPath: out,
        onProgress: seen.add,
      );

      expect(r.ok, isTrue, reason: '${r.message} / ${r.stderr}');
      expect(r.failure, isNull);
      expect(seen, isNotEmpty);
      expect(seen.first, greaterThan(0));
      expect(seen.last, 1.0, reason: 'end 必须把进度补到 1.0');
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThan(seen[i - 1]), reason: '进度不许倒退：$seen');
      }
      expect(seen, containsAll([0.25, 0.75]),
          reason: '分母是两条输入流的字节数，25% 与 75% 两档都要真收到');
      expect(File(out).existsSync(), isTrue);
      expect(File(out).lengthSync(), greaterThan(0));
      expect(r.mediaDuration, const Duration(seconds: 3),
          reason: 'out_time_ms 的实际单位是微秒；按毫秒算这里会变成 3000 秒');
      expect(v.existsSync(), isFalse, reason: '成功后视频流不该再留着');
      expect(a.existsSync(), isFalse, reason: '成功后音频流不该再留着');
    });

    test('两条流都不存在时进度不许算出 >1（分母守卫：读不到回 0 不是 -1）',
        () async {
      // 曾经的真缺陷：单条 _size 读不到回 -1，两笔相加后 `-1 + 1000 = 999`
      // 把「inBytes <= 0」的守卫抵掉，于是 1000/999 > 1，界面进度条直接越界。
      // 这里两条流都**不建**（分母 = 0），脚本却报出大得多的 total_size。
      final seen = <double>[];
      final out = pathOf('outnz.mp4');
      final bat = await fakeFfmpeg(
        name: 'nozip.bat',
        outPaths: [out],
        progress: const ['total_size=999999', 'progress=end'],
      );
      final r = await BiliMerger(ffmpegPath: bat, commandPrefix: prefix).merge(
        videoPath: pathOf('ghost-v.m4s'), // 刻意不创建
        audioPath: pathOf('ghost-a.m4s'),
        outPath: out,
        onProgress: seen.add,
      );
      expect(seen, isNotEmpty, reason: 'end 那一下总该报出来');
      for (final value in seen) {
        expect(value, lessThanOrEqualTo(1.0), reason: '进度越界：$seen');
        expect(value, greaterThanOrEqualTo(0.0), reason: '进度为负：$seen');
      }
      expect(seen, [1.0], reason: '分母无效时除了 end 那一档不该报出任何比例');
      expect(r.ok, isTrue, reason: r.message);
    });

    test('空前缀（生产走的那条形状）：直接 exec 也能把合并跑完', () async {
      // 生产环境 commandPrefix 是空的 —— argv.first 就是要执行的二进制。
      // 这条用例挡住「只有带 cmd /c 前缀时才 work」的实现偏差。
      final v = stream('vdp.m4s', 1000);
      final a = stream('adp.m4s', 1000);
      final out = pathOf('outdp.mp4');
      final bat = await fakeFfmpeg(
        name: 'direct.bat',
        outPaths: [out],
        progress: const ['total_size=1000', 'out_time_us=2000000', 'progress=end'],
      );
      final seen = <double>[];
      final r = await BiliMerger(ffmpegPath: bat).merge(
        videoPath: v.path,
        audioPath: a.path,
        outPath: out,
        onProgress: seen.add,
      );
      expect(r.ok, isTrue, reason: '${r.message} / ${r.stderr}');
      expect(r.commandLine, isNot(startsWith('cmd.exe')),
          reason: '空前缀时命令行里不该出现 cmd');
      expect(seen.last, 1.0);
      expect(r.mediaDuration, const Duration(seconds: 2));
      expect(File(out).existsSync(), isTrue);
      expect(v.existsSync(), isFalse);
      expect(a.existsSync(), isFalse);
    });

    test('产物与视频流同路径时不删成品（同名覆盖的自我保护）', () async {
      final v = stream('same.m4s', 1000);
      final a = stream('same_a.m4s', 1000);
      final bat = await fakeFfmpeg(
        name: 'same.bat',
        outPaths: [v.path],
        progress: const ['progress=end'],
      );
      final r = await BiliMerger(ffmpegPath: bat, commandPrefix: prefix).merge(
        videoPath: v.path,
        audioPath: a.path,
        outPath: v.path,
      );
      expect(r.ok, isTrue, reason: r.message);
      expect(v.existsSync(), isTrue, reason: 'outPath == videoPath 时删它就是删成品');
      expect(a.existsSync(), isFalse);
      expect(r.message, contains('保留'), reason: '这条附注要让用户看得见');
    });
  });

  // ── merge：三种失败形状 ───────────────────────────────────
  group('merge：三种失败形状要能区分，且一律留住原始流', () {
    void expectStreamsKept(File v, File a) {
      expect(v.existsSync(), isTrue, reason: '失败时视频流绝不能删');
      expect(a.existsSync(), isTrue, reason: '失败时音频流绝不能删');
    }

    test('退出码非 0 → exitNonZero，结果带命令行与 stderr 摘要', () async {
      final v = stream('v2.m4s', 1000);
      final a = stream('a2.m4s', 1000);
      final out = pathOf('out2.mp4');
      final bat = await fakeFfmpeg(
        name: 'fail.bat',
        outPaths: [out],
        progress: const ['out_time_us=1000000'],
        exitCode: 5,
        product: FakeProduct.none,
        stderrText: 'fake-ffmpeg-error: Invalid data found when processing input',
      );
      final r = await BiliMerger(ffmpegPath: bat, commandPrefix: prefix).merge(
        videoPath: v.path,
        audioPath: a.path,
        outPath: out,
      );

      expect(r.ok, isFalse);
      expect(r.failure, BiliMergeFailure.exitNonZero);
      expectStreamsKept(v, a);
      expect(r.stderr, contains('Invalid data found'));
      expect(r.message, contains('退出码 5'));
      // 可复现：三条路径 + 关键参数一个都不能少，粘回 cmd 就能重跑
      expect(
        r.commandLine,
        allOf([
          contains(v.path),
          contains(a.path),
          contains(out),
          contains('-movflags +faststart'),
          contains('-progress pipe:1'),
          startsWith('cmd.exe /c '),
        ]),
      );
    });

    test('退出码 0 但没有 progress=end → noEndProgress（进程提前死的形状）',
        () async {
      final v = stream('v3.m4s', 1000);
      final a = stream('a3.m4s', 1000);
      final out = pathOf('out3.mp4');
      final bat = await fakeFfmpeg(
        name: 'noend.bat',
        outPaths: [out],
        // 有进度、有产物，就是缺那一句 end
        progress: const ['out_time_us=2000000', 'total_size=1000'],
        product: FakeProduct.bytes,
      );
      final seen = <double>[];
      final r = await BiliMerger(ffmpegPath: bat, commandPrefix: prefix).merge(
        videoPath: v.path,
        audioPath: a.path,
        outPath: out,
        onProgress: seen.add,
      );

      expect(r.ok, isFalse, reason: '退出码 0 不足以判成功');
      expect(r.failure, BiliMergeFailure.noEndProgress);
      expectStreamsKept(v, a);
      expect(r.mediaDuration, const Duration(seconds: 2));
      expect(seen, isNot(contains(1.0)), reason: '没跑到 end 不许报 100%');
      // 非空残片要留在原地当现场
      expect(File(out).existsSync(), isTrue);
    });

    test('end + 退出码 0 但产物 0 字节 → badProduct，并清掉那个空产物',
        () async {
      final v = stream('v4.m4s', 1000);
      final a = stream('a4.m4s', 1000);
      final out = pathOf('out4.mp4');
      final bat = await fakeFfmpeg(
        name: 'empty.bat',
        outPaths: [out],
        progress: const ['total_size=2000', 'progress=end'],
        product: FakeProduct.empty,
      );
      final r = await BiliMerger(ffmpegPath: bat, commandPrefix: prefix).merge(
        videoPath: v.path,
        audioPath: a.path,
        outPath: out,
      );

      expect(r.ok, isFalse, reason: '只看退出码会把 0 字节判成成功');
      expect(r.failure, BiliMergeFailure.badProduct);
      expect(r.message, contains('0 字节'));
      expectStreamsKept(v, a);
      // 0 字节残片会被清掉：它会让「同名跳过」与重启对账误判成已下好
      expect(File(out).existsSync(), isFalse);
    });

    test('产物压根没被创建 → badProduct 说「不存在」，而不是「0 字节」', () async {
      final v = stream('v4b.m4s', 1000);
      final a = stream('a4b.m4s', 1000);
      final out = pathOf('out4b.mp4');
      final bat = await fakeFfmpeg(
        name: 'nofile.bat',
        outPaths: [out],
        progress: const ['total_size=2000', 'progress=end'],
        product: FakeProduct.none,
      );
      final r = await BiliMerger(ffmpegPath: bat, commandPrefix: prefix).merge(
        videoPath: v.path,
        audioPath: a.path,
        outPath: out,
      );
      expect(r.failure, BiliMergeFailure.badProduct);
      expect(r.message, contains('并不存在'), reason: '两种形状的话术要分开：${r.message}');
      expect(r.message, isNot(contains('0 字节')));
      expectStreamsKept(v, a);
    });

    test('非空残片不删 —— 清理只针对 0 字节那种', () async {
      final v = stream('v5.m4s', 1000);
      final a = stream('a5.m4s', 1000);
      final out = pathOf('out5.mp4');
      final bat = await fakeFfmpeg(
        name: 'partial.bat',
        outPaths: [out],
        progress: const ['out_time_us=1000000'],
        exitCode: 1,
        product: FakeProduct.bytes,
      );
      final r = await BiliMerger(ffmpegPath: bat, commandPrefix: prefix).merge(
        videoPath: v.path,
        audioPath: a.path,
        outPath: out,
      );
      expect(r.failure, BiliMergeFailure.exitNonZero);
      expectStreamsKept(v, a);
      expect(File(out).existsSync(), isTrue, reason: '非空残片是取证材料');
    });
  });

  // ── 闸门 ──────────────────────────────────────────────────
  group('闸门：全局只允许 1 个 ffmpeg', () {
    test('两个 merge 并发时，第二个排在第一个结束之后（计数文件为证）', () async {
      final v = stream('v6.m4s', 1000);
      final a = stream('a6.m4s', 1000);
      final o1 = pathOf('o1.mp4');
      final o2 = pathOf('o2.mp4');
      final mark = pathOf('mark.txt');
      final bat = await fakeFfmpeg(
        name: 'gate.bat',
        outPaths: [o1, o2], // 两次合并都要看见自己的产物
        progress: const ['progress=end'],
        markerPath: mark,
        hold: true,
      );

      final f1 = BiliMerger(ffmpegPath: bat, commandPrefix: prefix).merge(
        videoPath: v.path,
        audioPath: a.path,
        outPath: o1,
      );
      final f2 = BiliMerger(ffmpegPath: bat, commandPrefix: prefix).merge(
        videoPath: v.path,
        audioPath: a.path,
        outPath: o2,
      );

      // 闸门状态可观察：跑着 1 个、排着 1 个（假 ffmpeg 正占着那 1 秒）
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(BiliMerger.runningCountForTest, 1);
      expect(BiliMerger.waitingCountForTest, 1);

      final rs = await Future.wait([f1, f2]);
      expect(rs.map((r) => r.ok).toList(), [true, true],
          reason: rs.map((r) => '${r.message}|${r.stderr}').join('\n'));
      expect(BiliMerger.runningCountForTest, 0);
      expect(BiliMerger.waitingCountForTest, 0, reason: '收尾后不许留着排队计数');

      // 物证：START/END 成对且**不交叠**。并发的话会是 START,START,END,END。
      final lines = markerLines(mark);
      expect(lines.length, 6, reason: '每次运行三行：$lines');
      expect(lines[0], 'START');
      expect(lines[1], startsWith('ARGS=-hide_banner'),
          reason: 'argv 原样到达脚本，说明前缀只是起法、没吃掉参数');
      expect(lines[1], contains('-movflags'));
      expect(lines[2], 'END');
      expect(lines[3], 'START', reason: '第二段必须从第一段的 END 之后才开始');
      expect(lines[5], 'END');
      expect(lines.where((l) => l == 'START').length, 2);
      expect(lines.where((l) => l == 'END').length, 2);
    });

    test('前一次失败不卡闸门，后续请求照常跑', () async {
      final v = stream('v7.m4s', 100);
      final a = stream('a7.m4s', 100);
      final o1 = pathOf('o7a.mp4');
      final o2 = pathOf('o7b.mp4');
      final bad = await fakeFfmpeg(
        name: 'bad.bat',
        outPaths: [o1],
        exitCode: 9,
        product: FakeProduct.none,
      );
      final good = await fakeFfmpeg(
        name: 'good.bat',
        outPaths: [o2],
        progress: const ['progress=end'],
      );
      expect(
        (await BiliMerger(ffmpegPath: bad, commandPrefix: prefix)
                .merge(videoPath: v.path, audioPath: a.path, outPath: o1))
            .ok,
        isFalse,
      );
      final r = await BiliMerger(ffmpegPath: good, commandPrefix: prefix)
          .merge(videoPath: v.path, audioPath: a.path, outPath: o2);
      expect(r.ok, isTrue, reason: '闸门被上一次失败卡住了：${r.message}');
      expect(BiliMerger.runningCountForTest, 0);
      expect(BiliMerger.waitingCountForTest, 0);
    });
  });

  // ── 探测与缺失 ────────────────────────────────────────────
  group('available 探测与 ffmpeg 缺失', () {
    test('ffmpegPath 不存在 → 可读失败，不抛异常、不起进程、不动原始流', () async {
      final v = stream('v8.m4s', 100);
      final a = stream('a8.m4s', 100);
      final missing = '${tmp.path}\\no-such-dir\\ffmpeg.exe';
      final m = BiliMerger(ffmpegPath: missing);
      expect(await m.available, isFalse);

      final r = await m.merge(
        videoPath: v.path,
        audioPath: a.path,
        outPath: pathOf('o8.mp4'),
      );
      expect(r.ok, isFalse);
      expect(r.failure, BiliMergeFailure.ffmpegMissing);
      expect(r.message, contains('没找到 ffmpeg'));
      expect(r.message, contains(missing), reason: '要说清找的是哪个路径');
      expect(r.commandLine, contains('ffmpeg.exe'));
      expect(v.existsSync(), isTrue, reason: '没找到 ffmpeg 时更不许动原始流');
      expect(a.existsSync(), isTrue);
      expect(File(pathOf('o8.mp4')).existsSync(), isFalse);
    });

    test('默认路径（exe 同级 ffmpeg\\ffmpeg.exe）在测试环境里也不崩', () async {
      final m = BiliMerger();
      expect(m.ffmpegPath, defaultFfmpegPath());
      expect(await m.available, isFalse);
      final r = await m.merge(
        videoPath: pathOf('none.m4s'),
        audioPath: pathOf('none2.m4s'),
        outPath: pathOf('o9.mp4'),
      );
      expect(r.ok, isFalse);
      expect(r.failure, BiliMergeFailure.ffmpegMissing);
    });

    test('available 与 merge 口径一致：脚本在时探测为 true', () async {
      final bat = await fakeFfmpeg(
        name: 'avail.bat',
        outPaths: [pathOf('o10.mp4')],
        progress: const ['progress=end'],
      );
      final m = BiliMerger(ffmpegPath: bat, commandPrefix: prefix);
      expect(await m.available, isTrue);
      expect(m.ffmpegPath, bat);
    });
  });

  // 2026-10-11 的真缺陷：`assets/ffmpeg.exe` 一直只躺在 bundle 里，全项目没有
  // 任何一处把它落到盘上，而 NSIS 出包脚本里也 0 处提到 ffmpeg —— 于是开发实例
  // 与装机版**每一次**合并都报 ffmpegMissing（用户侧表现就是「下载完了但成品呢」）。
  group('随包 ffmpeg 的释放（两处找不到的那一种）', () {
    late Directory dataDir;
    late Directory exeDir;

    setUp(() async {
      dataDir = await Directory.systemTemp.createTemp('bili_ffmpeg_sidecar_');
      exeDir = Directory('${dataDir.path}\\exe');
      await exeDir.create(recursive: true);
      // 两个 override 都要给：不给 fallback 会去调 path_provider 的插件通道。
      await AppPaths.init(
        exeDirOverride: exeDir,
        fallbackOverride: dataDir,
      );
    });

    tearDown(() async {
      try {
        await dataDir.delete(recursive: true);
      } on FileSystemException {
        // 已经没了就算了。
      }
    });

    BiliAssetLoader loader(List<int> bytes, {void Function()? onCall}) =>
        (key) async {
          onCall?.call();
          expect(key, kBiliFfmpegAssetKey, reason: '只该读随包那一份资源');
          return ByteData.sublistView(Uint8List.fromList(bytes));
        };

    test('两处都没有 → 释放到 userdata，并用那一份', () async {
      var calls = 0;
      final m = BiliMerger(
        loadAsset: loader(const [70, 77, 80, 71], onCall: () => calls++),
      );
      final p = await m.resolvePath();
      expect(p, sidecarFfmpegPath());
      expect(File(p).existsSync(), isTrue, reason: '释放判据是盘上真有文件，不是返回值');
      expect(File(p).readAsBytesSync(), const [70, 77, 80, 71]);
      expect(calls, 1);
      expect(await m.available, isTrue);
      // 释放之后 ffmpegPath 这个同步取值也必须跟着变，否则 argv 会拼回旧位置。
      expect(m.ffmpegPath, p);
    });

    test('userdata 里已经有一份就不再读资源', () async {
      var calls = 0;
      await File(sidecarFfmpegPath()).writeAsBytes(const [1, 2, 3]);
      final m = BiliMerger(loadAsset: loader(const [9], onCall: () => calls++));
      expect(await m.resolvePath(), sidecarFfmpegPath());
      expect(calls, 0, reason: '重复释放会把 10 MB 白写一遍');
      expect(File(sidecarFfmpegPath()).readAsBytesSync(), const [1, 2, 3]);
    });

    test('读不到资源时不抛异常，落回「没找到 ffmpeg」那句可读失败', () async {
      final m = BiliMerger(
        loadAsset: (key) async => throw StateError('bundle 里没有 $key'),
      );
      expect(await m.available, isFalse);
      final r = await m.merge(
        videoPath: pathOf('none.m4s'),
        audioPath: pathOf('none2.m4s'),
        outPath: pathOf('o11.mp4'),
      );
      expect(r.failure, BiliMergeFailure.ffmpegMissing);
      expect(r.message, contains('没找到 ffmpeg'));
      expect(r.message, contains('释放'), reason: '要说清随包那一份也没能落盘');
      expect(File(sidecarFfmpegPath()).existsSync(), isFalse);
    });

    test('并发只释放一次（两个请求共用同一个 Future）', () async {
      var calls = 0;
      final m = BiliMerger(
        loadAsset: loader(const [4, 5], onCall: () => calls++),
      );
      final two = await Future.wait([m.resolvePath(), m.resolvePath()]);
      expect(two[0], two[1]);
      expect(calls, 1);
    });
  });
}
