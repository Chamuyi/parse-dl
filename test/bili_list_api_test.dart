import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_api.dart';
import 'package:parse_dl/services/bili_link.dart';
import 'package:parse_dl/services/bili_list_api.dart';

/// `bili_list_api.dart` 的五个接口 + 用户名缓存 + 自动翻页。
///
/// **全部用假传输与夹具，不发真实请求、不碰登录态。**
/// 钉住的四类事：
///   1. 每支接口的**翻页终止判据**到底读的是哪个字段（`page.count` /
///      `page.total` / `info.media_count`），以及收藏夹那个**不可靠的
///      `has_more` 有没有被误用**；
///   2. `card(mid)` 命中缓存必须**一个请求都不发**（参照实现踩过缺 return 的坑）；
///   3. 系列 meta 探针**复用**不重复请求；
///   4. 参数名（合集是 `page_num`/`page_size`，不是 `pn`/`ps`）与
///      「绝不带参照实现那四个 `dm_img_*` 机器串」。
void main() {
  group('主页投稿 arc/search', () {
    test('总数用 data.page.count，两页翻到尽；card 只被调一次', () async {
      final fake = _Fake()
        ..on('/x/space/wbi/arc/search', (p) => _arcSearch(
              pn: p['pn'] as int,
              ps: p['ps'] as int,
              count: 45,
            ))
        ..on('/x/web-interface/card', (p) => {
              'card': {'mid': '${p['mid']}', 'name': '海边的猫', 'fans': 1234}
            });
      final api = _api(fake);

      final items = await api.allSpaceArcs(mid: 123);
      expect(items.length, 45);
      // 判据一（累计 ≥ data.page.count）生效的证据：只发了 2 页请求。
      // 若只靠「本页为空」收口，这里会是 3 次（第 3 页才空）。
      expect(fake.countOf('/x/space/wbi/arc/search'), 2);
      expect(fake.countOf('/x/web-interface/card'), 1,
          reason: '翻两页重复问用户名就是参照实现踩过的那个坑');
      expect(items.first.upperName, '海边的猫');
      expect(items.last.bvid, 'BV0000000045');
    });

    test('正控制：清掉缓存之后同样的两页会重新问一次 card', () async {
      final fake = _Fake()
        ..on('/x/space/wbi/arc/search',
            (p) => _arcSearch(pn: p['pn'] as int, ps: p['ps'] as int, count: 45))
        ..on('/x/web-interface/card',
            (p) => {'card': {'mid': '${p['mid']}', 'name': '猫', 'fans': 1}});
      final api = _api(fake);
      await api.allSpaceArcs(mid: 123);
      expect(fake.countOf('/x/web-interface/card'), 1);
      api.clearCaches();
      await api.allSpaceArcs(mid: 123);
      // 上面那条「只调一次」不是假绿：缓存一清，请求就真的发出去了
      expect(fake.countOf('/x/web-interface/card'), 2);
    });

    test('参数集钉住，且绝不带参照实现那四个机器串', () async {
      final fake = _Fake()
        ..on('/x/space/wbi/arc/search',
            (p) => _arcSearch(pn: p['pn'] as int, ps: p['ps'] as int, count: 1))
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final api = _api(fake);
      await api.spaceArcs(mid: 123, keyword: '试听');
      final p = fake.lastParams('/x/space/wbi/arc/search')!;
      expect(p['pn'], 1);
      expect(p['ps'], kBiliSpacePageSize);
      expect(p['tid'], 0);
      expect(p['order'], 'pubdate');
      expect(p['mid'], 123);
      expect(p['platform'], 'web');
      expect(p['keyword'], '试听');
      fake.assertNoDeviceFingerprint();
    });

    test('接口没给总数时靠「这一页返回空」收口', () async {
      final fake = _Fake()
        ..on('/x/space/wbi/arc/search', (p) => {
              // page 里**没有 count**：total 口径缺失，只能等空页
              'page': {'pn': p['pn'], 'ps': 40},
              'list': {
                'vlist': (p['pn'] as int) == 1 ? _vlist(1, 2) : const []
              }
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final api = _api(fake);
      final items = await api.allSpaceArcs(mid: 123);
      expect(items.length, 2);
      expect(fake.countOf('/x/space/wbi/arc/search'), 2,
          reason: 'total 未知时必须翻到空页才停');
    });

    test('vlist 的 duration 给 "12:34" 这种串也要解成毫秒', () async {
      final fake = _Fake()
        ..on('/x/space/wbi/arc/search', (p) => {
              'page': {'pn': 1, 'ps': 40, 'count': 1},
              'list': {
                'vlist': [
                  {
                    'bvid': 'BV1S4pK6tEuR',
                    'aid': 64417133,
                    'title': '一年的海边',
                    'cover': '//i0.hdslb.com/bfs/archive/a.jpg',
                    'duration': '12:34',
                    'pubdate': 1705756536,
                    'mid': 9,
                    'author': 'UP本人',
                    'videos': 3,
                  }
                ]
              }
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '缓存名'}});
      final page = await _api(fake).spaceArcs(mid: 9);
      final a = page.items.single;
      expect(a.durationMs, 754000);
      expect(a.cover, 'https://i0.hdslb.com/bfs/archive/a.jpg');
      expect(a.partTotal, 3);
      expect(a.upperName, 'UP本人', reason: '项里自带的 UP 优先于缓存名');
      expect(a.publishTime, DateTime.fromMillisecondsSinceEpoch(1705756536000));
    });
  });

  group('合集 seasons_archives_list', () {
    test('总数用 data.page.total；分页参数名是 page_num / page_size', () async {
      final fake = _Fake()
        ..on('/x/polymer/web-space/seasons_archives_list', (p) => {
              'page': {
                'page_num': p['page_num'],
                'page_size': p['page_size'],
                'total': 35,
              },
              'meta': {'title': '超分辨率-动画', 'name': '合集·超分辨率-动画', 'mid': 123},
              'archives': _archives(
                from: ((p['page_num'] as int) - 1) * (p['page_size'] as int) + 1,
                count: (p['page_num'] as int) == 1 ? 30 : 5,
              ),
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '海边的猫'}});
      final items = await _api(fake).allSeasonArcs(mid: 123, seasonId: 9225450);
      expect(items.length, 35);
      expect(fake.countOf('/x/polymer/web-space/seasons_archives_list'), 2);
      final p2 = fake.lastParams('/x/polymer/web-space/seasons_archives_list')!;
      expect(p2['page_num'], 2, reason: '写成 pn 的话服务端当成没传，每页都给第一页');
      expect(p2['page_size'], kBiliSeasonPageSize);
      expect(p2['sort_reverse'], 'false');
      expect(p2['season_id'], 9225450);
    });

    test('archives 项不带作者名 → 名从 card 来；标题退到 meta.title', () async {
      final fake = _Fake()
        ..on('/x/polymer/web-space/seasons_archives_list', (p) => {
              'page': {'page_num': 1, 'page_size': 30, 'total': 1},
              // 实测有的响应根本没有 season 段
              'meta': {'name': '合集·超分辨率-动画', 'mid': 123},
              'archives': _archives(from: 1, count: 1),
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '海边的猫'}});
      final page = await _api(fake).seasonArcs(mid: 123, seasonId: 9225450);
      expect(page.listTitle, '合集·超分辨率-动画');
      expect(page.items.single.upperName, '海边的猫');
      expect(page.items.single.upperMid, 123);
    });

    test('season.title 在时优先它', () async {
      final fake = _Fake()
        ..on('/x/polymer/web-space/seasons_archives_list', (p) => {
              'page': {'page_num': 1, 'page_size': 30, 'total': 0},
              'season': {'title': '页面标题'},
              'meta': {'title': '元标题', 'name': '合集·元标题'},
              'archives': const [],
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final page = await _api(fake).seasonArcs(mid: 1, seasonId: 2);
      expect(page.listTitle, '页面标题');
    });
  });

  group('系列 series', () {
    test('探针命中的 meta 被复用，翻两页也只请求一次 series/series', () async {
      final fake = _Fake()
        ..on('/x/series/archives', (p) => {
              'page': {
                'num': p['pn'],
                'size': p['ps'],
                'total': 47,
              },
              // 实测这一支的 data 里没有 meta
              'archives': _archives(
                from: ((p['pn'] as int) - 1) * (p['ps'] as int) + 1,
                count: (p['pn'] as int) == 1 ? 30 : 17,
              ),
            })
        ..on('/x/series/series', (p) => {
              'meta': {
                'series_id': p['series_id'],
                'mid': 123,
                'name': 'galgame',
                'total': 48,
              }
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '海边的猫'}});
      final api = _api(fake);

      final meta = await api.probeSeries(1970940);
      expect(meta?.name, 'galgame');
      expect(fake.countOf('/x/series/series'), 1);

      final items = await api.allSeriesArcs(
        mid: 123,
        seriesId: 1970940,
        meta: {'name': meta!.name, 'mid': meta.mid, 'total': meta.total},
      );
      expect(items.length, 47);
      // 复用 + 缓存：探针那一次之外没有第二次
      expect(fake.countOf('/x/series/series'), 1,
          reason: '探针顺手拿到的 meta 要复用掉，省一次请求');
      expect(fake.countOf('/x/series/archives'), 2);
      expect(fake.countOf('/x/web-interface/card'), 1);
    });

    test('正控制：换个没探过的 series_id 就必须多发一次探针请求', () async {
      final fake = _Fake()
        ..on('/x/series/archives', (p) => {
              'page': {'num': 1, 'size': 30, 'total': 1},
              'archives': _archives(from: 1, count: 1),
            })
        ..on('/x/series/series', (p) => {
              'meta': {'series_id': p['series_id'], 'mid': 1, 'name': 'g', 'total': 1}
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final api = _api(fake);
      await api.seriesArcs(mid: 1, seriesId: 111);
      await api.seriesArcs(mid: 1, seriesId: 222);
      expect(fake.countOf('/x/series/series'), 2,
          reason: '上一组的「1 次」是复用出来的，不是探针压根没接线');
    });

    test('series 的参数集与标题来自 meta；总数只认 page.total，不认 meta.total', () async {
      final fake = _Fake()
        ..on('/x/series/archives', (p) {
          expect(p['only_normal'], 'true');
          expect(p['sort'], 'desc');
          expect(p['current_mid'], 0);
          return {
            'page': {'num': 1, 'size': 30, 'total': 17},
            'archives': _archives(from: 1, count: 17),
          };
        })
        ..on('/x/series/series', (p) => {
              // 故意给一个与 page.total(17) 不同的 meta.total(18)：
              // 总数取错字段的话这条断言会红
              'meta': {'series_id': p['series_id'], 'mid': 1, 'name': 'galgame', 'total': 18}
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final page = await _api(fake).seriesArcs(mid: 1, seriesId: 5);
      expect(page.total, 17, reason: '总数只认 page.total；meta.total 是另一个口径');
      expect(page.listTitle, 'galgame');
      expect(page.pageSize, 30);
    });

    test('探针：非系列 id 干净回非 0 → null，不抛给调用方', () async {
      final fake = _Fake()
        ..on('/x/series/series',
            (p) => throw const BiliApiException('no', code: 147002));
      expect(await _api(fake).probeSeries(1), isNull);
    });

    test('探针：给了 data 但没有 meta → 也算「不是系列」', () async {
      final fake = _Fake()..on('/x/series/series', (p) => <String, dynamic>{});
      expect(await _api(fake).probeSeries(1), isNull);
    });

    test('正控制：HTTP 层失败（没有业务 code）不许被当成「不是系列」吞掉', () async {
      final fake = _Fake()
        ..on('/x/series/series',
            (p) => throw const BiliApiException('http', statusCode: 412));
      await expectLater(_api(fake).probeSeries(1), throwsA(isA<BiliApiException>()));
    });
  });

  group('收藏夹 fav resource list', () {
    test('总数只认 info.media_count：has_more=true 但已翻尽也必须停', () async {
      final fake = _Fake()
        ..on('/x/v3/fav/resource/list', (p) => {
              // 实测 has_more 不可靠，这一条就是钉住「没去信它」
              'has_more': true,
              'page': null,
              'info': {'media_count': 3, 'title': '英语'},
              'medias': _medias(3),
            });
      final items = await _api(fake).allFavResources(mediaId: 1155866758);
      expect(items.length, 3);
      expect(fake.countOf('/x/v3/fav/resource/list'), 1,
          reason: '信了 has_more 就会再去问第 2 页');
    });

    test('反方向：has_more=false 但没翻尽 → 继续翻', () async {
      final fake = _Fake()
        ..on('/x/v3/fav/resource/list', (p) => {
              'has_more': false,
              'page': null,
              'info': {'media_count': 60, 'title': '英语'},
              'medias': _medias((p['pn'] as int) == 1 ? 40 : 20,
                  from: (p['pn'] as int) == 1 ? 1 : 41),
            });
      final items = await _api(fake).allFavResources(mediaId: 1);
      expect(items.length, 60);
      expect(fake.countOf('/x/v3/fav/resource/list'), 2);
    });

    test('参数集 + keyword 透传；medias 的 bv_id / upper 都要能吃下', () async {
      final fake = _Fake()
        ..on('/x/v3/fav/resource/list', (p) {
          expect(p['media_id'], 1155866758);
          expect(p['order'], 'mtime');
          expect(p['type'], 0);
          expect(p['tid'], 0);
          expect(p['keyword'], '试听');
          return {
            'has_more': false,
            'page': null,
            'info': {'media_count': 1, 'title': '英语'},
            'medias': [
              {
                'id': 851918256,
                'bv_id': 'BV1GL4y137ZA',
                'bvid': 'BV1GL4y137ZA',
                'title': '毕业演讲',
                'cover': 'http://i1.hdslb.com/a.jpg',
                'duration': 274,
                'pubtime': 1646213446,
                'upper': {'mid': 433406580, 'name': 'Youtube英语学习'},
                // 收藏夹的统计量在 cnt_info 里，字段名与 stat 那套不同名
                'cnt_info': {
                  'play': 2750502,
                  'collect': 68490,
                  'danmaku': 563,
                  'reply': 12,
                  'share': 3,
                },
              }
            ],
          };
        });
      final page = await _api(fake).favResources(
        mediaId: 1155866758,
        keyword: '试听',
      );
      expect(page.listTitle, '英语');
      final a = page.items.single;
      expect(a.bvid, 'BV1GL4y137ZA');
      expect(a.aid, 851918256);
      expect(a.durationMs, 274000);
      expect(a.cover, 'https://i1.hdslb.com/a.jpg');
      expect(a.upperMid, 433406580);
      expect(a.upperName, 'Youtube英语学习');
      // cnt_info → 统计量：`play` 当播放、`collect` 当收藏，不许串门
      expect(a.viewCount, 2750502);
      expect(a.favoriteCount, 68490);
      expect(a.replyCount, 12);
      expect(a.shareCount, 3);
      expect(a.likeCount, isNull);
      fake.assertNoDeviceFingerprint();
    });
  });

  group('自建收藏夹 created/list-all', () {
    test('无分页：一次请求，总数就是条数', () async {
      final fake = _Fake()
        ..on('/x/v3/fav/folder/created/list-all', (p) {
          expect(p['up_mid'], 476593058);
          expect(p.containsKey('pn'), isFalse, reason: '这个接口没有分页参数');
          return {
            'list': [
              {'id': 1155866758, 'title': '英语', 'media_count': 6},
              {'id': 99, 'name': '旧版字段', 'media_count': 2},
              {'id': 0, 'title': '没有 id 的一行'},
            ]
          };
        });
      final page = await _api(fake).createdFolders(upMid: 476593058);
      expect(page.items.length, 2, reason: 'id=0 的一行不该进列表');
      expect(page.total, 2);
      expect(page.items.first.mediaId, 1155866758);
      expect(page.items.first.title, '英语');
      expect(page.items.last.title, '旧版字段');
      expect(fake.countOf('/x/v3/fav/folder/created/list-all'), 1);
    });

    test('匿名回 code=0 但 data=null → 抛「要登录态」的错，不是空列表', () async {
      final fake = _Fake()
        ..onRaw('/x/v3/fav/folder/created/list-all',
            (p) => {'code': 0, 'message': 'OK', 'data': null});
      await expectLater(
        _api(fake).createdFolders(upMid: 1),
        throwsA(isA<BiliApiException>()),
      );
    });
  });

  group('翻页硬闸与传输装配', () {
    test('接口忽略 pn、每页都给同一批 → 到 maxPages 抛错而不是挂住', () async {
      final fake = _Fake()
        ..on('/x/v3/fav/resource/list', (p) => {
              'has_more': true,
              'info': {'media_count': 999999, 'title': 't'},
              'medias': _medias(40),
            });
      await expectLater(
        _api(fake).allFavResources(mediaId: 1, maxPages: 3),
        throwsA(isA<BiliListException>().having(
            (e) => e.reason, 'reason', BiliListReason.pageLimitExceeded)),
      );
      expect(fake.countOf('/x/v3/fav/resource/list'), 3);
    });

    test('没注入传输也没给 BiliApi → 结构化报「装配漏了」', () async {
      final api = BiliListApi();
      await expectLater(
        api.spaceArcs(mid: 1),
        throwsA(isA<BiliListException>()
            .having((e) => e.reason, 'reason', BiliListReason.transportMissing)),
      );
    });

    test('列表数组的键根本不存在 → 报 shapeMissing，不许静默当「一条稿都没有」', () async {
      final fake = _Fake()
        ..on('/x/space/wbi/arc/search', (p) => {
              'page': {'pn': 1, 'ps': 40, 'count': 12},
              // 既没有 list 也没有 archives：接口换形状 / 被塞了半个错误页
              'something': 1,
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      await expectLater(
        _api(fake).spaceArcs(mid: 1),
        throwsA(isA<BiliListException>()
            .having((e) => e.reason, 'reason', BiliListReason.shapeMissing)),
      );
    });

    test('正控制：键在但值是 null（真的空列表）不抛，回空', () async {
      final fake = _Fake()
        ..on('/x/space/wbi/arc/search', (p) => {
              'page': {'pn': 1, 'ps': 40, 'count': 0},
              'list': {'vlist': null},
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final page = await _api(fake).spaceArcs(mid: 1);
      expect(page.items, isEmpty);
      expect(page.total, 0);
    });

    test('注入的传输回整份响应（带 code）也收', () async {
      final fake = _Fake()
        ..onRaw('/x/polymer/web-space/seasons_archives_list', (p) => {
              'code': 0,
              'message': 'OK',
              'data': {
                'page': {'page_num': 1, 'page_size': 30, 'total': 1},
                'archives': _archives(from: 1, count: 1),
              },
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final page = await _api(fake).seasonArcs(mid: 1, seasonId: 2);
      expect(page.total, 1);
      // 正控制：同一个假传输遇到 code=-404 必须抛，否则上一条是空跑
      final bad = _Fake()
        ..onRaw('/x/polymer/web-space/seasons_archives_list',
            (p) => {'code': -404, 'message': '啥也不是'});
      await expectLater(
        _api(bad).seasonArcs(mid: 1, seasonId: 2),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -404)),
      );
    });
  });

  group('与链接层对接：分流与互斥', () {
    test('明说 type=series 的链接 → 请求清单里只有系列接口，合集一次都没被打到', () async {
      final fake = _Fake()
        ..on('/x/series/archives', (p) {
          expect(p['series_id'], 1970940);
          return {
            'page': {'num': 1, 'size': 30, 'total': 1},
            'archives': _archives(from: 1, count: 1),
          };
        })
        ..on('/x/series/series', (p) => {
              'meta': {'series_id': 1970940, 'mid': 123, 'name': 'galgame', 'total': 1}
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final target = parseBiliRef(
          'https://space.bilibili.com/228292951/lists/1970940?type=series')!
          .list!;
      final page = await _api(fake).arcs(target);
      expect(page.items.length, 1);
      expect(fake.paths, contains('/x/series/archives'));
      expect(fake.paths, isNot(contains('/x/polymer/web-space/seasons_archives_list')),
          reason: '链接明说 series，就绝不允许再去查合集接口');
    });

    test('正控制：type=season 的链接走的是合集接口（上面那条不是空断言）', () async {
      final fake = _Fake()
        ..on('/x/polymer/web-space/seasons_archives_list', (p) {
          expect(p['season_id'], 9225450);
          return {
            'page': {'page_num': 1, 'page_size': 30, 'total': 1},
            'archives': _archives(from: 1, count: 1),
          };
        })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final target = parseBiliRef(
          'https://space.bilibili.com/228292951/lists/9225450?type=season')!
          .list!;
      final page = await _api(fake).arcs(target);
      expect(page.items.length, 1);
      expect(fake.paths, contains('/x/polymer/web-space/seasons_archives_list'));
      expect(fake.paths, isNot(contains('/x/series/archives')));
      expect(fake.paths, isNot(contains('/x/series/series')),
          reason: '链接明说 season，反过来也不许去探系列');
    });

    test('身份未定的链接由 resolveTarget 判，判完直接取列表', () async {
      final fake = _Fake()
        ..on('/x/web-interface/wbi/view', (p) {
          expect(p['bvid'], 'BV1U5411N7sc');
          return {'ugc_season': {'id': 9225450, 'mid': 228292951}};
        })
        ..on('/x/polymer/web-space/seasons_archives_list', (p) => {
              'page': {'page_num': 1, 'page_size': 30, 'total': 1},
              'archives': _archives(from: 1, count: 1),
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final api = _api(fake);
      final ref = parseBiliRef('https://www.bilibili.com/list/999'
          '?sid=9225450&bvid=BV1U5411N7sc')!;
      final target = await api.resolveTarget(ref.list!);
      expect(target.kind, BiliListKind.season);
      expect(target.mid, 228292951, reason: 'mid 用接口给的，不用链接里的 999');
      final items = await api.allArcs(target);
      expect(items.length, 1);
      expect(fake.paths, isNot(contains('/x/series/series')));
    });

    test('探针判成系列后，arcs 拿 meta 复用；unknown 目标直接拒', () async {
      final fake = _Fake()
        ..on('/x/series/series', (p) => {
              'meta': {'series_id': 5, 'mid': 7, 'name': 'g', 'total': 2}
            })
        ..on('/x/series/archives', (p) => {
              'page': {'num': 1, 'size': 30, 'total': 2},
              'archives': _archives(from: 1, count: 2),
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '猫'}});
      final api = _api(fake);
      final target = await api.resolveTarget(
          BiliListTarget(kind: BiliListKind.unknown, mid: 1, sid: 5));
      expect(target.kind, BiliListKind.series);
      expect(target.seriesMeta, isNotNull);
      final items = await api.allArcs(target);
      expect(items.length, 2);
      expect(fake.countOf('/x/series/series'), 1, reason: '探针的 meta 要复用掉');
      await expectLater(
        api.arcs(BiliListTarget(kind: BiliListKind.unknown, mid: 1, sid: 5)),
        throwsA(isA<BiliListException>().having(
            (e) => e.reason, 'reason', BiliListReason.targetKindMismatch)),
      );
    });

    test('收藏夹链接整条走通：favId 进 media_id', () async {
      final fake = _Fake()
        ..on('/x/v3/fav/resource/list', (p) {
          expect(p['media_id'], 1155866758);
          return {
            'has_more': false,
            'info': {'media_count': 1, 'title': '英语'},
            'medias': _medias(1),
          };
        });
      final target =
          parseBiliRef('https://www.bilibili.com/medialist/detail/ml1155866758')!
              .list!;
      final items = await _api(fake).allArcs(target);
      expect(items.length, 1);
      expect(fake.paths, ['/x/v3/fav/resource/list']);
    });
  });

  group('列表项 → Media', () {
    test('映射到既有稿件模型：source=bili，cid 留空等 view 展开', () async {
      final fake = _Fake()
        ..on('/x/polymer/web-space/seasons_archives_list', (p) => {
              'page': {'page_num': 1, 'page_size': 30, 'total': 1},
              'archives': [
                {
                  'bvid': 'BV1S4pK6tEuR',
                  'aid': 117370215471804,
                  'title': '8K超分',
                  'pic': 'http://i0.hdslb.com/bfs/archive/a.jpg',
                  'duration': 98,
                  'pubdate': 1790927563,
                  'state': 0,
                  'stat': {'view': 223},
                }
              ],
            })
        ..on('/x/web-interface/card', (p) => {'card': {'name': '海边的猫', 'mid': '123'}});
      final target =
          BiliListTarget(kind: BiliListKind.season, mid: 123, seasonId: 9225450);
      final medias = _api(fake).toMedias((await _api(fake).allArcs(target)));
      expect(medias, hasLength(1));
      final m = medias.single;
      expect(m.source, 'bili');
      expect(m.id, 'BV1S4pK6tEuR');
      expect(m.tweetId, 'BV1S4pK6tEuR');
      expect(m.tweetText, '8K超分');
      expect(m.userName, '海边的猫');
      expect(m.userId, '123');
      expect(m.durationMs, 98000);
      expect(m.previewUrl, 'https://i0.hdslb.com/bfs/archive/a.jpg');
      expect(m.url, isEmpty, reason: '列表阶段不给下载地址');
      expect(m.variants, isEmpty);
      expect(m.bili!.bvid, 'BV1S4pK6tEuR');
      expect(m.bili!.aid, '117370215471804');
      expect(m.bili!.cid, isNull, reason: '列表接口不给 cid，不许填假值');
      // 统计量各归各位：`stat.view` 是播放量，落在 [BiliArchive.viewCount] 上；
      // Media 的通用统计字段（点赞 / 评论 / 收藏 / 分享）接口没给就该是 null，
      // 不许为「界面有数」把播放量塞进点赞。
      expect(m.likeCount, isNull, reason: 'stat.view 是播放量，不许冒充 likeCount');
      expect(m.commentCount, isNull);
      expect(m.collectCount, isNull);
      expect(m.shareCount, isNull);
      expect(m.bili!.partTotal, 1);
      expect(m.bili!.workTitle, '8K超分');
    });

    test('没有 BV 号的行（广告位之类）被丢掉，重复的 bvid 不排两行', () async {
      final page = BiliListResult<BiliArchive>(
        items: [
          _archive(''),
          _archive('BV1S4pK6tEuR'),
          _archive('BV1S4pK6tEuR'),
        ],
        total: 3,
        pageNum: 1,
        pageSize: 30,
      );
      final api = BiliListApi(
        signed: (p, q) async => const {},
        plain: (p, q) async => const {},
      );
      expect(api.toMedias(page.items), hasLength(1));
    });
  });
}

// ── 假传输与夹具 ───────────────────────────────────────────────

BiliListApi _api(_Fake fake) =>
    BiliListApi(signed: fake.transport, plain: fake.transport);

class _Fake {
  final Map<String, Map<String, dynamic> Function(Map<String, dynamic> params)>
      _handlers = {};
  final List<(String, Map<String, dynamic>)> calls = [];

  /// 处理器回的是**接口的 data 本体**（与 `BiliApi.getData` 同形）。
  _Fake on(String path, Map<String, dynamic> Function(Map<String, dynamic>) fn) {
    _handlers[path] = fn;
    return this;
  }

  /// 处理器回**整份响应**（页内 fetch 那一侧顺手拿到的是 `{code, message, data}`）。
  /// 与本层契约上该回 `data`，但两种都收 —— 这条由 `onRaw` 那两组用例钉住。
  _Fake onRaw(String path, Map<String, dynamic> Function(Map<String, dynamic>) fn) =>
      on(path, fn);

  List<String> get paths => calls.map((c) => c.$1).toList();

  int countOf(String path) => paths.where((p) => p == path).length;

  Map<String, dynamic>? lastParams(String path) {
    for (var i = calls.length - 1; i >= 0; i--) {
      if (calls[i].$1 == path) return calls[i].$2;
    }
    return null;
  }

  /// 硬纪律的自动化钉子：参照实现那四个 GPU / 屏幕串一个都不许出现在请求里。
  void assertNoDeviceFingerprint() {
    const banned = [
      'dm_img_list',
      'dm_img_str',
      'dm_cover_img_str',
      'dm_img_inter',
    ];
    for (final c in calls) {
      for (final key in banned) {
        expect(c.$2.containsKey(key), isFalse,
            reason: '${c.$1} 带了参照实现机器的指纹参数 $key');
      }
    }
  }

  BiliListTransport get transport => (path, params) async {
        final snapshot = Map<String, dynamic>.from(params);
        calls.add((path, snapshot));
        final fn = _handlers[path];
        if (fn == null) {
          throw BiliApiException('no fixture handler for $path');
        }
        return fn(snapshot);
      };
}

/// `arc/search` 的 data：总数在 `page.count`，列表在 `list.vlist`。
Map<String, dynamic> _arcSearch({
  required int pn,
  required int ps,
  required int count,
}) {
  final from = (pn - 1) * ps + 1;
  final n = count - from + 1;
  return {
    'page': {'pn': pn, 'ps': ps, 'count': count},
    'list': {'vlist': _vlist(from, n > ps ? ps : n)},
  };
}

List<Map<String, dynamic>> _vlist(int from, int count) => [
      for (var i = 0; i < count; i++)
        {
          'bvid': 'BV${(from + i).toString().padLeft(10, '0')}',
          'aid': 1000 + from + i,
          'title': '第${from + i}稿',
          'author': '',
          'cover': 'http://i0.hdslb.com/bfs/archive/${from + i}.jpg',
          'duration': 60,
          'pubdate': 1705756536,
          'mid': 123,
          'state': 0,
        }
    ];

List<Map<String, dynamic>> _archives({required int from, required int count}) => [
      for (var i = 0; i < count; i++)
        {
          'bvid': 'BV${(from + i).toString().padLeft(10, '0')}',
          'aid': 1000 + from + i,
          'title': '合集里的第${from + i}条',
          'pic': 'http://i0.hdslb.com/bfs/archive/x.jpg',
          'duration': 98,
          'pubdate': 1790927563,
          'state': 0,
          'stat': {'view': 223},
        }
    ];

List<Map<String, dynamic>> _medias(int count, {int from = 1}) => [
      for (var i = 0; i < count; i++)
        {
          'id': 851918256 + from + i,
          'bvid': 'BV${(from + i).toString().padLeft(10, '0')}',
          'title': '收藏夹里的第${from + i}条',
          'cover': 'http://i1.hdslb.com/a.jpg',
          'duration': 274,
          'pubtime': 1646213446,
          'upper': {'mid': 433406580, 'name': '学习号'},
          'cnt_info': {'play': 10},
        }
    ];

BiliArchive _archive(String bvid) => BiliArchive(
      bvid: bvid,
      aid: 1,
      title: 't',
      cover: '',
      durationMs: 1000,
      publishTime: null,
      upperMid: 1,
      upperName: 'u',
      partTotal: 1,
      state: 0,
      viewCount: 0,
    );
