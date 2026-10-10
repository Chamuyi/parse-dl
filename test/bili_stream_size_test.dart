import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_api.dart';

/// DASH 流的字节数。
///
/// 2026-10-10 真机（匿名、`qn=127`、`fnval=4048`）：返回的六条视频流与三条音频流
/// **都没有 `size` 字段**，解析出来的 `dataSize` 一律是 0 —— 界面会显示「0 B」，
/// 合并进度也没有分母。所以现在按 `bandwidth × 时长` 反推，并且用当次实测的
/// 真实字节数钉住估算精度。
void main() {
  /// 真机那条 2172 秒稿件里 **实际下载到的字节数**（curl 落盘后量出来的）：
  ///   视频 qn=32 avc1.640033, bandwidth=350352 → 95,104,081
  ///   音频 id=30280 mp4a.40.2, bandwidth=164211 → 44,579,075
  const realVideoBytes = 95104081;
  const realAudioBytes = 44579075;
  const durationSec = 2172;

  Map<String, dynamic> dashWithoutSize() => {
        'quality': 64,
        'format': 'mp4',
        'timelength': durationSec * 1000,
        'dash': {
          'duration': durationSec,
          'video': [
            {
              'id': 32,
              'codecs': 'avc1.640033',
              'bandwidth': 350352,
              'width': 854,
              'height': 480,
              'frame_rate': '30',
              'baseUrl': 'https://mcdn.example/v32.m4s',
              'backupUrl': ['https://mcdn.example/v32-b.m4s'],
              // 刻意不放 size —— 这就是真机响应的形状
            },
          ],
          'audio': [
            {
              'id': 30280,
              'codecs': 'mp4a.40.2',
              'bandwidth': 164211,
              'baseUrl': 'https://mcdn.example/a30280.m4s',
            },
          ],
        },
        'support_formats': [
          {'quality': 32, 'new_description': '480P 清晰'},
        ],
      };

  test('缺 size 时按 bandwidth × 时长 反推，误差锁在 1% 内', () {
    final r = BiliPlayUrl.fromJson(dashWithoutSize(), cid: 42528477088);
    final v = r.video.single;
    final a = r.audio.single;

    expect(v.dataSize, greaterThan(0), reason: '不能再交回 0');
    expect(
      (v.dataSize - realVideoBytes).abs() / realVideoBytes,
      lessThan(0.01),
      reason: '估算 ${v.dataSize} 与实测 $realVideoBytes 差得太远',
    );
    expect(
      (a.dataSize - realAudioBytes).abs() / realAudioBytes,
      lessThan(0.01),
      reason: '估算 ${a.dataSize} 与实测 $realAudioBytes 差得太远',
    );
  });

  test('给了 size 就用原值，不拿估算盖掉', () {
    final withSize = dashWithoutSize();
    (withSize['dash'] as Map)['video'] = [
      {
        ...(withSize['dash'] as Map)['video'][0] as Map,
        'size': 12345678,
      },
    ];
    final r = BiliPlayUrl.fromJson(withSize, cid: 1);
    expect(r.video.single.dataSize, 12345678);
  });

  test('bandwidth 或时长缺失时退回 0，不算出负数或垃圾值', () {
    final bare = dashWithoutSize();
    // 连容器级时长也拿掉 —— 这才是「什么都不知道」的那一格
    (bare['dash'] as Map).remove('duration');
    bare.remove('timelength');
    (bare['dash'] as Map)['video'] = [
      {
        'id': 32,
        'codecs': 'avc1.640033',
        'baseUrl': 'https://mcdn.example/v.m4s',
      },
    ];
    final r = BiliPlayUrl.fromJson(bare, cid: 1);
    expect(r.video.single.dataSize, 0);
    expect(r.video.single.bitrate, 0);
    expect(r.video.single.durationMs, 0);
  });

  test('正控制：把 bandwidth 改成十倍，估算必须跟着变大（判据不是恒真）', () {
    final boosted = dashWithoutSize();
    final v = (boosted['dash'] as Map)['video'][0] as Map;
    final normal = BiliPlayUrl.fromJson(boosted, cid: 1).video.single.dataSize;
    v['bandwidth'] = 3503520;
    final ten = BiliPlayUrl.fromJson(boosted, cid: 1).video.single.dataSize;
    expect(ten, greaterThan(normal * 9));
  });
}
