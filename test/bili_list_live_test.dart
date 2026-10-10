import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/bili_api.dart';
import 'package:parse_dl/services/bili_link.dart';
import 'package:parse_dl/services/bili_list_api.dart';
import 'package:parse_dl/services/bili_batch_runner.dart';

/// B 提交列表层的**真接口**复核（匿名可通的那几支）。
///
/// 为什么单独做一个执行器：`bili_list_api_test.dart` 全是夹具，而计划书在
/// B-a 那格明写过「接了页内 fetch 之后第一件事是拿真响应复核这几个路径」。
/// 匿名通道能覆盖的是 `view` 的 `ugc_season` → 合集 → `seasons_archives_list`
/// → `card` 这四步；`arc/search`（匿名 412）与 `x/series/*` 要靠真登录态那一轮，
/// 这里**不假装验过**，只在报告里标成没覆盖。
///
/// 只在环境变量给目录时才跑：
///
///     PD_BILI_LIST=F:/qoder/_tools/bili/listlive \
///       flutter test test/bili_list_live_test.dart
///
/// 候选稿件用 `PD_BILI_BVIDS=BV1xx,BV1yy` 传（逗号分隔）。默认那串是本轮验收
/// 已经匿名跑通过的公开稿件，**不带任何登录态**，也不碰他的 cookie。
void main() {
  final outDir = Platform.environment['PD_BILI_LIST'];
  final seeds = (Platform.environment['PD_BILI_BVIDS'] ??
          'BV1uzas6vEBB,BV1RXYF6kEMp,BV1E2RYBaEvT,BV1WxaY6jETA,BV1pzeH6REr7')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  test(
    '真接口：view → ugc_season → 合集翻到尽 → 稿件展开成有 cid 的分 P',
    timeout: const Timeout(Duration(minutes: 6)),
    skip: outDir == null ? '没给 PD_BILI_LIST，列表层真接口复核不跑' : false,
    () async {
      // 同验收执行器：**不初始化 TestWidgetsFlutterBinding**，
      // 那个 binding 会把所有 HttpClient 请求打回 400，真接口复核就假了。
      final api = BiliApi();
      final listApi = BiliListApi(api: api);
      final report = <String, dynamic>{'tried': <String>[]};

      Map<String, dynamic>? season;
      String? hitBvid;
      for (final bvid in seeds) {
        final data =
            await api.getSignedData('/x/web-interface/wbi/view', {'bvid': bvid},
                what: 'view');
        final s = data['ugc_season'];
        report['tried']
            .add('$bvid:${data['mid']}:${s is Map ? 'season=${s['id']}' : '无合集'}');
        if (s is Map && s['id'] != null) {
          season = s.cast<String, dynamic>();
          hitBvid = bvid;
          report['workTitle'] = data['title'];
          report['mid'] = data['mid'];
          break;
        }
      }
      expect(hitBvid, isNotNull,
          reason: '候选里没有任何带合集的稿件：换一个 bvid 再跑（${report['tried']}）');

      // 走**链接层**而不是手搓目标：用户贴的就是这种播放页地址，
      // 而 `sid` 既可能是合集也可能是系列，判定链必须被真接口跑一遍。
      final mid = season!['mid'] ?? report['mid'];
      final sid = season['id'];
      final link = 'https://www.bilibili.com/list/$mid?sid=$sid&bvid=$hitBvid';
      final ref = parseBiliRef(link);
      expect(ref?.list?.kind, BiliListKind.unknown, reason: '$link 没被认成待判列表');
      report['link'] = link;

      final judged = await listApi.resolveTarget(ref!.list!);
      report['judgedKind'] = judged.kind.name;
      report['judgedSeasonId'] = judged.seasonId;
      report['judgedMid'] = judged.mid;
      // 判定用的是接口给的 id/mid，不是链接路径里那两个数字（Bili23 实证过这点）。
      expect(judged.kind, BiliListKind.season,
          reason: 'view 的 ugc_season 已经说清是合集，判成别的就是把分流写错了');
      expect(judged.seasonId, sid);

      final summary = await listApi.allArcsSummary(judged);
      report['seasonTitle'] = season['title'] ?? '';
      report['listTitle'] = summary.listTitle;
      report['collected'] = summary.items.length;
      report['skippedUnsupported'] = summary.skipped;
      report['firstItems'] = [
        for (final a in summary.items.take(5))
          {
            'bvid': a.bvid,
            'aid': a.aid,
            'title': a.title,
            'mid': a.upperMid,
            'name': a.upperName,
            'durationMs': a.durationMs,
            'state': a.state,
            'partTotal': a.partTotal,
          },
      ];
      expect(summary.items, isNotEmpty, reason: '真合集不可能一条稿件都不给');
      expect(summary.listTitle, isNotEmpty, reason: '列表名没接上：界面那一行会是空的');
      expect(summary.skipped, 0, reason: '合集里出现没 BV 号的行说明字段路径写错了');

      // 用户名那一支顺带复核：合集的 archives 不带作者名，靠 `card` 补。
      final card = await listApi.card(int.parse('$mid'));
      report['cardName'] = card.name;
      expect(card.name, isNotEmpty, reason: 'card 拿不到名字，列表那一列会整片空着');

      // 最后一步：列表项**没有 cid**，必须能靠 `view` 展开成可下载的分 P。
      // 这一步不通过，批量页就是「列出来但一条都下不了」。
      final first = summary.items.firstWhere((a) => a.available);
      final view = await api.view(bvid: first.bvid);
      final parts = biliPartsOfView(view);
      report['expanded'] = {
        'bvid': first.bvid,
        'parts': parts.length,
        'cid': parts.isEmpty ? null : parts.first.bili?.cid,
        'durationMs': parts.isEmpty ? null : parts.first.durationMs,
      };
      expect(parts, isNotEmpty, reason: '展开不出分 P，批量页拿它没法取流');
      expect(int.tryParse(parts.first.bili?.cid ?? ''), greaterThan(0));

      File('$outDir/report.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report),
            flush: true);
      stdout.writeln('LISTLIVE ok season=${summary.listTitle} '
          'items=${summary.items.length}');
    },
  );

  test(
    '真接口：系列的正向形状 + 「sid 是系列」的分流（匿名可通那一半）',
    timeout: const Timeout(Duration(minutes: 4)),
    skip: outDir == null ? '没给 PD_BILI_LIST，列表层真接口复核不跑' : false,
    () async {
      // 默认这个 UP 是公开的、且确实有系列（2026-10-11 真接口跑的样本：
      // `series_list` 有 11 条，第一条「青春旅行团」`series_id=4684427`、`total=13`）。
      final mid = int.parse(Platform.environment['PD_BILI_MID'] ?? '546195');
      final api = BiliApi();
      final listApi = BiliListApi(api: api);

      // 系列的 id 没有公开的目录接口能猜，只能从 UP 自己的「合集与系列列表」里拿。
      // 这一支只是**取证用的探针**：生产代码不读它，读它的是下面那三步。
      final data = await api.getData(
        '/x/polymer/web-space/seasons_series_list',
        {'mid': mid, 'page_num': 1, 'page_size': 20},
        what: 'seasons_series_list',
      );
      File('$outDir/seasons_series.json')
        .writeAsStringSync(jsonEncode(data), flush: true);
      final seriesList =
          (data['items_lists'] as Map?)?['series_list'] as List? ?? const [];
      // 真响应的 id 键叫 `series_id`（`seasons_series_list` 与 `x/series/series`
      // 都是这一套；`x/polymer/…/seasons_list` 那边才叫 `season_id`）。
      final seriesIds = <int>[
        for (final e in seriesList.whereType<Map>())
          ?(_asInt((e['meta'] as Map?)?['series_id']) ??
              _asInt((e['meta'] as Map?)?['id'])),
      ];
      expect(seriesIds, isNotEmpty,
          reason: '这个 UP 没有系列，换一个 PD_BILI_MID（原始响应已落在 report 旁边）');
      final seriesId = seriesIds.first;

      // 1) 探针的正向形状：夹具里只有否定的 147002，这一步补上肯定的那一半
      final meta = await listApi.probeSeries(seriesId);
      expect(meta, isNotNull, reason: '真系列 id 探针却没给 meta：字段路径写错了');
      expect(meta!.name, isNotEmpty);

      // 2) 分流：链接只给 `sid`（既可能是合集也可能是系列）时必须判成系列，
      //    而且**不许再去打合集接口** —— 这是互斥那条纪律的现场版。
      final link = 'https://www.bilibili.com/list/$mid?sid=$seriesId';
      final ref = parseBiliRef(link);
      expect(ref?.list?.kind, BiliListKind.unknown);
      final judged = await listApi.resolveTarget(ref!.list!);
      expect(judged.kind, BiliListKind.series,
          reason: '$link 判成了 ${judged.kind.name}，分流在真接口上不成立');
      expect(judged.seriesId, seriesId);

      // 3) 翻页与字段：series/archives 的项没有作者名，名要从 card 补
      final summary = await listApi.allArcsSummary(judged);
      final report = <String, dynamic>{
        'mid': mid,
        'seriesId': seriesId,
        'metaName': meta.name,
        'listTitle': summary.listTitle,
        'collected': summary.items.length,
        'skippedUnsupported': summary.skipped,
        'first': summary.items.isEmpty
            ? null
            : {
                'bvid': summary.items.first.bvid,
                'name': summary.items.first.upperName,
                'state': summary.items.first.state,
              },
      };
      File('$outDir/series_report.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report),
            flush: true);
      expect(summary.items, isNotEmpty);
      expect(summary.skipped, 0, reason: '系列里出现没 BV 号的行说明字段路径写错了');
      expect(summary.listTitle, isNotEmpty, reason: '系列名要从 meta 落到列表标题');
      stdout.writeln('LISTLIVE series ok ${meta.name} items=${summary.items.length}');
    },
  );
}

int? _asInt(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');
