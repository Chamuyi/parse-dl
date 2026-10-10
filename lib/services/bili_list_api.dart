/// B 站「列表类」接口层：UP 主投稿 / 合集 / 系列 / 收藏夹。
///
/// 与 `bili_api.dart` 的分工：那一份只管**单条稿件**（`view` / `playurl` /
/// 登录），这一层管**一批稿件从哪儿列出来**。它只经 [BiliApi.getData] 与
/// [BiliApi.getSignedData] 两个口发请求，**不再往 `bili_api.dart` 里加方法**。
///
/// 三条实测事实决定了本文件的形状（2026-10-11 匿名逐条打过）：
///  * `/x/space/wbi/arc/search` 匿名直连 **HTTP 412**（第 1 页与第 2 页都是），
///    所以主页投稿这一条做成**可注入的传输**（[BiliListTransport]），生产上要
///    换成内嵌 WebView 的页内 fetch；其余四支匿名 + 最小参数就能拿到 code=0。
///  * `/x/series/series?series_id=1`（不存在的系列）回 **code=147002**，
///    是干净的「不是系列」信号 → [probeSeries] 拿它当探针；
///    而合集接口对不存在的 id 直接 -404，拿它当探针得捕获异常。
///  * 收藏夹的 `has_more` **不可靠** → 总数一律用 `data.info.media_count`。
///
/// **不抄参照实现的那四个 `dm_img_list` / `dm_img_str` / `dm_cover_img_str` /
/// `dm_img_inter` 常量**：那是那位作者自己机器的 GPU 串（明文含型号），
/// 抄进来既不合适也没必要。下面每个方法带的都是核对过的最小参数集。
///
/// 翻页终止判据**只用两个**（各接口分别钉在哪一个，见每个方法的注释）：
///  1. 已累计条数 ≥ 接口给的总数 `total`；
///  2. 这一页返回空。
/// 总数拿不到（`total <= 0`）时只靠判据 2 收口，所以 [allPages] 还带一道
/// `maxPages` 硬闸，防「服务端忽略 pn、每页都给同一批」把循环变成死循环。
library;

import '../models/bili_meta.dart';
import '../models/media.dart';
import 'bili_api.dart';
import 'bili_link.dart';

// ── 分页口径（各接口的总数字段名不一样，这里只放页大小）──

/// 主页投稿每页条数（参照实现同值，接口上限给到 40）
const int kBiliSpacePageSize = 40;

/// 合集每页条数
const int kBiliSeasonPageSize = 30;

/// 系列每页条数
const int kBiliSeriesPageSize = 30;

/// 收藏夹每页条数
const int kBiliFavPageSize = 40;

/// 自动翻页的硬闸。40 条一页时相当于 10000 条 —— 真超出的 UP 主由调用方
/// 显式传更大的 `maxPages`，而不是让这里默认无上限（一旦接口忽略 `pn`，
/// 无上限就是死循环）。
const int kBiliListMaxPages = 250;

// ── 注入点 ─────────────────────────────────────────────────────

/// 一条列表请求的传输。
///
/// **返回的是接口的 `data` 本体**（不是整份响应），与 [BiliApi.getData] /
/// [BiliApi.getSignedData] 同形 —— 这样默认实现就是转调那两个口，接线时
/// 换成页内 fetch 也不用改本层任何逻辑。
///
/// 换成页内 fetch 的写法（`bili_page.dart` 那边接线时照这个来）：
/// ```dart
/// BiliListApi(
///   api: api,
///   signed: (path, params) async {
///     final keys = await api.fetchWbiKeys();            // 签名仍在 Dart 侧
///     final url = biliSignedUri(path, params, keys.mixinKey).toString();
///     final body = await BiliInPage.get(ctrl, url);     // 凭据在浏览器侧
///     final code = body['code'];
///     if (code is num && code.toInt() != 0) {
///       throw BiliApiException('...', code: code.toInt());
///     }
///     return (body['data'] as Map).cast<String, dynamic>();
///   },
/// );
/// ```
/// 页内 fetch 拿回的是**整份 JSON**，所以实现里要自己判 `code` 再取 `data`；
/// 「非 0 就抛」这条契约不能省，[probeSeries] 靠异常与空 meta 两种否定形状收口。
typedef BiliListTransport = Future<Map<String, dynamic>> Function(
  String path,
  Map<String, dynamic> params,
);

// ── 数据形状 ───────────────────────────────────────────────────

/// 列表接口的一页。
///
/// [total] 是**接口自己给的总数**，字段名各接口不同（见各方法注释）；
/// 拿不到就是 0，此时 [isComplete] 退化成「这一页是不是空」。
class BiliListResult<T> {
  const BiliListResult({
    required this.items,
    required this.total,
    required this.pageNum,
    required this.pageSize,
    this.listTitle = '',
    this.skippedUnsupported = 0,
  });

  final List<T> items;

  /// 总数。`arc/search` 是 `data.page.count`，其余是 `data.page.total` /
  /// `data.info.media_count`；`list-all` 没有总数，用 `items.length` 顶。
  final int total;
  final int pageNum;
  final int pageSize;

  /// 列表自身的标题（合集名 / 系列名 / 收藏夹名），接口没给则 `''`。
  final String listTitle;

  /// 这一页里**认不出 BV 号**而被丢掉的条目数（收藏夹会混进音频 / 番剧 / 直播间）。
  /// 上层要把它如实说成「跳过 N 条本期不支持的条目」，静默吞掉的话用户会以为
  /// 「我 120 条的收藏夹怎么只下到 90 条，是漏了」。
  final int skippedUnsupported;

  /// 累计口径由 [BiliListApi.allPages] 掌握，这里只回答「这一页算不算翻到头」。
  bool get pageIsEmpty => items.isEmpty;

  /// 已知总数且本页给到了总数的口径。
  bool get totalKnown => total > 0;

  int get pages => total <= 0 || pageSize <= 0
      ? (items.isEmpty ? 0 : 1)
      : (total + pageSize - 1) ~/ pageSize;

  @override
  String toString() =>
      'BiliListResult(p$pageNum/$pages, items=${items.length}, total=$total)';
}

