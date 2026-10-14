import 'package:flutter/material.dart';

import '../theme/app_style.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';

/// 预览稿的**三列快捷卡** —— `.quick .qc` 的 Flutter 对应物。
///
/// 设计稿 §2.4 总览页「快捷开始」：6 个入口排两行三列，每张是
/// 「图标块 + 标题 + 副题 + 右侧箭头」。
///
/// ### 规格出处（`tools/ui/_redesign/preview/app.css`）
///
/// ```
/// :764 .quick { display:grid; grid-template-columns:repeat(3,1fr); gap:10px; }
/// :766 .qc  { display:flex; align-items:center; gap:11px; padding:13px 14px;
///              border-radius:12px; cursor:pointer; }
/// :769 .qc .ic { width:34px; height:34px; border-radius:10px; flex:none;
///                 display:grid; place-items:center; font-size:15px; font-weight:700; }
/// :773 .qc .tx { flex:1; min-width:0; }
/// :774 .qc .tx b    { font-size:13px; font-weight:600; display:block; }
/// :775 .qc .tx small{ font-size:10.5px; opacity:.5; }
/// :776 .qc .go { opacity:.3; font-size:13px; flex:none; }
/// ```
///
/// 图标块底色 `c.accentSoft` + 图标色 `c.accent` —— 预览稿写的是
/// `var(--accent-soft)` / `var(--ac)`（`index.html:263`），两个槽位
/// [AppColors] 都有，不必写死。
class QuickGrid extends StatelessWidget {
  final List<QuickCell> cells;

  const QuickGrid({super.key, required this.cells});

  @override
  Widget build(BuildContext context) {
    return GridView(
      // 嵌在页面滚动容器里：快捷卡是「两行三列」的固定网格，外层滚动。
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      // **高度固定，不按宽高比**（2026-10-15 修，与 [OptGrid] 同一处问题）。
      //
      // 原来用 `childAspectRatio: 1.6` —— 按栏宽算高度：格子宽 180 时高 112，
      // 比内容（图标块 34 + 上下 padding 26 = 60）高出一大截，真机上表现为
      // 卡片里大片留白、副题被挤成省略号。改成固定 `mainAxisExtent` 后，
      // 高度与栏宽解耦。
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        // 高度按**较高的一侧**取：图标块 34 与「标题 17 + 1 + 副题两行 28」
        // 里的 46，加下上 padding 26 → 72。实测 74 仍溢出 2px（中文行高比
        // 估算的略大），给到 78。
        mainAxisExtent: 78,
      ),
      children: [for (final cell in cells) _QuickTile(cell: cell)],
    );
  }
}

class QuickCell {
  final IconData icon;

  /// 卡片标题。已 `t()` 过。
  final String title;

  /// 副题。已 `t()` 过。
  final String sub;

  final VoidCallback? onTap;

  const QuickCell({
    required this.icon,
    required this.title,
    required this.sub,
    this.onTap,
  });
}

class _QuickTile extends StatelessWidget {
  final QuickCell cell;

  const _QuickTile({required this.cell});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    final card = AppCard(
      // `.qc` 圆角 12，与 `.stat` / `.hero2` 同档（CSS `:805`）
      radius: AppRadius.hero2,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(cell.icon, size: 17, color: c.accent),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cell.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.textStrong,
                  ),
                ),
                const SizedBox(height: 1),
                // 副题**允许换行**（最多两行）—— 预览稿 `app.css:775` 的
                // `.qc .tx small` 既没有 `nowrap` 也没有 `ellipsis`，就是
                // 自然换行；原来这里写死 `maxLines: 1 + ellipsis`，真机上
                // 「输入用户 ID 批量下载」被截成「输入用户 ID...」，与预览稿
                // 不符（2026-10-15 真机对照发现）。两行放不下时仍省略，
                // 不至于把格子顶破。
                Text(
                  cell.sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.35,
                    color: c.textMuted.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // CSS `:776` `.qc .go { opacity:.3; font-size:13px }` 是字符 ›；
          // 这里用 Material 箭头，同一个「可进入」的语义。
          Icon(Icons.chevron_right_rounded,
              size: 16, color: c.textMuted.withValues(alpha: 0.3)),
        ],
      ),
    );

    if (cell.onTap == null) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: cell.onTap, child: card),
    );
  }
}
