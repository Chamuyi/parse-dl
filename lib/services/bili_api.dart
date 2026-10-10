/// B 站 web 接口客户端 —— wbi 密钥、稿件信息、取流地址、扫码登录。
///
/// 写法对齐 `x_api.dart`：同一个 `http` 包、同样显式注入 `findProxy`、同样经
/// [AppLogger] 记一行「路径 → 状态码」、同样把失败翻译成可读中文再抛。
/// 但**不复用它**：X 那套是 GraphQL + ct0/Bearer，B 站这套是 WBI 签名 + buvid，
/// 混在一个类里两边都会被迫背上对方的包袱。
///
/// **登录态只走运行时**：cookie 只是构造参数与内存字段，不进 `toJson`、不进日志、
/// 不进异常文本；扫码轮询拿到的 `Set-Cookie` 同样**只作为返回值**交给调用方
/// （登录态归登录层管），本文件一个字都不落盘。
///
/// **匿名（不带 cookie）也必须能用**：`playurl` 在无登录态时会返回 480P 档，
/// 这是「未登录也能下」的兜底路径。所以下面没有任何一个方法强依赖 cookie，
/// 只在缺 cookie 时补一份匿名设备标识（见 [_ensureAnonymousCookie]）——
/// 参照实现也是这么做的：匿名请求一样要带 buvid3/buvid4，否则更容易被风控。
///
/// 本期只做普通稿件：`fnval` 固定 4048，番剧/影集那套 143312 属后续阶段。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/bili_config.dart';
import '../models/media_variant.dart';
import 'app_logger.dart';
import 'bili_wbi.dart';

// ── 公共请求头 ────────────────────────────────────────────────

const String kBiliApiHost = 'api.bilibili.com';
const String kBiliPassportHost = 'passport.bilibili.com';

/// 来源页。**不是可选项** —— B 站的取流 CDN 校验 Referer，缺了就是 403。
const String kBiliReferer = 'https://www.bilibili.com/';

/// 接口侧要的是**不带结尾斜杠**的 Origin，与 Referer 不同形，别合并成一个常量。
const String kBiliOrigin = 'https://www.bilibili.com';

/// 真实 Chrome UA。B 站对空 UA 和 Dart 默认 UA 直接走风控。
const String kBiliUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// 取流地址要一次把 AVC / HEVC / AV1 三族都要回来用的位域组合。
///
/// 刻意不按编码偏好收窄：同画质三族的**码率差得很远**（AV1 更省），
/// 收窄之后就没得可选了，偏好只能留在排序阶段起作用（见 [biliToVariants]）。
const int kBiliFnval = 4048;

/// 公共请求头。**下载器与 WebView 必须用同一份** —— 三处各自的 UA 只要差一个
/// 版本号，就会出现「页面能播、接口能查、下载 403」这种极难归因的组合。
const Map<String, String> biliRequestHeaders = {
  'User-Agent': kBiliUserAgent,
  'Referer': kBiliReferer,
  'Origin': kBiliOrigin,
};

/// 在公共请求头之上补运行时 cookie（空则不带，即匿名请求）。
Map<String, String> biliRequestHeadersWith(String cookie) => {
      ...biliRequestHeaders,
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };

const Duration kBiliTimeout = Duration(seconds: 20);

/// 一次接口调用的最多尝试次数。
///
/// 比 X 那边少一次：B 站的风控是「越重试越坐实」，拿不到就尽早把可读原因交给
/// 用户，而不是把一次网络抖动拖成几十秒。
const int kBiliMaxRetry = 4;

/// 画质档位号 → 标签。
///
/// 只在 `support_formats` 没给文案时兜底。刻意用 `1080P60` 这种**不含空格**的形状：
/// 它会被拼进文件名（`%QUALITY%`），并与 `BiliMeta.qualityLabel` 的既有示例同形。
const Map<int, String> kBiliQualityNames = {
  127: '8K',
  126: '杜比视界',
  125: 'HDR 真彩',
  120: '4K',
  116: '1080P60',
  112: '1080P+',
  100: 'AI 修复',
  80: '1080P',
  74: '720P60',
  64: '720P',
  32: '480P',
  16: '360P',
};

/// 音质档位号 → 标签（音频 id 不是单调的，见 [kBiliAudioRank]）。
const Map<int, String> kBiliAudioNames = {
  30255: '杜比全景声',
  30251: 'Hi-Res',
  30250: '杜比',
  30280: '192K',
  30232: '132K',
  30216: '64K',
};

/// 音频档位由高到低的顺序（照参照实现的 `audio_reorder_map`）。
///
/// 30216 的 id 比 30280 小却更差，所以**不能按 id 排**，只能按这张表。
const List<int> kBiliAudioRank = [30255, 30251, 30250, 30280, 30232, 30216];

/// 编码 → 界面/文件名用的短标签。`auto` 是偏好不是实际编码，没有标签。
String biliCodecLabel(BiliCodec codec) => switch (codec) {
      BiliCodec.avc => 'AVC',
      BiliCodec.hevc => 'HEVC',
      BiliCodec.av1 => 'AV1',
      BiliCodec.auto => '',
    };

/// 从 RFC 6381 编码串认族（`avc1.640032` / `hev1.1.6...` / `av01.0.17M...`）。
///
/// 优先看 `codecs` 前缀而不是 `codecid`：参照实测两者始终一致，而部分老稿件的
/// 响应里根本不带 `codecid`。认不出来返回 null（宁可排在最后，不要瞎猜）。
BiliCodec? biliCodecFromCodecs(String codecs) {
  if (codecs.isEmpty) return null;
  final prefix = codecs.split('.').first.toLowerCase();
  return switch (prefix) {
    'avc1' => BiliCodec.avc,
    'hev1' || 'hvc1' || 'dvh1' => BiliCodec.hevc,
    'av01' => BiliCodec.av1,
    _ => null,
  };
}

// ── 数据形状 ──────────────────────────────────────────────────