/// 一个列表翻到尽之后的汇总。
class BiliArcsSummary {
  const BiliArcsSummary({
    required this.items,
    required this.listTitle,
    required this.skipped,
  });

  final List<BiliArchive> items;

  /// 接口给的列表名；没有则空串（界面自己按目标类型兜一句）。
  final String listTitle;

  /// 各页累计的「本期不支持、已丢掉」条数。
  final int skipped;
}

/// 列表里的一条稿件。
///
/// **它映射成 [Media]（+ [BiliMeta]）交出去**，不另起一套稿件模型 —— 但列表
/// 接口给的字段比 `view` 少得多，有两个缺口必须让上层知道，所以模型落成
/// `Media` 时要往 [Media.bili] 里放真值、把缺的留成空，而不是填假值：
///  * **没有 `cid`**（四个列表接口都不给，收藏夹只藏在 `ugc.first_cid` 里）；
///  * **没有分 P 数**（`videos` 只有个别接口给，合集/系列的 archives 干脆没有）。
///
/// 所以 `Media.bili.cid` 一律留 null，台账与取流都要等页面用 `view` 展开成
/// 分 P 之后才有真 cid（`bili_link.dart` 的 [biliPartMedia] 是那条路）。
/// 列表项的 [Media.id] 用 `bvid`（与 `bili_feed.dart` 的种子条目同一口径）。
class BiliArchive {
  const BiliArchive({
    required this.bvid,
    required this.aid,
    required this.title,
    required this.cover,
    required this.durationMs,
    required this.publishTime,
    required this.upperMid,
    required this.upperName,
    required this.partTotal,
    required this.state,
    required this.viewCount,
    this.likeCount,
    this.replyCount,
    this.favoriteCount,
    this.shareCount,
  });

  final String bvid;
  final int aid;
  final String title;
  final String cover;
  final int durationMs;

  /// 发布/收录时间（`pubdate` / `pubtime`，秒级时间戳；缺则 null）
  final DateTime? publishTime;

  /// UP 主 mid。列表项自己没给时由调用方补（合集/系列的 archives 就没有）。
  final int upperMid;
  final String upperName;

  /// 分 P 数，**接口没给就是 1**（不是「不知道」的 0，免得 `%PART_TOTAL%` 变 0）
  final int partTotal;

  /// `state`：0 正常，非 0 是被删/下架/仅自己可见之类。上层据此灰显而不是让它进下载队列。
  final int state;
  final int viewCount;

  /// 统计量（接口没给则 null）。**只有 [viewCount] 是播放量**，
  /// 下面四个按 [Media] 自己的字段语义走，不许把播放量塞进点赞。
  final int? likeCount;
  final int? replyCount;
  final int? favoriteCount;
  final int? shareCount;

  bool get available => state == 0 && bvid.isNotEmpty;

  /// 列表接口的一页给的是**稿件级**信息，不是分 P 级：`cid` 与真实分 P 数都不在
  /// 响应里（收藏夹那条藏在 `ugc.first_cid`，但它是「第一条 P」的 cid，
  /// 不等于用户要下的那一 P）。所以这里**不填假值**，`cid` 留 null。
  ///
  /// [id] 就用 `bvid`：与 `bili_feed.dart` 的 `toSeedMedia()` 同一口径
  /// （「一条还没展开的稿件」），而 `bili_part_media` 那种 `bvid-P号` 是
  /// **展开之后**的键。同一个 bvid 在两处不会互相顶掉，因为展开后整体替换列表。
  Media toMedia() => Media(
        id: bvid,
        type: MediaType.video,
        url: '',
        previewUrl: cover,
        tweetId: bvid,
        tweetText: title,
        createdAt: publishTime,
        userId: upperMid == 0 ? null : upperMid.toString(),
        userName: upperName,
        mediaIndex: 1,
        source: 'bili',
        durationMs: durationMs,
        // 统计量按 [Media] 自己的字段语义放：点赞进 likeCount，播放量没有对应
        // 通用字段（留在 [viewCount] 上），不许为了「界面有数」把播放量塞进点赞。
        likeCount: likeCount,
        commentCount: replyCount,
        collectCount: favoriteCount,
        shareCount: shareCount,
        bili: BiliMeta(
          workTitle: title,
          partTitle: title,
          bvid: bvid,
          aid: aid.toString(),
          cid: null,
          partTotal: partTotal,
        ),
      );

  @override
  String toString() => 'BiliArchive($bvid, title=${title.length}, state=$state)';
}

/// 一个自建收藏夹（`/x/v3/fav/folder/created/list-all` 的一行）。
///
/// 刻意不是 [Media]：它不是一条稿件，而是「一组稿件的容器」，塞进 Media 就得
/// 造空标题/假 id，页面还会把它当一条可下载的东西排进列表。
class BiliFavFolder {
  const BiliFavFolder({
    required this.mediaId,
    required this.title,
    required this.mediaCount,
  });

  /// 拿去喂 [BiliListApi.favResources] 的那个 id
  final int mediaId;
  final String title;

  /// `media_count`。**只当显示用**：这一支（`list-all`）没有分页，也不保证与
  /// [favResources] 那一支同一时刻给同一个数。判翻尽用的总数一律是
  /// `favResources` 自己响应里的 `data.info.media_count`
  /// （2026-10-11 实测那一支：`info.media_count=3` 与 `medias` 的 3 条一致）。
  final int mediaCount;

  factory BiliFavFolder.fromJson(Map<String, dynamic> j) {
    final id = _asInt(j['id']) ?? _asInt(j['media_id']) ?? 0;
    return BiliFavFolder(
      mediaId: id,
      title: _str(_firstNonNull([j['name'], j['title']])),
      mediaCount: _asInt(j['media_count']) ?? 0,
    );
  }

  @override
  String toString() => 'BiliFavFolder($mediaId, ${title.length}字, $mediaCount)';
}

/// `x/series/series` 的 `data.meta`。
class BiliSeriesMeta {
  const BiliSeriesMeta({
    required this.seriesId,
    required this.mid,
    required this.name,
    required this.total,
  });

  final int seriesId;
  final int mid;
  final String name;

