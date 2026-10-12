import 'package:flutter/material.dart';

import '../models/media.dart';
import '../theme/app_theme.dart';

/// 统一媒体缩略图 —— 抓取结果 / 分P列表 / 媒体网格共用。
///
/// 为什么要有它：三处都要画同一件事（封面 + 角标 + 「已下载」缎带），
/// 各画一遍迟早会漂（抖音那边已经有一份 `_coverImage` 与 `_DownloadedRibbon`）。
/// 这个组件把那套观感收在一处，新页面直接用。
///
/// **它只管画，不管业务**：选中态的黄框由调用方通过 [selected] 传入
/// （色值必须是 [kMarkYellow]，与注入脚本画在抖音页面上的框同色 —— 用户
/// 就是靠"两边一样的框"确认"列表里这条 = 页面上那条"）。
class MediaThumb extends StatelessWidget {
  const MediaThumb({
    super.key,
    required this.media,
    this.width = 88,
    this.height = 50,
    this.radius = 7,
    this.selected = false,
    this.downloaded = false,
    this.showDuration = true,
    this.showCount = true,
    this.ribbonScale = 1,
    this.placeholderIcon,
  });

  final Media media;
  final double width;
  final double height;
  final double radius;

  /// 选中态：描一圈 [kMarkYellow]。
  final bool selected;

  /// 已下载：盖一条斜缎带。
  final bool downloaded;

  /// 视频显示时长角标（`mm:ss` / `h:mm:ss`）。
  final bool showDuration;

  /// 图文显示张数角标。
  final bool showCount;

  /// 缎带缩放（浮层里用大图时要跟着放大）。
  final double ribbonScale;

  /// 无封面时画的图标；不传就画一个中性的占位块。
  final IconData? placeholderIcon;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final url = media.previewUrl ?? '';
    final dur = _clock(media.durationMs);
    final isVideo = media.type == MediaType.video;

    return SizedBox(
      width: width,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: c.surfaceSunken,
          borderRadius: BorderRadius.circular(radius),
          // 勾了就描黄框，与注入脚本画在页面上的框同色同宽
          border: Border.all(
            color: selected ? kMarkYellow : c.lineSoft,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url.isEmpty)
              Center(
                child: Icon(
                  placeholderIcon ??
                      (isVideo
                          ? Icons.play_circle_outline_rounded
                          : Icons.image_outlined),
                  size: height * .42,
                  color: c.textFaint,
                ),
              )
            else
              _networkImage(url, c),

            // 右下角：视频给时长、图文给张数
            if (isVideo && showDuration && dur.isNotEmpty)
              _badge(c, dur, Alignment.bottomRight)
            else if (!isVideo && showCount && media.mediaIndex > 0)
              _badge(c, '${media.mediaIndex}', Alignment.bottomRight),

            if (downloaded) _Ribbon(scale: ribbonScale, c: c),
          ],
        ),
      ),
    );
  }

  /// 封面加载失败时退回占位图标 —— 不让一处 404 变成一片破图。
  Widget _networkImage(String url, AppColors c) => Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Center(
          child: Icon(Icons.broken_image_outlined,
              size: height * .38, color: c.textFaint),
        ),
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : ColoredBox(color: c.surfaceSunken),
      );

  Widget _badge(AppColors c, String text, Alignment align) => Align(
        alignment: align,
        child: Container(
          margin: const EdgeInsets.all(3),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .66),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 9,
              color: Colors.white,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        ),
      );

  /// `mm:ss` / `h:mm:ss`；拿不到时长回空串（不画「0:00」那种假数字）。
  static String _clock(int? ms) {
    final s = (ms ?? 0) ~/ 1000;
    if (s <= 0) return '';
    String p2(int v) => v.toString().padLeft(2, '0');
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return h > 0 ? '$h:${p2(m)}:${p2(sec)}' : '$m:${p2(sec)}';
  }
}

/// 「已下载」斜缎带（-45°）。
///
/// 与 `douyin_page.dart` 里那份 `_DownloadedRibbon` 同一画法 —— 尺寸按
/// [scale] 缩放，小格子用 1、浮层大图用 1.7。
class _Ribbon extends StatelessWidget {
  const _Ribbon({required this.scale, required this.c});

  final double scale;
  final AppColors c;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          Positioned(
            top: 8 * scale,
            left: -16 * scale,
            child: Transform.rotate(
              angle: -0.7853981633974483, // -pi/4
              child: Container(
                width: 52 * scale,
                alignment: Alignment.center,
                padding: EdgeInsets.symmetric(vertical: 1 * scale),
                color: c.success,
                child: Text(
                  '已下载',
                  style: TextStyle(
                    fontSize: 8 * scale,
                    color: c.onSuccess,
                    height: 1.15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
}
