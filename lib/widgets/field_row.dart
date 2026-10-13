import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 预览稿的**字段行** —— `.row .field .btn` 的 Flutter 对应物。
///
/// 用在「cookie / 代理地址 / 日志目录」这种「一个值 + 右侧一组动作」的行。
/// 设计稿 §2.1/§2.2 的每张设置卡都有它。
///
/// ### 规格出处（`tools/ui/_redesign/preview/app.css`）
///
/// ```
/// :130 .row  { display:flex; gap:8px; margin-bottom:10px; align-items:center; }
/// :132 .field { flex:1; height:36px; border-radius:8px; padding:0 11px;
///              font-size:12.5px; display:flex; align-items:center; gap:8px; min-width:0; }
/// :138 .btn   { height:36px; padding:0 15px; border-radius:8px; border:0;
///              font-size:12.5px; font-weight:550; }
/// :144 .btn.sm   { height:30px; padding:0 11px; font-size:11.5px; }
/// :145 .btn.xs   { height:26px; padding:0 9px; font-size:11px; border-radius:7px; }
/// :146 .btn.gh   { background:transparent; }
/// :148 .btn.danger { color:#e5484d; }
/// ```
///
/// ### 两个实现决定
///
/// 1. **字段本体用只读文本 + `surfaceSunken` 底**而不是 `TextField`：
///    预览稿的 `.field` 是展示型容器（`overflow:hidden; text-overflow:ellipsis`），
///    cookie 那种值被 `••••` 替过、地址是路径，都不需要光标。要真输入时
///    S9b 再按 `tpl .in`（`:517`）另立一个 `TemplateField`，不把两种语义塞一个组件。
/// 2. **按钮走原生 `FilledButton.tonal` / `TextButton`**：`app_theme.dart:284`
///    的 `buildAppTheme` 已经把三套风格的 `.btn` / `.btn.primary` 观感下发到
///    `filledButtonTheme` / `outlinedButtonTheme` / `textButtonTheme`，任何
///    `FilledButton.tonal`（普通按钮）与 `TextButton`（ghost）自动随风格走。
///    在本组件里再画一遍按钮等于绕开那层主题。
class FieldRow extends StatelessWidget {
  /// 值本体。已 `t()` 过。
  final String value;

  /// 等宽显示（`.field.mono`，`:137`）—— cookie / 模板串用。
  final bool mono;

  /// 字段左侧的小标记（预览稿 `home` 页地址行的 `@`）。null = 不加。
  final String? prefix;

  /// 右侧按钮组，按渲染顺序排。
  final List<FieldButton> buttons;

  /// null = `36px` 高（`.btn` 基准）；`FieldButtonSize.sm` = 30px；`xs` = 26px。
  final FieldButtonSize size;

  const FieldRow({
    super.key,
    required this.value,
    required this.buttons,
    this.mono = false,
    this.prefix,
    this.size = FieldButtonSize.sm,
  });

  @override
  Widget build(BuildContext context) {
    // 行高取本组按钮的高度（`.row` 是 align-items:center，谁高听谁的）
    final h = switch (size) {
      FieldButtonSize.base => 36.0,
      FieldButtonSize.sm => 30.0,
      FieldButtonSize.xs => 26.0,
    };

    return SizedBox(
      height: h,
      child: Row(
        children: [
          Expanded(
            child: _FieldBox(
              value: value,
              mono: mono,
              prefix: prefix,
              height: h,
            ),
          ),
          const SizedBox(width: 8),
          for (final b in buttons) ...[
            _FieldAction(button: b, size: size),
            if (b != buttons.last) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

enum FieldButtonSize { base, sm, xs }

/// 一个动作按钮。
class FieldButton {
  final String label;

  /// null = 按钮禁用（预览稿里「重登」「退出」在未登录时禁用）。
  final VoidCallback? onPressed;

  /// ghost = 无底色（CSS `.btn.gh`）；danger = 危险色文字（`.btn.danger`）。
  final bool ghost;
  final bool danger;

  const FieldButton(
    this.label, {
    this.onPressed,
    this.ghost = false,
    this.danger = false,
  });
}

class _FieldBox extends StatelessWidget {
  final String value;
  final bool mono;
  final String? prefix;
  final double height;

  const _FieldBox({
    required this.value,
    required this.mono,
    required this.prefix,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final p = prefix;

    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          if (p != null) ...[
            Text(
              p,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: c.textMuted,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                // mono 时 12（CSS `.field.mono`），否则 12.5
                fontSize: mono ? 12 : 12.5,
                color: c.textNormal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldAction extends StatelessWidget {
  final FieldButton button;
  final FieldButtonSize size;

  const _FieldAction({required this.button, required this.size});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final b = button;

    final label = Text(
      b.label,
      style: TextStyle(
        // xs 11 / sm 11.5 / base 12.5 —— 三档都在既有基线内
        fontSize: switch (size) {
          FieldButtonSize.xs => 11,
          FieldButtonSize.sm => 11.5,
          FieldButtonSize.base => 12.5,
        },
        // CSS `.btn` 是 font-weight:550。Flutter 没有半百字重，向下取整百
        // （与 `opt_grid.dart` / `page_header.dart` 同一规则）。
        fontWeight: FontWeight.w500,
        color: b.danger ? c.danger : null,
      ),
    );

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(size == FieldButtonSize.xs ? 7 : 9),
    );

    if (b.ghost) {
      return TextButton(
        onPressed: b.onPressed,
        style: TextButton.styleFrom(
          minimumSize: Size.zero,
          padding: EdgeInsets.symmetric(
            horizontal: size == FieldButtonSize.xs
                ? 9
                : size == FieldButtonSize.sm
                    ? 11
                    : 15,
          ),
          shape: shape,
        ),
        child: label,
      );
    }

    return FilledButton.tonal(
      onPressed: b.onPressed,
      style: FilledButton.styleFrom(
        minimumSize: Size.zero,
        padding: EdgeInsets.symmetric(
          horizontal: size == FieldButtonSize.xs
              ? 9
              : size == FieldButtonSize.sm
                  ? 11
                  : 15,
        ),
        shape: shape,
      ),
      child: label,
    );
  }
}
