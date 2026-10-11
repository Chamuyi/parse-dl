import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_additional.dart';
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
        // 白名单，不是「恰好这两个键」：限速也是 per-task option，但它不是头 ——
        // 落进会话文件只是一个数字，不碰凭据那条线。除这三个之外多带任何东西仍然算串门。
        expect(
          call.options.keys.toSet().difference({
            'referer',
            'user-agent',
            'max-download-limit',
          }),
          isEmpty,
          reason: '来源头与限速之外不许再带任何 per-task option',
        );
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

  group('限速：per-task max-download-limit', () {
    BiliConfig limited(int kbps) => cfg()..speedLimitKbps = kbps;

    test('设了限速 → 两条流都带上，写法是 aria2 认的 512K', () async {
      final env = await boot();
      await env.c.enqueueBiliMedia(biliVideo(), biliAudio(), '冬天', limited(512));
      expect(env.aria.calls, hasLength(2));
      for (final call in env.aria.calls) {
        expect(call.options['max-download-limit'], '512K');
      }
      await env.c.dispose();
    });

    test('0 = 不限，这个 option 干脆不出现', () async {
      final env = await boot();
      await env.c.enqueueBiliMedia(biliVideo(), biliAudio(), '冬天', limited(0));
      expect(env.aria.calls, isNotEmpty);
      for (final call in env.aria.calls) {
        expect(
          call.options.containsKey('max-download-limit'),
          isFalse,
          reason: '传 "0K" 语义相同，但会在会话文件里凭空多出一堆没用的字段',
        );
      }
      await env.c.dispose();
    });

    test('限速记在任务行上，markActive 与改名之后都不许丢', () async {
      // `_submit` 是 addPending 之后立刻 markActive，而这两处都是**整行重建** ——
      // 新字段最容易在这里被悄悄抹掉，那样换源重投就变回全速。
      final env = await boot();
      await env.c.enqueueBiliMedia(biliVideo(), biliAudio(), '冬天', limited(256));
      expect(env.s.tasks, hasLength(2));
      expect(
        env.s.tasks.every((t) => t.speedLimitKbps == 256),
        isTrue,
        reason: '两条流都要带；只有一条带上了等于没有',
      );
      expect(env.s.renameTaskFile(env.s.tasks.first.localId, '改名后的.m4s'), isTrue);
      expect(env.s.tasks.first.speedLimitKbps, 256);
      await env.c.dispose();
    });

    test('带限速时来源头里依然没有任何凭据', () async {
      final env = await boot();
      await env.c.enqueueBiliMedia(biliVideo(), biliAudio(), '冬天', limited(512));
      for (final call in env.aria.calls) {
        expect(call.options.keys, isNot(anyElement(contains('cookie'))));
        expect(call.options.values, isNot(anyElement(contains('SESSDATA'))));
      }
      await env.c.dispose();
    });

    test('限速只读 B 站那份配置：抖音与 X 拿不到它', () async {
      final env = await boot();
      await env.c.enqueueMedia(
        Media(
          id: 'dy-1',
          type: MediaType.video,
          url: 'https://v26-web.douyinvod.com/a.mp4',
          source: 'douyin',
        ),
      );
      expect(
        env.aria.calls.first.options.containsKey('max-download-limit'),
        isFalse,
        reason: '这一期只给 B 站开限速，不许顺手改抖音那条链路的口径',
      );
      await env.c.dispose();
    });
  });

  group('附加文件的产出缝', () {
    /// 走完「两条流都下完」这一步，让协调器真的进到收口。
    Future<void> run(
      Aria2Coordinator c,
      DownloadStore s,
      BiliConfig cfg, {
      Media? video,
    }) async {
      final r = await c.enqueueBiliMedia(
        video ?? biliVideo(),
        biliAudio(),
        '冬天',
        cfg,
      );
      await finish(c, s, r.videoLocalId!, fileName: '冬天.video.m4s');
      await finish(c, s, r.audioLocalId!, fileName: '冬天.audio.m4s');
    }

    test('没勾任何附加文件 → 一次都不调', () async {
      final env = await boot();
      var calls = 0;
      env.c.biliAdditional = ({
        required cfg,
        required saveDir,
        required outBase,
        required video,
      }) async {
        calls++;
        return BiliAdditionalOutcome.none;
      };
      await run(env.c, env.s, cfg());
      expect(calls, 0, reason: '一个格子都没勾还发请求，就是替用户多打一遍接口');
      await env.c.dispose();
    });

    test('注入点是 null（装配层没接）→ 合并照常、一句都不报', () async {
      final env = await boot();
      final settled = <BiliSettleInfo>[];
      env.c.onBiliSettled = settled.add;
      final c2 = cfg()..saveSubtitle = true;
      await run(env.c, env.s, c2);
      expect(env.m.calls, 1, reason: '附加文件没接线不能挡住合并');
      expect(settled.single.kind, BiliSettleKind.merged);
      expect(settled.single.message, isNot(contains('没拿到')));
      await env.c.dispose();
    });

    test('勾了字幕且 cid 拿得到 → 恰好调一次，参数是这一 P 的身份', () async {
      final env = await boot();
      final seen = <String>[];
      BiliConfig? gotCfg;
      env.c.biliAdditional = ({
        required cfg,
        required saveDir,
        required outBase,
        required video,
      }) async {
        seen.add(
          '$outBase|$saveDir|${video.bili?.cid}|${video.bili?.bvid}',
        );
        gotCfg = cfg;
        return const BiliAdditionalOutcome(
          tracks: [],
          written: ['冬天.字幕.srt'],
          missing: [],
        );
      };
      await run(env.c, env.s, cfg()..saveSubtitle = true);
      expect(seen, ['冬天|${tmp.path}|777|BV1xx']);
      expect(gotCfg!.saveSubtitle, isTrue);
      await env.c.dispose();
    });

    test('cid 拿不到（旧行没有 cid）→ 不发请求，也不报缺', () async {
      final env = await boot();
      var calls = 0;
      env.c.biliAdditional = ({
        required cfg,
        required saveDir,
        required outBase,
        required video,
      }) async {
        calls++;
        return BiliAdditionalOutcome.none;
      };
      // 注意是**不带 cid 的那一份 meta**，不能用 `copyWith(bili: null)`：
      // Media.copyWith 里写的是 `bili ?? this.bili`，传 null 等于「不改」，
      // 那样测出来的根本不是「没有身份」这一路。
      await run(
        env.c,
        env.s,
        cfg()..saveCover = true,
        video: biliVideo().copyWith(
          bili: const BiliMeta(
            workTitle: '作品',
            partTitle: '第3P 冬天',
            bvid: 'BV1xx',
            partTotal: 12,
          ),
        ),
      );
      expect(calls, 0, reason: '没有 cid 就没法取字幕与弹幕，硬打只会拿到一堆失败');
      expect(env.m.calls, 1, reason: '主产物不受这一层影响');
      await env.c.dispose();
    });

    test('产出抛异常 → 合并照常成功，收口文案里看得见「没拿到」', () async {
      final env = await boot();
      final settled = <BiliSettleInfo>[];
      env.c.onBiliSettled = settled.add;
      env.c.biliAdditional = ({
        required cfg,
        required saveDir,
        required outBase,
        required video,
      }) async => throw StateError('接口炸了');
      await run(env.c, env.s, cfg()..saveMetadata = true);
      expect(env.m.calls, 1, reason: '附加文件失败不能变成合并失败');
      expect(settled.single.kind, BiliSettleKind.merged);
      expect(settled.single.message, contains('没拿到'),
          reason: '只进日志等于用户看不见（这一层的原罪就是静默）');
      expect(settled.single.message, contains('附加文件没跑起来'));
      await env.c.dispose();
    });

    test('关合并那一路也产侧文件，但内封前提按「没开合并」如实算', () async {
      final env = await boot();
      bool? mergingSaw;
      env.c.biliAdditional = ({
        required cfg,
        required saveDir,
        required outBase,
        required video,
      }) async {
        mergingSaw = cfg.mergeAfterDownload;
        return const BiliAdditionalOutcome(
          tracks: [],
          written: ['冬天.封面.jpg'],
          missing: [],
        );
      };
      await run(env.c, env.s, cfg(merge: false)..saveCover = true);
      expect(mergingSaw, isFalse,
          reason: '这一条压根没有合并步骤，内封的前提必须是「没开合并」而不是别的');
      await env.c.dispose();
    });

    test('durl 退化路径（只有一行）也走这一层', () async {
      final env = await boot();
      var calls = 0;
      env.c.biliAdditional = ({
        required cfg,
        required saveDir,
        required outBase,
        required video,
      }) async {
        calls++;
        return BiliAdditionalOutcome.none;
      };
      // 音频侧没有流 = durl 退化路径，投一条、不建配对。
      // 这里也必须直接造一个不带 `chosen` 的 Media：`copyWith(chosen: null)`
      // 走的是 `??` 语义，传 null 是「不改」，退化路径根本不会被触发。
      final audio = Media(
        id: 'BV1xx-3_audio',
        type: MediaType.audio,
        url: 'https://upos.bilivideo.com/冬天-audio.m4s',
        source: 'bili',
        tweetId: 'BV1xx',
        mediaIndex: 3,
        bili: const BiliMeta(
          workTitle: '作品',
          partTitle: '第3P 冬天',
          bvid: 'BV1xx',
          cid: '777',
          partTotal: 12,
        ),
      );
      final r = await env.c.enqueueBiliMedia(
        biliVideo(),
        audio,
        '冬天',
        cfg()..saveDanmaku = true,
      );
      await finish(env.c, env.s, r.videoLocalId!, fileName: '冬天.mp4');
      expect(calls, 1, reason: '单文件那一条也是成品，用户勾的附加文件照样该出');
      await env.c.dispose();
    });

    test('缺项写在完成那一行的 note 上，重启之后还在', () async {
      final env = await boot();
      env.c.biliAdditional = ({
        required cfg,
        required saveDir,
        required outBase,
        required video,
      }) async => const BiliAdditionalOutcome(
        tracks: [],
        written: [],
        missing: ['字幕'],
      );
      await run(env.c, env.s, cfg()..saveSubtitle = true);

      final row = env.s.tasks.single;
      expect(row.status, DownloadStatus.complete,
          reason: '少一样附加文件不许把已完成的一行标成错误 —— 那会自动重下整条');
      expect(row.note, contains('字幕'));

      // 收口 message 只有失败分支会被读（台账桥接就是那么写的），
      // 所以「用户看得见」这句只能靠 note 这一行来兑现，重启后也必须在。
      final s2 = DownloadStore()..restoreFromJson(env.s.encode());
      expect(s2.tasks.single.note, contains('字幕'));

      await env.c.dispose();
    });

    test('没有缺项时完成行不带 note', () async {
      final env = await boot();
      env.c.biliAdditional = ({
        required cfg,
        required saveDir,
        required outBase,
        required video,
      }) async => const BiliAdditionalOutcome(
        tracks: [],
        written: ['冬天.封面.jpg'],
        missing: [],
      );
      await run(env.c, env.s, cfg()..saveCover = true);
      expect(env.s.tasks.single.note, isNull,
          reason: '一切正常时不该在行尾挂一句多余的说明');
      await env.c.dispose();
    });

    test('容器是 MP4 时内封轨被挡在合并之前，并挂上一条缺项', () async {
      final env = await boot();
      final settled = <BiliSettleInfo>[];
      env.c.onBiliSettled = settled.add;
      env.c.biliAdditional = ({
        required cfg,
        required saveDir,
        required outBase,
        required video,
      }) async => const BiliAdditionalOutcome(
        tracks: [
          BiliEmbeddedTrack(
            fileName: '冬天.字幕.chi.ass',
            title: '中文',
            iso639: 'chi',
            fromDanmaku: false,
          ),
        ],
        written: ['冬天.字幕.chi.ass'],
        missing: [],
      );
      // MP4 塞 ass 的实测后果是「整个文件写不出来」，不是掉一条轨那么轻，
      // 所以这一层必须在起进程之前就把它拦下来。
      await run(
        env.c,
        env.s,
        (cfg()
              ..container = BiliContainer.mp4
              ..saveSubtitle = true
              ..embedSubtitleTrack = true),
      );

      expect(env.m.trackLog.single, isEmpty, reason: '不该把字幕轨递给 ffmpeg');
      expect(env.s.tasks.single.fileName, endsWith('.mp4'));
      expect(settled.single.message, contains('内封轨要 MKV 容器'),
          reason: '拦下来了却不告诉用户，等于他以为内封成功了');
      await env.c.dispose();
    });

    test('MKV 收到字幕轨与章节输入，合并成功后章节中间文件被删掉', () async {
      final env = await boot();
      final chap = File('${tmp.path}${Platform.pathSeparator}chapter_1.txt');
      await chap.writeAsString(';FFMETADATA1\n');
      env.c.biliAdditional = ({
        required cfg,
        required saveDir,
        required outBase,
        required video,
      }) async => BiliAdditionalOutcome(
        tracks: const [
          BiliEmbeddedTrack(
            fileName: '冬天.字幕.chi.ass',
            title: '中文',
            iso639: 'chi',
            fromDanmaku: false,
          ),
        ],
        written: const ['冬天.字幕.chi.ass'],
        missing: const [],
        chapterMetadataPath: chap.path,
      );
      await run(
        env.c,
        env.s,
        (cfg()
              ..container = BiliContainer.mkv
              ..saveSubtitle = true
              ..embedSubtitleTrack = true),
      );

      final got = env.m.trackLog.single;
      expect(got, hasLength(1));
      expect(got.single.path, endsWith('冬天.字幕.chi.ass'));
      expect(got.single.lang, 'chi');
      expect(env.m.chapterLog.single, chap.path);
      expect(env.s.tasks.single.fileName, endsWith('.mkv'),
          reason: '选了 MKV 却落出 .mp4 是没人会报错的那类坏');
      expect(chap.existsSync(), isFalse, reason: '章节那份是给 ffmpeg 当输入的，不是交付物');
      await env.c.dispose();
    });

    test('章节文件删不掉时不许把已成功的合并改判成失败', () async {
      final env = await boot();
      final settled = <BiliSettleInfo>[];
      env.c.onBiliSettled = settled.add;
      // 目录冒充文件：delete() 必抛
      final fake = Directory('${tmp.path}${Platform.pathSeparator}chapter_dir');
      await fake.create();
      env.c.biliAdditional = ({
        required cfg,
        required saveDir,
        required outBase,
        required video,
      }) async => BiliAdditionalOutcome(
        tracks: const [],
        written: const ['x.nfo'],
        missing: const [],
        chapterMetadataPath: fake.path,
      );
      await run(env.c, env.s, cfg()..saveMetadata = true);
      expect(settled.single.kind, BiliSettleKind.merged);
      expect(fake.existsSync(), isTrue, reason: '删不掉就留在原地，别把成功改成失败');
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
      // 用一个**明确带 %EXT% 与 %CODEC%** 的模板：这条测的是「%EXT% 被剥掉、
      // 不会出现 .m4s.mp4」，与默认模板是哪一份无关 —— 早先它借用了默认模板，
      // 2026-10-11 默认收窄之后连带红了（新默认已不带 %CODEC%）。
      const tpl = '<P%P%->%PART_TITLE%-%QUALITY%-%CODEC%%EXT%';
      final base = Aria2Coordinator.biliOutBase(tpl, biliVideo(), BiliConfig());
      expect(base, endsWith('-AVC'), reason: '模板尾部是 -%QUALITY%-%CODEC%%EXT%');
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

  /// 假合并器也要收下新增的两样输入，否则这个 override 直接编译不过。
  /// 单独记账而不改 `_MergeCall` 的形状：那些老断言不该被我这次改动牵连。
  final trackLog = <List<BiliSubtitleInput>>[];
  final chapterLog = <String?>[];

  @override
  Future<BiliMergeResult> merge({
    required String videoPath,
    required String audioPath,
    required String outPath,
    List<BiliSubtitleInput> subtitleTracks = const [],
    String? chapterPath,
    void Function(double p)? onProgress,
  }) async {
    calls++;
    trackLog.add(subtitleTracks);
    chapterLog.add(chapterPath);
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
