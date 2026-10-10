import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_web.dart';

/// 行分隔符 / 行结束符：JSON 允许它们在字符串里裸着出现，JS 的字符串字面量
/// 把它们当行终止符 —— 这是 `_jsString` 必须额外处理的那两个字符。
const String kLineSep = '\u2028';
const String kParaSep = '\u2029';

void main() {
  group('jsString：把任意字符串安全地放进 JS 字符串字面量', () {
    // 能 round-trip 回原值，就证明转义没多也没少；这是这条 helper 的正确性判据。
    const nasty = [
      'https://api.bilibili.com/x/web-interface/nav',
      '''x");alert(1);//''',
      r"x');alert(1);//",
      r'反斜杠 \ 与引号 " 混排',
      '换行\n与制表\t',
      '$kLineSep 行分隔 $kParaSep 行结束',
      '中文与 emoji 😀 保持原样',
      '',
    ];

    test('每条都能原样解码回来', () {
      for (final s in nasty) {
        expect(jsonDecode(jsString(s)), s, reason: '转义出错：$s');
      }
    });

    test('首尾一定是双引号', () {
      for (final s in nasty) {
        final out = jsString(s);
        expect(out.startsWith('"') && out.endsWith('"'), isTrue, reason: out);
      }
    });

    test('输出里不出现裸的换行/回车 —— 否则整段脚本被折断', () {
      for (final s in nasty) {
        final out = jsString(s);
        expect(out.contains('\n'), isFalse, reason: '没转义换行：$out');
        expect(out.contains('\r'), isFalse, reason: '没转义回车：$out');
      }
    });

    test('U+2028 / U+2029 被转义成 \\uXXXX，且原文里不再裸着出现', () {
      final sep = jsString('a$kLineSep' 'b');
      final para = jsString('a$kParaSep' 'b');
      expect(sep, contains(r'\u2028'));
      expect(para, contains(r'\u2029'));
      expect(sep.contains(kLineSep), isFalse);
      expect(para.contains(kParaSep), isFalse);
      // 转义之后仍然能解回原值（正控制：证明不是「删掉了」而是「换写法」）
      expect(jsonDecode(sep), 'a$kLineSep' 'b');
      expect(jsonDecode(para), 'a$kParaSep' 'b');
    });

    test('中文与 emoji 不转成 \\uXXXX（可读性，JSON 也不要求）', () {
      expect(jsString('海边'), '"海边"');
      expect(jsString('😀'), '"😀"');
    });
  });

  group('发起脚本', () {
    test('URL 以字面量出现，并带 credentials: include 与两个哨兵', () {
      final s = BiliInPage.startScript('https://api.bilibili.com/x/y?z=1');
      expect(s, contains('"https://api.bilibili.com/x/y?z=1"'));
      expect(s, contains("credentials: 'include'"));
      expect(s, contains("'${BiliInPage.pending}'"));
      expect(s, contains("'${BiliInPage.errorPrefix}'"));
      expect(s, contains('window.__pdBili'));
    });

    test('想跳出字面量的 URL 被关在字符串里', () {
      const evil = '''x");alert(1;//''';
      final s = BiliInPage.startScript(evil);
      // 直接判据：fetch(...) 的第一个实参能被 jsonDecode 还原成原始 URL，
      // 说明它整条待在自己的引号里，没有提前闭合。
      final lit = _fetchArg(s);
      expect(jsonDecode(lit), evil);

      // 正控制：手工把这层引号扒掉，同一判据必须失败，否则测试是空跑的
      final broken = s.replaceFirst(lit, '"$evil"');
      expect(
        () => jsonDecode(_fetchArg(broken)),
        throwsA(isA<FormatException>()),
        reason: '正控制失效：判据抓不出被破坏的脚本',
      );
    });

    test('插值进脚本的 URL 不会带进裸 U+2028', () {
      final s = BiliInPage.startScript('https://x/y$kLineSep');
      expect(s.contains(kLineSep), isFalse);
      expect(jsonDecode(_fetchArg(s)), 'https://x/y$kLineSep');
    });
  });

  group('读回与清理脚本', () {
    test('读脚本先判全局对象存在，未初始化时返回 null 而不是抛', () {
      final s = BiliInPage.readScript('7');
      expect(s, contains('window.__pdBili.done["7"]'));
      expect(s, contains('window.__pdBili &&'));
      expect(s, contains(': null'));
    });

    test('清理脚本删的是同一个键', () {
      final s = BiliInPage.clearScript('7');
      expect(s, contains('delete'));
      expect(s, contains('["7"]'));
    });

    test('请求号里带引号也不会串到别的键上', () {
      const weirdKey = '''1");x''';
      final s = BiliInPage.readScript(weirdKey);
      expect(jsonDecode(RegExp(r'done\[(.*)\]').firstMatch(s)!.group(1)!),
          weirdKey);
    });
  });

  group('响应解码', () {
    test('正常 JSON 出 Map', () {
      expect(
        BiliInPage.decodeResponse('{"code":0,"data":{"isLogin":true}}', 'u'),
        {'code': 0, 'data': {'isLogin': true}},
      );
    });

    test('顶层不是对象 → 抛可读异常', () {
      expect(() => BiliInPage.decodeResponse('[1,2]', 'u'),
          throwsA(isA<BiliInPageException>()));
      expect(() => BiliInPage.decodeResponse('"s"', 'u'),
          throwsA(isA<BiliInPageException>()));
    });

    test('登录页 HTML → 报「不是 JSON」，只带开头一段', () {
      final html = '<html><body>${'x' * 400}</body></html>';
      late BiliInPageException e;
      try {
        BiliInPage.decodeResponse(html, 'u');
        fail('应当抛异常');
      } on BiliInPageException catch (got) {
        e = got;
      }
      expect(e.message, contains('响应不是 JSON'));
      expect(e.message.length, lessThan(320), reason: '整页 HTML 会灌进日志');
      expect(e.message, isNot(contains('x' * 300)));
    });
  });

  group('executeScript 返回值归一', () {
    test('String / num 都认，空串、null、布尔都不认', () {
      expect(BiliInPage.idOf('3'), '3');
      expect(BiliInPage.idOf(3), '3');
      expect(BiliInPage.idOf(''), isNull);
      expect(BiliInPage.idOf(null), isNull);
      expect(BiliInPage.idOf(true), isNull);
    });
  });

  group('登录态', () {
    test('未登录 / 已登录 / 检测不到 三种分得开', () {
      const anon = BiliLoginState();
      expect(anon.isLoggedIn, isFalse);
      expect(anon.unknown, isFalse, reason: '明确的「未登录」不等于「检测不到」');

      const loggedIn =
          BiliLoginState(isLoggedIn: true, uname: '海边', mid: '349326425505');
      expect(loggedIn.unknown, isFalse);
      expect(loggedIn.uname, '海边');

      expect(const BiliLoginState(noData: true).unknown, isTrue);

      final failed = BiliLoginState.failed('页内请求超时（20s）');
      expect(failed.unknown, isTrue);
      expect(failed.error, isNotNull);
      expect(failed.isLoggedIn, isFalse);
    });
  });
}

/// 从发起脚本里抠出 `fetch(` 的第一个实参。
String _fetchArg(String script) =>
    RegExp(r'fetch\((.*), \{ credentials')
        .firstMatch(script)!
        .group(1)!;
