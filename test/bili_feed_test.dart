import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_feed.dart';

/// 字段名与层级照 2026-10-10 真实响应的结构（`data.item[]`），**值全是虚构的**。
Map<String, dynamic> av(String bvid,
    {String goto = 'av', String pic = 'http://i0.hdslb.com/bfs/archive/x.jpg',
     int duration = 213, int id = 114514000}) {
  return {
    'goto': goto,
    'id': id,
    'bvid': bvid,
    'cid': 42528477088,
    'duration': duration,
    'pubdate': 1705756536,
    'title': '示例标题$goto',
    'uri': 'https://www.bilibili.com/video/$bvid',
    'pic': pic,
    'owner': {'mid': 349326425505, 'name': '示例UP主', 'face': ''},
    'stat': {'view': 12345, 'danmaku': 66, 'like': 777, 'vt': 0},
    'av_feature': null,
    'business_info': null,
    'ogv_info': null,
    'room_info': null,
    'rcmd_reason': null,
    'dislike_switch': 0,
    'is_followed': 0,
    'pos': 1,
    'track_id': 'track-example',
  };
}

Map<String, dynamic> data(List<Map<String, dynamic>> items) => {
      'item': items,
      'mid': 0,
      'preload_expose_pct': 0.5,
    };

void main() {
  group('推荐流解析', () {
    test('正常一条：秒转毫秒、http 补 https、owner/stat 拆平', () {
      final r = biliFeedItems(data([av('BV1ofPY3Thnr')]));
      expect(r, hasLength(1));
      final it = r.single;
      expect(it.bvid, 'BV1ofPY3Thnr');
      expect(it.aid, 114514000);
      expect(it.cid, 42528477088);
      expect(it.durationMs, 213 * 1000, reason: '推荐流的 duration 是秒');
      expect(it.cover, startsWith('https://'));
      expect(it.upperName, '示例UP主');
      expect(it.upperMid, 349326425505);
      expect(it.viewCount, 12345);
      expect(it.publishTime, DateTime.fromMillisecondsSinceEpoch(1705756536000));
    });

    test('非 av 的条目一律跳过（直播间 / 专栏 / 番剧 / 广告混在同一数组里）', () {
      final r = biliFeedItems(data([
        av('BV1ofPY3Thnr'),
        av('live', goto: 'live'),
        av('read', goto: 'read'),
        av('bangumi', goto: 'bangumi'),
        av('ad', goto: 'ad'),
      ]));
      expect(r.map((e) => e.bvid), ['BV1ofPY3Thnr']);
    });

    test('正控制：把 goto 改回 av，同一条就必须被收进来', () {
      final item = av('BV1ofPY3Thnr', goto: 'live');
      expect(biliFeedItems(data([item])), isEmpty);
      item['goto'] = 'av';
      expect(biliFeedItems(data([item])), hasLength(1));
    });

    test('没有 bvid / 空白 bvid 的条目不要（否则 view 展开时报错看不懂）', () {
      final noBvid = av('BV1ofPY3Thnr')..['bvid'] = '';
      final blankBvid = av('BV1ofPY3Thnr')..['bvid'] = '   ';
      expect(biliFeedItems(data([noBvid, blankBvid])), isEmpty);
    });

    test('协议相对地址与 https 都补齐', () {
      for (final probe in [
        '//i0.hdslb.com/bfs/archive/a.jpg',
        'https://i0.hdslb.com/bfs/archive/b.jpg',
      ]) {
        final r = biliFeedItems(data([av('BV1ofPY3Thnr', pic: probe)]));
        expect(r.single.cover.startsWith('https://'), isTrue, reason: probe);
      }
    });

    test('缺 item / 类型不对 / owner 为 null → 出空表而不是抛', () {
      expect(biliFeedItems({}), isEmpty);
      expect(biliFeedItems({'item': '不是列表'}), isEmpty);
      expect(biliFeedItems(data([av('BV1ofPY3Thnr')..['owner'] = null])),
          hasLength(1), reason: '少了 UP 主不该整条丢');
      final r = biliFeedItems(data([av('BV1ofPY3Thnr')..['owner'] = null]));
      expect(r.single.upperName, isEmpty);
      expect(r.single.upperMid, 0);
    });

    test('pubdate 为 0 时 publishTime 是 null，不编出 1970', () {
      final r = biliFeedItems(data([av('BV1ofPY3Thnr')..['pubdate'] = 0]));
      expect(r.single.publishTime, isNull);
    });

    test('toSeedMedia 只是「够显示」的种子，不带取流地址', () {
      final m = biliFeedItems(data([av('BV1ofPY3Thnr')])).single.toSeedMedia();
      expect(m.source, 'bili');
      expect(m.tweetId, 'BV1ofPY3Thnr');
      expect(m.url, isEmpty);
      expect(m.chosen, isNull);
      expect(m.bili!.partTotal, 1);
      expect(m.durationMs, 213000);
    });
  });

  group('随机抽样', () {
    List<int> pool(int n) => List.generate(n, (i) => i);

    test('固定种子可复现，且不重复', () {
      final a = sampleDistinct(pool(10), 3, Random(7));
      final b = sampleDistinct(pool(10), 3, Random(7));
      expect(a, b);
      expect(a.toSet().length, 3);
    });

    test('抽干不补：count 大于总数时返回全部', () {
      expect(sampleDistinct(pool(2), 5, Random(1)), [0, 1]);
    });

    test('count <= 0 / 空表都返回空，不抛', () {
      expect(sampleDistinct(pool(5), 0, Random(1)), isEmpty);
      expect(sampleDistinct(pool(5), -3, Random(1)), isEmpty);
      expect(sampleDistinct(<int>[], 3, Random(1)), isEmpty);
    });

    test('跑 200 轮验收口径的抽样，每轮 3 条互不相同', () {
      final items = biliFeedItems(
          data(List.generate(20, (i) => av('BV1ofPY3Thn$i'.padRight(12, 'x')))));
      expect(items.length, 20);
      for (var round = 0; round < 200; round++) {
        final picked = sampleDistinct(items, 3, Random(round));
        expect(picked.length, 3);
        expect(picked.map((e) => e.bvid).toSet().length, 3,
            reason: '第 $round 轮抽到重复：$picked');
      }
    });

    test('正控制：把总数缩到 2 条时，同种子就不可能给出 3 条', () {
      expect(sampleDistinct(pool(2), 3, Random(7)).length, 2);
    });
  });
}
