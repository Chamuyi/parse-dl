import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 预览稿的**小节标题** —— `.sec` 的 Flutter 对应物。
///
/// 用在「同一张卡里换了一组设置」的地方：设置页的「分模块设置」、
/// 「命名模板」，X 设置页的「命名模板」。设计稿 §2.1/§2.2 随处可见。
///
/// ### 规格出处（`tools/ui/_redesign/preview/app.css`）
///
/// ```
/// :213 .sec { font-size:10.5px; font-weight:700; letter-spacing:.5px;
///             opacity:.5; padding:12px 2px 5px; }
/// ```
///
/// 间距（上 12 / 下 5 / 左右各 2）照抄 CSS padding：它比普通
/// `SizedBox(height: 12)` 更松，因为同时承担「换组」的语义 ——
/// 只换数字不换语义会让小节与上一组字段糊在一起。
///
/// ### 文案：调用方 `t()` 之后传入，本组件不再自带 `t()`
///
/// 小节标题是**纯标签**（「命名模板」「分模块设置」），没有一处是运行时拼出来的，
/// 所以这里不内置翻译：调用方逐个 `t()` 后传进来，与其余 9 个预览稿组件
/// 的约定完全一致。
///
/// **为什么不在组件内 `t()`**（2026-10-13 收口时改掉）：英文界面下调用方
/// 传来的是**已译文**（如 `'Naming template'`），组件内再按这个字符串反查
/// 中文 key 表必然查不到，只能退回原文本身 —— 界面不报错但恒为英文；而若要求
/// 调用方改传中文字面量，又与本仓库「文案由调用方翻译后传入」的通用约定相反，
/// 同一个 `title` 参数在十个组件里会有两种语义。
///
/// **兜底不会丢**：`l10n_test` 的扫描器认的是源码里的 `t('…')` 字面量（已核实
/// `test/l10n_test.dart:166-198` 的机制）。翻译调用挪到调用方之后，那条
/// 字面量照样躺在调用方源码里，照样被扫到、照样进英文表。
class SubSection extends StatelessWidget {
  /// 小节标题。已由调用方 `t()` 过，本组件直接渲染。
  final String title;

  const SubSection(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 5),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            // CSS 是 opacity:.5，这里用同值叠加在 muted 上（不写死色值）
            color: c.textMuted.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}
