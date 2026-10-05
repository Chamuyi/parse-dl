import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/widgets/nav_items.dart';

/// 模块入口的展开 / 收起状态。
///
/// 需求原文：「侧边栏入口支持点击展开 / 点击收起」、
/// 「展开收起行为以该统一入口为交互主体，不拆分为多个独立入口分别控制」，
/// 以及 2026-09-19 的「这个侧边栏默认不要展开」。
///
/// 落地为三条：
///   1. 缺省 = **收起**（侧边栏一进来是干净的两行，不铺一屏子项）；
///   2. 点一下切换，且**只影响自己那一个模块**；
///   3. 状态写进设置、能读回来（下次启动保持）。
void main() {
  group('缺省状态', () {
    test('两个模块默认都是收起的', () {
      final a = AppearanceSettings();
      for (final g in kNavGroups) {
        expect(a.isNavGroupExpanded(g.id), isFalse,
            reason: '${g.label} 默认应当收起');
      }
    });

    test('没记录过的模块 id 也算收起（以后新增模块不会自己冒出来）', () {
      final a = AppearanceSettings();
      expect(a.isNavGroupExpanded('将来才有的模块'), isFalse);
    });
  });

  group('点击展开 / 收起', () {
    test('点一下展开，再点一下收起', () {
      final a = AppearanceSettings();

      a.toggleNavGroup('x');
      expect(a.isNavGroupExpanded('x'), isTrue);

      a.toggleNavGroup('x');
      expect(a.isNavGroupExpanded('x'), isFalse);
    });

    test('两个模块的展开状态互相独立（这是"不合并"的直接体现）', () {
      final a = AppearanceSettings();

      a.toggleNavGroup('x'); // 只展开 X 下载

      expect(a.isNavGroupExpanded('x'), isTrue);
      expect(a.isNavGroupExpanded('douyin'), isFalse,
          reason: '展开 X 下载不该把抖音也带开');
    });

    test('两个模块都展开后再逐个收起，互不干扰', () {
      final a = AppearanceSettings();

      a.toggleNavGroup('x');
      a.toggleNavGroup('douyin');
      expect(a.isNavGroupExpanded('x'), isTrue);
      expect(a.isNavGroupExpanded('douyin'), isTrue);

      a.toggleNavGroup('douyin');
      expect(a.isNavGroupExpanded('douyin'), isFalse);
      expect(a.isNavGroupExpanded('x'), isTrue);
    });
  });

  group('持久化', () {
    test('展开状态能写进 JSON 并读回来，另一个模块不受影响', () {
      final a = AppearanceSettings()..toggleNavGroup('douyin');

      final back = AppearanceSettings.fromJson(a.toJson());

      expect(back.isNavGroupExpanded('douyin'), isTrue);
      expect(back.isNavGroupExpanded('x'), isFalse);
    });

    test('旧配置里没有这个字段 → 按收起处理，不因升级报错', () {
      final old = {
        'themeMode': 'system',
        'windowMaterial': 'mica',
        'navLayout': 'dock',
      };

      final a = AppearanceSettings.fromJson(old);
      expect(a.isNavGroupExpanded('x'), isFalse);
      expect(a.isNavGroupExpanded('douyin'), isFalse);
    });

    test('字段是空 map 时也是收起', () {
      final a = AppearanceSettings.fromJson({'navGroupExpanded': {}});
      expect(a.isNavGroupExpanded('x'), isFalse);
    });

    test('字段值不是 bool 时按缺省读，不崩', () {
      final a = AppearanceSettings.fromJson({
        'navGroupExpanded': {'x': 'yes'},
      });
      expect(a.isNavGroupExpanded('x'), isFalse);
    });

    test('老用户存过的"展开"仍然生效（改缺省不覆盖用户的选择）', () {
      final a = AppearanceSettings.fromJson({
        'navGroupExpanded': {'x': true, 'douyin': true},
      });
      expect(a.isNavGroupExpanded('x'), isTrue);
      expect(a.isNavGroupExpanded('douyin'), isTrue);
    });

    test('往返两次不丢状态', () {
      final a = AppearanceSettings()..toggleNavGroup('x');
      final b = AppearanceSettings.fromJson(a.toJson());
      final c = AppearanceSettings.fromJson(b.toJson());

      expect(c.isNavGroupExpanded('x'), isTrue);
      expect(c.toJson()['navGroupExpanded'], {'x': true});
    });
  });
}
