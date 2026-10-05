import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'app_prefs.dart';

import '../models/media.dart';
import '../models/user.dart';
import 'app_logger.dart';
import 'twitter_time.dart';

/// X (Twitter) API 客户端。
///
/// 通过 GraphQL 接口拉取用户信息与媒体列表。
///
/// **实现策略：**
/// 1. HTTP 走 Dart 原生 `http` 包 —— 不再绕道 Rust 中转，简化调用链。
/// 2. 代理：用户启用时把代理 URL 写入环境变量 `HTTP_PROXY` / `HTTPS_PROXY`，
///    `http` 包会自动读取。关掉代理时还原。系统代理读取仍然走 Rust 端（IPC）。
/// 3. 失败重试：指数退避，最多 5 次（16 次只会把一次网络抖动拖成几分钟，5 次够用，
///    剩下的都是真的拿不到）。
class XApi {
  /// 已登录的 cookie 字符串（含 ct0）。
  String _cookie = '';

  /// Bearer token（X 公开的常量，所有 X 客户端都用同一个）。
  static const String _bearer =
      'AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA';

  /// User-Agent（移动端 UA，X 对桌面 UA 更严格）。
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

  static const String _host = 'x.com';

  // ── 代理 ────────────────────────────────────────────────────
  // **重要**：Dart 的 HttpClient 既不会读 Windows「Internet 选项」里的系统代理，
  // 也不读 Dart VM 内的环境变量。必须显式设置 `findProxy`，否则在需要代理的
  // 网络环境下会直接抛 `HandshakeException: Connection terminated during handshake`。

  /// 当前生效的 findProxy 规则（null / 空 = 直连）
  String? _findProxy;

  /// 当前是否走代理
  bool get proxyActive => (_findProxy ?? '').isNotEmpty;

  /// 当前 findProxy 规则（诊断用）
  String? get findProxyRule => _findProxy;

  /// 应用代理设置。由 `main.dart` 在启动时与设置变化时调用。
  ///
  /// - `enable == false`   → 直连
  /// - `useSystem == true` → 读 Windows 注册表里的系统代理
  /// - 否则使用 `url`
  Future<void> applyProxy({
    required bool enable,
    required bool useSystem,
    required String url,
  }) async {
    if (!enable) {
      _setFindProxy(null, '代理已关闭 → 直连');
      return;
    }
    final raw = useSystem ? await _readSystemProxy() : url.trim();
    if (raw == null || raw.trim().isEmpty) {
      _setFindProxy(null, '没有可用的代理地址 → 直连');
      return;
    }
    _setFindProxy(_toFindProxy(raw), null);
  }

  /// 统一设置 findProxy，并**同步到全局 HttpOverrides**。
  ///
  /// 后者负责让 `Image.network`（媒体缩略图、用户头像）也走代理 ——
  /// 那些图片走的是全局 HttpClient，不受本类的 `_findProxy` 影响。
  void _setFindProxy(String? rule, String? reason) {
    _findProxy = rule;
    ProxyHttpOverrides.findProxy = rule;
    debugPrint(
        rule == null ? 'XApi: ${reason ?? '直连'}' : 'XApi: findProxy = $rule');
  }

  /// 当前代理的完整 URL（带 scheme），供 aria2 的 `all-proxy` 使用。
  String? get effectiveProxyUrl {
    final rule = _findProxy;
    if (rule == null || rule.isEmpty) return null;
    final sp = rule.indexOf(' ');
    if (sp < 0) return null;
    final scheme = rule.substring(0, sp).toUpperCase();
    final hostPort = rule.substring(sp + 1);
    if (scheme == 'SOCKS5') return 'socks5://$hostPort';
    if (scheme == 'SOCKS') return 'socks4://$hostPort';
    return 'http://$hostPort';
  }

  /// 把 `http://127.0.0.1:7890` / `socks5://…` / 裸 `127.0.0.1:7890`
  /// 统一成 HttpClient 需要的 `PROXY host:port` / `SOCKS5 host:port`。
  String _toFindProxy(String raw) {
    final s = raw.trim();
    final lower = s.toLowerCase();
    if (lower.startsWith('socks5://')) return 'SOCKS5 ${s.substring(9)}';
    if (lower.startsWith('socks5h://')) return 'SOCKS5 ${s.substring(10)}';
    if (lower.startsWith('socks4://')) return 'SOCKS ${s.substring(9)}';
    if (lower.startsWith('socks://')) return 'SOCKS ${s.substring(8)}';
    if (lower.startsWith('https://')) return 'PROXY ${s.substring(8)}';
    if (lower.startsWith('http://')) return 'PROXY ${s.substring(7)}';
    return 'PROXY ${s.replaceAll(RegExp(r'/+$'), '')}';
  }

  /// 读 Windows「Internet 选项」里的代理（HKCU 注册表）。
  ///
  /// 返回形如 `127.0.0.1:7890`；未启用或读不到返回 null。
  Future<String?> _readSystemProxy() async {
    if (!Platform.isWindows) return null;
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    // 用绝对路径，避免依赖 PATH
    final regExe =
        '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\reg.exe';
    try {
      final enableRes =
          await Process.run(regExe, ['query', key, '/v', 'ProxyEnable']);
      if (enableRes.exitCode != 0) return null;
      final mEnable =
          RegExp(r'ProxyEnable\s+REG_DWORD\s+0x([0-9a-fA-F]+)')
              .firstMatch(enableRes.stdout.toString());
      final on = mEnable != null &&
          (int.tryParse(mEnable.group(1)!, radix: 16) ?? 0) != 0;
      if (!on) {
        debugPrint('XApi: 系统代理未启用（ProxyEnable=0）');
        return null;
      }

      final serverRes =
          await Process.run(regExe, ['query', key, '/v', 'ProxyServer']);
      if (serverRes.exitCode != 0) return null;
      var value = RegExp(r'ProxyServer\s+REG_SZ\s+(.+)')
          .firstMatch(serverRes.stdout.toString())
          ?.group(1)
          ?.trim();
      if (value == null || value.isEmpty) return null;

      // 可能是 "http=1.2.3.4:80;https=1.2.3.4:80" 这种按协议分列的值
      if (value.contains('=')) {
        final map = <String, String>{};
        for (final part in value.split(';')) {
          final i = part.indexOf('=');
          if (i > 0) {
            map[part.substring(0, i).trim().toLowerCase()] =
                part.substring(i + 1).trim();
          }
        }
        value = map['https'] ?? map['http'] ?? (map.isEmpty ? '' : map.values.first);
      }
      return value.isEmpty ? null : value;
    } catch (e) {
      debugPrint('XApi: 读取系统代理失败：$e');
      return null;
    }
  }

