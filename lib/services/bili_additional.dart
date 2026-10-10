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
