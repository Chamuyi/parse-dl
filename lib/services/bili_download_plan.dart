/// B 站「一条分 P 到底下哪两条流」的决策层 —— **全部纯函数，不打网络**。
///
/// 为什么单独一层：画质上限与编码偏好在 `bili_api.dart` 里没有任何落点 ——
/// `biliToVariants()` 只负责把响应摊平成「有序下载源」，它排的是**整条列表的
/// 优先级**，而下载要的是「这次就取这两条」。把这段判断从 API 层里分出来，
/// 才能不联网就把裁档 / 偏好 / 退化路径逐条钉住（`test/bili_coordinator_plan_test.dart`）。
///
/// 三条口径说明：
///  * **上限不等于结果。** `BiliQuality` 存的是上限（见 `bili_config.dart`），
///    B 站还会按账号权限先裁一刀，所以「选了 1080P60 只拿到 1080P」是正常结果：
///    先按 `quality.qn` 裁掉超上限的档，再在剩下的里取实际最高档。
///  * **先裁画质、再按编码偏好。** 编码影响的是能不能合并与兼容性，
///    不该把清晰度换掉，所以排序键是「档位号 → 编码偏好 → 码率」。
///  * **不碰 cookie。** 需要登录 / 大会员才能取的流，这一期拿不到就是不拿，
///    如实回一句可读原因（[BiliStreamPair.message]），由上层报给用户 ——
///    绝不为了拿到高阶档把凭据塞给 aria2（理由见 `aria2_coordinator.dart` 的
///    `_requestOptions`：per-task header 会被 `--save-session` 逐条原样写盘）。
library;

import '../models/bili_config.dart';
import '../models/bili_meta.dart';
import '../models/media.dart';
import '../models/media_variant.dart';
import 'bili_api.dart';

// ── 落名契约 ──────────────────────────────────────────────────

/// 视频流那条的临时名（**固定形状**，配对与重启重建都靠认这两个后缀）。
String biliVideoStreamName(String outBase) => '$outBase.video.m4s';

/// 音频流那条的临时名。
String biliAudioStreamName(String outBase) => '$outBase.audio.m4s';

/// 合并后的产物名。
String biliMergedName(String outBase) => '$outBase.mp4';

/// 这条流落到哪个 B 站容器扩展名（B 站 DASH 只有这几个形状）。
///
/// `%EXT%` 会跟着模板进到文件名里，而合并产物只该有一个 `.mp4`，
/// 所以 base 名必须把这段尾巴剥掉 —— 只认这张表里的扩展名，
/// 标题正文里的「冬.天」不会被误削。
final RegExp _biliTrailingExt =
    RegExp(r'\.(m4s|mp4|m4a|aac|mp3|flac)$', caseSensitive: false);

/// 由模板渲染出来的完整文件名反推**不含扩展名**的 base 名。
///
/// 上层（B 站页）拿它算 `outBase`，再交给
/// [Aria2Coordinator.enqueueBiliMedia]：视频流 / 音频流两条行各自补
/// `.video.m4s` / `.audio.m4s`，合并产物补 `.mp4`。
String biliBaseNameFromFileName(String fileName) {
  final m = _biliTrailingExt.firstMatch(fileName);
  return m == null ? fileName : fileName.substring(0, m.start);
}

// ── 选流结果 ──────────────────────────────────────────────────

/// 一条分 P 选出来的两条流（或 durl 退化路径下的那一个完整文件）。
class BiliStreamPair {
  /// 选中的视频流；null 表示一条都没选上（原因看 [message]）
  final MediaVariant? video;

  /// 选中的音频流；durl 退化路径是 null（那个文件本身就带声音）
  final MediaVariant? audio;

  /// 上层给进来的 base 名，原样回带 —— **这一层不算模板**，
  /// 模板要的是 `Media` 与用户设置，那是页面与协调器的事，混进来就没法纯测了。
  final String finalBaseName;

  /// true = DASH（要下两条、要合并）；false = durl 退化路径（一条完整 mp4）
  final bool isDash;

  /// 实际选中的画质档位号（`qn`），0 = 没选上。
  ///
  /// 界面要用它说清「你要的是 1080P60，拿到的是 1080P」—— 这不是 bug，
  /// 但瞒着用户报「已按 1080P60 下载」就是说谎。
  final int videoQn;

