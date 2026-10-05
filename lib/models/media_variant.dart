/// 一个「可选下载源」——同一条媒体在抖音上的某个具体码率 / 编码 / CDN 节点组合。
///
/// **为什么要有这一层：** 清晰度设置（6 个下载源 + 4 档质量优先策略）
/// 本质上是在「一条视频的多个 `bit_rate` 条目」里挑一个。所以媒体在**抓取时**
/// 必须把全部变体都留下来，**下载时**才按用户当前设置挑 ——
/// 否则用户改了清晰度设置，已经抓到的条目不会跟着变（参照实现也是这么分的）。
///
/// 变体与本体的关系：
///   - [urls] 是**同一变体的多个镜像地址**（不同 CDN 节点），依次尝试用。
///   - 一条视频通常有 3~6 个变体（不同分辨率 / 编码），每个变体 1~4 条镜像。
///
/// X 的媒体没有这个概念（只有一个直链），`Media.variants` 为空即可。
library;

/// 变体的来源种类，取值对应抖音响应里 `video` 下的各个地址字段。
enum VariantKind {
  /// `video.bit_rate[]` 里的条目 —— 带完整质量属性，质量优先策略只在这些里挑
  bitRate,

  /// `video.play_addr` —— 默认播放地址（不一定出现在 bit_rate 里）
  defaultAddr,

  /// `video.play_addr_h264` —— 指定 H.264
  h264,

  /// `video.play_addr_265` —— 指定 H.265
  h265,

  /// `video.download_addr` —— 官方下载地址
  download,

  /// `music.play_url` —— 音频（BGM / 仅音频模式）
  audio,

  /// 图集的一张图（镜像列表）
  image;

  static VariantKind fromId(String? id) => switch (id) {
        'bit_rate' => VariantKind.bitRate,
        'default' => VariantKind.defaultAddr,
        'h264' => VariantKind.h264,
        'h265' => VariantKind.h265,
        'download' => VariantKind.download,
        'audio' => VariantKind.audio,
        'image' => VariantKind.image,
        _ => VariantKind.defaultAddr,
      };

  String get id => switch (this) {
        VariantKind.bitRate => 'bit_rate',
        VariantKind.defaultAddr => 'default',
        VariantKind.h264 => 'h264',
        VariantKind.h265 => 'h265',
        VariantKind.download => 'download',
        VariantKind.audio => 'audio',
        VariantKind.image => 'image',
      };
}

/// 一个具体下载源。
class MediaVariant {
  /// 该变体的镜像地址列表（已去重、已转 https），**顺序即尝试顺序**。
  final List<String> urls;

  final VariantKind kind;

  /// 视频/图片的像素尺寸（0 表示未知）
  final int width;
  final int height;

  /// 帧率（0 表示未知）
  final int fps;

  /// 码率，单位 **bps**（`bit_rate` 字段就是这个单位）
  final int bitrate;

  /// 文件字节数（`play_addr.data_size`，0 表示未知）
  final int dataSize;

  /// 容器格式，通常 `mp4`
  final String format;

  /// 档位名，如 `low_720p` / `normal_1080p` / `higher_1080p`。
  /// 参照实现的「滤掉低画质」就是匹配它是否包含 `low`。
  final String gearName;

  /// ByteVC1（H.266/AV1 一路的抖音自有编码），兼容性差。
  /// 「兼容性+质量优先」策略会把它们排除掉。
  final bool isByteVc1;

  const MediaVariant({
    required this.urls,
    required this.kind,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.bitrate = 0,
    this.dataSize = 0,
    this.format = 'mp4',
    this.gearName = '',
    this.isByteVc1 = false,
  });

  bool get usable => urls.isNotEmpty;

  /// 像素总数 —— 分辨率评分的输入
  int get pixels => width > 0 && height > 0 ? width * height : 0;

  /// 推导扩展名（不带点）：`format` 为空或 `dash` 时按末位地址猜，最后退回 mp4。
  String get extension {
    var f = format.trim().replaceFirst(RegExp(r'^\.'), '').toLowerCase();
    if (f.isEmpty || f == 'dash') {
      f = '';
      for (final u in urls) {
        final ext = _extFromUrl(u);
        if (ext.isNotEmpty) {
          f = ext;
          break;
        }
      }
    }
    return f.isEmpty ? 'mp4' : f;
  }

  static String _extFromUrl(String url) {
    final path = url.split('?').first;
    final m = RegExp(r'\.([^./?#]+)$').firstMatch(path);
    return m == null ? '' : m.group(1)!.toLowerCase();
  }

  /// 复制并覆盖 —— 解析器把多个来源合并成同一变体时用。
  MediaVariant copyWith({List<String>? urls, bool? isByteVc1}) => MediaVariant(
        urls: urls ?? this.urls,
        kind: kind,
        width: width,
        height: height,
        fps: fps,
        bitrate: bitrate,
        dataSize: dataSize,
        format: format,
        gearName: gearName,
        isByteVc1: isByteVc1 ?? this.isByteVc1,
      );

  factory MediaVariant.fromJson(Map<String, dynamic> j) => MediaVariant(
        urls: ((j['urls'] as List?) ?? const [])
            .map((e) => e?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList(growable: false),
        kind: VariantKind.fromId(j['kind'] as String?),
        width: _i(j['w']),
        height: _i(j['h']),
        fps: _i(j['fps']),
        bitrate: _i(j['br']),
        dataSize: _i(j['size']),
        format: (j['format'] as String?) ?? 'mp4',
        gearName: (j['gear'] as String?) ?? '',
        isByteVc1: j['bytevc1'] == true,
      );

  Map<String, dynamic> toJson() => {
        'urls': urls,
        'kind': kind.id,
        'w': width,
        'h': height,
        'fps': fps,
        'br': bitrate,
        'size': dataSize,
        'format': format,
        'gear': gearName,
        'bytevc1': isByteVc1,
      };

  static int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}