  /// `meta.total`。**不拿来当总数**：总数一律用列表接口自己的 `page.total`
  /// （2026-10-11 实测两者同值 17/17，但一个是 meta 里的记账值、一个是列表的
  /// 分页总数，口径不是一回事，混用等于把「以后接口改口径」的风险请进门）。
  final int total;

  factory BiliSeriesMeta.fromJson(Map<String, dynamic> j) => BiliSeriesMeta(
        seriesId: _asInt(j['series_id']) ?? _asInt(j['id']) ?? 0,
        mid: _asInt(j['mid']) ?? 0,
        name: _str(_firstNonNull([j['name'], j['title']])),
        total: _asInt(j['total']) ?? 0,
      );

  @override
  String toString() => 'BiliSeriesMeta($seriesId, ${name.length}字, $total)';
}

/// `x/web-interface/card` 的结果（用户名 + 粉丝数）。
class BiliUpperCard {
  const BiliUpperCard({
    required this.mid,
    required this.name,
    required this.fans,
  });

  final int mid;

  /// `data.card.name`。**接口给的 `card.mid` 是字符串**（实测 `"228292951"`），
  /// 所以这里统一按数字收上来，[mid] 用传入的那个而不是响应里的。
  final String name;
  final int fans;

  factory BiliUpperCard.fromJson(int mid, Map<String, dynamic> j) {
    final card = j['card'];
    final c = card is Map ? card.cast<String, dynamic>() : j;
    return BiliUpperCard(
      mid: _asInt(c['mid']) ?? mid,
      name: _str(c['name']),
      fans: _asInt(c['fans']) ?? 0,
    );
  }

  @override
  String toString() => 'BiliUpperCard($mid, ${name.length}字, fans=$fans)';
}

/// 本层的失败（接口自己的错误由 [BiliApiException] 透出，不重复包一层）。
class BiliListException implements Exception {
  const BiliListException({required this.reason, this.detail});

  final BiliListReason reason;

  /// 附带的结构化线索（路径、页号、kind 名），**不是文案**。
  final String? detail;

  @override
  String toString() =>
      'BiliListException(${reason.code}${detail == null ? '' : ': $detail'})';
}

/// 本层能给出的失败种类（界面按 `code` 接自己的文案）。
enum BiliListReason {
  /// 既没注入传输、也没有 [BiliApi] 兜底 —— 装配漏了。
  transportMissing('bili-list-transport-missing'),

  /// 翻页翻到 `maxPages` 还没翻尽（多半是接口忽略了 `pn`）。
  pageLimitExceeded('bili-list-page-limit'),

  /// 目标kind 与所调用的方法不匹配（互斥断言的落点，见 [BiliListTarget]）。
  targetKindMismatch('bili-list-target-kind-mismatch'),

  /// 列表响应里找不到列表数组（接口改了形状或被返回了半个错误页）。
  shapeMissing('bili-list-shape-missing');

  const BiliListReason(this.code);

  /// 稳定标识（进日志 / 异常文本）。
  final String code;
}

// ── 接口层 ─────────────────────────────────────────────────────

class BiliListApi {
  /// [api] 是兜底传输（真实请求走它的两个取数口）；[signed] / [plain] 注入后
  /// **优先于** [api]，测试与页内 fetch 都从这里进来。
  ///
  /// `arc/search` 匿名直连 412，所以签名口 [signed] 是**唯一需要替换**的那一个：
  /// 生产接线换成内嵌 WebView 的页内 fetch（写法见 [BiliListTransport] 的注释），
  /// 其余四支匿名 + [plain] 就够。
  BiliListApi({
    BiliApi? api,
    BiliListTransport? signed,
    BiliListTransport? plain,
    Duration? pageDelay,
    // 命名参数不能以下划线开头，所以这里只能是「公开名 → 私有字段」的转写，
    // 而不是 initializing formal。
    // ignore: prefer_initializing_formals
  })  : _api = api,
        _signedOverride = signed,
        _plainOverride = plain,
        _pageDelay = pageDelay ?? Duration.zero;

  final BiliApi? _api;
  final BiliListTransport? _signedOverride;
  final BiliListTransport? _plainOverride;
  final Duration _pageDelay;

  /// 按 mid 缓存的用户名。
  ///
  /// **命中必须直接 return**（参照实现 `parser/space.py:72-78` 的注释写着它们
  /// 曾因缺这句 return 而「每翻一页重复请求一次用户名」）。缓存里有值就用缓存，
  /// 一次请求都不发 —— 这条由 `test/bili_list_api_test.dart` 钉住。
  final Map<int, BiliUpperCard> _cardCache = {};

  /// 按 series_id 缓存的系列 meta。探针已经拿过一次，翻第二页不必再拿。
  final Map<int, BiliSeriesMeta> _seriesMetaCache = {};

  /// 清掉运行期缓存（切账号 / 换登录态时调用）。
  void clearCaches() {
    _cardCache.clear();
    _seriesMetaCache.clear();
  }