  /// 实际选中的编码族，认不出来为 null（[BiliMeta.codecLabel] 的模板变量用它）
  final BiliCodec? videoCodec;

  /// 不可用**时**给用户看的一句话原因；可用时是 null。
  final String? message;

  const BiliStreamPair({
    this.video,
    this.audio,
    this.finalBaseName = '',
    this.isDash = true,
    this.videoQn = 0,
    this.videoCodec,
    this.message,
  });

  /// 能不能拿去入队。
  bool get usable =>
      message == null && video != null && (!isDash || audio != null);

  /// 需不需要走合并。durl 退化路径拿到的是完整 mp4，合并按钮那一步整段跳过。
  bool get needsMerge => usable && isDash && audio != null;
}

// ── 选流 ─────────────────────────────────────────────────────

/// 纯函数：从一次 `playurl` 的结果里挑出这次的视频流与音频流。
///
/// 不打网络、不读设置、不看 cookie —— 传进来的 [r] 就是 API 层已经拿回来的东西。
///
/// 视频：① 按 `quality.qn` 裁掉超上限的档 → ② 取剩下的里**实际最高**档
/// （[BiliQuality.highest] 的 `qn` 是 127，等于不裁）→ ③ 同档位内按 [codec]
/// 偏好取（`auto` = 兼容性优先 = 先 AVC）→ ④ 还并列就比码率，最后比原始顺序。
///
/// 第 ② 步那个「裁完是空的」的分支必须存在：账号权限低于用户选的上限时，
/// 上限本身筛不出任何流，硬要按上限判失败就等于「用户选了 8K 就什么都下不了」。
/// 所以退而取实际最高档，并在 [BiliStreamPair.videoQn] 里如实带上够到了哪一档。
///
/// 音频：取**码率最高**的那条。`kBiliAudioRank` 那张档位表是给界面标签用的，
/// 这里只认码率 —— 同一档位的镜像地址码率相同，不同档位之间码率单调，
/// 用码率当判据既不用查表也不会因为 B 站新增音质档而漏排。
BiliStreamPair planBiliStreams(
  BiliPlayUrl r,
  BiliQuality quality,
  BiliCodec codec, {
  String baseName = '',
}) {
  // durl 退化路径：老稿件没有 dash，给的本来就是能直接播的完整 mp4。
  if (!r.isDash) {
    final segments = r.singleFiles.where((s) => s.usable).toList();
    if (segments.isEmpty) {
      return BiliStreamPair(
        isDash: false,
        finalBaseName: baseName,
        message: '这个稿件没给出可下载的完整文件（durl 为空）。'
            '更高画质通常需要登录或大会员凭据，本期不支持带凭据下载。',
      );
    }
    // 分段稿件要**按顺序拼**成一个 mp4，本期不做（见 BiliPlayUrl.needsSegmentMerge）。
    // 只下第一段会拿到一个「能打开但只有前几分钟」的假成功 —— 比明确报错更坏。
    if (r.needsSegmentMerge) {
      return BiliStreamPair(
        isDash: false,
        finalBaseName: baseName,
        message: '这个稿件的老格式下载被切成 ${segments.length} 段，'
            '本期还不做分段拼接，直接下会拿到不完整的视频。',
      );
    }
    final s = segments.first;
    return BiliStreamPair(
      video: biliStreamToVariant(s, dash: false),
      finalBaseName: baseName,
      isDash: false,
      videoQn: s.id,
      videoCodec: s.codec,
    );
  }

  final usable = r.video.where((s) => s.usable).toList(growable: false);
  if (usable.isEmpty) {
    return BiliStreamPair(
      finalBaseName: baseName,
      message: '没取到任何可用的视频流。'
          '这类稿件通常需要登录或大会员凭据，本期不支持带凭据下载。',
    );
  }

  final cap = quality.qn;
  final inCap =
      usable.where((s) => s.id <= cap).toList(growable: false);
  final pool = inCap.isEmpty ? usable : inCap;

  var topQn = 0;
  for (final s in pool) {
    if (s.id > topQn) topQn = s.id;
  }
  final atQn = pool.where((s) => s.id == topQn).toList(growable: false);

  // 同档位内的编码偏好排序。`auto` 是「兼容性优先」：Windows 硬解覆盖面
  // AVC > HEVC > AV1；显式偏好排在自己那族之前，其余照兼容性顺序垫后 ——
  // 这样「要 HEVC 但这档只有 AVC」时仍有流可下，而不是直接失败。
  final ranked = <(int, int, BiliStream)>[];
  for (final e in atQn.indexed) {
    ranked.add((_biliCodecRank(codec, e.$2.codec), e.$1, e.$2));
  }
  ranked.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    if (a.$3.bitrate != b.$3.bitrate) {
      return b.$3.bitrate.compareTo(a.$3.bitrate);
    }
    return a.$2.compareTo(b.$2);
  });
  final chosen = ranked.first.$3;

  final audios = r.audio.where((s) => s.usable).toList(growable: false);
  if (audios.isEmpty) {
    // DASH 的视频流单独不是可播放文件：只下它等于下一个 0 秒的空壳。
    return BiliStreamPair(
      video: biliStreamToVariant(chosen, dash: true),
      finalBaseName: baseName,
      videoQn: chosen.id,
      videoCodec: chosen.codec,
      message: '这个稿件的音频流需要登录或大会员凭据才能取到，'
          '而 DASH 的视频流单独不能播放，本期不支持只下一半。',
    );
  }
  var best = audios.first;
  for (final s in audios) {
    if (s.bitrate > best.bitrate) best = s;
  }

  return BiliStreamPair(
    video: biliStreamToVariant(chosen, dash: true),
    audio: biliStreamToVariant(best, dash: true),
    finalBaseName: baseName,
    isDash: true,
    videoQn: chosen.id,
    videoCodec: chosen.codec,
  );
}