/// 签好名的完整请求地址。**纯函数**（密钥直接传进来），所以能离线验。
///
/// 两条不显然的规矩：
///  * host 必须显式拼上。`'https://$path?...'` 看着没错（path 自己带前导斜杠），
///    实际拼出的是 `https:///x/...` = **空 host**，而它只在真发请求时才炸，
///    不打网络的测试一概看不见 —— 所以这里把 host 单独列成参数。
///  * query 由 [biliWbiQuery] 自己拼，不用 `Uri.https(host, path, map)`：
///    签名的字节必须与发出去的字节完全一致，交给 Uri 再排一遍序、再按它自己的
///    规则编码就没人保证了。
Uri biliSignedUri(
  String path,
  Map<String, dynamic> params,
  String mixinKey, {
  String host = kBiliApiHost,
  int? wts,
}) {
  final signed = biliSignWbi(params, mixinKey, wts: wts);
  return Uri.parse('https://$host$path?${biliWbiQuery(signed)}');
}

/// wbi 签名用的两个 key。
///
/// 刻意**没有 `toJson`**：key 本身不算凭据，但它和 cookie 一样只该活在运行时里 ——
/// 一旦有了序列化方法，早晚会被塞进某个落盘结构，再想收回来就得兼容老数据。
class BiliKeys {
  final String imgKey;
  final String subKey;

  const BiliKeys({required this.imgKey, required this.subKey});

  /// 从 `nav` 的 `img_url` / `sub_url` 建出来（取文件名去扩展名）。
  factory BiliKeys.fromUrls({
    required String imgUrl,
    required String subUrl,
  }) =>
      BiliKeys(
        imgKey: biliKeyFromUrl(imgUrl),
        subKey: biliKeyFromUrl(subUrl),
      );

  String get mixinKey => biliMixinKey(imgKey, subKey);
}

/// 一个分 P。
class BiliPage {
  /// P 号，从 1 起（`%P%` 用它）
  final int index;
  final int cid;
  final String partTitle;
  final int durationMs;

  /// 该 P 的首帧封面
  final String pic;

  const BiliPage({
    required this.index,
    required this.cid,
    required this.partTitle,
    required this.durationMs,
    required this.pic,
  });
}

/// 稿件统计量（文件名模板与界面展示用）。
class BiliStat {
  final int view;
  final int like;
  final int reply;
  final int share;
  final int coin;
  final int danmaku;
  final int favorite;

  const BiliStat({
    this.view = 0,
    this.like = 0,
    this.reply = 0,
    this.share = 0,
    this.coin = 0,
    this.danmaku = 0,
    this.favorite = 0,
  });

  static const empty = BiliStat();

  factory BiliStat.fromJson(Map<String, dynamic> j) => BiliStat(
        view: _int(j['view']) ?? 0,
        like: _int(j['like']) ?? 0,
        reply: _int(j['reply']) ?? 0,
        share: _int(j['share']) ?? 0,
        coin: _int(j['coin']) ?? 0,
        danmaku: _int(j['danmaku']) ?? 0,
        favorite: _int(j['favorite']) ?? 0,
      );
}

/// `x/web-interface/view` 的结果：一个稿件的骨架 + 分 P 列表。
class BiliVideoView {
  final String bvid;

  /// av 号。这里存数字（与 [BiliApi.playurl] 的 `aid` 参数同形），
  /// 要进 `BiliMeta.aid` 时由上层 `toString()`。
  final int aid;

  /// 首个分 P 的 cid —— 单 P 稿件直接用它取流
  final int cid;
  final String title;
  final String cover;
  final String upperName;
  final int upperMid;
  final DateTime? publishTime;
  final int durationMs;

  /// 分 P 总数。**始终等于 [pages].length**，不给「总数比列表多」留口子：
  /// 台账和 `%PART_TOTAL%` 都靠它判「下全了没有」，两处不一致会比少一档更难查。
  final int partTotal;
  final List<BiliPage> pages;
  final BiliStat stat;

  /// 付费 / 大会员专享。上层用它把「只拿到 480P」解释成「这是付费稿件」，
  /// 而不是让代码背「下不到高清」的锅。
  final bool isPay;

  const BiliVideoView({
    required this.bvid,
    required this.aid,
    required this.cid,
    required this.title,
    required this.cover,
    required this.upperName,
    required this.upperMid,
    required this.publishTime,
    required this.durationMs,
    required this.partTotal,
    required this.pages,
    required this.stat,
    required this.isPay,
  });

  /// 入向工厂（不是出向接口 —— 本文件不把原始 Map 交给上层）。
  factory BiliVideoView.fromJson(Map<String, dynamic> j) {
    final pages = <BiliPage>[];
    var index = 0;
    for (final p in (j['pages'] as List? ?? const []).whereType<Map>()) {
      index++;
      final page = p.cast<String, dynamic>();
      pages.add(BiliPage(
        // `page` 就是 P 号；缺位时用遍历下标顶上，保证从 1 连号
        index: _int(page['page']) ?? index,
        cid: _int(page['cid']) ?? 0,
        partTitle: _str(page['part']),
        durationMs: (_int(page['duration']) ?? 0) * 1000,
        pic: _str(page['first_frame']),
      ));
    }

    final owner = j['owner'];
    final stat = j['stat'];
    final rights = j['rights'];

    return BiliVideoView(
      bvid: _str(j['bvid']),
      aid: _int(j['aid']) ?? 0,
      cid: _int(j['cid']) ?? (pages.isEmpty ? 0 : pages.first.cid),
      title: _str(j['title']),
      cover: _str(j['pic']),
      upperName: owner is Map ? _str(owner['name']) : '',
      upperMid: owner is Map ? (_int(owner['mid']) ?? 0) : 0,
      // `pubdate` 是秒级时间戳
      publishTime: _fromEpochSeconds(_int(j['pubdate'])),
      durationMs: (_int(j['duration']) ?? 0) * 1000,
      partTotal: pages.length,
      pages: pages,
      stat: stat is Map
          ? BiliStat.fromJson(stat.cast<String, dynamic>())
          : BiliStat.empty,
      isPay: rights is Map &&
          (rights['pay'] == true || rights['is_ugc_pay'] == true),
    );
  }

  /// 第 [index] P（1 起）；越界返回 null，由上层决定提示什么。
  BiliPage? pageAt(int index) =>
      index < 1 || index > pages.length ? null : pages[index - 1];
}

/// 一条可下载的流（DASH 的视频/音频流，或 durl 退化路径里的单个文件）。
class BiliStream {
  /// 视频流是画质档位号（qn），音频流是音质档位号（见 [kBiliAudioNames]）
  final int id;

