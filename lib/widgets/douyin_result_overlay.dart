import 'dart:math' show pi;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/media.dart';
import '../services/douyin_groups.dart';
import '../services/douyin_store.dart';
import '../theme/app_theme.dart';

/// 抖音「抓取结果」浮层的**跨层共享句柄**。
///
/// 浮层挂在**外壳层**（`app.dart` 里包住导航 `Row` 的那个 `Stack`），遮罩才盖得住
/// 左侧导航栏 —— 页面被 `ClipRect` + `Padding` 包住，浮层从页面内部**溢不出去**，
/// 只能盖到网页区（2026-10-12 用户原话：「不是覆盖在网页上，是覆盖在软件表面」）。
///
/// 但浮层要用的东西分居两侧，用这一个句柄接起来：
///   * [isOpen] —— 外壳层据此决定渲不渲染；
///   * [onEnqueue] / [enqueueing] —— 真正的入队逻辑与「下载进行中」标志**留在
///     页面里**（那里才有 toast 的 context 与 `setState`），由页面写进来。
class DouyinOverlayController extends ChangeNotifier {
  bool _open = false;

  /// 浮层是否展开。外壳层不缓存它，每帧都读这里 —— 页面点 ⤢ 时只改这一个值，
  /// 两侧不会各说各话。
  bool get isOpen => _open;

  void setOpen(bool v) {
    if (_open == v) return;
    _open = v;
    notifyListeners();
  }

  /// 页面注册进来的「下载选中」。页面销毁时置回 null。
  VoidCallback? onEnqueue;

  bool _enqueueing = false;

  /// 下载是否进行中（浮层按钮的禁用态与转圈）。
  bool get enqueueing => _enqueueing;

  void setEnqueueing(bool v) {
    if (_enqueueing == v) return;
    _enqueueing = v;
    notifyListeners();
  }
}

/// 「抓取结果」详情浮层。
///
/// 参照实现的批量下载列表是**一层盖在界面上的浮层**，不把内容挤窄
/// （2026-09-19 用户明确要求照这个做法）。一行一个作品，图文不平铺。
///
/// **为什么返回 `Positioned.fill`**：它铺满的是**自己所在的那个 Stack**，所以
/// 调用方必须把它放在期望的覆盖范围那一层的 `Stack` 里（见 `app.dart` 的注释）。
/// 自己只管「画出这一层」与「展开了哪些作品」，开关交回 [onClose]。
class DouyinResultOverlay extends StatefulWidget {
  const DouyinResultOverlay({
    super.key,
    required this.onClose,
    required this.enqueueing,
    required this.onEnqueue,
  });

  /// 关掉浮层 —— 点遮罩、点 ✕ 都走这里。
  final VoidCallback onClose;

  /// 下载进行中：底部那颗按钮的禁用态与转圈用它。
  final bool enqueueing;

  /// 真正触发下载。逻辑在页面里（`_enqueue`），这里只是调用方。
  final VoidCallback onEnqueue;

  @override
  State<DouyinResultOverlay> createState() => _DouyinResultOverlayState();
}

