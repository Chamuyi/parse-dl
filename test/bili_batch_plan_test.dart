import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_api.dart';
import 'package:parse_dl/services/bili_batch_store.dart';
import 'package:parse_dl/services/bili_link.dart';
import 'package:parse_dl/services/bili_list_api.dart';

/// `biliPlanWorks`：一个目标到底摊成「要下哪些稿件」。
///
/// 这段逻辑原来长在批量页的 `StatefulWidget` 里，于是**除了手点界面无从验证** ——
/// 而界面上的手点这一期恰恰不能当证据。抽成注入三个口的纯函数之后，
/// 这里钉的是四类事：
///   1. 上限截断留下的数是「截掉几条」而不是「剩几条」；
///   2. 单条稿件那一行**一个列表接口都不该发**；
///   3. `sid` 判成系列之后不许再去打合集接口（互斥那条纪律的现场版）；
///   4. 失败给的是**稳定 ASCII 码**，中文文案留在界面（编排层不新增用户可见中文串）。
void main() {
  List<Map<String, dynamic>> rows(int n) => [
    for (var i = 1; i <= n; i++)
      {
        'bvid': 'BV${i.toString().padLeft(10, '0')}',
        'aid': 1000 + i,
        'title': '稿件 $i',
        'duration': 120,
        'state': 0,
      },
  ];

  Future<({String bvid, String title})> fakeWork({String? bvid, int? aid}) async =>
      (bvid: bvid ?? 'av${aid ?? 0}', title: '单条标题');

  BiliListApi apiOf(_Fake fake) =>
      BiliListApi(signed: fake.transport, plain: fake.transport);

  final seasonRef = biliTargetRef(
    'https://space.bilibili.com/123/lists/9225450?type=season',
  )!;

  group('合集与系列', () {
    test('合集链接：翻到尽、列表名来自接口、目标判成 season', () async {
      final fake = _Fake()
        ..on('/x/polymer/web-space/seasons_archives_list', (p) => {
              'page': {'page_num': 1, 'page_size': 30, 'total': 3},
              'meta': {'title': '合集·冬', 'mid': 123},
              'archives': rows(3),
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '海边的猫'}});
      final plan = await biliPlanWorks(
        ref: seasonRef,
        listApi: apiOf(fake),
        resolveWork: fakeWork,
        expandShort: (u) async => null,
      );
      expect(plan.works.keys, hasLength(3));
      expect(plan.title, '合集·冬');
      expect(plan.target?.kind, BiliListKind.season);
      expect(plan.archives, hasLength(3));
      expect(plan.truncated, 0);
      expect(plan.collected, 3);
    });

    test('上限截掉的是「几条」而不是「剩几条」，明细仍给全量', () async {
      final fake = _Fake()
        ..on('/x/polymer/web-space/seasons_archives_list', (p) => {
              'page': {'page_num': 1, 'page_size': 30, 'total': 3},
              'meta': {'title': '合集·冬'},
              'archives': rows(3),
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final plan = await biliPlanWorks(
        ref: seasonRef,
        listApi: apiOf(fake),
        resolveWork: fakeWork,
        expandShort: (u) async => null,
        maxWorks: 2,
      );
      expect(plan.works.keys, hasLength(2));
      expect(plan.truncated, 1, reason: '界面要说「截掉 1 条」，说「找到 2 条」就是骗人');
      expect(plan.archives, hasLength(3), reason: '明细里要看得见全量');
    });

    test('只给 sid 的链接判成系列后，**不许**再打合集接口', () async {
      final fake = _Fake()
        ..on('/x/series/series', (p) => {
              'meta': {
                'series_id': p['series_id'],
                'mid': 123,
                'name': 'galgame',
                'total': 2,
              },
            })
        ..on('/x/series/archives', (p) => {
              'page': {'num': 1, 'size': 30, 'total': 2},
              'archives': rows(2),
            })
        ..on('/x/polymer/web-space/seasons_archives_list', (p) => {
              'page': {'page_num': 1, 'page_size': 30, 'total': 99},
              'meta': {'title': '走错门了'},
              'archives': rows(99),
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final ref = biliTargetRef(
        'https://www.bilibili.com/list/123?sid=4684427',
      )!;
      expect(ref.list?.kind, BiliListKind.unknown, reason: '先确认它真是待判形态');
      final plan = await biliPlanWorks(
        ref: ref,
        listApi: apiOf(fake),
        resolveWork: fakeWork,
        expandShort: (u) async => null,
      );
      expect(plan.target?.kind, BiliListKind.series);
      expect(plan.title, 'galgame');
      expect(plan.works.keys, hasLength(2));
      expect(
        fake.paths,
        isNot(contains('/x/polymer/web-space/seasons_archives_list')),
        reason: '判成系列还去查合集，用户看到的「系列内容」就是别处的',
      );
    });
  });

  group('单条稿件与失败形状', () {
    test('单条稿件那一行：一个列表接口都不发', () async {
      final fake = _Fake();
      var called = 0;
      final plan = await biliPlanWorks(
        ref: biliTargetRef('BV1uzas6vEBB')!,
        listApi: apiOf(fake),
        resolveWork: ({bvid, aid}) async {
          called++;
          return (bvid: bvid ?? '', title: '冬天');
        },
        expandShort: (u) async => null,
      );
      expect(called, 1);
      expect(fake.calls, isEmpty, reason: '单条稿件不该去翻任何列表接口');
      expect(plan.works.keys.single, 'BV1uzas6vEBB');
      expect(plan.title, '冬天');
      expect(plan.target, isNull);
    });

    test('短链展不开 → 稳定码 shortLinkUnresolved', () async {
      await expectLater(
        biliPlanWorks(
          ref: biliTargetRef('https://b23.tv/abc123')!,
          listApi: apiOf(_Fake()),
          resolveWork: fakeWork,
          expandShort: (u) async => null,
        ),
        throwsA(
          isA<BiliPlanException>().having(
            (e) => e.problem,
            'problem',
            BiliPlanProblem.shortLinkUnresolved,
          ),
        ),
      );
    });

    test('展开出来是本期不做的形态 → unsupported，detail 带链接层原话', () async {
      await expectLater(
        biliPlanWorks(
          ref: biliTargetRef('https://b23.tv/abc123')!,
          listApi: apiOf(_Fake()),
          resolveWork: fakeWork,
          expandShort: (u) async => parseBiliRef(
            'https://www.bilibili.com/bangumi/play/ep123456',
          ),
        ),
        throwsA(
          isA<BiliPlanException>()
              .having((e) => e.problem, 'problem', BiliPlanProblem.unsupported)
              .having((e) => e.detail, 'detail', contains('番剧')),
        ),
      );
    });

    test('空列表 → noWorks，而不是交出一个空计划', () async {
      final fake = _Fake()
        ..on('/x/polymer/web-space/seasons_archives_list', (p) => {
              'page': {'page_num': 1, 'page_size': 30, 'total': 0},
              'meta': {'title': '空合集'},
              'archives': <Map<String, dynamic>>[],
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      await expectLater(
        biliPlanWorks(
          ref: seasonRef,
          listApi: apiOf(fake),
          resolveWork: fakeWork,
          expandShort: (u) async => null,
        ),
        throwsA(
          isA<BiliPlanException>().having(
            (e) => e.problem,
            'problem',
            BiliPlanProblem.noWorks,
          ),
        ),
      );
    });

    test('阶段回调：普通链接只经过 listing，不该有 expanding', () async {
      final seen = <BiliBatchStatus>[];
      final fake = _Fake()
        ..on('/x/polymer/web-space/seasons_archives_list', (p) => {
              'page': {'page_num': 1, 'page_size': 30, 'total': 1},
              'meta': {'title': '合集·冬'},
              'archives': rows(1),
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      await biliPlanWorks(
        ref: seasonRef,
        listApi: apiOf(fake),
        resolveWork: fakeWork,
        expandShort: (u) async => null,
        onStage: seen.add,
      );
      expect(seen, [BiliBatchStatus.listing]);
      // 正控制：短链那一行必须**先**经过 expanding
      final seen2 = <BiliBatchStatus>[];
      await biliPlanWorks(
        ref: biliTargetRef('https://b23.tv/abc123')!,
        listApi: apiOf(
          _Fake()
            ..on('/x/polymer/web-space/seasons_archives_list', (p) => {
                  'page': {'page_num': 1, 'page_size': 30, 'total': 1},
                  'meta': {'title': '合集·冬'},
                  'archives': rows(1),
                })
            ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}}),
        ),
        resolveWork: fakeWork,
        expandShort: (u) async => seasonRef,
        onStage: seen2.add,
      );
      expect(seen2.first, BiliBatchStatus.expanding);
    });
  });
}

class _Fake {
  final Map<String, Map<String, dynamic> Function(Map<String, dynamic>)> _handlers =
      {};
  final List<(String, Map<String, dynamic>)> calls = [];

  _Fake on(
    String path,
    Map<String, dynamic> Function(Map<String, dynamic>) fn,
  ) {
    _handlers[path] = fn;
    return this;
  }

  List<String> get paths => calls.map((c) => c.$1).toList();

  BiliListTransport get transport => (path, params) async {
        calls.add((path, Map<String, dynamic>.from(params)));
        final fn = _handlers[path];
        if (fn == null) throw BiliApiException('没有给 $path 准备夹具');
        return fn(Map<String, dynamic>.from(params));
      };
}
