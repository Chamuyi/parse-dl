import 'dart:async';
import 'dart:convert';

import 'package:webview_windows/webview_windows.dart';

import 'app_logger.dart';

/// 在 B 站的内嵌页面里发一个 GET，把响应读回来。
///
/// **为什么要走「页内 fetch」而不是 Dart 的 `HttpClient`：**
/// B 站的登录态（`SESSDATA` 等）是 HttpOnly Cookie，JS 读不到、我们也导不出来，
/// 但它就在那个 WebView 的会话里。让页面自己去 `fetch(..., {credentials:'include'})`，
/// Cookie / Referer / Origin 全部由浏览器补 —— 我们不需要碰凭据，也不用把它
/// 抄进任何文件或日志。D1「登录与列表走 WebView、只有取流的签名自己算」就是这条。
///
/// 参数仍然是我们自己算好的**完整带签名 URL**（`bili_wbi.dart` 的产物）。
/// 也就是说：签名在 Dart 侧，凭据在浏览器侧，两边都不越界。
class BiliInPage {
  /// 轮询间隔与上限。
  ///
  /// `executeScript` 不会 await Promise，只能「发起 + 反复读全局变量」，
  /// 这是 webview_windows 0.4 的唯一可用形态（抖音侧的拦截脚本同一个套路）。
  static const Duration _tick = Duration(milliseconds: 60);
  static const Duration _defaultTimeout = Duration(seconds: 20);

  /// 页内还没写完时的占位值，以及「fetch 抛错了」的前缀。
  ///
  /// 刻意用 ASCII 哨兵而不是控制字符：NUL 过 JS ↔ Dart 的桥时会不会被吃掉，
  /// 取决于 webview_windows 的实现，赌不起；而正常的 B 站响应一定是 `{` 开头的
  /// JSON，撞不上这两个串。
  static const String pending = '@@PD@@';
  static const String errorPrefix = '@@ERR@@';

  /// 发起一条请求并等结果，返回解码后的 JSON。
  ///
  /// 失败原因分三类报出来（脚本没跑起来 / 页内 fetch 抛错 / 不是 JSON），
  /// 因为这三类在真机上的处置完全不同：前者是 WebView 没就绪，
  /// 中者是网络或被风控，后者通常是跳到了登录页的 HTML。
  static Future<Map<String, dynamic>> get(
    WebviewController ctrl,
    String url, {
    Duration timeout = _defaultTimeout,
  }) async {
    final id = await ctrl.executeScript(startScript(url));
    final key = idOf(id);
    if (key == null) {
      throw const BiliInPageException(
          '页面脚本没有返回请求号（WebView 可能还没就绪）');
    }

    final raw = await _awaitResult(ctrl, key, timeout);
    // 结果已经被读走，顺手清掉，别让全局对象越长越大
    unawaited(ctrl.executeScript(clearScript(key)).catchError((_) => null));

    if (raw == null) {
      throw BiliInPageException('页内请求超时（${timeout.inSeconds}s）：$url');
    }
    if (raw.startsWith(errorPrefix)) {
      throw BiliInPageException(
          '页内请求失败：${raw.substring(errorPrefix.length)}');
    }
    return decodeResponse(raw, url);
  }

  /// 检测内嵌页面的登录态。
  ///
  /// `nav` 接口不需要 WBI 签名，`data.isLogin` 就是「扫码了没有」的权威答案；
  /// 顺带把 `uname` / `mid` 带回去给界面显示「当前登录：xxx」。
  static Future<BiliLoginState> loginState(WebviewController ctrl) async {
    try {
      final j = await get(ctrl, 'https://api.bilibili.com/x/web-interface/nav');
      final data = j['data'];
      if (data is! Map) {
        return const BiliLoginState(noData: true);
      }
      return BiliLoginState(
        isLoggedIn: data['isLogin'] == true,
        uname: (data['uname'] as String?) ?? '',
        mid: data['mid']?.toString() ?? '',
      );
    } catch (e) {
      AppLogger.log('BILI', '登录态检测失败：$e');
      return BiliLoginState.failed('$e');
    }
  }

