import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/theme/window_material.dart';

/// 窗口材质**枚举层**的判据（2026-10-19 恢复 4 档）。
///
/// 覆盖两件事：
///   1. 4 档的 id 与 `fromId` 迁移矩阵（含已删除的 `none`）；
///   2. 材质不可用时的回退底色 `fallbackTo`。
///
/// 每条主判据都配一条负控制：把实现换成 c10b41e 那版（只剩 mica /
/// 一律回落 mica）时它必须变红。判据恒绿与恒红一样没用。
void main() {
  // ══════════════════════════════════════════════════════════
  // 4 档与持久化 id
  // ══════════════════════════════════════════════════════════

  group('四档材质与持久化 id', () {
    test('枚举就是 4 档，顺序为 mica / mica-alt / acrylic / acrylic-thin', () {
      expect(
        WindowMaterial.values.map((m) => m.id).toList(),
        <String>['mica', 'mica-alt', 'acrylic', 'acrylic-thin'],
        reason: 'id 是写进 settings.json 的契约，定下就不能改',
      );
    });

    test('id 唯一（重复 id 会让 fromId 静默取到错的那档）', () {
      final ids = WindowMaterial.values.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('label / description 不含汉字（l10n 判据要求有英文对照）', () {
      final cjk = RegExp(r'[\u4e00-\u9fff]');
      for (final m in WindowMaterial.values) {
        expect(cjk.hasMatch(m.label), isFalse,
            reason: '${m.id} 的 label「${m.label}」含汉字，英文界面会夹中文');
        expect(cjk.hasMatch(m.description), isFalse,
            reason: '${m.id} 的 description 含汉字');
        expect(m.label.trim(), isNotEmpty);
        expect(m.description.trim(), isNotEmpty);
      }
    });

    test('负控制：把 label 换成汉字时上面那条必须红', () {
      final cjk = RegExp(r'[\u4e00-\u9fff]');
      expect(cjk.hasMatch('亚克力'), isTrue,
          reason: '正则本身抓不到汉字的话，上一条判据就是恒绿的');
    });
  });

  // ══════════════════════════════════════════════════════════
  // fromId 迁移矩阵
  // ══════════════════════════════════════════════════════════

  group('fromId 迁移矩阵', () {
    test('四个有效 id 原样往返（旧配置不会被改写档位）', () {
      for (final m in WindowMaterial.values) {
        expect(WindowMaterial.fromId(m.id), m,
            reason: '${m.id} 是有效档位，读回必须还是它');
      }
    });

    test('已删除的 none 回落到 mica（不报错、不黑窗）', () {
      expect(WindowMaterial.fromId('none'), WindowMaterial.mica);
    });

    test('坏值 / 空串 / null 都回落到 mica', () {
      for (final bad in <String?>['', 'bogus', 'MICA', 'mica_alt', null]) {
        expect(WindowMaterial.fromId(bad), WindowMaterial.mica,
            reason: '「$bad」不是有效 id，必须回落到 mica');
      }
    });

    test('负控制：c10b41e 那版「一律回落 mica」会让往返矩阵变红', () {
      // 砍档那版只剩一个枚举值，fromId 恒返回 mica —— 等价于下面这个函数。
      WindowMaterial broken(String? id) => WindowMaterial.mica;
      expect(
        () => expect(broken('acrylic'), WindowMaterial.acrylic),
        throwsA(isA<TestFailure>()),
        reason: '恒回落 mica 的实现必须让「acrylic 原样保留」变红',
      );
      expect(
        () => expect(broken('mica-alt'), WindowMaterial.micaAlt),
        throwsA(isA<TestFailure>()),
      );
      expect(
        () => expect(broken('acrylic-thin'), WindowMaterial.acrylicThin),
        throwsA(isA<TestFailure>()),
      );
    });

    test('负控制：「坏值也当成有效档位」的实现会让回落判据变红', () {
      // 另一种坏法：orElse 返回 values.first（mica）没问题，但如果
      // firstWhere 不带 orElse 就会抛 —— 用 try/catch 兜底成「返回 null」，
      // 下游再 ?? 一个非 mica 的值，坏值就静默变成别的档位了。
      WindowMaterial? broken(String? id) {
        try {
          return WindowMaterial.values.firstWhere((m) => m.id == id);
        } catch (_) {
          return null;
        }
      }

      expect(
        () => expect(broken('none') ?? WindowMaterial.mica,
            WindowMaterial.acrylic),
        throwsA(isA<TestFailure>()),
        reason: 'none 必须落 mica；落成 acrylic 时这条负控制证明判据会红',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 端到端：settings.json → AppearanceSettings
  // ══════════════════════════════════════════════════════════

  group('settings.json 端到端迁移', () {
    AppearanceSettings read(String? materialId) =>
        AppearanceSettings.fromJson(<String, dynamic>{
          'windowMaterial': ?materialId,
        });

    test('配置里的四个有效 id 都能读回对应档位', () {
      for (final m in WindowMaterial.values) {
        expect(read(m.id).windowMaterial, m,
            reason: '${m.id} 写进配置后重启必须还是它');
      }
    });

    test('旧配置的 none 回落到 mica', () {
      expect(read('none').windowMaterial, WindowMaterial.mica);
    });

    test('字段缺失 / 坏值回落到 mica', () {
      expect(read(null).windowMaterial, WindowMaterial.mica);
      expect(read('garbage').windowMaterial, WindowMaterial.mica);
    });

    test('负控制：c10b41e 那版硬编码 mica 会让上面两条变红', () {
      // 砍档那版 fromJson 写死 `windowMaterial: WindowMaterial.mica`，
      // 配置字段**根本没被读**。等价实现：
      AppearanceSettings brokenFromJson(Map<String, dynamic> j) =>
          AppearanceSettings(windowMaterial: WindowMaterial.mica);

      expect(
        () => expect(brokenFromJson({'windowMaterial': 'acrylic'}).windowMaterial,
            WindowMaterial.acrylic),
        throwsA(isA<TestFailure>()),
        reason: '硬编码 mica 时必须让「acrylic 读回 acrylic」变红 —— '
            '这正是 c10b41e 留下的真缺陷（用户选亚克力重启静默变回 Mica）',
      );
    });

    test('往返编解码保留非默认档位', () {
      for (final m in WindowMaterial.values) {
        final a = AppearanceSettings(windowMaterial: m);
        final b = AppearanceSettings.fromJson(a.toJson());
        expect(b.windowMaterial, m, reason: '${m.id} 往返后变了');
      }
    });
  });

  // ══════════════════════════════════════════════════════════
  // 回退色：材质不可用时用主题底色
  // ══════════════════════════════════════════════════════════

  group('fallbackTo：材质不可用时回退主题底色', () {
    // 半透明的主题底色（模拟调色层 alpha 0.85 那种令牌）
    const translucentBase = Color(0x8A2C2C2C);
    const opaqueBase = Color(0xFF2C2C2C);

    test('回退色强制不透明（材质没了只剩纯色，不能让桌面透出来）', () {
      for (final m in WindowMaterial.values) {
        final c = m.fallbackTo(translucentBase);
        expect(c.a, 1.0,
            reason: '${m.id} 的回退色必须不透明 —— 参照物 '
                'BackdropSettings.DeriveFallbackColor 也是强制 alpha=255');
      }
    });

    test('RGB 保持主题底色不变（只改 alpha，不换颜色）', () {
      for (final m in WindowMaterial.values) {
        final c = m.fallbackTo(translucentBase);
        expect([c.r, c.g, c.b],
            [translucentBase.r, translucentBase.g, translucentBase.b],
            reason: '${m.id} 的回退色改动了 RGB，那就不再是「主题底色」了');
      }
    });

    test('本来就是不透明的底色原样返回', () {
      for (final m in WindowMaterial.values) {
        expect(m.fallbackTo(opaqueBase), opaqueBase);
      }
    });

    test('四档的回退色相同（照抄参照物：FallbackColor 与材质档位无关）', () {
      final colors =
          WindowMaterial.values.map((m) => m.fallbackTo(translucentBase)).toSet();
      expect(colors.length, 1,
          reason: '参照物的 FallbackColor 只由主题色调派生，不随材质档位变');
    });

    test('负控制：原样返回半透明底色会让「强制不透明」变红', () {
      Color noop(Color base) => base;
      expect(
        () => expect(noop(translucentBase).a, 1.0),
        throwsA(isA<TestFailure>()),
        reason: '不做 alpha 强制的实现必须让「回退色不透明」变红',
      );
    });

    test('负控制：顺手换掉 RGB 会让「RGB 不变」变红', () {
      Color wash(Color base) => base.withValues(alpha: 1.0, red: 0.0);
      expect(
        () => expect([wash(translucentBase).r, wash(translucentBase).g,
            wash(translucentBase).b],
            [translucentBase.r, translucentBase.g, translucentBase.b]),
        throwsA(isA<TestFailure>()),
        reason: '把回退色当「重画一层」的实现必须让 RGB 判据变红',
      );
    });
  });
}
