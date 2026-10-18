import 'package:flutter/material.dart';

import '../theme/app_style.dart';
import '../theme/app_theme.dart';

/// 全页统一的**纯文字页头** —— 预览稿 `.head h1 .sub` 的 Flutter 对应物。
///
/// ### 为什么这么做
///
/// 旧页头是「图标方块 + 大标题」（`settings_page.dart` 的 `_PageHeader`：
/// 44×44 的 `accentSoft` 方块 + 24px 标题）。用户 2026-10-13 真机裁定推翻
/// 计划书 §10「不改布局」：预览稿 `index.html` 同时是视觉层与页面骨架的统一
/// 基准，所以页头也改成预览稿那一套 —— `app.css:99-102`：
///
/// ```
/// .head { display:flex; align-items:center; gap:11px; padding:0 3px; }
/// .head h1 { font-size:18.5px; font-weight:650; letter-spacing:.1px; }
/// .head .sub { font-size:11.5px; opacity:.5; }
/// .head .sp { flex:1; }
/// ```
///
/// ### 取值与偏离（逐条可核对）
///
/// * **18.5 → 18**：`test/visual_tokens_test.dart` 的 `fontSizeBaseline` 只有
///   18 档可用，新增 18.5 会直接让棘轮报红。18 与 18.5 的差别肉眼不可辨。
/// * **`letter-spacing:.1px` / 副题 `opacity:.5`** 照抄；副题的灰色走
///   `c.textMuted.withValues(alpha: .5)`，不写死色值。
/// * **同行 baseline 对齐**（规格要求）：标题与副题内层用
///   `CrossAxisAlignment.baseline`，外层 Row 仍是 `center` —— 否则
///   trailing 按钮会被 baseline 对齐顶到上方。
/// * **`sp`（flex:1）由调用方决定**：原 CSS 用 `.sp { flex:1 }` 把右侧 pill
///   推到页头末尾。这里只在真有 trailing 时才插入 `Spacer()`，没有 trailing
///   的页（大多数）不会把标题拉宽。
///
/// ### 文案归调用方
///
/// 标题与副题由调用方 `t()` 之后传进来（组件本身不含任何中文字面量）——
/// 与本仓库「`t('…')` 的字面量必须能被 `l10n_test` 扫到」的约定一致。
class PageHeader extends StatelessWidget {
  final String title;

  /// 副标题。null = 只有一行标题（预览稿 14 页都给了副题，但组件不强制）。
  final String? subtitle;

  /// 右侧功能性控件（登录 pill、刷新按钮…）。**S9a 起所有原有 trailing
  /// 控件都必须接在这里，不许在页头替换时丢掉。**
  final Widget? trailing;

  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final sub = subtitle;
    // WinUI3 的页头是「Title + 次要说明」，**字重更重、无字距**，且上下留白
    // 更紧（WinUI 页面顶部直接贴标题，不像预览稿那样让标题探出 3px 去对齐）。
    final winui = AppTheme.of(context).style == AppStyle.winui;

    return Padding(
      // 3px 左移是预览稿 `.head { padding: 0 3px }` 的产物：页面内容缩在
      // 16px 边距里，标题往左探出 3px 正好与侧边栏文字对齐。
      // WinUI 不做这个探出 —— 它的标题与内容左缘对齐。
      padding: EdgeInsets.symmetric(horizontal: winui ? 0 : 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Flexible：标题过长时允许收缩，把 trailing 挤掉的旧 bug 不能重犯。
          Flexible(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    // CSS `.head h1` 是 font-weight:650。Flutter 的 FontWeight
                    // 只有整百常量（w550 这种东西是编译期错误），仓库既有 79 处
                    // 字重也全部只用整百。规则取向下整百：650→w600。
                    // 取重一档（w700）会让中文标题发糊，与卡头 w600 也分不开了。
                    //
                    // WinUI3 例外：它的 Title 是 w700 且**无字距**（Segoe UI
                    // Variable 的标题层级本就靠字重分层），取 w700 正是官方观感。
                    fontWeight: winui ? FontWeight.w700 : FontWeight.w600,
                    letterSpacing: winui ? 0 : 0.1,
                    color: c.textStrong,
                  ),
                ),
                if (sub != null && sub.isNotEmpty) ...[
                  const SizedBox(width: 11),
                  Flexible(
                    child: Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: c.textMuted.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}
