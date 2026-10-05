import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../widgets/app_toast.dart';
import '../services/app_paths.dart';
import '../services/webview2_version.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';

/// 进程级缓存：WebView2 版本在运行期不会变，只查一次注册表。
/// （Dart 的顶层 `final` 是惰性的，首次访问才发起查询。）
final Future<String?> _webView2 = webView2Version();

/// 「关于」页面。
///
/// 内容组织参照常见桌面软件：标识区 → 版本信息 → 数据与诊断 → 开源组件。
/// **不写「基于某某项目二次开发」** —— 用户 2026-09-20 明确要求；许可证本身
/// 照实声明（见 [_kThirdParty] 与 app.dart 的 `license`）。
///
/// 版本号和许可证通过编译期常量注入（在 `app.dart` 里通过 `aboutInfo` 传入），
/// 避免在运行时读取 package_config。
class AboutPage extends StatelessWidget {
  final AboutInfo info;

  const AboutPage({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 16),
      children: [
        // ── 标识 + 基本信息 ────────────────────────────────
        AppCard(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const _LogoBadge(),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t(info.name),
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            color: c.textStrong,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t(info.tagline),
                          style: TextStyle(fontSize: 13.5, color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 22),

              _InfoRow(
                label: t('版本号'),
                colors: c,
                child: _VersionBadge(value: info.version, colors: c),
              ),
              _InfoRow(
                label: t('作者'),
                colors: c,
                child: Text(
                  info.author,
                  style: TextStyle(color: c.textStrong),
                ),
              ),
              _InfoRow(
                label: t('许可证'),
                colors: c,
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  children: [
                    Text(
                      info.license,
                      style: TextStyle(color: c.textStrong),
                    ),
                    _LinkText(
                      text: t('条款全文'),
                      url: 'https://www.gnu.org/licenses/gpl-3.0.html',
                      colors: c,
                    ),
                  ],
                ),
              ),
              _InfoRow(
                label: t('系统要求'),
                colors: c,
                child: Text(
                  t('Windows 10 64 位及以上 · 需 WebView2 Runtime'),
                  style: TextStyle(color: c.textNormal, fontSize: 13),
                ),
              ),
            ],
          ),
        ),

        // ── 数据与诊断 ─────────────────────────────────────
        AppCard(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle(t('本机环境与数据'), c),
              const SizedBox(height: 6),
              Text(
                t('反馈问题时把这几项一并附上即可。'
                    '本程序不含遥测、也不自动更新。'),
                style: TextStyle(fontSize: 12.5, color: c.textMuted, height: 1.6),
              ),
              const SizedBox(height: 10),
              _DiagRow(
                label: t('本机系统'),
                value: Platform.operatingSystemVersion,
                colors: c,
              ),
              FutureBuilder<String?>(
                future: _webView2,
                builder: (context, snap) => _DiagRow(
                  label: 'WebView2',
                  value: switch (snap.connectionState) {
                    ConnectionState.done =>
                      snap.data ?? t('未检测到（抖音页会加载失败）'),
                    _ => t('读取中…'),
                  },
                  colors: c,
                ),
              ),
              _DiagRow(
                label: t('数据目录'),
                value: AppPaths.configDir.path,
                openPath: AppPaths.configDir.path,
                colors: c,
              ),
              _DiagRow(
                label: t('日志目录'),
                value: AppPaths.logsDir.path,
                openPath: AppPaths.logsDir.path,
                colors: c,
              ),
            ],
          ),
        ),

        // ── 开源组件 ───────────────────────────────────────
        AppCard(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle(t('使用的开源组件'), c),
              const SizedBox(height: 10),
              for (final e in _kThirdParty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 148,
                        child: Text(
                          e.name,
                          style: TextStyle(
                            fontSize: 13,
                            color: c.textStrong,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          t(e.license),
                          style: TextStyle(fontSize: 12.5, color: c.textMuted),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 「关于」页需要的全部数据。
class AboutInfo {
  final String name;
  final String tagline;
  final String version;
  final String author;
  final String license;

  const AboutInfo({
    required this.name,
    required this.tagline,
    required this.version,
    required this.author,
    required this.license,
  });
}

/// 随产品分发的第三方组件及其许可证。
///
/// 只列**打进安装包**的那些（aria2 是 exe 本体，其余是运行库）；
/// pub 依赖里的纯 Dart 工具库不单列，避免这张表变成没人维护的清单。
const List<({String name, String license})> _kThirdParty = [
  (name: 'Flutter SDK', license: 'BSD-3-Clause'),
  (name: 'aria2', license: 'GPL-2.0-or-later（捆绑 aria2c.exe）'),
  (name: 'WebView2 Runtime', license: '微软专有运行时，需系统已安装'),
  (name: 'webview_windows', license: 'MIT'),
  (name: 'flutter_acrylic', license: 'MIT'),
  (name: 'window_manager', license: 'MIT'),
  (name: 'provider / file_picker', license: 'MIT / BSD-3-Clause'),
];

/// 应用标识 —— 直接用 `assets/logo.png`，与 exe / 任务栏 / 安装包同源。
///
/// 之前这里是一个手画的「渐变方块 + 下载图标」，跟真正的图标不是一回事，
/// 换图标时容易漏改（也确实漏过）。
class _LogoBadge extends StatelessWidget {
  const _LogoBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5B8DFF).withValues(alpha: 0.32),
            blurRadius: 22,
            spreadRadius: -4,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset('assets/logo.png', fit: BoxFit.cover),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final AppColors c;
  const _SectionTitle(this.text, this.c);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: c.textStrong,
        letterSpacing: 0.2,
      ),
    );
  }
}

