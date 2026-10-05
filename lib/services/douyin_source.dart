/// 下载源解析 —— 「6 个下载源 + 4 档质量优先策略」的 Dart 实现。
///
/// 视频变体的综合得分由三个分量加权求和，权重见 [kDouyinQualityWeights]：
///
///   * **分辨率分量** —— 以 100 万像素为基准开平方，正好 1 倍基准得 50 分，
///     向上封顶 100。用开平方而不是线性，是为了让 4K 不至于把 1080p 拉开两倍。
///   * **帧率分量** —— 分段线性，拐点在 24 帧与 60 帧：24 帧以下每帧计 2 分，
///     24~60 帧区段每帧加 1.4 分，60 帧以上每帧只加 0.1 分（高帧率的边际收益递减）。
///   * **码率分量** —— 先按 √(宽×高) 归一化再折算，所以「小图配高码率」不会
///     被误判成高质量。
///
/// **三个容易被读错的口径（本项目的既定行为，都有测试钉着）：**
///   1. `auto` 档**不是** 0.7/0.2/0.1 的变体，而是 0.4/0.4/0.2 —— 只看
///      三个专项档会漏掉它。
///   2. 评分前置检查「宽 / 高 / 帧率 / 码率 四项任一 ≤ 0 → 直接判 0 分」**对
///      `auto` 也生效**，所以缺少帧率字段的变体会被排到最后（哪怕它分辨率最高）。
///   3. 评分候选集只从 `bit_rate[]` 里取，且**只保留 mp4 格式**；指定
///      H.264 / H.265 时走的是**另一个字段**，不参与评分。
library;

import 'dart:math' as math;

import '../models/douyin_config.dart';
import '../models/media.dart';
import '../models/media_variant.dart';

/// 分量之一：分辨率。以 100 万像素为基准开平方，1 倍 → 50 分，封顶 100。
double resolutionScore(int width, int height) {
  if (width <= 0 || height <= 0) return 0;
  return _cap(_sqrt(width * height / 1000000) * 50);
}

/// 分量之二：帧率。24 帧以下每帧 2 分；24~60 每帧 +1.4；60 以上每帧 +0.1。
double fpsScore(int fps) {
  if (fps <= 0) return 0;
  if (fps <= 24) return fps * 2;
  if (fps <= 60) return 48 + (fps - 24) * 1.4;
  return _cap(98 + (fps - 60) * 0.1);
}

/// 分量之三：码率。**按像素量归一化** —— 1080×1920 的 2.4 Mbps 与
/// 720×1280 的 1 Mbps 得分可以不同，避免「小图高码率」被误判成高质量。
double bitrateScore(int bitrate, int width, int height) {
  if (bitrate <= 0 || width <= 0 || height <= 0) return 0;
  final scale = _sqrt((width * height).toDouble()) * 0.15;
  if (scale <= 0) return 0;
  return _cap(bitrate / 1000 / scale * 60);
}

double _cap(double v) => v > 100 ? 100 : v;

/// 各档权重，顺序固定为 `(分辨率, 帧率, 码率)`。
///
/// **`auto` 不是"三档专项"的变体**，它自己是一组 0.4 / 0.2 / 0.4 ——
/// 只看专项档会漏掉这一档。权重是实测调过的经验值，重设等于从零调参，
/// 收益不明还会动下载失败率。
const Map<DouyinQualityMode, (double res, double fps, double bit)>
    kDouyinQualityWeights = {
  DouyinQualityMode.auto: (0.4, 0.2, 0.4),
  DouyinQualityMode.resolution: (0.7, 0.1, 0.2),
  DouyinQualityMode.fps: (0.2, 0.7, 0.1),
  DouyinQualityMode.bitrate: (0.2, 0.1, 0.7),
};

