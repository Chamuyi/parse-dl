import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/widgets/nav_items.dart';

/// 导航分组模型。
///
/// 需求形状：**侧边栏顶层就是两个模块**（不是「一个父项包住两个模块」），
/// 每个模块自己是一个「可点击展开的统一入口」。这个文件把形状钉死，
/// 免得以后有人又把它改回平铺或改回单父项。
void main() {
  group('两个模块并列且独立', () {
    test('正好两组：X 下载 / 抖音解析下载', () {
      expect(kNavGroups.length, 2);
      expect(kNavGroups[0].id, 'x');
      expect(kNavGroups[0].label, 'X 下载');
      expect(kNavGroups[1].id, 'douyin');
      expect(kNavGroups[1].label, '抖音解析下载');
    });

    test('X 组含 4 个功能页，顺序固定', () {
      expect(
        kNavGroups[0].children.map((e) => e.id).toList(),
        ['home', 'download-management', 'auto-task', 'x-settings'],
      );
    });

    test('抖音组的功能页与 X 组一一对应，顺序固定', () {
      expect(
        kNavGroups[1].children.map((e) => e.id).toList(),
        ['douyin', 'douyin-downloads', 'douyin-auto', 'douyin-settings'],
      );
    });

    test('两个模块的设置是**两个不同页面**（不合并成一处）', () {
      final xSettings = kNavGroups[0].children.last;
      final dySettings = kNavGroups[1].children.last;

      // 名字自带归属：三条都叫「设置」时，Dock 形态下两个滑杆图标 + 相同文字
      // 根本分不出点的是哪一个。
      expect(xSettings.label, 'X 下载设置');
      expect(dySettings.label, '抖音设置');
      expect(xSettings.id, isNot(dySettings.id));
    });

    test('导航 id 全局唯一（否则高亮会同时亮两处）', () {
      final ids = kNavItems.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length, reason: '有重复 id：$ids');
    });

    test('全局项不属于任何模块', () {
      final moduleIds = {
        for (final g in kNavGroups)
          for (final c in g.children) c.id,
      };
      for (final s in kNavStandalone) {
        expect(moduleIds.contains(s.id), isFalse,
            reason: '${s.id} 是全局项，不该出现在模块里');
      }
      expect(kNavStandalone.map((e) => e.id).toList(), ['settings', 'about']);
    });

    test('kNavItems 仍然覆盖全部条目（Dock 还在读它）', () {
      final flat = [
        for (final g in kNavGroups) ...g.children,
        ...kNavStandalone,
      ].map((e) => e.id).toList();

      expect(kNavItems.map((e) => e.id).toList(), flat);
    });
  });

  group('查询辅助', () {
    test('navItemById 找得到、找不到返回 null', () {
      expect(navItemById('douyin')?.label, '解析下载');
      expect(navItemById('x-settings')?.label, 'X 下载设置');
      expect(navItemById('不存在的页面'), isNull);
    });

    test('navGroupOf 能判断某个页面属于哪个模块', () {
      expect(navGroupOf('home')?.id, 'x');
      expect(navGroupOf('download-management')?.id, 'x');
      expect(navGroupOf('x-settings')?.id, 'x');
      expect(navGroupOf('douyin')?.id, 'douyin');
      expect(navGroupOf('douyin-settings')?.id, 'douyin');
    });

    test('全局项不属于任何模块', () {
      expect(navGroupOf('settings'), isNull);
      expect(navGroupOf('about'), isNull);
    });
  });
}
