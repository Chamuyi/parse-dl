import 'package:flutter/material.dart';

import '../theme/app_style.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';

/// 预览稿的**卡片骨架** —— `.card > .ct .r` + `.cb` 的 Flutter 对应物。
///
/// 设计稿 §三把它列为「所有卡」的地基：S9b/S9c 的每一张卡都是
/// 「卡头（左标题 + 右灰字）+ 内容区」。原来每个页面各写一遍
/// `AppCard + Column + Text(...)`，标题字号、卡头内边距、右侧灰字的灰法
/// 四处不同；这里收成一处。
///
/// ### 规格出处（`tools/ui/_redesign/preview/app.css`）
///
/// ```
/// :115 .card { display:flex; flex-direction:column; min-height:0; overflow:hidden; }
/// :116 .card > .ct {
///   display:flex; align-items:center; gap:8px; padding:10px 13px;
///   font-size:11.5px; font-weight:600; letter-spacing:.3px; flex:none; }
/// :120 .card > .ct .r { margin-left:auto; font-weight:400; font-size:11px; opacity:.55; }
/// :121 .card > .cb { flex:1; min-height:0; overflow:auto; padding:0 13px 13px; }
/// ```
///
/// 注意 `.ct` 的字号是 **11.5 / w600**，不是 13.5 —— 预览稿的卡头比
/// S1–S8 那批自创卡片的标题小一档、靠字重与左缩进区分层级。
///
/// ### 三点偏离，都有理由
///
/// 1. **圆角走 [AppRadius.card] 档位**而不是写 14 / 16 / 20 —— 三套风格对
///    同一个档位给不同半径（`app_style.dart:202`），这是「一套设计语言」的
///    一部分。卡片本体直接复用 [AppCard]，于是模糊 / 渐变面 / 内缘亮环 /
///    边框 / 投影全部随风格走，本组件不判断风格。
/// 2. **`.cb` 的 `overflow:auto` 不搬**：Flutter 里滚动由外层容器决定
///    （页面是 `ListView` / `SingleChildScrollView` / 固定高双栏），在这里
///    套一层滚动的卡会把「卡内滚动条」这种 CSS 特有行为也搬过来。内容区只
///    负责 padding。
/// 3. **右灰字按 `.r` 的 `margin-left:auto` 语义实现**（见
///    [_SectionCardHead]），标题不收缩、右侧自动推到末尾。
class SectionCard extends StatelessWidget {
  final String title;

  /// 卡头右侧的灰字（如「已选 4 / 9」「搜索失败时用」）。
  /// 已 `t()` 过，直接传进来的文本。null = 卡头只有左标题。
  final String? trailing;

  /// 内容区的 padding。默认 `0 13 13` 照 CSS `:121`；给了整体 padding 的
  /// 场景（如预览稿 `douyin-downloads` 那张卡）由调用方覆盖。
  final EdgeInsetsGeometry contentPadding;

  /// null = 用 [AppRadius.card]；`AppRadius.field` 等用于嵌在卡里的子块。
  final AppRadius radius;

  /// 是否在父级 `Column` 里撑开（CSS `.pane > .card { flex:1 }`）。
  ///
  /// **默认 false**：CSS 里 `.card` 自身的 flex 是默认值 `0 1 auto`，只有
  /// `.pane > .card`（`:113`）才是 `flex:1`。Flutter 里同样 —— 单栏
  /// `ListView` / `Column` 里的卡按内容取高，一旦默认包 `Expanded` 就会
  /// 在 unbounded 高度下当场抛「RenderFlex children have non-zero flex but
  /// incoming height constraints are unbounded」。**双栏 pane 内**想让两张卡
  /// 等高分配高度时才传 true。
  final bool flex;

  final Widget child;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    // WinUI 卡片内边距 16（官方 `FluentCardStyle`）；旧风格保留 13。
    this.contentPadding = EdgeInsets.zero,
    this.radius = AppRadius.card,
    this.flex = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    final head = _SectionCardHead(
      title: title,
      colors: c,
      trailing: trailing,
    );

    final body = AppCard(
      radius: radius,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head,
          Padding(padding: contentPadding, child: child),
        ],
      ),
    );

    // flex=true 时撑满父级（`.pane > .card { flex:1 }`，CSS `:113`）；
    // 默认按内容取高（CSS `.card` 自身 flex 为默认值）。
    return flex ? Expanded(child: body) : body;
  }
}

/// 卡头：左标题 + `margin-left:auto` 右推的灰字。
///
/// ### 为什么不是 `Flexible(textAlign: right)`
///
/// 上一版把右灰字实现成 `Flexible(Text(textAlign: TextAlign.right))`，
/// 两者在**标题可收缩**的前提下不等价：
///
/// * CSS 的 `.ct .r { margin-left:auto }`（`:120`）是「标题按内容取宽，
///   右侧元素被剩下的空白推到末尾」——标题短于可用宽度时，灰字**永远贴右边缘**；
/// * `Flexible + textAlign:right` 里灰字自己占满剩余空间、再把文字在内部右对齐。
///   视觉上像贴右，但**灰字本身获得了 flex 身份**：标题一变长，Flutter 先挤
///   灰字（它才是那个 flex:1 的），标题反而保持原宽 —— 与 CSS 的收缩顺序相反。
///
/// 做法上更接近 CSS 的版本是：标题不参与 flex（`mainAxisSize.min`），
/// 灰字前插一个 `Spacer`（等价于 `margin-left:auto` 的"吃掉剩余空白"），
/// 灰字自身用 `Flexible` 只负责超长时省略。这样「标题短 → 灰字贴右」与
/// 「标题长 → 标题先被挤」都与 CSS 一致。
class _SectionCardHead extends StatelessWidget {
  final String title;
  final AppColors colors;
  final String? trailing;

  const _SectionCardHead({
    required this.title,
    required this.colors,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final right = trailing;
    // WinUI3 的卡片头**更紧凑**（上下 8 而非 10）、标题**不带字距**：
    // WinUI 的排版规范里正文与标题都不加 letterSpacing，靠字号/字重分层。
    // 另三套保留预览稿的 10px + 0.3 字距。
    final winui = AppTheme.of(context).style == AppStyle.winui;

    return Padding(
      // 参照物卡头留白 16/12（与 `FluentCardStyle` 的 16 内边距对齐）。
      padding: EdgeInsets.fromLTRB(
        winui ? 16 : 13,
        winui ? 12 : 10,
        winui ? 16 : 13,
        winui ? 12 : 10,
      ),
      child: Row(
        // min：标题按内容取宽，剩下的空白交给右侧（CSS `.ct` 默认行为）
        mainAxisSize: MainAxisSize.min,
        children: [
          // 参照物 `SectionHeaderStyle` = 官方 `BodyStrongTextBlockStyle`：
          // **14px + SemiBold**。此前 11.5 让整个界面像「网页小标签」而不是
          // WinUI 卡片头 —— 这是 2026-10-19 用户判「不像 WinUI」的直接原因之一。
          Text(
            title,
            style: TextStyle(
              fontSize: winui ? 14 : 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: winui ? 0 : 0.3,
              color: c.textStrong,
            ),
          ),
          if (right != null) ...[
            const SizedBox(width: 8),
            // Spacer = CSS 的 margin-left:auto
            const Spacer(),
            Flexible(
              child: Text(
                right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: c.textMuted.withValues(alpha: 0.55),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
