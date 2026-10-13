import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 预览稿的**开关行** —— `.sw .lb .tg` 的 Flutter 对应物。
///
/// 设计稿 §2.1/§2.2 每张设置卡里最多的就是它。用户可见文案一律由调用方
/// `t()` 之后传入，本组件不含中文字面量。
///
/// ### 规格出处（`tools/ui/_redesign/preview/app.css`）
///
/// ```
/// :203 .sw   { display:flex; align-items:center; gap:9px; padding:9px 11px; border-radius:9px; }
/// :204 .sw .lb   { flex:1; font-size:12.5px; }
/// :205 .sw .lb small { display:block; font-size:10.5px; opacity:.5; margin-top:1px; }
/// :206 .sw .tg   { width:36px; height:20px; border-radius:999px; position:relative; flex:none; }
/// :207 .sw .tg::after { top:2px; left:2px; width:16px; height:16px;
///                        border-radius:50%; background:#fff; box-shadow:0 1px 3px rgba(0,0,0,.3); }
/// :212 .sw .tg.on::after { left:18px; }
/// ```
///
/// 轨道底色取 `c.surfaceSunken`（CSS 三套的 `.tg` 都是半透明黑 / 白块，
/// `:320` / `:387` / `:454`），打开态取 `c.accent` —— `:321` / `:388` / `:454`
/// 分别是 liquid 渐变 / frosted 纯色 / clay 渐变。
///
/// ### 三处偏离，都有理由
///
/// 1. **轨道尺寸不写死**：SDK 的 [Switch.adaptive] 自己决定 36×20 之外的
///    命中区（手指/鼠标的可及范围比 20px 高）。把整套交互交给 SDK 换来的是
///    平台键盘可达性与 `Semantics(toggled:)` 语义标签 —— 自绘那套两条都要
///    自己补，而真机上键盘用户点不到开关是看不见的回归。
/// 2. **打开态统一实色**，不给每种风格加渐变分支：liquid 那条渐变在 36×20
///    轨道上首尾色相差 8%，肉眼不可辨，却要让组件多三条判断路径
///    （与 `app_theme.dart:279` 记的「ButtonStyle 只接受单色」同一个边界）。
/// 3. **容器底色随风格但不判断风格**：`.sw` 在 CSS 里与 `.opt` / `.field`
///    同属「卡片内凹陷块」，这里统一取 `c.surfaceSunken` —— 三套 × 明暗的
///    正确值由色板自己回答。
class SwitchRow extends StatelessWidget {
  final String label;

  /// 副题（`.lb small`）。null = 只有一行。
  final String? subtitle;

  final bool value;

  /// null = 禁用态（预览稿里未登录时的「重新登录」）。
  final ValueChanged<bool>? onChanged;

  const SwitchRow({
    super.key,
    required this.label,
    required this.value,
    this.subtitle,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final sub = subtitle;

    // 整行都是热区（点文字也能切）。
    //
    // 预览稿的 `.sw` 是**静态原型**（`<div class="sw">` 里没有 click 处理器，
    // 也没有 `cursor:pointer`），照抄的话整行不可点；但本应用改造前的
    // `SwitchListTile` 是整行可点的，真机用户习惯点文字 —— 只留 36×20 的
    // 小开关会让「点了没反应」，这是**功能退化**而不是「更贴预览稿」。
    // 所以这里用 `InkWell` 包整行，开关本体保留自己的 onChanged（点开关时
    // 命中开关、点文字时命中 InkWell，两条路都写同一个值，不会双触发）。
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(fontSize: 12.5, color: c.textStrong),
                    ),
                    if (sub != null && sub.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        sub,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: c.textMuted.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 9),
              Switch.adaptive(
                value: value,
                onChanged: onChanged,
                activeTrackColor: c.accent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
