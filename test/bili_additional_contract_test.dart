import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/services/bili_additional.dart';

BiliEmbeddedTrack _t(String name, {bool danmaku = false}) =>
    BiliEmbeddedTrack(
      fileName: name,
      title: name,
      iso639: 'chi',
      fromDanmaku: danmaku,
    );

void main() {
  group('内封前提的三条判据 每条单独验，不许搭车', () {
    /// 三份都满足前提的配置，再各自破坏一条。
    BiliConfig ready({bool forDanmaku = false}) => BiliConfig()
      ..container = BiliContainer.mkv
      ..mergeAfterDownload = true
      ..subtitleFormat = BiliSubtitleFormat.ass
      ..danmakuFormat = BiliDanmakuFormat.ass
      ..saveSubtitle = !forDanmaku
      ..saveDanmaku = forDanmaku;

    test('三条都满足时可以内封', () {
      expect(ready().embedBlockReason(forDanmaku: false), isNull);
      expect(ready().embedBlockReason(forDanmaku: true), isNull);
    });

    test('只缺容器时，报的就是容器这一条', () {
      final c = ready()..container = BiliContainer.mp4;
      final r = c.embedBlockReason(forDanmaku: false);
      expect(r, isNotNull);
      expect(r!.length, 1, reason: '只破坏一条却报出两条，说明判据互相牵连');
      expect(r.first, contains('MKV'));
    });

    test('只关合并时，报的就是合并这一条', () {
      final c = ready()..mergeAfterDownload = false;
      final r = c.embedBlockReason(forDanmaku: false);
      expect(r!.length, 1);
      expect(r.first, contains('合并'));
    });

    test('只把字幕格式换成 srt 时，报的是字幕格式，不提弹幕', () {
      final c = ready()..subtitleFormat = BiliSubtitleFormat.srt;
      final r = c.embedBlockReason(forDanmaku: false);
      expect(r!.length, 1);
      expect(r.first, contains('字幕'));
    });

    test('只把弹幕格式换成 xml 时，报的是弹幕格式，不提字幕', () {
      final c = ready(forDanmaku: true)..danmakuFormat = BiliDanmakuFormat.xml;
      final r = c.embedBlockReason(forDanmaku: true);
      expect(r!.length, 1);
      expect(r.first, contains('弹幕'));
    });

    test('三条全缺就报三条', () {
      final c = BiliConfig()
        ..container = BiliContainer.mp4
        ..mergeAfterDownload = false
        ..subtitleFormat = BiliSubtitleFormat.srt;
      expect(c.embedBlockReason(forDanmaku: false), hasLength(3));
    });
  });

  group('orderTracks', () {
    test('字幕优先：字幕族排在弹幕墙之前', () {
      final out = orderTracks([
        _t('b.弹幕.中文.ass', danmaku: true),
        _t('a.字幕.中文.ass'),
      ], BiliTrackPriority.subtitleFirst);
      expect(out.map((e) => e.fileName).toList(), [
        'a.字幕.中文.ass',
        'b.弹幕.中文.ass',
      ]);
    });

    test('弹幕优先：同一批输入要翻过来', () {
      final out = orderTracks([
        _t('b.弹幕.中文.ass', danmaku: true),
        _t('a.字幕.中文.ass'),
      ], BiliTrackPriority.danmakuFirst);
      expect(out.map((e) => e.fileName).toList(), [
        'b.弹幕.中文.ass',
        'a.字幕.中文.ass',
      ]);
    });

    test('同族内部按文件名定序，两次跑不许漂', () {
      final tracks = [
        _t('z.字幕.eng.ass'),
        _t('a.字幕.chi.ass'),
        _t('m.字幕.jpn.ass'),
      ];
      final first = orderTracks(tracks, BiliTrackPriority.subtitleFirst);
      final second =
          orderTracks(tracks.reversed.toList(), BiliTrackPriority.subtitleFirst);
      expect(first.map((e) => e.fileName).toList(), [
        'a.字幕.chi.ass',
        'm.字幕.jpn.ass',
        'z.字幕.eng.ass',
      ]);
      expect(second.map((e) => e.fileName), first.map((e) => e.fileName));
    });

    test('排完不改原列表', () {
      final tracks = [_t('b', danmaku: true), _t('a')];
      orderTracks(tracks, BiliTrackPriority.danmakuFirst);
      expect(tracks[0].fileName, 'b');
      expect(tracks[1].fileName, 'a');
    });
  });

  group('biliAdditionalName', () {
    test('带语言时三段再接扩展名', () {
      expect(
        biliAdditionalName(
          base: '冬天-1080P',
          qualifier: '字幕',
          lang: 'chi',
          ext: 'ass',
        ),
        '冬天-1080P.字幕.chi.ass',
      );
    });

    test('不带语言时不留下多余的点', () {
      expect(
        biliAdditionalName(base: '冬天-1080P', qualifier: '封面', ext: 'jpg'),
        '冬天-1080P.封面.jpg',
      );
      expect(
        biliAdditionalName(
          base: '冬天-1080P',
          qualifier: '元数据',
          lang: '',
          ext: 'nfo',
        ),
        '冬天-1080P.元数据.nfo',
      );
    });

    test('扩展名多写了一个点也要吃掉', () {
      expect(
        biliAdditionalName(
          base: 'x',
          qualifier: '弹幕',
          lang: 'zh-CN',
          ext: '.xml',
        ),
        'x.弹幕.zh-CN.xml',
      );
    });
  });

  group('BiliAdditionalOutcome', () {
    test('空结果既没有轨也没有产物', () {
      expect(BiliAdditionalOutcome.none.tracks, isEmpty);
      expect(BiliAdditionalOutcome.none.written, isEmpty);
      expect(BiliAdditionalOutcome.none.missing, isEmpty);
      expect(BiliAdditionalOutcome.none.hasAnything, isFalse);
    });

    test('只拿到侧文件也算有产物（合并命令不该因此带上字幕轨）', () {
      const o = BiliAdditionalOutcome(
        tracks: [],
        written: ['x.封面.jpg'],
        missing: [],
      );
      expect(o.hasAnything, isTrue);
      expect(o.tracks, isEmpty);
      expect(o.chapterMetadataPath, isNull);
    });
  });
}
