import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_state.dart';
import '../services/x_api.dart';
import '../theme/app_theme.dart';
import 'app_toast.dart';
import 'field_row.dart';
import 'status_badge.dart';
import 'switch_row.dart';
import '../l10n/l10n.dart';

/// 「账号 / X 登录」设置区。
///
/// X 的登录实际只需要两个 cookie 值，所以拆成两个独立输入框：
///   - `auth_token` —— 身份令牌（十六进制字符串）
///   - `ct0`        —— CSRF token（**必须** 32 位十六进制，X 会校验）
///
/// 使用流程：
///   1. 「在浏览器登录」→ 登录 x.com → F12 → Application → Cookies
///   2. 分别复制两行的值填入；**或**把整段 cookie 串直接粘进任一框（自动拆分）
///   3. 「保存并验证」→ 调 X 接口确认有效 → 显示「已登录 @用户名」
class AccountSection extends StatefulWidget {
  const AccountSection({super.key});

  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  late final TextEditingController _authTokenCtrl;
  late final TextEditingController _ct0Ctrl;

  bool _obscure = true;
  bool _verifying = false;

  /// 自动拆分时防止 onChanged 递归
  bool _applying = false;

  /// 'saved' = 已保存并通过验证；'invalid' = 输入有问题；'expired' = 保存了但没通过验证
  String? _status;
  String _statusText = '';

  /// 除 auth_token / ct0 之外的其它 cookie（`twid` / `kdt` / `guest_id` …）。
  ///
  /// **原版 X-Spider 保存的是整段 cookie**，我们这里两个框只负责展示最关键的两项，
  /// 其余字段原样保留，避免因裁剪导致 X 的接口判定为未认证。
  final Map<String, String> _extras = {};

  @override
  void initState() {
    super.initState();
    final appState = context.read<AppState>();
    // 已有 cookie 时回填两个框（并保留其它字段）
    final parsed = _parseCookie(appState.cookie);
    _authTokenCtrl = TextEditingController(text: parsed?.$1 ?? '');
    _ct0Ctrl = TextEditingController(text: parsed?.$2 ?? '');
    if (appState.cookie.isNotEmpty) _rememberExtras(appState.cookie);
    _autoFillFromClipboard();
  }

  @override
  void dispose() {
    _authTokenCtrl.dispose();
    _ct0Ctrl.dispose();
    super.dispose();
  }

  // ── 解析 / 校验 ────────────────────────────────────────────

  /// 从各种可能的粘贴格式里解析出 (auth_token, ct0)；解析不出返回 null。
  ///
  /// 用户从浏览器复制时形态各异，这里要都能吃下：
  ///  - `auth_token=xxx; ct0=yyy`              （标准 cookie 串）
  ///  - `cookie: auth_token=xxx; ct0=yyy`      （复制整个请求头行）
  ///  - `auth_token=xxx` 换行 `ct0=yyy`
  ///  - DevTools 表格：`auth_token<TAB>xxx<TAB>.x.com …`
  ///  - 键值顺序颠倒、带引号、带 URL 编码
  ///  - 纯值（整段里唯一的 32 位 hex 会被认作 ct0）
  (String, String)? _parseCookie(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    String? at;
    String? ct0;

    // ① 按 k=v 片段解析（分号 / 换行 / Tab 都当分隔符）
    for (final part in text.split(RegExp(r'[;\r\n\t]+'))) {
      final s = part.trim();
      if (s.isEmpty) continue;
      final i = s.indexOf('=');
      if (i <= 0) continue;
      var k = s.substring(0, i).trim().toLowerCase();
      // "cookie: auth_token" → "auth_token"
      final colon = k.lastIndexOf(':');
      if (colon >= 0) k = k.substring(colon + 1).trim();
      final v = s.substring(i + 1).trim().replaceAll('"', '');
      if (k == 'auth_token' && v.isNotEmpty && at == null) at = v;
      if (k == 'ct0' && v.isNotEmpty && ct0 == null) ct0 = v;
    }

    // ② DevTools 表格等「label 后跟值」的形态
    at ??= _valueAfterLabel(text, 'auth_token');
    ct0 ??= _valueAfterLabel(text, 'ct0');

    // ③ 兜底：整段里带标签、但值没被 ①② 抓到时，按 hex 形态捞
    //    （要求文本里确实出现标签名，避免把「单独粘贴的一个值」误拆）
    final lower = text.toLowerCase();
    if (ct0 == null && lower.contains('ct0')) {
      final m = RegExp(r'[0-9a-f]{32}').firstMatch(lower);
      if (m != null) ct0 = m.group(0);
    }
    if (at == null && lower.contains('auth_token')) {
      final m = RegExp(r'[0-9a-f]{35,80}').firstMatch(lower);
      if (m != null && m.group(0) != ct0) at = m.group(0);
    }

    if (at == null || ct0 == null || at == ct0) return null;
    return (at, ct0);
  }

