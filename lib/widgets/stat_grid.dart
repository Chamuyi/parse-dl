import 'package:flutter/material.dart';

import '../theme/app_style.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';

/// 预览稿的**四格统计块** —— `.stats .stat` 的 Flutter 对应物。
///
/// 设计稿 §2.4 总览页第 ② 段：进行中 / 已完成 / 下载台账 / 磁盘占用，
/// 24px 大数字 + 单位 + 小注，四张卡等高并排。
///
/// ### 规格出处（`tools/ui/_redesign/preview/app.css`）
///
/// ```
/// :756 .stats { display:grid; grid-template-columns:repeat(4,1fr); gap:10px; flex:none; }
/// :757 .stat  { padding:13px 15px; border-radius:12px; }
/// :758 .stat .k { font-size:11px; opacity:.55; margin-bottom:5px;
///                  display:flex; align-items:center; gap:5px; }
/// :759 .stat .v { font-size:24px; font-weight:680; font-variant-numeric:tabular-nums;
///                  line-height:1.1; }
/// :760 .stat .v small { font-size:12px; font-weight:400; opacity:.5; margin-left:3px; }
/// :761 .stat .sub { font-size:10.5px; opacity:.45; margin-top:3px; }
/// ```
///
/// ### 为什么用 GridView 而不是四个 Expanded
///
/// **四张卡必须等高**。`Row(crossAxisAlignment: stretch)` 需要父级给有限
/// 高度，而 `ListView` 给的是无限 —— 直接写会当场抛「BoxConstraints forces
/// an infinite height」。`IntrinsicHeight` 包一层能解，但代价是先量一遍最高
/// 那张再把高度下发（`dashboard_page.dart:117-121` 现在正是这么绕的）。
/// Grid 的行高是布局引擎自己算的，四格天生等高，且 `childAspectRatio` 保证
/// 数字从 1 位涨到 4 位时格子不会被撑开。本组件放进 `ListView` 也是安全的
/// —— 见 [build] 里 `shrinkWrap` 的注释。
class StatGrid extends StatelessWidget {
  /// 四格数据，按渲染顺序排。调用方 `t()` 后传入。
  final List<StatCell> cells;

  const StatGrid({super.key, required this.cells});

  @override
  Widget build(BuildContext context) {
    return GridView(
      // 嵌在页面滚动容器（ListView / Column）里，不能自己滚 —— 外层负
      // 责滚动，否则同一方向上两个滚动视图会抢手势。
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      // **高度固定，不按宽高比**（2026-10-15 修，与 [OptGrid] / [QuickGrid]
      // 同一处问题）。原来 `childAspectRatio: 2.0` 按栏宽算高度：整页宽
      // （约 980px）下每格 245，高 122 —— 比内容（k 行 16 + 5 + 数字行 26 +
      // 3 + sub 行 14 + 上下 padding 26 ≈ 90）高出 30 多像素，四格显得空。
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        // 内容实测约 93px（含 sub 小注那格：k 行 16 + 5 + 数字行 26 + 3 +
        // sub 行 14 + 上下 padding 26 = 90，加上文字行高取整到 93）；
        // 给 96 留 3px 余量。曾按 92 设过，实测溢出 1px（判据当场报红）。
        mainAxisExtent: 96,
      ),
      children: [for (final cell in cells) _StatTile(cell: cell)],
    );
  }
}

/// 一格统计。[value] 与 [unit] 会被拼在一行里（CSS `.v small` 同排）。
class StatCell {
  /// 键名（如「下载台账」）。已 `t()` 过。
  final String key;

  final IconData? icon;

  /// 大数字本体（如 '2' / '1.8'）。不进 l10n —— 数字没有语言变体，
  /// 而千分位格式化是调用方的事（十进制分隔符随地区变）。
  final String value;

  /// 单位（如 '个' / 'GB'）。空串 = 不渲染。已 `t()` 过。
  final String unit;

  /// 小注（如 '今天 +3'）。null = 不渲染。已 `t()` 过。
  final String? sub;

  const StatCell({
    required this.key,
    required this.value,
    this.unit = '',
    this.sub,
    this.icon,
  });
}

class _StatTile extends StatelessWidget {
  final StatCell cell;

  const _StatTile({required this.cell});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final sub = cell.sub;
    final unit = cell.unit;
    final icon = cell.icon;

    return AppCard(
      // `.stat` 在 CSS `:804-806` 与 `.hero2` 同一档圆角
      radius: AppRadius.hero2,
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 12, color: c.textMuted.withValues(alpha: 0.55)),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  cell.key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: c.textMuted.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          // tabular-nums：数字等宽，四格并排时上下数字的小数点才对得齐。
          Text.rich(
            TextSpan(
              style: TextStyle(
                fontSize: 24,
                // CSS `.v` 是 680，向下取整百（与 opt_grid 同一规则）
                fontWeight: FontWeight.w600,
                color: c.textStrong,
                height: 1.1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              children: [
                TextSpan(text: cell.value),
                if (unit.isNotEmpty)
                  TextSpan(
                    text: unit,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: c.textMuted.withValues(alpha: 0.5),
                    ),
                  ),
              ],
            ),
          ),
          if (sub != null && sub.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: c.textMuted.withValues(alpha: 0.45),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
