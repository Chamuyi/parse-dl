import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/douyin_config.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/media_variant.dart';
import 'package:parse_dl/services/douyin_source.dart';

/// 下载源解析的测试 —— 参照实现「6 个下载源 + 4 档质量优先策略」。
///
/// 评分公式是**行为口径**（见 `douyin_source.dart` 文件头），所以这里的期望值
/// 手算出来的（不是跑一遍代码把输出抄回来），否则「实现和测试一起错」就
/// 没人能发现。三处容易踩的坑各有专门用例：
///   1. `auto` 是 0.4/0.4/0.2，不是 0.7/0.2/0.1；
///   2. 四项任一 ≤ 0 → 0 分（缺 FPS 的变体会被排到最后）；
///   3. 候选只从 `bit_rate[]` 里挑，且只认 `format == 'mp4'`。
void main() {
  MediaVariant v({
    String kind = 'bit_rate',
    required List<String> urls,
    int w = 1920,
    int h = 1080,
    int fps = 60,
    int br = 4000000,
    int size = 0,
    String format = 'mp4',
    String gear = 'normal_1080p',
    bool bytevc1 = false,
  }) =>
      MediaVariant(
        urls: urls,
        kind: VariantKind.fromId(kind),
        width: w,
        height: h,
        fps: fps,
        bitrate: br,
        dataSize: size,
        format: format,
        gearName: gear,
        isByteVc1: bytevc1,
      );

  group('三个分量分', () {
    test('分辨率分 = min(100, sqrt(像素/1e6) * 50)', () {
      expect(resolutionScore(1080, 1920), closeTo(72, 0.01));
      expect(resolutionScore(720, 1280), closeTo(48, 0.01));
      expect(resolutionScore(3840, 2160), closeTo(100, 0.001),
          reason: '4K 的 8.29M 像素算出 144 分，被 min 截到 100');
      expect(resolutionScore(0, 1080), 0);
      expect(resolutionScore(1080, -1), 0);
    });

    test('帧率分三段：≤24 线性 / 24~60 每帧 1.4 / >60 几乎封顶', () {
      expect(fpsScore(0), 0);
      expect(fpsScore(24), 48);
      expect(fpsScore(30), closeTo(56.4, 0.001));
      expect(fpsScore(60), closeTo(98.4, 0.001));
      expect(fpsScore(120), 100, reason: '98 + 60*0.1 超过 100 被截断');
      expect(fpsScore(4), 8);
    });

    test('码率分按像素量归一化（小图高码率不会被误判成高质量）', () {
      // 1080x1920 → sqrt(pixels)=1440 → scale = 1440*0.15 = 216
      expect(bitrateScore(216000, 1080, 1920), closeTo(60, 0.001));
      expect(bitrateScore(2160000, 1080, 1920), 100, reason: '被 min 截到 100');
      expect(bitrateScore(0, 1080, 1920), 0);
      expect(bitrateScore(1000, 0, 0), 0);
    });
  });

  group('综合分（四档权重）', () {
    test('auto 用 0.4/0.4/0.2，不是 0.7/0.2/0.1', () {
      final x = v(urls: ['https://a.com/1.mp4']);
      // rs≈72, bs=100, fs≈98.4
      // auto       = 72*0.4 + 100*0.4 + 98.4*0.2 = 88.48 → 88.5
      // resolution = 72*0.7 + 100*0.2 + 98.4*0.1 = 80.24 → 80.2
      expect(variantScore(x, DouyinQualityMode.auto), closeTo(88.5, 0.05));
      expect(
        variantScore(x, DouyinQualityMode.resolution),
        closeTo(80.2, 0.05),
      );
      expect(
        variantScore(x, DouyinQualityMode.bitrate),
        closeTo(94.2, 0.05),
      );
      expect(variantScore(x, DouyinQualityMode.fps), closeTo(93.3, 0.05));
    });

    test('四项任一 ≤ 0 直接判 0 分（对 auto 也生效）', () {
      const missingFps = MediaVariant(
        urls: ['https://a.com/1.mp4'],
        kind: VariantKind.bitRate,
        width: 3840,
        height: 2160,
        bitrate: 8000000,
      );
      expect(variantScore(missingFps, DouyinQualityMode.auto), 0);

      const noBitrate = MediaVariant(
        urls: ['https://a.com/1.mp4'],
        kind: VariantKind.bitRate,
        width: 1920,
        height: 1080,
        fps: 60,
      );
      expect(variantScore(noBitrate, DouyinQualityMode.auto), 0);
    });
  });

  group('rankVideoVariants（候选过滤 + 排序）', () {
    test('只认 format == mp4，dash 被剔除', () {
      final ranked = rankVideoVariants([
        v(urls: ['https://a.com/dash.mp4'], format: 'dash'),
        v(urls: ['https://a.com/ok.mp4']),
      ]);
      expect(ranked.map((e) => e.urls.first).toList(), ['https://a.com/ok.mp4']);
    });

    test('不可用（没有地址）的变体不进候选', () {
      final ranked = rankVideoVariants([
        v(urls: const []),
        v(urls: ['https://a.com/ok.mp4']),
      ]);
      expect(ranked, hasLength(1));
    });

    test('按得分降序，缺 fps 的 4K 反而排最后（坑 2）', () {
      final ranked = rankVideoVariants([
        v(urls: ['https://a.com/4k.mp4'], w: 3840, h: 2160, fps: 0, br: 8000000),
        v(urls: ['https://a.com/1080.mp4']),
      ]);
      expect(ranked.first.urls, ['https://a.com/1080.mp4']);
      expect(ranked.last.urls, ['https://a.com/4k.mp4']);
    });

    test('得分相同时保持原顺序（Dart 的 sort 不稳定，必须显式 tiebreak）', () {
      final a = v(urls: ['https://a.com/a.mp4']);
      final b = v(urls: ['https://a.com/b.mp4']);
      final c = v(urls: ['https://a.com/c.mp4']);
      final ranked = rankVideoVariants([a, b, c]);
      expect(ranked.map((e) => e.urls.first).toList(), [
        'https://a.com/a.mp4',
        'https://a.com/b.mp4',
        'https://a.com/c.mp4',
      ]);
    });

    test('滤掉低画质只作用于档位名含 low 的变体', () {
      final all = [
        v(urls: ['https://a.com/low.mp4'], gear: 'low_720p', w: 1280, h: 720),
        v(urls: ['https://a.com/hi.mp4']),
      ];
      expect(rankVideoVariants(all), hasLength(2));
      expect(
        rankVideoVariants(all, filterLowQuality: true).map((e) => e.urls.first),
        ['https://a.com/hi.mp4'],
      );
    });

    test('排除 ByteVC1 只作用于标记了的变体', () {
      final all = [
        v(urls: ['https://a.com/vc1.mp4'], bytevc1: true, w: 3840, h: 2160),
        v(urls: ['https://a.com/h264.mp4']),
      ];
      expect(rankVideoVariants(all).first.urls, ['https://a.com/vc1.mp4'],
          reason: '不排除时它的分数最高');
      expect(
        rankVideoVariants(all, filterByteVc1: true).map((e) => e.urls.first),
        ['https://a.com/h264.mp4'],
      );
    });

    test('默认档位名也是 auto 权重（不能只看 switch 的三档）', () {
      final ranked = rankVideoVariants([
        v(urls: ['https://a.com/small.mp4'], w: 1280, h: 720, fps: 30, br: 1500000),
        v(urls: ['https://a.com/big.mp4']),
      ]);
      expect(ranked.first.urls, ['https://a.com/big.mp4']);
    });
  });

  group('resolveDouyinMedia —— 6 个下载源', () {
    Media video() => Media(
          id: 'w1',
          type: MediaType.video,
          url: 'https://a.com/default.mp4',
          source: 'douyin',
          tweetId: 'w1',
          variants: [
            // 三个「指定字段」来源在真实载荷里**不带**质量属性
            // （质量属性只在 bit_rate[] 上），所以这里也不给 ——
            // 否则它们会在评分里和 bit_rate 打平、靠位次抢先，掩盖真正的问题。
            v(kind: 'default', urls: ['https://a.com/default.mp4'],
                w: 0, h: 0, fps: 0, br: 0),
            v(kind: 'h264', urls: ['https://a.com/h264.mp4'],
                w: 0, h: 0, fps: 0, br: 0),
            v(kind: 'h265', urls: ['https://a.com/h265.mp4'],
                w: 0, h: 0, fps: 0, br: 0),
            v(kind: 'bit_rate',
                urls: ['https://a.com/1080.mp4'],
                w: 1920,
                h: 1080,
                fps: 60,
                br: 4000000),
            v(kind: 'bit_rate',
                urls: ['https://a.com/720.mp4'],
                w: 1280,
                h: 720,
                fps: 30,
                br: 1500000),
            v(kind: 'bit_rate',
                urls: ['https://a.com/vc1.mp4'],
                w: 3840,
                h: 2160,
                fps: 60,
                br: 8000000,
                bytevc1: true),
            v(kind: 'audio', urls: ['https://m.douyinstatic.com/bgm.mp3'],
                w: 0, h: 0, fps: 0, br: 0),
          ],
        );

    test('视频（默认）取 play_addr，不评分', () {
      final r = resolveDouyinMedia(video(), DouyinConfig());
      expect(r.url, 'https://a.com/default.mp4');
      expect(r.type, MediaType.video);
    });

    test('H.264 / H.265 走各自的直接字段', () {
      expect(
        resolveDouyinMedia(video(), DouyinConfig(source: DouyinSource.h264)).url,
        'https://a.com/h264.mp4',
      );
      expect(
        resolveDouyinMedia(video(), DouyinConfig(source: DouyinSource.h265)).url,
        'https://a.com/h265.mp4',
      );
    });

    test('兼容性+质量优先：排除 ByteVC1，选评分最高的 mp4', () {
      final r = resolveDouyinMedia(
        video(),
        DouyinConfig(source: DouyinSource.qualityFirst),
      );
      expect(r.url, 'https://a.com/1080.mp4');
      expect(r.chosen!.width, 1920);
      expect(r.chosen!.fps, 60);
    });

    test('最高质量优先：不排除 ByteVC1，4K 夺冠', () {
      final r = resolveDouyinMedia(
        video(),
        DouyinConfig(source: DouyinSource.qualityFirstBytevc1),
      );
      expect(r.url, 'https://a.com/vc1.mp4');
      expect(r.chosen!.isByteVc1, isTrue);
    });

    test('换质量优先策略能真的换到不同源（不是摆设开关）', () {
      // A：高分辨率低帧率 —— 分辨率优先时夺冠
      //   分辨率 = 72*0.7 + 100*0.2 + 56.4*0.1 = 76.04 → 76.0
      //   帧率   = 56.4*0.7 + 72*0.2 + 100*0.1 = 63.88 → 63.9
      // B：低分辨率高帧率 —— 帧率优先时夺冠
      //   分辨率 = 48*0.7 + 100*0.2 + 98.4*0.1 = 63.44 → 63.4
      //   帧率   = 98.4*0.7 + 48*0.2 + 100*0.1 = 88.48 → 88.5
      final media = Media(
        id: 'w2',
        type: MediaType.video,
        url: 'https://a.com/a.mp4',
        source: 'douyin',
        tweetId: 'w2',
        variants: [
          v(urls: ['https://a.com/a.mp4'],
              w: 1920, h: 1080, fps: 30, br: 4000000),
          v(urls: ['https://a.com/b.mp4'],
              w: 1280, h: 720, fps: 60, br: 1500000),
        ],
      );

      final byRes = resolveDouyinMedia(
        media,
        DouyinConfig(
          source: DouyinSource.qualityFirstBytevc1,
          qualityMode: DouyinQualityMode.resolution,
        ),
      );
      expect(byRes.url, 'https://a.com/a.mp4');

      final byFps = resolveDouyinMedia(
        media,
        DouyinConfig(
          source: DouyinSource.qualityFirstBytevc1,
          qualityMode: DouyinQualityMode.fps,
        ),
      );
      expect(byFps.url, 'https://a.com/b.mp4');
    });

    test('仅音频：换成该作品的 BGM，类型也变成 audio', () {
      final r = resolveDouyinMedia(
        video(),
        DouyinConfig(source: DouyinSource.audioOnly),
      );
      expect(r.type, MediaType.audio);
      expect(r.url, 'https://m.douyinstatic.com/bgm.mp3');
      expect(r.chosen!.kind, VariantKind.audio);
    });

    test('仅音频但没有 BGM 时保留视频，不产出空任务', () {
      final noBgm = video().copyWith(variants: [
        v(kind: 'default', urls: ['https://a.com/default.mp4']),
      ]);
      final r = resolveDouyinMedia(
        noBgm,
        DouyinConfig(source: DouyinSource.audioOnly),
      );
      expect(r.type, MediaType.video);
      expect(r.url, 'https://a.com/default.mp4');
    });

    test('指定字段缺失时退回已有候选（能下到东西优先于严格按源）', () {
      final onlyDefault = video().copyWith(variants: [
        v(kind: 'default', urls: ['https://a.com/default.mp4']),
      ]);
      final r = resolveDouyinMedia(
        onlyDefault,
        DouyinConfig(source: DouyinSource.h264),
      );
      expect(r.url, 'https://a.com/default.mp4');
    });

    test('非 douyin 来源原样返回（X 的媒体不该被这套逻辑碰到）', () {
      final x = Media(
        id: 'x1',
        type: MediaType.video,
        url: 'https://video.twimg.com/x.mp4',
      );
      expect(resolveDouyinMedia(x, DouyinConfig()), same(x));
    });
  });

  group('resolveDouyinMedia —— 图文', () {
    Media image(List<String> urls) => Media(
          id: 'i1',
          type: MediaType.image,
          url: urls.first,
          source: 'douyin',
          tweetId: 'w1',
          altUrls: urls.length > 1 ? urls.sublist(1) : const [],
        );

    test('默认档：保持抖音下发的镜像顺序（通常 webp 在前）', () {
      final r = resolveDouyinMedia(
        image(['https://a.com/1.webp', 'https://a.com/1.jpeg']),
        DouyinConfig(),
      );
      expect(r.url, 'https://a.com/1.webp');
      expect(r.altUrls, ['https://a.com/1.jpeg']);
    });

    test('其它格式优先：把 webp 镜像挪到最后，URL 本身不变', () {
      final r = resolveDouyinMedia(
        image(['https://a.com/1.webp', 'https://a.com/1.jpeg']),
        DouyinConfig(imageFormat: DouyinImageFormat.jpgFirst),
      );
      expect(r.url, 'https://a.com/1.jpeg');
      expect(r.altUrls, ['https://a.com/1.webp']);
    });

    test('jpgFirst 是稳定重排（多个非 webp 之间保持原顺序）', () {
      final r = resolveDouyinMedia(
        image([
          'https://a.com/1.webp',
          'https://a.com/1.heic',
          'https://a.com/1.jpeg',
        ]),
        DouyinConfig(imageFormat: DouyinImageFormat.jpgFirst),
      );
      expect(r.url, 'https://a.com/1.heic');
      expect(r.altUrls, ['https://a.com/1.jpeg', 'https://a.com/1.webp']);
    });

    test('图片不会被补 ?name=orig（那是 X 的 CDN 规矩）', () {
      final r = resolveDouyinMedia(
        image(['https://p3.douyinpic.com/1.jpeg']),
        DouyinConfig(),
      );
      expect(r.url, 'https://p3.douyinpic.com/1.jpeg');
    });
  });
}