  /// 取 label 之后第一个「像值」的片段（Tab / 空格 / `=` / `:` 分隔都容忍）。
  String? _valueAfterLabel(String text, String label) {
    final idx = text.toLowerCase().indexOf(label.toLowerCase());
    if (idx < 0) return null;
    var rest = text.substring(idx + label.length);
    rest = rest.replaceFirst(RegExp(r'^[\s=:]+'), '');
    final m = RegExp(r'^([^\s;,\t]+)').firstMatch(rest);
    final v = m?.group(1)?.trim().replaceAll('"', '');
    if (v == null || v.isEmpty) return null;
    final lower = v.toLowerCase();
    if (lower == 'ct0' || lower == 'auth_token') return null;
    return v;
  }

  /// 兜底整理：把误粘进某个框的「整段 cookie」拆开 / 提取出合法值。
  /// 返回是否改动过。
  bool _normalizeInputs() {
    final atRaw = _authTokenCtrl.text.trim();
    final ct0Raw = _ct0Ctrl.text.trim();
    if (atRaw.isEmpty && ct0Raw.isEmpty) return false;

    // ① 两框内容拼起来整体解析（覆盖「整段粘进某一个框」）
    final parsed = _parseCookie('$atRaw\n$ct0Raw');
    if (parsed != null && (parsed.$1 != atRaw || parsed.$2 != ct0Raw)) {
      _setBoth(parsed.$1, parsed.$2);
      _rememberExtras('$atRaw\n$ct0Raw');
      return true;
    }

    // ② 逐框提取：从长串里捞出合法的值
    var changed = false;
    var ct0 = ct0Raw;
    if (ct0.isNotEmpty && !_isHex(ct0, 32)) {
      final m = RegExp(r'[0-9a-f]{32}').firstMatch(ct0.toLowerCase());
      if (m != null) {
        ct0 = m.group(0)!;
        _setCt0(ct0);
        changed = true;
      }
    }

    final at = _authTokenCtrl.text.trim();
    if (at.isNotEmpty &&
        (at.length < 20 || at.contains(RegExp(r'[=;\s,\t]')))) {
      final m = RegExp(r'[0-9a-f]{35,80}').firstMatch(at.toLowerCase());
      if (m != null && m.group(0) != ct0) {
        _setAuthToken(m.group(0)!);
        changed = true;
      }
    }
    return changed;
  }

  void _setBoth(String at, String ct0) {
    _applying = true;
    _authTokenCtrl.text = at;
    _ct0Ctrl.text = ct0;
    _applying = false;
  }

  void _setAuthToken(String v) {
    _applying = true;
    _authTokenCtrl.text = v;
    _applying = false;
  }

  void _setCt0(String v) {
    _applying = true;
    _ct0Ctrl.text = v;
    _applying = false;
  }

  /// 合并成 X 需要的 cookie 串。
  ///
  /// **尽可能还原完整 cookie**：两个框 + 解析出来的其它字段，
  /// 而不是只发 auth_token + ct0（原版就是发整段）。
  String get _mergedCookie {
    final parts = <String>[
      'auth_token=${_authTokenCtrl.text.trim()}',
      'ct0=${_ct0Ctrl.text.trim()}',
      for (final e in _extras.entries) '${e.key}=${e.value}',
    ];
    return parts.join('; ');
  }

  /// 把整段 cookie 解析成完整 map（含所有字段）。
  Map<String, String> _parseAll(String raw) {
    final out = <String, String>{};
    for (final part in raw.split(RegExp(r'[;\r\n\t]+'))) {
      final s = part.trim();
      if (s.isEmpty) continue;
      final i = s.indexOf('=');
      if (i <= 0) continue;
      var k = s.substring(0, i).trim().toLowerCase();
      final colon = k.lastIndexOf(':');
      if (colon >= 0) k = k.substring(colon + 1).trim();
      final v = s.substring(i + 1).trim().replaceAll('"', '');
      if (k.isEmpty || v.isEmpty) continue;
      if (!RegExp(r'^[a-z0-9_.\-]+$').hasMatch(k)) continue;
      out[k] = v;
    }
    return out;
  }