  /// RFC 6381 编码串原样留着：界面要显示，排错要对比
  final String codecs;

  /// 归族后的编码；认不出来为 null
  final BiliCodec? codec;
  final String baseUrl;
  final List<String> backupUrls;
  final int width;
  final int height;

  /// 整数帧率（`frame_rate` 也给过 `"29.97 fps"` 这种串，四舍五入）
  final int fps;

  /// 码率，单位 **bps**。取的是 `bandwidth`：B 站这个字段本来就是 bps
  /// （参照实现给 192K 音频档补的正是 `bandwidth: 192000`），与
  /// [MediaVariant.bitrate] 同单位，**不做换算**。老字段 `bitrate` 不是这个量纲，
  /// 所以刻意不取它。
  final int bitrate;

  /// 文件字节数（`size`，老响应里叫 `file_size`）
  final int dataSize;
  final int durationMs;

  /// 该档位的中文名（来自 `support_formats`，缺失时按 id 反查）
  final String qualityLabel;
  final bool isAudio;

  const BiliStream({
    required this.id,
    required this.codecs,
    required this.codec,
    required this.baseUrl,
    required this.backupUrls,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.bitrate = 0,
    this.dataSize = 0,
    this.durationMs = 0,
    this.qualityLabel = '',
    this.isAudio = false,
  });

  bool get usable => baseUrl.isNotEmpty;

  String get codecLabel => codec == null ? '' : biliCodecLabel(codec!);

  /// 依次尝试的地址：`baseUrl` 在首位，镜像跟其后（已去重）。
  List<String> get urls {
    final out = <String>[];
    for (final u in [baseUrl, ...backupUrls]) {
      if (u.isNotEmpty && !out.contains(u)) out.add(u);
    }
    return out;
  }
}

/// `x/player/wbi/playurl` 的结果。
class BiliPlayUrl {
  final int cid;

  /// true = 拿到了 `data.dash`；false = 老稿件只给 `data.durl` 的退化路径。
  ///
  /// 上层必须能区分这两者：DASH 要「一条视频流 + 一条音频流，下完合并」，
  /// durl 拿到的是完整 mp4，合并整步跳过。
  final bool isDash;

  /// 服务端认为本次给到的最高档位（`data.quality`）
  final int currentQn;
  final List<BiliStream> video;
  final List<BiliStream> audio;

  /// durl 退化路径的分段。正常只有 1 段；多段见 [needsSegmentMerge]。
  final List<BiliStream> singleFiles;

  /// 请求时带的编码偏好，回带给上层标注「按什么偏好取的」
  final BiliCodec preferredCodec;

  const BiliPlayUrl({
    required this.cid,
    required this.isDash,
    required this.currentQn,
    required this.video,
    required this.audio,
    required this.singleFiles,
    required this.preferredCodec,
  });

  /// 老稿件的 mp4 被切成多段时，单下其中一段不是完整视频。
  ///
  /// 本期不做分段拼接（那是合并器的事），但要把这种稿件**暴露出来**，
  /// 免得下载器以为拿到了完整文件、合出个残缺视频。
  bool get needsSegmentMerge => !isDash && singleFiles.length > 1;

  bool get hasVideo => video.isNotEmpty || singleFiles.isNotEmpty;

  /// 入向工厂（同 [BiliVideoView.fromJson]）。
  factory BiliPlayUrl.fromJson(
    Map<String, dynamic> j, {
    int? cid,
    BiliCodec preferredCodec = BiliCodec.auto,
  }) {
    // 档位文案整份响应共用一份，逐流查表
    final formats = _qualityLabelByQn(j['support_formats']);
    final dash = j['dash'];
    final video = <BiliStream>[];
    final audio = <BiliStream>[];

    if (dash is Map) {
      final d = dash.cast<String, dynamic>();
      // 2026-10-10 真机：`fnval=4048` 的响应里**每条流既不给 `size` 也不给 `duration`**
      // （六条视频流、三条音频流全是 0），时长只在容器级。所以下面两件事都要拿
      // 容器时长兜底：一是 `durationMs` 本身，二是「按 bandwidth × 时长 反推字节数」。
      final containerMs = _containerDurationMs(d, j);
      for (final e in (d['video'] as List? ?? const []).whereType<Map>()) {
        video.add(_streamFromMap(e.cast<String, dynamic>(), formats, false,
            containerMs: containerMs));
      }
      for (final e in (d['audio'] as List? ?? const []).whereType<Map>()) {
        audio.add(_streamFromMap(e.cast<String, dynamic>(), formats, true,
            containerMs: containerMs));
      }
      // `dash.flac.audio` / `dash.dolby.audio` 是嵌套对象/数组，形状与普通 audio
      // 不同；Hi-Res 与杜比音轨本期不取。
    }

    final qn = _int(j['quality']) ?? 0;
    final single = <BiliStream>[];
    for (final e in (j['durl'] as List? ?? const []).whereType<Map>()) {
      single.add(_durlToStream(e.cast<String, dynamic>(), j, qn, formats));
    }

    return BiliPlayUrl(
      cid: cid ?? 0,
      isDash: dash is Map && video.isNotEmpty,
      currentQn: qn,
      video: video,
      audio: audio,
      singleFiles: single,
      preferredCodec: preferredCodec,
    );
  }
}

/// 二维码登录：一张图对应一个 key。
class BiliQr {
  /// 要画成二维码的内容（B 站给的是个 https 链接）
  final String url;
  final String qrcodeKey;

  const BiliQr({required this.url, required this.qrcodeKey});
}

/// 扫码状态。
enum BiliQrState {
  /// 已确认，登录态在 [BiliQrStatus.setCookieHeaders] 里
  approved,

  /// 已扫码、手机上还没点确认
  scannedNotConfirmed,

  /// 二维码已过期，要重新生成
  expired,

  /// 还没人扫
  waiting,

  /// 没见过的码 —— 保留原始 [BiliQrStatus.code] 给上层显示，不猜语义
  unknown,
}

/// 一次轮询的结果。
///
/// **`Set-Cookie` 只在这里回传**：拿到登录态之后放哪（内存、WebView 会话、还是丢弃）
/// 是登录层的事，本层既不落盘也不打日志 —— 所以 [toString] 刻意不输出
/// [setCookieHeaders]，日志与异常文本里都带不出凭据。
class BiliQrStatus {
  final BiliQrState state;

