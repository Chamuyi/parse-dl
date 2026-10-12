// 内封字幕轨「默认轨」的回归判据。
//
// 真机现场（2026-10-12）：成品 mkv 里 10 条字幕轨，**阿拉伯语 AI 轨被标了
// default=1**，中文轨是 0。播放器按 default 选轨，用户打开就是一堆看不懂的字，
// 很容易被当成「中文字幕下错了 / 下的是外语版」。
//
// 根因：合并命令从没写过 `-disposition`，ffmpeg 就把 default 标给**第一条**
// 字幕流，而第一条是按文件名排序撞出来的（`字幕.ai-ar.ass` 恰好排第一）。
//
// 判据强度已用负控制验证：去掉 `-disposition` 那几行后，「命令里有 disposition」
// 与「中文轨被标 default」两条都会变红。
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/services/bili_additional.dart';
import 'package:parse_dl/services/bili_merger.dart';

BiliEmbeddedTrack tr(String file, String title, String iso,
        {bool dm = false}) =>
    BiliEmbeddedTrack(
        fileName: file, title: title, iso639: iso, fromDanmaku: dm);

/// 复刻真机现场那批轨（顺序就是 orderTracks 排出来的顺序）。
List<BiliEmbeddedTrack> realWorldTracks() => [
      tr('x.字幕.ai-ar.ass', 'العربية（AI）', 'ara'),
      tr('x.字幕.ai-en.ass', 'English（AI）', 'eng'),
      tr('x.字幕.ai-es.ass', 'Español（AI）', 'spa'),
      tr('x.字幕.ai-ja.ass', '日本語（AI）', 'jpn'),
      tr('x.字幕.ai-zh.ass', '中文（AI）', 'chi'),
      tr('x.字幕.zh.ass', '中文', 'chi'),
      tr('x.弹幕.ass', '弹幕', ''),
    ];

void main() {
  group('默认轨的选择', () {
    test('真机那批轨里选中中文（不是排第一的阿拉伯语）', () {
      final tracks = realWorldTracks();
      final i = biliDefaultTrackIndex(tracks);
      expect(i, greaterThanOrEqualTo(0));
      expect(tracks[i].iso639, 'chi',
          reason: '默认轨不是中文 → 用户打开看到外语');
    });

    test('中文 AI 轨也在候选里（只要 iso639 是 chi 就算）', () {
      final tracks = [
        tr('x.字幕.ai-ar.ass', 'العربية（AI）', 'ara'),
        tr('x.字幕.ai-zh.ass', '中文（AI）', 'chi'),
      ];
      expect(biliDefaultTrackIndex(tracks), 1);
    });

    test('多种中文写法都认（chi / zh-cn / zh-hans …）', () {
      for (final code in ['chi', 'zh', 'zh-CN', 'zh-Hans', 'zho']) {
        final tracks = [
          tr('a.ass', 'English', 'eng'),
          tr('b.ass', '中文', code),
        ];
        expect(biliDefaultTrackIndex(tracks), 1, reason: '$code 没被认成中文');
      }
    });

    test('没有中文时退回第一条非弹幕轨', () {
      final tracks = [
        tr('a.ass', 'العربية（AI）', 'ara'),
        tr('b.ass', 'English（AI）', 'eng'),
      ];
      expect(biliDefaultTrackIndex(tracks), 0);
    });

    test('弹幕轨不许当默认（它不是给人读的正文）', () {
      final tracks = [
        tr('x.弹幕.ass', '弹幕', '', dm: true),
        tr('x.字幕.ai-en.ass', 'English（AI）', 'eng'),
      ];
      expect(biliDefaultTrackIndex(tracks), 1,
          reason: '弹幕被选成默认 → 打开成品满屏弹幕而不是字幕');
    });

    test('只有弹幕时也返回它（总得有一条默认，不能返回 -1）', () {
      final tracks = [tr('x.弹幕.ass', '弹幕', '', dm: true)];
      expect(biliDefaultTrackIndex(tracks), 0);
    });

    test('负控制：空列表返回 -1（证明上面几条不是恒真）', () {
      expect(biliDefaultTrackIndex(const []), -1);
    });
  });

  group('合并命令真的写了 disposition', () {
    List<String> argsFor(List<BiliEmbeddedTrack> tracks) {
      final m = BiliMerger(ffmpegPath: 'ffmpeg.exe');
      return m.mergeArgs('v.m4s', 'a.m4s', 'out.mkv',
          subtitleTracks: [
            for (final t in tracks)
              (path: t.fileName, title: t.title, lang: t.iso639),
          ]);
    }

    test('每条字幕轨都有 -disposition:s:N', () {
      final args = argsFor(realWorldTracks());
      for (var k = 0; k < 7; k++) {
        expect(args, contains('-disposition:s:$k'),
            reason: '第 $k 条没有 disposition → ffmpeg 自行决定，可能选错');
      }
    });

    test('只有中文那条是 default，其余是 0', () {
      final tracks = realWorldTracks();
      final args = argsFor(tracks);
      // 找出 default 落在第几条
      var defaultAt = -1;
      for (var k = 0; k < tracks.length; k++) {
        final i = args.indexOf('-disposition:s:$k');
        expect(i, greaterThan(-1));
        if (args[i + 1] == 'default') defaultAt = k;
      }
      expect(defaultAt, isNot(-1), reason: '一条 default 都没有');
      // 判据是「被选中的那条语言是中文」，不是某个写死的下标 ——
      // 中文 AI 轨与中文人工轨都是 chi，谁被选中都满足设计（见
      // biliDefaultTrackIndex 的注释：判据只有「中文优先、弹幕垫底」）。
      expect(tracks[defaultAt].iso639, 'chi',
          reason: '默认轨不是中文 → 用户打开看到外语。实际选中第 $defaultAt 条：'
              '${tracks[defaultAt].title}');
      // 同时钉住「不是排第一的那条阿拉伯语」
      expect(defaultAt, isNot(0), reason: '又选回阿拉伯语了');
    });

    test('负控制：没有字幕轨时不该出现 disposition（证明上两条不是恒真）', () {
      final args = argsFor(const []);
      expect(args.any((a) => a.startsWith('-disposition')), isFalse);
    });

    test('正控制：-metadata:s:s:N title 仍在（改动没把原有行为挤掉）', () {
      final args = argsFor(realWorldTracks());
      expect(args, contains('-metadata:s:s:0'));
      expect(args, contains('title=العربية（AI）'));
    });
  });

  group('排轨顺序本身没被改动', () {
    test('subtitleFirst 时字幕在前、弹幕在后', () {
      final tracks = [
        tr('x.弹幕.ass', '弹幕', '', dm: true),
        tr('x.字幕.zh.ass', '中文', 'chi'),
      ];
      final ordered = orderTracks(tracks, BiliTrackPriority.subtitleFirst);
      expect(ordered.first.fromDanmaku, isFalse);
      expect(ordered.last.fromDanmaku, isTrue);
    });

    test('danmakuFirst 时反过来', () {
      final tracks = [
        tr('x.字幕.zh.ass', '中文', 'chi'),
        tr('x.弹幕.ass', '弹幕', '', dm: true),
      ];
      final ordered = orderTracks(tracks, BiliTrackPriority.danmakuFirst);
      expect(ordered.first.fromDanmaku, isTrue);
    });
  });
}
