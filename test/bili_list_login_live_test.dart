import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_api.dart';
import 'package:parse_dl/services/bili_list_api.dart';

/// **登录档**的列表层真接口复核：把计划书里那三格「匿名验不了」的一次跑完。
///
/// 为什么单独一个执行器而不是塞进 `bili_list_live_test.dart`：那份是匿名档，
/// 任何时候都能重跑；这一份要用他的登录态，跑一次就要他配合一次，
/// 所以判据要一次拿全，并且**没给 cookie 就整支 skip**，绝不半跑。
///
/// 凭据纪律（这条是这个文件存在的主要约束）：
///  * cookie 只从环境变量 `PD_BILI_COOKIE` 进来，只交给 [BiliApi.setCookie] 那个
///    **内存字段**；不写文件、不打日志、不进报告 JSON、不进异常文本（异常文本由
///    `bili_api.dart` 那一层保证不含 cookie，它报错只带路径与业务码）；
///  * 只报字节数，用来定位「拿没拿到整串」。
///
/// 三格各验什么（对应计划书 §八 的 Q3 / Q4 / Q5）：
///   1. **`arc/search` 的字段路径**：`data.page.count` 与 `data.list.vlist[]` 至今只有
///      参照实现给的口径（匿名直连被风控拒），这一跑是它第一次拿到真响应；
///   2. **`player/wbi/v2` 给不给字幕**（Q4）：匿名对 9 条全回 0 条字幕，分不清
///      「本来没有」与「匿名不给」；带上登录态数一次就知道「仅人工字幕」那档要不要登录；
///   3. **`fav/folder/created/list-all`**（Q5 的 Dart 侧）：能不能拿到他自建收藏夹的
///      `id/title/media_count`。⚠️ 这只证明**接口与字段**，不证明页内 fetch 那条路
///      能带上凭据 —— 后者要在真页面上点一次才算。
///
///     PD_BILI_LIST=F:/qoder/_tools/bili/listlive \
///     PD_BILI_COOKIE='<从浏览器复制的整串 cookie>' \
///       flutter test test/bili_list_login_live_test.dart
void main() {
  final outDir = Platform.environment['PD_BILI_LIST'];
  final cookie = Platform.environment['PD_BILI_COOKIE'] ?? '';
  final mid = int.parse(Platform.environment['PD_BILI_MID'] ?? '0');

  test(
    '登录档：arc/search 真响应 + 字幕给不给 + 自建收藏夹列表',
    timeout: const Timeout(Duration(minutes: 6)),
    skip: outDir == null
        ? '没给 PD_BILI_LIST'
        : (cookie.isEmpty ? '没给 PD_BILI_COOKIE，登录档不跑' : false),
    () async {
      // 同其他真机执行器：**不初始化 TestWidgetsFlutterBinding**，
      // 否则所有 HttpClient 请求被直接打回 400，看着像 B 站限流。
      stdout.writeln('LOGIN cookie bytes=${cookie.length}（只报字节数）');
      final api = BiliApi()..setCookie(cookie);
      final listApi = BiliListApi(api: api);
      // 没指定 mid 就用 nav 自己回的那个 —— 顺带证明这颗 cookie 是活的
      // （`nav` 匿名也回 `isLogin=false`，所以 isLogin 必须一起判，不能只拿到 mid）。
      final nav = await api.getData('/x/web-interface/nav', null, what: 'nav');
      expect(nav['isLogin'], true,
          reason: 'cookie 没让接口认出登录态，这一跑的证据不作数');
      final useMid = mid > 0 ? mid : int.tryParse('${nav['mid']}') ?? 0;
      expect(useMid, greaterThan(0));
      final report = <String, dynamic>{
        'mid': useMid,
        'navUname': nav['uname'],
        'cookie': '（不落盘）',
      };

      // ── 1) 主页投稿：第一次拿真响应，字段路径按夹具那样对不对 ──────────
      final page = await listApi.spaceArcs(mid: useMid, ps: 20);
      report['arcSearch'] = {
        'total': page.total,
        'items': page.items.length,
        'pageSize': page.pageSize,
        'firstBvid': page.items.isEmpty ? null : page.items.first.bvid,
        'firstTitle': page.items.isEmpty ? null : page.items.first.title,
        'firstUpper': page.items.isEmpty ? null : page.items.first.upperName,
        'firstDurationMs': page.items.isEmpty ? null : page.items.first.durationMs,
        'allHaveBvid': page.items.every((a) => a.bvid.isNotEmpty),
      };
      expect(
        page.items,
        isNotEmpty,
        reason: '带登录态还是拿不到投稿：那要么 cookie 已失效，要么字段路径要改',
      );
      expect(page.total, greaterThan(0), reason: '总数读的不是 data.page.count');
      expect(page.items.every((a) => a.bvid.isNotEmpty), isTrue);
      // 作者名：vlist 自己带 `author`，那就不该退回 card 的空串
      expect(
        page.items.first.upperName,
        isNotEmpty,
        reason: 'vlist 的 author 字段没接上，列表里会整片没有 UP 名',
      );

      // ── 2) 字幕：登录之后给不给、给的是人工还是 AI ────────────────────
      final subs = <Map<String, dynamic>>[];
      for (final a in page.items.take(5)) {
        try {
          final v = await api.view(bvid: a.bvid);
          if (v.pages.isEmpty) continue;
          final data = await api.getSignedData('/x/player/wbi/v2', {
            'cid': v.pages.first.cid,
            'bvid': a.bvid,
          }, what: '/x/player/wbi/v2');
          final list =
              ((data['subtitle'] as Map?)?['subtitles'] as List?) ?? const [];
          subs.add({
            'bvid': a.bvid,
            'count': list.length,
            'langs': [
              for (final e in list.whereType<Map>()) '${e['lan']}',
            ],
            'hasAi': list.whereType<Map>().any(
                  (e) => '${e['lan']}'.toLowerCase().startsWith('ai-'),
                ),
            'aiStatus': data['ai_status'],
          });
        } catch (e) {
          // 一条稿件失败不掀整支：这一格的目的就是「看到真实分布」，
          // 少一条也是证据。异常文本里没有 cookie（接口层保证）。
          subs.add({'bvid': a.bvid, 'error': '$e'});
        }
      }
      report['playerSubtitles'] = subs;
      // 只钉形状，不钉结论：有没有字幕是账号与稿件决定的，断言「必须有」会假红。
      expect(subs, isNotEmpty, reason: '一条都没问到，这一格就没跑成');

      // ── 3) 自建收藏夹：Q5 的 Dart 侧 ────────────────────────────────
      final folders = await listApi.createdFolders(upMid: useMid);
      report['createdFolders'] = {
        'count': folders.items.length,
        'first': folders.items.isEmpty
            ? null
            : {
                'mediaId': folders.items.first.mediaId,
                'title': folders.items.first.title,
                'mediaCount': folders.items.first.mediaCount,
              },
      };
      // 允许他一个自建收藏夹都没有：那这一格拿到的证据是「接口通、字段在、结果为空」。
      if (folders.items.isNotEmpty) {
        expect(folders.items.first.mediaId, greaterThan(0));
      }

      File('$outDir/login_report.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(report),
          flush: true,
        );
      stdout.writeln(
        'LOGINLIVE arcs=${page.items.length}/${page.total} '
        'subs=${subs.fold<int>(0, (s, e) => s + (e['count'] as int? ?? 0))} '
        'folders=${folders.items.length}',
      );
    },
  );
}