/// 一行「label + 路径 + 打开」。路径过长时中间省略，保留尾部便于辨认。
/// 诊断区的一行：label + 值，给了 [openPath] 才带「打开」。
///
/// 路径值从**尾部**截断（开头都是 `C:\Users\xxx`，留头没意义）。
class _DiagRow extends StatelessWidget {
  final String label;
  final String value;
  final String? openPath;
  final AppColors colors;

  const _DiagRow({
    required this.label,
    required this.value,
    required this.colors,
    this.openPath,
  });

  @override
  Widget build(BuildContext context) {
    final path = openPath;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: colors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: path == null ? null : TextDirection.rtl,
              style: TextStyle(fontSize: 12.5, color: colors.textNormal),
            ),
          ),
          if (path != null) ...[
            const SizedBox(width: 6),
            _LinkText(
              text: t('打开'),
              url: '',
              colors: colors,
              onTap: () async {
                final why = await _openDir(path);
                if (why == null || !context.mounted) return;
                AppToast.show(context, why, kind: AppToastKind.error);
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// 单条信息行（label + 内容）。
class _InfoRow extends StatelessWidget {
  final String label;
  final Widget child;
  final AppColors colors;

  const _InfoRow({
    required this.label,
    required this.child,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: colors.textMuted),
            ),
          ),
          Expanded(
            child: DefaultTextStyle.merge(
              style: TextStyle(fontSize: 14, color: colors.textStrong),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// 版本号药丸标签。
class _VersionBadge extends StatelessWidget {
  final String value;
  final AppColors colors;
  const _VersionBadge({required this.value, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: colors.accent.withValues(alpha: 0.3),
          width: 0.6,
        ),
      ),
      child: Text(
        'v$value',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: colors.accent,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 可点击的文字链接。给了 [onTap] 就走它，否则按 [url] 开浏览器。
class _LinkText extends StatelessWidget {
  final String text;
  final String url;
  final AppColors colors;
  final VoidCallback? onTap;

  const _LinkText({
    required this.text,
    required this.url,
    required this.colors,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap ?? () async {
          final why = await _openUrl(url);
          if (why == null || !context.mounted) return;
          AppToast.show(context, why, kind: AppToastKind.error);
        },
        child: Text(
          text,
          style: TextStyle(
            color: colors.accent,
            decoration: TextDecoration.underline,
            decorationColor: colors.accent.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// 调起系统默认浏览器打开 url。
///
/// url_launcher 在 Windows 上通过 ShellExecute 实现：失败仅影响「点链接没反应」，
/// 不会让应用崩溃。
/// **返回给用户看的原因**，`null` 表示成功。以前 `catch (_) {}` 空吞，
/// 没有默认浏览器 / 协议被系统拦下时，点链接就是完全没反应。
Future<String?> _openUrl(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    return null;
  } catch (e) {
    return '打不开这个链接：$e';
  }
}

/// 在资源管理器里打开目录。目录还没生成时先建出来，否则「打开」会没反应。
///
/// **返回给用户看的原因**，`null` 表示成功。以前是 `catch (_) {}` 空吞：
/// 资源管理器被系统策略拦住、或路径在移动硬盘上还没挂载时，点「打开」
/// 完全没反应，用户只会以为按钮坏了。
Future<String?> _openDir(String path) async {
  try {
    final d = Directory(path);
    if (!await d.exists()) await d.create(recursive: true);
    await Process.run('explorer', [path]);
    return null;
  } catch (e) {/* 打不开不影响主流程，但必须让用户知道 */
    return '打不开这个目录：$e';
  }
}
