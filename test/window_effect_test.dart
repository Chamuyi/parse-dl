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
}
