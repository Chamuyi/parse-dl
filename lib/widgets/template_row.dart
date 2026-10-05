import 'package:flutter/material.dart';

import '../services/file_name_template.dart';
import '../theme/app_theme.dart';
import '../l10n/l10n.dart';

/// 单个模板输入行：标签 + **可用变量表** + 输入框 + 「输出示例」预览。
///
/// 顺序照抄原版 X-Spider `FileNameTemplateInput`
/// （VariablePicker → Input → TemplateExample）—— 所以每个模板字段**各自**
/// 都带一份可用变量表，点哪个框的变量就插到哪个框，不存在「变量表只挂在
/// 文件名模板下面」的问题。
///
/// **为什么抽成公共组件**：X 下载与抖音解析下载各有自己的文件夹 / 文件名模板，
/// 两边要长得一模一样、行为也一致，所以只写一份实现。
///
/// **变量表按平台传入**（[vars]）：底层定义是同一份全集，但设置页只显示属于
/// 本平台语义的那些 —— X 设置里不会出现作品/作者这类抖音变量，抖音设置里
/// 也不会出现推文/用户名这类 X 变量。术语不串门。
class TemplateRow extends StatelessWidget {
  const TemplateRow({
    super.key,
    required this.label,
    required this.hint,
    required this.controller,
    required this.focusNode,
    required this.emptyHint,
    required this.onUseDefault,
    required this.example,
    required this.onPickVar,
    required this.vars,
    this.varHint,
    this.enabled = true,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final FocusNode focusNode;

  /// 模板为空时显示的说明
  final String emptyHint;

  /// 点「填入默认」写入的模板
  final VoidCallback onUseDefault;

  /// 用示例数据算出的结果（空串表示模板为空）
  final String example;

  /// 点变量表里的变量 → 插入本行的输入框。
  final void Function(String token) onPickVar;

  /// 本平台可用的变量表（X 传 `kXTemplateVars`，抖音传 `kDouyinTemplateVars`）。
  /// 两个模块的术语体系不同，所以这张表由调用方给，不在这里写死。
  final List<TemplateVar> vars;

  /// 变量表底部额外的提示（如「文件夹模板慎用逐文件变量」），可空。
  final String? varHint;

  /// 关掉时整行置灰不可编辑（例如「启用保存文件夹」关掉后的文件夹模板）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final empty = controller.text.trim().isEmpty;

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: c.textMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                InkWell(
                  onTap: onUseDefault,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      t('填入默认'),
                      style: TextStyle(fontSize: 11.5, color: c.accent),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // 可用变量表 —— 在本输入框的正上方，点一下就插进本框
            VariablePicker(onPick: onPickVar, hint: varHint, vars: vars),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              style: TextStyle(
                fontSize: 13,
                color: c.textStrong,
                fontFamily: 'Consolas',
              ),
              cursorColor: c.accent,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(fontSize: 12, color: c.textFaint),
                filled: true,
                fillColor: c.surfaceSunken,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: c.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: c.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: c.accent, width: 1.4),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // 输出示例
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('输出示例：'),
                  style: TextStyle(fontSize: 11.5, color: c.textFaint),
                ),
                Expanded(
                  child: SelectableText(
                    empty ? emptyHint : example,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: 'Consolas',
                      color: empty ? c.textFaint : c.accent,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 「可用变量」区块：点一下把 `%VAR%` 插进**所属字段**的模板框。
///
/// 原版 `FileNameTemplateInput`
/// 把它和输入框、输出示例打包在一起，所以**每个模板字段各带一份**；
/// 这里保持同样的结构。可折叠（原版是 `<details>`），默认展开，
/// 免得用户以为「文件夹模板没有可用变量」。
class VariablePicker extends StatefulWidget {
  const VariablePicker({
    super.key,
    required this.onPick,
    required this.vars,
    this.hint,
  });

  final void Function(String token) onPick;

  /// 要展示的变量表（按平台传入，见 [TemplateRow.vars]）。
  final List<TemplateVar> vars;

  /// 变量表底部的补充提示（例如「文件夹模板慎用逐文件变量」）。
  final String? hint;

  @override
  State<VariablePicker> createState() => _VariablePickerState();
}

class _VariablePickerState extends State<VariablePicker> {
  bool _expanded = true;

  /// 「参数格式」那行说明。
  ///
  /// 例子从**本平台**变量表里挑第一个带参数的变量，所以 X 设置里举的是 X 的
  /// 例子、抖音设置里举的是抖音的例子 —— 不写死某个变量名，避免又串了术语。
  String _paramHint() {
    final withParams = widget.vars
        .where((v) => v.params.isNotEmpty)
        .toList(growable: false);
    if (withParams.isEmpty) return t('参数格式：%VARIABLE,a=1,b=2%。');
    final v = withParams.first;
    final p = v.params.first;
    return tf(
        '参数格式：%VARIABLE,a=1,b=2%，如 %{ex}%（{desc}）。', {
          'ex': '%${v.name},${p.name}=${p.defaultValue}%',
          'desc': t(p.desc),
        });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(
                      Icons.data_object_outlined,
                      size: 14,
                      color: c.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      t('可用变量'),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: c.textStrong,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tf('共 {n} 个，点击插入到本模板',
                            {'n': widget.vars.length}),
                        style: TextStyle(fontSize: 11, color: c.textFaint),
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: c.textMuted,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final v in widget.vars)
                    _VarChip(
                      label: '%${v.name}%',
                      desc: t(v.desc),
                      tooltip: v.paramsTooltip == null ? null : t(v.paramsTooltip!),
                      onTap: () => widget.onPick('%${v.name}%'),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _paramHint(),
                style: TextStyle(
                  fontSize: 11.5,
                  color: c.textMuted,
                  height: 1.5,
                ),
              ),
              if (widget.hint != null) ...[
                const SizedBox(height: 6),
                Text(
                  widget.hint!,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: c.textMuted,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _VarChip extends StatelessWidget {
  final String label;
  final String desc;

  /// 带参数的变量才有：参数说明
  final String? tooltip;
  final VoidCallback onTap;

  const _VarChip({
    required this.label,
    required this.desc,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    final chip = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: c.surfaceSolid,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: c.line, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'Consolas',
                color: c.accent,
              ),
            ),
            const SizedBox(width: 5),
            Text(desc, style: TextStyle(fontSize: 10.5, color: c.textMuted)),
            if (tooltip != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.tune, size: 10, color: c.textFaint),
            ],
          ],
        ),
      ),
    );

    if (tooltip == null) return chip;
    return Tooltip(
      message: tooltip!,
      waitDuration: const Duration(milliseconds: 300),
      child: chip,
    );
  }
}
