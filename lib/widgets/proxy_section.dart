import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/aria2_coordinator.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import 'app_toast.dart';
import '../l10n/l10n.dart';

/// 「代理」设置区。
///
///   - 启用代理（开关）
///   - 使用系统代理（读 Windows「Internet 选项」，经 `reg query` 实现）
///   - 自定义代理 URL
///
/// 设置会由 `main.dart` 监听并同步到 `XApi`（注入 `HttpClient.findProxy`）。
/// Dart 的 HttpClient 默认直连、**不认 Windows 系统代理**，必须显式注入 ——
/// 否则在需要代理的网络环境下会抛
/// `HandshakeException: Connection terminated during handshake`。
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
    // 折叠组的概要行要显示地址当前值 → 输入时同步刷新
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ① 启用代理
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              t('启用代理'),
              style: TextStyle(fontSize: 13.5, color: c.textStrong),
            ),
            subtitle: Text(
              t('关闭后所有 X API 请求直接连接'),
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
            value: p.enable,
            activeThumbColor: c.accent,
            onChanged: (v) => settings.setProxy((q) => q.enable = v),
          ),
        ),

        if (p.enable) ...[
          const SizedBox(height: 8),

          // ② 使用系统代理
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(
                t('使用系统代理'),
                style: TextStyle(fontSize: 13.5, color: c.textStrong),
              ),
              subtitle: Text(
                t('自动读取 Windows「Internet 选项」里的代理设置（推荐）'),
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
              value: p.useSystem,
              activeThumbColor: c.accent,
              onChanged: (v) => settings.setProxy((q) => q.useSystem = v),
            ),
          ),

          // ③ 自定义代理地址 —— 外层「代理」分区已整体折叠；
          //    地址变成必填时由分区上的 forceExpand 自动展开。
          Text(
            t('自定义代理地址'),
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: c.textStrong,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            p.useSystem
                ? '当前使用系统代理，这里的地址会被忽略。'
                : '不使用系统代理时必须填写，例如 http://127.0.0.1:7890。',
            style: TextStyle(fontSize: 12.5, color: c.textMuted, height: 1.5),
          ),
          const SizedBox(height: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Opacity(
                opacity: p.useSystem ? 0.5 : 1.0,
                child: IgnorePointer(
                  ignoring: p.useSystem,
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _proxyUrlCtrl,
                          style: TextStyle(
                            fontSize: 13,
                            color: c.textStrong,
                            fontFamily: 'Consolas',
                          ),
                          cursorColor: c.accent,
                          decoration: InputDecoration(
                            labelText: '代理地址',
                            labelStyle: TextStyle(
                                fontSize: 12.5, color: c.textMuted),
                            hintText: 'http://127.0.0.1:7890',
                            hintStyle: TextStyle(
                                fontSize: 12, color: c.textFaint),
                            filled: true,
                            fillColor: c.surfaceSunken,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
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
                              borderSide:
                                  BorderSide(color: c.accent, width: 1.4),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!p.useSystem && _proxyUrlCtrl.text.trim().isEmpty) ...[
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
            ],
          ),
        ],

        const SizedBox(height: 12),

        // ④ 测试结果
        if (_testResult != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: (_testOk ? c.accent : c.danger).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: (_testOk ? c.accent : c.danger).withValues(alpha: 0.3),
              ),
            ),
            child: Row(
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
                    _testResult!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _testOk ? c.accent : c.danger,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],

        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check_rounded, size: 16),
              label: Text(t(_testing ? '测试中…' : '测试连接'),
                  style: const TextStyle(fontSize: 13.5)),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text(t('保存'), style: TextStyle(fontSize: 13.5)),
            ),
          ],
        ),
      ],
    );
  }
}