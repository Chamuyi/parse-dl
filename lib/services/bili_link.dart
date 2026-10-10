import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/bili_meta.dart';
import '../models/media.dart';

/// 用户粘进 B 站页的那一行文本 → 「这是哪一条稿件 / 哪一个列表」。
///
/// 单独一层的原因：这一层要吃的输入是**人手贴的**，形状比接口返回野得多
/// （裸 BV 号、`av` 号、整条带 query 的长链、`b23.tv` 短链、甚至番剧页）。
/// 把它和接口层分开，接口层就只管「给我一个 bvid/aid / 给我一个列表 id」，
/// 两边都能单测。
///
/// 列表类链接（主页投稿 / 合集 / 系列 / 收藏夹）在本层只做到**认出形状、
/// 抽出身份参数**；需要发请求才能定身份的那一种（`/list/{mid}?sid=…`，
/// sid 既可能是合集也可能是系列）由 [resolveBiliListTarget] 处理，
/// 它只收两个注入的回调，所以本文件依旧不依赖接口层。
class BiliRef {
  const BiliRef._({
    this.bvid,
    this.aid,
    this.partIndex,
    this.shortLink,
    this.unsupportedReason,
    this.list,
    this.problem,
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
  ///
  /// [problem] 那种「列表链接给不出身份」的情况，这里放的是 [BiliLinkProblem.code]
  /// （一个稳定 ASCII 串，不是文案）：本层的纪律是不新增用户可见中文字面量，
  /// 界面按 code 接自己的文案。历史那几行（番剧 / 专栏…）仍是中文原文案，
  /// 等 l10n 那批改动合完再统一收口。
  final String? unsupportedReason;

  /// 列表类链接解析出来的目标（普通稿件链接为 null）。
  final BiliListTarget? list;

  /// 认得是列表链接、但链接里没有任何可用的列表身份。
  final BiliLinkProblem? problem;

  bool get needsExpand => shortLink != null;

  /// 「这条不能当普通稿件解析」的总判据。页面据此走提示分支。
  bool get isUnsupported => unsupportedReason != null || problem != null;

  /// 是列表类链接（投稿列表 / 合集 / 系列 / 收藏夹）。
  bool get isList => list != null;

  @override
  String toString() => 'BiliRef(bvid: $bvid, aid: $aid, p: $partIndex, '
      'short: $shortLink, unsupported: $unsupportedReason, '
      'list: $list, problem: ${problem?.code})';
}

/// 列表类链接指向哪一种列表。
enum BiliListKind {
  /// UP 主主页投稿 —— `/x/space/wbi/arc/search`
  space,

  /// 合集 —— `/x/polymer/web-space/seasons_archives_list`
  season,

  /// 系列 —— `/x/series/archives`
  series,

  /// 收藏夹 —— `/x/v3/fav/resource/list`
  fav,

  /// 身份未定：链接给了 `sid`，但 `sid` 既可能是合集也可能是系列，
  /// 只给视频时连 `sid` 都没有。要 [resolveBiliListTarget] 发请求才判得出来。
  unknown,
}

/// 「列表链接认得出来，但给不出列表身份」。
///
/// 刻意是**结构化枚举**而不是中文句子：文案由界面层接（本层不许新增用户可见
/// 中文字面量），而 `code` 是稳定的 ASCII 串，可以直接进日志与测试断言。
enum BiliLinkProblem {
  /// 列表链接里既没有列表 id、也没有视频 —— 无从判定是哪一个列表。
  noListIdentity('bili-list-no-identity'),

  /// 收藏夹链接的 `fid` 拿不出数字 —— 没写 `fid`，或写的是 `fid=view_later`
  /// 这种「稍后再看」（本期不做）。
  favIdUnresolved('bili-fav-id-not-numeric');

  const BiliLinkProblem(this.code);

  /// 稳定标识（进日志 / 异常文本 / 界面按它取文案）。
  final String code;
}

/// 列表类链接的可执行目标。
///
/// **互斥是构造时卡的**：`kind` 说它是哪一支，另一支的 id 字段就不许带值 ——
/// 带着 `seasonId` 的系列目标去调合集接口，用户看到的是「系列的内容为什么来自
/// 合集」这种无从归因的现场，而接口本身不会报错（两个 id 都可能是合法数字）。
class BiliListTarget {
  BiliListTarget({
    required this.kind,
    this.mid,
    this.seasonId,
    this.seriesId,
    this.favId,
    this.sid,
    this.keyword = '',
    this.currentBvid = '',
    this.currentAid,
    this.seriesMeta,
  }) {
    switch (kind) {
      case BiliListKind.space:
        _forbid('space', season: true, series: true, fav: true);
      case BiliListKind.season:
        _forbid('season', series: true, fav: true);
      case BiliListKind.series:
        _forbid('series', season: true, fav: true);
      case BiliListKind.fav:
        _forbid('fav', season: true, series: true);
      case BiliListKind.unknown:
        // 未定身份只许带 sid；带上任何一支的 id 就说明上游已经判过了
        _forbid('unknown', season: true, series: true, fav: true);
    }
  }

  void _forbid(
    String as, {
    bool season = false,
    bool series = false,
    bool fav = false,
  }) {
    final bad = (season && seasonId != null) ||
        (series && seriesId != null) ||
        (fav && favId != null);
    if (bad) {
      throw ArgumentError.value(kind.name, 'kind', 'bili-list-target-conflict:$as');
    }
  }

  final BiliListKind kind;

  /// UP 主的 mid。**来自链接路径**，[resolveBiliListTarget] 命中合集/系列时会
  /// 换成接口给的 mid（视频实际属于谁，接口比链接可靠）。
  final int? mid;

  final int? seasonId;
  final int? seriesId;

  /// 收藏夹的 `media_id`（链接里的 `fid` / `ml…`）
  final int? favId;

  /// 只在 [BiliListKind.unknown] 上有值：链接给的 `sid`，待判身份
  final int? sid;

  /// 链接里的 `?keyword=`，要原样带进列表请求（搜索/筛选在后面用）
  final String keyword;

  /// 链接指向列表里的**某一条**视频时记下来（界面据此定位并勾选）；`''` = 没有
  final String currentBvid;

  /// 同上，但链接只给了 `oid`（aid）没给 bvid
  final int? currentAid;

  /// 系列探针顺带拿到的 `meta`（原样带出，交给 `seriesArcs(meta: …)` 复用，省一次请求）。
  ///
  /// 这里刻意是裸 `Map` 而不是新模型：本层不 import 接口层（接口层反过来 import
  /// 本文件），造个模型就得在这两层之间搬字段，白多一份转换。接口层的
  /// `BiliSeriesMeta.fromJson` 负责把它变成有类型的东西。
  final Map<String, dynamic>? seriesMeta;

  /// 该支列表的 id（主页投稿没有 id）
  int? get listId => switch (kind) {
        BiliListKind.season => seasonId,
        BiliListKind.series => seriesId,
        BiliListKind.fav => favId,
        BiliListKind.space => null,
        BiliListKind.unknown => sid,
      };

  bool get needsResolve => kind == BiliListKind.unknown;

  bool get hasVideo => currentBvid.isNotEmpty || currentAid != null;

  BiliListTarget copyWith({
    BiliListKind? kind,
    int? mid,
    int? seasonId,
    int? seriesId,
    int? favId,
    int? sid,
    String? keyword,
    String? currentBvid,
    int? currentAid,
    Map<String, dynamic>? seriesMeta,
  }) =>
      BiliListTarget(
        kind: kind ?? this.kind,
        mid: mid ?? this.mid,
        seasonId: seasonId ?? this.seasonId,
        seriesId: seriesId ?? this.seriesId,
        favId: favId ?? this.favId,
        sid: sid ?? this.sid,
        keyword: keyword ?? this.keyword,
        currentBvid: currentBvid ?? this.currentBvid,
        currentAid: currentAid ?? this.currentAid,
        seriesMeta: seriesMeta ?? this.seriesMeta,
      );

  @override
  String toString() => 'BiliListTarget(${kind.name}, mid: $mid, '
      'season: $seasonId, series: $seriesId, fav: $favId, sid: $sid, '
      'keyword: $keyword, bvid: $currentBvid, aid: $currentAid, '
      'meta: ${seriesMeta == null ? 'none' : 'reused'})';
}

/// BV 号：`BV` + 10 位 base58（不含 `0`/`O`/`I`/`l`）。
final _bvidRe = RegExp(r'BV[1-9A-HJ-NP-Za-km-z]{10}');

/// av 号：`av` + 数字（大小写都收）。
final _avRe = RegExp(r'^av(\d+)$', caseSensitive: false);

/// 用户经常从别处复制成小写 `bv1xx…`，B 站的号本身区分大小写但**前缀**不区分。
final _lowerBvRe = RegExp(r'^bv([1-9A-HJ-NP-Za-km-z]{10})$');

/// 短链域名。只认这一个：别自己拼重定向地址。
const String kBiliShortHost = 'b23.tv';

/// 直接贴的收藏夹 media_id（没有任何前缀与协议，纯数字）。
final _digitsRe = RegExp(r'^\d+$');

/// 收藏夹 id 的另一种写法：`/medialist/detail/ml1234567890`。
final _mlRe = RegExp(r'^ml(\d+)$', caseSensitive: false);

/// `?bvid=` 参数上的 BV 号。前缀大小写都收（参照实现的 `bvid=([Bb][Vv]…)`），
/// 正文按 base58 字母表校验，并把正文捕获出来统一拼回 `BV` 开头。
final _bvidParamRe = RegExp(r'^[Bb][Vv]([1-9A-HJ-NP-Za-km-z]{10})$');

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
  // 裸数字 = 收藏夹的 media_id（D8 说的「贴链接直抓」也接受直接贴 id）。
  // `av123` 上面那条分支已经吃掉，而稿件从来没有「裸数字」这种写法，
  // 所以这一支不会把稿件 id 误认成收藏夹 id。
  if (_digitsRe.hasMatch(text)) {
    final id = int.tryParse(text);
    if (id != null && id > 0) {
      return BiliRef._(
        list: BiliListTarget(kind: BiliListKind.fav, favId: id),
      );
    }
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

  // ③ 列表类链接。必须排在「本期不做表」之前：`space` / `list` / `medialist`
  // 三行已从那张表里摘掉，它们现在是能用的形态。
  final listRef = _parseListRef(uri, segs);
  if (listRef != null) return listRef;

  // ④ 认得出来但本期不做的形态 —— 明确报出来，别让它掉进「普通稿件」这条路。
  // 域名与路径段都要看：`/bangumi/play/ep…` 的 `bangumi` 在路径里，
  // `live.bilibili.com` 的 `live` 在**主机名**里，只看一处会漏。
  const unsupported = {
    'bangumi': '番剧 / 影视这一支本期不做（计划书里排在 P3）',
    'media': '影视这一支本期不做（计划书里排在 P3）',
    'read': '专栏文章没有可下载的视频流',
    'opus': '动态正文没有可下载的视频流',
    'article': '专栏文章没有可下载的视频流',
    'live': '直播间不支持',
    'vc': '课堂本期不做（计划书里排在 P3）',
    'show': '会员购演出本期不做（计划书里排在 P3）',
  };
  final labels = <String>[...uri.host.split('.'), ...segs];
  final hit = unsupported.entries.where((e) => labels.contains(e.key)).toList();
  if (hit.isNotEmpty) {
    return BiliRef._(unsupportedReason: hit.first.value);
  }

  // ⑤ 路径里随便哪儿冒出一个 BV 号（如 ?uri=… 之类转发页），照收
  final anywhere = _bvidRe.firstMatch(uri.toString());
  if (anywhere != null) {
    return BiliRef._(
        bvid: anywhere.group(0),
        partIndex: int.tryParse(uri.queryParameters['p'] ?? ''));
  }
  return null;
}

/// 列表类链接 → 目标。**纯函数**，不发请求：身份待判的那种给出
/// [BiliListKind.unknown]，由 [resolveBiliListTarget] 接着办。
///
/// `mid` / `sid` / `favId` 一律只从**路径段与指定的 query 参数**里取，
/// 不在整条链接上搜数字 —— 播放页链接的查询串里带着 `oid=` 这类长数字、
/// 收藏夹链接带着 `number=`（稍后再看定位用）与 `keyword=`，
/// 拿整条链接搜数字会抓到它们，然后把错误的 id 发给接口（实测过错一次）。
BiliRef? _parseListRef(Uri uri, List<String> segs) {
  final host = uri.host.toLowerCase();
  final q = uri.queryParameters;
  final keyword = (q['keyword'] ?? '').trim();
  final type = (q['type'] ?? '').trim().toLowerCase();
  final video = _linkVideo(q);
  final hasVideo = video.$1.isNotEmpty || video.$2 != null;

  /// 公共尾巴：把「链接指向列表里某一条视频」与 keyword 挂到目标上
  BiliListTarget withVideo(BiliListTarget t) => t.copyWith(
        keyword: keyword,
        currentBvid: video.$1,
        currentAid: video.$2,
      );

  // ── space.bilibili.com/{mid}[/…] ──
  if (host.startsWith('space.')) {
    final mid = _asInt(segs.first);
    if (mid == null) {
      // `space.bilibili.com/dynamic` 之类的一级页：不是某个 UP 的空间，认不出来
      return null;
    }
    if (segs.length >= 3 && segs[1] == 'lists') {
      final id = _asInt(segs[2]);
      if (id == null) return null;
      return BiliRef._(list: withVideo(_typedList(type, mid, id)));
    }
    if (segs.length >= 2 &&
        const {'favlist', 'favorite', 'fav'}.contains(segs[1])) {
      final fid = _asInt(q['fid']);
      if (fid == null) {
        // 带 `fid=view_later` 的「稍后再看」，以及根本没给 fid 的收藏夹页：
        // 链接里拿不到 media_id。「列出这个 UP 的自建收藏夹」是
        // `BiliListApi.createdFolders` 的活，由页面决定要不要接着问。
        return BiliRef._(
          problem: BiliLinkProblem.favIdUnresolved,
          unsupportedReason: BiliLinkProblem.favIdUnresolved.code,
        );
      }
      return BiliRef._(list: withVideo(BiliListTarget(
        kind: BiliListKind.fav,
        mid: mid,
        favId: fid,
      )));
    }
    return BiliRef._(list: withVideo(BiliListTarget(
      kind: BiliListKind.space,
      mid: mid,
    )));
  }

  // ── www.bilibili.com/list/{mid}?sid=…&oid=…&bvid=… ──
  //    以及收藏夹的播放页形态 www.bilibili.com/list/ml1234567890
  if (segs.first == 'list') {
    if (segs.length < 2) return _noIdentity();
    final ml = _mlRe.firstMatch(segs[1]);
    if (ml != null) {
      return BiliRef._(list: withVideo(BiliListTarget(
        kind: BiliListKind.fav,
        favId: int.tryParse(ml.group(1)!),
      )));
    }
    final mid = _asInt(segs[1]);
    final sid = _asInt(q['sid']);
    if (mid == null) return _noIdentity(); // `list/user,aid_1,1` 这类抄坏的链接
    if (sid != null) {
      // 有 sid 但没写 type：身份待判（合集 or 系列），交给 resolveBiliListTarget
      return BiliRef._(list: withVideo(_typedList(type, mid, sid)));
    }
    // 只给了路径里的 mid，没给 sid：链接里唯一的列表线索就是那条视频。
    // 带着视频还能靠 `view` 反查它所属的合集；连视频都没有就无从判定。
    if (!hasVideo) return _noIdentity();
    return BiliRef._(list: withVideo(BiliListTarget(
      kind: BiliListKind.unknown,
      mid: mid,
    )));
  }

  // ── www.bilibili.com/medialist/detail/ml1234567890 ──
  if (segs.first == 'medialist') {
    final id = segs
        .map((s) => _mlRe.firstMatch(s)?.group(1))
        .firstWhere((s) => s != null, orElse: () => null);
    final fid = id == null ? _asInt(q['fid']) : int.tryParse(id);
    if (fid == null) return _noIdentity();
    return BiliRef._(list: withVideo(BiliListTarget(
      kind: BiliListKind.fav,
      mid: _asInt(q['share_uid']),
      favId: fid,
    )));
  }

  return null;
}

/// 链接里指向「列表中的某一条视频」的参数：`bvid=` 优先，其次 `oid=`（就是 aid）。
///
/// 只在**这两个参数**上取，不在整条链接上搜 BV 号 —— `/list/` 播放页链接里
/// `bvid=` 自己就含 `bv`，拿整条串搜会先命中它、取回一个 `"bvid"`。
/// 前缀大小写都收（有人从别处复制成 `bvid=bv1S4…`），归一化成 `BV` 开头。
(String, int?) _linkVideo(Map<String, String> q) {
  final bv = (q['bvid'] ?? '').trim();
  final m = _bvidParamRe.firstMatch(bv);
  if (m != null) return ('BV${m.group(1)}', null);
  return ('', _asInt(q['oid']));
}

/// `?type=season|series` 说清楚了就是它说的；没写或写了别的 → 身份待判。
BiliListTarget _typedList(String type, int? mid, int id) => switch (type) {
      'season' => BiliListTarget(
          kind: BiliListKind.season, mid: mid, seasonId: id),
      'series' => BiliListTarget(
          kind: BiliListKind.series, mid: mid, seriesId: id),
      _ => BiliListTarget(kind: BiliListKind.unknown, mid: mid, sid: id),
    };

BiliRef _noIdentity() => BiliRef._(
      problem: BiliLinkProblem.noListIdentity,
      unsupportedReason: BiliLinkProblem.noListIdentity.code,
    );

/// 列表身份未定时要用的两件外部能力。**由调用方注入**：生产上是接口层
/// （`bili_list_api.dart` 的 `BiliListApi.resolveTarget`），测试给假实现。
///
/// 两个回调都返回接口的 `data`（拿不到就返回 null），本层只从中读
/// `ugc_season.id/mid` 与系列的 `meta`，不认任何接口细节。
typedef BiliViewFetcher = Future<Map<String, dynamic>?> Function({
  String? bvid,
  int? aid,
});

/// 系列探针：`series_id` 是系列 → 返回它的 `meta`；不是 → 返回 null。
typedef BiliSeriesProbe = Future<Map<String, dynamic>?> Function(int seriesId);

/// 把 [BiliListKind.unknown] 判成确定的合集 / 系列。
///
/// 判定链路（照参照实现 `parser/list.py:81-141` 的思路，顺序**不许自己发明**）：
///  1. 链接带视频 → 先 `view` 反查 `data.ugc_season`。它的 `id` 与链接的 `sid`
///     一致（或链接根本没给 `sid`）就按**合集**解析；`mid` 与 `season_id`
///     **一律用接口给的**，不用链接路径里那个数字（视频实际属于哪个合集，
///     接口比链接可靠）。
///  2. 否则（没有视频 / ugc_season 对不上）用 `sid` **先探系列**：
///     系列接口对非系列 id 干净回非 0（实测 147002），而合集接口对不存在的 id
///     直接 -404、拿它当探针要捕获异常 —— 所以先探前者。探针顺手拿到的 `meta`
///     挂在返回目标上，`seriesArcs` 直接复用，省一次请求。
///  3. 既没 `sid` 也没视频 → 抛 [ArgumentError]（纯解析阶段已经拦下这种情况，
///     走到这里说明调用方构造错了目标）。
///
/// 已经判明身份的（`kind != unknown`，即链接写了 `type=season|series`）
/// **原样返回、一个请求都不发** —— 链接明说是系列就绝不会再去看合集接口，
/// 反过来也一样。
Future<BiliListTarget> resolveBiliListTarget(
  BiliListTarget target, {
  required BiliViewFetcher view,
  required BiliSeriesProbe seriesProbe,
}) async {
  if (!target.needsResolve) return target;

  final sid = target.sid;

  Map<String, dynamic>? video;
  if (target.hasVideo) {
    video = await view(
      bvid: target.currentBvid.isEmpty ? null : target.currentBvid,
      aid: target.currentAid,
    );
  }
  final season = _asMap(video?['ugc_season']);
  final seasonId = _asInt(season?['id']);
  if (season != null && seasonId != null && (sid == null || seasonId == sid)) {
    return BiliListTarget(
      kind: BiliListKind.season,
      // 接口给的 mid 优先，链接路径里那个只是兜底
      mid: _asInt(season['mid']) ?? target.mid,
      seasonId: seasonId,
      keyword: target.keyword,
      currentBvid: target.currentBvid,
      currentAid: target.currentAid,
    );
  }

  if (sid != null) {
    final meta = await seriesProbe(sid);
    if (meta != null) {
      return BiliListTarget(
        kind: BiliListKind.series,
        mid: _asInt(meta['mid']) ?? target.mid,
        seriesId: sid,
        keyword: target.keyword,
        currentBvid: target.currentBvid,
        currentAid: target.currentAid,
        seriesMeta: meta,
      );
    }
    return BiliListTarget(
      kind: BiliListKind.season,
      mid: target.mid,
      seasonId: sid,
      keyword: target.keyword,
      currentBvid: target.currentBvid,
      currentAid: target.currentAid,
    );
  }

  throw ArgumentError.value(target, 'target', 'bili-list-target-no-identity');
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

Map<String, dynamic>? _asMap(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : null;

/// 跟随 `b23.tv` 短链的重定向，拿到最终地址再解析。
///
/// **先看第一跳的 `Location`，拿不到才退到 GET**：短链的目标地址本身就带着
/// `?p=` 这类分 P 参数，一路跟到底反而要经过中间页，参数可能被改写。
/// 退路有两条：GET 拿最终请求的 URL；再不行从 HTML 正文里抠 BV 号
/// （有些短链是 200 + 一段跳转脚本，压根不发 302）。
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
      // 结果仍然是个短链就等于什么都没进展 —— 返回它会让调用方原地打转，
      // 所以这里只认「已经落到能解析的形状」的那一种。
      if (byFinal != null && !byFinal.needsExpand) return byFinal;
    }
    // 最后一搏：从 HTML 里抠 BV 号（短链页常把目标写进 `<meta>` 或跳转脚本）
    // 用 bodyBytes 自己按 UTF-8 解，而不是 `get.body` —— 后者按响应头的
    // `content-type` 猜编码，短链页常常**不带** charset，猜不出来就退回 latin1，
    // 中文正文会直接解坏（本文件的测试就是被这个炸出来的）。
    final html = utf8.decode(get.bodyBytes, allowMalformed: true);
    final inBody = _bvidRe.firstMatch(html);
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
