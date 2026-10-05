import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/douyin_interceptor_js.dart';

/// 抖音**识别端点白名单**的规格测试。
///
/// 2026-09-18 之前是「URL 里含 /aweme/v1/web/ 就抄」，于是搜索、用户资料、
/// 播放统计这些接口也一并进来，右侧列表混进用户根本没在页面上见过的作品。
/// 现在逐条列出注入脚本监听的端点。
///
/// 规则表只存在于注入脚本里（JS），这里**把它解析出来再验** —— 而不是在测试里
/// 抄一份，否则两边各改各的、测试永远绿。
class _Rule {
  _Rule(this.pattern, this.kind);
  final String pattern;
  final String kind;

  /// JS 正则字面量 `/xxx/flags` → 模式串与大小写选项
  RegExp get regex {
    final body = pattern.substring(1, pattern.lastIndexOf('/'));
    final flags = pattern.substring(pattern.lastIndexOf('/') + 1);
    return RegExp(body, caseSensitive: !flags.contains('i'));
  }
}

/// 从脚本正文里抽出 WATCH_RULES 数组。
///
/// 注意这里**不能用 expect**：它在测试用例之外求值，会抛 OutsideTestException。
List<_Rule> _parseWatchRules(String src) {
  final start = src.indexOf('var WATCH_RULES = [');
  if (start < 0) throw StateError('注入脚本里找不到 WATCH_RULES');
  final end = src.indexOf('];', start);
  final block = src.substring(start, end);
  final found = RegExp(r"re:\s*(\/[^\n]+?\/[a-z]*),\s*kind:\s*'([a-z]+)'")
      .allMatches(block)
      .map((m) => _Rule(m.group(1)!, m.group(2)!))
      .toList();
  if (found.isEmpty) throw StateError('WATCH_RULES 里一条规则都没解析出来');
  return found;
}

/// 复刻 JS 侧 watchKindOf：取 pathname 后逐条匹配
String? _kindOf(List<_Rule> rules, String url) {
  final uri = Uri.parse(url);
  final path = uri.path;
  for (final r in rules) {
    if (r.regex.hasMatch(path)) return r.kind;
  }
  return null;
}

void main() {
  final rules = _parseWatchRules(kDouyinInterceptorJs);

  group('端点白名单本身', () {
    test('共 13 条端点', () {
      expect(rules, hasLength(13));
      expect(rules.map((r) => r.kind).toSet(),
          {'feed', 'profile', 'detail', 'list', 'comment'});
    });

    test('不再有任何"整段前缀放行"的宽匹配', () {
      // 形如 ^\/aweme\/v1\/web\/\/*$ 这种会把所有端点收进来的写法
      for (final r in rules) {
        expect(r.pattern, isNot(matches(r'^/\/aweme\\/v[12]\\/web\\/\*\$')),
            reason: '${r.pattern} 退化成前缀匹配了');
      }
      expect(kDouyinInterceptorJs,
          isNot(contains("url.indexOf('/aweme/v1/web/')")),
          reason: '旧的前缀放行逻辑应该已经删干净');
    });
  });

  group('该收的端点', () {
    test('feed 类：推荐流 / 关注流 / 精选模块流 /  Familiar 推荐', () {
      for (final u in [
        'https://www.douyin.com/aweme/v1/web/tab/feed/?device_platform=webapp',
        'https://www.douyin.com/aweme/v1/web/follow/feed/?a=1',
        'https://www.douyin.com/aweme/v1/web/module/feed/?b=2',
        'https://www.douyin.com/aweme/v2/web/module/feed/?b=2',
        'https://www.douyin.com/aweme/v1/web/familiar/recommend/feed/',
      ]) {
        expect(_kindOf(rules, u), 'feed', reason: u);
      }
    });

    test('profile 类：作者作品 / 喜欢 / 合集列表 / 收藏视频', () {
      for (final u in [
        'https://www.douyin.com/aweme/v1/web/aweme/post/?sec_uid=x&cursor=0',
        'https://www.douyin.com/aweme/v1/web/aweme/favorite/?cursor=60',
        'https://www.douyin.com/aweme/v1/web/aweme/listcollection/',
        'https://www.douyin.com/aweme/v1/web/collects/video/list/',
      ]) {
        expect(_kindOf(rules, u), 'profile', reason: u);
      }
    });

    test('detail 与 list 类', () {
      expect(
        _kindOf(rules, 'https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=1'),
        'detail',
      );
      expect(_kindOf(rules, 'https://www.douyin.com/aweme/v1/web/mix/aweme/'), 'list');
      expect(_kindOf(rules, 'https://www.douyin.com/aweme/v1/web/series/aweme/'), 'list');
      expect(_kindOf(rules, 'https://www.douyin.com/aweme/v1/web/collects/list/'), 'list');
      expect(
        _kindOf(rules, 'https://www.douyin.com/aweme/v1/web/music/listcollection/'),
        'list',
      );
      expect(
        _kindOf(rules,
            'https://www.douyin.com/aweme/v1/web/douyin/select/tab/course/catagory/video/'),
        'list',
      );
    });
  });

  group('不该收的端点（旧前缀匹配会误收）', () {
    test('搜索 / 用户资料 / 统计 / 任务 / 消息 一律不收', () {
      for (final u in [
        'https://www.douyin.com/aweme/v1/web/general/search/single/?kw=x',
        'https://www.douyin.com/aweme/v1/web/user/profile/other/?sec_uid=x',
        'https://www.douyin.com/aweme/v1/web/aweme/stats/?aweme_id=1',
        'https://www.douyin.com/aweme/v1/web/task/list/',
        'https://www.douyin.com/aweme/v1/web/im/user/info/',
        'https://www.douyin.com/aweme/v1/web/query/user/',
      ]) {
        expect(_kindOf(rules, u), isNull, reason: '$u 不该进白名单');
      }
    });

    test('非抖音域名上同名路径也不收', () {
      expect(
        _kindOf(rules, 'https://evil.example.com/aweme/v1/web/tab/feed/'),
        'feed',
        reason: '白名单只匹配 pathname —— 域名过滤在 shouldWatch 之外，'
            '这里记录当前行为：注入脚本本身只跑在抖音页面里',
      );
    });
  });

  group('评论引用', () {
    test('comment/list 被登记为 comment 类（已知噪声源）', () {
      expect(
        _kindOf(rules, 'https://www.douyin.com/aweme/v1/web/comment/list/?aweme_id=1'),
        'comment',
      );
    });
  });
}
