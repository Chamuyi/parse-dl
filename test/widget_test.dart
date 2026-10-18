import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/theme/window_material.dart';

void main() {
  group('Settings 与既有 {state, version} 配置格式兼容', () {
    /// 这段 JSON 是既有的 settings.json 结构（一份真实形状的样例）
    const legacyJson = '''
{
  "state": {
    "proxy": { "enable": true, "url": "http://127.0.0.1:7890", "useSystem": true },
    "download": {
      "saveDirBase": "D:\\\\demo\\\\dl",
      "dirTemplate": "%USER_NAME%%USER_SCREEN_NAME%",
      "fileNameTemplate": "%POST_TIME%%USER_NAME%%EXT%",
      "sameFileSkip": true
    },
    "app": { "autoCheckUpdate": false, "acceptPrerelease": false, "writeLogs": true },
    "appearance": {
      "themeMode": "system",
      "windowMaterial": "mica",
      "customTint": false,
      "tintColor": "#1d9bf0",
      "backgroundImage": "",
      "backgroundImageOpacity": 0.05
    }
  },
  "version": 3
}''';

    test('能正确解析既有配置', () {
      final s = Settings.decode(legacyJson);

      expect(s.proxy.enable, isTrue);
      expect(s.proxy.useSystem, isTrue);
      expect(s.download.saveDirBase, r'D:\demo\dl');
      expect(s.download.sameFileSkip, isTrue);
      expect(s.app.writeLogs, isTrue);
      expect(s.appearance.themeMode, ThemeMode2.system);
      expect(s.appearance.windowMaterial, WindowMaterial.mica);
      expect(s.appearance.backgroundImageOpacity, closeTo(0.05, 1e-9));
    });

    test('重新编码后仍是同一份结构', () {
      final s = Settings.decode(legacyJson);
      final root = jsonDecode(s.encode()) as Map<String, dynamic>;

      // 读的是 { state: {...}, version: 3 }
      expect(root['version'], 3);
      expect(root['state'], isA<Map<String, dynamic>>());

      final state = root['state'] as Map<String, dynamic>;
      expect(state.keys, containsAll(['proxy', 'download', 'app', 'appearance']));
      expect((state['appearance'] as Map)['windowMaterial'], 'mica');
    });

    test('往返编解码不丢字段', () {
      final a = Settings.decode(legacyJson);
      final b = Settings.decode(a.encode());

      expect(b.toJson(), equals(a.toJson()));
    });
  });


  // ══════════════════════════════════════════════════════════
  // 材质档位必须真的从配置读出来（2026-10-19）
  // ══════════════════════════════════════════════════════════

  group('材质档位不被硬编码', () {
    /// 一份最小的 {state, version} 配置骨架，只换 `windowMaterial` 一个字段。
    ///
    /// 不复用上面 group 里的 `legacyJson`（那是局部变量），这里自带一份，
    /// 保证这条判据只依赖材质字段本身。
    String withMaterial(String materialId) => '''
{"state":{"appearance":{"themeMode":"system","windowMaterial":"$materialId"}},"version":3}''';

    test('配置里写 mica-alt，读出来就是 mica-alt', () {
      // 上面「能正确解析既有配置」那条的 legacyJson 写的是 "mica"，
      // 而 mica 恰好也是回落值 —— 光靠它证明不了「字段真被读了」：
      // 把 fromJson 写成硬编码 mica 它照样绿。这条换个非默认档位。
      final s = Settings.decode(withMaterial('mica-alt'));
      expect(s.appearance.windowMaterial, WindowMaterial.micaAlt,
          reason: '配置里的 mica-alt 必须被读出来 —— 硬编码 mica 会让这条红');
      expect(s.appearance.themeMode, ThemeMode2.system,
          reason: '换材质不该影响同一份配置里的其他字段');
    });

    test('四个有效档位逐个往返（配置 → 对象 → 配置）', () {
      for (final m in WindowMaterial.values) {
        final a = Settings.decode(withMaterial(m.id));
        expect(a.appearance.windowMaterial, m, reason: '${m.id} 读丢了');
        final root = jsonDecode(a.encode()) as Map<String, dynamic>;
        expect((root['state'] as Map)['appearance']['windowMaterial'], m.id,
            reason: '${m.id} 写回配置时变了');
      }
    });

    test('已删除的 none 与坏值仍回落 mica', () {
      expect(Settings.decode(withMaterial('none')).appearance.windowMaterial,
          WindowMaterial.mica);
      expect(Settings.decode(withMaterial('garbage')).appearance.windowMaterial,
          WindowMaterial.mica);
    });

    test('负控制：硬编码 mica 会让上面两条变红', () {
      // c10b41e 那版就是 `windowMaterial: WindowMaterial.mica`（不读字段）。
      WindowMaterial hardcoded(String _) => WindowMaterial.mica;
      expect(
        () => expect(hardcoded('mica-alt'), WindowMaterial.micaAlt),
        throwsA(isA<TestFailure>()),
        reason: '硬编码时「mica-alt 读回 mica-alt」必须红',
      );
      expect(
        () => expect(hardcoded('acrylic'), WindowMaterial.acrylic),
        throwsA(isA<TestFailure>()),
      );
    });
  });

  group('ThemeMode2', () {
    test('id 映射与回退', () {
      expect(ThemeMode2.fromId('light'), ThemeMode2.light);
      expect(ThemeMode2.fromId('dark'), ThemeMode2.dark);
      expect(ThemeMode2.fromId('system'), ThemeMode2.system);
      expect(ThemeMode2.fromId('bogus'), ThemeMode2.system);
    });
  });
}
