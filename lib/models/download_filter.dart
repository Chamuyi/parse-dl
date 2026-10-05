import 'package:flutter/foundation.dart';

import 'media.dart';

/// 主页与自动执行共用的下载过滤器。
///
/// 覆盖：
///   - 日期范围（createdAt 区间）
///   - 媒体类型（视频 / 图片 / GIF）
///   - 下载源（tweets / medias）
class DownloadFilter {
  /// 起止时间（含）。两个 null 表示不限。
  final DateTime? dateFrom;
  final DateTime? dateTo;

  /// 允许的媒体类型。为空表示不限。
  final Set<MediaType> mediaTypes;

  /// 下载源。
  final DownloadSource source;

  const DownloadFilter({
    this.dateFrom,
    this.dateTo,
    this.mediaTypes = const {},
    this.source = DownloadSource.medias,
  });

  DownloadFilter copyWith({
    DateTime? dateFrom,
    DateTime? dateTo,
    Set<MediaType>? mediaTypes,
    DownloadSource? source,
    bool clearDateFrom = false,
    bool clearDateTo = false,
  }) {
    return DownloadFilter(
      dateFrom: clearDateFrom ? null : (dateFrom ?? this.dateFrom),
      dateTo: clearDateTo ? null : (dateTo ?? this.dateTo),
      mediaTypes: mediaTypes ?? this.mediaTypes,
      source: source ?? this.source,
    );
  }

  /// 与给定的 Media 比较，返回是否「应该下载」。
  bool accepts(Media m) {
    if (mediaTypes.isNotEmpty && !mediaTypes.contains(m.type)) return false;

    if (dateFrom != null && m.createdAt != null && m.createdAt!.isBefore(dateFrom!)) {
      return false;
    }
    if (dateTo != null && m.createdAt != null && m.createdAt!.isAfter(dateTo!)) {
      return false;
    }
    return true;
  }

  /// 是否已经翻过了日期下界 —— 到达即应**停止继续翻页**。
  ///
  /// 这是原版 `runCreationTask` 里
  /// `while (nextCursor !== null && now.isAfter(since))` 的判据（`now` 是
  /// 本页最旧一条推文的时间）。**注意它依赖 `createdAt` 能解析出来** ——
  /// 日期解析坏掉的那段时间，翻页会退化成「一路拉到底」。
  ///
  /// [oldestSeen] 为 null（整页都没有时间）时返回 false，即继续翻。
  bool reachedDateFloor(DateTime? oldestSeen) {
    if (dateFrom == null || oldestSeen == null) return false;
    return !oldestSeen.isAfter(dateFrom!);
  }

  Map<String, dynamic> toJson() => {
        'dateFrom': dateFrom?.toIso8601String(),
        'dateTo': dateTo?.toIso8601String(),
        'mediaTypes': mediaTypes.map((t) => t.name).toList(),
        'source': source.name,
      };

  static DownloadFilter fromJson(Map<String, dynamic> json) {
    return DownloadFilter(
      dateFrom: json['dateFrom'] is String
          ? DateTime.tryParse(json['dateFrom'] as String)
          : null,
      dateTo: json['dateTo'] is String
          ? DateTime.tryParse(json['dateTo'] as String)
          : null,
      mediaTypes: (json['mediaTypes'] as List?)
              ?.map((s) => MediaType.values.firstWhere(
                    (t) => t.name == s,
                    orElse: () => MediaType.image,
                  ))
              .toSet() ??
          const {},
      source: DownloadSource.values.firstWhere(
        (s) => s.name == json['source'],
        orElse: () => DownloadSource.medias,
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DownloadFilter &&
        other.dateFrom == dateFrom &&
        other.dateTo == dateTo &&
        other.source == source &&
        setEquals(other.mediaTypes, mediaTypes);
  }

  @override
  int get hashCode => Object.hash(
        dateFrom,
        dateTo,
        source,
        Object.hashAllUnordered(mediaTypes.map((t) => t.name)),
      );
}

enum DownloadSource {
  /// 走 UserMedia 的 timeline 接口（可拿到完整推文元数据，旧推文可能被截断）
  tweets,

  /// 走 UserMedia 解析后的 media 列表（速度更快，但更老推文可能拿不到）
  medias,
}