  /// 反复读全局槽位直到不再是占位值。超时返回 null（不抛，交给调用方定夺）。
  static Future<String?> _awaitResult(
    WebviewController ctrl,
    String key,
    Duration timeout,
  ) async {
    final ticks = timeout.inMilliseconds ~/ _tick.inMilliseconds;
    for (var i = 0; i < ticks; i++) {
      await Future<void>.delayed(_tick);
      final v = await ctrl.executeScript(readScript(key));
      if (v is! String || v == pending) continue;
      return v;
    }
    return null;
  }

  /// 把页内读回来的文本变成 JSON 对象。纯函数，可单测。
  static Map<String, dynamic> decodeResponse(String raw, String url) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // 截一段就够了：整串可能是登录页的 HTML，几百 KB 进日志只会把根因埋掉
      final head = raw.length > 240 ? '${raw.substring(0, 240)}…' : raw;
      throw BiliInPageException('响应不是 JSON（多半被重定向到登录页）：$head');
    }
    if (decoded is! Map) {
      throw BiliInPageException('响应顶层不是对象：${decoded.runtimeType}');
    }
    return decoded.cast<String, dynamic>();
  }

  /// 发起脚本：把结果写进 `window.__pdBili.done[k]`，返回号 `k`。
  ///
  /// URL 一律经 [jsString] 成串后再拼进脚本 —— 直接拼原始 URL 等于把
  /// 用户粘进来的链接当代码执行。
  static String startScript(String url) => '''
(function () {
  var ns = window.__pdBili || (window.__pdBili = { seq: 0, done: {} });
  var k = String(++ns.seq);
  ns.done[k] = '$pending';
  fetch(${jsString(url)}, { credentials: 'include' })
    .then(function (r) { return r.text(); })
    .then(function (t) { ns.done[k] = t; })
    .catch(function (e) {
      ns.done[k] = '$errorPrefix' + String((e && e.message) || e);
    });
  return k;
})()''';

  static String readScript(String key) =>
      "window.__pdBili && window.__pdBili.done"
      " ? window.__pdBili.done[${jsString(key)}] : null";

  static String clearScript(String key) =>
      "if (window.__pdBili && window.__pdBili.done)"
      " { delete window.__pdBili.done[${jsString(key)}]; } 'ok'";

  /// executeScript 的返回值是 `Object?`，同一个号有时被送成 String、
  /// 有时是 num，两种都认。
  static String? idOf(Object? v) {
    if (v is String) return v.isEmpty ? null : v;
    if (v is num) return v.toString();
    return null;
  }
}

/// 把 Dart 字符串变成 JS 字符串字面量。
///
/// `jsonEncode` 的转义集是 JS 的合法子集，唯一例外是 `U+2028` / `U+2029`：
/// 它们在 JSON 字符串里可以裸着出现，在 JS 字符串字面量里却是行分隔符，
/// 会让整段脚本语法错误（不是注入，但会让请求静默失败在页面里）。
String jsString(String s) => jsonEncode(s)
    .replaceAll('\u2028', '\\u2028')
    .replaceAll('\u2029', '\\u2029');

/// 页内请求的失败。
class BiliInPageException implements Exception {
  const BiliInPageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 内嵌页面的登录态快照。
class BiliLoginState {
  const BiliLoginState({
    this.isLoggedIn = false,
    this.uname = '',
    this.mid = '',
    this.noData = false,
    this.error,
  });

  BiliLoginState.failed(this.error)
      : isLoggedIn = false,
        uname = '',
        mid = '',
        noData = false;

  final bool isLoggedIn;
  final String uname;
  final String mid;

  /// 响应里压根没有 `data`（多半是被风控）。
  final bool noData;

  /// 检测本身失败的原因；`null` = 检测成功。
  final String? error;

  /// 拿不到结论 —— 界面要说「检测不到」，不能说「未登录」。
  bool get unknown => error != null || noData;
}
