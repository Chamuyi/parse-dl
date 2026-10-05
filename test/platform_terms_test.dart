import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/file_name_template.dart';

/// **术语边界**回归测试。
///
/// 需求原话：「变量命名需与抖音业务语义一致，禁止出现"x 里面的推文"这类与 X
/// 平台相关的内容或表述。X 模块中同样禁止出现"抖音"这类与 X 平台不相关内容
/// 或表述。」
///
/// 也就是两个模块的**术语不能串门**：
///   * X 下载设置里不能出现「作品 / 作者 / 抖音号」这类抖音说法；
///   * 抖音解析下载设置里不能出现「推文 / 用户名 / 转推」这类 X 说法。
///
/// 这里把这条规则钉成测试：以后往任一变量表里加东西，串了术语就会红。
void main() {
  /// 抖音特有的变量名（出现在 X 表里就是串了）
  const douyinOnly = {
    'AUTHOR',
    'AUTHOR_ID',
    'AUTHOR_UNIQUE_ID',
    'CREATE_TIME',
    'DESCRIPTION',
    'AWEME_ID',
    'CUSTOM_TEXT',
    'RESOLUTION',
    'BITRATE',
    'FPS',
    'DURATION',
    'FILE_SIZE',
    'LIKE_COUNT',
    'COMMENT_COUNT',
    'COLLECT_COUNT',
    'SHARE_COUNT',
  };

  /// X 特有的变量名（出现在抖音表里就是串了）
  const xOnly = {
    'POST_ID',
    'POST_TIME',
    'USER_ID',
    'USER_NAME',
    'USER_SCREEN_NAME',
    'MEDIA_ID',
    'MEDIA_WIDTH',
    'MEDIA_HEIGHT',
    'CONTENT',
    'TAGS',
  };

  group('变量名不跨平台', () {
    test('X 变量表里没有任何抖音专有变量', () {
      final names = kXTemplateVars.map((v) => v.name).toSet();
      final leaked = names.intersection(douyinOnly);
      expect(leaked, isEmpty, reason: 'X 设置里不该出现这些：$leaked');
    });

    test('抖音变量表里没有任何 X 专有变量', () {
      final names = kDouyinTemplateVars.map((v) => v.name).toSet();
      final leaked = names.intersection(xOnly);
      expect(leaked, isEmpty, reason: '抖音设置里不该出现这些：$leaked');
    });

    test('共用的三个变量两边都有', () {
      final x = kXTemplateVars.map((v) => v.name).toSet();
      final d = kDouyinTemplateVars.map((v) => v.name).toSet();
      for (final n in kCommonVarNames) {
        expect(x, contains(n), reason: '$n 应在 X 变量表里');
        expect(d, contains(n), reason: '$n 应在抖音变量表里');
      }
    });

    test('两张表各取所需，且都是全集的子集', () {
      final all = kAllTemplateVars.map((v) => v.name).toSet();
      final x = kXTemplateVars.map((v) => v.name).toSet();
      final d = kDouyinTemplateVars.map((v) => v.name).toSet();

      expect(all.containsAll(x), isTrue);
      expect(all.containsAll(d), isTrue);
      // 抖音表 17 个专有 + 3 个共用 = 20；X 表 10 个专有 + 3 个共用 = 13
      expect(d.length, 20);
      expect(x.length, 13);
      // SOURCE 是唯一「只存在于全集、两边都不展示」的变量
      expect(all.contains('SOURCE'), isTrue);
      expect(x.contains('SOURCE'), isFalse);
      expect(d.contains('SOURCE'), isFalse);
    });
  });

  group('变量描述文字里没有对方的术语', () {
    /// X 侧不该出现的词
    const douyinWords = ['抖音', 'douyin', '作品', '作者', 'aweme'];

    /// 抖音侧不该出现的词
    const xWords = ['推文', '帖子', 'tweet', '转推'];

    test('X 变量表的描述不含抖音说法', () {
      for (final v in kXTemplateVars) {
        final text =
            '${v.name} ${v.desc} '
            '${v.params.map((p) => p.desc).join(' ')}';
        for (final w in douyinWords) {
          expect(
            text.toLowerCase().contains(w.toLowerCase()),
            isFalse,
            reason: 'X 变量 ${v.name} 的描述里出现了「$w」：${v.desc}',
          );
        }
      }
    });

    test('抖音变量表的描述不含 X 说法', () {
      for (final v in kDouyinTemplateVars) {
        final text =
            '${v.name} ${v.desc} '
            '${v.params.map((p) => p.desc).join(' ')}';
        for (final w in xWords) {
          expect(
            text.toLowerCase().contains(w.toLowerCase()),
            isFalse,
            reason: '抖音变量 ${v.name} 的描述里出现了「$w」：${v.desc}',
          );
        }
      }
    });

    test('X 变量表里不能有描述提到另一个平台的 SOURCE', () {
      // SOURCE 的取值就是平台标识，列出来会让 X 设置里冒出别的平台字样，
      // 所以它只留在全集里供解析用，不进任何一张展示表。
      expect(kXTemplateVars.map((v) => v.name), isNot(contains('SOURCE')));
      expect(kDouyinTemplateVars.map((v) => v.name), isNot(contains('SOURCE')));
      expect(kAllTemplateVars.map((v) => v.name), contains('SOURCE'));
    });
  });

  group('示例媒体也是两套', () {
    test('X 的示例媒体用推文语境，source 是 x', () {
      final m = xExampleMedia();
      expect(m.source, 'x');
      expect(m.tweetText, contains('推文'));
      expect(m.tags, isNotEmpty);
    });

    test('抖音的示例媒体用作品语境，不含推文说法', () {
      final m = douyinExampleMedia();
      expect(m.source, 'douyin');
      expect(m.tweetText, isNot(contains('推文')));
      // 抖音侧的样例要能让抖音专有变量都有值
      expect(m.userName, isNotNull, reason: '%AUTHOR% 需要作者昵称');
      expect(m.userScreenName, isNotNull, reason: '%AUTHOR_UNIQUE_ID% 需要抖音号');
      expect(m.tweetId, isNotNull, reason: '%AWEME_ID% 需要作品 ID');
      expect(m.durationMs, isNotNull, reason: '%DURATION% 需要时长');
      expect(m.likeCount, isNotNull, reason: '%LIKE_COUNT% 需要点赞数');
      expect(m.chosen, isNotNull, reason: '%RESOLUTION% / %BITRATE% 需要选中的码率');
      // 竖屏更贴近抖音的实际内容
      expect(m.width! < m.height!, isTrue, reason: '抖音示例用竖屏');
    });

    test('抖音示例媒体把 16 个专有变量都填出非空值', () {
      final m = douyinExampleMedia();
      final out = <String, String>{};
      for (final v in kDouyinTemplateVars) {
        out[v.name] = resolveVariables('%${v.name}%', m);
      }
      // 这几个依赖「下载时按设置选源」的结果，示例里已给 chosen，应当有值
      for (final n in [
        'AUTHOR',
        'AUTHOR_ID',
        'AUTHOR_UNIQUE_ID',
        'CREATE_TIME',
        'DESCRIPTION',
        'AWEME_ID',
        'RESOLUTION',
        'BITRATE',
        'FPS',
        'DURATION',
        'FILE_SIZE',
        'LIKE_COUNT',
        'COMMENT_COUNT',
        'COLLECT_COUNT',
        'SHARE_COUNT',
      ]) {
        expect(out[n], isNotNull, reason: '$n 没解析出来');
        expect(out[n]!.isNotEmpty, isTrue, reason: '$n 解析成了空串');
      }
    });
  });

  group('解析用全集', () {
    test('跨平台变量都能解析（旧模板不会留残字）', () {
      final m = douyinExampleMedia();
      // 同时含 X 变量和抖音变量 —— 这种模板不该出现「%XXX% 原样保留」
      final out = resolveVariables('%POST_ID%_%AWEME_ID%_%EXT%', m);
      expect(out, isNot(contains('%')));
    });

    test('两个平台的示例媒体互不干扰', () {
      final x = xExampleMedia();
      final d = douyinExampleMedia();
      expect(
        resolveVariables('%DESCRIPTION%', x),
        isNot(equals(resolveVariables('%DESCRIPTION%', d))),
        reason: '两份样例的描述文字应当不同',
      );
    });
  });
}