/// 编码偏好 → 排序序号（0 最优先）。
///
/// 与 `bili_api.dart` 里那个私有 `_codecRank` **相近但刻意不同**，也刻意各写一份：
/// 那份给整条下载源列表排「用户大概会想要哪个」，非偏好族一律并列成第 1 档就够了；
/// 这一份要在**已经裁好画质**的同一档里定唯一胜者，并列会把胜者交给码率与
/// 响应里的原始顺序 —— 而 B 站同档 AV1 的码率天生低于 AVC，并列的结果就是
/// 「用户要 HEVC、这一档没有 HEVC」时把他领去下 AV1。
/// 所以这里非偏好族仍然保留兼容性顺序（AVC > HEVC > AV1），偏好只在「有它」时赢。
/// 两边共用一个私有函数反而会把两种用途的排序键绑死，故各自实现。
///
/// **显式偏好落空时不该判失败**：用户要 HEVC 而这一档只有 AVC 时，
/// 拿到 AVC 是「按他选的清晰度、换个编码」，直接不下才是真的没道理。
int _biliCodecRank(BiliCodec prefer, BiliCodec? actual) {
  if (actual == null) return 8; // 认不出编码的流排最后，但不至于判不可用
  final compat = switch (actual) {
    BiliCodec.avc => 1,
    BiliCodec.hevc => 2,
    BiliCodec.av1 => 3,
    BiliCodec.auto => 4,
  };
  return prefer != BiliCodec.auto && prefer == actual ? 0 : compat;
}

/// 一条 B 站流 → 项目自己的下载源形状。
///
/// 与 `bili_api.dart` 的 `_variantOf` 同形（`kind` 也复用抖音那套枚举，
/// 这样下载与台账侧不用加平台分支）。刻意不直接调那个私有函数：
/// 它跟着 `biliToVariants()` 的「摊平整条列表」的用途走，
/// 选流层要的只是「我挑出来的这一条」，两边各自演进更清楚。
MediaVariant biliStreamToVariant(BiliStream s, {required bool dash}) =>
    MediaVariant(
      urls: s.urls,
      kind: s.isAudio ? VariantKind.audio : VariantKind.bitRate,
      width: s.width,
      height: s.height,
      fps: s.fps,
      bitrate: s.bitrate,
      dataSize: s.dataSize,
      format: dash ? 'm4s' : 'mp4',
      gearName: s.isAudio
          ? s.qualityLabel
          : (s.codecLabel.isEmpty
              ? s.qualityLabel
              : '${s.qualityLabel}-${s.codecLabel}'),
    );

