import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_meta.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/bili_store.dart';

Media _part(String bvid, int index, int total, {String title = '标题'}) => Media(
  id: '$bvid-$index',
  type: MediaType.video,
  url: 'https://upos-sz-mirrorhw.bilivideo.com/example/v$index.m4s',
  tweetId: bvid,
  mediaIndex: index,
  source: 'bili',
  bili: BiliMeta(
    workTitle: title,
    partTitle: '第${index}P',
    bvid: bvid,
    partTotal: total,
  ),
);

void main() {
  group('BiliStore 聚合', () {
    test('同一稿件的分P聚成一组，顺序=首次出现', () {
      final s = BiliStore();
      s.replaceAll([
        _part('BV1aaa', 1, 3),
        _part('BV1bbb', 1, 2),
        _part('BV1aaa', 2, 3),
        _part('BV1aaa', 3, 3),
      ]);
      expect(s.groups.map((g) => g.key), ['BV1aaa', 'BV1bbb']);
      expect(s.groups.first.parts, hasLength(3));
      expect(s.groups.last.parts, hasLength(1));
    });

    test('组内没有 bili 块的媒体按 tweetId / id 兜底成组', () {
      final s = BiliStore();
      s.replaceAll([
        Media(
          id: 'no-bili-1',
          type: MediaType.video,
          url: 'https://x/y.m4s',
          tweetId: 'BV1zzz',
        ),
      ]);
      expect(s.groups.single.key, 'BV1zzz');
    });
  });

  group('BiliStore 勾选', () {
    test('replaceAll 默认全选（一次解析就是整批要下的形状）', () {
      final s = BiliStore();
      s.replaceAll([_part('BV1aaa', 1, 2), _part('BV1aaa', 2, 2)]);
      expect(s.chosen, hasLength(2));
    });

    test('toggleGroup 三态：全勾 / 全不勾 / 反相', () {
      final s = BiliStore();
      s.replaceAll([_part('BV1aaa', 1, 2), _part('BV1aaa', 2, 2)]);
      s.toggleGroup('BV1aaa');
      expect(s.selectedIn('BV1aaa'), 0);
      s.toggleGroup('BV1aaa');
      expect(s.selectedIn('BV1aaa'), 2);
      s.toggleGroup('BV1aaa', value: false);
      expect(s.selected, isEmpty);
    });

    test('toggle 未知组不报错', () {
      final s = BiliStore();
      s.replaceAll([_part('BV1aaa', 1, 2)]);
      expect(() => s.toggleGroup('不存在的组'), returnsNormally);
      expect(s.selectedIn('不存在的组'), 0);
    });

    test('chosen 保持 items 顺序，不按勾选顺序', () {
      final s = BiliStore();
      s.replaceAll([_part('BV1aaa', 1, 3), _part('BV1aaa', 2, 3), _part('BV1aaa', 3, 3)]);
      s.selectNone();
      s.toggle('BV1aaa-3');
      s.toggle('BV1aaa-1');
      expect(s.chosen.map((m) => m.id), ['BV1aaa-1', 'BV1aaa-3']);
    });
  });

  group('BiliStore 状态', () {
    test('setBusy 清掉上一次的错误，setError 把 busy 收回去', () {
      final s = BiliStore();
      s.setError('解析失败');
      expect(s.error, '解析失败');
      expect(s.busy, isFalse);
      s.setBusy(true);
      expect(s.error, isNull);
      expect(s.busy, isTrue);
    });

    test('clear 收掉结果与勾选，但保留最近链接', () {
      final s = BiliStore();
      s.replaceAll([_part('BV1aaa', 1, 2)], link: 'https://b23.tv/abc');
      s.clear();
      expect(s.items, isEmpty);
      expect(s.selected, isEmpty);
      expect(s.recentLinks, ['https://b23.tv/abc']);
    });

    test('最近链接去重、置顶、限长', () {
      final s = BiliStore();
      for (var i = 0; i < 15; i++) {
        s.replaceAll(const [], link: 'https://b23.tv/$i');
      }
      expect(s.recentLinks, hasLength(BiliStore.kMaxRecentLinks));
      expect(s.recentLinks.first, 'https://b23.tv/14');
      // 重复粘同一条不会挤成两行
      s.replaceAll(const [], link: 'https://b23.tv/14');
      expect(s.recentLinks.where((e) => e == 'https://b23.tv/14'), hasLength(1));
    });
  });

  group('变更通知', () {
    test('每次改勾选/结果都会 notify（界面靠这个刷新）', () {
      final s = BiliStore();
      var n = 0;
      s.addListener(() => n++);
      s.replaceAll([_part('BV1aaa', 1, 2)]);
      s.toggle('BV1aaa-1');
      s.toggleGroup('BV1aaa');
      s.selectAll();
      s.selectNone();
      s.setBusy(true);
      s.setError('x');
      s.clear();
      expect(n, 8);
    });
  });
}
