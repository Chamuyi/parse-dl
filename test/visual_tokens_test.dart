import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 视觉令牌的"不再扩散"检查。
///
/// 2026-09-30 普查：`lib/theme/` 之外还有 34 处写死的 `Color(0x…)`，
/// `fontSize:` 字面量 238 处、**18 个不同取值**（其中 11.5 / 12.5 / 13.5 / 10.5 / 12.8
/// 这些半整数档占了 47%），间距数值 560 个、26 档、52% 不是 4 的倍数。
///
/// 一次性把这些收敛到 3 档字号 + 一套刻度，会改到 238+ 处文本的观感，
/// 而这个应用只有一套 125% DPI 的真机眼力可以核对 —— 那种改动不该盲放。
/// 所以这里先立**棘轮**：存量按文件逐个记账，只许变少不许变多；新增一个
/// 没登记的文件、或引入第 19 种字号，测试立刻红。
/// 存量清单要变小就同步改下面的基线数字（改小 = 进步，改大 = 需要说明理由）。
void main() {
  List<String> libDartFiles() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => f.path.replaceAll(r'\', '/'))
      .toList();

  String readSource(String path) => File(path).readAsStringSync();

  /// `lib/theme/` 之外允许存在的 `Color(0x…)` 数量，按文件记账。
  ///
  /// 里面这些是**合法**的：色板本体（`app_theme.dart`）、材质定义
  /// （`window_material.dart`），以及"数据本身就是颜色"的地方 ——
  /// `tint_picker.dart` 的预设色板、`dock.dart` 的品牌渐变、
  /// `material_picker.dart` 的缩略图底色。它们不是"组件绕过色板"。
  const colorHardcodeBaseline = <String, int>{
    'lib/widgets/tint_picker.dart': 21, // 预设色调列表：颜色就是数据
    'lib/widgets/dock.dart': 4, // 徽标渐变 / Logo 兜底色
    'lib/widgets/material_picker.dart': 3, // 材质缩略图的壁纸渐变
    'lib/widgets/nav_items.dart': 2, // 运行中红点（自带发光，不走语义色）
    'lib/pages/about_page.dart': 1,
    'lib/widgets/background_layer.dart': 1, // Color(0xFF000000 | 用户十六进制)
    'lib/widgets/sidebar_nav.dart': 1,
    'lib/widgets/title_bar.dart': 1,
  };

  test('色板之外的写死颜色只许变少，不许变多、不许冒出新文件', () {
    final offenders = <String>[];
    for (final path in libDartFiles()) {
      if (path.startsWith('lib/theme/')) continue;
      final n = RegExp(r'Color\(0x').allMatches(readSource(path)).length;
      final allowed = colorHardcodeBaseline[path];
      if (allowed == null) {
        if (n > 0) offenders.add('$path 有 $n 处未登记');
        continue;
      }
      if (n > allowed) {
        offenders.add('$path 从 $allowed 涨到 $n 处');
      }
    }
    expect(offenders, isEmpty, reason: '新增写死颜色请改走 AppColors 语义槽位');
  });

  /// 现存 18 档字号。新写代码请复用已有取值；要立正式刻度表时，
  /// 先把这张表收敉到 3~5 档并同步改所有调用点。
  const fontSizeBaseline = <String>{
    '8', '9', '10', '10.5', '11', '11.5', '12', '12.5', '12.8', '13', '13.5',
    '14', '14.5', '15', '17', '18', '22', '24',
  };

  test('字号不许再发明新档位', () {
    final found = <String>{};
    final rx = RegExp(r'fontSize:\s*([0-9.]+)');
    for (final path in libDartFiles()) {
      for (final m in rx.allMatches(readSource(path))) {
        found.add(m.group(1)!);
      }
    }
    final novel = found.difference(fontSizeBaseline).toList()..sort();
    expect(
      novel,
      isEmpty,
      reason: '出现了基线之外的字号 $novel —— 现存 ${fontSizeBaseline.length} 档'
          '已经太多，不要再加',
    );
  });

  test('状态色只能来自色板槽位，绿/琥珀不再各处手写', () {
    // 只禁"被当状态色用过"的那几个值。#F59E0B 也在 tint_picker 的预设色板里
    // 出现过，但那是**数据**（用户可挑的色调之一），不是状态色，不在禁止范围。
    final rx = RegExp(r'0xFF(34C759|1FA85C|E0A040|2EB85C|3BA55D)',
        caseSensitive: false);
    final hits = <String>[];
    for (final path in libDartFiles()) {
      if (path == 'lib/theme/app_theme.dart') continue; // 槽位本体在这
      final src = readSource(path);
      for (final m in rx.allMatches(src)) {
        hits.add('$path: ${m.group(0)}');
      }
    }
    expect(hits, isEmpty, reason: '请改用 c.success / c.warning');
  });

  test('success / warning / onSuccess 三个槽位真的被用上', () {
    // 只加槽位没人用 = 假收敛。这里要求至少各有一处调用。
    final src = libDartFiles()
        .where((p) => !p.startsWith('lib/theme/'))
        .map(readSource)
        .join('\n');
    for (final slot in ['success', 'warning', 'onSuccess']) {
      // `c.success` / `colors.success` 都算；但不能把 `AppToastKind.success`
      // 当成槽位被用上了，所以要求点号前面是变量名而不是枚举类型名。
      final n = RegExp('(?<![A-Za-z])(c|colors|palette)\\.$slot\\b')
          .allMatches(src)
          .length;
      expect(n, greaterThan(0), reason: 'AppColors.$slot 没有任何调用点');
    }
  });
}
