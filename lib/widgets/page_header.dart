import 'package:flutter/material.dart';

import '../theme/app_style.dart';
import '../theme/app_theme.dart';
import '../theme/fluent_tokens.dart';

/// 全页统一的**页头** —— 照抄图吧工具箱的 `ToolPageHeader`。
///
/// ### 出处（逐值照抄，不自行发明）
///
/// `F:\samples\_verify\tubatool\TubaWinUi3.WinUI3\Controls\ToolPageHeader.xaml`：
///
/// ```xml
/// <Grid Padding="24,24,24,20" ColumnSpacing="16">
///   [返回按钮][图标块 48×48 r8][标题/副题 StackPanel Spacing=4][操作区 StackPanel Spacing=8]
/// </Grid>
/// ```
///
/// 标题用 `ToolPageTitleTextStyle`（BasedOn 官方 `TitleTextBlockStyle` → **28px**），
/// 副题用 `ToolPageSubtitleTextStyle`（BasedOn `BodyTextBlockStyle` → **14px**，
/// 前景 `TextFillColorSecondaryBrush`）。两个样式在参照物里**没有覆盖字号**，
/// 所以就是官方值。
///
/// ### 与旧版的差别（这就是「换骨」）
///
/// * 旧版是「18px 标题 + 11.5px 副题，横向同行、baseline 对齐」（预览稿 `.head`）。
/// * 新版是「28px 标题 + 14px 副题，**纵向两行**」，左侧带 48×48 图标块。
///   这正是用户说的「照抄其他项目的界面风格」——不是调字号，是换结构。
///
/// ### 取值与偏离（逐条可核对）
///
/// * **11.5 / 18 不再出现**：字号棘轮本来就不许 11.5 之外的新档，这里收敛到
///   [FluentText.title] / [FluentText.body] 两个已登记的官方档位。
/// * **图标块 48×48**（不是卡片里的 36）—— 参照物 `IconTile` 的 `Width/Height="48"`。
/// * **上下内边距 24/20 不对称** —— 参照物 `Padding="24,24,24,20"`，下方少 4px
///   是为了和内容区贴近。照抄，不"修正"成对称。
/// * **副题允许换行**：参照物 `TextWrapping="Wrap"`（标题则是 CharacterEllipsis）。
///
/// ### 文案归调用方
///
/// 标题与副题由调用方 `t()` 之后传进来（组件本身不含任何中文字面量）。
class PageHeader extends StatelessWidget {
  final String title;

  /// 副标题。null = 只有一行标题。
  final String? subtitle;

  /// 标题左侧的图标（参照物 `IconTile` 里的 FontIcon）。
  /// null 时不留图标块 —— 部分页面（下载管理）本来就没有对应图标。
  final IconData? icon;

  /// 右侧功能性控件（登录 pill、刷新按钮…）。
  final Widget? trailing;

  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final sub = subtitle;
    final ic = icon;
    final winui = AppTheme.of(context).style == AppStyle.winui;

    return Padding(
      // 参照物 `Padding="24,24,24,20"`：上 24、下 20（下方少 4px 贴近内容）。
      padding: EdgeInsets.fromLTRB(
        FluentSpace.large,
        winui ? FluentSpace.large : FluentSpace.medium,
        FluentSpace.large,
        winui ? 20 : FluentSpace.medium,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (ic != null) ...[
            // 参照物 `IconTile`：48×48、圆角 8，底色
            // `Background="{ThemeResource SubtleFillColorTransparentBrush}"`
            // （`Controls/ToolPageHeader.xaml:50`）= 官方 `subtleFillColorTransparent`
            // `0x00FFFFFF`（`color_resources.dart:210/:297`）—— 即**不铺底色**。
            Container(
              width: FluentBox.headerIconTile,
              height: FluentBox.headerIconTile,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(FluentRadius.card),
              ),
              child: Icon(
                ic,
                // 参照物 `FontIcon FontSize="20"`（`ToolPageHeader.xaml:57`）。
                size: 20,
                // 参照物 `Foreground="{ThemeResource AccentTextFillColorPrimaryBrush}"`
                // （`ToolPageHeader.xaml:58`）= 色板的 accentText 槽位
                // （浅 #005A9E / 深 #7FD4FF，即官方「强调色文字」档）。
                color: c.accentText,
              ),
            ),
            // 参照物 `ColumnSpacing="16"`。
            const SizedBox(width: FluentSpace.medium),
          ],
          // 标题/副题**纵向两行**，行间距 4（参照物 `StackPanel Spacing="4"`）。
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  // 参照物 `TextTrimming="CharacterEllipsis"`。
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FluentText.title,
                    // 官方规范：强调用 Semibold，不用 Bold。
                    fontWeight: FluentWeight.strong,
                    letterSpacing: 0,
                    height: 1.2,
                    color: c.textStrong,
                  ),
                ),
                if (sub != null && sub.isNotEmpty) ...[
                  const SizedBox(height: FluentSpace.xxSmall),
                  Text(
                    sub,
                    // 参照物 `TextWrapping="Wrap"`。
                    softWrap: true,
                    style: TextStyle(
                      fontSize: FluentText.body,
                      // 参照物 `TextFillColorSecondaryBrush`。
                      color: c.textMuted,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: FluentSpace.medium),
            trailing!,
          ],
        ],
      ),
    );
  }
}
