import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/app_style.dart';

/// 按钮主题的判据（单风格版）。
///
/// ### 2026-10-19 重写（用户裁定「你去把其他的删了」）
///
/// 旧版测「三套风格的按钮两两不同」，风格删了就没有比较对象。
/// 换锚为「winui 按钮必须符合 WinUI3 规范」：
///   - 主按钮 = 纯色强调色，没有渐变（与玻璃系最大的形态差异）
///   - 普通按钮 = 极淡表层色 + 1px 边线 + 几乎无影
///   - 圆角走 field 档（4px）
void main() {
  StyleButton btn(Brightness b) => AppStyle.winui.buttonOf(b);

  group('winui 按钮令牌', () {
    test('主按钮是纯色强调色，没有渐变', () {
      final b = btn(Brightness.light);
      expect(b.primaryGradient, isNull,
          reason: 'WinUI 主按钮必须是纯色 —— 渐变是玻璃系的语言');
      expect(b.primaryColor, const Color(0xFF0078D4));
    });

    test('深色主按钮用亮一档的强调色（配深字）', () {
      expect(btn(Brightness.dark).primaryColor, const Color(0xFF4CC2FF));
    });

    test('普通按钮：极淡表层色 + 极淡边线', () {
      final l = btn(Brightness.light);
      expect(l.color.a, lessThan(0.10), reason: 'WinUI 普通按钮几乎是透明的');
      expect(l.borderColor.a, lessThan(0.20));
    });

    test('投影几乎为零（浮起感靠边线，不靠影）', () {
      final l = btn(Brightness.light);
      expect(l.shadow.blurRadius, lessThanOrEqualTo(2));
      expect(l.shadow.color.a, lessThan(0.10));
      expect(l.primaryShadow.color.a, lessThan(0.15));
    });

    test('没有顶部高光（那是玻璃系的 inset 高光）', () {
      expect(btn(Brightness.light).primaryTopHighlight, isNull);
    });

    test('负控制：深浅两档的主按钮色确实不同', () {
      expect(btn(Brightness.light).primaryColor,
          isNot(btn(Brightness.dark).primaryColor),
          reason: '若相同，说明上面「亮一档」的断言是恒真的');
    });
  });

  group('按钮圆角走 field 档', () {
    test('= 4px（WinUI3 控件圆角）', () {
      expect(AppStyle.winui.radiusOf(AppRadius.field), 4);
    });
  });

  group('buttonOf 只按明暗分流', () {
    test('light / dark 返回不同令牌', () {
      expect(btn(Brightness.light), isNot(btn(Brightness.dark)));
    });
  });
}
