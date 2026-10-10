import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/models/bili_meta.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/media_variant.dart';
import 'package:parse_dl/services/aria2.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/app_logger.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/bili_merger.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/settings_store.dart';

/// B 站下载链路的集成测试：**两条流入队 → 都下完 → 合并 → 收口两行**。
///
/// 为什么这一层最关键：选流是纯函数（`bili_coordinator_plan_test.dart` 钉着），
/// 合并本身已经用真 ffmpeg 验过（`bili_merge_test.dart`），
/// 而「什么时候调合并、带哪三个路径、成败各怎么收口、重启后还认不认得这对流」
/// 只活在这个协调器里 —— 这一层出错的表现是用户拿到两个放不出声音的裸文件，
/// 或者界面上留着一行指向已经不存在的文件。
///
/// **全部是纯 Dart 的 `test()`，不起真进程、不连真 RPC。**
/// 两个注入缝隙：
///   * `_FakeAria` 换掉传输层（`Aria2Coordinator.withAria2`），
///     `bootstrap` 剩下的装配仍走生产代码；
///   * `_FakeMerger` 换掉 ffmpeg 那一步并记录调用次数与参数。
///
/// 关于「完成」怎么模拟：`Aria2` 那五个事件流是**私有 StreamController**，
/// 假传输层发不出 `onDownloadComplete`，所以测试直接调公开出来的收口入口
/// [Aria2Coordinator.biliStreamFinished] —— 那正是 [_onCompleteAsync] /
/// [reconcile] / [retryTask] 三个生产落点在调的同一个方法（不是只为测试造的旁路）。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bili_merge_link_');
    await AppPaths.init(exeDirOverride: tmp, fallbackOverride: tmp);
    await AppLogger.init(enabled: true);
  });

  tearDown(() async {
    await AppLogger.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ── 素材 ────────────────────────────────────────────────

  /// 视频流那侧的 Media —— 真实链路里由 `biliPairToMedias()` 造，
  /// 这里手写一遍是为了让「协调器只认这两个 Media」这件事本身被钉住。
  Media biliVideo({String base = '冬天'}) => Media(
        id: 'BV1xx-3',
        type: MediaType.video,
        url: 'https://upos.bilivideo.com/$base-video.m4s',
        altUrls: ['https://backup.bilivideo.com/$base-video.m4s'],
        source: 'bili',
        tweetId: 'BV1xx',
        tweetText: '把一年的海边拍成十二段',
        userName: '海边的猫',
        mediaIndex: 3,
        bili: const BiliMeta(
          workTitle: '作品',
          partTitle: '第3P 冬天',
          bvid: 'BV1xx',
          cid: '777',
          partTotal: 12,
          qualityLabel: '1080P',
          codecLabel: 'AVC',
        ),
        chosen: const MediaVariant(
          urls: [
            'https://upos.bilivideo.com/video.m4s',
            'https://backup.bilivideo.com/video.m4s',
          ],
          kind: VariantKind.bitRate,
          width: 1920,
          height: 1080,
          bitrate: 3000000,
          format: 'm4s',
        ),
      );

  Media biliAudio({String base = '冬天'}) => Media(
        id: 'BV1xx-3_audio',
        type: MediaType.audio,
        url: 'https://upos.bilivideo.com/$base-audio.m4s',
        altUrls: ['https://backup.bilivideo.com/$base-audio.m4s'],
        source: 'bili',
        tweetId: 'BV1xx',
        tweetText: '把一年的海边拍成十二段',
        userName: '海边的猫',
        mediaIndex: 3,
        bili: const BiliMeta(
          workTitle: '作品',
          partTitle: '第3P 冬天',
          bvid: 'BV1xx',
          cid: '777',
          partTotal: 12,
        ),
        chosen: const MediaVariant(
          urls: [
            'https://upos.bilivideo.com/audio.m4s',
            'https://backup.bilivideo.com/audio.m4s',
          ],
          kind: VariantKind.audio,
          bitrate: 192000,
          format: 'm4s',
        ),
      );

  BiliConfig cfg({bool merge = true}) => BiliConfig(
        saveDirBase: tmp.path,
        enableSaveFolder: false,
        dirTemplate: '',
        mergeAfterDownload: merge,
      );

  /// 起一套「假 aria2 + 假 merger + 真 store」的装配。
  Future<({Aria2Coordinator c, DownloadStore s, _FakeAria aria, _FakeMerger m})>
      boot({
    _FakeMerger? merger,
    DownloadStore? store,
    _FakeAria? aria,
  }) async {
    final a = aria ?? _FakeAria();
    final _FakeMerger fake = merger ?? _FakeMerger();
    final s = store ?? (DownloadStore()..setSaveDir(tmp.path));
    final c = Aria2Coordinator.withAria2(a, biliMerger: fake);
    await c.bootstrap(store: s, settings: SettingsStore());
    return (c: c, s: s, aria: a, m: fake);
  }

  /// 把一行标成「下完了」并走一次生产收口入口。
  Future<void> finish(
    Aria2Coordinator c,
    DownloadStore s,
    String localId, {
    required String fileName,
  }) async {
    final t = s.task(localId)!;
    // 真下载会把文件落到磁盘上：合并前要 stat 一次原始流在不在，
    // 所以这里也得造出两个有内容的假裸流。
    await File(t.fullPath).writeAsString('stream-bytes');
    s.markComplete(t.aria2Gid!);
    await c.biliStreamFinished(localId);
  }

  Future<void> waitUntil(Future<bool> Function() done, String why) async {
    for (var i = 0; i < 400 && !await done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(await done(), isTrue, reason: '超时：$why');
  }

  Future<String> logText() async {
    await AppLogger.flushForTest();
    return await File(await AppLogger.currentFilePath()).readAsString();
  }

  group('入队两条流', () {
    test('DownloadStore 里出现两行，名字是 <base>.video.m4s / <base>.audio.m4s', () async {
      final env = await boot();
      final r = await env.c.enqueueBiliMedia(
        biliVideo(),
        biliAudio(),
        '冬天',
        cfg(),
      );

      expect(r.outcome, EnqueueOutcome.queued);
      expect(r.videoLocalId, isNotNull);
      expect(r.audioLocalId, isNotNull);
      expect(env.s.tasks.length, 2, reason: '两条都是正常可见的任务行');

      final names = env.s.tasks.map((t) => t.fileName).toSet();
      expect(names, {'冬天.video.m4s', '冬天.audio.m4s'});
      expect(r.outPath, '${tmp.path}${Platform.pathSeparator}冬天.mp4');

      await env.c.dispose();
    });

    test('两行各自走一次 addUri，用的是各自那条流的地址', () async {
      final env = await boot();
      await env.c.enqueueBiliMedia(biliVideo(), biliAudio(), '冬天', cfg());

      expect(env.aria.calls.length, 2);
      final outs = env.aria.calls.map((e) => e.out).toList();
      expect(outs, ['冬天.video.m4s', '冬天.audio.m4s']);
      expect(env.aria.calls[0].url, contains('video.m4s'));
      expect(env.aria.calls[1].url, contains('audio.m4s'),
          reason: '两条行必须下各自的流，写成同一个地址就是下了两遍视频流');
      // 音频行的地址取的是 altUrls 之前的首选 —— 换源重试的候选链也在里面
      expect(env.aria.calls[1].url, isNot(env.aria.calls[0].url));

      await env.c.dispose();
    });

    test('音频流入队失败 → 不回滚视频那条，如实说明只进去一半', () async {
      final aria = _FakeAria(rejectSecond: true);
      final env = await boot(aria: aria);

      final r = await env.c.enqueueBiliMedia(
        biliVideo(),
        biliAudio(),
        '冬天',
        cfg(),
      );

      expect(r.outcome, EnqueueOutcome.rejected);
      expect(r.videoLocalId, isNotNull, reason: '已经在下的那条不该被悄悄丢掉');
      expect(r.message, contains('音频'));
      expect(env.s.tasks.length, 2, reason: '失败那行也留在界面上，用户才点得到重试');
      expect(env.s.tasks.last.status, DownloadStatus.error);

      await env.c.dispose();
    });
  });

  group('合并的触发时机', () {
    test('只完成一条 → 不合并', () async {
      final env = await boot();
      final r = await env.c.enqueueBiliMedia(
        biliVideo(),
        biliAudio(),
        '冬天',
        cfg(),
      );

      await finish(
        env.c,
        env.s,
        r.videoLocalId!,
        fileName: '冬天.video.m4s',
      );

      expect(env.m.calls, 0, reason: '缺一路输入就合，出来的是个放不出声音的空壳');
      expect(env.s.tasks.length, 2);

      await env.c.dispose();
    });

    test('两条都完成 → 合并被调用一次，参数是两个临时名与最终的 <base>.mp4', () async {
      final env = await boot();
      final r = await env.c.enqueueBiliMedia(
        biliVideo(),
        biliAudio(),
        '冬天',
        cfg(),
      );
      await finish(env.c, env.s, r.videoLocalId!, fileName: '冬天.video.m4s');
      await finish(env.c, env.s, r.audioLocalId!, fileName: '冬天.audio.m4s');

      expect(env.m.calls, 1);
      final call = env.m.seen.single;
      expect(call.videoPath, '${tmp.path}${Platform.pathSeparator}冬天.video.m4s');
      expect(call.audioPath, '${tmp.path}${Platform.pathSeparator}冬天.audio.m4s');
      expect(call.outPath, '${tmp.path}${Platform.pathSeparator}冬天.mp4');

      await env.c.dispose();
    });

    test('同一对重复收到完成事件也不会合第二次', () async {
      final env = await boot();
      final r = await env.c.enqueueBiliMedia(
        biliVideo(),
        biliAudio(),
        '冬天',
        cfg(),
      );
      await finish(env.c, env.s, r.videoLocalId!, fileName: '冬天.video.m4s');
      await finish(env.c, env.s, r.audioLocalId!, fileName: '冬天.audio.m4s');
      // aria2 的引擎级重试会把同一个完成事件再推一遍
      await env.c.biliStreamFinished(r.audioLocalId!);
      await env.c.biliStreamFinished(r.videoLocalId!);

      expect(env.m.calls, 1, reason: '合两次就是把 ffmpeg 的成品再盖一遍');

      await env.c.dispose();
    });

    test('mergeAfterDownload=false → 两条都完成后不调用合并', () async {
      final env = await boot();
      final r = await env.c.enqueueBiliMedia(
        biliVideo(),
        biliAudio(),
        '冬天',
        cfg(merge: false),
      );
      await finish(env.c, env.s, r.videoLocalId!, fileName: '冬天.video.m4s');
      await finish(env.c, env.s, r.audioLocalId!, fileName: '冬天.audio.m4s');

      expect(env.m.calls, 0);
      expect(env.s.tasks.map((t) => t.fileName).toSet(), {
        '冬天.video.m4s',
        '冬天.audio.m4s',
      }, reason: '关掉开关时两行就是裸流，界面语义得按裸流显示');
      expect(env.s.tasks.every((t) => t.status == DownloadStatus.complete), isTrue);

      await env.c.dispose();
    });
  });

  group('合并成功后的收口', () {
    test('视频行改名 <base>.mp4、音频行被移除、并且 notifyListeners 过', () async {
      final env = await boot();
      var notified = 0;
      env.s.addListener(() => notified++);

      final r = await env.c.enqueueBiliMedia(
        biliVideo(),
        biliAudio(),
        '冬天',
        cfg(),
      );
      // 从入队之后才开始计数：入队那两步自己就会 notify，
      // 拿「总共 notify 过几次」当断言永远为真，等于没测。
      final before = notified;
      await finish(env.c, env.s, r.videoLocalId!, fileName: '冬天.video.m4s');
      await finish(env.c, env.s, r.audioLocalId!, fileName: '冬天.audio.m4s');

      expect(notified, greaterThan(before),
          reason: '改名与删行必须让界面重建，否则用户还看见 .m4s');
      expect(env.s.tasks.length, 1, reason: '音频行收掉：它的文件已经被合并器删了');
      final kept = env.s.tasks.single;
      expect(kept.fileName, '冬天.mp4');
      expect(kept.status, DownloadStatus.complete);
      // 改名不是「换一行」：localId 与 gid 都还是视频那条自己的，
      // 否则「打开所在文件夹」与按创建时间排序都会跳到别的行为上。
      expect(kept.localId, r.videoLocalId);
      expect(kept.aria2Gid, isNotNull);

      await env.c.dispose();
    });

    test('收口回调给出 merged，且带着视频侧的 Media（台账 markDone 靠它的键组）', () async {
      final env = await boot();
      final settled = <BiliSettleInfo>[];
      env.c.onBiliSettled = settled.add;

      final r = await env.c.enqueueBiliMedia(
        biliVideo(),
        biliAudio(),
        '冬天',
        cfg(),
      );
      await finish(env.c, env.s, r.videoLocalId!, fileName: '冬天.video.m4s');
      await finish(env.c, env.s, r.audioLocalId!, fileName: '冬天.audio.m4s');

      final s = settled.single;
      expect(s.kind, BiliSettleKind.merged);
      expect(s.outBase, '冬天');
      expect(s.media.bili!.bvid, 'BV1xx');
      expect(s.media.bili!.cid, '777');

      await env.c.dispose();
    });

    test('不合并时回调给的是 streamsKept，而不是假装 merged', () async {
      final env = await boot();
      final settled = <BiliSettleInfo>[];
      env.c.onBiliSettled = settled.add;

      final r = await env.c.enqueueBiliMedia(
        biliVideo(),
        biliAudio(),
        '冬天',
        cfg(merge: false),
      );
      await finish(env.c, env.s, r.videoLocalId!, fileName: '冬天.video.m4s');
      await finish(env.c, env.s, r.audioLocalId!, fileName: '冬天.audio.m4s');

      expect(settled.single.kind, BiliSettleKind.streamsKept);

      await env.c.dispose();
    });
  });

  group('合并失败时必须什么都没丢', () {
    test('两行都还在、都还是 .m4s、结果里带 ffmpeg 命令行、日志文件写了原因', () async {
      final env = await boot(merger: _FakeMerger(ok: false));
      final settled = <BiliSettleInfo>[];
      env.c.onBiliSettled = settled.add;

      final r = await env.c.enqueueBiliMedia(
        biliVideo(),
        biliAudio(),
        '冬天',
        cfg(),
      );
      await finish(env.c, env.s, r.videoLocalId!, fileName: '冬天.video.m4s');
      await finish(env.c, env.s, r.audioLocalId!, fileName: '冬天.audio.m4s');

      expect(env.s.tasks.length, 2, reason: '字节已经到手，失败不能把任何一条流判没');
      expect(env.s.tasks.map((t) => t.fileName).toSet(), {
        '冬天.video.m4s',
        '冬天.audio.m4s',
      });
      expect(env.s.tasks.every((t) => t.status == DownloadStatus.complete), isTrue,
          reason: '下载是成功的，失败的是合并');
      // 两条裸流文件仍在磁盘上
      expect(File('${tmp.path}${Platform.pathSeparator}冬天.video.m4s').existsSync(), isTrue);
      expect(File('${tmp.path}${Platform.pathSeparator}冬天.audio.m4s').existsSync(), isTrue);

      final s = settled.single;
      expect(s.kind, BiliSettleKind.mergeFailed);
      expect(s.commandLine, contains('ffmpeg'), reason: '可复现的命令行必须回到调用方手里');
      expect(s.message, contains('合并失败'));

      // **写进日志文件**而不是只 debugPrint：这一条失败在用户那边是没有弹层的
      final text = await logText();
      expect(text, contains('合并失败'));
      expect(text, contains('ffmpeg'), reason: '日志里要能直接复制出重跑的命令');
      expect(text, contains('Invalid data'), reason: 'stderr 摘要也得进去');

      await env.c.dispose();
    });
  });

  group('红线：B 站分支不许带 cookie', () {
    test('B 站媒体拿到 referer + user-agent', () async {
      final env = await boot();
      await env.c.enqueueBiliMedia(biliVideo(), biliAudio(), '冬天', cfg());

      for (final call in env.aria.calls) {
        expect(call.options['referer'], 'https://www.bilibili.com/');
        expect(call.options['user-agent'], isNotEmpty);
      }

      await env.c.dispose();
    });

    test('返回的 header 里不存在任何 cookie 键 —— 一个都不许有', () async {
      final env = await boot();
      await env.c.enqueueBiliMedia(biliVideo(), biliAudio(), '冬天', cfg());

      for (final call in env.aria.calls) {
        expect(call.options.keys, isNot(anyElement(contains('cookie'))),
            reason: 'per-task header 会被 --save-session 逐条原样写进会话文件，'
                'Cookie 进去就是明文落盘');
        expect(call.options.values, isNot(anyElement(contains('SESSDATA'))));
        expect(call.options.values, isNot(anyElement(contains('bili_jct'))));
        expect(call.options.keys.toSet(), {'referer', 'user-agent'},
            reason: '除来源头之外不许多带任何东西');
      }

      await env.c.dispose();
    });

    test('抖音与 X 的既有口径不受影响', () async {
      final env = await boot();
      await env.c.enqueueMedia(
        Media(
          id: 'dy-1',
          type: MediaType.video,
          url: 'https://v26-web.douyinvod.com/a.mp4',
          source: 'douyin',
        ),
      );
      await env.c.enqueueMedia(
        Media(
          id: 'x-1',
          type: MediaType.image,
          url: 'https://pbs.twimg.com/media/a.jpg',
        ),
      );

      expect(env.aria.calls.first.options['referer'], 'https://www.douyin.com/');
      expect(env.aria.calls.last.options, isEmpty, reason: 'X 不需要来源头');

      await env.c.dispose();
    });
  });

  group('重启后的配对', () {
    test('进程内表丢了 → 按文件名重建配对并合出成品', () async {
      // 第一段：入队两条，然后把两行都标成完成 —— 但**不走**收口入口，
      // 这就是「两条流都下完了、应用却在合并之前被关掉」的那个现场。
      final env1 = await boot();
      final r = await env1.c.enqueueBiliMedia(
        biliVideo(),
        biliAudio(),
        '冬天',
        cfg(),
      );
      final s1 = env1.s;
      s1.markComplete(s1.task(r.videoLocalId!)!.aria2Gid!);
      s1.markComplete(s1.task(r.audioLocalId!)!.aria2Gid!);
      final snapshot = s1.encode();
      await env1.c.dispose();
      // 两条裸流的文件在真机上就是在那儿的（合并从没跑过，谁也没删它们）。
      await File('${tmp.path}${Platform.pathSeparator}冬天.video.m4s')
          .writeAsString('video-stream');
      await File('${tmp.path}${Platform.pathSeparator}冬天.audio.m4s')
          .writeAsString('audio-stream');

      // 第二段：**新建一个协调器**（进程内配对表是空的），只把任务表读回来。
      final s2 = DownloadStore()..setSaveDir(tmp.path);
      s2.restoreFromJson(snapshot);
      expect(s2.tasks.length, 2, reason: '前置条件：两行都恢复出来了');
      final merger2 = _FakeMerger();
      final env2 = await boot(store: s2, merger: merger2);
      final settled = <BiliSettleInfo>[];
      env2.c.onBiliSettled = settled.add;

      // `bootstrap` 里那一步重建是 unawaited 的（不能让 ffmpeg 挡住开窗）。
      await waitUntil(
          () async => merger2.calls > 0 || settled.isNotEmpty, '重启后没有重建配对');

      expect(merger2.calls, 1, reason: '两条都在盘上且都下完了，重启就该把成品合出来');
      expect(merger2.seen.single.videoPath,
          '${tmp.path}${Platform.pathSeparator}冬天.video.m4s');
      await waitUntil(() async => settled.isNotEmpty, '收口没回调');
      expect(settled.single.kind, BiliSettleKind.merged);
      expect(s2.tasks.single.fileName, '冬天.mp4');

      await env2.c.dispose();
    });

    test('只回来一条时：日志里有那一条，另一行保持已完成、不假装合好了', () async {
      final s = DownloadStore()..setSaveDir(tmp.path);
      // 只有视频流那一行（音频行上次就没进去 / 被删了）。
      s.addPending(biliVideo(), tmp.path, fileName: '冬天.video.m4s');
      final t = s.tasks.single;
      s.markActive(t.localId, 'gid-v');
      s.markComplete('gid-v');
      await File(t.fullPath).writeAsString('video-stream');
      final snapshot = s.encode();

      final s2 = DownloadStore()..setSaveDir(tmp.path);
      s2.restoreFromJson(snapshot);
      final merger = _FakeMerger();
      final env = await boot(store: s2, merger: merger);
      final settled = <BiliSettleInfo>[];
      env.c.onBiliSettled = settled.add;

      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(merger.calls, 0, reason: '缺一路输入不能合');
      expect(settled, isEmpty, reason: '不能报「已合并」');
      expect(s2.tasks.single.fileName, '冬天.video.m4s',
          reason: '界面保持「已完成（未合并）」，等用户重下另一条');
      final text = await logText();
      expect(text, contains('冬天'), reason: '必须如实留下一行「配对不全」的记录');
      expect(text, contains('未合并'));

      await env.c.dispose();
    });
  });

  group('base 名的渲染', () {
    test('模板里的 %EXT% 被剥掉，不会出现 .m4s.mp4 这种名字', () async {
      final env = await boot();
      final base = Aria2Coordinator.biliOutBase(
        kBiliDefaultFileNameTemplate,
        biliVideo(),
        BiliConfig(),
      );
      expect(base, endsWith('-AVC'), reason: '默认模板尾部是 -%QUALITY%-%CODEC%%EXT%');
      expect(base, isNot(contains('.m4s')));
      expect(base, isNot(contains('.mp4')));

      await env.c.enqueueBiliMedia(biliVideo(), biliAudio(), base, cfg());
      expect(env.s.tasks.map((t) => t.fileName).toSet(),
          {'$base.video.m4s', '$base.audio.m4s'});

      await env.c.dispose();
    });

    test('文件夹模板里的 / 仍然是层级分隔符（整串清洗会吃掉它，所以没用它）', () async {
      final env = await boot();
      final cfg2 = BiliConfig(
        saveDirBase: tmp.path,
        enableSaveFolder: true,
        dirTemplate: '海边的猫/冬天',
      );

      await env.c.enqueueBiliMedia(biliVideo(), biliAudio(), '冬天', cfg2);

      final dir = Directory(
          '${tmp.path}${Platform.pathSeparator}海边的猫${Platform.pathSeparator}冬天');
      expect(dir.existsSync(), isTrue, reason: '两段文件夹名各自净化、分隔符本身不许被换掉');
      expect(env.s.tasks.first.saveDir, dir.path);

      await env.c.dispose();
    });
  });
}

/// 假传输层：只换掉「进程 + RPC」，`bootstrap` 的其余装配走生产代码。
class _FakeAria extends Aria2 {
  _FakeAria({this.rejectSecond = false});

  /// true = 第二次 `addUri` 抛错（模拟只进去一半那种局面）。
  final bool rejectSecond;

  final calls = <_AddCall>[];

  @override
  Future<void> bootstrap() async {}

  @override
  Future<String> addUri(
    String url, {
    required String dir,
    required String out,
    Map<String, String>? options,
  }) async {
    if (rejectSecond && calls.length == 1) {
      throw StateError('aria2 调用 aria2.addUri 失败：拒绝任务');
    }
    calls.add((url: url, dir: dir, out: out, options: options ?? const {}));
    return 'gid-${calls.length}';
  }

  @override
  Future<void> remove(String gid) async {}

  @override
  Future<void> updateConcurrency(int value) async {}

  @override
  Future<bool> dispose() async => true;
}

typedef _AddCall = ({
  String url,
  String dir,
  String out,
  Map<String, String> options,
});

typedef _MergeCall = ({String videoPath, String audioPath, String outPath});

/// 假合并器：只记「被调了几次、带的是哪三个路径」，成功时照真货的样子
/// 写出产物并删掉两条原始流 —— 「产物已存在就别重复合」那条判据依赖这个行为。
class _FakeMerger extends BiliMerger {
  _FakeMerger({this.ok = true}) : super();

  final bool ok;
  int calls = 0;
  final seen = <_MergeCall>[];

  @override
  Future<BiliMergeResult> merge({
    required String videoPath,
    required String audioPath,
    required String outPath,
    void Function(double p)? onProgress,
  }) async {
    calls++;
    seen.add(
      (videoPath: videoPath, audioPath: audioPath, outPath: outPath),
    );
    if (!ok) {
      return const BiliMergeResult(
        ok: false,
        failure: BiliMergeFailure.exitNonZero,
        message: 'ffmpeg 退出码 1（合并失败）。两条原始流已保留。',
        commandLine:
            r'"C:\ffmpeg\ffmpeg.exe" -i a.m4s -i b.m4s -c copy out.mp4"',
        stderr: 'a.m4s: Invalid data found when processing input',
      );
    }
    await File(outPath).writeAsString('merged-mp4');
    for (final path in [videoPath, audioPath]) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
    return const BiliMergeResult(
      ok: true,
      commandLine: r'"C:\ffmpeg\ffmpeg.exe" -i a.m4s -i b.m4s out.mp4"',
    );
  }
}
