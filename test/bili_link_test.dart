import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
// `show Response` 是必要的：`package:http` 会连带导出 `MediaType`，
// 与本项目的 `models/media.dart` 里的同名枚举撞车，整个测试文件编译不过。
import 'package:http/http.dart' show Response;
import 'package:http/testing.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/bili_link.dart';

void main() {
  group('裸号', () {
    test('BV 号原样收下', () {
      final r = parseBiliRef('BV1ofPY3Thnr')!;
      expect(r.bvid, 'BV1ofPY3Thnr');
      expect(r.aid, isNull);
      expect(r.isUnsupported, isFalse);
      expect(r.needsExpand, isFalse);
    });

    test('前后空白与换行不算内容', () {
      expect(parseBiliRef('  BV1ofPY3Thnr \n')!.bvid, 'BV1ofPY3Thnr');
    });

    test('小写 bv 前缀归一化成大写（台账键与路径只该有一种写法）', () {
      expect(parseBiliRef('bv1ofPY3Thnr')!.bvid, 'BV1ofPY3Thnr');
    });

    test('av 号转成 int，前缀大小写都收', () {
      expect(parseBiliRef('av114514000')!.aid, 114514000);
      expect(parseBiliRef('AV114514000')!.aid, 114514000);
    });

    test('BV 号长度不对 / 含 base58 之外的字符 → 不认', () {
      expect(parseBiliRef('BV123'), isNull);
      // 0 / O / I / l 不在 base58 字母表里
      expect(parseBiliRef('BV1O0Il1O0Il'), isNull);
      expect(parseBiliRef('https://example.com/video/BV1ofPY3Thnr'), isNull);
    });
  });

  group('整条长链', () {
    test('/video/BV…?p=3 拿到 BV 号与分P号', () {
      final r = parseBiliRef(
          'https://www.bilibili.com/video/BV1S4pK6tEuR?p=3&vd_source=abc')!;
      expect(r.bvid, 'BV1S4pK6tEuR');
      expect(r.partIndex, 3);
    });

    test('没有 ?p= 时 partIndex 是 null（由调用方决定默认，不是 0 也不是 1）', () {
      final r = parseBiliRef('https://www.bilibili.com/video/BV1S4pK6tEuR')!;
      expect(r.partIndex, isNull);
    });

    test('?p= 是非数字时不炸，退回 null', () {
      final r =
          parseBiliRef('https://www.bilibili.com/video/BV1S4pK6tEuR?p=abc')!;
      expect(r.bvid, 'BV1S4pK6tEuR');
      expect(r.partIndex, isNull);
    });

    test('/video/av… 也认', () {
      final r = parseBiliRef('https://www.bilibili.com/video/av114514000')!;
      expect(r.aid, 114514000);
    });

    test('m. 子站与大小写混排都收', () {
      expect(parseBiliRef('https://m.bilibili.com/video/BV1S4pK6tEuR')!.bvid,
          'BV1S4pK6tEuR');
      expect(parseBiliRef('https://www.bilibili.com/video/bv1s4pk6teur')!.bvid,
          isNotNull);
    });

    test('https 与 http 都行', () {
      expect(parseBiliRef('http://www.bilibili.com/video/BV1S4pK6tEuR')!.bvid,
          'BV1S4pK6tEuR');
    });
  });

  group('短链', () {
    test('b23.tv 标成「需要先展开」，不猜目标', () {
      final r = parseBiliRef('https://b23.tv/aBc1234')!;
      expect(r.needsExpand, isTrue);
      expect(r.shortLink, 'https://b23.tv/aBc1234');
      expect(r.bvid, isNull);
      expect(r.aid, isNull);
    });

    test('短链后面跟着的垃圾路径不干扰判断', () {
      expect(parseBiliRef('https://b23.tv/aBc1234?is_hot=1')!.needsExpand, isTrue);
    });
  });

  group('认得出来但本期不做', () {
    test('番剧 / 影视 / 合集 / 空间 / 专栏 / 直播各自给出原因', () {
      for (final probe in {
        'https://www.bilibili.com/bangumi/play/ep123456': '番剧',
        'https://www.bilibili.com/media/sss/123': '影视',
        'https://www.bilibili.com/medialist/detail/ml1': '合集',
        'https://space.bilibili.com/349326425505': '空间',
        'https://www.bilibili.com/read/cv12345': '专栏',
        'https://live.bilibili.com/123': '直播',
      }.entries) {
        final r = parseBiliRef(probe.key);
        expect(r, isNotNull, reason: '${probe.key} 应当被认出来');
        expect(r!.isUnsupported, isTrue, reason: '${probe.value} 不该走普通稿件');
        expect(r.bvid, isNull);
        expect(r.aid, isNull);
      }
    });

    test('合集那条不许被当成普通稿件悄悄解析', () {
      // 回归：早先的写法是 `/list` 没进段列表判据，会掉到「路径里随便哪儿找 BV」那条
      final r = parseBiliRef('https://www.bilibili.com/list/user,aid_1,1')!;
      expect(r.isUnsupported, isTrue);
    });
  });

  group('完全不认的输入', () {
    test('空串 / 纯空白 / 别的网站 / 只有协议头', () {
      for (final bad in ['', '   ', 'https://www.youtube.com/watch?v=x', 'https://', '抖音']) {
        expect(parseBiliRef(bad), isNull, reason: '不该认: $bad');
      }
    });

    test('正控制：同一条真链接必须能认（防上面那条因为规则改动而空跑）', () {
      expect(parseBiliRef('https://www.bilibili.com/video/BV1S4pK6tEuR'),
          isNotNull);
    });
  });

  group('分P → Media', () {
    Media build() => biliPartMedia(
          bvid: 'BV1S4pK6tEuR',
          aid: 64417133,
          workTitle: '把一年的海边拍成十二段',
          upperName: '海边的猫',
          upperMid: 349326425505,
          publishTime: DateTime.fromMillisecondsSinceEpoch(1705756536000),
          cover: 'https://i0.hdslb.com/bfs/archive/example_cover.jpg',
          partTotal: 12,
          partIndex: 3,
          cid: 42528477088,
          partTitle: '第3P 冬天',
          durationMs: 632000,
        );

    test('落进通用字段 + bili 块，source 是 bili', () {
      final m = build();
      expect(m.source, 'bili');
      expect(m.id, 'BV1S4pK6tEuR-3');
      expect(m.type, MediaType.video);
      expect(m.tweetId, 'BV1S4pK6tEuR');
      expect(m.tweetText, '把一年的海边拍成十二段');
      expect(m.userName, '海边的猫');
      expect(m.userId, '349326425505');
      expect(m.mediaIndex, 3);
      expect(m.durationMs, 632000);
      expect(m.bili!.cid, '42528477088');
      expect(m.bili!.partTotal, 12);
      expect(m.bili!.partTitle, '第3P 冬天');
    });

    test('解析阶段刻意不带下载地址（入队时才按设置选流）', () {
      final m = build();
      expect(m.url, isEmpty);
      expect(m.chosen, isNull);
      expect(m.variants, isEmpty);
    });

    test('落盘 JSON 里 bili 块在、且不含 variants', () {
      final j = build().toJson();
      expect(j['bili'], isA<Map>());
      expect((j['bili'] as Map)['bvid'], 'BV1S4pK6tEuR');
      expect(j.containsKey('variants'), isFalse);
      // 读回来还是同一批值
      final back = Media.fromJson(j.cast<String, dynamic>());
      expect(back.bili!.cid, '42528477088');
      expect(back.source, 'bili');
    });
  });

  group('短链展开（假 client，不碰网）', () {
    const target = 'https://www.bilibili.com/video/BV1S4pK6tEuR?p=3';

    test('302 的 Location 带着分P号，必须原样解析出来', () async {
      final seen = <String>[];
      final c = MockClient((req) async {
        seen.add(req.method);
        return Response('', 302, headers: {'location': target});
      });
      final r = await expandBiliShortLink('https://b23.tv/aBc1234', client: c);
      expect(r!.bvid, 'BV1S4pK6tEuR');
      expect(r.partIndex, 3);
      expect(seen, ['HEAD'], reason: '第一跳就该停住，不用再去 GET');
    });

    test('HEAD 没有 Location 时退到 GET，从正文里抠 BV 号', () async {
      final seen = <String>[];
      final c = MockClient((req) async {
        seen.add(req.method);
        if (req.method == 'HEAD') return Response('', 200);
        // 不带 content-type —— 故意让「按响应头猜编码」这条路失效
        return Response.bytes(
            utf8.encode('<a href="/video/BV1S4pK6tEuR">看这里</a>'), 200);
      });
      final r = await expandBiliShortLink('https://b23.tv/aBc1234', client: c);
      expect(r!.bvid, 'BV1S4pK6tEuR');
      expect(seen, ['HEAD', 'GET'], reason: '第二级退路必须真的被走到');
    });

    test('三条路都走空 → 返回 null，不抛', () async {
      final c = MockClient((req) async => Response('nothing here', 200));
      expect(await expandBiliShortLink('https://b23.tv/aBc1234', client: c),
          isNull);
    });

    test('Location 指向另一个短链时不再递归（避免来回跳）', () async {
      final c = MockClient((req) async =>
          Response('', 302, headers: {'location': 'https://b23.tv/other'}));
      final r = await expandBiliShortLink('https://b23.tv/aBc1234', client: c);
      expect(r, isNull, reason: '二次短链交给上层决定，这里不无限跟');
    });

    test('正控制：把 Location 换成番剧页，必须落进「本期不做」而不是解出 BV', () async {
      final c = MockClient((req) async => Response('', 302, headers: {
            'location': 'https://www.bilibili.com/bangumi/play/ep123456'
          }));
      final r = await expandBiliShortLink('https://b23.tv/aBc1234', client: c);
      expect(r!.bvid, isNull);
      expect(r.isUnsupported, isTrue);
    });
  });
}
