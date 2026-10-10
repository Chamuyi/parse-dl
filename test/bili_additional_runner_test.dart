import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/models/bili_meta.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/media_variant.dart';
import 'package:parse_dl/services/bili_additional_runner.dart';

/// 编排层：它唯一的价值是「汇总」，所以测的全是汇总规则，
/// 渲染细节归 `bili_danmaku_test.dart`，解码细节归 `bili_dm_proto_test.dart`。
/// 这一族的编排只吃 [BiliAdditionalDeps]；本文件只开弹幕一族，
/// 所以其余四个口一律给「一发就炸」的桩 —— 它们被叫到了就是回归。
BiliAdditionalDeps danmakuDeps(
  Future<List<int>> Function(int cid, int segmentIndex) segment,
) => BiliAdditionalDeps(
  signedData: (path, params) async {
    throw StateError('弹幕这一族不该发签名请求：$path');
  },
  plainData: (path, params) async {
    throw StateError('弹幕这一族不该发明文请求：$path');
  },
  jsonAtUrl: (url) async => throw StateError('不该取 JSON：$url'),
  bytesAtUrl: (url) async => throw StateError('不该取字节：$url'),
  danmakuSegment: segment,
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bili_addl_runner'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 真夹具：匿名从 `seg.so` 取回来的第 1 段（5 条弹幕）。
  final realBytes = File('test/fixtures/fixture_BV1uzas6vEBB_seg1.bin').readAsBytesSync();

  Media part({String? cid, int durationMs = 60 * 1000}) => Media(
    id: 'BV1xx-1',
    type: MediaType.video,
    url: 'https://upos.bilivideo.com/v.m4s',
    source: 'bili',
    tweetId: 'BV1xx',
    mediaIndex: 1,
    durationMs: durationMs,
    previewUrl: 'https://i0.hdslb.com/bfs/cover.jpg',
    bili: BiliMeta(
      workTitle: '冬天',
      partTitle: '第1P',
      bvid: 'BV1xx',
      cid: cid,
      partTotal: 1,
    ),
    chosen: const MediaVariant(
      urls: ['https://upos.bilivideo.com/v.m4s'],
      kind: VariantKind.bitRate,
      bitrate: 1000000,
      format: 'm4s',
    ),
  );

  BiliConfig cfg({
    bool danmaku = true,
    BiliDanmakuFormat format = BiliDanmakuFormat.ass,
    BiliContainer container = BiliContainer.mkv,
    bool embed = false,
    BiliTrackPriority priority = BiliTrackPriority.subtitleFirst,
  }) => BiliConfig(
    saveDirBase: tmp.path,
    enableSaveFolder: false,
    dirTemplate: '',
    saveDanmaku: danmaku,
    danmakuFormat: format,
    container: container,
    embedSubtitleTrack: embed,
    trackPriority: priority,
  );

  group('弹幕没勾时', () {
    test('一个段都不取，返回空结果', () async {
      var calls = 0;
      final out = await biliProduceAdditional(
        cfg: cfg(danmaku: false),
        saveDir: tmp.path,
        outBase: '冬天',
        video: part(cid: '777'),
        deps: danmakuDeps((cid, segmentIndex) async {
          calls++;
          return realBytes;
        }),
      );
      expect(calls, 0);
      expect(out.tracks, isEmpty);
      expect(out.written, isEmpty);
      expect(out.missing, isEmpty);
      expect(out.hasAnything, isFalse);
    });
  });

  group('身份取不到时不许硬打接口', () {
    test('没有 cid → 一句能看见的话，且不取段', () async {
      var calls = 0;
      final out = await biliProduceAdditional(
        cfg: cfg(),
        saveDir: tmp.path,
        outBase: '冬天',
        video: part(cid: null),
        deps: danmakuDeps((cid, segmentIndex) async {
          calls++;
          return realBytes;
        }),
      );
      expect(calls, 0);
      expect(out.missing, contains(kBiliAdditionalNoCid));
      expect(out.written, isEmpty);
    });

    test('时长为 0 → 分段数算不出来，也不取段', () async {
      var calls = 0;
      final out = await biliProduceAdditional(
        cfg: cfg(),
        saveDir: tmp.path,
        outBase: '冬天',
        video: part(cid: '777', durationMs: 0),
        deps: danmakuDeps((cid, segmentIndex) async {
          calls++;
          return realBytes;
        }),
      );
      expect(calls, 0);
      expect(out.missing, contains(kBiliAdditionalNoDuration));
    });
  });

  group('正常取回', () {
    test('ass 侧文件落盘；没勾内封时轨是空的但**要留下话**', () async {
      final out = await biliProduceAdditional(
        cfg: cfg(embed: false),
        saveDir: tmp.path,
        outBase: '冬天',
        video: part(cid: '777'),
        deps: danmakuDeps((cid, segmentIndex) async => realBytes),
      );
      expect(out.written, hasLength(1));
      expect(
        File('${tmp.path}${Platform.pathSeparator}${out.written.single}').existsSync(),
        isTrue,
      );
      expect(out.tracks, isEmpty);
      // `missing` 的语义是「用户要了却没拿到」。没勾内封是他自己选的，
      // 每次都报一句就是骚扰 —— 报警一旦被稀释，真正缺东西时也没人看了。
      expect(out.missing, isEmpty);
    });

    test('MP4 + 勾了内封：前提缺的那条话必须出现在 missing 里', () async {
      final out = await biliProduceAdditional(
        cfg: cfg(container: BiliContainer.mp4, embed: true),
        saveDir: tmp.path,
        outBase: '冬天',
        video: part(cid: '777'),
        deps: danmakuDeps((cid, segmentIndex) async => realBytes),
      );
      expect(out.tracks, isEmpty);
      expect(out.missing.any((m) => m.contains('MKV')), isTrue,
          reason: '原因文案直接来自 embedBlockReason，不另造说法');
    });

    test('XML 格式时永远没有内封轨，但侧文件照落', () async {
      final out = await biliProduceAdditional(
        cfg: cfg(format: BiliDanmakuFormat.xml, embed: true),
        saveDir: tmp.path,
        outBase: '冬天',
        video: part(cid: '777'),
        deps: danmakuDeps((cid, segmentIndex) async => realBytes),
      );
      expect(out.written.single, endsWith('.xml'));
      expect(out.tracks, isEmpty);
    });

    test('分段数按时长算并逐段取（6 分钟一段）', () async {
      final seen = <int>[];
      await biliProduceAdditional(
        cfg: cfg(),
        saveDir: tmp.path,
        outBase: '冬天',
        video: part(cid: '777', durationMs: 7 * 60 * 1000),
        deps: danmakuDeps((cid, segmentIndex) async {
          seen.add(segmentIndex);
          return realBytes;
        }),
      );
      expect(seen, [1, 2], reason: '7 分钟 = 2 段；段号从 1 起（实测口径）');
    });
  });

  group('汇总规则', () {
    test('内封轨按 trackPriority 排（这一层是唯一排轨序的地方）', () async {
      // 只有一族时看不出顺序，所以这里**直接验 orderTracks 被叫到了**：
      // 弹幕轨的 fromDanmaku 为 true，字幕优先时必须排最后 —— 单族时等价于
      // 「仍然产出这一条」，两族撞名那条组合由 orderTracks 自己的测试覆盖。
      final out = await biliProduceAdditional(
        cfg: cfg(embed: true, priority: BiliTrackPriority.subtitleFirst),
        saveDir: tmp.path,
        outBase: '冬天',
        video: part(cid: '777'),
        deps: danmakuDeps((cid, segmentIndex) async => realBytes),
      );
      expect(out.tracks.single.fromDanmaku, isTrue);
      expect(out.tracks.single.iso639, isEmpty, reason: '弹幕没有语言标签，别乱填 chi');
    });
  });
}
