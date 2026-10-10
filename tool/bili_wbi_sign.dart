// 纯 Dart 的签名工具：把 nav 的 wbi_img 地址与一组参数交给**生产代码**签好，打印 query。
//
// 存在理由：验收那一跑要拿登录态发请求，而登录态只在浏览器里，
// 所以「签名」这步只能由外部脚本算出完整 URL、再由页面去发。
// 外部脚本（Python）算的 query 必须与 `biliSignWbi` 一致才作数 ——
// 用 `--json` 同时喂给两边，逐字节比 `w_rid` 就是这次等价性的证据。
//
// 用法：dart run tool/bili_wbi_sign.dart <in.json>
// in.json = {"img_url":"...","sub_url":"...","targets":[{"path":"/x/...","wts":123,"params":{...}}]}
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:parse_dl/services/bili_wbi.dart';

void main(List<String> args) {
  final doc =
      jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final mk = biliMixinKey(
    biliKeyFromUrl(doc['img_url'] as String),
    biliKeyFromUrl(doc['sub_url'] as String),
  );
  final out = <Map<String, dynamic>>[];
  for (final t in (doc['targets'] as List).cast<Map<String, dynamic>>()) {
    final params = (t['params'] as Map).cast<String, dynamic>();
    final wts = t['wts'] as int?;
    final signed = biliSignWbi(params, mk, wts: wts);
    out.add({
      'path': t['path'],
      'query': biliWbiQuery(signed),
      'w_rid': signed['w_rid'],
      'mixin_key_len': mk.length,
    });
  }
  // 密钥本身不外传：只报 mixinKey 的长度，够定位「取错 key」这一类问题。
  stdout.write(jsonEncode(out));
  stdout.write('\n# md5 sanity: '
      '${md5.convert(utf8.encode('abc'))}\n');
}
