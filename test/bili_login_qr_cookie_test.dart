import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_api.dart';

/// 扫码取回登录态并**暂存**，供后面几支登录档执行器复用（跑完由外层删掉整个目录）。
///
/// 为什么单独一支：正常纪律是「cookie 只活在一个进程的内存里」，但这次登录档要跑
/// 两三轮（列表三格 + 高清档位下载），每轮都让他扫一次码是白白折腾人。
/// 所以这里把扫码这一件事单独做完，落到 `PD_BILI_COOKIE_OUT` 指定的文件里，
/// 用完**必须删**。落点选在仓库外（`F:\qoder\_tools\bili\live\`），
/// 永不进 git、不进日志、不打印值。
///
/// 用法（后台跑，然后把打印出来的 URL 给他扫码）：
///
///     PD_BILI_COOKIE_OUT=F:/qoder/_tools/bili/live/ck.txt \
///     PD_BILI_QR_OUT=F:/qoder/_tools/bili/live/qr.txt \
///       flutter test test/bili_login_qr_cookie_test.dart
///
/// 轮询只打**字节数与结论**，绝不打 cookie 值；`code=0` 之外的每一轮只报一个状态码。
void main() {
  final cookieOut = Platform.environment['PD_BILI_COOKIE_OUT'];
  final qrOut = Platform.environment['PD_BILI_QR_OUT'];

  test(
    '扫码 → 拿到登录 cookie 并暂存（用 dart:io 直连，为的是保住 Set-Cookie 的每一条）',
    timeout: const Timeout(Duration(minutes: 22)),
    skip: cookieOut == null ? '没给 PD_BILI_COOKIE_OUT' : false,
    () async {
      // 不初始化 binding：那会把所有 HttpClient 请求打回 400。
      final api = BiliApi();
      final outPath = cookieOut!;
      final dir = File(outPath).parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);

      String? pending;
      for (var attempt = 1; attempt <= 24; attempt++) {
        final qr = await api.qrcodeGenerate();
        final qurl = qr.url, qkey = qr.qrcodeKey;
        pending = qurl;
        if (qrOut != null) {
          File(qrOut).writeAsStringSync('$qurl\n$qkey\n', flush: true);
        }
        // 只 ASCII 化的长度与提示进 stdout：URL 本身只落文件，少一处复制泄漏。
        stdout.writeln('QR_READY attempt=$attempt url_len=${qurl.length} key_len=${qkey.length}');

        final until = DateTime.now().add(const Duration(minutes: 3, seconds: 20));
        while (DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(seconds: 2));
          final pair = await pollOnce(qkey);
          if (pair == null) continue;
          final (code, cookies) = pair;
          if (code == 0 && cookies.isNotEmpty) {
            File(outPath).writeAsStringSync(cookies, flush: true);
            stdout.writeln('LOGIN ok cookie_bytes=${cookies.length} attempts=$attempt');
            // 立刻自查一次：证明这颗 cookie 真能让接口认出登录态，而不是存了一串废值。
            final verified = await verifyLogin(api, cookies);
            stdout.writeln('LOGIN verified isLogin=$verified mid_len=${verified ? 1 : 0}');
            expect(verified, isTrue,
                reason: '扫码说成功了，但 nav 不认这串 cookie —— 别把它当登录态用');
            return;
          }
          if (code == 86038) {
            stdout.writeln('QR_EXPIRED attempt=$attempt');
            break; // 换一张码
          }
        }
      }
      fail('扫了 $pending 这么久还没确认，登录态没拿到（这一支不产出 cookie 文件）');
    },
  );
}

/// 一次轮询：返回 `(业务码, 拼好的 cookie 串)`；网络抖动返回 null 继续等。
///
/// 为什么绕开 `BiliApi.qrcodePoll`：`package:http` 的 headers 是
/// `Map<String,String>`，dart:io 早把同名 `Set-Cookie` 用逗号并成一条，
/// 而它的值里本来就带逗号（`expires=Mon, 12 ...`），并完再也拆不回去。
/// `HttpHeaders` 的下标取值才保得住每条独立的头。
Future<(int, String)?> pollOnce(String key) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(
      Uri.parse(
        'https://passport.bilibili.com/x/passport-login/web/qrcode/poll'
        '?qrcode_key=$key&source=main-fe-header',
      ),
    );
    req.headers.set('User-Agent', kBiliUserAgent);
    req.headers.set('Referer', 'https://www.bilibili.com/');
    final res = await req.close().timeout(const Duration(seconds: 12));
    final body = await res.transform(utf8.decoder).join();
    final each = res.headers['set-cookie'] ?? const <String>[];
    final cookie = each
        .map((h) => h.split(';').first.trim())
        .where((kv) => kv.contains('='))
        .join('; ');
    final decoded = body.isEmpty ? null : jsonDecode(body);
    if (decoded is! Map) return null;
    final code = int.tryParse('${decoded['code']}') ?? -1;
    return (code, cookie);
  } catch (e) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 带着这串 cookie 问一次 `nav`：`isLogin` 为真才算数。
Future<bool> verifyLogin(BiliApi api, String cookie) async {
  api.setCookie(cookie);
  try {
    final nav = await api.getData('/x/web-interface/nav', null, what: 'nav');
    return nav['isLogin'] == true;
  } catch (e) {
    stdout.writeln('LOGIN verify failed: ${e.runtimeType}');
    return false;
  }
}