  /// B 站原始的 `data.code`
  final int code;
  final String message;

  /// 登录成功后要跳转的地址
  final String redirectUrl;
  final List<String> setCookieHeaders;

  const BiliQrStatus({
    required this.state,
    required this.code,
    required this.message,
    required this.redirectUrl,
    required this.setCookieHeaders,
  });

  bool get hasCookies => setCookieHeaders.isNotEmpty;

  @override
  String toString() =>
      'BiliQrStatus(${state.name}, code=$code)${hasCookies ? ' +cookies' : ''}';
}

// ── 取流结果 → 下载源 ─────────────────────────────────────────

/// 取流结果 → 项目自己的下载源列表。**纯函数**：不发请求、不读设置、不碰状态。
///
/// 顺序即优先级：**先排好序的视频流，然后音频流**。DASH 的两条流各自都不是能独立
/// 播放的文件，所以下载器要一边一条、交给合并器。`kind` 复用抖音那套
/// [VariantKind]（视频 `bitRate` / 音频 `audio`），下载与台账侧不用加平台分支。
///
/// 视频流排序：编码偏好 → 画质档位号降序 → 码率降序 → 原始顺序。
/// 档位号排在码率前面是必须的：同档位的 AV1 码率天生低于 AVC（压缩率更高），
/// 只比码率会把更优的编码判成更差的。Dart 的 `List.sort` 不稳定，所以显式带上
/// 原始下标做 tiebreak —— 否则同一份响应两次解析可能给出不同顺序，
/// 「跳过已下载」的台账会对不上。
List<MediaVariant> biliToVariants(BiliPlayUrl r, BiliCodec prefer) {
  final videos = <(int, BiliStream)>[];
  for (final e in r.video.indexed) {
    if (e.$2.usable) videos.add(e);
  }
  videos.sort((a, b) {
    final byCodec = _codecRank(prefer, a.$2.codec)
        .compareTo(_codecRank(prefer, b.$2.codec));
    if (byCodec != 0) return byCodec;
    if (a.$2.id != b.$2.id) return b.$2.id.compareTo(a.$2.id);
    if (a.$2.bitrate != b.$2.bitrate) {
      return b.$2.bitrate.compareTo(a.$2.bitrate);
    }
    return a.$1.compareTo(b.$1);
  });

  final audios = <(int, BiliStream)>[];
  for (final e in r.audio.indexed) {
    if (e.$2.usable) audios.add(e);
  }
  audios.sort((a, b) {
    final byRank = _audioRank(a.$2.id).compareTo(_audioRank(b.$2.id));
    if (byRank != 0) return byRank;
    if (a.$2.bitrate != b.$2.bitrate) {
      return b.$2.bitrate.compareTo(a.$2.bitrate);
    }
    return a.$1.compareTo(b.$1);
  });

  final out = <MediaVariant>[];
  for (final entry in videos) {
    out.add(_variantOf(entry.$2, dash: r.isDash));
  }
  for (final entry in audios) {
    out.add(_variantOf(entry.$2, dash: r.isDash));
  }
  // durl 退化路径：分段按原顺序给出（拼接顺序就是它）。
  if (!r.isDash) {
    for (final s in r.singleFiles) {
      if (s.usable) out.add(_variantOf(s, dash: false));
    }
  }
  return out;
}

/// 把 [prefer] 想看的编码排到 0，其余排到 1；`auto` 按兼容性给固定序。
int _codecRank(BiliCodec prefer, BiliCodec? actual) {
  if (actual == null) return 3;
  if (prefer != BiliCodec.auto) return prefer == actual ? 0 : 1;
  // 「自动」= 兼容性优先：Windows 上硬解覆盖面就是 AVC > HEVC > AV1。
  return switch (actual) {
    BiliCodec.avc || BiliCodec.auto => 0,
    BiliCodec.hevc => 1,
    BiliCodec.av1 => 2,
  };
}

int _audioRank(int id) {
  final i = kBiliAudioRank.indexOf(id);
  return i < 0 ? kBiliAudioRank.length : i;
}

MediaVariant _variantOf(BiliStream s, {required bool dash}) => MediaVariant(
      urls: s.urls,
      kind: s.isAudio ? VariantKind.audio : VariantKind.bitRate,
      width: s.width,
      height: s.height,
      fps: s.fps,
      bitrate: s.bitrate,
      dataSize: s.dataSize,
      // DASH 的裸流落盘是 `.m4s`（合并之后才叫 mp4），durl 直接是完整 mp4。
      format: dash ? 'm4s' : 'mp4',
      // 抖音侧「滤掉低画质」那套口径靠 [MediaVariant.gearName]；B 站没有 gear 名，
      // 这里把「档位-编码」拼上去顶替，日志与文件名里都是人看得懂的那一档。
      gearName: s.isAudio
          ? s.qualityLabel
          : (s.codecLabel.isEmpty
              ? s.qualityLabel
              : '${s.qualityLabel}-${s.codecLabel}'),
    );

// ── 客户端 ────────────────────────────────────────────────────

class BiliApi {
  /// `cookie` 只存进内存字段。传空就是不登录，接口照样能取到 480P。
  ///
  /// `findProxy` 与 XApi 同一个形态（`PROXY host:port` / `SOCKS5 host:port`，
  /// 空 = 直连）；不传就只走 `main.dart` 设的全局 `HttpOverrides`。
  /// 两个都落成私有字段（`this._findProxy`）：登录态与代理规则没有任何对外可读的
  /// getter，序列化路径也就无从长出来。
  BiliApi({String? cookie, this._findProxy}) : _cookie = cookie ?? '';

  String _cookie;
  String? _findProxy;

  /// 匿名设备标识（buvid3/buvid4），只在内存里，进程结束就没了。
  String _anonCookie = '';
  bool _anonAttempted = false;

  BiliKeys? _keys;
  DateTime? _keysAt;

  /// 密钥缓存有效期。B 站按天轮换，而 `nav` 有限流：一次解析要发几十个签名请求，
  /// 每个都先打一遍 nav 等于自己把自己打进风控。
  static const Duration _keysTtl = Duration(hours: 6);

