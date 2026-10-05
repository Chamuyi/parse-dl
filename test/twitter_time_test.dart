import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/file_name_template.dart';
import 'package:parse_dl/services/twitter_time.dart';

/// X 的时间字符串是 RFC 2822 风格，**Dart 的 `DateTime.parse` 解析不了**，
/// 直接导致文件名模板的 `%POST_TIME%` 一直输出「未知日期」。这组测试守住这个回归。
void main() {
  group('parseTwitterCreatedAt', () {
    test('X 的标准格式（REST v1.1 与 GraphQL legacy.created_at 都是它）', () {
      final t = parseTwitterCreatedAt('Wed Oct 10 20:19:24 +0000 2018');
      expect(t, isNotNull);
      expect(t!.toUtc(), DateTime.utc(2018, 10, 10, 20, 19, 24));
    });

    test('日是一位数时中间是两个空格（Twitter 用 %e 补位）', () {
      final t = parseTwitterCreatedAt('Wed Dec  1 12:00:00 +0000 2021');
      expect(t!.toUtc(), DateTime.utc(2021, 12, 1, 12, 0, 0));
    });

    test('带非零时区偏移时能还原真实时刻', () {
      expect(
        parseTwitterCreatedAt('Wed Oct 10 20:19:24 +0800 2018')!.toUtc(),
        DateTime.utc(2018, 10, 10, 12, 19, 24),
      );
      expect(
        parseTwitterCreatedAt('Wed Oct 10 12:19:24 -0700 2018')!.toUtc(),
        DateTime.utc(2018, 10, 10, 19, 19, 24),
      );
    });

    test('月份 12 个都能认', () {
      for (final m in ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                       'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']) {
        final t = parseTwitterCreatedAt('Mon $m 5 01:02:03 +0000 2020');
        expect(t, isNotNull, reason: m);
      }
      expect(
        parseTwitterCreatedAt('Sat Feb 5 01:02:03 +0000 2000')!.toUtc(),
        DateTime.utc(2000, 2, 5, 1, 2, 3),
      );
    });

    test('兼容 ISO-8601（万一端点改格式）', () {
      expect(
        parseTwitterCreatedAt('2018-10-10T20:19:24Z')!.toUtc(),
        DateTime.utc(2018, 10, 10, 20, 19, 24),
      );
      // 不带时区的 ISO 串会被 Dart 当成**本地时间**（这是 DateTime.parse 的既有
      // 语义），所以这里跟「本地 DateTime」比较，测试结果不会随时区漂移。
      expect(
        parseTwitterCreatedAt('2018-10-10 20:19:24'),
        DateTime(2018, 10, 10, 20, 19, 24),
      );
    });

    test('标准 RFC 2822 顺序（日 月 年）也能吃下，时区名按 UTC 处理', () {
      final t = parseTwitterCreatedAt('Wed, 10 Oct 2018 20:19:24 GMT');
      expect(t, isNotNull);
      expect(t!.toUtc(), DateTime.utc(2018, 10, 10, 20, 19, 24));
      // 别把「X 的 ctime 顺序」和「RFC 2822 顺序」搞混
      expect(
        parseTwitterCreatedAt('wed, 10 oct 2018 20:19:24 +0800')!.toUtc(),
        DateTime.utc(2018, 10, 10, 12, 19, 24),
      );
    });

    test('无法识别 / 空值一律返回 null，不抛异常', () {
      expect(parseTwitterCreatedAt(null), isNull);
      expect(parseTwitterCreatedAt(''), isNull);
      expect(parseTwitterCreatedAt('   '), isNull);
      expect(parseTwitterCreatedAt('随便什么东西'), isNull);
      expect(parseTwitterCreatedAt('2018'), isNull);
    });
  });

  group('回归：%POST_TIME% 不再输出「未知日期」', () {
    test('真实 X 时间字符串经模板渲染出正确日期', () {
      final m = Media(
        id: '1',
        type: MediaType.image,
        url: 'https://pbs.twimg.com/media/x.jpg',
        tweetId: '1145141919810',
        createdAt: parseTwitterCreatedAt('Sat Jan 20 21:15:36 +0000 2024'),
      );
      expect(m.createdAt, isNotNull);
      // 只校验「不是未知日期」和格式，具体小时数取决于本地时区
      final out = resolveVariables('%POST_TIME%', m);
      expect(out, isNot('未知日期'));
      expect(out, matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}$')));
    });

    test('解析失败时才回退到「未知日期」（与原版一致）', () {
      final m = Media(
        id: '1',
        type: MediaType.image,
        url: 'https://pbs.twimg.com/media/x.jpg',
        createdAt: parseTwitterCreatedAt('garbage'),
      );
      expect(resolveVariables('%POST_TIME%', m), '未知日期');
      expect(resolveVariables('%POST_TIME,d=1%', m), '未知日期');
    });
  });
}
