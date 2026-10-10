import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_meta.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/media_variant.dart';
import 'package:parse_dl/services/bili_batch_runner.dart';

/// `biliRunWorks`：批量页「逐条稿件展开 → 投队列」那一段。
///
/// 抽出来之前它长在 `BiliBatchPage` 的 State 里，于是**除了手点界面无从验证**；
/// 而抽取的同一轮里就在它旁边发现了「注释写了兜底、代码没写」的 bug
/// （跑批循环少 per-target catch，一条失败掀掉整批）。这里钉的就是这几件事：
/// 一条失败不许掀整批、空分 P 要留下能翻成人话的清单、停止按钮真的能停。
void main() {
  Media media(String bvid, {int part = 1}) => Media(
    id: '$bvid-$part',
    type: MediaType.video,
    url: 'https://upos.bilivideo.com/v.m4s',
    source: 'bili',
    tweetId: bvid,
    mediaIndex: part,
    durationMs: 60 * 1000,
    bili: BiliMeta(
      workTitle: '冬天',
      partTitle: '第$part P',
      bvid: bvid,
      cid: '${42000000000 + part}',
      partTotal: 3,
    ),
    chosen: const MediaVariant(
      urls: ['https://upos.bilivideo.com/v.m4s'],
      kind: VariantKind.bitRate,
      bitrate: 1000000,
      format: 'm4s',
    ),
  );

  /// 三条稿件，每条展开成 3 个分 P。
  final works = {'BVaaaaaa0001': '一', 'BVaaaaaa0002': '二', 'BVaaaaaa0003': '三'};

  Future<List<Media>> expandThree(String bvid) async => [
    media(bvid, part: 1),
    media(bvid, part: 2),
    media(bvid, part: 3),
  ];

  BiliRunTally tallyOf({int queued = 0}) {
    final t = BiliRunTally()..queued = queued;
    return t;
  }

  test('默认只取第 1P：每条稿件一次投递，每次一条', () async {
    final sent = <int>[];
    final tally = BiliRunTally();
    await biliRunWorks(
      tally: tally,
      works: works,
      expandWork: expandThree,
      download: (parts) async {
        sent.add(parts.length);
        return tallyOf(queued: parts.length);
      },
    );
    expect(sent, [1, 1, 1]);
    expect(tally.queued, 3);
  });

  test('勾了「全部 P」时每条投三条', () async {
    final sent = <int>[];
    final tally = BiliRunTally();
    await biliRunWorks(
      tally: tally,
      works: works,
      expandWork: expandThree,
      allParts: true,
      download: (parts) async {
        sent.add(parts.length);
        return tallyOf(queued: parts.length);
      },
    );
    expect(sent, [3, 3, 3]);
    expect(tally.queued, 9);
  });

  test('第二条抛错：只算它一条失败，第三条照投', () async {
    final tried = <String>[];
    final tally = BiliRunTally();
    await biliRunWorks(
      tally: tally,
      works: works,
      expandWork: (bvid) async {
        tried.add(bvid);
        if (bvid.endsWith('2')) throw Exception('playurl 412');
        return expandThree(bvid);
      },
      download: (parts) async => tallyOf(queued: 1),
    );
    expect(tried, hasLength(3), reason: '一条失败就掀整批是最坏的体验');
    expect(tally.failed, 1);
    expect(tally.queued, 2);
    expect(tally.notes.single, contains('412'));
  });

  test('展开不出分 P：失败计数 + 把 bvid 留给界面拼文案', () async {
    final tally = BiliRunTally();
    final sent = <String>[];
    await biliRunWorks(
      tally: tally,
      works: works,
      expandWork: (bvid) async =>
          bvid.endsWith('1') ? <Media>[] : expandThree(bvid),
      download: (parts) async {
        sent.add(parts.first.id);
        return tallyOf(queued: 1);
      },
    );
    expect(tally.noParts, ['BVaaaaaa0001']);
    expect(tally.failed, 1);
    expect(sent, hasLength(2));
    // 正控制：这一层不许自己造中文文案（界面才有权说人话）
    expect(tally.notes, isEmpty);
  });

  test('停止之后一条都不再投', () async {
    final sent = <String>[];
    final tally = BiliRunTally();
    await biliRunWorks(
      tally: tally,
      works: works,
      keepGoing: () => sent.isEmpty,
      expandWork: expandThree,
      download: (parts) async {
        sent.add(parts.first.id);
        return tallyOf(queued: 1);
      },
    );
    expect(sent, hasLength(1), reason: '点了停止就该在下一条之前退出');
    expect(tally.queued, 1);
  });

  test('每条都要有进度回调（界面上那一行得在动）', () async {
    var ticks = 0;
    await biliRunWorks(
      tally: BiliRunTally(),
      works: works,
      expandWork: expandThree,
      download: (parts) async => tallyOf(queued: 1),
      onProgress: () => ticks++,
    );
    expect(ticks, 3);
  });
}
