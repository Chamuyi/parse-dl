import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/services/bili_danmaku.dart';
import 'package:parse_dl/services/bili_dm_proto.dart';

/// 弹幕取数 + 三种格式渲染 + 契约登记的测试。
///
/// **全程不发网络**：取数层只认注入进来的 `fetchSegment`，测试给的是内存里的假字节；
/// 三个渲染函数都是纯函数。真夹具（匿名取回的 seg1/seg2）负责证明「解出来的东西
/// 确实能一路走到产物」，手工构造的条目负责触发夹具里没有的分支（同刻多条、
/// 顶部/底部、特效类、超长文本、屏蔽池）—— 那些造出来是允许的，每处都标了造法。
void main() {
  late Uint8List seg1;
  late Uint8List seg2;

  setUpAll(() {
    seg1 = File('test/fixtures/fixture_BV1uzas6vEBB_seg1.bin').readAsBytesSync();
    seg2 = File('test/fixtures/fixture_BV1uzas6vEBB_seg2.bin').readAsBytesSync();
  });

  /// 假取数器：记下每次被要求的段号，可指定某几段抛错。
  /// `bySegment` 没给的段回空字节（= 这一段真没有弹幕，与「失败」是两回事）。
  BiliDanmakuSegmentFetcher fakeFetcher(
    Map<int, List<int>> bySegment, {
    Set<int> failOn = const {},
    required List<int> requested,
  }) => (cid, segmentIndex) async {
    requested.add(segmentIndex);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (failOn.contains(segmentIndex)) {
      throw const BiliDmProtoException('故意的段级失败');
    }
    return bySegment[segmentIndex] ?? const [];
  };

  BiliDanmaku item({
    int id = 1,
    int stime = 0,
    int mode = 1,
    int size = 25,
    int color = 0xFFFFFF,
    String text = '测试弹幕',
    int date = 1790000000,
    int pool = 0,
  }) => BiliDanmaku(
    id: id,
    stime: stime,
    mode: mode,
    size: size,
    color: color,
    text: text,
    date: date,
    pool: pool,
  );

  BiliConfig danmakuConfig({
    BiliDanmakuFormat format = BiliDanmakuFormat.ass,
    bool embed = false,
    BiliContainer container = BiliContainer.mp4,
    bool merge = true,
  }) => BiliConfig()
    ..saveDanmaku = true
    ..danmakuFormat = format
    ..embedSubtitleTrack = embed
    ..container = container
    ..mergeAfterDownload = merge;

  // ── 把 ass 产物里的 Dialogue 拆回字段，断言才不用把正则糊在业务断言里 ──
  final dialogueRe = RegExp(
    r'^Dialogue: (\d+),([^,]*),([^,]*),([^,]*),([^,]*),(\d+),(\d+),(\d+),([^,]*),(.*)$',
  );

  /// 覆盖块 = 开头的 `{...}`；文本里转义过的 `\{` `\}` 不能当定界符
  int endOfOverrideBlock(String body) {
    if (!body.startsWith('{')) return 0;
    for (var i = 1; i < body.length; i++) {
      if (body.codeUnitAt(i) == 0x7D && body[i - 1] != r'\') return i + 1;
    }
    return 0;
  }

  List<_AssDialogue> parseDialogues(String ass) {
    final out = <_AssDialogue>[];
    for (final line in ass.split('\n')) {
      if (!line.startsWith('Dialogue:')) continue;
      final m = dialogueRe.firstMatch(line);
      if (m == null) throw StateError('Dialogue 行形状不符：$line');
      final body = m.group(10)!;
      final cut = endOfOverrideBlock(body);
      out.add(
        _AssDialogue(
          startMs: parseAssTime(m.group(2)!),
          endMs: parseAssTime(m.group(3)!),
          style: m.group(4)!,
          override: body.substring(0, cut),
          text: body.substring(cut),
        ),
      );
    }
    return out;
  }

  /// 从覆盖块里取 y（滚动取 `\move` 的 y，固定取 `\pos` 的 y）—— y 相同即同一行
  ///
  /// ⚠️ **`\move` 是一对括号四个参数**。这里原来写的是两对括号
  /// `\move\(…\)\(…\)` —— 那个正则与实现一起错，于是 1400+ 条用例全绿，
  /// 而 VLC / PotPlayer 里所有滚动弹幕**停在左上角不动**（标签非法被整条忽略）。
  /// 规范见 Aegisub《ASS Tags》：只列 `\move(x1,y1,x2,y2)` 与带 t1,t2 的六参形。
  int yOf(_AssDialogue d) {
    final move =
        RegExp(r'\\move\((-?\d+),(-?\d+),(-?\d+),(-?\d+)\)').firstMatch(d.override);
    if (move != null) return int.parse(move.group(2)!);
    final pos = RegExp(r'\\pos\(([^)]*)\)').firstMatch(d.override);
    if (pos != null) return int.parse(pos.group(1)!.split(',').last);
    throw StateError('覆盖块里既没有 \\move 也没有 \\pos：${d.override}');
  }

  Iterable<String> dialogueLines(String ass) =>
      ass.split('\n').where((l) => l.startsWith('Dialogue:'));

  group('分段数口径', () {
    test('实测那条 3 小时稿件（10990 秒）是 31 段', () {
      expect(biliDanmakuSegmentCount(10990), 31);
    });

    test('边界按整段进位，不抹平', () {
      expect(biliDanmakuSegmentCount(1), 1);
      expect(biliDanmakuSegmentCount(359), 1);
      expect(biliDanmakuSegmentCount(360), 1);
      expect(biliDanmakuSegmentCount(361), 2);
      expect(biliDanmakuSegmentCount(720), 2);
      expect(biliDanmakuSegmentCount(721), 3);
    });

    test('时长未知时仍取 1 段，而不是整批不请求', () {
      // 拿不到时长是元数据层的问题；返回 0 会让「勾了弹幕却一个请求都不发」变成静默
      expect(biliDanmakuSegmentCount(0), 1);
      expect(biliDanmakuSegmentCount(-5), 1);
    });
  });

  group('取数：限并发、回报进度、一段失败不拖垮整批', () {
    test('31 段全部按 1 基段号各请求一次', () async {
      final requested = <int>[];
      final result = await biliFetchDanmaku(
        cid: 42231463949,
        segmentCount: 31,
        fetchSegment: fakeFetcher({1: seg1, 2: seg2}, requested: requested),
        maxConcurrent: 3,
      );
      expect(requested.length, 31, reason: '每段都要取，一段都不能少');
      expect(requested.toSet().length, 31, reason: '段号不许重发');
      expect(requested..sort(), List<int>.generate(31, (i) => i + 1));
      expect(result.segmentCount, 31);
      expect(result.items.length, 6); // 夹具的 5 + 1 条
    });

    test('并发上限确实生效（自增计数器盯住同时在飞数）', () async {
      var inflight = 0;
      var peak = 0;
      final seen = <int>{};
      Future<List<int>> fetcher(int cid, int segmentIndex) async {
        inflight++;
        peak = math.max(peak, inflight);
        seen.add(segmentIndex);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        inflight--;
        return const [];
      }

      await biliFetchDanmaku(
        cid: 1,
        segmentCount: 31,
        fetchSegment: fetcher,
        maxConcurrent: 3,
      );
      expect(peak, lessThanOrEqualTo(3), reason: '31 段一把打出去就是这条要拦的');
      expect(peak, greaterThanOrEqualTo(2), reason: '退化成串行就不叫限并发');
      expect(seen, equals({for (var i = 1; i <= 31; i++) i}));

      // 上限 1 时必须真的串行
      inflight = 0;
      peak = 0;
      await biliFetchDanmaku(
        cid: 1,
        segmentCount: 5,
        fetchSegment: fetcher,
        maxConcurrent: 1,
      );
      expect(peak, 1);
    });

    test('并发数大于段数时不开多余的 worker', () async {
      final requested = <int>[];
      await biliFetchDanmaku(
        cid: 9,
        segmentCount: 2,
        fetchSegment: fakeFetcher({1: seg1, 2: seg2}, requested: requested),
        maxConcurrent: 8,
      );
      expect(requested, [1, 2]);
    });

    test('进度回调按已结束的段递增，收尾是 (total,total)', () async {
      final progress = <List<int>>[];
      await biliFetchDanmaku(
        cid: 1,
        segmentCount: 31,
        fetchSegment: fakeFetcher(
          {},
          failOn: {7, 13},
          requested: <int>[],
        ),
        onProgress: (done, total) => progress.add([done, total]),
      );
      expect(progress.length, 31, reason: '失败也要推进度，否则界面卡在 29/31');
      expect(progress.every((p) => p[1] == 31), isTrue);
      expect(progress.map((p) => p[0]), List<int>.generate(31, (i) => i + 1));
    });

    test('某段抛错只记段号，其余段的弹幕照收', () async {
      final result = await biliFetchDanmaku(
        cid: 42231463949,
        segmentCount: 4,
        fetchSegment: fakeFetcher(
          {1: seg1, 2: seg2},
          failOn: {3},
          requested: <int>[],
        ),
      );
      expect(result.failedSegments, [3]);
      expect(result.isComplete, isFalse);
      expect(result.items.length, 6);
      expect(result.items.first.text, '这个文字和声音配的太古代了', reason: '按 stime 定序');
    });

    test('解码失败的段与取回失败的段合并成同一个段号列表', () async {
      // 造法：三个 0xFF 的 varint 永远凑不完整，代表「脏字节」而不是「没网」
      final result = await biliFetchDanmaku(
        cid: 1,
        segmentCount: 3,
        fetchSegment: fakeFetcher(
          {1: seg1, 2: [0xFF, 0xFF, 0xFF]},
          failOn: {3},
          requested: <int>[],
        ),
      );
      expect(result.failedSegments, [2, 3], reason: '解不开就是没拿到，对用户同一回事');
      expect(result.items.length, 5);
    });

    test('cid 原样透传（分 P 之间只有 cid 不同，串了就取到别的 P 的弹幕）', () async {
      final seenCids = <int>[];
      await biliFetchDanmaku(
        cid: 12345,
        segmentCount: 2,
        fetchSegment: (cid, index) async {
          seenCids.add(cid);
          return const [];
        },
      );
      expect(seenCids, [12345, 12345]);
    });

    test('段数为 0 时一个请求都不发', () async {
      final requested = <int>[];
      final result = await biliFetchDanmaku(
        cid: 1,
        segmentCount: 0,
        fetchSegment: fakeFetcher({}, requested: requested),
      );
      expect(requested, isEmpty);
      expect(result.items, isEmpty);
    });
  });

  group('过滤与账目', () {
    test('默认黑名单挡住 mode 7/8，但特效条数按全量计而不是 0', () {
      // 造法：夹具里没有特效类样本
      final items = [
        item(id: 1, mode: 1),
        item(id: 2, mode: 7, text: r'\pos(1,2){}'),
        item(id: 3, mode: 8, text: 'code'),
      ];
      final s = biliSelectDanmaku(items, const BiliDanmakuFilter());
      expect(s.kept, hasLength(1));
      expect(s.stats.total, 3);
      expect(
        s.stats.special,
        2,
        reason: '黑名单挡掉的也算「未渲染的特效类」，漏计就是假报账',
      );
      expect(s.stats.dropped, 2);
    });

    test('文本长度上限按 rune 计，emoji 代理对不算两条', () {
      final filter = const BiliDanmakuFilter(maxTextLength: 3);
      expect(filter.accepts(item(text: '你好吗')), isTrue);
      expect(filter.accepts(item(text: '你好吗呀')), isFalse);
      // 😀 在 UTF-16 里是 2 个 code unit、1 个 rune
      expect(filter.accepts(item(text: 'a😀b')), isTrue);
      expect(item(text: 'a😀b').text.length, 4, reason: '坐实「按 code unit 会误杀」');
    });

    test('默认长度上限等于 B 站自身上限，不额外丢合法弹幕', () {
      expect(kBiliDanmakuDefaultMaxTextLength, 100);
      const filter = BiliDanmakuFilter();
      expect(filter.accepts(item(text: '字' * 100)), isTrue);
      expect(filter.accepts(item(text: '字' * 101)), isFalse);
    });

    test('pool 黑名单：默认挡 2（登录屏蔽区）', () {
      const filter = BiliDanmakuFilter();
      expect(filter.accepts(item(pool: 0)), isTrue);
      expect(filter.accepts(item(pool: 2)), isFalse);
      expect(
        const BiliDanmakuFilter(blockedPools: {}).accepts(item(pool: 2)),
        isTrue,
      );
    });

    test('空白文本一律不落进产物', () {
      const filter = BiliDanmakuFilter();
      expect(filter.accepts(item(text: '')), isFalse);
      expect(filter.accepts(item(text: '   ')), isFalse);
      expect(filter.accepts(item(text: '\t 　')), isFalse);
    });

    test('类型计数把滚动/逆向/顶部/底部分开', () {
      final s = biliSelectDanmaku(
        [
          item(id: 1, mode: 1),
          item(id: 2, mode: 2),
          item(id: 3, mode: 6),
          item(id: 4, mode: 4),
          item(id: 5, mode: 5),
        ],
        const BiliDanmakuFilter(blockedModes: {}),
      );
      expect(s.stats.scroll, 2);
      expect(s.stats.reverse, 1);
      expect(s.stats.top, 1);
      expect(s.stats.bottom, 1);
      expect(s.stats.rendered, 5);
    });
  });

  group('xml', () {
    test('真夹具的第一条落在 p 属性的八个槽位上', () {
      final xml = biliDanmakuToXml(biliDecodeDmSegReply(seg1));
      expect(
        xml,
        contains(
          '  <d p="88.151,1,25,16777215,1790525000,0,,2209842883157768448">'
          '火影的BGM？</d>\n',
        ),
      );
      expect(xml, startsWith('<?xml version="1.0" encoding="UTF-8"?>\n<i>\n'));
      expect(xml, endsWith('</i>\n'));
      expect(RegExp('<d p=').allMatches(xml).toList(), hasLength(5));
    });

    test('五个保留字符全转义，且 & 只被转一次', () {
      // 造法：真夹具里没有带保留字符的文本
      final xml = biliDanmakuToXml([item(id: 7, text: '<a> & "b" \'c\'')]);
      expect(
        xml,
        contains('&lt;a&gt; &amp; &quot;b&quot; &apos;c&apos;'),
        reason: '& 若最后处理会把 &lt; 二次转义成 &amp;lt;',
      );
      expect(xml, isNot(contains('&amp;lt;')));
    });

    test('stime 的毫秒部分保留三位小数', () {
      expect(biliDanmakuToXml([item(id: 1, stime: 1)]), contains('p="0.001,'));
      expect(
        biliDanmakuToXml([item(id: 1, stime: 123456)]),
        contains('p="123.456,'),
      );
    });
  });

  group('json', () {
    test('字段原样转储、缩进 2、且不含 pool 这个假字段', () {
      final text = biliDanmakuToJson(biliDecodeDmSegReply(seg1));
      expect(text, contains('\n  {\n    "id"'), reason: '缩进两格');
      final back = jsonDecode(text) as List;
      expect(back.length, 5);
      expect(back[0], {
        'id': 2209842883157768448,
        'stime': 88151,
        'mode': 1,
        'size': 25,
        'color': 16777215,
        'text': '火影的BGM？',
        'date': 1790525000,
      });
      expect((back[0] as Map).containsKey('pool'), isFalse);
    });

    test('json 档不做过滤：特效类原文照留', () {
      // 这一档的用途是「接口给了什么」的取证件，一加工就和 xml 那档重复了
      final items = [item(id: 1, mode: 7, text: r'\pos(1,2)')];
      expect(jsonDecode(biliDanmakuToJson(items)), hasLength(1));
    });
  });

  group('ass：样式', () {
    test('字体/字号/不透明度/边距都取配置', () {
      final cfg = BiliConfig()
        ..danmakuFontFace = 'SimHei'
        ..danmakuFontSize = 32
        ..danmakuOpacity = 60
        ..danmakuMarginV = 18;
      final ass = biliDanmakuToAss([item()], cfg).content;
      final style = ass.split('\n').firstWhere((l) => l.startsWith('Style: '));
      final cells = style.substring('Style: '.length).split(',');
      expect(cells, hasLength(23), reason: 'Format 行给了 23 个字段，Style 必须同数');
      expect(cells[0], kBiliDanmakuAssStyleName);
      expect(cells[1], 'SimHei');
      expect(cells[2], '32');
      // alpha = 255×(100-60)/100 = 102 → 0x66
      expect(cells[3], '&H66FFFFFF');
      expect(cells[cells.length - 2], '18', reason: 'MarginV');
      expect(cells.last, '1');
      expect(ass, contains('PlayResX: $kBiliDanmakuPlayResX'));
      expect(ass, contains('PlayResY: $kBiliDanmakuPlayResY'));
    });

    test('Format 行的字段数与 Style 行一致', () {
      final ass = biliDanmakuToAss([item()], BiliConfig()).content;
      final formatLine = ass
          .split('\n')
          .firstWhere((l) => l.startsWith('Format: Name, Fontname'));
      expect(
        formatLine.substring('Format: '.length).split(',').length,
        23,
      );
    });

    test('字号/边距被 settings.json 写成 0 或负数时不崩', () {
      // 行高 = 字号×1.3 取整；字号 0 会让「画面高 ~/ 行高」直接抛异常，
      // 而整条弹幕（连同一份已经取回来的字节）就全废了 —— 夹成最小 1px 只是难看，不是错。
      final cfg = BiliConfig()
        ..danmakuFontSize = 0
        ..danmakuMarginV = -20
        ..danmakuOpacity = 150;
      final result = biliDanmakuToAss([item(id: 1, stime: 0)], cfg);
      expect(result.events, 1);
      expect(result.content, contains('PlayResX: '));
      final style = result.content.split('\n').firstWhere((l) => l.startsWith('Style: '));
      final cells = style.substring('Style: '.length).split(',');
      expect(cells[2], '1', reason: '字号被夹到最小 1');
      expect(cells[cells.length - 2], '0', reason: 'MarginV 夹到 0');
      expect(cells[3], startsWith('&H00'), reason: '不透明度越界夹成全不透明');
    });

    test('三段必备区块齐全，纯函数不带 BOM', () {
      final ass = biliDanmakuToAss([item()], BiliConfig()).content;
      expect(ass, contains('[Script Info]'));
      expect(ass, contains('[V4+ Styles]'));
      expect(ass, contains('[Events]'));
      expect(ass, contains('Format: Layer, Start, End, Style, Name, MarginL'));
      expect(ass, isNot(startsWith('\uFEFF')));
    });
  });

  group('ass：三类弹幕的写法', () {
    test('真夹具 6 条都是滚动，逐条给 \\an7 + \\move，右进左出', () {
      final items = [...biliDecodeDmSegReply(seg1), ...biliDecodeDmSegReply(seg2)];
      final result = biliDanmakuToAss(items, BiliConfig());
      expect(result.events, 6);
      final dialogues = parseDialogues(result.content);
      expect(dialogues, hasLength(6));
      for (final d in dialogues) {
        expect(d.override, contains(r'\an7'));
        expect(d.override, contains(r'\move('));
        expect(d.override, contains(r'\c&H00FFFFFF&'), reason: '夹具六条都是白色');
        expect(d.style, kBiliDanmakuAssStyleName);
        // 一对括号四个参数 —— 规范形（Aegisub《ASS Tags》）。
        // 曾写成两对括号，播放器整条标签不认，弹幕全停左上角。
        final move = RegExp(
          r'\\move\((-?\d+),(-?\d+),(-?\d+),(-?\d+)\)',
        ).firstMatch(d.override)!;
        expect(int.parse(move.group(1)!), kBiliDanmakuPlayResX, reason: '从右缘进');
        expect(int.parse(move.group(3)!), lessThan(0), reason: '从左侧完全出屏');
        expect(move.group(2), move.group(4), reason: '同一行 y 不变，否则弹幕斜着走');
        expect(d.endMs, greaterThan(d.startMs));
      }
      expect(dialogues.first.text, '这个文字和声音配的太古代了');
    });

    test('⚠️ 负控制：\\move 不许写成两对括号（播放器会整条忽略）', () {
      // 这条是 2026-10-11 用户实测「VLC / PotPlayer 里弹幕停在左上角不动」
      // 的回归钉。当时的实现与旧断言一起用 `\move(A,B)(C,D)`，
      // 两边自洽所以全绿 —— 而播放器按规范只认一对括号。
      final result = biliDanmakuToAss(
        [item(id: 1, mode: 1, stime: 0)],
        BiliConfig(),
      );
      final d = parseDialogues(result.content).single;
      expect(
        RegExp(r'\\move\([^)]*\)\([^)]*\)').hasMatch(d.override),
        isFalse,
        reason: '两对括号是非法语法，会让整条 \\move 失效（弹幕不动）',
      );
      expect(
        RegExp(r'\\move\(-?\d+,-?\d+,-?\d+,-?\d+\)').hasMatch(d.override),
        isTrue,
        reason: '必须是一对括号四个参数',
      );
    });

    test('顶部用 \\an8、底部用 \\an2，停留 5 秒', () {
      final result = biliDanmakuToAss(
        [item(id: 1, mode: 4, stime: 1000), item(id: 2, mode: 5, stime: 1000)],
        BiliConfig(),
      );
      final dialogues = parseDialogues(result.content);
      expect(dialogues, hasLength(2));
      expect(dialogues[0].override, contains(r'\an8'));
      expect(dialogues[1].override, contains(r'\an2'));
      expect(dialogues[0].override, contains(r'\pos('));
      expect(dialogues[0].endMs - dialogues[0].startMs, 5000);
      expect(yOf(dialogues[0]), lessThan(yOf(dialogues[1])), reason: '顶在上、底在下');
      expect(yOf(dialogues[1]), lessThanOrEqualTo(kBiliDanmakuPlayResY));
    });

    test('逆向（mode 6）从左边进、往右出', () {
      final d = parseDialogues(
        biliDanmakuToAss([item(id: 1, mode: 6, stime: 0)], BiliConfig()).content,
      ).single;
      final move = RegExp(
        r'\\move\((-?\d+),(-?\d+),(-?\d+),(-?\d+)\)',
      ).firstMatch(d.override)!;
      expect(int.parse(move.group(1)!), lessThan(0));
      expect(int.parse(move.group(3)!), kBiliDanmakuPlayResX);
    });

    test('特效类（mode>=7）不渲染但条数如实带回', () {
      final result = biliDanmakuToAss(
        [
          item(id: 1, mode: 1),
          item(id: 2, mode: 7, text: r'\r\pos(1,2)'),
          item(id: 3, mode: 8, text: 'code'),
        ],
        BiliConfig(),
      );
      expect(result.specialSkipped, 2);
      expect(result.events, 1);
      expect(result.content, isNot(contains(r'\pos(1,2)')));
    });

    test('弹幕文本里的花括号与换行不会劈开覆盖块', () {
      final content = biliDanmakuToAss(
        [item(id: 1, text: '{a}\n换行', stime: 0)],
        BiliConfig(),
      ).content;
      final d = parseDialogues(content).single;
      expect(d.override, startsWith(r'{\an7'));
      expect(d.text, r'\{a\} 换行');
      expect(dialogueLines(content), hasLength(1));
    });

    test('每条自带颜色走 \\c，非白色也不共用样式', () {
      final d = parseDialogues(
        biliDanmakuToAss([item(id: 1, color: 0xFF0000, stime: 0)], BiliConfig()).content,
      ).single;
      expect(d.override, contains(r'\c&H000000FF&'), reason: '红 → BGR 的末两位是 R');
    });

    test('覆盖块与文本之间不插空格', () {
      final line = dialogueLines(
        biliDanmakuToAss([item(id: 1, stime: 0, text: '靠左')], BiliConfig()).content,
      ).first;
      expect(line, isNot(contains('} ')), reason: '那个空格会变成可见缩进并撑宽估算');
      expect(line, contains('}靠左'));
    });
  });

  group('ass：防重叠', () {
    test('同一时刻的多条必然落在不同行', () {
      // 造法：真夹具 6 条时间隔得很开，同刻多条这种形态只能造
      final items = [
        for (var i = 0; i < 5; i++) item(id: i + 1, stime: 10000, text: '第$i条弹幕'),
      ];
      final dialogues = parseDialogues(biliDanmakuToAss(items, BiliConfig()).content);
      expect(dialogues, hasLength(5));
      expect(
        dialogues.map(yOf).toSet(),
        hasLength(5),
        reason: '叠在同一行是本期最显眼的 bug',
      );
    });

    test('同一行上相邻两条时间不交叠（40 条同刻的暴力例）', () {
      // 40 条 > 滚动区行数（1080 高、字号 25 时是 32 行），必然触发「顺延出场」
      final items = [
        for (var i = 0; i < 40; i++) item(id: i + 1, stime: 20000, text: '挤一挤$i'),
      ];
      final dialogues = parseDialogues(biliDanmakuToAss(items, BiliConfig()).content);
      expect(dialogues, hasLength(40));
      final byRow = <int, List<_AssDialogue>>{};
      for (final d in dialogues) {
        byRow.putIfAbsent(yOf(d), () => []).add(d);
      }
      for (final entry in byRow.entries) {
        final rows = [...entry.value]..sort((a, b) => a.startMs.compareTo(b.startMs));
        for (var i = 1; i < rows.length; i++) {
          expect(
            rows[i].startMs,
            greaterThanOrEqualTo(rows[i - 1].endMs),
            reason: '行 ${entry.key} 上第 $i 条与上一条时间交叠',
          );
        }
      }
      expect(dialogues.every((d) => d.startMs >= 20000), isTrue, reason: '只许往后顺延');
      expect(byRow.length, lessThanOrEqualTo(32));
    });

    test('隔得够开的两条复用同一行（证明是槽位分配而不是轮流换行）', () {
      // 滚动一条约 8 秒走完，间隔 60 秒必然早已空出来
      final items = [
        item(id: 1, stime: 0, text: '第一条'),
        item(id: 2, stime: 60000, text: '第二条'),
        item(id: 3, stime: 120000, text: '第三条'),
      ];
      final ys = parseDialogues(
        biliDanmakuToAss(items, BiliConfig()).content,
      ).map(yOf).toSet();
      expect(ys, hasLength(1), reason: '屏幕空着还换行就是轮转而不是槽位');
    });

    test('固定弹幕同刻也只许各行一条，超出行数的顺延', () {
      final items = [
        for (var i = 0; i < 4; i++) item(id: i + 1, mode: 4, stime: 5000, text: '顶$i'),
      ];
      final dialogues = parseDialogues(biliDanmakuToAss(items, BiliConfig()).content);
      expect(dialogues.map(yOf).take(3).toSet(), hasLength(3));
      final sorted = [...dialogues]..sort((a, b) => a.startMs.compareTo(b.startMs));
      expect(sorted.last.startMs, greaterThan(5000), reason: '默认 3 行占满，第 4 条只能等');
      expect(sorted.last.startMs, 10000, reason: '停留 5 秒 → 10 秒时第 0 行空出来');
    });

    test('输入乱序也先按时间排再分行', () {
      final items = [
        item(id: 3, stime: 30000, text: '后'),
        item(id: 1, stime: 10000, text: '先'),
        item(id: 2, stime: 20000, text: '中'),
      ];
      final dialogues = parseDialogues(biliDanmakuToAss(items, BiliConfig()).content);
      expect(dialogues.map((d) => d.startMs), orderedEquals([10000, 20000, 30000]));
    });

    test('顶部/底部不占用滚动行的槽位', () {
      // 六个滚动（10s 起，约 18.3s 走完）→ 中间夹 3 顶 2 底（20s）→ 25s 再来一条滚动。
      // 若三个区共用一套槽位，最后那条只会被顶/底部挤到第 6 行去，白占一整行画面。
      final items = [
        for (var i = 0; i < 6; i++)
          item(id: 100 + i, stime: 10000, text: '同刻第$i条弹幕'),
        for (var i = 0; i < 3; i++) item(id: 200 + i, mode: 4, stime: 20000, text: '顶部$i'),
        for (var i = 0; i < 2; i++) item(id: 300 + i, mode: 5, stime: 20000, text: '底部$i'),
        item(id: 400, mode: 6, stime: 25000, text: '逆向一条'),
      ];
      final dialogues = parseDialogues(biliDanmakuToAss(items, BiliConfig()).content);
      expect(dialogues, hasLength(12));
      // 前六条各占一行，第七到第十一条是固定弹幕，最后一条回到滚动第 0 行（y=0）
      expect(yOf(dialogues.last), 0, reason: '滚动区早空出来了，回第 0 行才叫槽位分配');
      expect(
        dialogues.sublist(0, 6).map(yOf).toSet(),
        hasLength(6),
        reason: '同刻六条必须六个不同的 y',
      );
      expect(dialogues.sublist(6, 11).map(yOf).toSet(), hasLength(5));
    });

    test('同一批两次跑出的产物逐字节相同（槽位分配不许带随机性）', () {
      final items = [
        for (var i = 0; i < 12; i++) item(id: i + 1, stime: 5000, text: '重复$i 一次'),
      ];
      final first = biliDanmakuToAss(items, BiliConfig()).content;
      final second = biliDanmakuToAss(items.reversed.toList(), BiliConfig()).content;
      expect(second, first);
    });
  });

  group('ass 的换算辅助', () {
    test('时间串是 H:MM:SS.cc（厘秒两位）', () {
      expect(biliAssTime(0), '0:00:00.00');
      expect(biliAssTime(88151), '0:01:28.15');
      expect(biliAssTime(3723456), '1:02:03.45');
      expect(biliAssTime(59999), '0:00:59.99');
    });

    test('宽度估算：CJK 一个全角、ASCII 半个', () {
      // '火影的BGM？' = 4 全角 + 3 半角 = (4 + 3×0.55)×25 = 141.25 → 向上取整 142
      expect(biliDanmakuWidthOf('火影的BGM？', 25), 142);
      expect(biliDanmakuWidthOf('abc', 25), 42); // 3×0.55×25 = 41.25 → 42
      expect(biliDanmakuWidthOf('中文', 25), 50);
      expect(biliDanmakuWidthOf('', 25), 0);
    });

    test('产物里的第一条滚动弹幕终点 = 起点 + (画面宽 + 估算宽)/速度', () {
      final d = parseDialogues(
        biliDanmakuToAss([item(id: 1, stime: 0, text: '中文')], BiliConfig()).content,
      ).single;
      final expected = ((kBiliDanmakuPlayResX + 50) / kBiliDanmakuScrollPxPerSecond * 1000)
          .ceil();
      expect(d.endMs - d.startMs, expected);
    });
  });

  group('落盘与契约登记', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('bili-danmaku-'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<BiliDanmakuRunResult> run(
      BiliConfig cfg, {
      Map<int, List<int>>? bySegment,
      Set<int> failOn = const {},
      String base = '冬天-1080P',
      BiliDanmakuFilter filter = const BiliDanmakuFilter(),
    }) async {
      final requested = <int>[];
      return buildBiliDanmakuSideFile(
        saveDir: tmp.path,
        base: base,
        cid: 42231463949,
        durationSeconds: 700,
        cfg: cfg,
        filter: filter,
        fetchSegment: fakeFetcher(
          bySegment ?? {1: seg1, 2: seg2},
          failOn: failOn,
          requested: requested,
        ),
      );
    }

    test('没勾弹幕开关时一个请求都不发、也不产出', () async {
      final requested = <int>[];
      final r = await buildBiliDanmakuSideFile(
        saveDir: tmp.path,
        base: 'x',
        cid: 1,
        durationSeconds: 700,
        cfg: BiliConfig(),
        fetchSegment: fakeFetcher({}, requested: requested),
      );
      expect(requested, isEmpty);
      expect(r.outcome.hasAnything, isFalse);
      expect(r.outcome.missing, isEmpty);
      expect(r.fileName, isNull);
      expect(tmp.listSync(), isEmpty);
    });

    test('ass + 勾内封 + 三条前提齐 → 登记一条待内封轨', () async {
      final r = await run(danmakuConfig(embed: true, container: BiliContainer.mkv));
      expect(r.outcome.written, ['冬天-1080P.弹幕.ass']);
      final track = r.outcome.tracks.single;
      expect(track.fileName, '冬天-1080P.弹幕.ass');
      expect(track.fromDanmaku, isTrue);
      expect(track.iso639, '', reason: '弹幕没有语言标签这个概念，留空而不是硬填 chi');
      expect(track.title, kBiliDanmakuQualifier);
      expect(r.outcome.missing, isEmpty);
      final file = File('${tmp.path}/冬天-1080P.弹幕.ass');
      expect(file.existsSync(), isTrue);
      // 带 BOM 写盘：Windows 上按 GBK 猜编码的播放器只认这个标记
      final raw = file.readAsBytesSync();
      expect(raw.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(raw.sublist(3)), startsWith('[Script Info]'));
      expect(utf8.decode(raw.sublist(3)), contains('火影的BGM？'));
    });

    test('勾了内封但容器是 MP4：落盘照旧，missing 里是配置原文的原因', () async {
      final r = await run(danmakuConfig(embed: true));
      expect(r.outcome.tracks, isEmpty);
      expect(r.outcome.written, hasLength(1));
      expect(r.outcome.missing, hasLength(1));
      expect(r.outcome.missing.single, contains('MKV'), reason: '不许静默，也不许另造说法');
    });

    test('关合并时 missing 报的是合并那一条', () async {
      final r = await run(
        danmakuConfig(embed: true, container: BiliContainer.mkv, merge: false),
      );
      expect(r.outcome.tracks, isEmpty);
      expect(r.outcome.missing.single, contains('合并'));
    });

    // 语义改定（2026-10-10，主仓）：`missing` 只装「用户要了却没拿到」的东西。
    // 没勾内封是他自己的选择，每次下载都在完成行挂一句「未开启内封」是骚扰，
    // 而报警被稀释之后，真缺东西时也没人看了。侧文件的名字本来就在磁盘上。
    test('没勾内封时 ass 只留侧文件，且不进 missing', () async {
      final r = await run(danmakuConfig());
      expect(r.outcome.tracks, isEmpty);
      expect(r.outcome.written, hasLength(1));
      expect(r.outcome.missing, isEmpty);
    });

    test('xml 档想内封时，报的是「弹幕格式要选 ASS」这一条', () async {
      final r = await run(
        danmakuConfig(
          format: BiliDanmakuFormat.xml,
          embed: true,
          container: BiliContainer.mkv,
        ),
      );
      expect(r.outcome.tracks, isEmpty);
      expect(r.outcome.written, ['冬天-1080P.弹幕.xml']);
      expect(r.outcome.missing.single, contains('弹幕格式要选 ASS'));
      final body = File('${tmp.path}/冬天-1080P.弹幕.xml').readAsStringSync();
      expect(body, startsWith('<?xml'));
      expect(body, isNot(startsWith('\uFEFF')), reason: 'xml 不加 BOM：解析器更不容忍');
    });

    test('json 档落盘的是可读回的对象数组', () async {
      await run(danmakuConfig(format: BiliDanmakuFormat.json));
      final body = File('${tmp.path}/冬天-1080P.弹幕.json').readAsStringSync();
      final list = jsonDecode(body) as List;
      expect(list, hasLength(6));
      expect(list[0]['stime'], 44450, reason: '取数层已按 stime 定序');
    });

    test('分段失败时 missing 逐段列出段号与总段数', () async {
      final r = await run(danmakuConfig(), failOn: {2});
      expect(r.outcome.written, hasLength(1));
      expect(r.outcome.missing.first, contains('第 2'));
      expect(r.outcome.missing.first, contains('2 段'));
      expect(r.stats.failedSegments, 1);
      expect(r.stats.total, 5, reason: 'seg2 失败，只剩 seg1 的 5 条');
    });

    test('接口 0 条时不落空文件，missing 里说清是没返回', () async {
      final r = await run(danmakuConfig(), bySegment: {});
      expect(r.outcome.written, isEmpty);
      expect(r.fileName, isNull);
      expect(r.outcome.missing, contains(kBiliDanmakuMissingEmptyApi));
      expect(tmp.listSync(), isEmpty);
    });

    test('全部被过滤规则挡掉时，原因与「接口没返回」区分开', () async {
      final r = await run(danmakuConfig(), filter: const BiliDanmakuFilter(maxTextLength: 1));
      expect(r.outcome.written, isEmpty);
      expect(r.outcome.missing, contains(kBiliDanmakuMissingAllFiltered));
      expect(r.stats.dropped, 6);
    });

    test('特效条数在 ass 档的 missing 里可见', () async {
      // 造法：夹具里没有 mode>=7 的样本，把真解出的 5 条与造的 1 条编回 protobuf
      final fake = [
        ...biliDecodeDmSegReply(seg1),
        item(id: 99, mode: 7, stime: 300000, text: r'\pos(1,2)'),
      ];
      final r = await buildBiliDanmakuSideFile(
        saveDir: tmp.path,
        base: 'b',
        cid: 1,
        durationSeconds: 10,
        cfg: danmakuConfig(),
        fetchSegment: (cid, index) async => index == 1 ? encodeFake(fake) : const [],
      );
      expect(r.stats.special, 1);
      expect(r.stats.kept, 5, reason: '默认黑名单把它挡在产物外面');
      expect(
        r.outcome.missing.any((m) => m.contains(kBiliDanmakuNoteSpecialSkipped)),
        isTrue,
      );
    });

    test('落盘名走契约的 biliAdditionalName，轨序交给 orderTracks', () async {
      final r = await run(
        danmakuConfig(embed: true, container: BiliContainer.mkv)
          ..trackPriority = BiliTrackPriority.danmakuFirst,
        base: '冬天-1080P60-AV1',
      );
      expect(r.outcome.written.single, '冬天-1080P60-AV1.弹幕.ass');
      expect(r.outcome.tracks.single.fileName, '冬天-1080P60-AV1.弹幕.ass');
    });

    test('保存目录不存在时递归建出来，而不是抛', () async {
      final deep = '${tmp.path}/a/b/c';
      final r = await buildBiliDanmakuSideFile(
        saveDir: deep,
        base: 'x',
        cid: 1,
        durationSeconds: 10,
        cfg: danmakuConfig(format: BiliDanmakuFormat.json),
        fetchSegment: fakeFetcher({1: seg1}, requested: <int>[]),
      );
      expect(r.outcome.written, hasLength(1));
      expect(File('$deep/x.弹幕.json').existsSync(), isTrue);
    });
  });
}

/// 把内存里的假弹幕编回 protobuf（**造法**：只用于喂夹具里没有的档位）。
List<int> encodeFake(List<BiliDanmaku> items) {
  final out = <int>[];
  for (final d in items) {
    final elem = <int>[
      ..._v(1, d.id),
      ..._v(2, d.stime),
      ..._v(3, d.mode),
      ..._v(4, d.size),
      ..._v(5, d.color),
      ..._b(7, utf8.encode(d.text)),
      ..._v(8, d.date),
    ];
    out.addAll(_b(1, elem));
  }
  return out;
}

List<int> _key(int number, int wireType) => _varint((number << 3) | wireType);

List<int> _varint(int v) {
  final out = <int>[];
  var x = v;
  while (true) {
    final byte = x & 0x7F;
    x = x >>> 7;
    if (x == 0) {
      out.add(byte);
      return out;
    }
    out.add(byte | 0x80);
  }
}

List<int> _v(int number, int value) => [..._key(number, 0), ..._varint(value)];

List<int> _b(int number, List<int> payload) => [
  ..._key(number, 2),
  ..._varint(payload.length),
  ...payload,
];

/// `H:MM:SS.cc` → 毫秒
int parseAssTime(String s) {
  final parts = s.split(RegExp(r'[:.]'));
  return (((int.parse(parts[0]) * 60) + int.parse(parts[1])) * 60 +
          int.parse(parts[2])) *
      1000 +
      int.parse(parts[3]) * 10;
}

/// 解析出来的一条 Dialogue（只为断言服务）
class _AssDialogue {
  const _AssDialogue({
    required this.startMs,
    required this.endMs,
    required this.style,
    required this.override,
    required this.text,
  });
  final int startMs;
  final int endMs;
  final String style;
  final String override;
  final String text;
}
