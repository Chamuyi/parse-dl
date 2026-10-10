/// B 站一条媒体独有的上下文。
///
/// 其他平台这个字段是 null。刻意**不往 [Media] 上摊一堆 B 站字段** ——
/// 那样每个新平台都会把通用模型撑大一遍，也让「术语不许串门」的检查失去抓手。
class BiliMeta {
  /// 作品标题（多 P 时的父标题）
  final String? workTitle;

  /// 分 P / 小标题
  final String? partTitle;

  /// BV 号
  final String? bvid;

  /// av 号（字符串存，避免与 `int` 的解析结果互相打架）
  final String? aid;

  /// 分 P 的内容 id —— 台账去重的组成部分
  final String? cid;

  /// 分 P 总数。**1 表示单 P**：`%P%` 与 `<...>` 可选段据此判"没有分 P 号"。
  final int partTotal;

  /// 画质标签，如 `1080P60`
  final String? qualityLabel;

  /// 编码标签，如 `AVC` / `HEVC` / `AV1`
  final String? codecLabel;

  const BiliMeta({
    this.workTitle,
    this.partTitle,
    this.bvid,
    this.aid,
    this.cid,
    this.partTotal = 1,
    this.qualityLabel,
    this.codecLabel,
  });

  /// 是否单 P（单 P 没有 P 号，模板里的 `<P%P%>` 整段应当消失）。
  bool get isSinglePart => partTotal <= 1;

  Map<String, dynamic> toJson() => {
        if (workTitle != null) 'workTitle': workTitle,
        if (partTitle != null) 'partTitle': partTitle,
        if (bvid != null) 'bvid': bvid,
        if (aid != null) 'aid': aid,
        if (cid != null) 'cid': cid,
        'partTotal': partTotal,
        if (qualityLabel != null) 'qualityLabel': qualityLabel,
        if (codecLabel != null) 'codecLabel': codecLabel,
      };

  factory BiliMeta.fromJson(Map<String, dynamic> j) => BiliMeta(
        workTitle: j['workTitle'] as String?,
        partTitle: j['partTitle'] as String?,
        bvid: j['bvid'] as String?,
        aid: j['aid'] as String?,
        cid: j['cid'] as String?,
        partTotal: (j['partTotal'] as num?)?.toInt() ?? 1,
        qualityLabel: j['qualityLabel'] as String?,
        codecLabel: j['codecLabel'] as String?,
      );
}
