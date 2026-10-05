import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/douyin_config.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/douyin_groups.dart';
import 'package:parse_dl/services/douyin_store.dart';

/// 抓取结果的**作品粒度**折叠。
///
/// 诉求原话（2026-09-19）：「图文视频和实况视频，在抓取结果要按视频放，
/// 不要一张图片一张图片放在那」—— 参照实现的列表就是一行一个作品。
void main() {
  Media img(String aweme, int i, {int total = 1}) => Media(
        id: '${aweme}_$i',
        type: MediaType.image,
        url: 'https://p/$aweme-$i.jpg',
        previewUrl: 'https://p/$aweme-$i.jpg',
        source: 'douyin',
        tweetId: aweme,
        tweetText: '作品 $aweme（$total 图）',
        tags: const ['随拍', '摄影'],
        mediaIndex: i,
        likeCount: 100 + i,
      );

  /// 实况图的配对视频：序号与图相同，id 带 `v` 后缀
  Media live(String aweme, int i) => Media(
        id: '${aweme}_${i}v',
        type: MediaType.video,
        url: 'https://p/$aweme-$i.mp4',
        source: 'douyin',
        tweetId: aweme,
        mediaIndex: i,
      );

  Media video(String aweme, {int ms = 40000}) => Media(
        id: aweme,
        type: MediaType.video,
        url: 'https://p/$aweme.mp4',
        previewUrl: 'https://p/$aweme-cover.jpg',
        source: 'douyin',
        tweetId: aweme,
        tweetText: '视频作品 $aweme',
        mediaIndex: 1,
        durationMs: ms,
      );

  group('groupByAweme（纯函数）', () {
    test('图文作品折成一组，不平铺成 N 行', () {
      final g = groupByAweme([
        for (var i = 1; i <= 9; i++) img('A', i, total: 9),
      ]);
      expect(g, hasLength(1));
      expect(g.single.awemeId, 'A');
      expect(g.single.imageCount, 9);
      expect(g.single.hasMainVideo, isFalse);
      expect(g.single.typeLabel, '图文 9 图');
    });

    test('单图作品不写「1 图」', () {
      expect(groupByAweme([img('A', 1)]).single.typeLabel, '图文');
    });

    test('纯视频作品标「视频」，封面取它的 cover', () {
      final g = groupByAweme([video('V')]).single;
      expect(g.hasMainVideo, isTrue);
      expect(g.imageCount, 0);
      expect(g.typeLabel, '视频');
      expect(g.coverUrl, 'https://p/V-cover.jpg');
      expect(g.durationMs, 40000);
    });

    test('实况图：图 + 配对视频折成一组，标「实况图文 N 图」', () {
      final g = groupByAweme([
        img('L', 1, total: 3),
        live('L', 1),
        img('L', 2, total: 3),
        live('L', 2),
        img('L', 3, total: 3),
      ]).single;
      expect(g.items, hasLength(5), reason: '条目一条不少，只是折进同一行');
      expect(g.imageCount, 3);
      expect(g.imageLiveCount, 2);
      expect(g.hasMainVideo, isFalse, reason: '配对视频不算主视频');
      expect(g.typeLabel, '实况图文 2 图');
    });

    test('视频 + 图集的混合作品两个数都给出', () {
      final g = groupByAweme([
        video('M'),
        img('M', 1),
        img('M', 2),
      ]).single;
      expect(g.hasMainVideo, isTrue);
      expect(g.typeLabel, '视频 + 2 图');
    });

    test('组顺序 = 各作品首条出现的先后（页面从上到下）', () {
      final g = groupByAweme([
        img('A', 1),
        video('B'),
        img('A', 2),
        video('C'),
      ]);
      expect(g.map((e) => e.awemeId).toList(), ['A', 'B', 'C']);
    });

    test('统计数取该作品首条（同作品各条一致）', () {
      final g = groupByAweme([img('A', 1), img('A', 2)]).single;
      expect(g.likeCount, 101);
      expect(g.tags, ['随拍', '摄影']);
      expect(g.title, '作品 A（1 图）');
    });
  });

  group('DouyinStore 的作品粒度勾选', () {
    test('toggleGroup 一次勾上整条作品的每一张图', () {
      final s = DouyinStore();
      s.ingest([
        for (var i = 1; i <= 4; i++) img('A', i, total: 4),
        video('B'),
      ]);
      final groups = s.awemeGroups;
      expect(groups, hasLength(2));

      s.toggleGroup(groups.first);
      expect(s.isGroupSelected(groups.first), isTrue);
      expect(s.selectedCount, 4, reason: '4 张图全勾上');
      expect(s.isGroupSelected(groups.last), isFalse);

      s.toggleGroup(groups.first);
      expect(s.isGroupSelected(groups.first), isFalse);
      expect(s.selectedCount, 0);
    });

    test('勾选全部图文后，带 BGM 视频的组是「部分选中」且界面看得出来', () {
      // 2026-09-24 用户报的 bug：点「勾选全部图文」后右侧一个黄框都没有。
      // 根因是格子用「整组每条都选中」判定，而图文组在开着 includeBgm 时
      // 还带一条视频媒体 → 永远不满足 → 已选 145 却画成没选。
      final s = DouyinStore();
      s.ingest([img('A', 1, total: 2), img('A', 2, total: 2), video('A')]);
      final g = s.awemeGroups.single;

      s.selectAllOfType(video: false);

      expect(s.selectedCount, 2, reason: '只勾了两张图，BGM 视频不在图文勾选范围内');
      expect(s.groupSelectionOf(g), DouyinSelection.some,
          reason: '必须是"部分选中"，格子才画得出黄框');
      expect(s.isGroupSelected(g), isFalse,
          reason: '整组判定保留给 toggleGroup 决定"补全还是清空"');
      expect(s.selectionState, null, reason: '全选框该显示半选横杠，而不是像没勾');

      s.toggleGroup(g);
      expect(s.groupSelectionOf(g), DouyinSelection.all,
          reason: '在部分选中的组上再点一次 → 补全整组');
      expect(s.selectionState, true);
    });

    test('一条都没勾时 selectionState 是 false，不是 null', () {
      final s = DouyinStore()..ingest([img('A', 1)]);
      expect(s.selectionState, isFalse);
      expect(s.groupSelectionOf(s.awemeGroups.single), DouyinSelection.none);
    });

    test('awemeGroups 跟随筛选：被筛掉的作品不出现在列表里', () {
      final s = DouyinStore();
      s.ingest([img('A', 1), video('B')]);
      expect(s.awemeGroups, hasLength(2));
      s.setFilter(s.filter.copyWith(keyword: '视频作品'));
      expect(s.awemeGroups.map((g) => g.awemeId).toList(), ['B']);
    });

    test('下载列表仍是媒体粒度 —— 折叠只影响展示', () {
      final s = DouyinStore();
      s.ingest([for (var i = 1; i <= 3; i++) img('A', i, total: 3)]);
      s.toggleGroup(s.awemeGroups.single);
      final list = s.buildDownloadList(
        DouyinConfig(skipDownloaded: false),
      );
      expect(list.items, hasLength(3), reason: '3 张图都要下');
    });
  });
}
