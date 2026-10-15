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
///       material == WindowMaterial.micaAlt,
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

  group('材质 → 原生效果映射', () {
    test('四种材质各自落到哪个效果（逐条点名，不写恒真断言）', () {
      expect(windowEffectOf(WindowMaterial.mica), acrylic.WindowEffect.mica);
      expect(
          windowEffectOf(WindowMaterial.micaAlt), acrylic.WindowEffect.tabbed);
      expect(
          windowEffectOf(WindowMaterial.acrylic), acrylic.WindowEffect.acrylic);
      expect(
          windowEffectOf(WindowMaterial.none), acrylic.WindowEffect.disabled);
    });

    test('细亚克力与亚克力落到同一个效果 —— 库的能力边界，如实记录', () {
      // `flutter_acrylic` 只有 acrylic / mica / tabbed 三个效果，没有
      // 「细亚克力」。所以这两者必然相同 —— 真机截图一模一样是**预期**，
      // 不是「没生效」。若将来换库补上了这一档，这条会红，提醒改实现。
      expect(
        windowEffectOf(WindowMaterial.acrylicThin),
        windowEffectOf(WindowMaterial.acrylic),
        reason: 'flutter_acrylic 没有独立的「细亚克力」效果，只能落到 acrylic；'
            '换了支持该效果的库之后要改这里',
      );
    });

    test('五种材质的效果不全都一样（否则设置项等于没有）', () {
      final effects = {
        for (final m in WindowMaterial.values) windowEffectOf(m),
      };
      // mica / tabbed / acrylic / disabled 四档 → 至少 4 个不同取值
      expect(
        effects.length,
        greaterThanOrEqualTo(4),
        reason: '材质设置必须真的能改变窗口效果，否则那几个选项是装饰',
      );
    });

    test('关闭材质落到 disabled，不是某个半透明效果', () {
      expect(windowEffectOf(WindowMaterial.none), acrylic.WindowEffect.disabled,
          reason: '「纯色」就该关掉材质，不能还留一层模糊');
    });
  });

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
        isNot(contains('material == WindowMaterial.micaAlt')),
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
}
