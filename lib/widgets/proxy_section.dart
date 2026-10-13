import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/settings.dart';
import '../services/app_state.dart';
import '../services/aria2_coordinator.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import 'app_toast.dart';
import 'field_row.dart';
import 'switch_row.dart';
import '../l10n/l10n.dart';

/// 「代理」设置区的**卡内容** —— 卡头「代理」由设置页的 `SectionCard` 提供。
///
/// 预览稿（`index.html` :670-676）这一张卡是：
///
/// ```
/// .sw  启用代理
/// .sw  使用系统代理（副题 = 当前代理地址）
/// .row 字段(地址) + 按钮「测试连通性」
/// ```
///
/// 2026-10-13 S9b 平铺改造前，这一块是「两个 `SwitchListTile` + 一段自绘说明
/// + `TextField` + 一行按钮」，而且**两个开关在关闭态下会被整段藏起来**
/// （`if (p.enable) ...`）—— 那是折叠时代的写法：分区收起时无所谓，平铺之后
/// 就会让「使用系统代理」这一项凭空消失，用户找不到它。现在两个开关**恒常
/// 渲染**（与预览稿一致），只有地址输入框在「用系统代理」时置灰不可编辑。
///
/// ### 必填校验一点没放宽
///
/// 原来靠「分区 `forceExpand` 自动展开」保证必需项不藏在收起态里 ——
/// 平铺之后收起态不存在了，那条机制随之退役。但**判据本身必须留下**：
/// 「启用代理 + 不用系统代理 + 地址为空」时，输入框套红框、下面一行红字说明。
/// 平铺反而让这件事更直接：错误状态永远在屏幕上，不用先展开才看得见。
///
/// 数据绑定一字未改：`p.enable` / `p.useSystem` / `p.url` 同一批字段，
/// 测试连接仍走 [AppState.api] 的 `applyProxy` + `ping`，保存仍会下发 aria2。
class ProxySection extends StatefulWidget {
  const ProxySection({super.key});

  @override
  State<ProxySection> createState() => _ProxySectionState();
}

