import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_meta.dart';
import 'package:parse_dl/services/file_name_template.dart';

/// B 站模块加入后的**术语边界**检查（与 `platform_terms_test.dart` 同一套规矩，
/// 那份钉 X ↔ 抖音，这份钉 B 站 ↔ 另两家）。
void main() {
  /// B 站特有的变量名：出现在 X 或抖音的表里就是串了术语。
  const biliOnly = [
    'WORK_TITLE',
    'PART_TITLE',
    'P',
    'PART_TOTAL',
    'BVID',
    'AVID',
    'CID',
    'UP_NAME',
    'UP_MID',
    'QUALITY',
    'CODEC',
  ];

  /// 三家各自的专有变量（用来验证「专有 = 全集里去掉共用」）。
  const douyinOnly = [
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
  ];

  group('B 站变量表不串门', () {
    test('X 表里没有任何 B 站专有变量', () {
      final names = kXTemplateVars.map((v) => v.name).toSet();
      expect(names.intersection(biliOnly.toSet()), isEmpty);
    });

    test('抖音表里没有任何 B 站专有变量', () {
      final names = kDouyinTemplateVars.map((v) => v.name).toSet();
      expect(names.intersection(biliOnly.toSet()), isEmpty);
    });

    test('B 站表里既没有 X 专有、也没有抖音专有变量', () {
      final names = kBiliTemplateVars.map((v) => v.name).toSet();
      const xOnly = [
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
      ];
      // CUSTOM_TEXT / RESOLUTION / DURATION / FILE_SIZE 是刻意共用的文件属性，
      // 剩下 13 个抖音专有项不该出现在 B 站设置里。
      const sharedWithBili = {
        'CUSTOM_TEXT',
        'RESOLUTION',
        'DURATION',
        'FILE_SIZE',
      };
      final leakedDy = names
          .intersection(douyinOnly.toSet())
          .difference(sharedWithBili);
      expect(leakedDy, isEmpty, reason: 'B 站设置里不该出现这些：$leakedDy');
      expect(names.intersection(xOnly.toSet()), isEmpty);
    });

    test('B 站 11 个专有变量全部进了表，且都在全集里', () {
      final names = kBiliTemplateVars.map((v) => v.name).toSet();
      final all = kAllTemplateVars.map((v) => v.name).toSet();
      for (final n in biliOnly) {
        expect(names, contains(n), reason: '$n 应当在 B 站变量表里');
        expect(all, contains(n), reason: '$n 应当能参与解析');
      }
      expect(names.length, 18); // 11 专有 + 4 文件属性 + 3 共用
      // SOURCE 只留在全集供解析，不进任何展示表
      expect(names.contains('SOURCE'), isFalse);
    });

    test('B 站表的描述里没有 X 与抖音的说法', () {
      // 「作品」两家都说，所以它不在禁列里；这里钉的是真正的专有术语。
      const forbidden = ['推文', '帖子', 'tweet', '转推', '抖音', 'douyin', 'aweme'];
      for (final v in kBiliTemplateVars) {
        final text =
            '${v.name} ${v.desc} ${v.params.map((p) => p.desc).join(' ')}'
                .toLowerCase();
        for (final w in forbidden) {
          expect(
            text.contains(w.toLowerCase()),
            isFalse,
            reason: 'B 站变量 ${v.name} 的描述里出现了「$w」：${v.desc}',
          );
        }
      }
    });

    test('抖音与 X 表的描述里也没有 B 站的说法', () {
      const forbidden = ['BV号', 'av号', 'UP主', '分P', '稿件'];
      for (final v in [...kXTemplateVars, ...kDouyinTemplateVars]) {
        for (final w in forbidden) {
          expect(
            v.desc.contains(w),
            isFalse,
            reason: '${v.name} 的描述里出现了「$w」：${v.desc}',
          );
        }
      }
    });
  });

  group('B 站示例媒体', () {
    test('source 是 bili，走的是作品 / 分P / UP 主语境', () {
      final m = biliExampleMedia();
      expect(m.source, 'bili');
      expect(m.bili, isNotNull);
      expect(m.tweetText, isNot(contains('推文')));
      expect(m.bili!.partTotal, greaterThan(1), reason: '示例要能演示补零');
    });

    test('11 个专有变量都解析出非空值', () {
      final m = biliExampleMedia();
      for (final n in biliOnly) {
        final out = resolveVariables('%$n%', m);
        expect(out.isNotEmpty, isTrue, reason: '%$n% 解析成了空串');
      }
    });

    test('%P% 按分 P 总数补零（12 分 P 的第 3 P → 03）', () {
      expect(resolveVariables('%P%', biliExampleMedia()), '03');
      expect(resolveVariables('<P%P%>', biliExampleMedia()), 'P03');
    });

    test('%P,w=3% 显式宽度优先于按总数自动', () {
      expect(resolveVariables('%P,w=3%', biliExampleMedia()), '003');
    });

    test('单 P 稿件的 %P% 是 0，可选段整段消失', () {
      final single = biliExampleMedia().copyWith(
        bili: const BiliMeta(bvid: 'BV1y4411o7Kp', partTotal: 1),
      );
      expect(resolveVariables('%P%', single), '0');
      expect(resolveVariables('<P%P%>', single), '');
      expect(resolveVariables('X<P%P%>Y', single), 'XY');
    });

    test('X 与抖音的媒体上没有 bili 块，靠 bili 块的变量出空串而不是残字', () {
      // UP_NAME / UP_MID 读的是通用字段 userName / userId（和抖音的 AUTHOR /
      // AUTHOR_ID 同一个套路）：跨平台解析时它们给出对方平台的对应值，这是
      // 刻意复用，不算串门 —— 串门管的是**设置页的展示表**，上面已经钉过。
      const fromBiliBlock = [
        'WORK_TITLE',
        'PART_TITLE',
        'P',
        'PART_TOTAL',
        'BVID',
        'AVID',
        'CID',
        'QUALITY',
        'CODEC',
      ];
      for (final m in [xExampleMedia(), douyinExampleMedia()]) {
        expect(m.bili, isNull);
        for (final n in fromBiliBlock) {
          expect(resolveVariables('%$n%', m), isEmpty, reason: '$n 不该有值');
        }
        // 混着写的旧模板也不会留下没替换的残字
        expect(
          resolveVariables('%BVID%_%P%_%AWEME_ID%', m),
          isNot(contains('%')),
        );
      }
    });
  });
}
