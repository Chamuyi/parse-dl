import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/models/bili_meta.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/media_variant.dart';
import 'package:parse_dl/services/bili_api.dart';
import 'package:parse_dl/services/bili_download_plan.dart';

/// `planBiliStreams()` 与各纯函数的单测 —— **一条都不打网络**。
///
/// 这层存在的意义就是「给一份响应，定死这次下哪两条流」，所以它能全部离线钉住。
/// 素材一律直接构造 `BiliPlayUrl` / `BiliStream`（`fromJson` 那条路
/// `bili_api_shape_test.dart` 已经覆盖过了，这里重复解析一遍没有价值）。
void main() {
  /// 造一条视频流。`id` 就是 B 站的画质档位号（qn）。
  BiliStream v(
    int qn,
    BiliCodec codec, {
    int bitrate = 1000,
    String? url,
  }) =>
      BiliStream(
        id: qn,
        codecs: switch (codec) {
          BiliCodec.avc => 'avc1.640032',
          BiliCodec.hevc => 'hev1.1.6.L150',
          BiliCodec.av1 => 'av01.0.17M.08',
          BiliCodec.auto => '',
        },
        codec: codec == BiliCodec.auto ? null : codec,
        baseUrl: url ?? 'https://cdn.example.com/v$qn-${codec.id}.m4s',
        backupUrls: const [],
        width: 1920,
        height: 1080,
        bitrate: bitrate,
        qualityLabel: kBiliQualityNames[qn] ?? '$qn',
      );

  /// 造一条音频流。
  BiliStream a(int id, {required int bitrate, String? url}) => BiliStream(
        id: id,
        codecs: 'mp4a.40.2',
        codec: null,
        baseUrl: url ?? 'https://cdn.example.com/a$id.m4s',
        backupUrls: const [],
        bitrate: bitrate,
        isAudio: true,
        qualityLabel: kBiliAudioNames[id] ?? '$id',
      );

  BiliPlayUrl dash({
    required List<BiliStream> video,
    required List<BiliStream> audio,
  }) =>
      BiliPlayUrl(
        cid: 777,
        isDash: true,
        currentQn: video.isEmpty ? 0 : video.first.id,
        video: video,
        audio: audio,
        singleFiles: const [],
        preferredCodec: BiliCodec.auto,
      );

  BiliPlayUrl durl(List<BiliStream> files) => BiliPlayUrl(
        cid: 777,
        isDash: false,
        currentQn: 64,
        video: const [],
        audio: const [],
        singleFiles: files,
        preferredCodec: BiliCodec.auto,
      );

  group('画质上限裁剪', () {
    test('给 127/116/80/64 四条流，选 1080P（qn 80）时取到 80', () {
      final r = dash(
        video: [
          v(127, BiliCodec.avc),
          v(116, BiliCodec.avc),
          v(80, BiliCodec.avc),
          v(64, BiliCodec.avc),
        ],
        audio: [a(30280, bitrate: 192000)],
      );

      final p = planBiliStreams(r, BiliQuality.q1080, BiliCodec.avc);

      expect(p.videoQn, 80, reason: '上限就是 80，超上限的 127/116 必须先裁掉');
      expect(p.usable, isTrue);
    });

    test('上限高于实际可用时取实际最高那条（B 站会按账号权限先裁一刀）', () {
      // 非大会员账号选到 1080P60，响应里却只有 720P / 480P —— 这是正常结果，
      // 判「超出上限就没得下」等于用户什么都下载不了。
      final r = dash(
        video: [v(64, BiliCodec.avc), v(32, BiliCodec.avc)],
        audio: [a(30216, bitrate: 64000)],
      );

      final p = planBiliStreams(r, BiliQuality.q1080p60, BiliCodec.avc);

      expect(p.videoQn, 64);
      expect(p.usable, isTrue);
    });

    test('最高可用（highest）不裁任何档，取实际最高', () {
      final r = dash(
        video: [v(80, BiliCodec.avc), v(116, BiliCodec.avc)],
        audio: [a(30280, bitrate: 192000)],
      );

      final p = planBiliStreams(r, BiliQuality.highest, BiliCodec.auto);

      expect(p.videoQn, 116);
    });

    test('用户选的上限比所有流都低时仍然下得动（退到实际最高，不判失败）', () {
      // 例：账号能拿到的最低就是 1080P，用户手点选了 360P。
      // 硬按上限筛会一条都不剩 —— 界面只能报「没找到符合你设置的画质」，
      // 而实际上手里就有一条能下的流。宁可下一档高的，也不要空手回来。
      final r = dash(
        video: [v(80, BiliCodec.avc)],
        audio: [a(30280, bitrate: 192000)],
      );

      final p = planBiliStreams(r, BiliQuality.q360, BiliCodec.avc);

      expect(p.videoQn, 80);
      expect(p.usable, isTrue);
    });

    test('画质优先于编码偏好：同一条 80 的 AVC 不该赢过 116 的 HEVC', () {
      final r = dash(
        video: [v(116, BiliCodec.hevc), v(80, BiliCodec.avc)],
        audio: [a(30280, bitrate: 192000)],
      );

      final p = planBiliStreams(r, BiliQuality.q1080p60, BiliCodec.avc);

      expect(p.videoQn, 116, reason: '先裁画质、再按编码取；编码偏好不许把清晰度换掉');
      expect(p.videoCodec, BiliCodec.hevc, reason: '该档位没有 AVC，就退到本档实际有的编码');
    });
  });

  group('编码偏好', () {
    BiliPlayUrl threeCodeAtOneQn() => dash(
          video: [
            v(80, BiliCodec.av1, bitrate: 2000000),
            v(80, BiliCodec.hevc, bitrate: 3000000),
            v(80, BiliCodec.avc, bitrate: 5000000),
          ],
          audio: [a(30280, bitrate: 192000)],
        );

    test('auto = 兼容性优先，同画质先取 AVC', () {
      final p = planBiliStreams(
        threeCodeAtOneQn(),
        BiliQuality.q1080,
        BiliCodec.auto,
      );

      expect(p.videoCodec, BiliCodec.avc);
    });

    test('显式偏好 hevc 取 HEVC', () {
      final p = planBiliStreams(
        threeCodeAtOneQn(),
        BiliQuality.q1080,
        BiliCodec.hevc,
      );

      expect(p.videoCodec, BiliCodec.hevc);
    });

    test('显式偏好 av1 取 AV1', () {
      final p = planBiliStreams(
        threeCodeAtOneQn(),
        BiliQuality.q1080,
        BiliCodec.av1,
      );

      expect(p.videoCodec, BiliCodec.av1);
    });

    test('偏好那一族在这一档不存在时，仍按兼容性顺序给出一条（不判失败）', () {
      final r = dash(
        video: [v(80, BiliCodec.av1), v(80, BiliCodec.avc)],
        audio: [a(30280, bitrate: 192000)],
      );

      final p = planBiliStreams(r, BiliQuality.q1080, BiliCodec.hevc);

      expect(p.usable, isTrue);
      expect(p.videoCodec, BiliCodec.avc, reason: '没有 HEVC 时按兼容性优先落回 AVC，而不是 AV1');
    });

    test('同族同档并列时按码率降序，再按原始顺序（排序必须可复现）', () {
      final r = dash(
        video: [
          v(80, BiliCodec.avc, bitrate: 3000),
          v(80, BiliCodec.avc, bitrate: 5000),
          v(80, BiliCodec.avc, bitrate: 3000),
        ],
        audio: [a(30280, bitrate: 192000)],
      );

      final p = planBiliStreams(r, BiliQuality.q1080, BiliCodec.avc);

      expect(p.video!.bitrate, 5000);
      // 同一个 base 跑两遍必须给同一个结果：台账按 bvid+cid 去重，
      // 选流若不稳定，同一分 P 两次会算出两个文件名。
      final again = planBiliStreams(r, BiliQuality.q1080, BiliCodec.avc);
      expect(again.video!.urls, p.video!.urls);
    });
  });

  group('音频流', () {
    test('取码率最高的那条（不是档位号最大的那条）', () {
      final r = dash(
        video: [v(80, BiliCodec.avc)],
        audio: [
          a(30216, bitrate: 64000),
          a(30280, bitrate: 192000),
          a(30232, bitrate: 132000),
        ],
      );

      final p = planBiliStreams(r, BiliQuality.q1080, BiliCodec.auto);

      expect(p.audio!.bitrate, 192000);
      expect(p.audio!.kind, VariantKind.audio, reason: '音频侧靠 kind 认，界面与合并都读它');
    });

    test('DASH 没有音频流时判不可用，并给出可读原因', () {
      // 只下视频流会拿到一个「能建文件但放不出声音」的空壳，
      // 而 DASH 视频流单独甚至不能播放 —— 宁可不入队。
      final r = dash(video: [v(80, BiliCodec.avc)], audio: []);

      final p = planBiliStreams(r, BiliQuality.q1080, BiliCodec.auto);

      expect(p.usable, isFalse);
      expect(p.message, isNotNull);
      expect(p.message, contains('音频'));
    });

    test('一条视频流都没有时给「需要凭据」这句话，不返回半个结果', () {
      final r = dash(video: [], audio: []);

      final p = planBiliStreams(r, BiliQuality.q1080, BiliCodec.auto);

      expect(p.usable, isFalse);
      expect(p.video, isNull);
      expect(p.message, contains('登录'));
    });
  });

  group('durl 退化路径（isDash == false）', () {
    test('拿到的就是完整 mp4：只有一条、不需要合并', () {
      final r = durl([
        BiliStream(
          id: 64,
          codecs: 'avc1.640032',
          codec: BiliCodec.avc,
          baseUrl: 'https://cdn.example.com/full.mp4',
          backupUrls: const ['https://backup.example.com/full.mp4'],
          qualityLabel: '720P',
        ),
      ]);

      final p = planBiliStreams(r, BiliQuality.q1080, BiliCodec.auto);

      expect(p.isDash, isFalse);
      expect(p.usable, isTrue);
      expect(p.needsMerge, isFalse, reason: 'durl 是完整文件，走合并等于把一个 mp4 当两路输入');
      expect(p.audio, isNull);
      expect(p.video!.format, 'mp4');
      expect(p.video!.urls, [
        'https://cdn.example.com/full.mp4',
        'https://backup.example.com/full.mp4',
      ], reason: '镜像地址要全带上，换源重试靠它');
    });

    test('分段的老稿件不做拼接，如实回一句', () {
      final r = durl([
        BiliStream(
          id: 64,
          codecs: 'avc1',
          codec: BiliCodec.avc,
          baseUrl: 'https://cdn.example.com/part1.mp4',
          backupUrls: const [],
        ),
        BiliStream(
          id: 64,
          codecs: 'avc1',
          codec: BiliCodec.avc,
          baseUrl: 'https://cdn.example.com/part2.mp4',
          backupUrls: const [],
        ),
      ]);

      final p = planBiliStreams(r, BiliQuality.q1080, BiliCodec.auto);

      expect(r.needsSegmentMerge, isTrue);
      expect(p.usable, isFalse);
      expect(p.message, contains('段'));
    });
  });

  group('两条 Media', () {
    Media part() => Media(
          id: 'BV1xx-3',
          type: MediaType.video,
          url: 'https://old.example.com/x',
          source: 'bili',
          tweetId: 'BV1xx',
          userName: '海边的猫',
          mediaIndex: 3,
          bili: const BiliMeta(
            workTitle: '作品',
            partTitle: '第3P',
            bvid: 'BV1xx',
            cid: '777',
            partTotal: 12,
            qualityLabel: '1080P',
            codecLabel: 'AVC',
          ),
        );

    test('视频侧 type=video、音频侧 chosen.kind=audio，source 都是 bili', () {
      final r = dash(
        video: [v(80, BiliCodec.avc, url: 'https://cdn.example.com/v.m4s')],
        audio: [a(30280, bitrate: 192000, url: 'https://cdn.example.com/a.m4s')],
      );
      final p = planBiliStreams(r, BiliQuality.q1080, BiliCodec.auto);
      final medias = biliPairToMedias(part: part(), pair: p);

      expect(medias.video.source, 'bili');
      expect(medias.video.type, MediaType.video);
      expect(medias.video.url, 'https://cdn.example.com/v.m4s');
      expect(medias.video.chosen!.kind, VariantKind.bitRate);

      final audio = medias.audio!;
      expect(audio.source, 'bili', reason: '_requestOptions 靠 source 认平台，串了就没来源头');
      expect(audio.type, MediaType.audio);
      expect(audio.url, 'https://cdn.example.com/a.m4s');
      expect(audio.chosen!.kind, VariantKind.audio);
    });

    test('两条的 id 必须分开（同 id 会让两行撞在一起）', () {
      final r = dash(
        video: [v(80, BiliCodec.avc)],
        audio: [a(30280, bitrate: 192000)],
      );
      final m = biliPairToMedias(
        part: part(),
        pair: planBiliStreams(r, BiliQuality.q1080, BiliCodec.auto),
      );

      expect(m.video.id, isNot(m.audio!.id));
      expect(m.audio!.id, contains('_audio'));
      // 台账与去重读的是 bvid + cid，两边必须还是同一个分 P
      expect(m.audio!.bili!.bvid, m.video.bili!.bvid);
      expect(m.audio!.bili!.cid, m.video.bili!.cid);
    });

    test('durl 退化路径只给一条 Media（没有配对可言）', () {
      final r = durl([
        BiliStream(
          id: 64,
          codecs: 'avc1',
          codec: BiliCodec.avc,
          baseUrl: 'https://cdn.example.com/full.mp4',
          backupUrls: const [],
        ),
      ]);
      final m = biliPairToMedias(
        part: part(),
        pair: planBiliStreams(r, BiliQuality.q1080, BiliCodec.auto),
      );

      expect(m.audio, isNull);
      expect(m.video.url, 'https://cdn.example.com/full.mp4');
    });

    test('落盘名三件套由 base 唯一决定', () {
      expect(biliVideoStreamName('冬天'), '冬天.video.m4s');
      expect(biliAudioStreamName('冬天'), '冬天.audio.m4s');
      expect(biliMergedName('冬天'), '冬天.mp4');
    });

    test('base 名会把 %EXT% 那段剥掉，但不动标题里的点', () {
      expect(biliBaseNameFromFileName('冬天-1080P-AVC.m4s'), '冬天-1080P-AVC');
      expect(biliBaseNameFromFileName('冬天-1080P.mp4'), '冬天-1080P');
      expect(
        biliBaseNameFromFileName('2K 修复.冬.天'),
        '2K 修复.冬.天',
        reason: '只有真的容器扩展名才该被剥，标题正文里的点不是扩展名',
      );
    });
  });
}
