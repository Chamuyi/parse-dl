import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/models/bili_meta.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/media_variant.dart';
import 'package:parse_dl/services/bili_additional_runner.dart';
import 'package:parse_dl/services/bili_chapter.dart';
import 'package:parse_dl/services/bili_cover.dart';

/// 附加文件这一层的测试：编排（谁该被叫、缺项怎么说）+ 四个写入器本身。
///
/// 全用注入的假取数口，**不发真实请求**。真实那一次要等登录档那一轮
/// （匿名实测拿不到字幕，见取证 Q4），所以这里给的都是夹具级证据。
void main() {
  final pngMagic = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bili_files'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Media video({String? cid, int durationMs = 60 * 1000, String? pic = 'https://i0.hdslb.com/c.jpg'}) =>
      Media(
        id: 'BV1xx-1',
        type: MediaType.video,
        url: 'https://upos.bilivideo.com/v.m4s',
        source: 'bili',
        tweetId: 'BV1xx',
        mediaIndex: 1,
        durationMs: durationMs,
        previewUrl: pic,
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

  BiliAdditionalDeps depsOf({
    Map<String, dynamic>? player,
    Map<String, dynamic>? view,
    Map<String, dynamic>? subtitleBody,
    List<int> Function(String url)? bytes,
    List<int> Function(int cid, int index)? seg,
    List<String> called = const [],
    Map<String, dynamic>? tags,
  }) => BiliAdditionalDeps(
    signedData: (path, params) async {
      if (path == '/x/player/wbi/v2') return player ?? const {};
      if (path == '/x/web-interface/wbi/view') return view ?? const {};
      throw StateError('不该打这一支：$path');
    },
    plainData: (path, params) async {
      if (path == '/x/web-interface/view/detail/tag') return tags ?? const {'data': []};
      throw StateError('不该打这一支：$path');
    },
    jsonAtUrl: (url) async {
      // 协议相对地址必须在到达这里之前被补成 https:，否则真机上必然取不到
      expect(url.startsWith('//'), isFalse, reason: 'subtitle_url 的 // 前缀没被补全：$url');
      return subtitleBody ?? const {};
    },
    bytesAtUrl: (url) async => bytes == null ? pngMagic : bytes(url),
    danmakuSegment: (cid, index) async => seg == null ? const <int>[] : seg(cid, index),
  );

  BiliConfig cfgOf({bool mkv = false, bool embed = false}) => BiliConfig()
    ..container = mkv ? BiliContainer.mkv : BiliContainer.mp4
    ..embedSubtitleTrack = embed
    ..saveDirBase = tmp.path
    ..enableSaveFolder = false
    ..dirTemplate = '';

  String read(String name) =>
      File('${tmp.path}${Platform.pathSeparator}$name').readAsStringSync();

  // ── 字幕 ────────────────────────────────────────────────────

  group('字幕', () {
    final player = {
      'subtitle': {
        'subtitles': [
          {
            'lan': 'zh-CN',
            'lan_doc': '中文',
            'subtitle_url': '//xyz.mcdn.bilibili.com/1.json',
          },
          {
            'lan': 'ai-es',
            'lan_doc': '西班牙语',
            'subtitle_url': '//xyz.mcdn.bilibili.com/2.json',
          },
        ],
      },
    };
    final body = {
      'body': [
        {'content': '第二句', 'start_time': 2.5, 'end_time': 4.0},
        {'content': '第一句', 'start_time': 0.5, 'end_time': 2.0},
      ],
    };

    test('srt：按时间排好，时间戳是 HH:MM:SS,mmm', () async {
      final out = await biliProduceAdditional(
        cfg: cfgOf()..saveSubtitle = true,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: depsOf(player: player, subtitleBody: body),
      );
      expect(out.written, hasLength(2));
      final srt = read('冬天.字幕.zh-CN.srt');
      expect(srt, startsWith('1\n00:00:00,500 --> 00:00:02,000'));
      expect(srt, contains('2\n00:00:02,500 --> 00:00:04,000'));
      expect(out.missing, isEmpty);
    });

    test('仅人工字幕：ai- 那一条整个不取', () async {
      final out = await biliProduceAdditional(
        cfg: cfgOf()
          ..saveSubtitle = true
          ..subtitleManualOnly = true,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: depsOf(player: player, subtitleBody: body),
      );
      expect(out.written, ['冬天.字幕.zh-CN.srt']);
    });

    test('按语言筛：只勾 es 时人工 zh 那条不该被捞进来（前缀要能对上）', () async {
      final out = await biliProduceAdditional(
        cfg: cfgOf()
          ..saveSubtitle = true
          ..subtitleLangs = ['es'],
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: depsOf(player: player, subtitleBody: body),
      );
      expect(out.written, ['冬天.字幕.ai-es.srt']);
    });

    test('MKV + ass + 勾内封：登记成轨，语言码归一到 ISO 639-2，AI 那条标题要标出来', () async {
      final out = await biliProduceAdditional(
        cfg: cfgOf(mkv: true, embed: true)
          ..saveSubtitle = true
          ..subtitleFormat = BiliSubtitleFormat.ass,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: depsOf(player: player, subtitleBody: body),
      );
      expect(out.tracks, hasLength(2));
      final byName = {for (final t in out.tracks) t.fileName: t};
      expect(byName['冬天.字幕.zh-CN.ass']!.iso639, 'chi');
      expect(byName['冬天.字幕.zh-CN.ass']!.title, '中文');
      expect(byName['冬天.字幕.ai-es.ass']!.title, '西班牙语（AI）',
          reason: 'lan_doc 与人工字幕同名，不标注的话菜单里会出现两条一样的名字');
      expect(byName['冬天.字幕.ai-es.ass']!.iso639, 'spa',
          reason: 'ai- 前缀不能污染 ISO 639-2 的换算');
      expect(read('冬天.字幕.zh-CN.ass'), contains('[Events]'));
    });

    test('MP4 却勾了内封：侧文件照落，但缺项要说清缺的是容器', () async {
      final out = await biliProduceAdditional(
        cfg: cfgOf(mkv: false, embed: true)
          ..saveSubtitle = true
          ..subtitleFormat = BiliSubtitleFormat.ass,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: depsOf(player: player, subtitleBody: body),
      );
      expect(out.tracks, isEmpty);
      expect(out.written, hasLength(2));
      expect(out.missing.every((m) => m.contains('MKV')), isTrue);
    });

    test('接口一条都不给时，这句话要出现在缺项里（匿名实测就是这个形状）', () async {
      final out = await biliProduceAdditional(
        cfg: cfgOf()..saveSubtitle = true,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: depsOf(player: const {}),
      );
      expect(out.written, isEmpty);
      expect(out.missing.single, contains('字幕'));
    });
  });

  // ── 章节 ────────────────────────────────────────────────────

  group('章节', () {
    test('view_points 空 → 不产出、也不报警（这是常态）', () async {
      final out = await biliProduceAdditional(
        cfg: cfgOf()..saveChapter = true,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: depsOf(player: const {'view_points': []}),
      );
      expect(out.chapterMetadataPath, isNull);
      expect(out.missing, isEmpty, reason: '九成稿件没有章节，每次都报就是噪声');
    });

    test('接口的 from/to 是秒：写出去必须乘回毫秒', () {
      final text = biliChaptersToFfmetadata([
        {'from': 0, 'to': 30, 'content': '开场'},
        {'from': 30, 'to': 0, 'content': '正片'},
        {'from': 50, 'to': 999999, 'content': '越界'},
      ], 60)!;
      expect(text, startsWith(';FFMETADATA1'));
      expect(text, contains('START=0\nEND=30000'));
      expect(
        text,
        contains('START=30000\nEND=50000'),
        reason: '末段 to=0 时先拿下一段的起点兜底，比直接拉到片尾更准',
      );
      expect(
        text,
        contains('START=50000\nEND=59999'),
        reason: '越界的 to 夹到总时长，再往前挪 1ms（贴着片尾的 END 一样会告警）',
      );
      expect(text.split('[CHAPTER]').length - 1, 3);
    });

    test('标题里的 ffmetadata 元字符要转义，别把 title 变成新键值', () {
      final text = biliChaptersToFfmetadata([
        {'from': 0, 'to': 10, 'content': 'a=b; c#d'},
      ], 60)!;
      expect(text, contains(r'title=a\=b\; c\#d'));
    });

    test('定不出长度的越界段整段跳过，不写出一条 0 秒章节', () {
      final text = biliChaptersToFfmetadata([
        {'from': 10, 'to': 5},
      ], 0);
      expect(text, isNull);
    });

    test('有章节时落一个中间文件，路径交出去给合并层', () async {
      final out = await biliProduceAdditional(
        cfg: cfgOf()..saveChapter = true,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: depsOf(
          player: {
            'view_points': [
              {'from': 0, 'to': 20, 'content': '第一章'},
            ],
          },
        ),
      );
      expect(out.chapterMetadataPath, isNotNull);
      expect(File(out.chapterMetadataPath!).existsSync(), isTrue);
      expect(
        File(out.chapterMetadataPath!).readAsStringSync(),
        contains('title=第一章'),
      );
    });
  });

  // ── 封面 ────────────────────────────────────────────────────

  group('封面', () {
    test('按图床的后缀缩放写法取，落成 `<base>.封面.png`', () async {
      final seen = <String>[];
      final out = await biliProduceAdditional(
        cfg: cfgOf()
          ..saveCover = true
          ..coverFormat = BiliCoverFormat.png,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: depsOf(
          bytes: (url) {
            seen.add(url);
            return pngMagic;
          },
        ),
      );
      expect(seen.single, 'https://i0.hdslb.com/c.jpg@.png');
      expect(out.written, ['冬天.封面.png']);
      expect(
        File('${tmp.path}${Platform.pathSeparator}冬天.封面.png').readAsBytesSync(),
        pngMagic,
      );
    });

    test('取不到原图时不静默：缺项里要有封面这一条', () async {
      final out = await biliProduceAdditional(
        cfg: cfgOf()..saveCover = true,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777', pic: null),
        deps: depsOf(),
      );
      expect(out.written, isEmpty);
      expect(out.missing.single, contains('封面'));
    });

    test('图床偶发失败要重试，三次都不成才算没拿到', () async {
      var tries = 0;
      final name = await biliWriteCover(
        cfg: cfgOf()..saveCover = true,
        saveDir: tmp.path,
        outBase: '冬天',
        pic: 'https://i0.hdslb.com/c.jpg',
        fetch: (url) async {
          tries++;
          if (tries < kBiliCoverAttempts) throw const SocketException('5xx');
          return pngMagic;
        },
      );
      expect(tries, kBiliCoverAttempts);
      expect(name, isNotNull);
    });
  });

  // ── 元数据 ──────────────────────────────────────────────────

  group('元数据', () {
    final view = {
      'bvid': 'BV1xx',
      'title': '冬天',
      'desc': '一条片子',
      'tname': '生活',
      'pubdate': 1790000000,
      'owner': {'name': '海边的猫'},
    };

    test('json 档不多取标签接口（那是 nfo 才需要的）', () async {
      var tagCalls = 0;
      final out = await biliProduceAdditional(
        cfg: cfgOf()
          ..saveMetadata = true
          ..metadataFormat = BiliMetadataFormat.json,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: BiliAdditionalDeps(
          signedData: (path, params) async => view,
          plainData: (path, params) async {
            tagCalls++;
            return const {'data': []};
          },
          jsonAtUrl: (url) async => const {},
          bytesAtUrl: (url) async => const <int>[],
          danmakuSegment: (cid, i) async => const <int>[],
        ),
      );
      expect(tagCalls, 0);
      expect(out.written, ['冬天.元数据.json']);
    });

    test('nfo 档多取一次标签，标签要成 <tag> 元素', () async {
      final out = await biliProduceAdditional(
        cfg: cfgOf()
          ..saveMetadata = true
          ..metadataFormat = BiliMetadataFormat.nfo,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: depsOf(
          view: view,
          tags: {
            'data': [
              {'tag_name': '美食'},
              {'tag_name': 'vlog & 日常'},
            ],
          },
        ),
      );
      expect(out.written, ['冬天.元数据.nfo']);
      final nfo = read('冬天.元数据.nfo');
      expect(nfo, contains('<tag>美食</tag>'));
      expect(nfo, contains('&amp;'), reason: '标签里的 & 必须转义，否则整个 nfo 解析不过');
      expect(nfo, contains('<studio>海边的猫</studio>'));
      expect(nfo, contains('<premiered>2026-'));
    });
  });

  // ── 编排与汇总 ──────────────────────────────────────────────

  group('编排', () {
    test('一个开关都没勾 → 一次请求都不发', () async {
      var hits = 0;
      final out = await biliProduceAdditional(
        cfg: cfgOf(),
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: '777'),
        deps: BiliAdditionalDeps(
          signedData: (p, x) async {
            hits++;
            return const {};
          },
          plainData: (p, x) async {
            hits++;
            return const {};
          },
          jsonAtUrl: (u) async {
            hits++;
            return const {};
          },
          bytesAtUrl: (u) async {
            hits++;
            return const <int>[];
          },
          danmakuSegment: (c, i) async {
            hits++;
            return const <int>[];
          },
        ),
      );
      expect(hits, 0);
      expect(out.hasAnything, isFalse);
    });

    test('没有 cid → 不硬打接口，缺项说清楚', () async {
      final out = await biliProduceAdditional(
        cfg: cfgOf()..saveSubtitle = true,
        saveDir: tmp.path,
        outBase: '冬天',
        video: video(cid: null),
        deps: depsOf(),
      );
      expect(out.missing, contains(kBiliAdditionalNoCid));
      expect(out.written, isEmpty);
    });
  });
}
