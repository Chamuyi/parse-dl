import 'dart:io';

import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/window_effect.dart';
import 'package:parse_dl/theme/window_material.dart';

/// 窗口材质的**映射**判据。
///
/// ### 为什么单测这个纯函数（2026-10-15）
///
/// `applyWindowMaterial` 要走原生通道，widget 测试里跑不起来，所以它
/// **长期零测试覆盖**。代价是里面一个真 bug 一直没人发现：
///
/// ```dart
/// // 修前（错）：
/// dark: material == WindowMaterial.mica ||
///       material == WindowMaterial.mica,
/// ```
///
/// 它拿「材质类型」当「窗口明暗」用 —— 浅色模式下选 Mica 传 `dark: true`、
/// 深色模式下选亚克力传 `dark: false`，**两种组合都反了**。真机表现是
/// 窗口的系统绘制部分（标题栏/边框）明暗与应用主题不符。
///
/// 修法：把「材质 → 效果」的查表抽成公开纯函数 [windowEffectOf]，`dark`
/// 由调用方按实际明暗传入。这样映射本身可测，而「dark 不许按材质猜」
/// 这件事由下面那条**源码守卫**钉住。
void main() {
  String readSource(String relativePath) {
    final f = File(relativePath);
    if (!f.existsSync()) {
      throw StateError('找不到 $relativePath（测试的工作目录应为仓库根）');
    }
    return f.readAsStringSync();
  }


  group('源码守卫：dark 不许按材质猜', () {
    // 这条钉的是**调用形态**，不是返回值 —— 上面那组测不出「dark 传错了」，
    // 因为 `dark` 是调用方给的参数，纯函数里看不到它。
    test('applyWindowMaterial 收 dark 参数，函数体里不得出现材质判断', () {
      final src = readSource('lib/services/window_effect.dart');

      // 前置：签名里必须收 dark（否则调用方无从指定明暗）
      expect(
        src,
        contains('required bool dark'),
        reason: 'dark 必须是必填参数 —— 原来它不在签名里，是函数内部按材质算的',
      );

      // 主判据：函数体里不许再出现 `material == WindowMaterial.mica`
      // 这类「拿材质当明暗」的写法。
      expect(
        src,
        isNot(contains('material == WindowMaterial.mica')),
        reason: 'dark 不许按材质类型推断 —— 它描述的是窗口外观的明暗，'
            '与选哪种材质无关（2026-10-15 修过的真 bug）',
      );
      expect(
        src,
        isNot(contains('material == WindowMaterial.mica')),
        reason: '同上',
      );
    });

    test('调用点按实际明暗传 dark，而不是按材质', () {
      final app = readSource('lib/app.dart');
      expect(
        app,
        contains('dark: brightness == Brightness.dark'),
        reason: '`app.dart` 是唯一的应用点，dark 必须来自 `_resolveBrightness` '
            '算出的实际明暗',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 4 档 → 3 个原生效果（2026-10-19 恢复，照抄图吧工具箱）
  // ══════════════════════════════════════════════════════════

  /// 判据本体：四档逐档钉死到原生效果。
  ///
  /// 抽成函数是为了让**负控制**能拿同一组断言去跑坏实现 —— 断言要是恒真，
  /// 坏实现也会绿，负控制就抓不到它。
  void assertFourWayMapping(acrylic.WindowEffect Function(WindowMaterial) f) {
    expect(f(WindowMaterial.mica), acrylic.WindowEffect.mica,
        reason: 'mica 必须落到 DWMSBT_MAINWINDOW');
    expect(f(WindowMaterial.micaAlt), acrylic.WindowEffect.tabbed,
        reason: 'mica-alt 必须落到 DWMSBT_TABBEDWINDOW（官方 Mica Alt）');
    expect(f(WindowMaterial.acrylic), acrylic.WindowEffect.acrylic,
        reason: 'acrylic 必须落到 DWMSBT_TRANSIENTWINDOW');
    expect(f(WindowMaterial.acrylicThin), acrylic.WindowEffect.acrylic,
        reason: '细亚克力没有原生档位，只能落到 acrylic');
  }

  group('材质 → 原生效果映射（4 档）', () {
    test('四档逐档钉死', () {
      assertFourWayMapping(windowEffectOf);
    });

    test('四档落到 3 个不同效果（恢复 4 档必须有实际后果）', () {
      final effects = WindowMaterial.values.map(windowEffectOf).toSet();
      expect(effects.length, 3,
          reason: '4 档应落到 3 个原生效果 —— 细亚克力与亚克力在原生层合并');
      expect(
        effects,
        containsAll(<acrylic.WindowEffect>[
          acrylic.WindowEffect.mica,
          acrylic.WindowEffect.tabbed,
          acrylic.WindowEffect.acrylic,
        ]),
      );
    });

    test('负控制：c10b41e 那版「恒返回 mica」会让逐档判据变红', () {
      expect(
        () => assertFourWayMapping((_) => acrylic.WindowEffect.mica),
        throwsA(isA<TestFailure>()),
        reason: '恒返回 mica 时这条判据必须红 —— 否则它测不出这次回退',
      );
    });

    test('负控制：mica 与 mica-alt 互换也会变红', () {
      expect(
        () => assertFourWayMapping((m) => switch (m) {
              WindowMaterial.mica => acrylic.WindowEffect.tabbed,
              WindowMaterial.micaAlt => acrylic.WindowEffect.mica,
              WindowMaterial.acrylic => acrylic.WindowEffect.acrylic,
              WindowMaterial.acrylicThin => acrylic.WindowEffect.acrylic,
            }),
        throwsA(isA<TestFailure>()),
        reason: '两档效果对调后逐档判据必须红',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 源码守卫：启动路径不许把配置里的材质覆盖成 Mica
  // ══════════════════════════════════════════════════════════

  group('源码守卫：启动路径按配置取材质', () {
    // 这一组钉的是 `app.dart` 里的**调用形态**，纯函数判据看不到它。
    //
    // 真缺陷（c10b41e 引入）：`app.dart` 里写的是
    //     visualStyle == AppStyle.winui ? WindowMaterial.mica : 配置值
    // e5c4b6e 删掉另三套风格后 `AppStyle` 只剩 winui 一个值，这个三元
    // **恒取 mica 分支** —— 用户在设置里选的亚克力在启动路径上被静默覆盖。
    // 上面那组「映射逐档钉死」全程绿，因为 `windowEffectOf` 本身是对的，
    // 错的是**没人拿配置值去调它**。
    /// 去掉 `//` 行注释与 `///` 文档注释，只留真正的代码。
    ///
    /// 必须先剥注释再判 —— 否则「解释旧写法」的注释本身会命中判据，
    /// 把一条守卫变成「谁也别想写清楚为什么改」（本条判据第一版就踩了）。
    String stripLineComments(String src) => src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('app.dart 不再按风格把材质强制成 mica', () {
      final code = stripLineComments(readSource('lib/app.dart'));

      // 主判据：不许出现「风格判断 + 落到 mica」这个组合
      expect(
        code,
        isNot(contains('visualStyle == AppStyle.winui')),
        reason: 'AppStyle 只剩 winui 一个值，任何 `== AppStyle.winui` 的三元'
            '都恒走一个分支。启动路径必须直接读配置里的材质。',
      );
      expect(
        code,
        isNot(contains('? WindowMaterial.mica')),
        reason: '启动路径不许把材质硬编码成 mica —— 那会让设置里的四档失效',
      );

      // 前置：必须真的从配置读（否则上一条可能因为「整段被删」而假绿）
      expect(
        code,
        contains('s.settings.appearance.windowMaterial'),
        reason: '必须从配置读材质，不是从别处',
      );
    });

    test('负控制：剥注释不会把真代码一起剥掉', () {
      // 若 stripLineComments 写错（比如整段过滤掉），上面的 isNot 会恒绿。
      const src = '''
// visualStyle == AppStyle.winui
final m = s.settings.appearance.windowMaterial;''';
      final code = stripLineComments(src);
      expect(code, isNot(contains('visualStyle == AppStyle.winui')),
          reason: '注释里的旧写法要被剥掉');
      expect(code, contains('s.settings.appearance.windowMaterial'),
          reason: '真代码必须留着 —— 否则守卫变成恒绿');
    });

    test('负控制：c10b41e 那版写法会被这条守卫判红', () {
      // 复刻当时的源码片段，证明上面两条 isNot 真的能命中。
      const broken = 'appearance.visualStyle == AppStyle.winui'
          ' ? WindowMaterial.mica'
          ' : s.settings.appearance.windowMaterial';
      expect(broken, contains('visualStyle == AppStyle.winui'),
          reason: '守卫的子串必须能命中旧写法，否则它是恒绿的');
      expect(broken, contains('? WindowMaterial.mica'));
    });
  });

  // ══════════════════════════════════════════════════════════
  // 能力边界：细亚克力落到亚克力
  // ══════════════════════════════════════════════════════════

  group('能力边界：acrylicThin 与 acrylic 同效果', () {
    test('两者落到同一个原生效果', () {
      expect(windowEffectOf(WindowMaterial.acrylicThin),
          windowEffectOf(WindowMaterial.acrylic));
      expect(windowEffectOf(WindowMaterial.acrylicThin),
          acrylic.WindowEffect.acrylic);
    });

    test('但亚克力组与 Mica 组确实不同（证明上一条不是「全都一样」）', () {
      expect(windowEffectOf(WindowMaterial.acrylicThin),
          isNot(windowEffectOf(WindowMaterial.mica)));
      expect(windowEffectOf(WindowMaterial.acrylic),
          isNot(windowEffectOf(WindowMaterial.micaAlt)));
    });

    test('负控制：「细亚克力并进 Mica 组」的坏实现会让上面两条变红', () {
      // 「反正分不出来，都算 mica」是这次回退最可能被偷懒成的那种实现。
      acrylic.WindowEffect lazyMerge(WindowMaterial m) =>
          m == WindowMaterial.mica || m == WindowMaterial.acrylicThin
              ? acrylic.WindowEffect.mica
              : windowEffectOf(m);

      expect(
        () => expect(lazyMerge(WindowMaterial.acrylicThin),
            windowEffectOf(WindowMaterial.acrylic)),
        throwsA(isA<TestFailure>()),
        reason: '细亚克力被并进 mica 组时「与 acrylic 同效果」必须红',
      );
      expect(
        () => expect(lazyMerge(WindowMaterial.acrylicThin),
            isNot(windowEffectOf(WindowMaterial.mica))),
        throwsA(isA<TestFailure>()),
        reason: '细亚克力被并进 mica 组时「与 mica 不同」必须红',
      );
    });
  });
}
