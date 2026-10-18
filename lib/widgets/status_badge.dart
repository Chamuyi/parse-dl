import 'package:flutter/material.dart';

import '../theme/app_style.dart';
import '../theme/app_theme.dart';

/// 预览稿的**胶囊徽章** —— `.st2` 的 Flutter 对应物。
///
/// 四处配色必须走 [AppColors] 既有槽位，**不许写十六进制色值字面量**：色板
/// 棘轮（`test/visual_tokens_test.dart`）盯着 `lib/theme/` 之外硬编码的颜色
/// 构造调用，新写一处就红。
///
/// ### 规格出处（`tools/ui/_redesign/preview/app.css`）
///
/// ```
/// :201 .st2 { font-size:10px; font-weight:700; padding:2px 8px; border-radius:999px; }
/// ```
/// 配色按三套浅色（`:309-312` liquid / `:377-380` frosted / `:442-445` clay）
/// 与三套深色（`:874-877` / `:917-920` / `:965-969`）。
///
/// ### 浅色 vs 深色：两套取值，如实计入
///
/// | 槽位 | 浅色（CSS） | 深色（CSS） |
/// |---|---|---|
/// | done 底 | `.14`–`.15` 绿 | `.15`–`.16` 亮绿 |
/// | done 字 | `#0f7a38` / `#15803d` | `#7BE8A8` |
/// | run 底 | `.13`–`.15` 蓝 | `.17`–`.18` 亮蓝 |
/// | run 字 | `var(--ac)` | `#57B9FF` / `#A5B3FF` |
/// | wait 底 | `.06`–`.07` 灰 | `.08` 灰 |
/// | err 底 | `.13`–`.14` 红 | `.15`–`.16` 亮红 |
/// | err 字 | `#c0392b` / `#9a3412` | `#FF9B9B` |
///
/// **Flutter 侧不分风格、只分明暗**：三套风格的同一状态色相互差 ≤2%
/// （可逐条对上面三组行号），而色板 [AppColors.light] / [AppColors.dark]
/// 本身就是按明暗分的两套槽位。所以这里用
/// `AppTheme.of(context).brightness` 取**两档不透明度**，颜色一律取槽位：
/// 浅色档 `success/accent/danger` 是深色饱和色，深色档是亮色 ——
/// CSS 那两套字色差异（深绿 vs 亮绿）由槽位自己给，组件不再判风格。
enum StatusKind {
  /// 完成 / 已登录。
  done,

  /// 进行中 / 运行中。
  run,

  /// 等待 / 待处理。
  wait,

  /// 失败 / 错误。
  err,
}

class StatusBadge extends StatelessWidget {
  final StatusKind kind;

  /// 已 `t()` 过的文案，如 '已登录' / '运行中'。
  final String text;

  const StatusBadge({super.key, required this.kind, required this.text});

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final c = t.colors;
    // CSS 深色三套的底一律比浅色高约 2 个百分点（.13→.15、.14→.16）；
    // 5% 差值在 10px 字上看不出来，但少了它深色下的胶囊会显"脏"。
    final dark = t.brightness == Brightness.dark;
    double a(double light, double darkV) => dark ? darkV : light;

    final (Color fg, Color bg) = switch (kind) {
      // done / run / err 都是「同色系低饱和底 + 同色系文字」；
      // wait 是中性灰（CSS 用 --ink3，对应 c.textMuted）。
      StatusKind.done => (
          c.success,
          c.success.withValues(alpha: a(0.14, 0.15)),
        ),
      StatusKind.run => (
          c.accent,
          c.accent.withValues(alpha: a(0.15, 0.17)),
        ),
      StatusKind.wait => (
          c.textMuted,
          c.textMuted.withValues(alpha: a(0.07, 0.08)),
        ),
      StatusKind.err => (
          c.danger,
          c.danger.withValues(alpha: a(0.13, 0.15)),
        ),
    };

    // WinUI3 的状态标记是**小圆角矩形**（4px），不是胶囊 —— 这是它和另三套
    // 在「同一个语义」上最直观的形态差异之一。内边距也略收紧（8→7），
    // 因为直角矩形比胶囊在视觉上更"占宽"，沿用 8 会显得松散。
    final shape = t.style.shapeOf();

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: shape.badgePadH,
        vertical: shape.badgePadV,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(shape.badgeRadius),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}
