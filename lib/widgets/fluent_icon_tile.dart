import 'package:flutter/material.dart';

import '../theme/app_style.dart';
import '../theme/app_theme.dart';
import '../theme/fluent_tokens.dart';

/// WinUI 的**图标瓦片** —— 卡片/设置项左侧那个方形的浅色底 + 图标。
///
/// ### 出处（逐值照抄）
///
/// `F:\samples\_verify\tubatool\TubaWinUi3.WinUI3\Styles\SettingsStyles.xaml:10-15`
/// 与 `FluentTokens.xaml:90-95`：
///
/// ```xml
/// <Style x:Key="IconBorderStyle" TargetType="Border">
///     <Setter Property="Width" Value="36" />
///     <Setter Property="Height" Value="36" />
///     <Setter Property="Background" Value="{ThemeResource SubtleFillColorSecondaryBrush}" />
///     <Setter Property="CornerRadius" Value="8" />
/// </Style>
/// ```
///
/// 导航卡用另一档：`NavCardIconBorderStyle` 是 **40×40**，其余相同。
/// 两档都用 [FluentBox.iconTile] / [FluentBox.navIconTile]。
///
/// ### 为什么单独抽一个组件
///
/// 参照物里这个形状出现了 **97 次**（仅 SettingsPage 就 97 处引用语义画刷）。
/// 它是 WinUI 视觉里最容易一眼认出的部件之一：**方、浅、圆角 8、图标居中**。
/// 此前本项目各页面自己拼 `Container + Icon`，尺寸与圆角各不相同 ——
/// 抽成一处才能和参照物逐值对上。
class FluentIconTile extends StatelessWidget {
  /// 图标。通常是 [Icon]，也可以塞任意小尺寸 widget。
  final Widget icon;

  /// 边长。默认 36（`IconBorderStyle`）；导航卡传 40（`NavCardIconBorderStyle`）。
  final double size;

  const FluentIconTile({
    super.key,
    required this.icon,
    this.size = FluentBox.iconTile,
  });

  /// 导航卡档：40×40。
  const FluentIconTile.nav({
    super.key,
    required this.icon,
  }) : size = FluentBox.navIconTile;

  @override
  Widget build(BuildContext context) {
    final th = AppTheme.of(context);
    final c = th.colors;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // 官方 `SubtleFillColorSecondary`（深色 6% 白 / 浅色 3.5% 黑）——
        // 参照物 `Styles/SettingsStyles.xaml:15` 给 `IconBorderStyle` 的底色。
        //
        // 2026-10-19 批次 A 修正：原先借 `lineSoft`（官方
        // `subtleFillColorTertiary` 量级，深色 4% 白 / 浅色 2% 黑），
        // 那是**描边**档位，铺在图标块上比参照物淡一档。
        color: th.style.subtleFillOf(th.brightness).color,
        // 官方 CornerRadius 是 8（CardCornerRadiusToken），不是控件的 4。
        borderRadius: BorderRadius.circular(FluentRadius.card),
      ),
      child: IconTheme(
        // 参照物里图标是 FontIcon 18px（SettingsPage 的 Glyph）。
        data: IconThemeData(size: FluentText.bodyLarge, color: c.textNormal),
        child: icon,
      ),
    );
  }
}
