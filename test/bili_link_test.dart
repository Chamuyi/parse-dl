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
    test('番剧 / 影视 / 专栏 / 直播各自给出原因', () {
      // 2026-10-11：`space` / `list` / `medialist` 三行已从「不支持表」里摘掉，
      // 它们现在走下面的「列表类链接」那组判据；这一组只留**仍然不做**的形态，
      // 判据一条没放松（每条都还必须是 isUnsupported，且不许解出 BV/AV）。
      for (final probe in {
        'https://www.bilibili.com/bangumi/play/ep123456': '番剧',
        'https://www.bilibili.com/media/sss/123': '影视',
        'https://www.bilibili.com/read/cv12345': '专栏',
        'https://www.bilibili.com/opus/1234567': '动态',
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

    test('抄坏的列表链接仍是「不支持」，但给出的是结构化 code', () {
      // 上面那条现在落进 BiliLinkProblem（不再是表里的中文句子）：
      // 本层的纪律是「不新增用户可见中文字面量」，界面按 code 接文案。
      final r = parseBiliRef('https://www.bilibili.com/list/user,aid_1,1')!;
      expect(r.problem, BiliLinkProblem.noListIdentity);
      expect(r.unsupportedReason, 'bili-list-no-identity');
      expect(r.isList, isFalse);
      // 正控制：同一条链接换成能判身份的写法，就必须落进列表而不是报错
      expect(parseBiliRef('https://www.bilibili.com/list/123?sid=456')!.isList,
          isTrue);
    });
  });

  group('列表类链接：认形状、抽身份（纯解析，一个请求都不发）', () {
    test('space.bilibili.com/{mid} → 主页投稿，mid 取自路径', () {
      final r = parseBiliRef('https://space.bilibili.com/349326425505')!;
      expect(r.isUnsupported, isFalse);
      expect(r.isList, isTrue);
      expect(r.list!.kind, BiliListKind.space);
      expect(r.list!.mid, 349326425505);
      expect(r.bvid, isNull);
      expect(r.aid, isNull);
      // 尾部斜杠与带 query 的写法同解
      expect(
          parseBiliRef('https://space.bilibili.com/349326425505/')!.list!.mid,
          349326425505);
      expect(
          parseBiliRef('https://space.bilibili.com/349326425505?spm_id_from=333')!
              .list!
              .mid,
          349326425505);
    });

    test('lists/{id}?type=season|series 各自落到对应的一支，互不越界', () {
      final season = parseBiliRef(
          'https://space.bilibili.com/228292951/lists/9225450?type=season')!;
      expect(season.list!.kind, BiliListKind.season);
      expect(season.list!.seasonId, 9225450);
      expect(season.list!.seriesId, isNull);
      expect(season.list!.listId, 9225450);

      final series = parseBiliRef(
          'https://space.bilibili.com/228292951/lists/1970940?type=series')!;
      expect(series.list!.kind, BiliListKind.series);
      expect(series.list!.seriesId, 1970940);
      expect(series.list!.seasonId, isNull);
    });

    test('没写 type 的 lists/{id} → 身份待判，只带 sid', () {
      final r = parseBiliRef('https://space.bilibili.com/228292951/lists/1970940')!;
      expect(r.list!.kind, BiliListKind.unknown);
      expect(r.list!.sid, 1970940);
      expect(r.list!.needsResolve, isTrue);
      // 待判的目标不许提前带上任何一支的 id（否则「互斥」就成了空话）
      expect(r.list!.seasonId, isNull);
      expect(r.list!.seriesId, isNull);
      expect(r.list!.favId, isNull);
    });

    test('播放页 list/{mid}?sid=…&oid=…&bvid=… → 待判，且带上那条视频', () {
      final r = parseBiliRef('https://www.bilibili.com/list/228292951'
          '?sid=1970940&oid=459386222&bvid=BV1U5411N7sc')!;
      expect(r.list!.kind, BiliListKind.unknown);
      expect(r.list!.mid, 228292951);
      expect(r.list!.sid, 1970940);
      expect(r.list!.currentBvid, 'BV1U5411N7sc');
      expect(r.list!.hasVideo, isTrue);
      expect(r.bvid, isNull, reason: '列表链接不许被当单条稿件解出来');
    });

    test('只有 oid 没有 bvid 时，oid 当 aid 用', () {
      final r = parseBiliRef(
          'https://www.bilibili.com/list/228292951?sid=1970940&oid=459386222')!;
      expect(r.list!.currentAid, 459386222);
      expect(r.list!.currentBvid, isEmpty);
      expect(r.list!.hasVideo, isTrue);
    });

    test('小写 bvid= 也收，并归一化成 BV 开头', () {
      final r = parseBiliRef(
          'https://www.bilibili.com/list/228292951?sid=1&bvid=bv1U5411N7sc')!;
      expect(r.list!.currentBvid, 'BV1U5411N7sc');
    });

    test('medialist/detail/ml… 与 list/ml… 都是收藏夹', () {
      final a = parseBiliRef('https://www.bilibili.com/medialist/detail/ml1155866758')!;
      expect(a.list!.kind, BiliListKind.fav);
      expect(a.list!.favId, 1155866758);
      expect(a.list!.listId, 1155866758);
      final b = parseBiliRef('https://www.bilibili.com/list/ml1155866758?bvid=BV1U5411N7sc')!;
      expect(b.list!.kind, BiliListKind.fav);
      expect(b.list!.favId, 1155866758);
      expect(b.list!.currentBvid, 'BV1U5411N7sc');
    });

    test('space…/favlist?fid=… → 收藏夹，fid 是 media_id', () {
      final r = parseBiliRef(
          'https://space.bilibili.com/476593058/favlist?fid=1155866758&fid_type=1')!;
      expect(r.list!.kind, BiliListKind.fav);
      expect(r.list!.favId, 1155866758);
      expect(r.list!.mid, 476593058);
    });

    test('fid=view_later（稍后再看）报结构化 code，不猜 id', () {
      final r = parseBiliRef(
          'https://space.bilibili.com/476593058/favlist?fid=view_later')!;
      expect(r.isUnsupported, isTrue);
      expect(r.problem, BiliLinkProblem.favIdUnresolved);
      expect(r.unsupportedReason, 'bili-fav-id-not-numeric');
      expect(r.list, isNull);
    });

    test('query 里的长数字不许污染 mid / sid / favId', () {
      // 参照实现踩过的那一类坑：链接的查询串带着 number / oid / share_uid 之类
      // 一长串数字，拿整条链接去搜数字会先命中它们。
      final r = parseBiliRef('https://space.bilibili.com/1234/favlist'
          '?fid=99&number=1234567890123&keyword=abc1234567890')!;
      expect(r.list!.mid, 1234);
      expect(r.list!.favId, 99);
      expect(r.list!.keyword, 'abc1234567890');
    });

    test('?keyword= 原样带出来（URL 编码的中文要解开）', () {
      final r = parseBiliRef(
          'https://space.bilibili.com/123?keyword=%E6%B5%8B%E8%AF%95')!;
      expect(r.list!.kind, BiliListKind.space);
      expect(r.list!.keyword, '测试');
    });

    test('正控制：同一形状的链接，非列表形态仍然不该被判成列表', () {
      // 上面那组「是列表」的判据必须是**认出来了**才成立，不是把所有
      // bilibili 链接都兜进列表 —— 拿一条主页链接当反例。
      final r = parseBiliRef('https://www.bilibili.com/bangumi/play/ep123456')!;
      expect(r.isList, isFalse);
      expect(r.list, isNull);
    });
  });

  group('列表身份判定链（注入假回调，不碰网）', () {
    test('链接明说 type=series → 一个请求都不发，更不会去查合集', () async {
      final log = _CallLog();
      final ref = parseBiliRef(
          'https://space.bilibili.com/228292951/lists/1970940?type=series')!;
      final out = await resolveBiliListTarget(
        ref.list!,
        view: _view(null, log),
        seriesProbe: _probe(null, log),
      );
      expect(out.kind, BiliListKind.series);
      expect(out.seriesId, 1970940);
      expect(log.views, isEmpty, reason: '明说 series 还去查 view 就是多此一举');
      expect(log.probes, isEmpty);
    });

    test('链接明说 type=season → 同样不发请求，也不会去看系列探针', () async {
      final log = _CallLog();
      final ref = parseBiliRef(
          'https://space.bilibili.com/228292951/lists/9225450?type=season')!;
      final out = await resolveBiliListTarget(
        ref.list!,
        view: _view({'ugc_season': {'id': 1, 'mid': 1}}, log),
        seriesProbe: _probe({'name': 'x', 'mid': 1}, log),
      );
      expect(out.kind, BiliListKind.season);
      expect(out.seasonId, 9225450);
      expect(out.seriesId, isNull);
      expect(log.views, isEmpty);
      expect(log.probes, isEmpty);
    });

    test('正控制：身份未定的同一条链接确实会发请求（防上面两条空跑）', () async {
      final log = _CallLog();
      final ref =
          parseBiliRef('https://www.bilibili.com/list/228292951?sid=1970940')!;
      expect(ref.list!.kind, BiliListKind.unknown);
      await resolveBiliListTarget(
        ref.list!,
        view: _view({'ugc_season': {'id': 1, 'mid': 1}}, log),
        seriesProbe: _probe({'name': 'galgame', 'mid': 228292951}, log),
      );
      expect(log.probes, [1970940], reason: '没 sid 也没视频时才该去探系列');
      expect(log.views, isEmpty);
    });

    test('带视频 → 先看 ugc_season，id 对上就按合集，mid 用接口给的', () async {
      final log = _CallLog();
      final ref = parseBiliRef('https://www.bilibili.com/list/999999'
          '?sid=9225450&bvid=BV1Sfa26cE37')!;
      final out = await resolveBiliListTarget(
        ref.list!,
        // 接口给的 mid 与链接路径里那个**故意不同**：要的是接口赢
        view: _view({'ugc_season': {'id': 9225450, 'mid': 228292951}}, log),
        seriesProbe: _probe(null, log),
      );
      expect(out.kind, BiliListKind.season);
      expect(out.seasonId, 9225450);
      expect(out.mid, 228292951, reason: 'mid 一律用接口给的，不用链接路径里的数字');
      expect(log.views, ['BV1Sfa26cE37']);
      expect(log.probes, isEmpty, reason: '已经判成合集就不必再探系列');
      expect(out.currentBvid, 'BV1Sfa26cE37', reason: '链接指向那一条要留住，界面靠它定位');
    });

    test('链接没给 sid、只给视频 → 照样按 ugc_season 判合集', () async {
      final log = _CallLog();
      final ref = parseBiliRef(
          'https://www.bilibili.com/list/228292951?bvid=BV1Sfa26cE37')!;
      expect(ref.list!.kind, BiliListKind.unknown);
      final out = await resolveBiliListTarget(
        ref.list!,
        view: _view({'ugc_season': {'id': 4242, 'mid': 228292951}}, log),
        seriesProbe: _probe(null, log),
      );
      expect(out.kind, BiliListKind.season);
      expect(out.seasonId, 4242);
      expect(log.probes, isEmpty);
    });

    test('ugc_season 与 sid 对不上 → 退回探系列；探针命中就是系列', () async {
      final log = _CallLog();
      final ref = parseBiliRef('https://www.bilibili.com/list/228292951'
          '?sid=1970940&bvid=BV1Sfa26cE37')!;
      final out = await resolveBiliListTarget(
        ref.list!,
        view: _view({'ugc_season': {'id': 9225450, 'mid': 228292951}}, log),
        seriesProbe:
            _probe({'name': 'galgame', 'mid': 777, 'series_id': 1970940}, log),
      );
      expect(out.kind, BiliListKind.series);
      expect(out.seriesId, 1970940);
      expect(out.mid, 777);
      expect(out.seriesMeta, isNotNull, reason: '探针顺手拿到的 meta 要带回去复用');
      expect(log.probes, [1970940]);
      expect(log.views, ['BV1Sfa26cE37']);
    });

    test('探针说不是系列 → 按合集处理（sid 当 season_id）', () async {
      final log = _CallLog();
      final ref =
          parseBiliRef('https://www.bilibili.com/list/228292951?sid=9225450')!;
      final out = await resolveBiliListTarget(
        ref.list!,
        view: _view(null, log),
        seriesProbe: _probe(null, log),
      );
      expect(out.kind, BiliListKind.season);
      expect(out.seasonId, 9225450);
      expect(out.seriesMeta, isNull);
    });

    test('既没 sid 也没视频 → 纯解析阶段就报错，resolver 也拦', () async {
      expect(parseBiliRef('https://www.bilibili.com/list/228292951')!.isUnsupported,
          isTrue);
      // 直接构造一个空身份的待判目标（绕过纯解析）也要被拦下来，不许静默发请求
      await expectLater(
        resolveBiliListTarget(
          BiliListTarget(kind: BiliListKind.unknown, mid: 1),
          view: ({String? bvid, int? aid}) async => null,
          seriesProbe: (int id) async => null,
        ),
        throwsArgumentError,
      );
    });

    test('keyword 在判定之后还在（不许被 resolver 吃掉）', () async {
      final ref = parseBiliRef('https://www.bilibili.com/list/228292951'
          '?sid=1970940&keyword=%E8%AF%95%E5%90%AC')!;
      final out = await resolveBiliListTarget(
        ref.list!,
        view: ({String? bvid, int? aid}) async => null,
        seriesProbe: (int id) async => {'name': 'x', 'mid': 2},
      );
      expect(out.kind, BiliListKind.series);
      expect(out.keyword, '试听');
    });
  });

  group('列表目标的互斥（构造时就卡住）', () {
    test('series 目标带 seasonId → ArgumentError', () {
      expect(
        () => BiliListTarget(
            kind: BiliListKind.series, mid: 1, seriesId: 2, seasonId: 3),
        throwsArgumentError,
      );
      expect(
        () => BiliListTarget(
            kind: BiliListKind.season, mid: 1, seasonId: 3, seriesId: 2),
        throwsArgumentError,
      );
      expect(
        () => BiliListTarget(kind: BiliListKind.fav, favId: 1, seasonId: 2),
        throwsArgumentError,
      );
      expect(
        () => BiliListTarget(kind: BiliListKind.unknown, sid: 1, seriesId: 2),
        throwsArgumentError,
      );
      // 正控制：合法组合必须建得出来，否则上面四条是空断言
      expect(BiliListTarget(kind: BiliListKind.series, seriesId: 2).listId, 2);
      expect(
          BiliListTarget(kind: BiliListKind.unknown, sid: 2).needsResolve, isTrue);
      expect(BiliListTarget(kind: BiliListKind.space, mid: 2).listId, isNull);
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

/// 记录判定链里哪些回调被调过 —— 「明说 series 不许去查合集」这条
/// 只能靠这份清单断言（返回值本身看不出发没发过请求）。
class _CallLog {
  final List<String> views = [];
  final List<int> probes = [];
}

BiliViewFetcher _view(Map<String, dynamic>? result, _CallLog log) =>
    ({String? bvid, int? aid}) async {
      log.views.add(bvid ?? 'aid:$aid');
      return result;
    };

BiliSeriesProbe _probe(Map<String, dynamic>? result, _CallLog log) =>
    (int seriesId) async {
      log.probes.add(seriesId);
      return result;
    };
