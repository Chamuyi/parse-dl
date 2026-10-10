import 'package:http/http.dart' as http;

import '../models/bili_meta.dart';
import '../models/media.dart';

/// 用户粘进 B 站页的那一行文本 → 「这是哪一条稿件」。
///
/// 单独一层的原因：这一层要吃的输入是**人手贴的**，形状比接口返回野得多
/// （裸 BV 号、`av` 号、整条带 query 的长链、`b23.tv` 短链、甚至番剧页）。
/// 把它和接口层分开，接口层就只管「给我一个 bvid/aid」，两边都能单测。
class BiliRef {
  const BiliRef._({
    this.bvid,
    this.aid,
    this.partIndex,
    this.shortLink,
    this.unsupportedReason,
  });

  /// BV 号（`/video/BV…` 那一支）
  final String? bvid;

  /// av 号（`av…`，**不含**前缀）
  final int? aid;

  /// 分 P 号（URL 里的 `?p=`，1 起）。没写就是 null = 由调用方决定默认。
  final int? partIndex;

  /// 需要先跟随重定向才能知道指向哪儿（`b23.tv/xxx` 这类短链）。
  final String? shortLink;

  /// 认得出来但**本期不做**（如番剧页）—— 界面要如实说，不能当成普通稿件去解析。
  final String? unsupportedReason;

  bool get needsExpand => shortLink != null;
  bool get isUnsupported => unsupportedReason != null;

  @override
  String toString() => 'BiliRef(bvid: $bvid, aid: $aid, p: $partIndex, '
      'short: $shortLink, unsupported: $unsupportedReason)';
}

/// BV 号：`BV` + 10 位 base58（不含 `0`/`O`/`I`/`l`）。
final _bvidRe = RegExp(r'BV[1-9A-HJ-NP-Za-km-z]{10}');

/// av 号：`av` + 数字（大小写都收）。
final _avRe = RegExp(r'^av(\d+)$', caseSensitive: false);

/// 用户经常从别处复制成小写 `bv1xx…`，B 站的号本身区分大小写但**前缀**不区分。
final _lowerBvRe = RegExp(r'^bv([1-9A-HJ-NP-Za-km-z]{10})$');

/// 短链域名。只认这一个：别自己拼重定向地址。
const String kBiliShortHost = 'b23.tv';

/// 解析一行输入。认不出来返回 null（界面据此提示「这不是 B 站链接」）。
BiliRef? parseBiliRef(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  // ① 裸 BV / 裸 av
  if (_bvidRe.hasMatch(text) && RegExp(r'^BV').hasMatch(text)) {
    return BiliRef._(bvid: text);
  }
  final lower = _lowerBvRe.firstMatch(text);
  if (lower != null) {
    // 归一化成规范的大写前缀，后面拼路径、进台账键都只有一种写法
    return BiliRef._(bvid: 'BV${lower.group(1)}');
  }
  final av = _avRe.firstMatch(text);
  if (av != null) {
    return BiliRef._(aid: int.tryParse(av.group(1)!));
  }

  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || !uri.host.contains('bilibili')) {
    // b23.tv 的主机名里没有 bilibili，得单独判
    if (uri != null && uri.host == kBiliShortHost) {
      return BiliRef._(shortLink: text);
    }
    return null;
  }

  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return null;

  // ② /video/BV… 或 /video/av…（还可能是 /video/BV…?p=3）
  if (segs[0] == 'video') {
    final p = int.tryParse(uri.queryParameters['p'] ?? '');
    if (segs.length >= 2) {
      final tail = segs[1];
      if (_bvidRe.hasMatch(tail) && tail.startsWith('BV')) {
        return BiliRef._(bvid: tail, partIndex: p);
      }
      final m = _lowerBvRe.firstMatch(tail);
      if (m != null) {
        return BiliRef._(bvid: 'BV${m.group(1)}', partIndex: p);
      }
      final a = _avRe.firstMatch(tail);
      if (a != null) {
        return BiliRef._(aid: int.tryParse(a.group(1)!), partIndex: p);
      }
    }
    return null;
  }

  // ③ 认得出来但本期不做的形态 —— 明确报出来，别让它掉进「普通稿件」这条路。
  // 域名与路径段都要看：`space.bilibili.com/xxx` 的 `space` 在**主机名**里，
  // 而 `/bangumi/play/ep…` 的 `bangumi` 在路径里，只看一处会漏。
  const unsupported = {
    'bangumi': '番剧 / 影视这一支本期不做（计划书里排在 P3）',
    'media': '影视这一支本期不做（计划书里排在 P3）',
    'medialist': '合集列表本期不做（计划书里排在 P2）',
    'list': '合集列表本期不做（计划书里排在 P2）',
    'read': '专栏文章没有可下载的视频流',
    'opus': '动态正文没有可下载的视频流',
    'article': '专栏文章没有可下载的视频流',
    'space': 'UP 主空间批量本期不做（计划书里排在 P2）',
    'live': '直播间不支持',
    'vc': '课堂本期不做（计划书里排在 P3）',
    'show': '会员购演出本期不做（计划书里排在 P3）',
  };
  final labels = <String>[...uri.host.split('.'), ...segs];
  final hit = unsupported.entries.where((e) => labels.contains(e.key)).toList();
  if (hit.isNotEmpty) {
    return BiliRef._(unsupportedReason: hit.first.value);
  }

  // ④ 路径里随便哪儿冒出一个 BV 号（如 ?uri=… 之类转发页），照收
  final anywhere = _bvidRe.firstMatch(uri.toString());
  if (anywhere != null) {
    return BiliRef._(
        bvid: anywhere.group(0),
        partIndex: int.tryParse(uri.queryParameters['p'] ?? ''));
  }
  return null;
}

