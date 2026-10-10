import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_meta.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/file_name_template.dart';

/// 命名这一维的验收判据。
///
/// 「随机命名模板」要随的是**真能用的名字**：不许留没替换的 `%VAR%`、不许有
/// Windows 非法字符、不许长到越限、几条预设之间必须真的不一样（要是都能渲染出
/// 同一个名字，那"随机"就是假的）。
void main() {
  /// Windows 文件名里不能出现的字符。`/` 例外 —— 它只在**文件夹模板**里当层级分隔符。
  final illegal = RegExp(r'[<>:"\\|?*\x00-\x1f]');

  Media singlePart() => biliExampleMedia().copyWith(
    mediaIndex: 1,
    bili: const BiliMeta(
      workTitle: '把一年的海边拍成十二段',
      partTitle: '把一年的海边拍成十二段',
      bvid: 'BV1ofPY3Thnr',
      aid: '114514000',
      cid: '765432109',
      partTotal: 1,
      qualityLabel: '1080P60',
      codecLabel: 'AV1',
    ),
  );

  Media labeled(String q, String c) => biliExampleMedia().copyWith(
    bili: BiliMeta(
      workTitle: '把一年的海边拍成十二段',
      partTitle: '第3P 冬天',
      bvid: 'BV1ofPY3Thnr',
      partTotal: 12,
      qualityLabel: q,
      codecLabel: c,
    ),
  );

  List<String> fileNameTemplates() => [
        kBiliDefaultFileNameTemplate,
        ...kBiliTemplatePresets.map((p) => p.fileNameTemplate),
      ];

  group('B 站命名模板', () {
    test('多 P 与单 P 都渲染得出来，且不留未替换的变量', () {
      for (final m in [biliExampleMedia(), singlePart()]) {
        for (final t in [
          ...fileNameTemplates(),
          ...kBiliTemplatePresets.map((p) => p.dirTemplate),
        ].where((t) => t.isNotEmpty)) {
          final out = resolveVariables(t, m);
          expect(out.contains('%'), isFalse,
              reason: '$t 在 mediaIndex=${m.mediaIndex} 上留了残字：$out');
        }
      }
    });

    test('正控制：未知变量本该原样留着（证明上面那条不是恒真）', () {
      final out = resolveVariables('%WORK_TITLE%_%NOT_A_VAR%', biliExampleMedia());
      expect(out, contains('%NOT_A_VAR%'));
    });

    test('文件名模板的渲染结果不含 Windows 非法字符', () {
      for (final m in [biliExampleMedia(), singlePart()]) {
        for (final t in fileNameTemplates()) {
          final out = resolveVariables(t, m);
          expect(illegal.hasMatch(out), isFalse, reason: '$t → $out');
        }
      }
    });

    test('文件夹模板每一层都非空且不含非法字符', () {
      for (final p in kBiliTemplatePresets) {
        if (p.dirTemplate.isEmpty) continue;
        final out = resolveVariables(p.dirTemplate, biliExampleMedia());
        for (final seg in out.split('/')) {
          expect(illegal.hasMatch(seg), isFalse, reason: '${p.id} → $out');
          expect(seg.trim().isEmpty, isFalse, reason: '${p.id} 有空层级：$out');
        }
      }
    });

    test('单 P 不渲染出 P0 / P00；多 P 的补零确实在（两半合起来才算数）', () {
      final one = singlePart();
      for (final t in fileNameTemplates()) {
        final out = resolveVariables(t, one);
        expect(out, isNot(contains('P0-')), reason: '$t → $out');
        expect(out, isNot(matches(RegExp(r'P0\d-'))), reason: '$t → $out');
      }
      final multi =
          resolveVariables(kBiliDefaultFileNameTemplate, biliExampleMedia());
      expect(multi, startsWith('P03-'), reason: '示例是 12 分 P 的第 3 P：$multi');
    });

    test('各预设产出的文件名互不相同（"随机模板"要真随得出差别）', () {
      final names = {
        for (final p in kBiliTemplatePresets)
          p.id: resolveVariables(p.fileNameTemplate, biliExampleMedia()),
      };
      expect(names.values.where((n) => n.trim().isNotEmpty), isNotEmpty);
      expect(names.values.toSet().length, greaterThan(1), reason: '$names');
    });

    test('画质与编码进名字：换档必须改变渲染结果', () {
      final a = resolveVariables(kBiliDefaultFileNameTemplate, labeled('1080P60', 'AV1'));
      final b = resolveVariables(kBiliDefaultFileNameTemplate, labeled('480P', 'AVC'));
      expect(a, isNot(equals(b)), reason: '$a vs $b');
      expect(b, contains('480P'));
      expect(b, contains('AVC'));
    });

    test('渲染结果非空且不超单串上限', () {
      for (final m in [biliExampleMedia(), singlePart()]) {
        for (final t in fileNameTemplates()) {
          final out = resolveVariables(t, m);
          expect(out.trim().isEmpty, isFalse, reason: '$t 渲染成空串');
          expect(out.length, lessThanOrEqualTo(kDouyinFileNameMax),
              reason: '$t → ${out.length} 码元');
        }
      }
    });

    test('超长标题：模板层不截断，截断发生在入队时的全路径保护里', () {
      final long = biliExampleMedia().copyWith(
        bili: BiliMeta(
          workTitle: '长' * 240,
          partTitle: '长' * 240,
          bvid: 'BV1ofPY3Thnr',
          partTotal: 3,
          qualityLabel: '1080P',
          codecLabel: 'AVC',
        ),
        mediaIndex: 2,
      );
      final out = resolveVariables(kBiliDefaultFileNameTemplate, long);
      expect(out.length, greaterThan(kDouyinFileNameMax),
          reason: '模板引擎刻意不截断 —— 截断要连着目录一起算才有意义');

      const dir = r'D:/demo/dl/把一年的海边拍成十二段';
      expect(pathFitsWindowsMax(dir, out), isFalse);
      final clamped = clampNameForFullPath(dir, out);
      expect(pathFitsWindowsMax(dir, clamped), isTrue);
      expect(clamped.length, lessThan(out.length));
    });
  });
}