  /// 运行时生效的 cookie（用户登录态优先，其次匿名标识）。
  /// **刻意是私有 getter**：登录态不该有任何被序列化出去的顺手路径。
  String get _effectiveCookie => _cookie.isNotEmpty ? _cookie : _anonCookie;

  bool get hasCookie => _cookie.isNotEmpty;

  /// 更新登录态。扫码登录成功后由登录层调用；传空串表示退出登录。
  void setCookie(String cookie) {
    _cookie = cookie;
  }

  /// 代理规则变化时同步（设置页改代理之后调用）。
  void setFindProxy(String? rule) {
    _findProxy = rule;
  }

  // ── 接口 ────────────────────────────────────────────────────

  /// 取 wbi 签名密钥：`x/web-interface/nav` 的 `data.wbi_img`。
  ///
  /// **注意这里不看 `code`**：匿名请求 nav 会带 `code=-101`（未登录），
  /// 但 `wbi_img` 照样在 `data` 里。一遇到非 0 就抛的话，「未登录也能用」
  /// 这条兜底路径会在第一步就断掉。
  Future<BiliKeys> fetchWbiKeys() async {
    await _ensureAnonymousCookie();
    final body =
        await _getJson(() => _uri(kBiliApiHost, '/x/web-interface/nav', null));
    final data = body['data'];
    final wbi = data is Map ? data['wbi_img'] : null;
    if (wbi is! Map) {
      throw BiliApiException(
        '取 wbi 签名密钥失败：响应里没有 wbi_img（${_briefEnvelope(body)}）',
      );
    }
    final imgUrl = _str(wbi['img_url']);
    final subUrl = _str(wbi['sub_url']);
    final keys = BiliKeys.fromUrls(imgUrl: imgUrl, subUrl: subUrl);
    if (keys.imgKey.isEmpty || keys.subKey.isEmpty) {
      throw BiliApiException(
        '取 wbi 签名密钥失败：wbi_img 的 img_url/sub_url 提不出 key'
        '（$imgUrl / $subUrl）',
      );
    }
    _keys = keys;
    _keysAt = DateTime.now();
    AppLogger.log('BILI', 'wbi 密钥已更新'); // 只记「更新了」，不记密钥本身
    return keys;
  }

  /// 稿件信息（标题 / UP 主 / 分 P 列表 / 统计量）。
  Future<BiliVideoView> view({String? bvid, String? aid}) async {
    _requireTarget(bvid: bvid, aid: aid);
    await _ensureAnonymousCookie();
    return BiliVideoView.fromJson(
      await _data('/x/web-interface/view', {'bvid': bvid, 'aid': aid},
          what: '取稿件信息'),
    );
  }

  /// 取流地址（走 WBI 签名）。
  ///
  /// [qn] 是**上限**而不是档位：B 站会按账号权限在 `support_formats` 里裁掉拿不到的
  /// 高阶档，所以「传 116 只给到 80」是正常结果；匿名时通常只给到 32（480P），
  /// 这条兜底路径正是「未登录也能用」的实现方式。
  ///
  /// [codec] 只记录在结果里供上层标注，**不参与请求**：三族流一次性都要回来，
  /// 偏好留到 [biliToVariants] 排序时再用 —— 提前收窄等于替用户做了个他看不见的决定。
  Future<BiliPlayUrl> playurl({
    required int cid,
    required int qn,
    BiliCodec codec = BiliCodec.auto,
    String? bvid,
    int? aid,
  }) async {
    await _ensureAnonymousCookie();
    final data = await _signedData(
      '/x/player/wbi/playurl',
      {
        'cid': cid,
        'qn': qn,
        'fnval': kBiliFnval,
        'fnver': 0,
        'fourk': 1,
        'bvid': bvid,
        'aid': aid,
      },
      what: '取流地址',
    );
    final result = BiliPlayUrl.fromJson(data, cid: cid, preferredCodec: codec);
    if (!result.hasVideo) {
      // code 已经是 0（否则 `_unwrap` 先抛了），所以这条只解释「为什么是空的」：
      // 付费稿件、下架稿件、被风控的请求都会给出一个不带流的正常响应。
      throw BiliApiException(
        '取流地址失败：响应里既没有 dash 视频流也没有 durl 单文件'
        '（服务端只给到 quality=${result.currentQn}；付费稿件或被风控时就是这个形状）',
      );
    }
    return result;
  }

  /// [biliToVariants] 的入口。实现是纯函数，挂到类上是为了让下载器只认这一个接口。
  List<MediaVariant> toVariants(BiliPlayUrl r, BiliCodec prefer) =>
      biliToVariants(r, prefer);

  /// 生成登录二维码。画成图是页面层的事，这里只回内容与 key。
  Future<BiliQr> qrcodeGenerate() async {
    await _ensureAnonymousCookie();
    final data = await _data(
      '/x/passport-login/web/qrcode/generate',
      {
        'source': 'main-fe-header',
        'go_url': kBiliReferer,
        'web_location': '333.1007',
      },
      host: kBiliPassportHost,
      what: '生成登录二维码',
    );
    final key = _str(data['qrcode_key']);
    if (key.isEmpty) {
      throw BiliApiException('生成登录二维码失败：响应里没有 qrcode_key');
    }
    return BiliQr(url: _str(data['url']), qrcodeKey: key);
  }

  /// 轮询扫码状态。
  ///
  /// 状态码取自 web 轮询接口：`0` 已确认、`86090` 已扫未确认、`86038` 过期、
  /// `86101` 未扫码。个别资料里「未扫码」写作 `65`，那是 App/TV 端的另一套接口，
  /// web 这个接口给的是 `86101`；认不出来的码一律落进 [BiliQrState.unknown]
  /// 并保留原始 code 由上层显示，不在这里猜语义。
  ///
  /// 确认成功后 B 站用**响应头**下发登录态，[BiliQrStatus.setCookieHeaders]
  /// 就是那份头，原样交出去（只回传，不落盘、不打日志）。
  Future<BiliQrStatus> qrcodePoll(String key) async {
    await _ensureAnonymousCookie();
    final response = await _getWithCookies(_uri(
      kBiliPassportHost,
      '/x/passport-login/web/qrcode/poll',
      {'qrcode_key': key},
    ));
    final body = response.body;
    final data = body['data'];
    final map = data is Map ? data.cast<String, dynamic>() : body;
    final code = _int(map['code']) ?? _int(body['code']) ?? -1;
    return BiliQrStatus(
      state: _qrState(code),
      code: code,
      message: _str(map['message']),
      redirectUrl: _str(map['url']),
      setCookieHeaders: response.cookies,
    );
  }

