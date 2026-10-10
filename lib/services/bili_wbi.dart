/// WBI 签名 —— B 站 web 接口的请求签名，纯计算层（不发请求）。
///
/// 算法照 B 站前端那份 JS（参照实现 `parser/base.py` 的 `enc_wbi` 是它的复刻）：
///   1. `nav` 返回两个图片地址，去掉扩展名的文件名就是 img_key / sub_key；
///   2. 两串拼成 64 位，按 [kMixinKeyEncTab] 逐位重排，截前 32 位得 mixinKey；
///   3. 参数补 `wts`（秒级时间戳）后按 key 字典序排，值里剔除 `!'()*`，
///      urlencode，`md5(query + mixinKey)` 就是 `w_rid`。
///
/// **为什么要单独一层而不是写进 [BiliApi] 的方法里**：签名是「给一组参数、
/// 得一个签名」的纯函数，能拿已知向量离线钉死；而取密钥、缓存、重试是另一件事。
/// B 站的密钥按天轮换、算法又完全在客户端侧，任何一处排序或转义写错，
/// 表现都是 `-403`「风控」这种与网络毫无关系的错误 —— 只有把算法本身
/// 关在测试里才防得住（所以 `wts` 做成可注入参数）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 固定重排表（64 项）。前端 JS 里硬编码，服务端只换密钥不换表，
/// 所以这张表一旦改动就等于算法换代，不是配置项。
const List<int> kMixinKeyEncTab = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
  33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
  61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
  36, 20, 34, 44, 52,
];

/// 表里最大下标是 63，所以两个 key 拼起来至少要 64 个字符才够取。
const int kBiliKeySourceLength = 64;

/// mixinKey 定长 32 位（重排之后截断）。
const int kBiliMixinKeyLength = 32;

/// 签名前要的值里剔除的字符：`!` `'` `(` `)` `*`。
///
/// 这五个在 JS 的 `encodeURIComponent` 与 Python/Dart 的 query 编码里规则不一致，
/// 留着会让「客户端算的 query」和「服务端重算的 query」字节不同，签名必然对不上。
/// 用码点集合而不是正则：省掉字符类里转义这五个符号的写法坑。
const Set<int> kBiliStrippedValueChars = {0x21, 0x27, 0x28, 0x29, 0x2A};

/// 拼出 mixinKey。
///
/// key 不够长时抛可读中文而不是让下标越界：短 key 只可能是 `nav` 没返回
/// `wbi_img` 或只返回了半套（弱网与被风控下的真实形态），而 `RangeError`
/// 看上去像本地代码 bug，用户与集成方都无从归因。
String biliMixinKey(String imgKey, String subKey) {
  final source = '$imgKey$subKey';
  if (source.length < kBiliKeySourceLength) {
    throw BiliWbiException(
      'wbi 签名密钥不足：img_key + sub_key 只有 ${source.length} 个字符，'
      '需要 $kBiliKeySourceLength 个（通常是 nav 接口没返回 wbi_img）',
    );
  }
  final buffer = StringBuffer();
  for (final index in kMixinKeyEncTab) {
    buffer.write(source[index]);
  }
  return buffer.toString().substring(0, kBiliMixinKeyLength);
}

/// 给参数签名，返回**新** map（含 `w_rid` 与 `wts`，值一律是剔除特殊字符之后的字符串）。
///
/// 为什么结果里放的是过滤后的值：签名算的是「过滤 + 编码之后的 query」，
/// 请求发出去的也必须是同一串字节，服务端才会重算出同一个 `w_rid`。
/// 所以调用方拿这个 map 直接交给 [biliWbiQuery] 拼地址，别再回头用原始参数拼。
///
/// [wts] 可注入 —— 已知向量测试要的正是「同样的输入 → 同样的签名」。
/// 值为 `null` 的项直接跳过，方便上层把 `bvid` / `aid` 这类可选参数一起传进来。
Map<String, dynamic> biliSignWbi(
  Map<String, dynamic> params,
  String mixinKey, {
  int? wts,
}) {
  final signed = <String, String>{};
  for (final entry in params.entries) {
    final value = entry.value;
    if (value == null) continue;
    signed[entry.key] = _stripSpecialChars('$value');
  }
  signed['wts'] =
      '${wts ?? DateTime.now().millisecondsSinceEpoch ~/ 1000}';

  final query = biliWbiQuery(signed);
  final digest = md5.convert(utf8.encode('$query$mixinKey'));
  return <String, dynamic>{...signed, 'w_rid': digest.toString()};
}

/// 拼 query。**排序与编码方式都参与签名**，所以签名与发请求共用这一个函数。
///
/// `Uri.encodeQueryComponent` 与参照实现用的 Python `urlencode`（`quote_plus`）
/// 逐字符等价：空格转 `+`、`~` 不转义、其余按 UTF-8 大写十六进制百分号编码。
/// 换成 `Uri.encodeComponent` 会把空格转成 `%20`，签名立刻对不上 ——
/// 这是本项目里最容易踩且最难从错误信息倒查出来的一条。
String biliWbiQuery(Map<String, dynamic> params) {
  final keys = params.keys.where((k) => params[k] != null).toList()..sort();
  return keys
      .map((k) =>
          '${Uri.encodeQueryComponent(k)}='
          '${Uri.encodeQueryComponent('${params[k]!}')}')
      .join('&');
}

/// 从 `nav` 的 `img_url` / `sub_url` 取出 key（文件名去扩展名）。
///
/// 地址形如 `https://i0.hdslb.com/bfs/face/xxx.jpg`，实测也见过带 query 的形态，
/// 所以先剥 `#` 与 `?` 再取后缀 —— 顺序反了会把鉴权参数当文件名。
String biliKeyFromUrl(String url) {
  if (url.isEmpty) return '';
  final path = url.split('#').first.split('?').first;
  final slash = path.lastIndexOf('/');
  final name = slash < 0 ? path : path.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

String _stripSpecialChars(String value) {
  final buffer = StringBuffer();
  for (final codeUnit in value.codeUnits) {
    if (kBiliStrippedValueChars.contains(codeUnit)) continue;
    buffer.writeCharCode(codeUnit);
  }
  return buffer.toString();
}

/// 签名这一层的失败原因（只有「算不出来」这一类；网络与业务错误由 `BiliApi` 抛）。
class BiliWbiException implements Exception {
  final String message;

  const BiliWbiException(this.message);

  @override
  String toString() => 'BiliWbiException: $message';
}