/// 单个变体的综合得分。[mode] 为 `auto` 时用 0.4/0.4/0.2，其余按主项 0.7。
///
/// **四项任一为 0 就返回 0**（见文件头「口径 2」）。
double variantScore(MediaVariant v, DouyinQualityMode mode) {
  if (v.width <= 0 || v.height <= 0 || v.fps <= 0 || v.bitrate <= 0) return 0;
  final (wRes, wFps, wBit) = kDouyinQualityWeights[mode]!;
  return _round1(
    wRes * resolutionScore(v.width, v.height) +
        wFps * fpsScore(v.fps) +
        wBit * bitrateScore(v.bitrate, v.width, v.height),
  );
}

/// 候选集过滤 + 按得分降序。
///
/// 过滤链：`去空 → 去不可用 → 只要 mp4 → (可选)非 low 档 → (可选)非 ByteVC1`。
///
/// 排序**稳定**：得分相同时保持原顺序（Dart 的 `List.sort` 不稳定，
/// 所以这里显式带下标做 tiebreak）。
List<MediaVariant> rankVideoVariants(
  List<MediaVariant> variants, {
  DouyinQualityMode mode = DouyinQualityMode.auto,
  bool filterLowQuality = false,
  bool filterByteVc1 = false,
}) {
  final indexed = <(int, MediaVariant)>[];
  for (var i = 0; i < variants.length; i++) {
    final v = variants[i];
    if (!v.usable) continue;
    if (v.format.toLowerCase() != 'mp4') continue;
    if (filterLowQuality && v.gearName.toLowerCase().contains('low')) continue;
    if (filterByteVc1 && v.isByteVc1) continue;
    indexed.add((i, v));
  }
  indexed.sort((a, b) {
    final sa = variantScore(a.$2, mode);
    final sb = variantScore(b.$2, mode);
    if (sa != sb) return sb.compareTo(sa);
    return a.$1.compareTo(b.$1);
  });
  return indexed.map((e) => e.$2).toList(growable: false);
}

/// 按配置挑出这条媒体**该用哪些地址下载**，返回「已解析」的媒体副本。
///
/// 解析规则（按配置项决定取哪个字段的候选地址）：
///
/// | [DouyinConfig.source] | 取哪个字段 |
/// |---|---|
/// | `defaultAddr` / `h264` / `h265` | 对应 `kind` 的变体，**不评分** |
/// | `qualityFirst` | `bit_rate[]` 评分第一名，**排除 ByteVC1** |
/// | `qualityFirstBytevc1` | `bit_rate[]` 评分第一名，**不排除 ByteVC1** |
/// | `audioOnly` | 该作品的 **BGM**（`music.play_url`），不是抽音轨 |
///
/// 图文作品只按 [DouyinConfig.imageFormat] 重排镜像顺序（**不改 URL** ——
/// jpg 优先就是这么实现的；早前那种「把 `.webp` 改成
/// `.jpeg`」的写法有被 CDN 路径校验拦掉的风险，已废弃）。
Media resolveDouyinMedia(Media m, DouyinConfig cfg) {
  if (m.source != 'douyin') return m;

  if (m.type.isImage) return _resolveImage(m, cfg);

  if (m.type.isAudio) {
    return _apply(m, _urlsOfKind(m, VariantKind.audio), null);
  }

  // ── 视频 ────────────────────────────────────────────────
  if (cfg.source == DouyinSource.audioOnly) {
    final audio = _urlsOfKind(m, VariantKind.audio);
    if (audio.isNotEmpty) {
      // 换成音频：类型、扩展名、候选地址都要跟着换
      return _apply(
        m.copyWith(type: MediaType.audio),
        audio,
        _firstVariantOfKind(m, VariantKind.audio),
      );
    }
    // 没有 BGM 可换时**保留视频**而不是产出空任务 ——
    // 直接换成音频列表会拿到空数组、该条目失败，对用户没有价值。
  }

  final byKind = _urlsOfKind(m, switch (cfg.source) {
    DouyinSource.h264 => VariantKind.h264,
    DouyinSource.h265 => VariantKind.h265,
    DouyinSource.qualityFirst || DouyinSource.qualityFirstBytevc1 =>
      VariantKind.bitRate,
    _ => VariantKind.defaultAddr,
  });

  if (cfg.source.needsQualityMode) {
    final ranked = rankVideoVariants(
      m.variants,
      mode: cfg.qualityMode,
      filterLowQuality: cfg.filterLowQuality,
      // 「兼容性+质量优先」这一档**强制**排除 ByteVC1；用户手动勾选也排除
      filterByteVc1: cfg.source == DouyinSource.qualityFirst || cfg.filterByteVc1,
    );
    if (ranked.isNotEmpty) {
      return _apply(m, ranked.first.urls, ranked.first);
    }
    // 评分候选为空（缺 bit_rate）时退回该档位的直接字段，再退回已有候选
    if (byKind.isNotEmpty) return _apply(m, byKind, null);
    return m;
  }

  if (byKind.isNotEmpty) {
    return _apply(m, byKind, _firstVariantOfKind(m, _kindOf(cfg.source)));
  }

  // 指定字段缺失（如没有 play_addr_h264）时**不要产出空任务**：
  // 退回已有的候选地址，保证「能下到东西」优先于「严格按源」。
  return _apply(m, m.downloadCandidates, m.chosen);
}