  // ── 内部：请求 ──────────────────────────────────────────────

  /// 通用 GET → JSON。[buildUri] 每次重试都重新调用：签名里的 `wts` 会过期，
  /// 拿同一串签名重放只会在几轮退避之后再次被拒。
  Future<Map<String, dynamic>> _getJson(
    FutureOr<Uri> Function() buildUri, {
    int maxRetry = kBiliMaxRetry,
  }) async {
    var delayMs = 400;
    for (var i = 0; i < maxRetry; i++) {
      try {
        return await _getJsonOnce(await buildUri());
      } catch (e) {
        AppLogger.log('BILI', '第 ${i + 1} 次请求失败：$e');
        if (i == maxRetry - 1) rethrow;
        // 限流与风控：再快也照样被打回来，等久一点比多打几次有用
        final throttled = e is BiliApiException &&
            (e.statusCode == 403 || e.statusCode == 412 || e.statusCode == 429);
        await Future<void>.delayed(
            Duration(milliseconds: throttled ? delayMs * 3 : delayMs));
        delayMs *= 2;
      }
    }
    throw BiliApiException('请求 B 站接口失败（已重试 $maxRetry 次）');
  }

  Future<Map<String, dynamic>> _getJsonOnce(Uri uri) async {
    final client = _httpClient();
    try {
      final res =
          await client.get(uri, headers: _apiHeaders()).timeout(kBiliTimeout);
      AppLogger.log('BILI', 'GET ${_logUri(uri)} -> ${res.statusCode}');
      final text = utf8.decode(res.bodyBytes, allowMalformed: true);
      if (res.statusCode >= 400) {
        throw BiliApiException(
          'HTTP ${res.statusCode}：${_clip(text, 160)}',
          statusCode: res.statusCode,
        );
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw BiliApiException('响应不是 JSON 对象（HTTP ${res.statusCode}）');
      }
      return decoded.cast<String, dynamic>();
    } on FormatException {
      // 被风控时 B 站会回一段 HTML，jsonDecode 直接炸 —— 换成能读的原因
      throw BiliApiException('响应不是 JSON（多半被风控拦了，返回的是页面不是接口）');
    } finally {
      client.close();
    }
  }

  /// 签名请求 → `data`。
  Future<Map<String, dynamic>> _signedData(
    String path,
    Map<String, dynamic> params, {
    required String what,
  }) async {
    try {
      return _unwrap(await _getJson(() => _signedUri(path, params)), what);
    } on BiliApiException catch (e) {
      // 密钥按天轮换，进程内缓存会在换密钥之后一直给出旧签名。-403 是
      // 「签名被拒」唯一的信号：清缓存重取一次，比让用户重启应用便宜得多。
      if (e.code != -403) rethrow;
      AppLogger.log('BILI', '$what 签名被拒，重取 wbi 密钥后重试一次');
      _keys = null;
      return _unwrap(await _getJson(() => _signedUri(path, params)), what);
    }
  }

  Future<Uri> _signedUri(String path, Map<String, dynamic> params) async {
    final keys = await _cachedWbiKeys();
    return biliSignedUri(path, params, keys.mixinKey);
  }