class _DouyinResultOverlayState extends State<DouyinResultOverlay> {
  /// 浮层里**展开看逐张图**的作品 id（参照实现也是一行一作品，点开才摊开）。
  ///
  /// 它只被浮层用到（右侧格子不逐个摊开），所以随浮层留在这里 ——
  /// 外壳层开关浮层时不该顺手把它清掉。
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final store = context.watch<DouyinStore>();
    final groups = store.awemeGroups;

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.42),
          child: Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              // 面板内的空白不该关掉浮层，这里把点击吃掉
              onTap: () {},
              child: Container(
                width: 560,
                margin: const EdgeInsets.fromLTRB(0, 14, 14, 14),
                decoration: BoxDecoration(
                  // **不能用 surfaceFloat** —— 它是 0xE0 半透明（给毛玻璃弹层设计的），
                  // 底下再叠一层黑遮罩，盖在抖音页面上就糊成一片（2026-09-19 反馈）。
                  color: c.surfaceSolid,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: c.line),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildPanelHeader(c, store, groups.length),
                    Divider(height: 1, color: c.lineSoft),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: groups.length,
                        itemBuilder: (context, i) =>
                            _buildGroupRow(c, store, groups[i]),
                      ),
                    ),
                    Divider(height: 1, color: c.lineSoft),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                      child: DouyinEnqueueButton(
                        store: store,
                        enqueueing: widget.enqueueing,
                        onPressed: widget.onEnqueue,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanelHeader(AppColors c, DouyinStore store, int n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Icon(Icons.auto_awesome_motion_rounded, size: 17, color: c.accent),
          const SizedBox(width: 8),
          Text(
            t('抓取结果'),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: c.textStrong,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            tf('{n} 个作品', {'n': n}),
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
          const Spacer(),
          Text(
            tf('已选 {n}', {'n': store.selectedCount}),
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
          IconButton(
            onPressed: widget.onClose,
            tooltip: t('收起'),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            color: c.textMuted,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  /// 一行 = 一个作品（对齐参照实现的列表）：勾选框 + 缩略图 + 类型标签 +
  /// 标题 + 点赞/评论/收藏/分享 + 话题 + 时间。点行可以摊开看逐张图。
  Widget _buildGroupRow(AppColors c, DouyinStore store, DouyinAwemeGroup g) {
    // 与右侧格子同一套三态判定，否则浮层里看着没勾、格子里看着勾了
    final sel = store.groupSelectionOf(g);
    final picked = sel != DouyinSelection.none;
    final open = _expanded.contains(g.awemeId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (open) {
              _expanded.remove(g.awemeId);
            } else {
              _expanded.add(g.awemeId);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 26,
                  height: 26,
                  child: Checkbox(
                    // null = 半选（横杠）：勾了图但同组还带着没勾的 BGM 视频时
                    value: switch (sel) {
                      DouyinSelection.all => true,
                      DouyinSelection.some => null,
                      DouyinSelection.none => false,
                    },
                    tristate: true,
                    activeColor: c.accent,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (_) => store.toggleGroup(g),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 88,
                  height: 110,
                  child: Container(
                    decoration: BoxDecoration(
                      color: c.surfaceSunken,
                      borderRadius: BorderRadius.circular(7),
                      // 勾了就描黄框，与右侧格子、抖音页面上的框同色同宽
                      border: Border.all(
                        color: picked ? kMarkYellow : c.lineSoft,
                        width: picked ? 2 : 1,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        DouyinCoverImage(url: g.coverUrl),
                        if (store.isGroupDownloaded(g))
                          const Positioned.fill(
                            child: DownloadedRibbon(scale: 1.7),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: TypeChip(c, t(g.typeLabel)),
                            ),
                            const WidgetSpan(child: SizedBox(width: 6)),
                            TextSpan(
                              text: g.title,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: c.textStrong,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),
                      StatRow(c, g: g),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              [
                                for (final t in g.tags.take(3)) t,
                                if (g.createdAt != null) _clock(g.createdAt!),
                              ].join('  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: c.textFaint,
                              ),
                            ),
                          ),
                          Icon(
                            open
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            size: 17,
                            color: c.textFaint,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // 摊开：逐条媒体 + 各自勾选（图文想单挑某几张时用）
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(41, 0, 12, 10),
            child: Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final m in g.items)
                  _MiniMediaTile(
                    c: c,
                    media: m,
                    checked: store.isSelected(m.id),
                    onTap: () => store.toggle(m.id),
                  ),
              ],
            ),
          ),
        Divider(height: 1, indent: 10, color: c.lineSoft.withValues(alpha: 0.5)),
      ],
    );
  }

  static String _clock(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

/// 详情浮层与右侧抓取面板**共用**的那颗下载按钮。
///
/// 两处都看得见它，所以状态只有一份（[enqueueing]）—— 否则浮层里转着圈、
/// 面板里还能再点一次。
class DouyinEnqueueButton extends StatelessWidget {
  const DouyinEnqueueButton({
    super.key,
    required this.store,
    required this.enqueueing,
    required this.onPressed,
  });

  final DouyinStore store;
  final bool enqueueing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final picked = store.selectedCount;
    final visible = store.visibleCount;
    final label = picked > 0
        ? '下载选中（$picked）'
        : (store.hasFilter ? '下载筛选结果（$visible）' : '下载全部（$visible）');

    return SizedBox(
      height: 36,
      child: FilledButton.icon(
        onPressed: visible == 0 || enqueueing ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: Colors.white,
          // 不给这两条，禁用时走主题默认的灰底灰字 —— 它是面板里唯一的终点
          // 动作，灰到和面板背景糊成一片，用户分不清是"没东西可下"还是"坏了"。
          disabledBackgroundColor: c.accent.withValues(alpha: 0.28),
          disabledForegroundColor: c.textMuted,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: enqueueing
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Colors.white),
                ),
              )
            : const Icon(Icons.download_rounded, size: 17),
        label: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 抖音封面图。**右侧格子与详情浮层共用**，所以是公开的顶层组件。
///
/// 抖音图片 CDN 会校验来源，必须带 Referer + UA 才给图。
class DouyinCoverImage extends StatelessWidget {
  const DouyinCoverImage({super.key, required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final u = url;
    if (u == null || u.isEmpty) {
      return Icon(Icons.image_outlined, size: 16, color: c.textFaint);
    }
    return Image.network(
      u,
      fit: BoxFit.cover,
      headers: const {
        'Referer': 'https://www.douyin.com/',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      },
      errorBuilder: (_, _, _) =>
          Icon(Icons.image_not_supported_outlined, size: 16, color: c.textFaint),
    );
  }
}

/// 「已下载」斜缎带 —— 台账是作品粒度，所以整条作品都带。
/// 样式：绿色底、-45° 斜跨左上角、文案「已下载」。
/// 靠**外层**的 `clipBehavior` 把溢出部分裁掉，正好裁成缎带。
///
/// 从 `douyin_page.dart` 搬来时由 `_DownloadedRibbon` 改成公开名：
/// 它要被浮层（另一个文件）引用，Dart 不允许跨文件引用下划线开头的名字。
class DownloadedRibbon extends StatelessWidget {
  const DownloadedRibbon({super.key, this.scale = 1});

  /// 缎带跟着缩略图尺寸走：侧边栏小格子用默认 1，浮层里的大缩略图用 1.7
  final double scale;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Stack(
      children: [
        Positioned(
          top: 8 * scale,
          left: -16 * scale,
          child: Transform.rotate(
            angle: -pi / 4,
            child: Container(
              width: 52 * scale,
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(vertical: 1 * scale),
              color: c.success,
              child: Text(
                t('已下载'),
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
}

/// 行首的「图文 9 图 / 视频 / 实况图文 3 图」小标签
class TypeChip extends StatelessWidget {
  const TypeChip(this.c, this.label, {super.key});

  final AppColors c;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.accentLine),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10.5, color: c.accent, height: 1.35),
      ),
    );
  }
}

/// 点赞 / 评论 / 收藏 / 分享 —— 参照实现列表里那四个数
class StatRow extends StatelessWidget {
  const StatRow(this.c, {required this.g, super.key});

  final AppColors c;
  final DouyinAwemeGroup g;

  @override
  Widget build(BuildContext context) {
    Widget one(IconData icon, int v) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: c.textFaint),
        const SizedBox(width: 3),
        Text('$v', style: TextStyle(fontSize: 11, color: c.textMuted)),
      ],
    );
    return Wrap(
      spacing: 12,
      runSpacing: 3,
      children: [
        one(Icons.favorite_border_rounded, g.likeCount),
        one(Icons.mode_comment_rounded, g.commentCount),
        one(Icons.star_outline_rounded, g.collectCount),
        one(Icons.share_outlined, g.shareCount),
      ],
    );
  }
}

/// 摊开一行后的单条媒体小方格：想只下其中几张图时用。
///
/// 只有浮层用到，所以随浮层搬来本文件（原先私有于 `douyin_page.dart`）。
class _MiniMediaTile extends StatelessWidget {
  const _MiniMediaTile({
    required this.c,
    required this.media,
    required this.checked,
    required this.onTap,
  });

  final AppColors c;
  final Media media;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 52,
        height: 62,
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: c.surfaceSunken,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: checked ? c.accent : c.lineSoft,
                    width: checked ? 1.5 : 0.8,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: (media.previewUrl ?? '').isEmpty
                    ? Icon(
                        media.type.isVideo
                            ? Icons.play_arrow_rounded
                            : Icons.photo_rounded,
                        size: 16,
                        color: c.textFaint,
                      )
                    : Image.network(
                        media.previewUrl!,
                        fit: BoxFit.cover,
                        headers: const {
                          'Referer': 'https://www.douyin.com/',
                          'User-Agent':
                              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                              '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
                        },
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.image_not_supported_outlined,
                          size: 16,
                          color: Colors.white54,
                        ),
                      ),
              ),
            ),
            Positioned(
              right: 2,
              top: 2,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: checked ? c.accent : Colors.black45,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: checked ? c.accent : Colors.white70,
                    width: 1,
                  ),
                ),
                child: checked
                    ? const Icon(
                        Icons.check_rounded,
                        size: 9,
                        color: Colors.white,
                      )
                    : null,
              ),
            ),
            Positioned(
              left: 3,
              bottom: 2,
              child: Text(
                media.type.isVideo ? '视频' : '${media.mediaIndex}',
                style: const TextStyle(
                  fontSize: 9,
                  color: Colors.white,
                  backgroundColor: Colors.black54,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