/// 跟随 `b23.tv` 短链的重定向，拿到最终地址再解析。
///
/// **故意不跟自动重定向**：`http` 的客户端默认会一路跟到底，而 B 站的跳转链上
/// 有一跳会把 `p=` 丢掉。这里只取**第一跳的 Location**，取不到才退回最终地址，
/// 这样 `?p=3` 这种分 P 信息能留住。
Future<BiliRef?> expandBiliShortLink(String shortUrl,
    {http.Client? client, Duration timeout = const Duration(seconds: 10)}) async {
  final c = client ?? http.Client();
  // package:http 1.6 的 `head` / `get` 收的是 `Uri`，不是字符串。
  final target = Uri.parse(shortUrl);
  try {
    final resp = await c.head(target, headers: const {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    }).timeout(timeout);
    final location = resp.headers['location'];
    if (location != null && location.isNotEmpty) {
      final direct = parseBiliRef(location);
      if (direct != null && !direct.needsExpand) return direct;
    }
    // 没有 302（有些短链直接 200 出 HTML）→ 退到 GET 拿最终 URL
    final get = await c.get(target, headers: const {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    }).timeout(timeout);
    final req = get.request;
    if (req != null) {
      final byFinal = parseBiliRef(req.toString());
      if (byFinal != null) return byFinal;
    }
    // 最后一搏：从 HTML 里抠 BV 号（短链页常把目标写进 `<meta>` 或跳转脚本）
    final inBody = _bvidRe.firstMatch(get.body);
    return inBody == null ? null : BiliRef._(bvid: inBody.group(0));
  } finally {
    if (client == null) c.close();
  }
}

/// 一条分 P → 界面上那一行的 [Media]。
///
/// **这里刻意不带任何下载地址**：`playurl` 要按 `cid` 一条一条问，而且画质
/// 上限是「按设置选源」那一刻的事。列表先只放展示信息（标题 / 封面 / 时长 /
/// BV / cid / 分 P 号），入队时再由调用方补 `chosen` 与 `url`。
/// 地址留空不是疏忽 —— 它同时也是「这条还没解析过取流地址」的标记。
Media biliPartMedia({
  required String bvid,
  required int aid,
  required String workTitle,
  required String upperName,
  required int upperMid,
  required DateTime? publishTime,
  required String cover,
  required int partTotal,
  required int partIndex,
  required int cid,
  required String partTitle,
  required int durationMs,
}) {
  return Media(
    id: '$bvid-$partIndex',
    type: MediaType.video,
    url: '',
    previewUrl: cover,
    tweetId: bvid,
    tweetText: workTitle,
    createdAt: publishTime,
    userId: upperMid.toString(),
    userName: upperName,
    mediaIndex: partIndex,
    source: 'bili',
    durationMs: durationMs,
    bili: BiliMeta(
      workTitle: workTitle,
      partTitle: partTitle,
      bvid: bvid,
      aid: aid.toString(),
      cid: cid.toString(),
      partTotal: partTotal,
    ),
  );
}
