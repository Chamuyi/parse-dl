/// 元数据：nfo（媒体库读）与 json（我们那份解析结果）。
///
/// 两档的代价不一样，这里要如实分开：
///  * **nfo 要多取一次接口**。`view` 不回标签，标签在
///    `x/web-interface/view/detail/tag?bvid=`（2026-10-10 匿名实测 code=0，
///    `data[]` 每项一个 `tag_name`）。所以勾 nfo 会多一个请求，json 档不会。
///  * json 档是「原样存一份」，不做过滤与排序 —— 它的用途就是事后能对上是
///    哪个响应，替它挑字段反而破坏了用途。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/bili_config.dart';
import 'bili_additional.dart';

typedef BiliTagFetcher = Future<List<String>> Function(String bvid);

/// `x/web-interface/view/detail/tag` 的 `data[]` → 标签名列表。
/// 形状不对（没登录被裁、接口改版）时回空列表，不抛。
List<String> biliTagsFromData(Object? data) {
  if (data is! List) return const [];
  return [
    for (final e in data)
      if (e is Map && e['tag_name'] is String) (e['tag_name'] as String).trim(),
  ].where((s) => s.isNotEmpty).toList();
}

/// 渲染 nfo。[view] 是 `x/web-interface/wbi/view` 的 `data` 本体。
String biliMetadataToNfo({
  required Map<String, dynamic> view,
  required List<String> tags,
  required String partTitle,
  required int partIndex,
}) {
  final title = _str(view['title']).isEmpty ? partTitle : _str(view['title']);
  final lines = <String>[
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<movie>',
    '  <title>${_x(title)}</title>',
    if (partIndex > 1) '  <originaltitle>${_x(partTitle)}</originaltitle>',
    '  <plot>${_x(_str(view['desc']))}</plot>',
    if (_str(view['tname']).isNotEmpty) '  <genre>${_x(_str(view['tname']))}</genre>',
    if (_str((view['owner'] is Map ? view['owner']['name'] : '')).isNotEmpty)
      '  <studio>${_x(_str((view['owner'] as Map)['name']))}</studio>',
    for (final t in tags)
      '  <tag>${_x(t)}</tag>',
    if (_str(view['bvid']).isNotEmpty)
      '  <uniqueid type="bilibili">${_x(_str(view['bvid']))}</uniqueid>',
    '  <premiered>${_iso(_int(view['pubdate']))}</premiered>',
    '</movie>',
  ];
  return lines.join('\n');
}

/// 写元数据文件，返回落盘的文件名列表（没开开关就是空表）。
Future<List<String>> biliWriteMetadata({
  required BiliConfig cfg,
  required String saveDir,
  required String outBase,
  required Map<String, dynamic> view,
  required String partTitle,
  required int partIndex,
  required BiliTagFetcher? fetchTags,
}) async {
  if (!cfg.saveMetadata) return const [];
  final out = <String>[];
  if (cfg.metadataFormat == BiliMetadataFormat.json) {
    final name = biliAdditionalName(
      base: outBase,
      qualifier: '元数据',
      ext: 'json',
    );
    await File(p.join(saveDir, name)).writeAsString(
      const JsonEncoder.withIndent('  ').convert(view),
    );
    out.add(name);
    return out;
  }
  final bvid = _str(view['bvid']);
  final tags = bvid.isEmpty || fetchTags == null ? const <String>[] : await fetchTags(bvid);
  final name = biliAdditionalName(
    base: outBase,
    qualifier: '元数据',
    ext: 'nfo',
  );
  await File(p.join(saveDir, name)).writeAsString(
    biliMetadataToNfo(
      view: view,
      tags: tags,
      partTitle: partTitle,
      partIndex: partIndex,
    ),
  );
  out.add(name);
  return out;
}

String _str(Object? v) => v is String ? v : (v == null ? '' : '$v');

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

/// 投稿时间戳（秒）→ `YYYY-MM-DD`。0 / 负数一律当「不知道」，不写成 1970。
String _iso(int epochSeconds) {
  if (epochSeconds <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

String _x(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