  Future<BiliKeys> _cachedWbiKeys() async {
    final cached = _keys;
    final at = _keysAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _keysTtl) {
      return cached;
    }
    return await fetchWbiKeys();
  }

  Future<Map<String, dynamic>> _data(
    String path,
    Map<String, dynamic>? params, {
    required String what,
    String host = kBiliApiHost,
  }) async {
    final body = await _getJson(() => _uri(host, path, params));
    return _unwrap(body, what);
  }

  Map<String, dynamic> _unwrap(Map<String, dynamic> body, String what) {
    final code = _int(body['code']);
    if (code != 0) {
      throw BiliApiException(
        '$what失败：${biliCodeHint(code, body['message'])}',
        code: code,
      );
    }
    final data = body['data'];
    if (data is! Map) {
      throw BiliApiException('$what失败：响应里没有 data');
    }
    return data.cast<String, dynamic>();
  }

  /// 拿 JSON 的同时把响应里的 `Set-Cookie` **逐条**取回来。
  ///
  /// 为什么这一步要绕开 `package:http`：它的 `Response.headers` 是
  /// `Map<String, String>`，dart:io 早把同名头用逗号并成了一条；而 `Set-Cookie`
  /// 的值里本来就带逗号（`expires=Mon, 12 ...`），并完就再也拆不回去了。
  /// `HttpHeaders` 的下标取值保留每条独立的头，所以这里直接用 dart:io 发请求。
  Future<_CookieResponse> _getWithCookies(Uri uri) async {
    final client = _ioClient();
    try {
      final request = await client.openUrl('GET', uri).timeout(kBiliTimeout);
      for (final e in _apiHeaders().entries) {
        request.headers.set(e.key, e.value);
      }
      final res = await request.close().timeout(kBiliTimeout);
      // 下标取值才是「每条头一个元素」；`res.headers['set-cookie']` 之外没有别的拿法
      final cookies =
          List<String>.from(res.headers[HttpHeaders.setCookieHeader] ?? const []);
      AppLogger.log('BILI', 'GET ${_logUri(uri)} -> ${res.statusCode}');
      final bytes = <int>[];
      await for (final chunk in res) {
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      if (res.statusCode >= 400) {
        throw BiliApiException(
          'HTTP ${res.statusCode}：${_clip(text, 160)}',
          statusCode: res.statusCode,
        );
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw BiliApiException('响应不是 JSON 对象（HTTP ${res.statusCode}）');
      }
      return _CookieResponse(
        body: decoded.cast<String, dynamic>(),
        cookies: cookies,
      );
    } finally {
      // force：出错时响应体没读完，不强制关会把连接挂在那儿等超时
      client.close(force: true);
    }
  }

  /// 缺登录态时补一份匿名设备标识（`x/frontend/finger/spi` 的 b_3 / b_4）。
  ///
  /// 参照实现的匿名请求带的是 buvid3/buvid4/bili_ticket/buvid_fp 一组；本期只补
  /// buvid —— `bili_ticket` 要 murmur3 + HMAC 一整套自有算法、`buvid_fp` 又是 UA 的
  /// 哈希，两者都只在「已经被风控盯上」那条路径上才起作用。缺标识的后果只是
  /// 更容易被风控，不影响匿名取 480P，所以这里失败也不往上抛。
  Future<void> _ensureAnonymousCookie() async {
    if (_cookie.isNotEmpty || _anonCookie.isNotEmpty || _anonAttempted) return;
    // 先置位再发请求：解析几十个分 P 时会有几十个调用同时走到这里，
    // 而 `finger/spi` 也只是个普通接口，并发打它同样会招来风控。
    _anonAttempted = true;
    try {
      final data =
          await _data('/x/frontend/finger/spi', null, what: '取匿名设备标识');
      final b3 = _str(data['b_3']);
      final b4 = _str(data['b_4']);
      if (b3.isEmpty) return;
      _anonCookie = b4.isEmpty ? 'buvid3=$b3' : 'buvid3=$b3; buvid4=$b4';
      AppLogger.log('BILI', '匿名设备标识已就绪'); // 只记「有了」，不记内容
    } catch (e) {
      AppLogger.log('BILI', '匿名 buvid 获取失败（不阻断，按无标识继续）：$e');
    }
  }

  /// 匿名请求用的 HTTP 客户端。
  ///
  /// 与 XApi 同理：Dart 的 `HttpClient` 不读 Windows 系统代理、也不读环境变量，
  /// 必须显式设 `findProxy`。[findProxy] 为空时退回全局 `HttpOverrides`
  /// （`main.dart` 里设的那份），所以应用级代理照样生效。
  http.Client _httpClient() {
    final rule = _findProxy;
    if (rule == null || rule.isEmpty) return http.Client();
    return IOClient(_ioClient());
  }

  HttpClient _ioClient() {
    final client = HttpClient();
    final rule = _findProxy;
    if (rule != null && rule.isNotEmpty) {
      client.findProxy = (uri) => rule;
    }
    client.connectionTimeout = kBiliTimeout;
    return client;
  }

  Map<String, String> _apiHeaders() => {
        ...biliRequestHeaders,
        'Accept': 'application/json, text/plain, */*',
        if (_effectiveCookie.isNotEmpty) 'Cookie': _effectiveCookie,
      };

  Uri _uri(String host, String path, Map<String, dynamic>? params) {
    final query = <String, String>{};
    if (params != null) {
      for (final e in params.entries) {
        final v = e.value;
        if (v == null) continue;
        final text = '$v';
        if (text.isEmpty) continue;
        query[e.key] = text;
      }
    }
    return Uri.https(host, path, query.isEmpty ? null : query);
  }

  void _requireTarget({String? bvid, String? aid}) {
    if ((bvid == null || bvid.isEmpty) && (aid == null || aid.isEmpty)) {
      throw BiliApiException('bvid 与 aid 至少要给一个');
    }
  }

  static BiliQrState _qrState(int code) => switch (code) {
        0 => BiliQrState.approved,
        86090 => BiliQrState.scannedNotConfirmed,
        86038 => BiliQrState.expired,
        86101 => BiliQrState.waiting,
        _ => BiliQrState.unknown,
      };

  /// 日志用的精简 URI。**只记路径与 query 摘要**：B 站的取流地址自带鉴权参数，
  /// 完整 URL 进日志等于把可下载凭据写进一个会被备份的文件。
  static String _logUri(Uri uri) {
    final q = uri.query;
    final short = q.length > 150 ? '${q.substring(0, 150)}…' : q;
    return short.isEmpty ? uri.path : '${uri.path}?$short';
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : text.substring(0, max);

  String _briefEnvelope(Map<String, dynamic> body) {
    final code = _int(body['code']);
    final message = _str(body['message']);
    if (code == null && message.isEmpty) return '无 code/message 字段';
    return message.isEmpty ? 'code=$code' : 'code=$code message=$message';
  }
}

/// B 站业务错误码 → 可读中文。
///
/// 只列本期真会遇到、且**用户能做点什么**的码；其余原样带出服务端的文案。
/// 这里绝不拼 cookie —— 异常文本会进日志、也会显示到界面上。
String biliCodeHint(int? code, Object? message) {
  final text = (message ?? '').toString();
  return switch (code) {
    -101 => '未登录或登录态无效（$text）—— 匿名请求只该指望 480P，更高档位需要 cookie',
    -352 => '被 B 站风控拦截（请求过快或缺少设备标识），稍后再试',
    -403 => 'WBI 签名校验被拒（本地缓存的密钥多半已过期）',
    -412 => '请求被 B 站拒绝（多半是 UA / Referer 与风控），换个代理再试',
    62002 => '稿件不存在（BV/AV 号是不是抄错了？）',
    62012 => '稿件不可用（审核中、被删除或仅自己可见）',
    _ => text.isEmpty ? 'B 站返回 code=$code' : 'B 站返回 code=$code：$text',
  };
}

/// `_getWithCookies` 的返回打包。**私有类型**：它带着登录态，不该被当成通用容器。
class _CookieResponse {
  final Map<String, dynamic> body;
  final List<String> cookies;

  const _CookieResponse({required this.body, required this.cookies});
}

/// B 站接口层的异常。
///
/// [message] 只有 HTTP 状态、B 站给的业务文案和路径 —— 这一层手里握着登录态，
/// 而异常文本会被打进日志、也会显示到界面上，所以任何含 cookie 的东西
/// 都不许汇到这里。
class BiliApiException implements Exception {
  final String message;

  /// B 站业务 `code`
  final int? code;

  /// HTTP 状态码
  final int? statusCode;

  const BiliApiException(this.message, {this.code, this.statusCode});

  @override
  String toString() =>
      'BiliApiException(${code != null ? 'code=$code' : 'http=$statusCode'}): $message';
}

// ── 解析小工具 ────────────────────────────────────────────────

String _str(dynamic v) => v == null ? '' : '$v';

int? _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

DateTime? _fromEpochSeconds(int? seconds) => seconds == null || seconds <= 0
    ? null
    : DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

/// `support_formats` → 「档位号 → 展示文案」。
///
/// 文案字段在历史上有过三个名字（`quality_desc` / `new_description` /
/// `display_desc`），按这个顺序取第一个非空的：实测同一份响应里至少有一个，
/// 而只认其中一个的写法会在部分稿件上拿不到标签。
Map<int, String> _qualityLabelByQn(dynamic supportFormats) {
  final out = <int, String>{};
  if (supportFormats is! List) return out;
  for (final e in supportFormats.whereType<Map>()) {
    final j = e.cast<String, dynamic>();
    final qn = _int(j['quality']);
    if (qn == null) continue;
    final label = _firstNonEmpty(
        [j['quality_desc'], j['new_description'], j['display_desc']]);
    if (label.isNotEmpty) out[qn] = label;
  }
  return out;
}

String _firstNonEmpty(List<dynamic> values) {
  for (final v in values) {
    final s = _str(v);
    if (s.isNotEmpty) return s;
  }
  return '';
}

BiliStream _streamFromMap(
  Map<String, dynamic> j,
  Map<int, String> formats,
  bool isAudio, {
  int containerMs = 0,
}) {
  final id = _int(j['id']) ?? 0;
  final codecs = _str(j['codecs']);
  final bandwidth = _int(j['bandwidth']) ?? 0;
  final selfMs = (_int(j['duration']) ?? 0) * 1000;
  final durationMs = selfMs > 0 ? selfMs : containerMs;
  // `size` 在 `fnval=4048` 的响应里**不给**（2026-10-10 真机：六条视频流、三条音频流
  // 的 `size` 全是缺失，`dataSize` 一律落到 0）。所以按 `bandwidth × 时长` 反推。
  // 这个估算不是凑数：同一条 2172 秒的稿件，估视频 95,145,568 / 实下 95,104,081
  // （差 0.04%），估音频 44,583,286 / 实下 44,579,075（差 0.009%）。
  // 真拿到 `size` 时仍然优先用原值。
  final sizeBytes = _int(j['size'] ?? j['file_size']) ??
      (bandwidth > 0 && durationMs > 0
          ? bandwidth * durationMs ~/ 8000
          : 0);
  return BiliStream(
    id: id,
    codecs: codecs,
    codec: isAudio
        ? null
        : biliCodecFromCodecs(codecs) ?? _codecFromCodecid(_int(j['codecid'])),
    baseUrl: _firstNonEmpty([j['baseUrl'], j['base_url']]),
    backupUrls: _urlList([j['backupUrl'], j['backup_url']]),
    width: _int(j['width']) ?? 0,
    height: _int(j['height']) ?? 0,
    fps: _fps(j['frame_rate']),
    bitrate: bandwidth,
    dataSize: sizeBytes,
    durationMs: durationMs,
    qualityLabel: _labelOf(id, isAudio, formats),
    isAudio: isAudio,
  );
}

/// 容器级时长（毫秒）：`dash.duration` 是秒，`data.timelength` 是毫秒。
int _containerDurationMs(Map<String, dynamic> dash, Map<String, dynamic> data) {
  final fromDash = _int(dash['duration']) ?? 0;
  if (fromDash > 0) return fromDash * 1000;
  return _int(data['timelength']) ?? 0;
}

/// 老稿件的 `durl` 一段 → 一条「流」。durl 的字段名与 dash 完全不同，编码信息
/// 也不在段里（在 `data.codecs` 顶层），所以得从外面补。
BiliStream _durlToStream(
  Map<String, dynamic> j,
  Map<String, dynamic> root,
  int qn,
  Map<int, String> formats,
) {
  final rawCodecs = root['codecs'];
  final codecs = rawCodecs is List && rawCodecs.isNotEmpty
      ? _str(rawCodecs.first)
      : _str(rawCodecs);
  // `length` 是毫秒；durl 段里没有码率字段，只能按「字节数 / 时长」反推成 bps，
  // 好让它和 dash 的 bandwidth 同量纲（上层比较档位时才不会被单位绊一下）。
  final lengthMs = _int(j['length']) ?? 0;
  final sizeBytes = _int(j['size']) ?? 0;
  final bitrate = lengthMs > 0 && sizeBytes > 0
      ? sizeBytes * 8 * 1000 ~/ lengthMs
      : 0;
  return BiliStream(
    id: qn,
    codecs: codecs,
    codec: biliCodecFromCodecs(codecs),
    baseUrl: _str(j['url']),
    backupUrls: _urlList([j['backup_url']]),
    width: _int(root['width']) ?? 0,
    height: _int(root['height']) ?? 0,
    fps: _fps(root['frame_rate']),
    bitrate: bitrate,
    dataSize: sizeBytes,
    durationMs: lengthMs,
    qualityLabel: _labelOf(qn, false, formats),
    isAudio: false,
  );
}

/// 档位号 → 标签：先 `support_formats` 给的文案，再内置中文表。
String _labelOf(int id, bool isAudio, Map<int, String> formats) {
  final hit = formats[id];
  if (hit != null && hit.isNotEmpty) return hit;
  return isAudio ? (kBiliAudioNames[id] ?? '') : (kBiliQualityNames[id] ?? '');
}

/// `frame_rate` 既给过数字（`25`）也给过串（`"29.97 fps"`），统一成整数帧率。
int _fps(dynamic v) {
  if (v is num) return v.round();
  final text = _str(v);
  if (text.isEmpty) return 0;
  final head = text.split(RegExp(r'[^0-9.]')).first;
  final parsed = double.tryParse(head);
  return parsed == null ? 0 : parsed.round();
}

/// `codecid` 是 B 站自己的编码号（7 AVC / 12 HEVC / 13 AV1），只在没有 `codecs` 时用。
BiliCodec? _codecFromCodecid(int? codecid) => switch (codecid) {
      7 => BiliCodec.avc,
      12 => BiliCodec.hevc,
      13 => BiliCodec.av1,
      _ => null,
    };

/// `backupUrl` 有的响应给串、有的给数组，两种都收。
List<String> _urlList(List<dynamic> candidates) {
  final out = <String>[];
  for (final c in candidates) {
    if (c is List) {
      for (final v in c) {
        final s = _str(v);
        if (s.isNotEmpty && !out.contains(s)) out.add(s);
      }
    } else {
      final s = _str(c);
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
  }
  return out;
}
