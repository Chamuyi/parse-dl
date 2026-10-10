import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/file_name_template.dart';

/// 模板引擎的可选段 `<...>`（B 站模块的前置能力）。
///
/// 判空口径必须看**变量的原始值**：参照实现里单 P 作品的 P 号原始值是 `0`、
/// 渲染出来是 `"00"`，按文本判空就漏掉，结果所有单 P 作品都多出一个 `P00`。
void main() {
  final m = xExampleMedia();
  final bare = Media(
    id: '1',
    type: MediaType.image,
    url: 'https://pbs.twimg.com/media/x.jpg',
  );

  group('可选段基本行为', () {
    test('段内变量有值 → 整段保留并展开', () {
      expect(resolveVariables('<@%USER_NAME%>x', m), '${'@这是用户昵称'}x');
    });

    test('段内变量为空 → 整段连字面字符一起丢弃', () {
      // bare 没有 userName → `<@%USER_NAME%>` 整段消失，段外的 `x` 保留
      expect(resolveVariables('<@%USER_NAME%>x', bare), 'x');
    });

    test('段内多个变量，任一为空就整段丢', () {
      final noTags = Media(
        id: '1',
        type: MediaType.image,
        url: 'https://pbs.twimg.com/media/x.jpg',
        userName: '有昵称',
      );
      expect(resolveVariables('<%USER_NAME%-%TAGS%>x', noTags), 'x');
    });

    test('段外的字面字符不受影响', () {
      expect(resolveVariables('a<%USER_NAME%>b', bare), 'ab');
      expect(resolveVariables('a<%USER_NAME%>b', m), 'a${m.userName}b');
    });
  });

  group('可选段只扫模板，不扫注入结果', () {
    test('变量值里的尖括号不会被当成可选段吞掉', () {
      // perVar 传恒等（抖音侧那条路径就是如此），值里的 `<b>` 会原样留在文本里。
      // 若实现成"先展开再找尖括号"，这里会被吃掉一段。
      final evil = xExampleMedia().copyWith(userName: r'a<b>c:d"e/f\g|h?i*j');
      expect(
        resolveVariables('%USER_NAME%<%POST_ID%>', evil, perVar: (s) => s),
        'a<b>c:d"e/f\\g|h?i*j${evil.tweetId}',
      );
    });

    test('X 侧净化后同样正确（非法字符换 !）', () {
      final evil = xExampleMedia().copyWith(userName: r'a<b>c');
      expect(
        resolveVariables('<%POST_ID%>-%USER_NAME%', evil),
        '${evil.tweetId}-a!b!c',
      );
    });

    test('不成对的尖括号原样保留', () {
      expect(resolveVariables('a<b', m, perVar: (s) => s), 'a<b');
      expect(resolveVariables('x>y', m, perVar: (s) => s), 'x>y');
    });
  });

  group('没有可选段时行为与改动前一致', () {
    test('X 默认文件名模板', () {
      expect(
        resolveVariables(
          '%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%',
          m,
        ),
        '2024-01-20 21-15-36 userscreenname 1145141919810-1.jpg',
      );
    });

    test('抖音默认文件名模板（整串清洗路径）', () {
      expect(
        resolveDouyinFileName(
          '%AUTHOR%_%CREATE_TIME,d=1%_%DESCRIPTION%%IMAGE_INDEX%%EXT%',
          douyinExampleMedia(),
        ),
        isNotEmpty,
      );
    });
  });
}