  /// 记住除两个主字段外的其它 cookie 字段（只增不减，避免误清空）。
  void _rememberExtras(String raw) {
    _parseAll(raw).forEach((k, v) {
      if (k == 'auth_token' || k == 'ct0') return;
      _extras[k] = v;
    });
  }

  /// 是否恰好是指定长度的十六进制串。
  bool _isHex(String s, int len) =>
      s.length == len && RegExp('^[0-9a-fA-F]{$len}\$').hasMatch(s);

  // ── 输入 / 导入 ────────────────────────────────────────────

  /// 把整段 cookie 粘进任一框时自动拆分到两个框。
  void _maybeAutoSplit(String value) {
    if (_applying) return;
    final lower = value.toLowerCase();
    if (!lower.contains('auth_token') && !lower.contains('ct0')) return;

    final parsed = _parseCookie(value);
    if (parsed == null) return;

    // 解析结果就等于输入本身 → 用户是在填单个值，不拆
    final v = value.trim();
    if (parsed.$1 == v || parsed.$2 == v) return;

    _applying = true;
    _authTokenCtrl.text = parsed.$1;
    _ct0Ctrl.text = parsed.$2;
    _applying = false;
    _rememberExtras(value);
    setState(() {
      _status = null;
      _statusText = '已自动拆分 auth_token 与 ct0';
    });
  }