  BiliListTransport _transport({required bool signed}) {
    final injected = signed ? _signedOverride : _plainOverride;
    if (injected != null) return injected;
    final a = _api;
    if (a == null) {
      throw BiliListException(
        reason: BiliListReason.transportMissing,
        detail: signed ? 'signed' : 'plain',
      );
    }
    // `what` 传路径而不是中文句子：异常文本会变成
    // 「/x/space/wbi/arc/search失败：B 站返回 code=-403」——
    // 定位更快，而且本层不许新增用户可见中文字面量。
    return signed
        ? (path, params) => a.getSignedData(path, params, what: path)
        : (path, params) => a.getData(path, params, what: path);
  }

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, dynamic> params, {
    bool signed = false,
  }) =>
      _transport(signed: signed)(path, params);

  /// 整份响应 → `data`。注入的传输给 `data` 本体，这里两种都收：
  /// 带 `code` 的当成整份响应（判完 code 再取 data），不带的直接当 data 用。
  ///
  /// 为什么要收两种：`BiliApi.getData` 回的是 `data`，而页内 fetch 那侧
  /// 顺手拿到的是整份 `{code, message, data}` —— 让接线的人拆还是不拆，
  /// 少一个坑是一个。
  static Map<String, dynamic> _dataOf(Map<String, dynamic> body, String path) {
    final code = _asInt(body['code']);
    if (code != null) {
      if (code != 0) {
        throw BiliApiException(biliCodeHint(code, body['message']), code: code);
      }
      final data = body['data'];
      if (data is! Map) {
        // 实测匿名调「我的自建收藏夹列表」就是这个形状：code=0 但 data=null，
        // 也就是说这一支要登录态。ASCII 文本，界面按 code 接自己的文案。
        throw BiliApiException('$path code=0 data-missing');
      }
      return data.cast<String, dynamic>();
    }
    return body;
  }

  // ── 五个取列表的口 ──────────────────────────────────────────

  /// UP 主主页投稿：`/x/space/wbi/arc/search`（**走签名口**）。
  ///
  /// 参数集实测自参照实现：`pn` `ps` `tid=0` `order=pubdate` `mid` `platform=web`。
  /// **总数取 `data.page.count`**，列表在 `data.list.vlist[]`。
  ///
  /// **这一支的字段名只有夹具级证据**：2026-10-11 匿名直连实测就是
  /// `HTTP 412`（带不带 `pn` 都一样），拿不到真响应。`page.count` / `page.pn` /
  /// `page.ps` / `list.vlist` 按参照实现 `parser/space.py:45-63` + `:101` 写，
  /// vlist 项内的字段按「多种写法都收」的 `_archives` 兜着（`pic`/`cover`、
  /// `duration` 给秒也给 `"12:34"`）。接了页内 fetch 之后第一件事是拿真响应
  /// 复核这几个路径。
  ///
  /// [keyword] 是这个接口自带的服务端搜索，链接里的 `?keyword=` 要原样带进来。
  ///
  /// 列表项自己带 `author` 时用作者的，**没带才退到 [card]**（vlist 实测是带的，
  /// 而合集 / 系列的 archives 干脆没有作者字段）。每页都会走一次 [card]，
  /// 但命中缓存时它一个请求都不发 —— 这是「翻两页 card 只被调一次」的落点。
  Future<BiliListResult<BiliArchive>> spaceArcs({
    required int mid,
    int pn = 1,
    int ps = kBiliSpacePageSize,
    String? keyword,
  }) async {
    final data = _dataOf(
      await _get(
        '/x/space/wbi/arc/search',
        {
          'pn': pn,
          'ps': ps,
          'tid': 0,
          'order': 'pubdate',
          'mid': mid,
          'platform': 'web',
          if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
        },
        signed: true,
      ),
      '/x/space/wbi/arc/search',
    );
    final upper = await card(mid);
    return BiliListResult(
      items: _archives(
        // `data.list.vlist` 是这一支的形状；万一接口换成了 `archives`，
        // 也接得住（见 _rows：认不出的形状要报出来，不许当「这 UP 没投过稿」）
        data.containsKey('list') ? _rows(data, ['list', 'vlist']) : _rows(data, ['archives']),
        fallbackMid: mid,
        fallbackName: upper.name,
      ),
      // 这一支的总数在 page.count，不是别的接口的 page.total
      total: _asInt(_at(data, ['page', 'count'])) ?? 0,
      pageNum: _asInt(_at(data, ['page', 'pn'])) ?? pn,
      pageSize: _asInt(_at(data, ['page', 'ps'])) ?? ps,
    );
  }

  /// 合集：`/x/polymer/web-space/seasons_archives_list`（不签名即可）。
  ///
  /// 参数集：`mid` `season_id` `sort_reverse=false` `page_size` `page_num`
  /// —— **注意分页参数是 `page_num`/`page_size`**，不是别的接口的 `pn`/`ps`，
  /// 写错的话服务端会当成没传，每页都回第一页。
  ///
  /// **总数取 `data.page.total`**，列表在 `data.archives[]`，标题优先
  /// `data.season.title`、缺失退 `data.meta.title` / `data.meta.name`。
  ///
  /// 2026-10-11 匿名实测（mid=228292951 / season_id=9225450）：`data` 的键是
  /// `aids` / `archives` / `meta` / `page`，**没有 `season` 这一段**（`page` 是
  /// `{page_num, page_size, total}`），所以标题只能退到 `meta.title`（或 `meta.name`，
  /// 后者带「合集·」前缀）。三种落点都接着，顺序见 [_seasonTitle]。
  /// archives 项**不带作者名**（字段是 `aid bvid ctime duration pic pubdate
  /// stat state title ugc_pay`，`duration` 是**秒**），名靠 [card]。
  ///
  /// 这个接口不支持服务端 `keyword`，筛选留给上层（列表项已有标题可比）。
  Future<BiliListResult<BiliArchive>> seasonArcs({
    required int mid,
    required int seasonId,
    String? listTitle,
    int pn = 1,
    int ps = kBiliSeasonPageSize,
  }) async {
    final data = _dataOf(
      await _get('/x/polymer/web-space/seasons_archives_list', {
        'mid': mid,
        'season_id': seasonId,
        'sort_reverse': 'false',
        'page_size': ps,
        'page_num': pn,
      }),
      '/x/polymer/web-space/seasons_archives_list',
    );
    final upper = await card(mid);
    return BiliListResult(
      items: _archives(
        _rows(data, ['archives']),
        fallbackMid: mid,
        fallbackName: upper.name,
      ),
      total: _asInt(_at(data, ['page', 'total'])) ?? 0,
      pageNum: _asInt(_at(data, ['page', 'page_num'])) ?? pn,
      pageSize: _asInt(_at(data, ['page', 'page_size'])) ?? ps,
      listTitle: listTitle ?? _seasonTitle(data),
    );
  }

  /// 合集标题的三种落点：`data.season.title` → `data.meta.title` → `data.meta.name`。
  ///
  /// 实测有的响应**根本没有 `season` 段**（只有 `meta`），只按一种写法取就拿到空串。
  static String _seasonTitle(Map<String, dynamic> data) {
    for (final v in [
      _at(data, ['season', 'title']),
      _at(data, ['meta', 'title']),
      _at(data, ['meta', 'name']),
    ]) {
      final s = _str(v).trim();
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  /// 系列：`/x/series/archives`（不签名即可）。
  ///
  /// 参数集：`mid` `current_mid=0` `series_id` `only_normal=true` `sort=desc`
  /// `ps` `pn`。**总数取 `data.page.total`**，列表在 `data.archives[]`。
  ///
  /// **这个接口不含 meta**（2026-10-11 匿名实测 `data` 只有 `aids` /
  /// `archives` / `page`，`page` 是 `{num, size, total}` —— 字段名与合集那支的
  /// `page_num` / `page_size` 不一样，别看串了），
  /// 标题要另从 `/x/series/series?series_id=` 的 `data.meta` 拿。[meta] 传
  /// [probeSeries] 顺手取到的那份即可复用，不再发第二次请求；没传则这里自己
  /// 取一次（同一 id 的后续页走 [_seriesMetaCache]，也不重复请求）。
  Future<BiliListResult<BiliArchive>> seriesArcs({
    required int mid,
    required int seriesId,
    int pn = 1,
    int ps = kBiliSeriesPageSize,
    Map<String, dynamic>? meta,
  }) async {
    final data = _dataOf(
      await _get('/x/series/archives', {
        'mid': mid,
        'current_mid': 0,
        'series_id': seriesId,
        'only_normal': 'true',
        'sort': 'desc',
        'ps': ps,
        'pn': pn,
      }),
      '/x/series/archives',
    );
    final m = await _seriesMeta(seriesId, injected: meta);
    final title = m?.name ?? '';
    // 系列的 archives 项自带 `upMid` 却**不带作者名**（实测），名还是得问 card；
    // 命中缓存时这一步一个请求都不发。
    final upper = await card(mid);
    return BiliListResult(
      items: _archives(
        _rows(data, ['archives']),
        fallbackMid: mid,
        fallbackName: upper.name,
      ),
      total: _asInt(_at(data, ['page', 'total'])) ?? 0,
      pageNum: _asInt(_at(data, ['page', 'num'])) ?? pn,
      pageSize: _asInt(_at(data, ['page', 'size'])) ?? ps,
      listTitle: title,
    );
  }

  /// 收藏夹资源：`/x/v3/fav/resource/list`（不签名即可）。
  ///
  /// 参数集：`media_id` `pn` `ps` `keyword` `order=mtime` `type=0` `tid=0`。
  /// **总数取 `data.info.media_count`，列表在 `data.medias[]`**。
  ///
  /// **刻意不用 `has_more`**：按给的口径它不可靠，而 `data.info.media_count`
  /// 是准的（2026-10-11 匿名实测 media_id=1155866758：`info.media_count=3`、
  /// `medias` 3 条、`has_more=false`、**`data.page` 是 null** → 别去读 page）。
  /// medias 项的字段与别的列表不同名：`id`(=aid) / `bv_id`+`bvid` / `cover` /
  /// `duration`(秒) / `pubtime` / `upper.{mid,name}` / `ugc.first_cid`。
  Future<BiliListResult<BiliArchive>> favResources({
    required int mediaId,
    int pn = 1,
    int ps = kBiliFavPageSize,
    String? keyword,
  }) async {
    final data = _dataOf(
      await _get('/x/v3/fav/resource/list', {
        'media_id': mediaId,
        'pn': pn,
        'ps': ps,
        if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
        'order': 'mtime',
        'type': 0,
        'tid': 0,
      }),
      '/x/v3/fav/resource/list',
    );
    final parsed = _archiveRows(
      _rows(data, ['medias']),
      fallbackMid: 0,
      fallbackName: '',
    );
    return BiliListResult(
      items: parsed.items,
      skippedUnsupported: parsed.skipped,
      // 总数只认 info.media_count（实测 data.page 是 null）
      total: _asInt(_at(data, ['info', 'media_count'])) ?? 0,
      pageNum: pn,
      pageSize: ps,
      listTitle: _str(_at(data, ['info', 'title'])),
    );
  }

  /// 我的自建收藏夹列表：`/x/v3/fav/folder/created/list-all?up_mid={uid}`。
  ///
  /// **需要登录态**：2026-10-11 匿名实测回 `code=0` 但 `data=null`
  /// （[_dataOf] 把这种形状报成 `code=0 data-missing`，而不是给一个空列表 ——
  /// 「你没登录」和「你没有自建收藏夹」是两句话），所以上层要么带着 cookie 调，
  /// 要么走页内 fetch。返回的行是 `data.list[]` 的
  /// `id` / `title` / `media_count`。
  ///
  /// **这一支没有分页**：`list-all` 一次给全，[BiliListResult.total] 就是
  /// `items.length`，[allPages] 用不上它（别给它套自动翻页）。
  Future<BiliListResult<BiliFavFolder>> createdFolders({
    required int upMid,
  }) async {
    final raw = await _get('/x/v3/fav/folder/created/list-all', {
      'up_mid': upMid,
    });
    final data = _dataOf(raw, '/x/v3/fav/folder/created/list-all');
    final rows = _rows(data, ['list']);
    final out = <BiliFavFolder>[];
    if (rows is List) {
      for (final e in rows.whereType<Map>()) {
        final f = BiliFavFolder.fromJson(e.cast<String, dynamic>());
        if (f.mediaId != 0) out.add(f);
      }
    }
    return BiliListResult(
      items: out,
      total: out.length, // 无分页：总数就是给到的条数
      pageNum: 1,
      pageSize: out.length,
    );
  }

  // ── 用户名 / 系列 meta ──────────────────────────────────────

  /// UP 主名片：`x/web-interface/card?mid=`（实测匿名 code=0，能拿到
  /// `data.card.name` / `fans`）。
  ///
  /// **按 mid 缓存，命中直接 return，一个请求都不发**。
  ///
  /// 失败**照抛**：`spaceArcs` / `seasonArcs` / `seriesArcs` 都会走这里，
  /// 名片接口挂了就是整批列表拿不到 UP 名。这里没把它吞成空串 —— 吞掉的话
  /// 界面会安静地显示一片没有作者的列表，比报错难归因。
  /// 页面层要是判断「列表还是要显示、名先空着」，自己 catch 这一支即可。
  Future<BiliUpperCard> card(int mid) async {
    final hit = _cardCache[mid];
    if (hit != null) return hit; // ← 缺这句就是参照实现踩过的坑
    final data = _dataOf(
      await _get('/x/web-interface/card', {'mid': mid}),
      '/x/web-interface/card',
    );
    final result = BiliUpperCard.fromJson(mid, data);
    _cardCache[mid] = result;
    return result;
  }

  /// 系列 meta 探针：`/x/series/series?series_id=`。
  ///
  /// 是系列 → 返回它的 `meta`（顺带被 [seriesArcs] 复用）；
  /// **不是系列 → 返回 null**（实测非系列 id 干净回 `code=147002`）。
  ///
  /// 探针的「否」有两种形状，两种都收：注入的传输按契约抛 [BiliApiException]
  /// （`BiliApi.getData` 判 code 非 0 就抛），或老老实实给出没有 meta 的 data。
  /// 除「不是系列」之外的失败（HTTP 挂了）不吞 —— 吞了会把网络问题伪装成
  /// 「这个 sid 是合集」，然后去调合集接口，归因现场就没了。
  Future<BiliSeriesMeta?> probeSeries(int seriesId) async {
    final hit = _seriesMetaCache[seriesId];
    if (hit != null) return hit;
    Map<String, dynamic>? data;
    try {
      data = _dataOf(
        await _get('/x/series/series', {'series_id': seriesId}),
        '/x/series/series',
      );
    } on BiliApiException catch (e) {
      // 业务 code 非 0 = 「这不是系列」，是预期结果之一
      if (e.code == null) rethrow;
      return null;
    }
    final meta = data['meta'];
    if (meta is! Map) return null;
    final parsed = BiliSeriesMeta.fromJson(meta.cast<String, dynamic>());
    // name 是探针的最低可辨识条件：合集的 data 里根本没有 meta.name，
    // 认错了 kind 会导致下面「明说 series 就不许再查合集」那条断言形同虚设。
    if (parsed.name.isEmpty) return null;
    _seriesMetaCache[seriesId] = parsed;
    return parsed;
  }

  /// [probeSeries] 的裸 Map 形态，给 `resolveTarget` 用（链接层的回调只认 Map）。
  Future<Map<String, dynamic>?> probeSeriesRaw(int seriesId) async {
    final meta = await probeSeries(seriesId);
    if (meta == null) return null;
    return {'series_id': meta.seriesId, 'mid': meta.mid, 'name': meta.name, 'total': meta.total};
  }

  Future<BiliSeriesMeta?> _seriesMeta(int seriesId, {Map<String, dynamic>? injected}) async {
    if (injected != null) {
      final m = injected['meta'];
      final raw = m is Map
          ? BiliSeriesMeta.fromJson(m.cast<String, dynamic>())
          : BiliSeriesMeta.fromJson(injected);
      _seriesMetaCache[seriesId] = raw;
      return raw;
    }
    final hit = _seriesMetaCache[seriesId];
    if (hit != null) return hit;
    return await probeSeries(seriesId);
  }

  // ── 自动翻页 ────────────────────────────────────────────────

  /// 翻到尽。**两个终止判据**（各接口钉在哪个见上面五个方法的注释）：
  ///  1. 已累计 ≥ 这一页给的 `total`（`total <= 0` 即接口没给总数时**跳过此判据**）；
  ///  2. 这一页返回空。
  ///
  /// 外加 `maxPages` 硬闸：到了还没翻尽就抛 [BiliListException]
  /// （[BiliListReason.pageLimitExceeded]）—— 接口忽略 `pn`、每页都给同一批时，
  /// 这两个判据都收不住口，宁可不翻也不要挂住界面。
  ///
  /// 页与页之间等 `pageDelay`（构造参数，默认 0，测试与注入实现不等待）。
  /// 参照实现按「风控是越重试越坐实」的口径给列表请求留了间隔，真机接线时把
  /// `BiliListApi(pageDelay: ...)` 传成非零即可，不用改这里。
  Future<List<T>> allPages<T>(
    Future<BiliListResult<T>> Function(int pageNum) fetchPage, {
    int maxPages = kBiliListMaxPages,
    void Function(BiliListResult<T> page)? onPage,
  }) async {
    final out = <T>[];
    for (var pn = 1; pn <= maxPages; pn++) {
      if (pn > 1 && _pageDelay > Duration.zero) {
        await Future<void>.delayed(_pageDelay);
      }
      final page = await fetchPage(pn);
      onPage?.call(page);
      out.addAll(page.items);
      if (page.pageIsEmpty) return out; // 判据二
      if (page.totalKnown && out.length >= page.total) return out; // 判据一
    }
    throw BiliListException(
      reason: BiliListReason.pageLimitExceeded,
      detail: 'maxPages=$maxPages got=${out.length}',
    );
  }

  /// 主页投稿翻到尽。
  Future<List<BiliArchive>> allSpaceArcs({
    required int mid,
    String? keyword,
    int ps = kBiliSpacePageSize,
    int maxPages = kBiliListMaxPages,
  }) =>
      allPages(
        (pn) => spaceArcs(mid: mid, pn: pn, ps: ps, keyword: keyword),
        maxPages: maxPages,
      );

  /// 合集翻到尽。[meta] 传 [probeSeries] 拿到的那份可以顺带复用标题。
  Future<List<BiliArchive>> allSeasonArcs({
    required int mid,
    required int seasonId,
    String? listTitle,
    int ps = kBiliSeasonPageSize,
    int maxPages = kBiliListMaxPages,
  }) =>
      allPages(
        (pn) => seasonArcs(
          mid: mid,
          seasonId: seasonId,
          listTitle: listTitle,
          pn: pn,
          ps: ps,
        ),
        maxPages: maxPages,
      );

  /// 系列翻到尽（第一页取到的 meta 会被缓存，后面的页不再请求 meta）。
  Future<List<BiliArchive>> allSeriesArcs({
    required int mid,
    required int seriesId,
    Map<String, dynamic>? meta,
    int ps = kBiliSeriesPageSize,
    int maxPages = kBiliListMaxPages,
  }) =>
      allPages(
        (pn) => seriesArcs(
          mid: mid,
          seriesId: seriesId,
          pn: pn,
          ps: ps,
          meta: meta,
        ),
        maxPages: maxPages,
      );

  /// 收藏夹翻到尽。
  Future<List<BiliArchive>> allFavResources({
    required int mediaId,
    String? keyword,
    int ps = kBiliFavPageSize,
    int maxPages = kBiliListMaxPages,
  }) =>
      allPages(
        (pn) => favResources(
          mediaId: mediaId,
          pn: pn,
          ps: ps,
          keyword: keyword,
        ),
        maxPages: maxPages,
      );

  // ── 与链接层对接 ────────────────────────────────────────────

  /// 把链接层「身份未定」的目标判成合集 / 系列（判定链路见
  /// [resolveBiliListTarget]：先看视频的 `ugc_season`，再用系列探针）。
  Future<BiliListTarget> resolveTarget(BiliListTarget target) =>
      resolveBiliListTarget(
    target,
    view: ({String? bvid, int? aid}) async {
      if ((bvid == null || bvid.isEmpty) && aid == null) return null;
      final params = <String, dynamic>{};
      if (bvid != null && bvid.isNotEmpty) params['bvid'] = bvid;
      if (aid != null) params['aid'] = aid;
      return _dataOf(
        await _get('/x/web-interface/wbi/view', params, signed: true),
        '/x/web-interface/wbi/view',
      );
    },
    seriesProbe: probeSeriesRaw,
  );

  /// 按目标分流取一页。
  ///
  /// **互斥就卡在这里**：[BiliListTarget] 构造时已保证「kind 是 series 就不许带
  /// seasonId」，这一层再按 kind 分支 —— 明说 series 的目标只会走到
  /// [seriesArcs]，合集接口连一次请求都收不到（`test/bili_list_api_test.dart`
  /// 用「请求路径清单」盯这一条）。
  Future<BiliListResult<BiliArchive>> arcs(
    BiliListTarget target, {
    int pn = 1,
  }) async {
    final kind = target.kind;
    final id = target.listId;
    if (kind == BiliListKind.unknown) {
      throw BiliListException(
        reason: BiliListReason.targetKindMismatch,
        detail: 'unknown:${target.sid}',
      );
    }
    switch (kind) {
      case BiliListKind.space:
        final mid = target.mid;
        if (mid == null) {
          throw BiliListException(
            reason: BiliListReason.targetKindMismatch,
            detail: 'space-no-mid',
          );
        }
        return spaceArcs(mid: mid, pn: pn, keyword: _keywordOrNull(target.keyword));
      case BiliListKind.season:
        final mid = target.mid;
        if (mid == null || id == null) {
          throw BiliListException(
            reason: BiliListReason.targetKindMismatch,
            detail: 'season-missing-mid-or-id',
          );
        }
        return seasonArcs(mid: mid, seasonId: id, pn: pn);
      case BiliListKind.series:
        final mid = target.mid;
        if (mid == null || id == null) {
          throw BiliListException(
            reason: BiliListReason.targetKindMismatch,
            detail: 'series-missing-mid-or-id',
          );
        }
        return seriesArcs(
          mid: mid,
          seriesId: id,
          pn: pn,
          meta: target.seriesMeta,
        );
      case BiliListKind.fav:
        if (id == null) {
          throw BiliListException(
            reason: BiliListReason.targetKindMismatch,
            detail: 'fav-missing-id',
          );
        }
        return favResources(
          mediaId: id,
          pn: pn,
          keyword: _keywordOrNull(target.keyword),
        );
      case BiliListKind.unknown:
        throw BiliListException(
          reason: BiliListReason.targetKindMismatch,
          detail: 'unknown',
        );
    }
  }

  /// [arcs] 的「翻到尽」版：直接把分页循环压在同一个分流点上，
  /// 于是 kind 的校验与互斥只有一处判据（不复制一份 switch，
  /// 免得两处的分支以后被人改出差别来）。
  ///
  /// 不用于 `createdFolders`（那一支没有分页）。
  Future<List<BiliArchive>> allArcs(
    BiliListTarget target, {
    int maxPages = kBiliListMaxPages,
  }) =>
      allPages((pn) => arcs(target, pn: pn), maxPages: maxPages);

  /// [allArcs] 的带汇总版：批量页除了稿件还要**列表标题**（合集名 / 收藏夹名，
  /// 界面那一行要显示它）与**被丢掉的条数**（见 [BiliListResult.skippedUnsupported]）。
  /// 分页循环仍然只在 [allPages] 一处，终止判据不会被复制出第二份口径。
  Future<BiliArcsSummary> allArcsSummary(
    BiliListTarget target, {
    int maxPages = kBiliListMaxPages,
  }) async {
    var skipped = 0;
    var title = '';
    final items = await allPages(
      (pn) => arcs(target, pn: pn),
      maxPages: maxPages,
      onPage: (page) {
        skipped += page.skippedUnsupported;
        if (title.isEmpty) title = page.listTitle;
      },
    );
    return BiliArcsSummary(items: items, listTitle: title, skipped: skipped);
  }

  /// 列表项 → 界面那一行的 [Media]（薄封装，页面少写一层循环）。
  ///
  /// 顺序保持接口给的顺序；`id` 是 bvid，所以**接口要是连着给了两条同一个
  /// bvid**（翻页无效那一种），这里会去掉后面的重复而不是排两行一样的进去。
  List<Media> toMedias(List<BiliArchive> items) {
    final seen = <String>{};
    final out = <Media>[];
    for (final e in items) {
      if (e.bvid.isEmpty || !seen.add(e.bvid)) continue;
      out.add(e.toMedia());
    }
    return out;
  }
}

// ── 解析小工具 ────────────────────────────────────────────────

/// 一批原始列表项 → [BiliArchive]（不关心被丢掉几条时用这一支）。
List<BiliArchive> _archives(
  Object? rows, {
  required int fallbackMid,
  required String fallbackName,
}) =>
    _archiveRows(rows, fallbackMid: fallbackMid, fallbackName: fallbackName)
        .items;

/// 一批原始列表项 → [BiliArchive]，外加「丢了几条」。
///
/// `rows` 给 null 或空都回空列表（收藏夹为空、合集不存在都是这个形状）。
///
/// 各接口的字段名不齐（`pic` / `cover`、`aid` / `id` / `media_id`、
/// `pubdate` / `pubtime`、`bvid` / `bv_id`、`duration` 给过秒也给过 `"12:34"`），
/// 这里一次抹平，免得五个方法各写一遍映射再各写错一处。
///
/// 「列表项自己带的 UP」优先于 `fallback*`：合集 / 系列的 `archives` **不带作者名**
/// （实测只有 `upMid`），那两支的名字靠调用方传进来的 [card] 结果兜住。
({List<BiliArchive> items, int skipped}) _archiveRows(
  Object? rows, {
  required int fallbackMid,
  required String fallbackName,
}) {
  if (rows is! List) {
    return (items: const <BiliArchive>[], skipped: 0);
  }
  final out = <BiliArchive>[];
  var skipped = 0;
  for (final e in rows.whereType<Map>()) {
    final j = e.cast<String, dynamic>();
    final bvid = _firstBvid(j);
    // 认不出 BV 号的行（广告位、直播间、收藏夹里的音频与番剧）一律跳过，
    // 但条数要留给上层说人话。
    if (bvid.isEmpty) {
      skipped++;
      continue;
    }
    final upper = _asMap(j['upper']) ?? _asMap(j['owner']);
    // 统计量在两支里叫法不同：列表类给 `stat`（view / like / reply / favorite /
    // share），收藏夹给 `cnt_info`（play / danmaku / collect / reply / share）。
    final stat = _asMap(j['stat']) ?? _asMap(j['cnt_info']);
    out.add(BiliArchive(
      bvid: bvid,
      aid: _asInt(_firstNonNull([j['aid'], j['id'], j['media_id']])) ?? 0,
      title: _str(j['title']).trim(),
      cover: _https(_str(_firstNonEmptyStr([j['pic'], j['cover'], j['src']]))),
      durationMs: _durationMs(_firstNonNull([j['duration'], j['length']])),
      publishTime: _secondsToDate(_firstNonNull(
          [j['pubdate'], j['pubtime'], j['created'], j['last_update']])),
      upperMid: _asInt(_firstNonNull(
              [j['mid'], j['upMid'], j['author_mid'], upper?['mid']])) ??
          fallbackMid,
      upperName: _firstNonEmptyStr([j['author'], j['name'], upper?['name']]) ??
          fallbackName,
      // 只有个别接口给分 P 数；没给一律按单 P 记（展开时由 view 纠正）
      partTotal: _asInt(_firstNonNull([j['videos'], j['video_count']])) ?? 1,
      state: _asInt(j['state']) ?? 0,
      // `arc/search` 的 vlist 把播放量摊在顶层的 `play` 上，所以三层都看
      viewCount: _asInt(_firstNonNull([stat?['view'], j['play'], stat?['play']])) ?? 0,
      likeCount: _asInt(_firstNonNull([stat?['like'], stat?['thumb_up']])),
      replyCount: _asInt(stat?['reply']),
      favoriteCount: _asInt(_firstNonNull([stat?['favorite'], stat?['collect']])),
      shareCount: _asInt(stat?['share']),
    ));
  }
  return (items: out, skipped: skipped);
}

/// `bvid` 有两种写法：`bvid`（多数接口）与 `bv_id`（收藏夹的 `medias`）。
String _firstBvid(Map<String, dynamic> j) {
  for (final v in [j['bvid'], j['bv_id']]) {
    final s = _str(v).trim();
    if (s.isNotEmpty) return s;
  }
  return '';
}

/// 沿路径取字段（`['list', 'vlist']` 就是 `data.list.vlist`）。
///
/// 中间层不是 Map 就返回 null —— 接口换了形状时报「没有列表数组」而不是
/// 在深处抛一个类型转换异常。
Object? _at(Map<String, dynamic> data, List<String> path) {
  Object? cur = data;
  for (final key in path) {
    final m = _asMap(cur);
    if (m == null) return null;
    cur = m[key];
  }
  return cur;
}

/// 取**列表数组**本身。与 [_at] 的差别只有一件，但那件很重要：
/// 路径上的键**根本不存在** → 抛 [BiliListReason.shapeMissing]，
/// 而「键在、值是 null / 空数组」→ 回空列表。
///
/// 为什么分这两档：接口改了形状（或塞回来半个错误页）时被当成
/// 「这个 UP 一条稿都没投过」，界面就是一片空白加一句假话 ——
/// 这正是本项目最恨的静默失败。
Object? _rows(Map<String, dynamic> root, List<String> path) {
  Object? cur = root;
  for (var i = 0; i < path.length; i++) {
    final m = _asMap(cur);
    if (m == null) return const [];
    final key = path[i];
    if (!m.containsKey(key)) {
      throw BiliListException(
        reason: BiliListReason.shapeMissing,
        detail: path.sublist(0, i + 1).join('.'),
      );
    }
    cur = m[key];
  }
  return cur;
}

Map<String, dynamic>? _asMap(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : null;

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

String _str(Object? v) => v == null ? '' : '$v';

Object? _firstNonNull(List<Object?> values) {
  for (final v in values) {
    if (v != null) return v;
  }
  return null;
}

String? _firstNonEmptyStr(List<Object?> values) {
  for (final v in values) {
    final s = _str(v).trim();
    if (s.isNotEmpty) return s;
  }
  return null;
}

String? _keywordOrNull(String s) {
  final t = s.trim();
  return t.isEmpty ? null : t;
}

/// 时长：秒（`98`）与 `"12:34"` / `"1:02:03"` 两种都见过，统一成毫秒。
int _durationMs(Object? v) {
  if (v == null) return 0;
  if (v is num) return v.toInt() * 1000;
  final text = '$v'.trim();
  if (text.isEmpty) return 0;
  if (!text.contains(':')) {
    final n = int.tryParse(text);
    return n == null ? 0 : n * 1000;
  }
  var ms = 0;
  for (final part in text.split(':')) {
    ms = ms * 60 + (int.tryParse(part.trim()) ?? 0);
  }
  return ms * 1000;
}

DateTime? _secondsToDate(Object? v) {
  final s = _asInt(v) ?? 0;
  return s <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(s * 1000);
}

/// B 站的封面常给 `http://` 甚至 `//` 开头，界面按 https 取（与 `bili_feed.dart` 同规矩）。
String _https(String url) {
  if (url.startsWith('//')) return 'https:$url';
  if (url.startsWith('http://')) return url.replaceFirst('http://', 'https://');
  return url;
}
