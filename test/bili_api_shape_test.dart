import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/models/media_variant.dart';
import 'package:parse_dl/services/bili_api.dart';

/// `toVariants` 的形状测试：**不打网络**，手写 `playurl` 的 `data` 块喂解析器。
///
/// 这是本期与下载器唯一的接口，所以要钉住四件事：
///   1. 排序（编码偏好 → 档位 → 码率 → 原顺序，稳定）；
///   2. 地址顺序（`baseUrl` 首位、镜像跟其后 —— 换源重试靠这个顺序）；
///   3. 档位标签的来源（`support_formats` 优先，缺失才按 qn 反查）；
///   4. 老稿件的 durl 退化路径能被上层认出来（`isDash == false`）。
void main() {
  Map<String, dynamic> dashData() => {
        'quality': 80,
        'support_formats': [
          {
            'quality': 116,
            'quality_desc': '1080P60',
            'codecs': ['avc1.640032', 'hev1.1.6.L120.90', 'av01.0.17M.08'],
          },
          {
            'quality': 80,
            'quality_desc': '1080P 高清',
            'codecs': ['avc1.640032', 'hev1.1.6.L120.90'],
          },
          {'quality': 64, 'quality_desc': '720P 准高清', 'codecs': ['av01.0.17M.08']},
        ],
        'dash': {
          'duration': 632,
          'video': [
            {
              'id': 80,
              'codecid': 7,
              'codecs': 'avc1.640032',
              'baseUrl': 'https://m.example/v-avc-80.m4s',
              'backupUrl': [
                'https://m.example/v-avc-80-b.m4s',
                'https://m.example/v-avc-80-c.m4s',
              ],
              'width': 1920,
              'height': 1080,
              // B 站这个字段给过串也给过数字，两种都要能吃下
              'frame_rate': '29.97 fps',
              'bandwidth': 3200000,
              'size': 253000000,
            },
            {
              'id': 80,
              'codecid': 12,
              'codecs': 'hev1.1.6.L120.90',
              'baseUrl': 'https://m.example/v-hevc-80.m4s',
              'backupUrl': ['https://m.example/v-hevc-80-b.m4s'],
              'width': 1920,
              'height': 1080,
              'frame_rate': 30,
              'bandwidth': 2100000,
              'size': 166000000,
            },
            {
              'id': 64,
              'codecid': 13,
              'codecs': 'av01.0.17M.08',
              'baseUrl': 'https://m.example/v-av1-64.m4s',
              'backupUrl': const <String>[],
              'width': 1280,
              'height': 720,
              'frame_rate': 60,
              'bandwidth': 900000,
              'size': 71000000,
            },
          ],
          'audio': [
            {
              'id': 30216,
              'codecs': 'mp4a.40.2',
              'baseUrl': 'https://m.example/a-64k.m4s',
              'backupUrl': ['https://m.example/a-64k-b.m4s'],
              'bandwidth': 64000,
              'size': 5000000,
            },
            {
              'id': 30280,
              'codecs': 'mp4a.40.2',
              'baseUrl': 'https://m.example/a-192k.m4s',
              'backupUrl': const <String>[],
              'bandwidth': 192000,
              'size': 15000000,
            },
          ],
        },
      };

  BiliPlayUrl dash({BiliCodec prefer = BiliCodec.auto}) => BiliPlayUrl.fromJson(
        dashData(),
        cid: 765432109,
        preferredCodec: prefer,
      );

  group('解析', () {
    test('dash 形态：三条视频流两条音频流都认得编码', () {
      final r = dash();
      expect(r.isDash, isTrue);
      expect(r.cid, 765432109);
      expect(r.currentQn, 80);
      expect(r.video.length, 3);
      expect(r.audio.length, 2);
      expect(r.video.map((s) => s.codec), [
        BiliCodec.avc,
        BiliCodec.hevc,
        BiliCodec.av1,
      ]);
      expect(r.video.map((s) => s.codecLabel), ['AVC', 'HEVC', 'AV1']);
      // `frame_rate` 是串时要四舍五入成整数帧率
      expect(r.video.map((s) => s.fps), [30, 30, 60]);
      expect(r.video.first.width, 1920);
      expect(r.video.first.dataSize, 253000000);
      expect(r.needsSegmentMerge, isFalse);
    });

    test('qualityLabel 取 support_formats 的文案，没有才按 qn 反查中文名', () {
      final r = dash();
      expect(r.video[0].qualityLabel, '1080P 高清');
      expect(r.video[2].qualityLabel, '720P 准高清');
      expect(r.audio[0].qualityLabel, '64K');

      // 同一份流但没有 support_formats（老响应/部分稿件确实不带）
      final noFormats = dashData()..remove('support_formats');
      final fallback = BiliPlayUrl.fromJson(noFormats, cid: 1);
      expect(fallback.video[0].qualityLabel, '1080P');
      expect(fallback.video[2].qualityLabel, '720P');
      // 音频走自己的档位表（解析顺序里第一条是 30216）
      expect(fallback.audio.first.qualityLabel, '64K');
    });

    test('档位号 116 在没有声明时反查成 1080P60', () {
      final data = {
        'quality': 116,
        'dash': {
          'video': [
            {
              'id': 116,
              'codecs': 'av01.0.17M.08',
              'baseUrl': 'https://m.example/v-av1-116.m4s',
            },
          ],
        },
      };
      expect(BiliPlayUrl.fromJson(data).video.single.qualityLabel, '1080P60');
    });

    test('没有 dash 只有 durl 时退化成单文件，且 isDash 明确为 false', () {
      final r = BiliPlayUrl.fromJson(durlData(), cid: 42);
      expect(r.isDash, isFalse);
      expect(r.video, isEmpty);
      expect(r.singleFiles.length, 1);
      expect(r.hasVideo, isTrue);
      final s = r.singleFiles.first;
      expect(s.id, 32);
      expect(s.qualityLabel, '480P');
      expect(s.codec, BiliCodec.avc); // 编码来自 data.codecs，不在段里
      expect(s.width, 852);
      expect(s.height, 480);
      expect(s.durationMs, 632000); // durl 的 length 本来就是毫秒
      expect(s.dataSize, 40000000);
      // durl 段里没有码率字段，按 字节×8÷秒 反推：320000000000 ~/ 632000 = 506329 bps
      expect(s.bitrate, 506329);
      expect(r.needsSegmentMerge, isFalse);
    });

    test('多段 durl 会被标出来（单下一段不是完整视频）', () {
      final two = durlData();
      (two['durl'] as List).add({
        'order': 2,
        'length': 632000,
        'size': 40000000,
        'url': 'https://m.example/single-480-part2.mp4',
      });
      final r = BiliPlayUrl.fromJson(two, cid: 42);
      expect(r.isDash, isFalse);
      expect(r.needsSegmentMerge, isTrue);
      expect(r.singleFiles.length, 2);
    });
  });

  group('toVariants 排序', () {
    test('偏好 HEVC 时，1080P/HEVC 排第一', () {
      final v = biliToVariants(dash(), BiliCodec.hevc);
      expect(v.first.urls.first, 'https://m.example/v-hevc-80.m4s');
      expect(v.first.kind, VariantKind.bitRate);
    });

    test('偏好 auto（兼容性优先）时，同画质先 AVC', () {
      final v = biliToVariants(dash(), BiliCodec.auto);
      expect(v.first.urls.first, 'https://m.example/v-avc-80.m4s');
      // 剩下的视频流按 AVC → HEVC → AV1 的兼容性顺序
      expect(
        v.take(3).map((e) => e.urls.first),
        [
          'https://m.example/v-avc-80.m4s',
          'https://m.example/v-hevc-80.m4s',
          'https://m.example/v-av1-64.m4s',
        ],
      );
    });

    test('偏好 AV1 时压过清晰度档位（这是既定行为，不是 bug）', () {
      final v = biliToVariants(dash(), BiliCodec.av1);
      expect(v.first.urls.first, 'https://m.example/v-av1-64.m4s');
      expect(v.first.gearName, '720P 准高清-AV1');
    });

    test('同档同编码不因为码率差而换档：档位号优先于码率', () {
      // AV1 天生比 AVC 省码率，只比码率会把更优的编码判成更差的
      final v = biliToVariants(dash(), BiliCodec.auto);
      final avc = v.firstWhere((e) => e.urls.first.contains('v-avc-80'));
      final hevc = v.firstWhere((e) => e.urls.first.contains('v-hevc-80'));
      expect(avc.bitrate, greaterThan(hevc.bitrate));
      expect(v.indexOf(avc), lessThan(v.indexOf(hevc)));
    });

    test('视频变体全在音频变体之前，音频按档位表而不是 id 大小排', () {
      final v = biliToVariants(dash(), BiliCodec.auto);
      final kinds = v.map((e) => e.kind).toList();
      expect(kinds, [
        VariantKind.bitRate,
        VariantKind.bitRate,
        VariantKind.bitRate,
        VariantKind.audio,
        VariantKind.audio,
      ]);
      // 30216 的 id 比 30280 小却更差：按 kBiliAudioRank 排的话 192K 在前
      expect(v[3].urls.first, 'https://m.example/a-192k.m4s');
      expect(v[4].urls.first, 'https://m.example/a-64k.m4s');
      // 音频没有编码之分，gearName 就是档位名本身
      expect(v[3].gearName, '192K');
      expect(v[4].gearName, '64K');
    });

    test('每条变体的 urls 都是 baseUrl 在首位、镜像跟其后', () {
      final r = dash();
      final v = biliToVariants(r, BiliCodec.avc);
      for (final variant in v) {
        expect(variant.urls.first, isNotEmpty);
        expect(variant.usable, isTrue);
      }
      final avc = v.firstWhere((e) => e.urls.first.contains('v-avc-80'));
      expect(avc.urls, [
        'https://m.example/v-avc-80.m4s',
        'https://m.example/v-avc-80-b.m4s',
        'https://m.example/v-avc-80-c.m4s',
      ]);
      // 与流上的 baseUrl / backupUrls 完全对得上
      final stream = r.video.firstWhere((s) => s.baseUrl.contains('v-avc-80'));
      expect(avc.urls, [stream.baseUrl, ...stream.backupUrls]);
    });

    test('档位、尺寸、码率、大小都搬进了 MediaVariant', () {
      final v = biliToVariants(dash(), BiliCodec.auto);
      final avc = v.firstWhere((e) => e.urls.first.contains('v-avc-80'));
      expect(avc.width, 1920);
      expect(avc.height, 1080);
      expect(avc.fps, 30);
      expect(avc.bitrate, 3200000); // bandwidth 本来就是 bps，不换算
      expect(avc.dataSize, 253000000);
      expect(avc.format, 'm4s');
      expect(avc.extension, 'm4s');
      expect(avc.gearName, '1080P 高清-AVC');
      expect(avc.pixels, 1920 * 1080);
    });

    test('durl 退化路径的变体是完整 mp4，且只有一条视频', () {
      final v = biliToVariants(BiliPlayUrl.fromJson(durlData(), cid: 1), BiliCodec.auto);
      expect(v.length, 1);
      expect(v.single.kind, VariantKind.bitRate);
      expect(v.single.format, 'mp4');
      expect(v.single.extension, 'mp4');
      expect(v.single.urls, [
        'https://m.example/single-480.mp4',
        'https://m.example/single-480-b.mp4',
      ]);
      expect(v.single.gearName, '480P-AVC');
    });

    test('没有 baseUrl 的流直接丢掉，不给下载器留空任务', () {
      final data = {
        'quality': 80,
        'dash': {
          'video': [
            {'id': 80, 'codecs': 'avc1.640032', 'baseUrl': ''},
            {
              'id': 64,
              'codecs': 'avc1.640032',
              'baseUrl': 'https://m.example/ok.m4s',
            },
          ],
        },
      };
      final v = biliToVariants(BiliPlayUrl.fromJson(data), BiliCodec.auto);
      expect(v.length, 1);
      expect(v.single.urls.single, 'https://m.example/ok.m4s');
    });

    test('类上的 toVariants 就是那个纯函数，没加料', () {
      final r = dash();
      expect(
        BiliApi().toVariants(r, BiliCodec.hevc).map((e) => e.urls.first),
        biliToVariants(r, BiliCodec.hevc).map((e) => e.urls.first),
      );
    });
  });

  group('签名地址', () {
    test('host 真拼上去了，query 里带 w_rid 与 wts', () {
      // 这条测试的存在理由：`'https://$path?...'` 会拼出 `https:///x/...`，
      // 空 host 只在真发请求时才炸，不打网络的测试本来看不见它。
      final uri = biliSignedUri(
        '/x/player/wbi/playurl',
        {
          'cid': 765432109,
          'qn': 80,
          'bvid': 'BV1y4411o7Kp',
          'fnval': kBiliFnval,
          'fnver': 0,
          'fourk': 1,
        },
        // bili_wbi_test 里那对固定 key 算出来的 mixinKey
        'd330cc1b330db728904788b09ab15f82',
        wts: 1700000000,
      );
      expect(uri.host, 'api.bilibili.com');
      expect(uri.path, '/x/player/wbi/playurl');
      expect(uri.queryParameters['wts'], '1700000000');
      expect((uri.queryParameters['w_rid'] ?? '').length, 32);
      expect(uri.toString(), startsWith('https://api.bilibili.com/x/player/wbi/playurl?'));
      // aid 这种没传的可选项不该出现在 query 里（出现了就等于拿 null 去签了名）
      expect(uri.queryParameters.containsKey('aid'), isFalse);
    });
  });

  group('接口常量', () {
    test('公共请求头是同一份，且不含任何登录态', () {
      expect(biliRequestHeaders['Referer'], 'https://www.bilibili.com/');
      expect(biliRequestHeaders['Origin'], 'https://www.bilibili.com');
      expect(biliRequestHeaders['User-Agent'], contains('Chrome/'));
      expect(biliRequestHeaders.keys, isNot(contains('Cookie')));
      // 只有显式传 cookie 才会有 Cookie 头 —— 空就是匿名
      expect(biliRequestHeadersWith('').keys, isNot(contains('Cookie')));
      expect(biliRequestHeadersWith('a=1').length, biliRequestHeaders.length + 1);
    });

    test('本期 fnval 固定 4048（番剧的 143312 属后续阶段）', () {
      expect(kBiliFnval, 4048);
    });
  });
}

/// durl 退化路径的响应块（老稿件：没有 dash，编码信息在顶层）
Map<String, dynamic> durlData() => {
      'quality': 32,
      'codecs': ['avc1.640032'],
      'width': 852,
      'height': 480,
      'frame_rate': 25,
      'accept_quality': [32, 16],
      'accept_description': ['480P 清晰', '360P 流畅'],
      'durl': [
        {
          'order': 1,
          'length': 632000,
          'size': 40000000,
          'url': 'https://m.example/single-480.mp4',
          'backup_url': ['https://m.example/single-480-b.mp4'],
        },
      ],
    };
