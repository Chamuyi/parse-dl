import 'package:flutter/material.dart';

/// 全应用统一的滚动条外观 —— 预览稿 `app.css` 那三条规则的 Flutter 对应物。
///
/// ## 为什么需要它（2026-10-15 真机）
///
/// Flutter 在**桌面平台**（Windows / Linux / macOS）默认会给每个可滚动组件
/// 套一层 `Scrollbar`（见 SDK `material/app.dart` 的
/// `MaterialScrollBehavior.buildScrollbar`）—— 于是侧边栏右侧、内容区右侧各
/// 多出一条**系统默认样式**的竖线，与预览稿完全不符。用户 2026-10-15 看真机
/// 时指出「怎么有一个滑动的东西」。
///
/// 预览稿里滚动条是被**刻意设计过**的，三处规格各不相同：
///
/// ```
/// :40  .stage::-webkit-scrollbar            { width: 10px; }   ← 整页
///      .stage::-webkit-scrollbar-thumb      { background: rgba(140,140,155,.42);
///                                             border-radius: 999px; }
/// :59  .side::-webkit-scrollbar             { width: 0; }      ← 侧边栏：**隐藏**
/// :122 .card > .cb::-webkit-scrollbar       { width: 8px; }    ← 卡内
///      .card > .cb::-webkit-scrollbar-thumb { background: rgba(140,140,155,.38); }
/// ```
///
/// Flutter 的 `ScrollbarThemeData` 只能给**一个**厚度/颜色，没法按「哪个容器」
/// 区分 —— 所以这里取**卡内那一档**（8px / 半透明 / 全圆角）作为全局默认：
/// 它是最常出现的一种，且 8px 与 10px 的差别肉眼几乎看不出。
///
/// **侧边栏那条单独隐藏**（预览稿 `width: 0`）：见 `sidebar_nav.dart`，那里
/// 用 [ScrollConfiguration] 就地覆盖 `buildScrollbar` 返回原 child ——
/// 比 `Scrollbar(thickness: 0)` 可靠（后者仍插入一层 `RawScrollbar`，
/// 需要 controller，且厚度 0 未必真的不画）。
///
/// ## 样式为什么用 [ScrollbarTheme] 而不是覆写 behavior
///
/// `MaterialScrollBehavior` **没有** `scrollbarTheme` 可覆写（SDK 里只有
/// `buildScrollbar` / `buildOverscrollIndicator` 等）。滚动条的视觉参数由
/// `ScrollbarTheme` 或 `ThemeData.scrollbarTheme` 下发，所以这里把
/// [AppScrollBehavior] 与 [AppScrollbarTheme] 分成两件事，在 `app.dart`
/// 里一起挂上。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // 横向滚动条不挂（与 SDK 默认一致）。
    if (axisDirectionToAxis(details.direction) == Axis.horizontal) {
      return child;
    }
    // 只在桌面端挂（与 SDK 默认一致）—— 移动端的滚动条由系统绘制。
    switch (getPlatform(context)) {
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
        return Scrollbar(
          controller: details.controller,
          // 平时不常驻，滚动/悬停时才淡入 —— 预览稿的 `::-webkit-scrollbar-thumb`
          // 也是「有内容可滚时才看得见」。
          thumbVisibility: false,
          child: child,
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.iOS:
        return child;
    }
  }
}

/// 滚动条的视觉参数（预览稿 `.card > .cb` 那一档）。
///
/// 挂在 `app.dart` 的 `MaterialApp` 外层（`ScrollbarTheme` 是 InheritedWidget，
/// 必须包住整棵树才生效）。
class AppScrollbarTheme extends StatelessWidget {
  final Widget child;

  const AppScrollbarTheme({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ScrollbarTheme(
      data: const ScrollbarThemeData(
        // 预览稿 `width: 8px`（`.stage` 那档是 10px，取 8 见类文档说明）。
        thickness: WidgetStatePropertyAll<double>(8),
        // 8px 宽 + 圆角 4 = CSS 的 `border-radius: 999px` 全圆效果。
        radius: Radius.circular(4),
        // 不常驻：与 [AppScrollBehavior] 的 `thumbVisibility: false` 一致。
        thumbVisibility: WidgetStatePropertyAll<bool>(false),
        // 轨道不画：预览稿只定义了 thumb，没给 track 背景。
        trackVisibility: WidgetStatePropertyAll<bool>(false),
        // 滑块与内容边缘留 2px（CSS 的 `border: 2px solid transparent` 效果）。
        crossAxisMargin: 2,
      ),
      child: child,
    );
  }
}

/// 「这一层不要滚动条」—— 就地覆盖 [ScrollBehavior.buildScrollbar]。
///
/// 用在侧边栏（预览稿 `.side::-webkit-scrollbar { width: 0 }`）。比
/// `Scrollbar(thickness: 0)` 可靠：后者仍插入一层 `RawScrollbar`，需要
/// controller（[SidebarNav] 是 `StatelessWidget`，加 controller 得改类型），
/// 而且「厚度 0」在不同 Flutter 版本上未必真的不画。
class NoScrollbarBehavior extends ScrollBehavior {
  const NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}
