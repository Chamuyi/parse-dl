import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/widgets/nav_items.dart';

/// 导航第三组与路由的接线检查。
///
/// 页面本体嵌 WebView2，不适合在 widget 测试里构造；但「三个 id 有没有都接上」
/// 是纯静态可判的 —— 少接一条的现场表现是：侧边栏点得到、点进去白屏。
/// 所以这里直接扫 `app.dart` 的源码。
void main() {
  const biliIds = ['bili', 'bili-downloads', 'bili-settings'];

  NavGroup biliGroup() =>
      kNavGroups.firstWhere((g) => g.id == 'bili', orElse: () => kNavGroups.first);

  group('导航第三组', () {
    test('一共三组，B 站那组有 3 个子项', () {
      expect(kNavGroups.map((g) => g.id), ['x', 'douyin', 'bili']);
      expect(biliGroup().children.map((c) => c.id), biliIds);
    });

    test('B 站这一期不放「自动下载」入口（点了会白屏）', () {
      expect(biliIds, isNot(contains('bili-auto')));
      expect(biliGroup().children, hasLength(3));
    });

    test('id 全局不重复，且两个「下载管理」不是同一个导航项', () {
      final ids = kNavItems.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length, reason: '有重复 id：$ids');
      expect(ids, contains('download-management'));
      expect(ids, contains('douyin-downloads'));
      expect(ids, contains('bili-downloads'));
    });

    test('每个 id 都能查到；正控制：编一个 id 必须查不到', () {
      for (final id in biliIds) {
        expect(navItemById(id), isNotNull, reason: '$id 没进导航');
      }
      expect(navItemById('bili-nope'), isNull);
    });

    test('badge 是单字且三组互不相同', () {
      final badges = kNavGroups.map((g) => g.badge).toList();
      expect(badges.every((b) => b.length == 1), isTrue, reason: '$badges');
      expect(badges.toSet().length, badges.length);
    });
  });

  group('路由与标题都接上', () {
    final appSrc = File('lib/app.dart').readAsStringSync();

    test('app.dart 里每个 id 都有 case，也有标题映射', () {
      for (final id in biliIds) {
        expect(appSrc, contains("case '$id'"), reason: '$id 没有路由 case');
        expect(appSrc, contains("'$id' =>"), reason: '$id 没有标题映射');
      }
      // 正控制：一个不存在于导航里的 id 不该出现在这里
      expect(appSrc, isNot(contains("case 'bili-auto'")));
    });

    test('B 站的三个页面类各自独立，不借用另两个模块的页面', () {
      // 下载管理页是三模块共用的（靠 feed 分流），这是**唯一**允许的共用
      final biliCases = RegExp(r"case '(bili[^']*)':").allMatches(appSrc);
      expect(biliCases, hasLength(3));
      final body = appSrc.substring(
        biliCases.first.start,
        appSrc.indexOf('case ', appSrc.indexOf('bili-downloads')),
      );
      expect(body, contains('BiliPage'));
      expect(body, isNot(contains('DouyinPage')));
    });
  });

  group('导航文案不串门', () {
    const biliForbidden = ['推文', '帖子', 'tweet', '抖音', 'aweme', 'douyin'];
    const xDouyinForbidden = ['BV 号', 'UP 主', '稿件'];

    test('B 站组的标题与子项里没有另两个模块的说法', () {
      final g = biliGroup();
      final text = [g.id, g.label, g.badge,
        for (final c in g.children) ...[c.id, c.label]].join(' ').toLowerCase();
      for (final w in biliForbidden) {
        expect(text.contains(w.toLowerCase()), isFalse,
            reason: 'B 站导航里出现了「$w」：$text');
      }
    });

    test('X 与抖音组的导航文案里也没有 B 站专有说法', () {
      for (final g in kNavGroups.where((e) => e.id != 'bili')) {
        final text = [g.label, for (final c in g.children) c.label].join(' ');
        for (final w in xDouyinForbidden) {
          expect(text.contains(w), isFalse,
              reason: '${g.id} 组里出现了「$w」：$text');
        }
      }
    });
  });
}
