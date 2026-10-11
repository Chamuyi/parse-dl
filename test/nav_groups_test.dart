import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/widgets/nav_items.dart';

/// 导航分组模型。
///
/// 需求形状：**侧边栏顶层就是三个模块**（不是「一个父项包住三个模块」），
/// 每个模块自己是一个「可点击展开的统一入口」。这个文件把形状钉死，
/// 免得以后有人又把它改回平铺或改回单父项。
void main() {
  group('三个模块并列且独立', () {
    test('正好三组：X 下载 / 抖音解析下载 / B 站下载', () {
      expect(kNavGroups.length, 3);
      expect(kNavGroups[0].id, 'x');
      expect(kNavGroups[0].label, 'X 下载');
      expect(kNavGroups[1].id, 'douyin');
      expect(kNavGroups[1].label, '抖音解析下载');
      expect(kNavGroups[2].id, 'bili');
      expect(kNavGroups[2].label, 'B 站下载');
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

    test('B 站组的 id 命名与另两组同规则，批量入口叫 bili-batch', () {
      expect(
        kNavGroups[2].children.map((e) => e.id).toList(),
        ['bili', 'bili-batch', 'bili-downloads', 'bili-settings'],
      );
      // 抖音那一路的入口叫「自动下载」（要滚页面抓），B 站这批是「批量下载」
      // （列表接口直接翻），两种行为不该共用一个名字。
      expect(kNavGroups[2].children.map((e) => e.id), isNot(contains('bili-auto')));
      expect(kNavGroups[2].children.map((e) => e.id), isNot(contains('bili-downloads-auto')));
    });

    test('三组各自的 badge 是一个单字，且组 id 与 badge 不同名', () {
      for (final g in kNavGroups) {
        expect(g.badge.length, 1, reason: '${g.id} 的徽标必须是单字');
        expect(g.id, isNot(g.badge));
      }
      expect(kNavGroups.map((g) => g.badge).toList(), ['X', '抖', 'B']);
    });

    test('三个模块的设置是**三个不同页面**（不合并成一处）', () {
      final xSettings = kNavGroups[0].children.last;
      final dySettings = kNavGroups[1].children.last;
      final biliSettings = kNavGroups[2].children.last;

      // 名字自带归属：三条都叫「设置」时，Dock 形态下三个滑杆图标 + 相同文字
      // 根本分不出点的是哪一个。
      expect(xSettings.label, 'X 下载设置');
      expect(dySettings.label, '抖音设置');
      expect(biliSettings.label, 'B 站设置');
      expect({xSettings.id, dySettings.id, biliSettings.id}, hasLength(3));
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
      expect(navItemById('bili')?.label, '解析下载');
      expect(navItemById('x-settings')?.label, 'X 下载设置');
      expect(navItemById('不存在的页面'), isNull);
    });

    test('navGroupOf 能判断某个页面属于哪个模块', () {
      expect(navGroupOf('home')?.id, 'x');
      expect(navGroupOf('download-management')?.id, 'x');
      expect(navGroupOf('x-settings')?.id, 'x');
      expect(navGroupOf('douyin')?.id, 'douyin');
      expect(navGroupOf('douyin-settings')?.id, 'douyin');
      expect(navGroupOf('bili')?.id, 'bili');
      expect(navGroupOf('bili-downloads')?.id, 'bili');
      expect(navGroupOf('bili-settings')?.id, 'bili');
    });

    test('全局项不属于任何模块', () {
      expect(navGroupOf('settings'), isNull);
      expect(navGroupOf('about'), isNull);
    });
  });
}
