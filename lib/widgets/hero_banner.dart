import 'package:flutter/material.dart';

import '../theme/app_style.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';

/// 预览稿的**头图横幅** —— `.hero` / `.hero2 .mark .live` 的 Flutter 对应物。
///
/// S9c 才真正接线（主页 hero + 总览 hero2），S9a 只把组件和规格落定。
/// 用户可见文案一律由调用方 `t()` 之后传入，本组件不含中文字面量。
///
/// ### hero（`:229-239`）
///
/// ```
/// .hero { display:flex; align-items:center; gap:14px; padding:16px 18px; border-radius:12px; }
/// .hero .av  { width:52px; height:52px; border-radius:14px; display:grid;
///              place-items:center; font-size:20px; font-weight:700; }
/// .hero .info b    { font-size:15px; font-weight:650; display:block; }
/// .hero .info small{ font-size:11.5px; opacity:.55; }
/// ```
///
/// ### hero2（`:741-753`）
///
/// ```
/// .hero2 { display:flex; flex-direction:row; align-items:center; gap:16px;
///          padding:18px 20px; border-radius:16px; }
/// .hero2 .mark { width:54px; height:54px; border-radius:15px; font-size:22px; font-weight:700; }
/// .hero2 .txt b    { font-size:19px; font-weight:650; letter-spacing:.2px; display:block; }
/// .hero2 .txt small{ font-size:12px; opacity:.55; }
/// .hero2 .live { display:flex; gap:8px; flex:none; }
/// ```
///
/// ### 头像块的渐变：复用既有做法，不写死色值
///
/// CSS 三套都是 `linear-gradient(140deg, var(--ac), var(--ac2))`
/// （`:322` / `:389` / `:455`）。仓库里**已有等价实现**：
/// `theme/app_style.dart` 的 [AppStyleButtonTokens.buttonOf] 会给 liquid /
/// clay 下发 `StyleButton.primaryGradient`（首色 `c.accent`、末色该风格
/// `accent2`），frosted 则是实色。这里取同一条令牌 —— 于是三套的渐变方不
/// 一致这件事**由风格令牌自己回答**，组件不判断风格。
/// `accent2` 从 `StyleColors` 取（`AppColors` 里没有这个槽位，见
/// `style_colors.dart:45` 的说明）。
class HeroBanner extends StatelessWidget {
  /// 头像块里的字符（X 主页是「X」，关于页是「解」）。
  final String badge;

  final String title;
  final String subtitle;

  /// 右侧 pill 组（登录态 / 版本）。null = 头图没有 trailing。
  final List<HeroPill> pills;

  /// `hero`（52px 头像）+ 15px 标题，或 `hero2`（54px）+ 19px 标题。
  final bool large;

  /// 头像块用图片（真 logo）而不是字符。
  final String? imageAsset;

  const HeroBanner({
    super.key,
    required this.badge,
    required this.title,
    required this.subtitle,
    this.pills = const [],
    this.large = false,
    this.imageAsset,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final c = t.colors;
    final style = t.style;
    final brightness = t.brightness;

    // WinUI3 的徽标块是**直角**（或极小圆角），不是 14/15px 的大圆角 ——
    // WinUI 的圆角体系里只有 4（控件）/ 8（容器）两档，14 那档不存在。
    final winui = style == AppStyle.winui;
    final avSize = large ? 54.0 : 52.0;
    final avRadius = winui ? 4.0 : (large ? 15.0 : 14.0);
    final titleSize = large ? 19.0 : 15.0;
    final subSize = large ? 12.0 : 11.5;

    // 渐变 / 实色由风格令牌定：liquid 与 clay 有 primaryGradient，
    // frosted 只有 primaryColor（= c.accent）。
    final btn = style.buttonOf(brightness);
    final gradient = btn.primaryGradient;
    final asset = imageAsset;

    final avatar = Container(
      width: avSize,
      height: avSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: gradient == null ? (btn.primaryColor ?? c.accent) : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(avRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: asset != null
          ? Image.asset(asset, fit: BoxFit.cover)
          : Text(
              badge,
              style: TextStyle(
                fontSize: large ? 22 : 20,
                fontWeight: FontWeight.w700,
                // CSS 两处都写死 color:#fff（`:322` / `:389`）—— 头像块
                // 三套都是深色底上的白字，不是可变 token。
                color: Colors.white,
              ),
            ),
    );

    final text = Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: titleSize,
              // CSS `.hero .info b` / `.hero2 .txt b` 都是 font-weight:650。
              // Flutter 没有半百字重，向下取整百（同 `opt_grid.dart` 的规则）：
              // 取 w700 会让中文标题发糊。
              fontWeight: FontWeight.w600,
              letterSpacing: large ? 0.2 : 0,
              color: c.textStrong,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: subSize,
              color: c.textMuted.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );

    return AppCard(
      // hero2 是大统计块的档位（CSS `:804-806`），hero 是小控件档
      // （`:273` / `:348` / `:409`，正好等于 AppRadius.qi）。
      radius: large ? AppRadius.hero2 : AppRadius.qi,
      padding: EdgeInsets.fromLTRB(18, large ? 18 : 16, 18, large ? 18 : 16),
      child: Row(
        children: [
          avatar,
          SizedBox(width: large ? 16 : 14),
          text,
          if (pills.isNotEmpty) ...[
            const SizedBox(width: 12),
            for (final p in pills) ...[
              _HeroPill(pill: p, colors: c),
              if (p != pills.last) const SizedBox(width: 8),
            ],
          ],
        ],
      ),
    );
  }
}

/// 头图右侧的一个状态 pill —— `.pill` + `.ok`。
///
/// ```
/// :103 .pill { font-size:11.5px; padding:6px 12px; border-radius:999px;
///              display:inline-flex; align-items:center; gap:7px; white-space:nowrap; }
/// :108 .pill .ok { width:6px; height:6px; border-radius:50%; flex:none; }
/// ```
class HeroPill {
  final String text;

  /// 状态点颜色。null = 没有点（版本号那种）。
  /// 从 [AppColors] 槽位取（`c.success` / `c.danger`），不写死。
  final Color? dotColor;

  const HeroPill(this.text, {this.dotColor});
}

class _HeroPill extends StatelessWidget {
  final HeroPill pill;
  final AppColors colors;

  const _HeroPill({required this.pill, required this.colors});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final dot = pill.dotColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
          ],
          Text(
            pill.text,
            style: TextStyle(fontSize: 11.5, color: c.textNormal),
          ),
        ],
      ),
    );
  }
}
