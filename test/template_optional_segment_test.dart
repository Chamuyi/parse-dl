import 'dart:convert';

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

  group('全路径 260 保护', () {
    const dir = r'D:\demo\dl\把一年的海边拍成十二段';

    test('放得下时原名一字不动', () {
      final name = 'P03-第3P 冬天-1080P60-AV1.mp4';
      expect(clampNameForFullPath(dir, name), name);
      expect(pathFitsWindowsMax(dir, name), isTrue);
    });

    test('超出时只裁文件名，扩展名保住', () {
      final long = '${'标' * 300}.mp4';
      final out = clampNameForFullPath(dir, long);
      expect(out.endsWith('.mp4'), isTrue);
      expect(out.length, lessThan(long.length));
      expect(pathFitsWindowsMax(dir, out), isTrue);
    });

    test('计数按 UTF-16 码元，不是 UTF-8 字节（中文不按字节多砍）', () {
      // 250 个汉字 = 750 字节，但 Windows 计 250 个码元；配合这个目录刚好放得下
      final cjk = '${'汉' * 200}.mp4';
      final dir2 = r'D:\demo\dl';
      expect(pathFitsWindowsMax(dir2, cjk), isTrue);
      expect(utf8.encode(cjk).length, greaterThan(260), reason: '字节数早就超了');
      expect(clampNameForFullPath(dir2, cjk), cjk);
    });

    test('不把代理对切成半个（emoji 结尾不能留下高代理）', () {
      // 目录 4 个码元 → 名字预算 260-8-4-1=247，去掉 `.mp4` 后主体剩 243。
      // 故意把 emoji 摆在第 243/244 码元上：不处理就会留下半个高代理。
      final withEmoji = '${'x' * 242}\u{1F600}.mp4';
      final out = clampNameForFullPath(r'D:\d', withEmoji);
      expect(out.length, lessThanOrEqualTo(247));
      // 关键判据：结果里不许有落单的高代理
      for (var i = 0; i < out.length; i++) {
        final u = out.codeUnitAt(i);
        if (u >= 0xD800 && u <= 0xDBFF) {
          expect(out.codeUnitAt(i + 1) >= 0xDC00 && out.codeUnitAt(i + 1) <= 0xDFFF,
              isTrue,
              reason: '位置 $i 留下半个代理对：${out.codeUnits}');
        }
      }
    });

    test('开头的点不算扩展名（`.gitignore` 式名字整串都是主体）', () {
      final dotted = '.${'x' * 300}';
      final out = clampNameForFullPath(r'D:\d', dotted);
      expect(out.startsWith('.'), isTrue);
      expect(out.length, lessThan(dotted.length));
    });

    test('目录本身已经长到放不下时，压到最短并如实报放不下', () {
      final hugeDir = 'D:/${'深' * 250}';
      final out = clampNameForFullPath(hugeDir, 'a.mp4');
      expect(pathFitsWindowsMax(hugeDir, out), isFalse);
      expect(out, isNotEmpty, reason: '不能交回空名字，aria2 的 out: 没有二次补救机会');
    });

    test('留了余量：正好 260 也算放不下（要给 .aria2 与控制文件腾地方）', () {
      final name = '${'x' * (260 - 1 - r'D:\demo'.length)}.mp4';
      expect(pathFitsWindowsMax(r'D:\demo', name), isFalse);
    });
  });
}