class _ProxySectionState extends State<ProxySection> {
  late final TextEditingController _proxyUrlCtrl;

  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    final p = context.read<SettingsStore>().settings.proxy;
    _proxyUrlCtrl = TextEditingController(text: p.url);
    // 地址框的当前值参与「必填但为空」的判定，输入时要重建
    _proxyUrlCtrl.addListener(_onUrlChanged);
  }

  void _onUrlChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _proxyUrlCtrl.removeListener(_onUrlChanged);
    _proxyUrlCtrl.dispose();
    super.dispose();
  }

  /// 连通性测试：按**当前输入框/开关**的配置临时应用一次，然后拉 x.com 首页。
  Future<void> _test() async {
    if (_testing) return;
    final settings = context.read<SettingsStore>().settings.proxy;
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final api = context.read<AppState>().api;
    await api.applyProxy(
      enable: true,
      useSystem: settings.useSystem,
      url: _proxyUrlCtrl.text.trim(),
    );
    final err = await api.ping();

    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = err == null;
      if (err == null) {
        final rule = api.findProxyRule;
        _testResult = rule == null || rule.isEmpty
            ? '可直连 x.com（未使用代理）'
            : '连接成功（经 $rule）';
      } else {
        _testResult = '连接失败：$err';
      }
    });
  }

  Future<void> _save() async {
    final settings = context.read<SettingsStore>();
    await settings.setProxy((p) {
      p.url = _proxyUrlCtrl.text.trim();
    });
    // 立刻同步到 aria2，并把下发结果如实报出来 —— 以前无论成败都弹「已保存」
    final why =
        await Aria2Coordinator.instance.updateProxy(_proxyUrlCtrl.text.trim());
    if (!mounted) return;
    AppToast.show(
      context,
      why == null ? t('已保存') : tf('已保存，但{why}', {'why': why}),
      kind: why == null ? AppToastKind.success : AppToastKind.info,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final settings = context.watch<SettingsStore>();
    final p = settings.settings.proxy;

    // 必填判据：开了代理、又不走系统代理，那地址就是必填的。
    final needUrl = p.enable && !p.useSystem;
    final urlEmpty = _proxyUrlCtrl.text.trim().isEmpty;
    final missing = needUrl && urlEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ① 启用代理
        SwitchRow(
          label: t('启用代理'),
          subtitle: t('关闭后所有 X API 请求直接连接'),
          value: p.enable,
          onChanged: (v) => settings.setProxy((q) => q.enable = v),
        ),
        const SizedBox(height: 8),

        // ② 使用系统代理 —— 恒常渲染（见类文档：平铺后不许再靠 `if` 藏项）。
        //    副题按预览稿给「当前会用哪条规则」，而不是一句泛泛的说明：
        //    用户在这一行就能读出「现在到底走不走代理」。
        SwitchRow(
          label: t('使用系统代理'),
          subtitle: p.useSystem
              ? t('自动读取 Windows「Internet 选项」里的代理设置（推荐）')
              : (p.url.trim().isEmpty
                  ? t('不用系统代理时必须填写下面的地址')
                  : p.url.trim()),
          value: p.useSystem,
          onChanged: (v) => settings.setProxy((q) => q.useSystem = v),
        ),
        const SizedBox(height: 10),

        // ③ 自定义代理地址 —— 走系统代理时置灰，但**不消失**：
        //    消失会让「地址存在且是这一项」这件事看不出来。
        Opacity(
          opacity: p.useSystem ? 0.5 : 1.0,
          child: IgnorePointer(
            ignoring: p.useSystem,
            child: TextField(
              controller: _proxyUrlCtrl,
              style: TextStyle(
                fontSize: 13,
                color: c.textStrong,
                fontFamily: 'Consolas',
              ),
              cursorColor: c.accent,
              decoration: InputDecoration(
                labelText: t('代理地址'),
                labelStyle: TextStyle(fontSize: 12.5, color: c.textMuted),
                hintText: 'http://127.0.0.1:7890',
                hintStyle: TextStyle(fontSize: 12, color: c.textFaint),
                filled: true,
                fillColor: c.surfaceSunken,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                // 必填未填 → 红框。这是平铺后**代替 forceExpand** 的那条可见信号。
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: missing ? c.danger : c.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: missing ? c.danger : c.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: missing ? c.danger : c.accent,
                    width: 1.4,
                  ),
                ),
              ),
            ),
          ),
        ),

        // 必填未填时的错误文案（原样保留：这句话以前藏在展开态里，现在常驻）
        if (missing) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 14, color: c.danger),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  t('还没填代理地址 —— 「测试连接」与下载都会失败'),
                  style: TextStyle(fontSize: 12, color: c.danger),
                ),
              ),
            ],
          ),
        ],

        const SizedBox(height: 10),

        // ④ 字段行：地址 + 「测试连通性」（预览稿 .row .field .btn）。
        //    地址在输入框里已经能编辑，这里那个 `.field` 位置改用**结果区**：
        //    没有结果时显示一句当前生效规则，有结果时显示那一行 —— 不然这一行
        //    会是一块与输入框重复的只读路径。
        FieldRow(
          value: _testResult ?? _currentRuleLine(p),
          mono: _testResult == null,
          buttons: [
            FieldButton(
              t(_testing ? '测试中…' : '测试连通性'),
              onPressed: _testing ? null : _test,
            ),
            FieldButton(t('保存'), ghost: true, onPressed: _save),
          ],
        ),

        // 测试结果的颜色信号（原自绘结果条保留其语义：成功=主色，失败=危险色）
        if (_testResult != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                _testOk
                    ? Icons.check_circle_outline_rounded
                    : Icons.error_outline_rounded,
                size: 15,
                color: _testOk ? c.accent : c.danger,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t(_testOk ? '连通性正常' : '连通性异常'),
                  style: TextStyle(
                    fontSize: 12,
                    color: _testOk ? c.accent : c.danger,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 还没测过时，那一行显示「当前会用哪条规则」——比留一块空白有信息量。
  String _currentRuleLine(ProxySettings p) {
    if (!p.enable) return t('当前直连，不使用代理');
    if (p.useSystem) return t('当前使用系统代理');
    return p.url.trim().isEmpty ? t('还没填代理地址') : p.url.trim();
  }
}
