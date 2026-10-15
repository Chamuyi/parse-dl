import 'package:flutter/material.dart';

/// 全应用统一的滚动条处理 —— **一律不显示滚动条**。
///
/// ## 为什么最终是「彻底不显示」（2026-10-15 用户裁定）
///
/// Flutter 在**桌面平台**（Windows / Linux / macOS）默认会给每个可滚动组件
/// 套一层 `Scrollbar`（见 SDK `material/app.dart` 的
/// `MaterialScrollBehavior.buildScrollbar`）—— 于是侧边栏右侧、内容区右侧各
/// 多出一条**系统默认样式**的竖线，与预览稿完全不符。用户 2026-10-15 看真机
/// 时指出「怎么有一个滑动的东西」，随后又追一句「右边滚动条还在，并且三个
/// 模块的设置还有全局设置都是在」。
///
/// 中间方案（`2fae366`）只把那条**系统默认样式**换成了预览稿那一档
/// （8px / 半透明 / 全圆角、空闲时隐藏、滚动或悬停时淡入）。它确实让滚动条
/// 与预览稿一致了，但用户要的不是「换个样式的滚动条」，而是**任何时刻都
/// 不再出现**：设置类页面内容常溢出视口，快速滚动时那条淡入的细条会被连同
/// 截图一起留下来，于是看起来「还在」。用户据此裁定**彻底隐藏**。
///
/// 预览稿 `app.css` 三处规格中，`.side::-webkit-scrollbar { width: 0 }`
/// 正是「隐藏」；本项目把它从侧边栏一档**推广到全应用**。滚动本身不受影响
/// —— 滚轮、触控板、拖拽、键盘翻页都照旧，只是少了那条视觉提示。
///
/// 于是这里不再需要 [ScrollbarTheme]：没有任何 `Scrollbar` 被创建，就没有
/// 样式可下发。原来那套 8px/圆角/`thumbVisibility: false` 的参数已随之删除
/// （留着会让后人以为还在给滚动条配色）。
///
/// ## 为什么不改成 `ScrollConfiguration` + `MediaQuery.removePadding`
///
/// 那条路是移动端去 DraggableScrollbar 用的；桌面端的问题根源就是
/// `MaterialScrollBehavior` 自己会挂 `Scrollbar`，所以必须在
/// [buildScrollbar] 这一层直接返回 child，才是「根本不创建」而不是
/// 「创建了但不画」。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // 任何轴向、任何平台都不挂 —— 桌面端由本方法彻底接管，移动端本就
    // 不挂（SDK 默认只在桌面端插入）。
    //
    // 负控制（2026-10-15 已取证）：把下一行换成
    // `return Scrollbar(controller: details.controller, child: child);`
    // 会让 `app_scroll_behavior_test.dart` 里两条判据变红（-2）——
    // 说明它们不是恒真断言。
    return child;
  }
}

/// 「这一层不要滚动条」—— 就地覆盖 `ScrollBehavior.buildScrollbar`。
///
/// 用在侧边栏（预览稿 `.side::-webkit-scrollbar { width: 0 }`）。比
/// `Scrollbar(thickness: 0)` 可靠：后者仍插入一层 `RawScrollbar`，需要
/// controller（[SidebarNav] 是 `StatelessWidget`），而且「厚度 0」在不同
/// Flutter 版本上未必真的不画。
///
/// [AppScrollBehavior] 推广到全应用后，侧边栏这一层在语义上已经多余；保留它
/// 是为了让「侧边栏没有滚动条」这件事有一个**可点名、可测的**落点
/// （`test/app_scroll_behavior_test.dart` 直接问它），而不是只能靠全局设置
/// 间接推断。
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
