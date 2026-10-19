import 'package:flutter/widgets.dart';

/// WinUI 3 / Fluent Design 的**几何与版式令牌**。
///
/// ### 出处（逐值照抄，不自行发明）
///
/// `F:\samples\_verify\tubatool\TubaWinUi3.WinUI3\Styles\FluentTokens.xaml`
/// —— 图吧工具箱（真实 WinUI 3 成品）的设计令牌字典。它自己的注释写着：
///
/// > 间距遵循 8px 网格：4 / 8 / 12 / 16 / 24 / 32
/// > 圆角：控件 4 / 卡片与浮层 8 / 药丸 12（对齐官方 ControlsCornerRadius /
/// >        OverlayCornerRadius）
/// > 版式阶梯派生自官方 TextBlock 样式：
/// >   Caption 12 / Body 14 / BodyStrong 14 / BodyLarge(+Strong) 18 /
/// >   Subtitle 20 / Title 28
/// > 官方规范：强调用 Semibold，不用 Bold；正文不覆盖 FontFamily
///
/// 这些数字不是「看着差不多」，是 WinUI 官方规范在参照物里的落地值。
/// 本项目此前各组件各写各的间距（10/13/14/20 混用），这层的作用就是把它们
/// 收敛到同一套刻度上。
///
/// ### 与既有令牌层的关系
///
/// 正交，不重叠：
/// * `AppColors` / `StyleColors` —— 管**颜色**
/// * `AppSurface` —— 管**材质**（模糊/渐变/投影）
/// * `AppStyleRadiusTokens` —— 管**卡片级大半径**（按风格取 14/16/20）
/// * `StyleShape` —— 管**控件级几何**（标题栏高度、开关轨等 15 项）
/// * **本文件** —— 管**间距 / 圆角刻度 / 字号阶梯**，与风格无关（WinUI 只有一套）
///
/// 刻意不叫 `AppSpacing` 之类：它抄的是 Fluent 规范本身，不是本项目的风格层。

/// 间距刻度（8px 网格）。
///
/// 照抄 `FluentTokens.xaml:41-46` 的 `SpaceXxSmall` … `SpaceXLarge`。
abstract final class FluentSpace {
  /// 4 —— 紧密元素之间（图标与文字、徽章内边距）
  static const double xxSmall = 4;

  /// 8 —— 同一组内的元素间距
  static const double xSmall = 8;

  /// 12 —— 组与组之间
  static const double small = 12;

  /// 16 —— 卡片内边距、区块之间（最常用）
  static const double medium = 16;

  /// 24 —— 页面级留白、大区块之间
  static const double large = 24;

  /// 32 —— 页面外边距、大标题上下
  static const double xLarge = 32;
}

/// 圆角刻度。
///
/// 照抄 `FluentTokens.xaml:49-52`。三档各有明确用途，不要混用：
/// 控件用 [control]，卡片/浮层用 [card]，药丸用 [pill]。
abstract final class FluentRadius {
  /// 4 —— 控件级（按钮、输入框、选项格）
  static const double control = 4;

  /// 8 —— 卡片与浮层（`CardCornerRadiusToken` / `DialogCornerRadiusToken`）
  static const double card = 8;

  /// 12 —— 药丸形（分段控件、标签）
  static const double pill = 12;
}

/// 字号阶梯。
///
/// 照抄 `FluentTokens.xaml:55-62` 的样式定义。**只登记这些档位** ——
/// `test/visual_tokens_test.dart` 的字号棘轮会把中间值（如 11.5 / 13.5）判红，
/// 新写组件时请从这六档里选。
///
/// 注意 Caption 与 Body 同为 14 的那一对：官方 Caption 是 12，Body 是 14，
/// BodyStrong 也是 14 但字重更重 —— 层级靠**字重**而非字号区分，这是 WinUI
/// 的做法（参照物注释：「强调用 Semibold，不用 Bold」）。
abstract final class FluentText {
  /// 12 —— 次要说明、卡头右侧灰字、徽章
  static const double caption = 12;

  /// 14 —— 正文（BodyTextBlockStyle）
  static const double body = 14;

  /// 14 —— 小标题（BodyStrongTextBlockStyle，配 [FluentWeight.strong] 字重）
  static const double bodyStrong = 14;

  /// 18 —— 卡片标题（BodyLargeStrongTextBlockStyle，配 [FluentWeight.strong]）
  static const double bodyLarge = 18;

  /// 20 —— 统计数值、页面副标题（SubtitleTextBlockStyle）
  static const double subtitle = 20;

  /// 28 —— 页面主标题（TitleTextBlockStyle）
  static const double title = 28;
}

/// 字重。
///
/// 官方规范：**强调用 SemiBold，不用 Bold**（见参照物 `FluentTokens.xaml:11`）。
/// Flutter 的 [FontWeight.w600] 对应 SemiBold，[FontWeight.w700] 是 Bold ——
/// 两者在 WinUI 里观感差别明显，别顺手写 w700。
abstract final class FluentWeight {
  /// 正文
  static const FontWeight regular = FontWeight.w400;

  /// 强调（官方给强调用的那一档）
  static const FontWeight strong = FontWeight.w600;
}

/// 组件级常用组合 —— 直接照抄 `FluentTokens.xaml:65-95` 的几个 Style。
///
/// 这些是参照物里反复出现的形状，写成常量避免每个组件各写一遍。
abstract final class FluentBox {
  /// 卡片（`FluentCardStyle`）：内边距 16、圆角 8、1px 边线。
  ///
  /// 底色与描边色不在这里 —— 那是 `AppColors` 的事（官方语义画刷）。
  static const EdgeInsets cardPadding = EdgeInsets.all(FluentSpace.medium);

  /// 图标块（`IconBorderStyle`）：36×36、圆角 8。
  static const double iconTile = 36;

  /// 页头图标块（`ToolPageHeader.xaml` 的 `IconTile`）：48×48、圆角 8。
  ///
  /// 比卡片里的 [iconTile] 大一圈 —— 页头只有一颗图标，尺寸按标题层级放大。
  static const double headerIconTile = 48;

  /// 导航卡图标块（`NavCardIconBorderStyle`）：40×40、圆角 8。
  static const double navIconTile = 40;

  /// 设置项（`SettingsCardStyle` = FluentCard）：图标 36 + 标题 + 描述 + 右侧控件。
  /// 内部横向间距用 [FluentSpace.medium]（参照物 `ColumnSpacing="16"`）。
  static const double settingsIconGap = FluentSpace.medium;
}