  /// 进入页面时自动检测剪贴板
  Future<void> _autoFillFromClipboard() async {
    final appState = context.read<AppState>();
    if (appState.isLoggedIn) return;
    if (_authTokenCtrl.text.isNotEmpty || _ct0Ctrl.text.isNotEmpty) return;
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      final parsed = _parseCookie(clip?.text ?? '');
      if (parsed == null) return;
      if (!mounted) return;
      _rememberExtras(clip?.text ?? '');
      setState(() {
        _authTokenCtrl.text = parsed.$1;
        _ct0Ctrl.text = parsed.$2;
        _status = null;
        _statusText = '已从剪贴板自动填充，点击「保存并验证」';
      });
    } catch (_) {
      // 剪贴板不可用（远程桌面等）→ 静默忽略
    }
  }

  /// 从剪贴板智能导入整段 cookie
  Future<void> _importFromClipboard() async {
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clip?.text ?? '';
      if (text.trim().isEmpty) {
        _toast(t('剪贴板为空'), AppToastKind.error);
        return;
      }
      final parsed = _parseCookie(text);
      if (parsed == null) {
        _toast(t('剪贴板里没有同时找到 auth_token 与 ct0'), AppToastKind.error);
        return;
      }
      _rememberExtras(text);
      setState(() {
        _authTokenCtrl.text = parsed.$1;
        _ct0Ctrl.text = parsed.$2;
        _status = null;
        _statusText = '已从剪贴板导入 auth_token 与 ct0';
      });
    } catch (_) {
      _toast(t('剪贴板访问失败'), AppToastKind.error);
    }
  }

  // ── 保存 / 验证 / 退出 ─────────────────────────────────────

  Future<void> _save() async {
    // 兜底：整段 cookie 被粘进了某个框 → 先尝试自动拆分
    final autoFixed = _normalizeInputs();

    final at = _authTokenCtrl.text.trim();
    final ct0 = _ct0Ctrl.text.trim();

    if (at.isEmpty || ct0.isEmpty) {
      setState(() {
        _status = 'invalid';
        _statusText = 'auth_token 和 ct0 都要填';
      });
      return;
    }
    if (!_isHex(ct0, 32)) {
      setState(() {
        _status = 'invalid';
        _statusText = ct0.length > 40
            ? 'ct0 框里不是单个值（${ct0.length} 字符），也没能找到 32 位十六进制。'
                '请在 DevTools 里只复制 ct0 那一格的「Value」。'
            : 'ct0 必须是 32 位十六进制（当前 ${ct0.length} 位）';
      });
      return;
    }
    if (at.length < 20) {
      setState(() {
        _status = 'invalid';
        _statusText = 'auth_token 看起来不完整（当前 ${at.length} 位）';
      });
      return;
    }
    if (autoFixed) {
      _toast(t('已自动从粘贴内容中提取 auth_token 与 ct0'));
    }
    setState(() {
      _verifying = true;
      _status = null;
      _statusText = '正在验证…';
    });

    final appState = context.read<AppState>();
    await appState.setCookie(_mergedCookie);

    String? err;
    String? screenName;
    try {
      screenName = await appState.api.getCurrentUserScreenName();
      if (screenName == null) {
        err = '已保存，但没能确认登录状态（请检查网络或代理）';
      }
    } on XApiException catch (e) {
      err = '验证失败：${e.message}';
    } catch (e) {
      err = friendlyNetworkError(e) ?? '验证出错：$e';
    }

    if (!mounted) return;
    setState(() {
      _verifying = false;
      if (err == null) {
        _status = 'saved';
        _statusText = screenName != null && screenName.isNotEmpty
            ? '已登录 @${screenName.replaceFirst('@', '')}'
            : '已登录';
      } else {
        _status = 'expired';
        _statusText = err;
      }
    });
  }

  Future<void> _logout() async {
    final appState = context.read<AppState>();
    await appState.clearCookie();
    if (!mounted) return;
    setState(() {
      _authTokenCtrl.clear();
      _ct0Ctrl.clear();
      _extras.clear();
      _status = null;
      _statusText = '';
    });
    _toast(t('已退出登录'));
  }

  /// 在浏览器打开 x.com 登录页。
  ///
  /// 以前是裸 await：没有默认浏览器、或协议被系统拦下时 `launchUrl` 抛
  /// PlatformException，按钮点下去像死的 —— 连一句异常提示都没有。
  Future<void> _openLogin() async {
    try {
      await launchUrl(
        Uri.parse('https://x.com/login'),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '打不开浏览器：$e', kind: AppToastKind.error);
    }
  }

  /// 统一的顶部提示（与全站其它反馈同一个样式，不再用底部 SnackBar）
  void _toast(String text, [AppToastKind kind = AppToastKind.success]) {
    if (!mounted) return;
    AppToast.show(context, text, kind: kind);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final appState = context.watch<AppState>();
    final loggedIn = appState.isLoggedIn;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ① 登录状态行 —— 预览稿 `x-settings:441-442` 的 `.sw` + `.st2`：
        //    左侧「登录状态」+ 副题（已登录 @user / 尚未登录），右侧一枚胶囊徽章。
        //    这里**不是** SwitchRow：预览稿这一行右边是徽章而不是开关，
        //    开关会读成「可以在这里登出」，而登出是下面那一行的按钮。
        _StatusRow(
          label: t('登录状态'),
          subtitle: loggedIn
              ? (_status == 'saved' && _statusText.isNotEmpty
                  ? _statusText
                  : t('已登录 X 账号'))
              : (_statusText.isNotEmpty ? _statusText : t('尚未登录')),
          kind: loggedIn
              ? StatusKind.done
              : (_status == 'invalid' || _status == 'expired'
                  ? StatusKind.err
                  : StatusKind.wait),
          badgeText: t(loggedIn ? '已登录' : '未登录'),
        ),
        const SizedBox(height: 10),

        // ② 两个必填框 —— `auth_token` / `ct0` 是账号分区的本体，标签保留
        //    （settings_scope_test 的正控制就是拿这两个字串证明账号在 X 页）。
        _CookieField(
          label: 'auth_token',
          hint: t('十六进制字符串（约 40 位）'),
          controller: _authTokenCtrl,
          obscure: _obscure,
          colors: c,
          onChanged: _maybeAutoSplit,
        ),
        const SizedBox(height: 10),
        _CookieField(
          label: 'ct0',
          hint: t('32 位十六进制（CSRF token）'),
          controller: _ct0Ctrl,
          obscure: _obscure,
          colors: c,
          onChanged: _maybeAutoSplit,
        ),
        const SizedBox(height: 10),

        // ③ 合并后的 cookie 一览 + 「显示 / 复制」（预览稿 `:443-444` 的
        //    `.row` + `.field.mono` + 两枚 `.btn.sm`）。
        FieldRow(
          value: _obscure ? '••••••••••••••••（已隐藏）' : _mergedCookie,
          mono: true,
          buttons: [
            FieldButton(
              t(_obscure ? '显示' : '隐藏'),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            FieldButton(
              t('复制'),
              ghost: true,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _mergedCookie));
                _toast(t('已复制完整 cookie'));
              },
            ),
          ],
        ),
        const SizedBox(height: 10),

        // ④ 取凭据的两个入口（原版保留：登录页 + 智能导入）
        Row(
          children: [
            Expanded(
              child: _ActionButton(
                icon: Icons.open_in_browser_rounded,
                label: t('在浏览器登录'),
                onTap: _openLogin,
                filled: false,
                colors: c,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ActionButton(
                icon: Icons.content_paste_rounded,
                label: t('智能导入完整 cookie'),
                onTap: _importFromClipboard,
                filled: false,
                colors: c,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // ⑤ 提交 / 退出（预览稿 `:445-446`：重新登录 + 退出登录(danger)）。
        //    「重新登录」= 原「在浏览器登录」那条路径的显式入口；「退出登录」危险色。
        Row(
          children: [
            FilledButton.tonal(
              onPressed: _openLogin,
              style: FilledButton.styleFrom(minimumSize: Size.zero),
              child: Text(t('重新登录'), style: const TextStyle(fontSize: 11.5)),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: loggedIn ? _logout : null,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                foregroundColor: c.danger,
              ),
              child: Text(t('退出登录'), style: const TextStyle(fontSize: 11.5)),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _verifying ? null : _save,
              icon: _verifying
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.verified_outlined, size: 16),
              label: Text(t(_verifying ? '验证中…' : '保存并验证'),
                  style: const TextStyle(fontSize: 11.5)),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // ⑥ 获取方式说明 —— 平铺后常驻（原来它在分区展开态里）
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.line, width: 0.6),
          ),
          child: Text(
            t('获取方式：点「在浏览器登录」登录 x.com → 按 F12 → Application → '
                'Cookies → x.com → 找到 auth_token 与 ct0 两行，双击 Value 列复制值，'
                '分别填到上面两个框。\n'
                '省事做法：把整段 cookie（或直接从 DevTools 复制的多行内容）粘进任一框，'
                '会自动拆分出这两个值。'),
            style: TextStyle(fontSize: 11.5, color: c.textMuted, height: 1.55),
          ),
        ),
      ],
    );
  }
}

