/// 本机 WebView2 Runtime 的版本号；读不到返回 null。
///
/// **为什么不问 WebviewController**：关于页里没有 WebView 实例，为了读一个
/// 版本号去建一个 controller 太重。WebView2 Runtime 安装时会把版本写进注册表，
/// 这里按「机器级 → 用户级」依次试三个键，取第一个命中的。
///
/// 用 `reg query` 而不是 win32 绑定：省掉指针和内存管理，而这个调用只在
/// 打开关于页时发生一次，起一个进程的开销可以接受。
library;

import 'dart:io';

/// Edge WebView2 Runtime 的固定客户端 GUID（不是本机相关，写死即可）。
const String kWebView2ClientGuid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

/// 要试的注册表键，按优先级排列。
List<String> webView2RegKeys() {
  final s = Platform.pathSeparator;
  final clients = 'Microsoft${s}EdgeUpdate${s}Clients';
  return [
    'HKLM$s' 'SOFTWARE$s' 'WOW6432Node$s' '$clients$s' '$kWebView2ClientGuid',
    'HKLM$s' 'SOFTWARE$s' '$clients$s' '$kWebView2ClientGuid',
    'HKCU$s' 'Software$s' '$clients$s' '$kWebView2ClientGuid',
  ];
}

/// 从 `reg query ... /v pv` 的输出里抠出版本号。
///
/// 典型输出：
/// ```
/// HKEY_LOCAL_MACHINE\SOFTWARE\...\{F301...}
///     pv    REG_SZ    143.0.3650.96
/// ```
/// 抽成纯函数是为了能单测——真实读注册表依赖本机环境。
String? parseRegPv(String stdoutText) {
  for (final raw in stdoutText.split('\n')) {
    final line = raw.trim();
    if (!line.startsWith('pv')) continue;
    final parts = line.split(RegExp(r'\s{2,}'));
    // 至少要有 `pv  REG_SZ  <值>` 三段；有些语言/版本里类型列会缺
    final value = parts.length >= 3 ? parts.last.trim() : '';
    if (value.isNotEmpty && value != 'REG_SZ') return value;
  }
  return null;
}

/// 读不到返回 null。调用方负责显示成「未检测到」——WebView2 是硬依赖，
/// 装了本应用但缺它的话，抖音页会直接走「没装 WebView2 运行时」的错误分支。
Future<String?> webView2Version() async {
  if (!Platform.isWindows) return null;
  for (final key in webView2RegKeys()) {
    try {
      final r = await Process.run('reg', ['query', key, '/v', 'pv']);
      if (r.exitCode != 0) continue;
      final v = parseRegPv(r.stdout as String? ?? '');
      if (v != null) return v;
    } catch (_) {
      // reg 不可用 / 无权限：接着试下一个键，全失败就返回 null
    }
  }
  return null;
}
