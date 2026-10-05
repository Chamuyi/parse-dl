import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/webview2_version.dart';

/// 读注册表依赖本机环境，所以把「解析 reg 输出」抽成纯函数单独测；
/// 真实读取只在本机跑一次核对（实测命中 143.0.3650.96）。
void main() {
  group('parseRegPv', () {
    test('标准输出里取出版本号', () {
      const out = r'''

HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}
    pv    REG_SZ    143.0.3650.96

''';
      expect(parseRegPv(out), '143.0.3650.96');
    });

    test('键不存在（只有错误提示）→ null', () {
      expect(
        parseRegPv('ERROR: The system was unable to find the specified registry key.'),
        isNull,
      );
    });

    test('pv 行缺值 → null，不返回空串', () {
      expect(parseRegPv('    pv    REG_SZ'), isNull);
    });

    test('值里带空格也不被截断', () {
      expect(parseRegPv('    pv    REG_SZ    1.2.3.4 beta'), '1.2.3.4 beta');
    });

    test('多行时取第一个 pv', () {
      const out = '    pv    REG_SZ    111.0.0.1\n    pv    REG_SZ    222.0.0.2';
      expect(parseRegPv(out), '111.0.0.1');
    });
  });

  group('要试的注册表键', () {
    test('三条，按机器级 → 用户级排列，都以 GUID 结尾', () {
      final keys = webView2RegKeys();
      expect(keys, hasLength(3));
      for (final k in keys) {
        expect(k.endsWith(kWebView2ClientGuid), isTrue, reason: k);
      }
      expect(keys[0], contains('WOW6432Node'), reason: '64 位系统上机器级最常见这个');
      expect(keys[2], startsWith('HKCU'), reason: '用户级安装兜底');
    });
  });
}
