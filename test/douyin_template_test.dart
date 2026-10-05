import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/media_variant.dart';
import 'package:parse_dl/services/file_name_template.dart';

/// 16 个抖音文件名变量的格式化测试。
///
/// 期望值按七个格式化函数的**行为口径**手算（见 `file_name_template.dart`）。
/// **唯一的刻意差异**：参照实现用下划线拼接
/// 自动加下划线连接组件，本项目由用户手写 `%A%_%B%`，所以这里变量
/// 只输出值本身、不带前导下划线。
void main() {
  /// 带完整质量属性的变体 —— `%BITRATE%` / `%FPS%` / `%FILE_SIZE%` 读它。
  const chosen = MediaVariant(
    urls: ['https://v11.douyinvod.com/a.mp4'],
    kind: VariantKind.bitRate,
    width: 1920,
    height: 1080,
    fps: 60,
    bitrate: 4000000,
    dataSize: 4194304, // 4 MiB
  );

  Media mk({
    MediaType type = MediaType.video,
    String? userName = '张三',
    String? userId = '111',
    String? userScreenName = 'zhangsan',
    String? tweetText = '作品描述',
    String? tweetId = '7300000000000000001',
    DateTime? createdAt,
    int? width = 1080,
    int? height = 1920,
    int? durationMs = 90000,
    int? likeCount,
    int? commentCount,
    int? collectCount,
    int? shareCount,
    String? customText,
    MediaVariant? withChosen,
  }) =>
      Media(
        id: 'm1',
        type: type,
        url: 'https://x/a.mp4',
        source: 'douyin',
        userName: userName,
        userId: userId,
        userScreenName: userScreenName,
        tweetText: tweetText,
        tweetId: tweetId,
        createdAt: createdAt,
        width: width,
        height: height,
        durationMs: durationMs,
        likeCount: likeCount,
        commentCount: commentCount,
        collectCount: collectCount,
        shareCount: shareCount,
        customText: customText,
        chosen: withChosen,
      );

  group('formatDurationSeconds', () {
    test('小于 60 秒只有秒', () {
      expect(formatDurationSeconds(0), '0s');
      expect(formatDurationSeconds(-5), '0s');
      expect(formatDurationSeconds(1), '1s');
      expect(formatDurationSeconds(45), '45s');
      expect(formatDurationSeconds(59), '59s');
    });

    test('分钟档：中间为 0 的位省略', () {
      expect(formatDurationSeconds(60), '1m');
      expect(formatDurationSeconds(90), '1m30s');
      expect(formatDurationSeconds(120), '2m');
      expect(formatDurationSeconds(3599), '59m59s');
    });

    test('小时档：为 0 的位一律省略', () {
      expect(formatDurationSeconds(3600), '1h');
      expect(formatDurationSeconds(3661), '1h1m1s');
      expect(formatDurationSeconds(7200), '2h');
      expect(formatDurationSeconds(7380), '2h3m');
      expect(formatDurationSeconds(7325), '2h2m5s');
    });

    test('%DURATION% 走的是毫秒取整秒', () {
      expect(resolveVariables('%DURATION%', mk(durationMs: 90000)), '1m30s');
      expect(resolveVariables('%DURATION%', mk(durationMs: 1500)), '1s');
      expect(resolveVariables('%DURATION%', mk(durationMs: null)), '0s');
    });
  });

  group('formatFileSize', () {
    test('大于 1MB 取整，否则保留一位小数', () {
      expect(formatFileSize(524288), '0.5MB');
      expect(formatFileSize(1048576), '1.0MB');
      expect(formatFileSize(2097152), '2MB');
      expect(formatFileSize(10485760), '10MB');
    });

    test('0 / 负数出空串（不是 0MB）', () {
      expect(formatFileSize(0), '');
      expect(formatFileSize(-1), '');
    });

    test('%FILE_SIZE% 读 chosen 的 data_size', () {
      expect(resolveVariables('%FILE_SIZE%', mk(withChosen: chosen)), '4MB');
      expect(resolveVariables('%FILE_SIZE%', mk()), '',
          reason: '还没挑源 / 变体没带 data_size 时不给数字');
    });
  });

  group('formatStatCount', () {
    test('空 / 0 → 0', () {
      expect(formatStatCount(null), '0');
      expect(formatStatCount(0), '0');
    });

    test('上限截断到 9999999+', () {
      expect(formatStatCount(1), '1');
      expect(formatStatCount(9999999), '9999999');
      expect(formatStatCount(10000000), '9999999+');
      expect(formatStatCount(999999999), '9999999+');
    });

    test('四个统计变量各带自己的单位后缀', () {
      final m = mk(likeCount: 100, commentCount: 5, collectCount: 7, shareCount: 3);
      expect(resolveVariables('%LIKE_COUNT%', m), '100点赞');
      expect(resolveVariables('%COMMENT_COUNT%', m), '5评论');
      expect(resolveVariables('%COLLECT_COUNT%', m), '7收藏');
      expect(resolveVariables('%SHARE_COUNT%', m), '3分享');
    });

    test('统计缺失时输出 0 + 单位（不是空串）', () {
      final m = mk();
      expect(resolveVariables('%LIKE_COUNT%', m), '0点赞');
      expect(resolveVariables('%SHARE_COUNT%', m), '0分享');
    });
  });

  group('formatCreateTime', () {
    test('YYYYMMDDHHmmss，本地时区、无分隔符', () {
      expect(
        formatCreateTime(DateTime(2023, 11, 15, 6, 13, 20)),
        '20231115061320',
      );
      expect(formatCreateTime(DateTime(2024, 1, 2, 3, 4, 5)), '20240102030405');
    });

    test('月日时分秒都补零', () {
      expect(
        formatCreateTime(DateTime(2024, 1, 2, 3, 4, 5)),
        '20240102030405',
      );
    });

    test('d=1 只留日期 —— 抖音侧「按日期分文件夹」用它，不用 X 的 %POST_TIME%', () {
      expect(
        formatCreateTime(DateTime(2023, 11, 15, 6, 13, 20), dateOnly: true),
        '20231115',
      );
      final m = mk(createdAt: DateTime(2023, 11, 15, 6, 13, 20));
      expect(resolveVariables('%CREATE_TIME,d=1%', m), '20231115');
      // 不传参数时仍是完整时间戳
      expect(resolveVariables('%CREATE_TIME%', m), '20231115061320');
    });

    test('时间缺失出空串（与 %POST_TIME% 的「未知日期」不同）', () {
      expect(formatCreateTime(null), '');
      expect(resolveVariables('%CREATE_TIME%', mk()), '');
      // 对照：同一个缺失时间，%POST_TIME% 仍是「未知日期」
      expect(resolveVariables('%POST_TIME%', mk()), '未知日期');
    });
  });

  group('resolutionText', () {
    test('优先用 chosen 的宽高', () {
      expect(resolutionText(mk(withChosen: chosen)), '1920x1080');
    });

    test('没有 chosen 时退回 Media.width/height', () {
      expect(resolutionText(mk(width: 720, height: 1280)), '720x1280');
    });

    test('宽高缺一不可，否则空串', () {
      expect(resolutionText(mk(width: 0, height: 1280)), '');
      expect(resolutionText(mk(width: 720, height: 0)), '');
      expect(resolutionText(mk(width: null, height: null)), '');
      expect(resolveVariables('%RESOLUTION%', mk(width: null, height: null)), '');
    });
  });

  group('比特率 / 帧率', () {
    test('%BITRATE% = round(bps/1000) + Kbps', () {
      expect(resolveVariables('%BITRATE%', mk(withChosen: chosen)), '4000Kbps');
    });

    test('%FPS% = 帧率 + fps', () {
      expect(resolveVariables('%FPS%', mk(withChosen: chosen)), '60fps');
    });

    test('取不到时出空串而不是 0（避免文件名里出现无意义的 0Kbps）', () {
      expect(resolveVariables('%BITRATE%', mk()), '');
      expect(resolveVariables('%FPS%', mk()), '');
    });
  });

  group('作者 / 描述 / 自定义文本', () {
    test('%AUTHOR% = @昵称，缺昵称回落 unknown_author', () {
      expect(resolveVariables('%AUTHOR%', mk(userName: '张三')), '@张三');
      expect(resolveVariables('%AUTHOR%', mk(userName: null)), '@unknown_author');
      expect(resolveVariables('%AUTHOR%', mk(userName: '')), '@unknown_author');
    });

    test('%AUTHOR_ID% 是数字 uid，%AUTHOR_UNIQUE_ID% 是抖音号', () {
      final m = mk(userId: '111', userScreenName: 'zhangsan');
      expect(resolveVariables('%AUTHOR_ID%', m), '111');
      expect(resolveVariables('%AUTHOR_UNIQUE_ID%', m), 'zhangsan');
      // 与 X 侧的 USER_ID / USER_SCREEN_NAME 同源
      expect(resolveVariables('%USER_ID%', m), '111');
      expect(resolveVariables('%USER_SCREEN_NAME%', m), 'zhangsan');
    });

    test('%AWEME_ID% 与 %POST_ID% 同源（都是 aweme_id）', () {
      final m = mk(tweetId: '7300000000000000001');
      expect(resolveVariables('%AWEME_ID%', m), '7300000000000000001');
      expect(resolveVariables('%POST_ID%', m), '7300000000000000001');
    });

    test('%CUSTOM_TEXT% 原样输出设置里的自定义文本', () {
      expect(resolveVariables('%CUSTOM_TEXT%', mk(customText: '我的后缀')), '我的后缀');
      expect(resolveVariables('%CUSTOM_TEXT%', mk()), '');
    });

    test('%DESCRIPTION% 默认截 25 字符，params 被 clamp 到 1~120', () {
      final m = mk(tweetText: '一二三四五六七八九十');
      expect(resolveVariables('%DESCRIPTION%', m), '一二三四五六七八九十');
      expect(resolveVariables('%DESCRIPTION,t=3%', m), '一二三...');
      expect(resolveVariables('%DESCRIPTION,t=120%', m), '一二三四五六七八九十');
      expect(resolveVariables('%DESCRIPTION,t=1000%', m), '一二三四五六七八九十');
      expect(resolveVariables('%DESCRIPTION,t=abc%', m), '一二三四五六七八九十');
      // 描述为空时拿作品 id 兜底，不留空
      expect(resolveVariables('%DESCRIPTION%', mk(tweetText: '')),
          '7300000000000000001');
      expect(resolveVariables('%DESCRIPTION%', mk(tweetText: null)),
          '7300000000000000001');
    });

    test('%DESCRIPTION% 超过默认 25 字符时截断并加 ...', () {
      final long = mk(tweetText: '一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十');
      final out = resolveVariables('%DESCRIPTION%', long);
      expect(out, '一二三四五六七八九十一二三四五六七八九十一二三四五...');
      expect(out.runes.length, 28, reason: '25 个字符 + 3 个点');
    });
  });

  group('组合模板', () {
    test('默认模板的完整命名一眼可读', () {
      final m = mk(
        userName: '张三',
        createdAt: DateTime(2023, 11, 15, 6, 13, 20),
        likeCount: 100,
        withChosen: chosen,
        customText: '收藏版',
      );
      expect(
        resolveVariables(
          '%AUTHOR%_%CREATE_TIME%_%DESCRIPTION%_%RESOLUTION%_%CUSTOM_TEXT%',
          m,
        ),
        '@张三_20231115061320_作品描述_1920x1080_收藏版',
      );
    });

    test('变量值里的非法字符照样被净化', () {
      final m = mk(userName: r'a<b>c:d');
      expect(resolveVariables('%AUTHOR%', m), '@a!b!c!d');
    });
  });
}
