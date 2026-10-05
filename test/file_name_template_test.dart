import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/file_name_template.dart';

/// 期望值对齐原版 X-Spider 的示例数据（`constants/file-name-template.ts`
/// 里的 EXAMPLE_USER / EXAMPLE_POST / EXAMPLE_MEDIA）。
void main() {
  final m = xExampleMedia();

  group('resolveVariables 基本替换', () {
    test('默认文件名模板（原版默认值）', () {
      final out = resolveVariables(
        '%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%',
        m,
      );
      expect(out, '2024-01-20 21-15-36 userscreenname 1145141919810-1.jpg');
    });

    test('原版文档里的示例模板', () {
      final out = resolveVariables(
        '%POST_TIME%_%USER_NAME%_%USER_SCREEN_NAME%_%CONTENT%_%EXT%',
        m,
      );
      expect(
        out,
        '2024-01-20 21-15-36_这是用户昵称_userscreenname_'
        '这里是推文内容,这里是推文内容，这里是推文内容，这里是推文内容，_.jpg',
      );
    });

    test('文件夹模板里的 / 保留为路径分隔符', () {
      expect(
        resolveVariables('%USER_SCREEN_NAME%/%POST_ID%', m),
        'userscreenname/1145141919810',
      );
    });

    test('未知变量原样保留', () {
      expect(resolveVariables('%NOPE%', m), '%NOPE%');
      // 大小写不敏感
      expect(resolveVariables('%post_id%', m), '1145141919810');
      expect(resolveVariables('%Post_Id%', m), '1145141919810');
    });

    test('空模板返回空串', () {
      expect(resolveVariables('', m), '');
    });
  });

  group('带参数的变量', () {
    test('%POST_TIME,d=1% 只保留日期', () {
      expect(resolveVariables('%POST_TIME,d=1%', m), '2024-01-20');
      expect(resolveVariables('%POST_TIME,d=0%', m), '2024-01-20 21-15-36');
    });

    test('%CONTENT,t=N% 按字符数截断', () {
      expect(resolveVariables('%CONTENT,t=4%', m), '这里是推');
      expect(resolveVariables('%CONTENT,t=1%', m), '这');
    });

    test('%CONTENT% 不带参数时默认截断 32 字符（与原版代码行为一致）', () {
      final out = resolveVariables('%CONTENT%', m);
      expect(out.runes.length, 32);
      expect(out, m.tweetText!.substring(0, 32));
    });

    test('%CONTENT,t=0% 截出空串', () {
      expect(resolveVariables('%CONTENT,t=0%', m), '');
    });

    test('参数非法时回退默认值', () {
      expect(resolveVariables('%CONTENT,t=abc%', m).runes.length, 32);
    });
  });

  group('各变量取值', () {
    test('POST_ID / MEDIA_* / USER_*', () {
      expect(resolveVariables('%POST_ID%', m), '1145141919810');
      expect(resolveVariables('%MEDIA_ID%', m), '1234567890123456789');
      expect(resolveVariables('%MEDIA_WIDTH%', m), '1323');
      expect(resolveVariables('%MEDIA_HEIGHT%', m), '1136');
      expect(resolveVariables('%MEDIA_INDEX%', m), '1');
      expect(resolveVariables('%USER_ID%', m), '1145141919');
      expect(resolveVariables('%USER_NAME%', m), '这是用户昵称');
      expect(resolveVariables('%USER_SCREEN_NAME%', m), 'userscreenname');
    });

    test('EXT 从下载链接里取（图片已补 ?name=orig）', () {
      expect(m.downloadUrl, 'https://pbs.twimg.com/media/EXAMPLEid01.jpg?name=orig');
      expect(resolveVariables('%EXT%', m), '.jpg');
    });

    test('MEDIA_TYPE 用原版字面量 photo / video / animated_gif', () {
      expect(resolveVariables('%MEDIA_TYPE%', m), 'photo');
      expect(MediaType.video.id, 'video');
      expect(MediaType.animatedGif.id, 'animated_gif');
    });

    test('TAGS 用逗号连接', () {
      expect(resolveVariables('%TAGS%', m), '标签1,标签2');
    });

    test('缺字段时出空串而不是 null', () {
      final bare = Media(
        id: '1',
        type: MediaType.image,
        url: 'https://pbs.twimg.com/media/x.jpg',
      );
      expect(resolveVariables('%USER_NAME%', bare), '');
      expect(resolveVariables('%POST_TIME%', bare), '未知日期');
      expect(resolveVariables('%CONTENT%', bare), '');
      expect(resolveVariables('%TAGS%', bare), '');
    });
  });

  group('文件名净化', () {
    test('Windows 非法字符替换成 !', () {
      final evil = xExampleMedia().copyWith(userName: r'a<b>c:d"e/f\g|h?i*j');
      expect(resolveVariables('%USER_NAME%', evil), 'a!b!c!d!e!f!g!h!i!j');
    });

    test('保留名加叹号避免与设备名冲突', () {
      expect(unicodeFilenamify('con'), 'con!');
      expect(unicodeFilenamify('NUL'), 'NUL!');
      expect(unicodeFilenamify('lpt1'), 'lpt1!');
      expect(unicodeFilenamify('console'), 'console');
    });

    test('冒号被净化 —— 所以 POST_TIME 用 - 分隔时分秒', () {
      expect(unicodeFilenamify('21:15:36'), '21!15!36');
    });
  });

  group('unicode 感知截断', () {
    test('emoji 代理对不会被切成两半', () {
      const s = '😀😀😀';
      expect(unicodeSubstring(s, 0, 2), '😀😀');
      expect(unicodeSubstring(s, 1, 3), '😀😀');
    });

    test('start == end 时返回空串', () {
      expect(unicodeSubstring('abc', 1, 1), '');
    });

    test('结尾越界不会抛异常', () {
      expect(unicodeSubstring('abc', 0, 99), 'abc');
    });
  });

  group('下载链接', () {
    test('图片补 ?name=orig 拿到原图', () {
      final photo = Media(
        id: '1',
        type: MediaType.image,
        url: 'https://pbs.twimg.com/media/AAA.jpg',
      );
      expect(photo.downloadUrl, 'https://pbs.twimg.com/media/AAA.jpg?name=orig');
    });

    test('已带 name 参数时被覆盖', () {
      final photo = Media(
        id: '1',
        type: MediaType.image,
        url: 'https://pbs.twimg.com/media/AAA.jpg?name=small',
      );
      expect(photo.downloadUrl, 'https://pbs.twimg.com/media/AAA.jpg?name=orig');
    });

    test('视频直链原样返回', () {
      final video = Media(
        id: '1',
        type: MediaType.video,
        url: 'https://video.twimg.com/x/y.mp4',
      );
      expect(video.downloadUrl, 'https://video.twimg.com/x/y.mp4');
    });
  });

  group('文件夹模板拆段', () {
    test('/ 与 \\ 都当分隔符', () {
      expect(parseDirSegments('userscreenname/1145141919810'),
          ['userscreenname', '1145141919810']);
      expect(parseDirSegments(r'userscreenname\1145141919810'),
          ['userscreenname', '1145141919810']);
      expect(parseDirSegments('a//b///c'), ['a', 'b', 'c']);
    });

    test('空段与 . .. 被丢弃（防止跳出保存目录）', () {
      expect(parseDirSegments(''), isEmpty);
      expect(parseDirSegments('  '), isEmpty);
      expect(parseDirSegments('..'), isEmpty);
      expect(parseDirSegments('../../etc'), ['etc']);
      expect(parseDirSegments('./a/./b'), ['a', 'b']);
    });

    test('模板解析后再拆段', () {
      final dir = resolveVariables('%USER_SCREEN_NAME%/%POST_ID%', m);
      expect(parseDirSegments(dir), ['userscreenname', '1145141919810']);
    });
  });

  group('可用变量表', () {
    test('14 个原版变量 + 16 个抖音变量，顺序即替换顺序', () {
      expect(kAllTemplateVars.map((v) => v.name).toList(), [
        // ── 原版 X-Spider 的 14 个 ──
        'POST_ID',
        'POST_TIME',
        'USER_ID',
        'USER_NAME',
        'USER_SCREEN_NAME',
        'MEDIA_ID',
        'MEDIA_WIDTH',
        'MEDIA_HEIGHT',
        'MEDIA_INDEX',
        'CONTENT',
        'MEDIA_TYPE',
        'EXT',
        'TAGS',
        'SOURCE',
        // ── 抖音专有 17 个，顺序 = kDouyinVarNames 的声明顺序 ──
        'AUTHOR',
        'AUTHOR_ID',
        'AUTHOR_UNIQUE_ID',
        'CREATE_TIME',
        'DESCRIPTION',
        'IMAGE_INDEX',
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
      ]);
      expect(kAllTemplateVars, hasLength(31));
    });

    test('只有 POST_TIME / CONTENT / CREATE_TIME / DESCRIPTION 带参数', () {
      final withParams =
          kAllTemplateVars.where((v) => v.params.isNotEmpty).map((v) => v.name);
      expect(withParams, ['POST_TIME', 'CONTENT', 'CREATE_TIME', 'DESCRIPTION']);
    });

    test('变量名不重复（否则模板替换会互相覆盖）', () {
      final names = kAllTemplateVars.map((v) => v.name).toList();
      expect(names.toSet(), hasLength(names.length));
    });

    test('每个变量都有中文说明', () {
      for (final v in kAllTemplateVars) {
        expect(v.desc, isNotEmpty, reason: v.name);
      }
    });
  });
}
