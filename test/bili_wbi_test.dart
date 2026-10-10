import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_wbi.dart';

/// WBI 签名的已知向量测试。
///
/// **下面每个期望值都是先用量独立实现算出来、再写成字面量的**（Python 的
/// `hashlib.md5` + `urllib.parse.urlencode`，命令附在每条断言旁边）。
/// 之所以强调这一点：如果让被测实现自己算一遍再和「同样的实现」对撞，
/// 排序错了、转义错了两边会一起错，测试永远绿 —— 而这正是唯一能钉死
/// 「客户端算的 query == 服务端重算的 query」的地方（签名一错表现是 -403 风控，
/// 从错误信息根本倒查不回来说明是哪一个字符编码漂了）。
void main() {
  // 自己造的一对 32 位十六进制 key（真实 key 就是这个形状，从图片文件名取来的）
  const imgKey = '7d070483c80752b30d309a11c0c9a9ad';
  const subKey = 'b888d6f1d8b042d3973b4cf6b0b5bd99';

  group('mixinKey', () {
    test('重排表是 0~63 的一个全排列', () {
      // 表本身写错（漏一项、重复一项）会让所有签名一起漂，先用结构不变量拦住
      expect(kMixinKeyEncTab.length, 64);
      expect(kMixinKeyEncTab.toSet().length, 64);
      expect(kMixinKeyEncTab.every((i) => i >= 0 && i < 64), isTrue);
      expect(kMixinKeyEncTab.reduce((a, b) => a > b ? a : b), 63);
    });

    test('两个 key 重排后截 32 位', () {
      // python（orig 是两个 key 直接拼接，共 64 字符）：
      //   orig = '7d070483c80752b30d309a11c0c9a9ad' + 'b888d6f1d8b042d3973b4cf6b0b5bd99'
      //   reduce(lambda s, i: s + orig[i], mixinKeyEncTab, '')[:32]
      //     → d330cc1b330db728904788b09ab15f82
      final key = biliMixinKey(imgKey, subKey);
      expect(key, 'd330cc1b330db728904788b09ab15f82');
      expect(key.length, kBiliMixinKeyLength);
    });

    test('key 不够长时报可读原因，而不是让下标越界', () {
      // 短 key 只可能是 nav 没给 wbi_img（弱网 / 风控的真实形态）。
      // RangeError 看上去像本地代码 bug，用户与集成方都归不了因。
      expect(() => biliMixinKey('abc', 'def'), throwsA(isA<BiliWbiException>()));
      expect(() => biliMixinKey(imgKey, ''), throwsA(isA<BiliWbiException>()));
      try {
        biliMixinKey(imgKey, 'b888d6f1');
      } on BiliWbiException catch (e) {
        expect(e.message, contains('wbi 签名密钥不足'));
        expect(e.message, contains('40 个字符'));
      }
    });
  });

  group('完整签名', () {
    const mixin = 'd330cc1b330db728904788b09ab15f82';
    const wts = 1700000000;

    // 参数集刻意含一个带 `!'()*` 的值（验过滤生效）与一个中文值（验 urlencode 形状）。
    Map<String, dynamic> params() => {
          'bvid': 'BV1y4411o7Kp',
          'cid': 765432109,
          'qn': 80,
          'fnval': 4048,
          'fnver': 0,
          'fourk': 1,
          'title': '冬天的海',
          'note': "!'()*abc",
        };

    test('w_rid 等于 Python 独立算出的那串', () {
      // python（注意 w_rid 不参与签名，query 里没有它）：
      //   p = {'bvid':'BV1y4411o7Kp','cid':765432109,'qn':80,'fnval':4048,
      //        'fnver':0,'fourk':1,'title':'冬天的海','note':"!'()*abc",'wts':1700000000}
      //   p = dict(sorted(p.items()))
      //   p = {k: ''.join(filter(lambda c: c not in "!'()*", str(v))) for k, v in p.items()}
      //   q = urllib.parse.urlencode(p)
      //     → bvid=BV1y4411o7Kp&cid=765432109&fnval=4048&fnver=0&fourk=1&note=abc
      //       &qn=80&title=%E5%86%AC%E5%A4%A9%E7%9A%84%E6%B5%B7&wts=1700000000
      //   hashlib.md5((q + 'd330cc1b330db728904788b09ab15f82').encode()).hexdigest()
      //     → aeb4857b7f4b5cb14333911ba003b86c
      final signed = biliSignWbi(params(), mixin, wts: wts);
      expect(signed['w_rid'], 'aeb4857b7f4b5cb14333911ba003b86c');
      expect(signed['wts'], '1700000000');
    });

    test('query 串本身与 Python 的 urlencode 逐字节一致', () {
      // 签名对不上时第一个要看的就是这串；空格转 `+`、`~` 不转义、UTF-8 大写十六进制
      final signed = biliSignWbi(params(), mixin, wts: wts)
        ..remove('w_rid');
      expect(
        biliWbiQuery(signed),
        'bvid=BV1y4411o7Kp&cid=765432109&fnval=4048&fnver=0&fourk=1'
        '&note=abc&qn=80&title=%E5%86%AC%E5%A4%A9%E7%9A%84%E6%B5%B7'
        '&wts=1700000000',
      );
    });

    test('特殊字符在返回的 map 里就已经被剔掉（发出去的字节 = 签名的字节）', () {
      final signed = biliSignWbi(params(), mixin, wts: wts);
      final note = signed['note'] as String;
      expect(note, 'abc');
      for (final ch in ["!", "'", '(', ')', '*']) {
        expect(note, isNot(contains(ch)), reason: '$ch 该在签名之前就被剔掉');
      }
    });

    test('不改动传进来的原 map', () {
      final source = params();
      biliSignWbi(source, mixin, wts: wts);
      expect(source.containsKey('w_rid'), isFalse);
      expect(source.containsKey('wts'), isFalse);
      expect(source['note'], "!'()*abc");
    });

    test('同一份参数的两种插入顺序给出同一个 w_rid', () {
      final forward = biliSignWbi(params(), mixin, wts: wts);
      final reversed = <String, dynamic>{};
      for (final key in params().keys.toList().reversed) {
        reversed[key] = params()[key];
      }
      final signedReversed = biliSignWbi(reversed, mixin, wts: wts);
      expect(signedReversed['w_rid'], forward['w_rid']);
      expect(signedReversed['w_rid'], 'aeb4857b7f4b5cb14333911ba003b86c');
    });

    test('null 值的可选项整个不进签名', () {
      // 上层把 bvid / aid 这类「有哪个传哪个」的可选参数一起塞进来，
      // 这里必须当它们不存在 —— 带 `aid=null` 去签名会被服务端重算成另一种 query。
      final signed = biliSignWbi({...params(), 'aid': null}, mixin, wts: wts);
      expect(signed.containsKey('aid'), isFalse);
      expect(signed['w_rid'], 'aeb4857b7f4b5cb14333911ba003b86c');
    });

    test('wts 不注入时取当前秒级时间戳', () {
      final signed = biliSignWbi({'bvid': 'BV1y4411o7Kp'}, mixin);
      final wts = int.tryParse(signed['wts'] as String);
      expect(wts, isNotNull);
      // 要的是**秒**：拿毫秒当 wts 是照抄别人实现时最容易漏的一处，
      // 表现同样是 -403。
      final delta = DateTime.now().millisecondsSinceEpoch ~/ 1000 - wts!;
      expect(delta, inInclusiveRange(0, 5));
    });
  });

  group('从图片地址取 key', () {
    test('去扩展名', () {
      expect(
        biliKeyFromUrl('https://i0.hdslb.com/bfs/face/abcdef0123456789.jpg'),
        'abcdef0123456789',
      );
    });

    test('带 query 的也要先剥掉再取后缀', () {
      expect(
        biliKeyFromUrl(
          'https://i0.hdslb.com/bfs/face/1a2b3c4d5e6f78901234567890abcdef.jpg'
          '?auth_key=1700000000-0-0-fe8d3a8c&bfa=1',
        ),
        '1a2b3c4d5e6f78901234567890abcdef',
      );
    });

    test('nav 上那对真实形状的地址能直接拼出 mixinKey', () {
      final img = biliKeyFromUrl('https://i0.hdslb.com/bfs/wbi/$imgKey.png');
      final sub = biliKeyFromUrl('https://i0.hdslb.com/bfs/wbi/$subKey.png');
      expect(biliMixinKey(img, sub), 'd330cc1b330db728904788b09ab15f82');
    });

    test('空串与没有点号的文件名都原样返回', () {
      expect(biliKeyFromUrl(''), '');
      expect(biliKeyFromUrl('abcdef0123456789'), 'abcdef0123456789');
      // 目录名以点开头时那不扩展名，别把首字符当点切掉
      expect(biliKeyFromUrl('https://x/y/.hidden'), '.hidden');
    });
  });
}
