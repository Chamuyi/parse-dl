/// X（Twitter）返回的时间字符串解析。
///
/// X 的 REST v1.1 `created_at` 与 GraphQL `legacy.created_at` 都是
/// **ctime/asctime 布局**（注意：它并不是严格 RFC 2822 的「日 月 年」顺序）：
///
/// ```
/// Wed Oct 10 20:19:24 +0000 2018      ← 星期 月 日 时:分:秒 时区 年
/// Wed Dec  1 12:00:00 +0000 2021      ← 日是一位数时前面补空格（C 的 %e）
/// ```
///
/// **Dart 的 `DateTime.parse` 只认 ISO-8601 的一个子集**，碰到上面这种格式
/// 直接抛 `FormatException`（`tryParse` 则返回 null）。之前就是拿它去解析，
/// 于是 `createdAt` 永远是 null → 文件名模板里的 `%POST_TIME%` 一直输出「未知日期」。
///
/// 原版靠 dayjs：`dayjs(item.legacy.created_at)` —— dayjs 对非 ISO 字符串会退回
/// `new Date(string)`，而 JS 的 `Date` 能解析这种格式。这里补上等价能力。
library;

/// 月份英文缩写（大小写不敏感）
const Map<String, int> _monthAbbr = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// X 实际使用的 **ctime 布局**：`[Wed ]Oct 10 20:19:24 +0000 2018`
///
/// 星期可省略；日是一位数时前面可能多一个空格（`\s+` 一起吃掉）；
/// 时区允许数字偏移（`+0000`）或名字（`UTC` / `GMT`）。
final RegExp _ctime = RegExp(
  r'^(?:[A-Za-z]{3,9},?\s+)?' // 可选星期：Wed / Wednesday / Wed,
  r'([A-Za-z]{3,9})\s+' // 月：Oct / October
  r'(\d{1,2})\s+' // 日：10
  r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s+' // 时:分[:秒]
  r'([+-]\d{4}|[A-Za-z]{1,5})\s+' // 时区：+0000 / UTC / GMT
  r'(\d{4})$', // 年：2018
);

/// 标准 **RFC 2822 布局**：`Wed, 10 Oct 2018 20:19:24 +0000`
///
/// X 本身不发这种，但别的时间源（或将来改版）可能会，顺手兼容一下。
final RegExp _rfc2822 = RegExp(
  r'^(?:[A-Za-z]{3,9},?\s+)?' // 可选星期
  r'(\d{1,2})\s+' // 日：10
  r'([A-Za-z]{3,9})\s+' // 月：Oct
  r'(\d{4})\s+' // 年：2018
  r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s+' // 时:分[:秒]
  r'([+-]\d{4}|[A-Za-z]{1,5})$', // 时区
);

/// `Oct` / `October` → 10；认不出返回 null。
int? _monthOf(String token) {
  final k = token.toLowerCase();
  return _monthAbbr[k.length >= 3 ? k.substring(0, 3) : k];
}

/// 时区字符串 → 偏移分钟数。数字偏移按 `+0800` 解析；名称（UTC/GMT/…）一律当 0。
int _offsetMinutesOf(String tzRaw) {
  if (tzRaw.length != 5 || (tzRaw[0] != '+' && tzRaw[0] != '-')) return 0;
  final sign = tzRaw[0] == '-' ? -1 : 1;
  final hh = int.tryParse(tzRaw.substring(1, 3)) ?? 0;
  final mm = int.tryParse(tzRaw.substring(3, 5)) ?? 0;
  return sign * (hh * 60 + mm);
}

DateTime _build({
  required int year,
  required int month,
  required int day,
  required int hour,
  required int minute,
  required int second,
  required String tzRaw,
}) =>
    // 先按「UTC 墙上时间 - 偏移」还原真实时刻，再转本地时区
    DateTime.utc(year, month, day, hour, minute, second)
        .subtract(Duration(minutes: _offsetMinutesOf(tzRaw)))
        .toLocal();

/// 解析 X 的时间字符串，失败返回 null（**不抛异常**）。
///
/// 返回值统一 `toLocal()` —— 原版 `dayjs(...).format(...)` 输出的就是本地时间，
/// 模板里的 `%POST_TIME%` 因此显示用户所在时区的日期。
DateTime? parseTwitterCreatedAt(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;

  // ① 先试 ISO-8601（成本为零；万一某天端点改回这种格式）。
  //    注意：不带时区的 ISO 串会被当成**本地时间**，这是 Dart 的既有语义。
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso.toLocal();

  // ② ctime 布局（X 的真实格式）
  final c = _ctime.firstMatch(s);
  if (c != null) {
    final month = _monthOf(c.group(1)!);
    if (month == null) return null;
    return _build(
      year: int.parse(c.group(7)!),
      month: month,
      day: int.parse(c.group(2)!),
      hour: int.parse(c.group(3)!),
      minute: int.parse(c.group(4)!),
      second: int.tryParse(c.group(5) ?? '') ?? 0,
      tzRaw: c.group(6)!,
    );
  }

  // ③ 标准 RFC 2822 布局
  final r = _rfc2822.firstMatch(s);
  if (r != null) {
    final month = _monthOf(r.group(2)!);
    if (month == null) return null;
    return _build(
      year: int.parse(r.group(3)!),
      month: month,
      day: int.parse(r.group(1)!),
      hour: int.parse(r.group(4)!),
      minute: int.parse(r.group(5)!),
      second: int.tryParse(r.group(6) ?? '') ?? 0,
      tzRaw: r.group(7)!,
    );
  }

  return null;
}
