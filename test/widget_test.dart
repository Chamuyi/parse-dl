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

  group('WindowMaterial 持久化标识稳定', () {
    test('id 映射正确', () {
      expect(WindowMaterial.fromId('mica'), WindowMaterial.mica);
      expect(WindowMaterial.fromId('mica-alt'), WindowMaterial.micaAlt);
      expect(WindowMaterial.fromId('acrylic'), WindowMaterial.acrylic);
      expect(WindowMaterial.fromId('acrylic-thin'), WindowMaterial.acrylicThin);
      expect(WindowMaterial.fromId('none'), WindowMaterial.none);
    });

    test('未知值回退到 mica', () {
      expect(WindowMaterial.fromId('???'), WindowMaterial.mica);
      expect(WindowMaterial.fromId(null), WindowMaterial.mica);
    });

    test('持久化用的 id 与原版字符串完全一致', () {
      expect(WindowMaterial.mica.id, 'mica');
      expect(WindowMaterial.micaAlt.id, 'mica-alt');
      expect(WindowMaterial.acrylic.id, 'acrylic');
      expect(WindowMaterial.acrylicThin.id, 'acrylic-thin');
      expect(WindowMaterial.none.id, 'none');
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