// ── 单个 cookie 输入框 ─────────────────────────────────────

class _CookieField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final bool obscure;
  final AppColors colors;
  final ValueChanged<String> onChanged;

  const _CookieField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.obscure,
    required this.colors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: c.textStrong,
            fontFamily: 'Consolas',
          ),
        ),
        const SizedBox(height: 5),
        TextField(
          controller: controller,
          obscureText: obscure,
          onChanged: onChanged,
          style: TextStyle(
            fontSize: 12.5,
            color: c.textStrong,
            fontFamily: 'Consolas',
          ),
          cursorColor: c.accent,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 12,
              color: c.textFaint,
              fontFamily: 'Consolas',
            ),
            filled: true,
            fillColor: c.surfaceSunken,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
      ],
    );
  }
}

// ── 登录状态行 ────────────────────────────────────────────

/// 「登录状态」这一行 —— 预览稿 `x-settings:441-442` 的 `.sw` + `.st2`。
///
/// 原来是自带图标、底色与「退出」按钮的状态条。平铺改造后按预览稿收成一行：
/// **左侧标题 + 副题，右侧一枚胶囊徽章**。退出按钮移到下面的操作行
/// （预览稿 `:446` 的「退出登录(danger)」也在那里），这一行只回答
/// 「现在登没登」。
///
/// 底色仍取 `surfaceSunken`（`.sw` 的凹陷块语义），与 [SwitchRow] 同一档 ——
/// 这一页上「一行设置」的视觉重量因此统一。
class _StatusRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final StatusKind kind;

  /// 徽章文案（已 `t()`）。
  final String badgeText;

  const _StatusRow({
    required this.label,
    required this.subtitle,
    required this.kind,
    required this.badgeText,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Container(
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
                Text(label,
                    style: TextStyle(fontSize: 12.5, color: c.textStrong)),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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
          StatusBadge(kind: kind, text: badgeText),
        ],
      ),
    );
  }
}

// ── 操作按钮 ──────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;
  final AppColors colors;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.filled,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color:
              filled ? colors.accent.withValues(alpha: 0.1) : colors.surfaceSunken,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: filled ? colors.accentLine : colors.line,
            width: 0.6,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14, color: filled ? colors.accent : colors.textNormal),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: filled ? colors.accent : colors.textStrong,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
