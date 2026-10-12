/// 附加文件（弹幕 / 字幕 / 封面 / 章节 / 元数据）这一层的**共用契约**。
///
/// 生产者（`bili_subtitle.dart` 等四个写入器）和消费者（`bili_merger.dart` 拼
/// ffmpeg 命令、`aria2_coordinator.dart` 的合并回写）只认这里这几个类型，
/// 两边各自演进不至于互相踩。
///
/// 一条纪律写在类型上而不是写在注释里：附加文件**不走 aria2**。它们都是几十 KB
/// 的小文件，走 aria2 要新增一类 gid 配对，而带凭据的那几种还会撞上
/// 「per-task header 被 `--save-session` 明文写盘」这条红线。
library;

import '../models/bili_config.dart';
import '../models/media.dart';

/// 一条已经落盘、等着塞进成品的内封字幕轨。
class BiliEmbeddedTrack {
  const BiliEmbeddedTrack({
    required this.fileName,
    required this.title,
    required this.iso639,
    required this.fromDanmaku,
  });

  /// 保存目录里的文件名，一定是 `.ass` —— 非 ass 格式根本塞不进容器，
  /// 生产者在决定要不要产出这个对象之前就该把格式判掉。
  final String fileName;

  /// 播放器菜单里的轨道名。AI 字幕必须在这一步就标出来：B 站给的人工字幕和
  /// AI 字幕的 `lan_doc` 完全同名，只有 `lan` 里的 `ai-` 前缀能区分，
  /// 不标注的话菜单里会出现两条「中文」。
  final String title;

  /// MKV 的 `Language` 元素要 ISO 639-2 三字母码（`chi` / `eng` / `jpn`…），
  /// 而 B 站回的是 BCP-47（`zh-cn` / `ai-es`）。空串 = 不写这个标签。
  final String iso639;

  /// 弹幕墙还是字幕幕。两族撞在一起时谁排前面由 [BiliConfig.trackPriority] 定。
  final bool fromDanmaku;
}

/// 按优先级排轨序：排在列表最前的那条占成品里的第一条字幕轨。
///
/// 同一族内部按文件名稳定排序，不然同一批两次跑出来的轨序会随哈希顺序漂。
List<BiliEmbeddedTrack> orderTracks(
  List<BiliEmbeddedTrack> tracks,
  BiliTrackPriority priority,
) {
  int groupOf(BiliEmbeddedTrack t) => switch (priority) {
    BiliTrackPriority.danmakuFirst => t.fromDanmaku ? 0 : 1,
    BiliTrackPriority.subtitleFirst => t.fromDanmaku ? 1 : 0,
  };
  final sorted = [...tracks]
    ..sort((a, b) {
      final g = groupOf(a).compareTo(groupOf(b));
      return g != 0 ? g : a.fileName.compareTo(b.fileName);
    });
  return sorted;
}

/// 中文轨的语言码（ISO 639-2 与 BCP-47 两种写法都认）。
const Set<String> kBiliChineseLangs = {'chi', 'zh', 'zh-cn', 'zh-hans',
  'zh-hant', 'zh-hk', 'zh-tw', 'zho'};

