import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_dm_proto.dart';

/// 手写 protobuf wire 解码器的测试。
///
/// **两份真夹具是匿名从 `dm/wbi/web/seg.so` 拿到的原字节**（BV1uzas6vEBB / cid
/// 42231463949 的第 1、2 段），不是我自己编的：
///   test/fixtures/fixture_BV1uzas6vEBB_seg1.bin  790 字节 5 条
///   test/fixtures/fixture_BV1uzas6vEBB_seg2.bin  293 字节 1 条
/// 下面凡是「造出来」的字节都写明了造法，且只用于边界情况（未知 tag、截断、
/// wire type 不匹配）—— 那些真夹具里没有。
///
/// 负控制是本文件的主要目的：自写解码器最危险的失效模式是**读串位之后还一路绿**
/// （缺字段时默默用缺省值填上，产物看着正常），所以每条负控制都同时断言
/// 「那个不该被当成的字段」和「它后面的字段仍然正确」。
void main() {
  late Uint8List seg1;
  late Uint8List seg2;
  setUpAll(() {
    seg1 = File('test/fixtures/fixture_BV1uzas6vEBB_seg1.bin').readAsBytesSync();
    seg2 = File('test/fixtures/fixture_BV1uzas6vEBB_seg2.bin').readAsBytesSync();
  });

  // ── 造字节用的小工具（与被测实现无关，独立写一遍才防得住「一起错」）──

  List<int> varint(int v) {
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

  List<int> key(int number, int wireType) => varint((number << 3) | wireType);

  List<int> fVarint(int number, int value) => [...key(number, 0), ...varint(value)];

  List<int> fBytes(int number, List<int> payload) => [
    ...key(number, 2),
    ...varint(payload.length),
    ...payload,
  ];

  List<int> fFixed32(int number, int value) => [
    ...key(number, 5),
    for (var i = 0; i < 4; i++) (value >> (8 * i)) & 0xFF,
  ];

  List<int> fFixed64(int number, int value) => [
    ...key(number, 1),
    for (var i = 0; i < 8; i++) (value >> (8 * i)) & 0xFF,
  ];

  /// 把一条真 elem 的字段按原 wire type 重排，并把其中 `from` 号字段改名成 `to`。
  List<int> relabel(List<BiliProtoField> fields, {required int from, required int to}) {
    final out = <int>[];
    for (final f in fields) {
      final number = f.number == from ? to : f.number;
      switch (f.wireType) {
        case 0:
          out.addAll(fVarint(number, f.varintValue));
        case 2:
          out.addAll(fBytes(number, f.bytesValue));
        case 1:
          out.addAll(fFixed64(number, f.fixedValue));
        case 5:
          out.addAll(fFixed32(number, f.fixedValue));
        default:
          throw StateError('测试造不了 wireType=${f.wireType}');
      }
    }
    return out;
  }

  /// 真夹具里第 n 条 elem 的原始字节（n 从 0 起）
  List<int> realElem(Uint8List seg, int n) {
    final elems = biliProtoReadFields(seg).where((f) => f.number == 1).toList();
    return elems[n].bytesValue;
  }

  group('真夹具正控制：五个字段逐条核死', () {
    test('seg1 解出 5 条，且每条的 7 个字段都对得上探针结果', () {
      final items = biliDecodeDmSegReply(seg1);
      expect(items.length, 5);
      // 期望值逐条来自匿名探针的字段 dump（id 是 19 位雪花号，按 int64 存）
      const expected = [
        [2209842883157768448, 88151, 1, 25, 16777215, 1790525000, '火影的BGM？'],
        [2211089722657317120, 152751, 1, 25, 16777215, 1790673634, '混血种的悲哀'],
        [
          2211980415701372928,
          44450,
          1,
          25,
          16777215,
          1790779813,
          '这个文字和声音配的太古代了',
        ],
        [
          2214856996430913792,
          246886,
          1,
          25,
          16777215,
          1791122728,
          '乌鸦的头部绷不住了',
        ],
        [
          2219141386203733504,
          57576,
          1,
          25,
          16777215,
          1791633468,
          '绘梨衣说话真的没问题吗',
        ],
      ];
      for (var i = 0; i < expected.length; i++) {
        final e = expected[i];
        final d = items[i];
        expect(d.id, e[0], reason: '第 $i 条 id');
        expect(d.stime, e[1], reason: '第 $i 条 stime');
        expect(d.mode, e[2], reason: '第 $i 条 mode');
        expect(d.size, e[3], reason: '第 $i 条 size');
        expect(d.color, e[4], reason: '第 $i 条 color');
        expect(d.date, e[5], reason: '第 $i 条 date');
        expect(d.text, e[6], reason: '第 $i 条 text');
      }
    });

    test('19 位 id 没掉精度（int64 而非 double）', () {
      // id 超过 2^53，一旦被当 double 走一圈就会在末位漂；这条钉住「按 varint 原样读」
      final id = biliDecodeDmSegReply(seg1).first.id;
      expect(id, 2209842883157768448);
      expect(id.toRadixString(16), '1eaaf064dc0b3900');
    });

    test('stime 是「相对视频的毫秒」，不是段内偏移', () {
      // 判据：分段 1 覆盖 [0,360000) ms、分段 2 覆盖 [360000,720000) ms。
      // seg1 五条全落在前一个区间，seg2 那条 603282 落在后一个 —— 说明接口没有
      // 按段归零，渲染时**不需要**再加段起始时间。加错了就会把 seg2 的弹幕
      // 画到 1080 秒处（约 18 分钟），是肉眼可见的错。
      final a = biliDecodeDmSegReply(seg1);
      final b = biliDecodeDmSegReply(seg2);
      expect(a.every((d) => d.stime >= 0 && d.stime < 360000), isTrue);
      expect(b, hasLength(1));
      expect(b.single.stime, 603282);
      expect(b.single.stime, inInclusiveRange(360000, 720000));
      expect(b.single.text, '小字');
    });

    test('顶层除 elems(1) 之外的 4、5 两个字段被忽略，不影响条数', () {
      final top = biliProtoReadFields(seg1).map((f) => f.number).toSet();
      expect(top, containsAll(<int>[1, 4, 5]));
      expect(biliDecodeDmSegReply(seg1), hasLength(5));
    });

    test('真字节里 descriptor 没写的 15/20/21/25/26/27 六个 tag 都读得到、也不崩', () {
      // 这条就是「未知 tag 按 wire type 跳过」的正控制：先证明它们在字节里，
      // 再证明语义层没被它们带偏（26 恰好是本条的 oid，值域和 stime 一样是整数，
      // 一旦字段号认错就会画到 420 亿秒处）。
      final fields = biliProtoReadFields(realElem(seg1, 0));
      final byNumber = {for (final f in fields) f.number: f};
      expect(byNumber[15]?.varintValue, 1);
      expect(byNumber[20]?.bytesValue, utf8Bytes('0'));
      expect(byNumber[21]?.bytesValue, utf8Bytes('0'));
      expect(byNumber[25]?.varintValue, 1);
      expect(byNumber[26]?.varintValue, 42231463949); // oid
      expect(byNumber[27]?.varintValue, 1);
      // 语义层只交出 7 个字段，oid 没有冒充 stime
      final d = biliDecodeDmSegReply(fBytes(1, realElem(seg1, 0))).single;
      expect(d.stime, 88151);
      expect(d.date, 1790525000);
    });

    test('同一批里有的 elem 没有 tag 15（第 3 条），长度不同也不串位', () {
      // 未知 tag 的**存在性不稳定**才是真正的雷：第 1 条 107 字节、第 3 条 129 字节，
      // 中间夹着变长的未知字段。这里断言两条的 text 都对，等于证明跳过的字节数没算错。
      final items = biliDecodeDmSegReply(seg1);
      final third = biliProtoReadFields(realElem(seg1, 2));
      expect(third.map((f) => f.number), isNot(contains(15)));
      expect(items[2].text, '这个文字和声音配的太古代了');
      expect(items[0].text, '火影的BGM？');
    });
  });

  group('负控制：字段号认错时必须当场露出来', () {
    test('把 stime 的 tag 2 改成 31，解码器认成 31 而不是 stime', () {
      // 造法：取真夹具第 1 条 elem 的全部字段，只把字段号 2 换成 31，其余原样重排。
      // 关键在于 **31 号字段的 key 是两字节 varint**（(31<<3)|0 = 248 → 0xF8 0x01），
      // 一次只读一个字节 key 的实现会在这里直接读飞，后面所有字段全串位。
      final original = biliProtoReadFields(realElem(seg1, 0));
      final mutated = relabel(original, from: 2, to: 31);
      expect(
        varint((31 << 3) | 0),
        [0xF8, 0x01],
        reason: '先钉住「tag 31 的 key 不是单字节」这个前提',
      );

      // wire 层：字段号真的是 31，且不再有 2
      final got = biliProtoReadFields(mutated);
      final numbers = got.map((f) => f.number).toList();
      expect(numbers, contains(31));
      expect(numbers, isNot(contains(2)));
      expect(got.firstWhere((f) => f.number == 31).varintValue, 88151);

      // 语义层：stime 退回缺省 0（而不是 88151），并且**后面的字段全部还对**
      final d = biliDecodeDmSegReply(fBytes(1, mutated)).single;
      expect(d.stime, 0, reason: '把 31 当成 stime 读出来就是这条负控制没拦住');
      expect(d.id, 2209842883157768448);
      expect(d.mode, 1);
      expect(d.size, 25);
      expect(d.color, 16777215);
      expect(d.text, '火影的BGM？');
      expect(d.date, 1790525000);
    });

    test('把 text 的 tag 7 改成 31 后，text 变空而 id 与 date 仍对', () {
      final mutated = relabel(biliProtoReadFields(realElem(seg1, 0)), from: 7, to: 31);
      final d = biliDecodeDmSegReply(fBytes(1, mutated)).single;
      expect(d.text, isEmpty);
      expect(d.id, 2209842883157768448);
      expect(d.date, 1790525000, reason: '变长的 7 号字段被跳过后不该影响后面的定界');
    });

    test('stime 以 length-delimited 出现时按缺省处理，不去读那段字节', () {
      // 造法：把 tag 2 的 wire type 从 0 换成 2，负载塞 4 个字节 0xFF。
      // 若实现「不管 wire type 一律读长度然后当整数凑」，这里会读出一个巨大的 stime
      // （表现为弹幕飞到几十小时后），而正确的做法是退回缺省 0。
      final payload = [0xFF, 0xFF, 0xFF, 0xFF];
      final mutated = fBytes(2, payload) + fVarint(1, 123) + fBytes(7, utf8Bytes('x'));
      final d = biliDecodeDmSegReply(fBytes(1, mutated)).single;
      expect(d.stime, 0);
      expect(d.id, 123);
      expect(d.text, 'x');
    });

    test('0 号字段直接报错（protobuf 不允许），不返回半截结果', () {
      expect(
        () => biliProtoReadFields([0x00, 0x01]),
        throwsA(isA<BiliDmProtoException>()),
      );
    });

    test('不支持的 wire type 3/4/6 报错，而不是当成未知字段跳过去', () {
      // group（3/4）在本期不支持，也**不能**装作不认识就跳过：
      // 那会把后续字节当成 payload 吞掉，比报错危险得多。
      for (final wt in [3, 4, 6, 7]) {
        expect(
          () => biliProtoReadFields([(1 << 3) | wt, 0x00]),
          throwsA(isA<BiliDmProtoException>()),
          reason: 'wireType=$wt 应当被拒',
        );
      }
    });

    test('截断的负载报错而不是少报一条', () {
      // 造法一：把第 1 条 elem 的长度声明留原样、负载砍掉一半。
      final elem = realElem(seg1, 0);
      final truncated = [...key(1, 2), ...varint(elem.length), ...elem.take(8)];
      expect(
        () => biliDecodeDmSegReply(truncated),
        throwsA(isA<BiliDmProtoException>()),
      );
      // 造法二：整段响应末尾少 3 个字节 —— 顶层最后一个 tag 5 声明 184 字节却只剩 181
      expect(
        () => biliDecodeDmSegReply(seg1.sublist(0, seg1.length - 3)),
        throwsA(isA<BiliDmProtoException>()),
      );
      // 造法三：key 后面的 varint 只给了带续位的前半截就没了
      expect(
        () => biliProtoReadFields([...key(1, 0), 0x80]),
        throwsA(isA<BiliDmProtoException>()),
      );
      // 正控制：完整夹具不抛（防止上面三条因为「任何异常都算过」而假绿）
      expect(biliDecodeDmSegReply(seg1), hasLength(5));
    });

    test('超过 64 位的 varint 报错', () {
      // 造法：11 个 0x80 再补一个 0x01 —— 每个实现都在「10 字节」处该收手
      expect(
        () => biliProtoReadFields([...key(1, 0), ...List<int>.filled(10, 0x80), 0x01]),
        throwsA(isA<BiliDmProtoException>()),
      );
      // 第 10 个字节贡献了 2 位以上 = 超出 64 位
      expect(
        () => biliProtoReadFields([...key(1, 0), ...List<int>.filled(9, 0x80), 0x82]),
        throwsA(isA<BiliDmProtoException>()),
      );
    });
  });

  group('四种 wire type 都能读，未知 tag 按类型跳过', () {
    test('varint / fixed64 / length-delimited / fixed32 各读一条', () {
      final bytes = [
        ...fVarint(3, 300),
        ...fFixed64(99, 0x0102030405060708),
        ...fBytes(7, utf8Bytes('hi')),
        ...fFixed32(11, 0xAABBCCDD),
      ];
      final fields = biliProtoReadFields(bytes);
      expect(fields.map((f) => f.number).toList(), [3, 99, 7, 11]);
      expect(fields[0].wireType, 0);
      expect(fields[0].varintValue, 300);
      expect(fields[1].wireType, 1);
      expect(fields[1].fixedValue, 0x0102030405060708);
      expect(fields[2].bytesValue, utf8Bytes('hi'));
      expect(fields[3].wireType, 5);
      expect(fields[3].fixedValue, 0xAABBCCDD);
    });

    test('语义层遇到未知 tag 的 fixed64 / fixed32 也照样跳，不吃错字节数', () {
      // 造法：已知的 id(1)、mode(3) 之间塞未知 fixed64(30) 与未知 fixed32(31)。
      // fixed64 吃 8 个字节、fixed32 吃 4 个；任何一处算错，mode 就会读出垃圾值。
      final elem = [
        ...fVarint(1, 42),
        ...fFixed64(30, 0x7FFFFFFFFFFFFFFF),
        ...fVarint(3, 4),
        ...fFixed32(31, 0xDEADBEEF),
        ...fBytes(7, utf8Bytes('顶部一条')),
      ];
      final d = biliDecodeDmSegReply(fBytes(1, elem)).single;
      expect(d.id, 42);
      expect(d.mode, 4);
      expect(d.isTop, isTrue);
      expect(d.text, '顶部一条');
    });

    test('elems 之外的 tag 1 同名字段不会混进来（顶层只认 tag 1）', () {
      // 造法：顶层放 tag 2（实测是段内最大时间）与 tag 5，都不该变成弹幕
      final top = [...fBytes(1, fVarint(1, 7)), ...fVarint(2, 360000), ...fBytes(5, [1, 2])];
      expect(biliDecodeDmSegReply(top), hasLength(1));
      expect(biliDecodeDmSegReply(top).single.id, 7);
    });

    test('空字节与只有顶层其它字段的响应都解成 0 条，而不是抛', () {
      expect(biliDecodeDmSegReply(const []), isEmpty);
      expect(biliDecodeDmSegReply(fVarint(4, 360000)), isEmpty);
    });

    test('length-delimited 的负载是**拷贝**，原缓冲被复用也不受影响', () {
      final buffer = Uint8List.fromList(fBytes(7, utf8Bytes('ab')));
      final field = biliProtoReadFields(buffer).single;
      buffer[2] = 0x63; // 改掉负载首字节：'ab' → 'cb'
      expect(String.fromCharCodes(field.bytesValue), 'ab');
    });

    test('非 utf8 的脏文本不清空整条弹幕', () {
      // 造法：0xC3 单独出现是半截 utf8 序列（真机上偶发的截断表情）
      final elem = [...fVarint(1, 5), 0x3A, 0x01, 0xC3];
      final d = biliDecodeDmSegReply(fBytes(1, elem)).single;
      expect(d.id, 5);
      expect(d.text, isNotEmpty, reason: '退成 latin1 也要把这条留住');
      expect(d.text.runes.single, 0xC3);
    });
  });

  group('颜色到 ass 的换算', () {
    test('0xRRGGBB → &HAABBGGRR：BGR 反序且 alpha 在前', () {
      expect(biliAssColor(0xFF0000), '&H000000FF'); // 红 → 末两位是 R
      expect(biliAssColor(0x00FF00), '&H0000FF00'); // 绿
      expect(biliAssColor(0x0000FF), '&H00FF0000'); // 蓝
      expect(biliAssColor(0xFFFFFF), '&H00FFFFFF'); // 真夹具里的白色
      expect(biliAssColor(0x000000), '&H00000000');
      expect(biliAssColor(0xFF8000), '&H000080FF');
    });

    test('不透明度 100 是全不透明（alpha=00），0 是全透明（alpha=FF）', () {
      // 这一条最容易反着写：ASS 的 alpha 与直觉相反，00 才是实心
      expect(biliAssColor(0xFFFFFF, opacity: 100), '&H00FFFFFF');
      expect(biliAssColor(0xFFFFFF, opacity: 0), '&HFFFFFFFF');
      expect(biliAssColor(0xFFFFFF, opacity: 50), '&H80FFFFFF');
      expect(biliAssColor(0xFFFFFF, opacity: 75), '&H40FFFFFF');
    });

    test('越界的不透明度被夹住而不是算出负 alpha', () {
      expect(biliAssColor(0xFFFFFF, opacity: 130), '&H00FFFFFF');
      expect(biliAssColor(0xFFFFFF, opacity: -20), '&HFFFFFFFF');
    });
  });
}

List<int> utf8Bytes(String s) => utf8.encode(s);