// ── 两条 Media ────────────────────────────────────────────────

/// 把选流结果摊成**两个 Media 实例**（配对关系不在 Media 里，见下）。
///
/// 为什么是两个实例而不是一条复合 `Media`：`Media` 只有一条下载候选链
/// （`url` + `altUrls` + `chosen`），下载链路 / X / 抖音全都按这个走。
/// 把它改成「装两条流」会牵连全部路径，所以 B 站的「一条分 P = 两个文件」
/// 用两个 Media 表达，配对由 `Aria2Coordinator` 记在进程内的表里
/// （**不进 `Media`、不进 `DownloadTask` 的字段**）。
/// 返回的 `audio` 为 null 就是**没有第二条流**（durl 退化路径，或者压根没选上）：
/// 协调器据此走单条入队、不建配对，界面上一行就是成品。
({Media video, Media? audio}) biliPairToMedias({
  required Media part,
  required BiliStreamPair pair,
}) {
  final video = pair.video;
  if (video == null) {
    // 一条都没选上：原样退回，由调用方去读 [BiliStreamPair.message] 报给用户。
    return (video: part, audio: null);
  }
  final videoMedia =
      _withStream(part, video, type: MediaType.video, idSuffix: '');
  final audio = pair.audio;
  if (audio == null) {
    // durl 退化路径：一个完整 mp4，本来就没有第二条流，也就没有配对。
    return (video: videoMedia, audio: null);
  }
  return (
    video: videoMedia,
    audio: _withStream(part, audio, type: MediaType.audio, idSuffix: '_audio'),
  );
}

/// 用某条流的具体地址覆盖 [base] 的下载字段，其余展示字段（标题 / UP 主 /
/// B 站上下文 / 时长）原样留着 —— 两条行在界面上说的是同一个分 P。
///
/// 刻意不用 `Media.copyWith`：它**改不了 `id`**（`id` 是构造必填、copyWith 原样带走），
/// 而两条流的 `id` 必须分开 —— 任务行的 localId 是 `<media.id>_<微秒>`，
/// 同 id 的两行一旦落在同一微秒就是同一条记录，重试也分不清在重下哪条。
/// 音频侧的后缀只动 `id`：台账与去重读的是 `bili.cid` / `tweetId`（两边同值），
/// 不受影响。
Media _withStream(
  Media base,
  MediaVariant v, {
  required MediaType type,
  required String idSuffix,
}) {
  final urls = v.urls;
  return Media(
    id: '${base.id}$idSuffix',
    type: type,
    url: urls.isEmpty ? base.url : urls.first,
    altUrls: urls.length <= 1
        ? const []
        : urls.sublist(1).toList(growable: false),
    previewUrl: base.previewUrl,
    width: v.width > 0 ? v.width : base.width,
    height: v.height > 0 ? v.height : base.height,
    tweetId: base.tweetId,
    tweetText: base.tweetText,
    createdAt: base.createdAt,
    userId: base.userId,
    userName: base.userName,
    userScreenName: base.userScreenName,
    tags: base.tags,
    mediaIndex: base.mediaIndex,
    source: 'bili',
    variants: [v],
    chosen: v,
    durationMs: base.durationMs,
    likeCount: base.likeCount,
    commentCount: base.commentCount,
    collectCount: base.collectCount,
    shareCount: base.shareCount,
    collectionEpisode: base.collectionEpisode,
    customText: base.customText,
    // 音频行不带画质/编码标签：给一条音频标「1080P60 / AV1」是错的文案，
    // 而 %QUALITY% / %CODEC% 在文件名模板里只有视频侧该取到值。
    bili: base.bili == null
        ? null
        : BiliMeta(
            workTitle: base.bili!.workTitle,
            partTitle: base.bili!.partTitle,
            bvid: base.bili!.bvid,
            aid: base.bili!.aid,
            cid: base.bili!.cid,
            partTotal: base.bili!.partTotal,
            qualityLabel:
                type == MediaType.audio ? null : base.bili!.qualityLabel,
            codecLabel:
                type == MediaType.audio ? null : base.bili!.codecLabel,
          ),
  );
}