/// 把挑好的地址写回媒体：首个当主地址，其余当换源备用。
Media _apply(Media m, List<String> urls, MediaVariant? chosen) {
  final clean = <String>[];
  for (final u in urls) {
    if (u.isNotEmpty && !clean.contains(u)) clean.add(u);
  }
  if (clean.isEmpty) return m;
  return m.copyWith(
    url: clean.first,
    altUrls: clean.length > 1 ? clean.sublist(1) : const <String>[],
    chosen: chosen,
  );
}

/// 图文：按图片格式偏好**重排镜像顺序**（不动 URL 本身）。
///
/// 默认档保持抖音下发的原顺序；「其它格式优先（jpg）」把 `.webp` 的镜像
/// 挪到最后 —— 判定看去掉 query 之后的路径后缀，稳定排序保持其余顺序。
Media _resolveImage(Media m, DouyinConfig cfg) {
  var urls = m.downloadCandidates;
  if (urls.isEmpty) return m;

  if (cfg.imageFormat == DouyinImageFormat.jpgFirst) {
    final stable = <(int, String)>[];
    for (var i = 0; i < urls.length; i++) {
      stable.add((i, urls[i]));
    }
    stable.sort((a, b) {
      final wa = _isWebp(a.$2) ? 1 : 0;
      final wb = _isWebp(b.$2) ? 1 : 0;
      if (wa != wb) return wa.compareTo(wb);
      return a.$1.compareTo(b.$1);
    });
    urls = stable.map((e) => e.$2).toList(growable: false);
  }

  return m.copyWith(
    url: urls.first,
    altUrls: urls.length > 1 ? urls.sublist(1) : const <String>[],
    chosen: m.variants.isEmpty ? null : m.variants.first,
  );
}

bool _isWebp(String url) =>
    url.split('?').first.toLowerCase().endsWith('.webp');

List<String> _urlsOfKind(Media m, VariantKind kind) {
  final out = <String>[];
  for (final v in m.variants) {
    if (v.kind != kind) continue;
    for (final u in v.urls) {
      if (u.isNotEmpty && !out.contains(u)) out.add(u);
    }
  }
  return out;
}

MediaVariant? _firstVariantOfKind(Media m, VariantKind kind) {
  for (final v in m.variants) {
    if (v.kind == kind && v.usable) return v;
  }
  return null;
}

VariantKind _kindOf(DouyinSource s) => switch (s) {
      DouyinSource.h264 => VariantKind.h264,
      DouyinSource.h265 => VariantKind.h265,
      _ => VariantKind.defaultAddr,
    };

// ── 小工具 ────────────────────────────────────────────────

double _sqrt(double x) => x <= 0 ? 0 : math.sqrt(x);

double _round1(double v) => (v * 10).roundToDouble() / 10;