  /// 连通性测试：拉一次 x.com 首页。成功返回 null，失败返回错误描述。
  Future<String?> ping() async {
    try {
      await _getText(Uri.https(_host, '/'), maxRetry: 1);
      return null;
    } catch (e) {
      return e is XApiException ? e.message : e.toString();
    }
  }

  /// 设置 cookie。空字符串表示未登录。
  void setCookie(String cookie) {
    _cookie = cookie;
  }

  bool get hasCookie => _cookie.isNotEmpty;

  /// 从 cookie 字符串里抽取 ct0。
  String? get _csrfToken {
    for (final part in _cookie.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length >= 2 && kv[0] == 'ct0') {
        return kv.sublist(1).join('=');
      }
    }
    return null;
  }

  Map<String, String> _commonHeaders() {
    final csrf = _csrfToken;
    return {
      'User-Agent': _userAgent,
      'Referer': 'https://$_host/',
      'Accept': '*/*',
      if (_cookie.isNotEmpty && csrf != null) ...{
        'Authorization': 'Bearer $_bearer',
        'Cookie': _cookie,
        'X-Csrf-Token': csrf,
      },
    };
  }

  /// 只带 Cookie 的请求头（）。
  ///
  /// **请求 x.com 的 HTML 页面时必须用它** —— 带 `Authorization` 请求首页会被 401
  /// （实测日志里 `GET / -> 401`，只带 Cookie 就正常）。
  Map<String, String> _cookieOnlyHeaders() => {
        'User-Agent': _userAgent,
        'Referer': 'https://$_host',
        if (_cookie.isNotEmpty) 'Cookie': _cookie,
      };

  /// 构建 HTTP 客户端：按当前代理设置注入 `findProxy`。
  ///
  /// Dart 的 `HttpClient` 默认直连，不认系统代理 —— 所以这里必须显式注入，
  /// 否则在国内网络下会抛 `HandshakeException`。
  http.Client _httpClient() {
    final rule = _findProxy;
    if (rule == null || rule.isEmpty) return http.Client();
    final inner = HttpClient();
    inner.findProxy = (uri) => rule;
    inner.connectionTimeout = const Duration(seconds: 20);
    return IOClient(inner);
  }

  /// 通用 GET，带 JSON 解析与重试。
  Future<Map<String, dynamic>> _getJson(
    Uri uri, {
    int maxRetry = 5,
  }) async {
    var delayMs = 200;
    Object? lastErr;
    for (var i = 0; i < maxRetry; i++) {
      try {
        final res = await _httpClient().get(
          uri,
          headers: _commonHeaders(),
        ).timeout(const Duration(seconds: 20));
        AppLogger.log('XAPI', 'GET ${_logUri(uri)} -> ${res.statusCode}');
        if (res.statusCode == 429 || res.statusCode == 403) {
          // X 限流：等更久
          await Future<void>.delayed(
              Duration(milliseconds: delayMs * (i + 2)));
          continue;
        }
        if (res.statusCode >= 400) {
          final snippet = utf8.decode(res.bodyBytes);
          AppLogger.log(
            'XAPI',
            'HTTP ${res.statusCode} ${_logUri(uri)} body='
            '${snippet.substring(0, snippet.length.clamp(0, 400))}',
          );
          throw XApiException(
              'HTTP ${res.statusCode}: ${res.body.substring(0, res.body.length.clamp(0, 200))}',
              statusCode: res.statusCode);
        }
        return jsonDecode(utf8.decode(res.bodyBytes))
            as Map<String, dynamic>;
      } catch (e) {
        lastErr = e;
        AppLogger.log(
            'XAPI', 'GET ${_logUri(uri)} 第 ${i + 1} 次失败：$e');
        if (i == maxRetry - 1) rethrow;
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        delayMs *= 2;
      }
    }
    throw XApiException('Failed after $maxRetry retries: $lastErr');
  }

  /// 日志用的精简 URI（GraphQL 的 query 可能几 KB，截断）
  static String _logUri(Uri uri) {
    final q = uri.query;
    final short = q.length > 150 ? '${q.substring(0, 150)}…' : q;
    return short.isEmpty ? uri.path : '${uri.path}?$short';
  }

  /// REST v1.1 GET（**不依赖会轮换的 GraphQL queryId**，稳定性更高）。
  ///
  /// 已实测（2026-09）：`users/show.json` / `account/settings.json` /
  /// `account/verify_credentials.json` 均返回 401（存在，需认证）而非 404，
  /// 说明这些端点可用、且不要求 `x-client-transaction-id`。
  Future<dynamic> _getJsonV11(String path, Map<String, String> params) async {
    final uri = Uri.https(_host, path, params);
    final res = await _httpClient()
        .get(uri, headers: _commonHeaders())
        .timeout(const Duration(seconds: 20));
    final text = utf8.decode(res.bodyBytes);
    AppLogger.log('XAPI', 'GET ${_logUri(uri)} -> ${res.statusCode}');
    if (res.statusCode >= 400) {
      throw XApiException(
        'HTTP ${res.statusCode}: ${text.substring(0, text.length.clamp(0, 300))}',
        statusCode: res.statusCode,
      );
    }
    try {
      return jsonDecode(text);
    } catch (_) {
      throw XApiException('响应不是合法 JSON（HTTP ${res.statusCode}）',
          statusCode: res.statusCode);
    }
  }

  /// 把 REST v1.1 的 user 对象转成 [TwitterUser]。
  TwitterUser? _userFromV11(Map<String, dynamic> j) {
    final id = (j['id_str'] as String?) ?? j['id']?.toString();
    final sn = j['screen_name'] as String?;
    if (id == null && sn == null) return null;
    final avatarRaw = j['profile_image_url_https'] as String?;
    return TwitterUser(
      id: id,
      name: j['name'] as String?,
      screenName: sn,
      description: j['description'] as String?,
      avatar: avatarRaw?.replaceFirst('_normal', '_400x400'),
      mediaCount: _tryInt(j['media_count']),
      followersCount: _tryInt(j['followers_count']),
      friendsCount: _tryInt(j['friends_count']),
    );
  }

  /// 通用 GET，直接返回文本（抓 HTML / JS bundle 用）。
  ///
  /// 默认只带 Cookie —— HTML 页面带 `Authorization` 会被 401。
  Future<String> _getText(
    Uri uri, {
    int maxRetry = 3,
    Map<String, String>? headers,
  }) async {
    Object? lastErr;
    for (var i = 0; i < maxRetry; i++) {
      try {
        final res = await _httpClient()
            .get(uri, headers: headers ?? _cookieOnlyHeaders())
            .timeout(const Duration(seconds: 30));
        AppLogger.log('XAPI', 'GET ${_logUri(uri)} -> ${res.statusCode}');
        if (res.statusCode >= 400) {
          throw XApiException('HTTP ${res.statusCode}',
              statusCode: res.statusCode);
        }
        return utf8.decode(res.bodyBytes);
      } catch (e) {
        lastErr = e;
        AppLogger.log('XAPI', 'GET ${_logUri(uri)} 第 ${i + 1} 次失败：$e');
        if (i == maxRetry - 1) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 300 * (i + 1)));
      }
    }
    throw XApiException('Failed after $maxRetry retries: $lastErr');
  }

  // ── GraphQL queryId 动态解析 ────────────────────────────────
  // X 每 2~4 周轮换一次 GraphQL 的 queryId（doc_id）。硬编码的 hash 一过期，
  // 请求就会 404 / 返回空结果 —— 表现就是「搜不到用户」「加载不出媒体」。
  // 所以这里的做法：先从 x.com 的 JS bundle 里抓当前值，抓不到才退回硬编码兜底。

  /// 硬编码兜底 —— **取自原版 X-Spider 2.2.2**
  /// （前代模块 里的 GraphQL 路径），原版实测可用。
  static const Map<String, String> _queryIdFallback = {
    'UserByScreenName': 'NimuplG1OB7Fd2btCLdBOw',
    'UserMedia': 'cEjpJXA15Ok78yO4TUQPeQ',
    'Viewer': 'okN0YyEwCLKQrGUymh4Ugg',
  };

  final Map<String, String> _queryIdCache = {};

  /// queryId 磁盘缓存（AppPrefs），避免每次启动都重抓几 MB 的 bundle
  static const String _queryIdPrefsKey = 'x_query_id_cache_v1';

  /// 磁盘缓存有效期：24 小时（X 轮换周期 2~4 周，24h 足够安全）
  static const int _queryIdTtlMs = 24 * 3600 * 1000;

  bool _queryIdDiskLoaded = false;

  Future<void> _ensureQueryIdCacheLoaded() async {
    if (_queryIdDiskLoaded) return;
    _queryIdDiskLoaded = true;
    try {
      final prefs = await AppPrefs.getInstance();
      final raw = prefs.getString(_queryIdPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final ts = (map['ts'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - ts > _queryIdTtlMs) return;
      final ids = map['ids'];
      if (ids is Map) {
        ids.forEach((k, v) {
          if (k is String && v is String && v.isNotEmpty) {
            _queryIdCache[k] = v;
          }
        });
      }
    } catch (e) {
      debugPrint('XApi: queryId 磁盘缓存读取失败: $e');
    }
  }

  Future<void> _saveQueryIdDiskCache() async {
    try {
      final prefs = await AppPrefs.getInstance();
      await prefs.setString(
        _queryIdPrefsKey,
        jsonEncode({
          'ts': DateTime.now().millisecondsSinceEpoch,
          'ids': _queryIdCache,
        }),
      );
    } catch (e) {
      debugPrint('XApi: queryId 磁盘缓存写入失败: $e');
    }
  }

  /// 清掉 queryId 缓存，强制下次重新抓取。
  void clearQueryIdCache() {
    _queryIdCache.clear();
    _persistQueryIdCacheCleared();
  }

  Future<void> _persistQueryIdCacheCleared() async {
    try {
      final prefs = await AppPrefs.getInstance();
      await prefs.remove(_queryIdPrefsKey);
    } catch (_) {}
  }

  /// 取某个 operation 当前有效的 queryId。
  ///
  /// 顺序：内存/磁盘缓存 → **硬编码兜底**（原版 2.2.2 实测可用的值，快且不发多余请求）
  /// → 抓 x.com 的 JS bundle（仅在 `forceFetch`，即上次请求 404 时才做）。
  Future<String> _resolveQueryId(
    String operationName, {
    bool forceFetch = false,
  }) async {
    await _ensureQueryIdCacheLoaded();
    final hit = _queryIdCache[operationName];
    if (hit != null && hit.isNotEmpty && !forceFetch) return hit;

    // 优先用硬编码兜底 —— 原版 X-Spider 2.2.2 就是用这两个值，
    // 避免每次启动都去拉几 MB 的 bundle。
    if (!forceFetch) {
      final fb = _queryIdFallback[operationName] ?? '';
      if (fb.isNotEmpty) {
        _queryIdCache[operationName] = fb;
        debugPrint('XApi: 使用内置 queryId $operationName = $fb');
        return fb;
      }
    }

    // 上次 404 → 说明内置/缓存的值过期了，抓 bundle 找新的。
    // 注意：已登录时访问 /home 才会返回含 GraphQL 定义的 bundle；
    // 匿名访问只会拿到 logged-out 的空壳（实测不含任何 queryId）。
    for (final page in const ['/home', '/']) {
      try {
        final html = await _getText(Uri.https(_host, page));
        // 兼容旧 client-web 与新 x-web 两种前端路径
        final bundleUrls = RegExp(
          r'''https://abs\.twimg\.com/(?:responsive-web/client-web|x-web)[^"'\s\\]+\.js''',
        ).allMatches(html).map((m) => m.group(0)!).toSet();

        for (final url in bundleUrls) {
          try {
            final js = await _getText(Uri.parse(url));
            final id = _pickQueryId(js, operationName);
            if (id != null) {
              _queryIdCache[operationName] = id;
              debugPrint('XApi: resolved $operationName queryId = $id');
              unawaited(_saveQueryIdDiskCache());
              return id;
            }
          } catch (e) {
            debugPrint('XApi: bundle $url failed: $e');
          }
        }
      } catch (e) {
        debugPrint('XApi: 抓取页面 $page 失败：$e');
      }
    }

    final fb = _queryIdFallback[operationName] ?? '';
    if (fb.isNotEmpty) {
      debugPrint('XApi: fallback queryId for $operationName = $fb');
      _queryIdCache[operationName] = fb;
    }
    return fb;
  }

  /// 从 bundle 源码里抽出 `{queryId:"xxx",operationName:"YYY"}`。
  String? _pickQueryId(String js, String operationName) {
    // ① 紧凑格式（最常见）
    final patterns = [
      RegExp('queryId:"([^"]{10,64})",operationName:"$operationName"'),
      RegExp('operationName:"$operationName",queryId:"([^"]{10,64})"'),
      RegExp("queryId:'([^']{10,64})',operationName:'$operationName'"),
      RegExp("operationName:'$operationName',queryId:'([^']{10,64})'"),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(js);
      if (m != null) return m.group(1);
    }
    // ② 宽松格式：operationName 前后 300 字符内找 queryId
    final idx = js.indexOf('operationName:"$operationName"');
    if (idx >= 0) {
      final start = (idx - 300).clamp(0, js.length);
      final end = (idx + 300).clamp(0, js.length);
      final seg = js.substring(start, end);
      final m = RegExp('queryId:"([^"]{10,64})"').firstMatch(seg);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// GraphQL GET：queryId 过期（404/400）时抓新的 bundle 再试一次。
  Future<Map<String, dynamic>> _graphqlGet(
    String operationName,
    Map<String, String> params, {
    bool allowRetry = true,
  }) async {
    final queryId = await _resolveQueryId(operationName);
    if (queryId.isEmpty) {
      throw XApiException('无法解析 GraphQL queryId：$operationName');
    }
    final uri =
        Uri.https(_host, '/i/api/graphql/$queryId/$operationName', params);
    try {
      return await _getJson(uri);
    } on XApiException catch (e) {
      final expired = e.statusCode == 404 || e.statusCode == 400;
      if (allowRetry && expired) {
        debugPrint(
            'XApi: $operationName -> ${e.statusCode}，尝试抓取最新 queryId');
        _queryIdCache.remove(operationName);
        final fresh = await _resolveQueryId(operationName, forceFetch: true);
        // 抓不到新值（还是内置/缓存的那个）→ 没救了，直接抛
        if (fresh.isEmpty || fresh == queryId) rethrow;
        return _graphqlGet(operationName, params, allowRetry: false);
      }
      rethrow;
    }
  }

  /// 验证当前 cookie 是否有效，并返回当前登录用户的 screen_name。
  ///
  /// **日志实测（2026-09-13）**：
  ///   - `GET /`（只带 Cookie）→ 200，HTML 含 `"screen_name":"…"` ✅
  ///   - `account/settings.json` → **404**（该端点已不可用）
  ///   - GraphQL `Viewer` → **404 Query not found**（queryId 不可靠）
  ///   - GraphQL `UserByScreenName` → **200**（原版 queryId 可用）
  ///
  /// 因此只保留两路：① 首页 HTML 正则（原版做法）② 固定账号验证。
  Future<String?> getCurrentUserScreenName() async {
    if (_cookie.isEmpty || _csrfToken == null) {
      throw XApiException('未设置 cookie');
    }

    // ① 原版做法：拉首页 HTML 正则匹配
    //    （_getText 只带 Cookie —— 带 Authorization 请求首页会 401）
    try {
      final html = await _getText(Uri.https(_host, '/'), maxRetry: 1);
      final m = RegExp(r'"screen_name":"(.*?)"').firstMatch(html);
      if (m != null && m.group(1)!.isNotEmpty) return m.group(1);
      debugPrint('XApi: 首页 HTML（${html.length}B）未含 screen_name');
    } catch (e) {
      debugPrint('XApi: 首页验证失败：$e');
    }

    // ② 用固定账号验证 —— UserByScreenName 已实测返回 200，
    //    能查通即说明 cookie 有效（拿不到自己的 handle，返回 null）
    await getUser('x');
    return null;
  }

  /// 旧的 REST 验证实现（保留备用）。
  ///
  /// 注意：该端点目前需要 `x-client-transaction-id`，缺失会 404。
  // ignore: unused_element
  Future<String?> _verifyByAccountSettings() async {
    final uri = Uri.https(
      _host,
      '/i/api/1.1/account/settings.json',
      {
        'include_profile_interstitial_type': '1',
        'include_blocking': '1',
        'skip_status': '1',
        'return_user': '1',
      },
    );
    final body = await _getJson(uri);
    return body['screen_name'] as String?;
  }

  /// 按 screen_name 加载用户信息。
  ///
  /// **与原版 X-Spider 2.2.2 保持一致：优先走 GraphQL `UserByScreenName`**
  /// （queryId 用原版验证过的值，过期时才自动抓新的）。
  /// GraphQL 不可用时才降级到 REST v1.1 `users/show.json`。
  Future<TwitterUser> getUser(String screenName) async {
    // ① GraphQL UserByScreenName（原版路径）
    try {
      final legacy = await _getUserByScreenNameGraphql(screenName);
      if (legacy != null) return legacy;
    } on XApiException catch (e) {
      // 401/403 = cookie 失效 / 未登录，直接上抛
      if (e.statusCode == 401 || e.statusCode == 403) rethrow;
      debugPrint(
          'XApi: UserByScreenName(GraphQL) 失败（${e.statusCode}），降级 REST');
    }

    // ② 降级：REST v1.1 users/show.json
    // 401/403 = cookie 失效 → 上抛；404 + code 50 = 用户不存在
    final v11 = await _getJsonV11('/i/api/1.1/users/show.json', {
      'screen_name': screenName,
      'include_entities': 'false',
      'skip_status': 'true',
    });
    if (v11 is Map<String, dynamic>) {
      final u = _userFromV11(v11);
      if (u != null) return u;
    }
    throw XApiException('找不到该用户：$screenName');
  }

  /// GraphQL UserByScreenName 的实现（原版 `getUser` 的对应物）。
  Future<TwitterUser?> _getUserByScreenNameGraphql(String screenName) async {
    final features = jsonEncode(_userFeatures);
    final variables = jsonEncode({
      'screen_name': screenName,
      'withSafetyModeUserFields': true,
    });
    final fieldToggles = jsonEncode({'withAuxiliaryUserLabels': false});

    final body = await _graphqlGet('UserByScreenName', {
      'features': features,
      'fieldToggles': fieldToggles,
      'variables': variables,
    });

    final legacy = _deepGet(body, ['data', 'user', 'result', 'legacy'])
        as Map<String, dynamic>?;
    if (legacy == null) {
      throw XApiException('找不到该用户：$screenName');
    }

    final restId = _deepGet(body, ['data', 'user', 'result', 'rest_id'])
        as String?;
    final avatarRaw = legacy['profile_image_url_https'] as String?;
    final avatar = avatarRaw?.replaceFirst('_normal', '_400x400');

    return TwitterUser(
      id: restId,
      name: legacy['name'] as String?,
      screenName: legacy['screen_name'] as String?,
      description: legacy['description'] as String?,
      avatar: avatar,
      mediaCount: _tryInt(legacy['media_count']),
      followersCount: _tryInt(legacy['followers_count']),
      friendsCount: _tryInt(legacy['friends_count']),
    );
  }

  /// 加载某个用户 ID 的媒体列表（分页）。
  ///
  /// GraphQL 端点 `UserMedia`。
  ///
  /// **注意：** 这部分 GraphQL 响应嵌套很深（timeline_v2 → instructions →
  /// entries → items → tweet_results → result → legacy → entities → media），
  /// X 的响应嵌套很深，逐层守卫比一次转到位更稳；改动这段前先用真实响应跑一遍对比。
  Future<MediaPage> getUserMedias(
    String userId, {
    String? cursor,
    int count = 20,
  }) async {
    final features = jsonEncode(_userMediaFeatures);
    final variables = jsonEncode({
      'userId': userId,
      'count': count,
      'cursor': cursor,
      'includePromotedContent': false,
      'withClientEventToken': false,
      'withBirdwatchNotes': false,
      'withVoice': true,
      'withV2Timeline': true,
    });

    try {
      final body = await _graphqlGet('UserMedia', {
        'features': features,
        'variables': variables,
      });

      final tweets = _parseUserMediaEntries(body);
      final nextCursor = _parseNextCursor(body);

      AppLogger.log(
        'XAPI',
        'UserMedia 解析：${tweets.length} 条媒体，nextCursor=${nextCursor != null}',
      );
      if (tweets.isEmpty) {
        // 诊断：把 instructions / entryType 分布记下来，便于定位结构变化
        final instructions = _deepGet(body, [
          'data',
          'user',
          'result',
          'timeline_v2',
          'timeline',
          'instructions',
        ]);
        if (instructions is List) {
          final types = instructions
              .whereType<Map<String, dynamic>>()
              .map((e) => e['type'])
              .toList();
          final entryTypes = <String>[];
          for (final ins in instructions.whereType<Map<String, dynamic>>()) {
            final entries = ins['entries'];
            if (entries is List) {
              for (final e in entries.whereType<Map<String, dynamic>>()) {
                final t = e['content']?['entryType'];
                if (t != null) entryTypes.add('$t');
              }
            }
          }
          AppLogger.log(
            'XAPI',
            'UserMedia 未解析出媒体！instructions=$types entryTypes=$entryTypes',
          );
        }
      }

      return MediaPage(
        tweets: tweets,
        nextCursor: nextCursor,
        hasMore: nextCursor != null,
      );
    } catch (e) {
      // GraphQL 不可用（queryId 抓不到 / 端点变更）时，降级到 REST v1.1。
      // 注意：REST 只能取最近约 3200 条推文；翻页时（cursor != null）不降级，
      // 否则会重复返回首页数据。
      if (cursor != null) rethrow;
      debugPrint('XApi: UserMedia(GraphQL) 失败：$e → 尝试 REST v1.1');
      final list = await _getJsonV11(
        '/i/api/1.1/statuses/user_timeline.json',
        {
          'user_id': userId,
          'count': '200',
          'tweet_mode': 'extended',
          'include_entities': 'true',
          'exclude_replies': 'true',
          'exclude_retweets': 'true',
        },
      );
      if (list is! List) rethrow;
      return MediaPage(
        tweets: _parseTimelineV11(list),
        nextCursor: null,
        hasMore: false,
      );
    }
  }

  /// REST v1.1 `statuses/user_timeline.json` 的解析（降级路径专用）。
  ///
  /// v1.1 的推文结构：`extended_entities.media[]`，
  /// 尺寸在 `sizes.{large,original}`，视频地址在 `video_info.variants`。
  List<Media> _parseTimelineV11(List<dynamic> tweets) {
    final media = <Media>[];
    for (final t in tweets) {
      if (t is! Map<String, dynamic>) continue;
      final tweetId = (t['id_str'] as String?) ?? t['id']?.toString();
      final fullText = (t['full_text'] as String?) ?? t['text'] as String?;
      final created = parseTwitterCreatedAt(t['created_at'] as String?);

      final raw = (t['extended_entities']?['media'] as List?) ??
          (t['entities']?['media'] as List?);
      if (raw == null) continue;

      // 发帖人 / 话题标签 —— 文件名模板的 %USER_*% 与 %TAGS% 要用
      final user = t['user'] as Map<String, dynamic>?;
      final userId = (user?['id_str'] as String?) ?? user?['id']?.toString();
      final userName = user?['name'] as String?;
      final userScreenName = user?['screen_name'] as String?;
      final tags = ((t['entities']?['hashtags'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((h) => h['text'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toList(growable: false);

      for (final (idx, m) in raw.indexed) {
        if (m is! Map<String, dynamic>) continue;
        final type = m['type'] as String?;
        final id = (m['id_str'] as String?) ?? m['id']?.toString();
        if (id == null) continue;

        final size = m['sizes']?['large'] ?? m['sizes']?['original'];
        final w = (size?['w'] as num?)?.toInt();
        final h = (size?['h'] as num?)?.toInt();
        final preview = m['media_url_https'] as String?;

        switch (type) {
          case 'photo':
            media.add(Media(
              id: id,
              type: MediaType.image,
              url: preview ?? '',
              previewUrl: preview,
              width: w,
              height: h,
              tweetId: tweetId,
              tweetText: fullText,
              createdAt: created,
              userId: userId,
              userName: userName,
              userScreenName: userScreenName,
              tags: tags,
              mediaIndex: idx + 1,
            ));
          case 'video':
          case 'animated_gif':
            final variants = (m['video_info']?['variants'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .where((v) => v['content_type'] == 'video/mp4')
                .toList()
              ?..sort((a, b) => ((b['bitrate'] as num?) ?? 0)
                  .compareTo((a['bitrate'] as num?) ?? 0));
            media.add(Media(
              id: id,
              type: type == 'video' ? MediaType.video : MediaType.animatedGif,
              url: variants?.firstOrNull?['url'] as String? ?? '',
              previewUrl: preview,
              width: w,
              height: h,
              tweetId: tweetId,
              tweetText: fullText,
              createdAt: created,
              userId: userId,
              userName: userName,
              userScreenName: userScreenName,
              tags: tags,
              mediaIndex: idx + 1,
            ));
        }
      }
    }
    return media;
  }

  // ── 内部：UserByScreenName features ─────────────────────────
  Map<String, dynamic> get _userFeatures => const {
        'hidden_profile_likes_enabled': true,
        'hidden_profile_subscriptions_enabled': true,
        'responsive_web_graphql_exclude_directive_enabled': true,
        'verified_phone_label_enabled': false,
        'subscriptions_verification_info_is_identity_verified_enabled': true,
        'subscriptions_verification_info_verified_since_enabled': true,
        'highlights_tweets_tab_ui_enabled': true,
        'responsive_web_twitter_article_notes_tab_enabled': false,
        'creator_subscriptions_tweet_preview_api_enabled': true,
        'responsive_web_graphql_skip_user_profile_image_extensions_enabled':
            false,
        'responsive_web_graphql_timeline_navigation_enabled': true,
      };

  // ── 内部：UserMedia features ────────────────────────────────
  Map<String, dynamic> get _userMediaFeatures => const {
        'responsive_web_graphql_exclude_directive_enabled': true,
        'verified_phone_label_enabled': false,
        'creator_subscriptions_tweet_preview_api_enabled': true,
        'responsive_web_graphql_timeline_navigation_enabled': true,
        'responsive_web_graphql_skip_user_profile_image_extensions_enabled':
            false,
        'c9s_tweet_anatomy_moderator_badge_enabled': true,
        'tweetypie_unmention_optimization_enabled': true,
        'responsive_web_edit_tweet_api_enabled': true,
        'graphql_is_translatable_rweb_tweet_is_translatable_enabled': true,
        'view_counts_everywhere_api_enabled': true,
        'longform_notetweets_consumption_enabled': true,
        'responsive_web_twitter_article_tweet_consumption_enabled': true,
        'tweet_awards_web_tipping_enabled': false,
        'freedom_of_speech_not_reach_fetch_enabled': true,
        'standardized_nudges_misinfo': true,
        'tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled':
            true,
        'rweb_video_timestamps_enabled': true,
        'longform_notetweets_rich_text_read_enabled': true,
        'longform_notetweets_inline_media_enabled': true,
        'responsive_web_media_download_video_enabled': false,
        'responsive_web_enhance_cards_enabled': false,
      };

  /// 解析 UserMedia 响应里所有推文的 media。
  ///
  /// 返回的每个 Media 都已经带 tweetId / tweetText / createdAt。
  List<Media> _parseUserMediaEntries(Map<String, dynamic> body) {
    final instructions = _deepGet(body, [
      'data',
      'user',
      'result',
      'timeline_v2',
      'timeline',
      'instructions',
    ]);
    if (instructions is! List) return const [];

    final tweets = <Map<String, dynamic>>[];

    // 从任意一层节点里取出 tweet result —— 兼容两种形态：
    //   ① module 里的 `item.itemContent.tweet_results.result`
    //   ② 直接 entry 的 `content.itemContent.tweet_results.result`
    void takeTweet(dynamic node) {
      if (node is! Map<String, dynamic>) return;
      var r = _deepGet(node, ['itemContent', 'tweet_results', 'result']);
      r ??= _deepGet(node, ['tweet_results', 'result']);
      if (r is! Map<String, dynamic>) return;
      final tweet = r['__typename'] == 'TweetWithVisibilityResults'
          ? r['tweet'] as Map<String, dynamic>?
          : r;
      if (tweet != null) tweets.add(tweet);
    }

    for (final ins in instructions) {
      if (ins is! Map<String, dynamic>) continue;
      final type = ins['type'];

      if (type == 'TimelineAddEntries') {
        final entries = ins['entries'];
        if (entries is! List) continue;
        for (final e in entries) {
          if (e is! Map<String, dynamic>) continue;
          final content = e['content'];
          if (content is! Map<String, dynamic>) continue;

          // **UserMedia 的媒体推文通常包在 TimelineTimelineModule 里**
          //（原版就是先找 module 再取 content.items），漏掉它会一条媒体都解析不出来。
          if (content['entryType'] == 'TimelineTimelineModule') {
            final items = content['items'];
            if (items is! List) continue;
            for (final it in items) {
              takeTweet(_deepGet(it, ['item']));
            }
          } else {
            takeTweet(content);
          }
        }
      } else if (type == 'TimelineAddToModule') {
        // 翻页时媒体会追加到 module
        final moduleItems = ins['moduleItems'];
        if (moduleItems is! List) continue;
        for (final it in moduleItems) {
          takeTweet(_deepGet(it, ['item']));
        }
      }
    }

    final media = <Media>[];
    for (final t in tweets) {
      final tweetId = t['rest_id'] as String?;
      final created =
          parseTwitterCreatedAt(t['legacy']?['created_at'] as String?);
      final fullText = t['legacy']?['full_text'] as String?;

      // 发帖人 / 话题标签 —— 与原版 api.ts 取值路径一致
      //   user.id        ← core.user_results.result.rest_id
      //   user.name      ← core.user_results.result.legacy.name
      //   tags           ← legacy.entities.hashtags[].text
      final userResult = _deepGet(t, ['core', 'user_results', 'result']);
      final userLegacy = userResult is Map<String, dynamic>
          ? userResult['legacy'] as Map<String, dynamic>?
          : null;
      final userId = (userResult is Map<String, dynamic>
              ? userResult['rest_id'] as String?
              : null) ??
          userLegacy?['id_str'] as String?;
      final userName = userLegacy?['name'] as String?;
      final userScreenName = userLegacy?['screen_name'] as String?;
      final tags = ((t['legacy']?['entities']?['hashtags'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((h) => h['text'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toList(growable: false);

      // extended_entities 里才带 video_info；没有时退回 entities
      final entities = t['legacy']?['extended_entities']?['media'] ??
          t['legacy']?['entities']?['media'];
      if (entities is! List) continue;

      for (final (idx, m) in entities.indexed) {
        if (m is! Map<String, dynamic>) continue;
        final type = m['type'] as String?;
        final id = m['id_str'] as String?;
        if (id == null) continue;

        switch (type) {
          case 'photo':
            media.add(Media(
              id: id,
              type: MediaType.image,
              url: m['media_url_https'] as String? ?? '',
              previewUrl: m['media_url_https'] as String?,
              width: (m['original_info']?['width'] as num?)?.toInt(),
              height: (m['original_info']?['height'] as num?)?.toInt(),
              tweetId: tweetId,
              tweetText: fullText,
              createdAt: created,
              userId: userId,
              userName: userName,
              userScreenName: userScreenName,
              tags: tags,
              mediaIndex: idx + 1,
            ));
          case 'video':
            final variants = (m['video_info']?['variants'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .where((v) => v['content_type'] == 'video/mp4')
                .toList()
              ?..sort((a, b) =>
                  ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
            final best = variants?.firstOrNull;
            media.add(Media(
              id: id,
              type: MediaType.video,
              url: best?['url'] as String? ?? '',
              previewUrl: m['media_url_https'] as String?,
              width: (m['original_info']?['width'] as num?)?.toInt(),
              height: (m['original_info']?['height'] as num?)?.toInt(),
              tweetId: tweetId,
              tweetText: fullText,
              createdAt: created,
              userId: userId,
              userName: userName,
              userScreenName: userScreenName,
              tags: tags,
              mediaIndex: idx + 1,
            ));
          case 'animated_gif':
            final variants = (m['video_info']?['variants'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .where((v) => v['content_type'] == 'video/mp4')
                .toList();
            final best = variants?.firstOrNull;
            media.add(Media(
              id: id,
              type: MediaType.animatedGif,
              url: best?['url'] as String? ?? '',
              previewUrl: m['media_url_https'] as String?,
              width: (m['original_info']?['width'] as num?)?.toInt(),
              height: (m['original_info']?['height'] as num?)?.toInt(),
              tweetId: tweetId,
              tweetText: fullText,
              createdAt: created,
              userId: userId,
              userName: userName,
              userScreenName: userScreenName,
              tags: tags,
              mediaIndex: idx + 1,
            ));
        }
      }
    }

    return media;
  }

  String? _parseNextCursor(Map<String, dynamic> body) {
    final instructions = _deepGet(body, [
      'data',
      'user',
      'result',
      'timeline_v2',
      'timeline',
      'instructions',
    ]);
    if (instructions is! List) return null;

    for (final ins in instructions) {
      if (ins is! Map<String, dynamic>) continue;
      if (ins['type'] != 'TimelineAddEntries') continue;
      final entries = ins['entries'];
      if (entries is! List) continue;
      for (final e in entries) {
        if (e is! Map<String, dynamic>) continue;
        if (e['content']?['entryType'] == 'TimelineTimelineCursor' &&
            e['content']?['cursorType'] == 'Bottom') {
          return e['content']?['value'] as String?;
        }
      }
    }
    return null;
  }
}

/// 让**所有** `dart:io` 的 HttpClient 走代理 —— 包括 `Image.network`。
///
/// **为什么必须要有它**：原版是 WebView 渲染，`<img src="https://pbs.twimg.com/…">`
/// 由 WebView2 自己加载，而 WebView2 默认就读 Windows 系统代理，所以图片能显示。
/// Flutter 的 `Image.network` / `NetworkImage` 内部用的是 **Dart 的全局 HttpClient**，
/// 既不读系统代理也不读环境变量 —— 不设这个，媒体缩略图和用户头像在需要代理的
/// 网络下会全部加载失败（表现为空白/破图标）。
///
/// 用法：`main()` 最开头 `HttpOverrides.global = ProxyHttpOverrides();`，
/// 之后改静态字段 `ProxyHttpOverrides.findProxy` 即可动态生效。
class ProxyHttpOverrides extends HttpOverrides {
  /// 形如 `PROXY 127.0.0.1:7897`；null / 空 = 直连
  static String? findProxy;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    final rule = findProxy;
    if (rule != null && rule.isNotEmpty) {
      client.findProxy = (uri) => rule;
      client.connectionTimeout = const Duration(seconds: 20);
    }
    return client;
  }
}

/// 把底层网络异常翻译成**可操作**的中文提示；非网络类异常返回 null。
///
/// 典型场景：国内直连 x.com 时 Dart 会抛
/// `HandshakeException: Connection terminated during handshake` ——
/// 用户看不懂，但真正要做的只有一件事：去「设置 → 代理」配置代理。
String? friendlyNetworkError(Object error) {
  final s = error.toString();
  if (s.contains('HandshakeException') ||
      s.contains('Connection terminated') ||
      s.contains('CERTIFICATE') ||
      s.contains('WRONG_VERSION_NUMBER')) {
    return '无法连接 X：TLS 握手被中断（网络被阻断）→ 请到「设置 → 代理」配置代理后重试';
  }
  if (s.contains('SocketException') ||
      s.contains('Failed host lookup') ||
      s.contains('Network is unreachable') ||
      s.contains('Connection refused')) {
    return '无法连接 X：网络不可达 → 请到「设置 → 代理」配置代理后重试';
  }
  if (s.contains('TimeoutException') || s.contains('超时')) {
    return '连接 X 超时 → 请检查网络，或在「设置 → 代理」更换代理';
  }
  return null;
}

/// 一页媒体结果。
class MediaPage {
  final List<Media> tweets;
  final String? nextCursor;
  final bool hasMore;

  const MediaPage({
    required this.tweets,
    required this.nextCursor,
    required this.hasMore,
  });
}

/// 连续几页解析不出任何媒体就认定已经翻到底。
///
/// 留 1 页的余量是给 X 偶发的可见性过滤；实测末尾之后是**每一页都空**
/// （2026-09-18 线上从某页起连续 87 次「0 条媒体」）。
const int kEmptyPageStopAfter = 2;

/// 读完这一页之后还要不要继续翻。
///
/// **为什么要在这里兜底**：X 翻到时间线末尾时，返回的那一页里一条媒体都没有
/// （`TimelineAddEntries` 的 entries 只剩 Top/Bottom 两个游标），可 `hasMore`
/// 与游标照样给。翻页循环只认 `nextCursor == null` 收尾的话就永远停不下来：
/// 任务一直挂在「创建中」，串行队列后面的用户全被堵住，下载管理页表现为
/// 角标有数字而列表是空的。
///
/// 两条停止条件都留着，因为实测两条各覆盖一种情况：
///  - 游标与本次请求携带的完全相同 → 服务端在原地打转；
///  - 连续 [kEmptyPageStopAfter] 页 0 条媒体 → 已经到底
///    （游标**每页都在变**，光靠上一条拦不住，2026-09-18 就是这么漏的）。
///
/// [emptyPagesBefore] 传"这一页之前已连续空了几页"。
///
/// 抽成纯函数是为了能单测 —— 走到这里需要真实登录态与网络。
bool mediaPageHasMore({
  required String? requestedCursor,
  required MediaPage page,
  int emptyPagesBefore = 0,
}) {
  if (!page.hasMore) return false;
  final next = page.nextCursor;
  if (next == null || next.isEmpty) return false;
  if (next == requestedCursor) return false;
  if (page.tweets.isEmpty && emptyPagesBefore + 1 >= kEmptyPageStopAfter) {
    return false;
  }
  return true;
}

class XApiException implements Exception {
  final String message;
  final int? statusCode;

  XApiException(this.message, {this.statusCode});

  @override
  String toString() => 'XApiException($statusCode): $message';
}

// ── 小工具 ─────────────────────────────────────────────────────

dynamic _deepGet(dynamic obj, List<String> path) {
  dynamic cur = obj;
  for (final key in path) {
    if (cur is Map) {
      cur = cur[key];
    } else {
      return null;
    }
  }
  return cur;
}

int? _tryInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is String) return int.tryParse(v);
  return null;
}