/// 哪一条字幕轨该是播放器的**默认轨**。
///
/// 为什么不能靠「谁排第一谁默认」：ffmpeg 会把 `default` 标给**第一条**字幕流，
/// 而第一条是按文件名排序撞出来的。2026-10-12 真机撞上：`字幕.ai-ar.ass`
/// （阿拉伯语）恰好排第一，于是成品的默认字幕轨是阿拉伯语 —— 用户打开就是
/// 一堆看不懂的字，还以为「中文字幕下错了」。
///
/// 判据只有一条：**中文优先，弹幕垫底**。不区分人工/AI —— 两者同名（B站给的
/// `lan_doc` 完全一样），而 [BiliEmbeddedTrack] 上没有「是不是 AI」这个字段，
/// 靠标题里的「（AI）」后缀去判是把展示文案当语义用，不值当。
/// 返回 -1 表示没有可作默认的轨（空列表）。
int biliDefaultTrackIndex(List<BiliEmbeddedTrack> tracks) {
  if (tracks.isEmpty) return -1;
  int rank(BiliEmbeddedTrack t) {
    if (t.fromDanmaku) return 2;   // 弹幕垫底：它不是给人读的正文
    return kBiliChineseLangs.contains(t.iso639.toLowerCase()) ? 0 : 1;
  }
  var best = 0;
  var bestRank = rank(tracks[0]);
  for (var i = 1; i < tracks.length; i++) {
    final r = rank(tracks[i]);
    if (r < bestRank) {
      bestRank = r;
      best = i;
    }
  }
  return best;
}

/// 附加文件的落盘名。
///
/// 形如 `冬天-1080P.弹幕.中文.ass`、`冬天-1080P.字幕.eng.srt`、`冬天-1080P.封面.jpg`。
/// qualifier 是「弹幕 / 字幕 / 元数据」这一族的名字，lang 可省。这么排是因为
/// 弹幕和字幕会各有好几种语言，光靠扩展名分不开，而媒体库软件按主名配对。
String biliAdditionalName({
  required String base,
  required String qualifier,
  String? lang,
  required String ext,
}) {
  final parts = [base, qualifier, if (lang != null && lang.isNotEmpty) lang];
  return '${parts.join('.')}.${ext.replaceAll('.', '')}';
}

/// 一次附加文件跑完的结果。
class BiliAdditionalOutcome {
  const BiliAdditionalOutcome({
    required this.tracks,
    required this.written,
    required this.missing,
    this.chapterMetadataPath,
  });

  /// 待内封的轨，**已经按优先级排好**，合并命令照这个顺序拼 `-map`。
  final List<BiliEmbeddedTrack> tracks;

  /// 成功落盘的侧文件名。
  final List<String> written;

  /// 用户勾了但没拿到的东西（接口没返回、语言筛完剩零条、网络失败都算）。
  ///
  /// 这一项非空时界面要如实列出来。主产物完好就仍然算下载成功，
  /// 但「没拿到」绝不能只写进日志。
  final List<String> missing;

  /// 章节的 ffmetadata 中间文件路径；合并命令用它写章节，**合并成功后要删掉**。
  final String? chapterMetadataPath;

  static const BiliAdditionalOutcome none = BiliAdditionalOutcome(
    tracks: [],
    written: [],
    missing: [],
  );

  bool get hasAnything =>
      tracks.isNotEmpty || written.isNotEmpty || chapterMetadataPath != null;
}

/// 这一份配置里有没有要产出任何附加文件。为 false 时协调器一个请求都不发，
/// 也不会往收口文案里掺「没拿到」。
bool biliAsksForAnything(BiliConfig cfg) =>
    cfg.saveSubtitle ||
    cfg.saveCover ||
    cfg.saveChapter ||
    cfg.saveMetadata ||
    cfg.saveDanmaku;

/// 附加文件的产出钩子。
///
/// 协调器在**起 ffmpeg 之前**调一次：ass 字幕轨与章节的 ffmetadata 是合并命令的
/// 输入，必须先落盘。实现在 `bili_subtitle.dart` 那几个文件里，由装配层
/// （`main.dart`）注进来 —— 协调器不该知道接口层与渲染层的存在。
///
/// 做成可空函数域而不是抽象类，是跟着这个模块里 `onBiliSettled` /
/// `onTaskSubmitted` 的既有写法走的；没注就是「只出成品、没有侧文件」，
/// 这一层的缺席永远不该波及主产物。
typedef BiliAdditionalProduce =
    Future<BiliAdditionalOutcome> Function({
      required BiliConfig cfg,
      required String saveDir,
      required String outBase,
      required Media video,
    });
