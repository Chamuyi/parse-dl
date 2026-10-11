import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_api.dart';
import 'package:parse_dl/services/bili_subtitle.dart';

/// 钉住两条**只有真接口才能暴露**的字幕形状。
///
/// 2026-10-11 登录档验收现场：三条 1080P 全部下载成功，但每条都报
/// 「字幕：ai-zh 正文取回失败」，而同一份日志里那条 URL 的 `GET … -> 200`
/// 是**成功**的。顺着查下去是两个独立的 bug：
///
/// **bug 1 —— 信封**：字幕正文是 CDN 直出，顶层是
/// `{font_size, font_color, Stroke, type, lang, version, body:[…]}`，
/// **没有 code、也没有 data**。而 `jsonAtUrl` 走了为业务接口设计的 `_unwrap`，
/// 它要求 `code == 0` 且 `data` 是 Map，于是这份正常响应被判成
/// 「B 站返回 code=null」，又被调用侧 `catch (_)` 吞成一句「正文取回失败」。
///
/// **bug 2 —— 字段名**：修好信封后错误变成「ai-zh 是空的」。实测三条稿件，
/// 每条 body 的键都是 `['content','from','location','music','sid','to']`，
/// 而解析器读的是 `start_time`/`end_time` → 每条都在 `s == null` 被 continue
/// → 解析出 0 条。同一份协议在 `bili_chapter.dart` 里读的就是 `from`/`to`。
///
/// **两个 bug 匿名档都碰不到**：匿名态 `subtitles` 恒为 0 条，根本走不到取正文。
/// 而既有单测把 `jsonAtUrl` 注入成返回 Map 的替身、夹具又照抄了错字段名，
/// 所以 1426 条全绿也抓不到任何一个。
void main() {
  test(
    '字幕正文：不带 code/data 信封的响应要能取回来',
    timeout: const Timeout(Duration(minutes: 1)),
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      // 真实形状：无 code、无 data；每条的键照实测抄
      // （content/from/location/music/sid/to）。
      const payload = '{"font_size":0.4,"font_color":"#FFFFFF",'
          '"background_alpha":0.5,"background_color":"#9C27B0",'
          '"Stroke":"none","type":"json","lang":"zh","version":"v1.0.0",'
          '"body":[{"from":0.5,"to":2.0,"content":"第一句",'
          '"location":2,"music":0.0,"sid":1}]}';

      server.listen((req) async {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(payload);
        await req.response.close();
      });

      final api = BiliApi();
      final url = 'http://127.0.0.1:${server.port}/ai_subtitle.json';

      // 判据：这份响应没有 code/data，但它是**合法**的字幕正文。
      // 取不回来（抛异常）就是 bug 1 复发。
      final got = await api.jsonAtUrl(url);
      expect(got['body'], isA<List>(), reason: '正文没取回来：$got');
      expect(got['body'] as List, hasLength(1));
    },
  );

  test(
    '字幕正文：用真字段名 from/to 要能解出条目（start_time 是错的）',
    () {
      // bug 2 的回归：真接口给的是 from/to
      final real = <String, dynamic>{
        'body': [
          {'content': '第二句', 'from': 2.5, 'to': 4.0, 'location': 2, 'music': 0.0, 'sid': 1},
          {'content': '第一句', 'from': 0.5, 'to': 2.0, 'location': 2, 'music': 0.0, 'sid': 1},
        ],
      };
      final lines = biliParseSubtitleBody(real);
      expect(lines, hasLength(2), reason: 'from/to 没被认出来 —— bug 2 复发');
      // 要按时间排好，且秒转毫秒
      expect(lines.first.$1, 500);
      expect(lines.first.$3, '第一句');
      expect(lines.last.$1, 2500);
      expect(lines.last.$3, '第二句');

      // 旧字段名作为别名保留（人工字幕没验过，不排除它给另一套名字）
      final legacy = <String, dynamic>{
        'body': [
          {'content': '旧写法', 'start_time': 1.0, 'end_time': 2.0},
        ],
      };
      expect(biliParseSubtitleBody(legacy), hasLength(1),
          reason: 'start_time 作为别名要还能兜住');

      // 负控制：两边都没有时间字段时，必须**解不出来**而不是编一个 0 秒出来
      final neither = <String, dynamic>{
        'body': [
          {'content': '没有时间', 'location': 1},
        ],
      };
      expect(biliParseSubtitleBody(neither), isEmpty,
          reason: '没有时间字段时不许凭空造条目');
    },
  );

  test(
    '字幕正文：业务错误信封仍要抛（别把判据放松成"什么都收"）',
    timeout: const Timeout(Duration(minutes: 1)),
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      // 服务端真回了一个业务错误时，必须还是抛 —— 否则新的实现
      // 会把「被风控拒了」也当成一份正常正文吞下去。
      const payload = '{"code":-412,"message":"请求被拦截","data":null}';

      server.listen((req) async {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(payload);
        await req.response.close();
      });

      final api = BiliApi();
      final url = 'http://127.0.0.1:${server.port}/blocked.json';

      await expectLater(
        api.jsonAtUrl(url),
        throwsA(isA<BiliApiException>()),
        reason: '带 code 的业务错误信封必须仍然抛，不能被当成正文收下',
      );
    },
  );
}
