// 字幕 ass 样式的回归判据。
//
// 为什么要有这个文件：`&H$alpha FFFFFF` 里那个空格是**肉眼极难发现**的一类错误
// —— ass 颜色是 `&HAABBGGRR`，libass 在空格处截断，只读到 `&H00` 并补零成
// `&H00000000`（不透明黑）。文件能生成、播放器不报错、测试全绿，只有用户看到
// 一片黑字才知道。所以判据必须**直接钉住颜色字段的形状**。
//
// 这些判据的强度已用负控制验证过：把实现改回 `&H$alpha FFFFFF` 时，
// 「主色不含空格」与「主色是不透明白」两条都会变红。
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/services/bili_dm_proto.dart';
import 'package:parse_dl/services/bili_subtitle.dart';

BiliConfig cfgWith({int? fontSize, int? opacity, int? marginV}) {
  final c = BiliConfig();
  if (fontSize != null) c.danmakuFontSize = fontSize;
  if (opacity != null) c.danmakuOpacity = opacity;
  if (marginV != null) c.danmakuMarginV = marginV;
  return c;
}

BiliSubtitleEntry entryWith(String text) => BiliSubtitleEntry(
      lan: 'zh',
      lanDoc: '中文',
      lines: [(0, 1000, text)],
    );

/// 取出 `Style:` 行并按逗号切成字段。
List<String> styleFields(BiliConfig cfg) {
  final ass = biliSubtitleToAss(entryWith('测试'), cfg);
  final line = ass
      .split('\n')
      .firstWhere((l) => l.startsWith('Style:'), orElse: () => '');
  expect(line, isNotEmpty, reason: 'ass 里没有 Style 行');
  return line.substring('Style:'.length).split(',');
}

void main() {
  group('主色（黑字缺陷的判据）', () {
    test('主色字段不含空格 —— 空格会让 libass 截断成黑色', () {
      final f = styleFields(cfgWith());
      final primary = f[3]; // Name, Fontname, Fontsize, PrimaryColour
      expect(primary.contains(' '), isFalse,
          reason: '主色里有空格 → libass 只读到 &H00 → 补零成不透明黑。'
              '实测：带空格时字形像素 79% 是近黑（1080/1367）');
    });

    test('主色恰好是不透明白 &H00FFFFFF', () {
      expect(styleFields(cfgWith())[3], '&H00FFFFFF');
    });

    test('主色与 biliAssColor 同源（不手拼）', () {
      // 同一个不透明度下，字幕主色必须等于弹幕那套函数的输出。
      for (final op in [100, 60, 0]) {
        final f = styleFields(cfgWith(opacity: op));
        expect(f[3], biliAssColor(0xFFFFFF, opacity: op),
            reason: 'opacity=$op 时与 biliAssColor 不一致 → 又有人手拼了颜色');
      }
    });

    test('负控制：手拼带空格的串确实会被判错（证明上面那条不是恒真）', () {
      // 直接构造那个错误形状，确认判据能识别它
      const buggy = '&H00 FFFFFF';
      expect(buggy.contains(' '), isTrue);
      expect(buggy == '&H00FFFFFF', isFalse);
      // 而正确的形状不含空格
      expect(biliAssColor(0xFFFFFF, opacity: 100), isNot(contains(' ')));
    });
  });

  group('字号（小字缺陷的判据）', () {
    test('默认配置下字幕字号 = 48（抄 B站公式 28×1920/1139≈47.2）', () {
      expect(styleFields(cfgWith())[2], '48');
    });

    test('用户调过弹幕字号就尊重他的选择', () {
      expect(styleFields(cfgWith(fontSize: 60))[2], '60');
      expect(styleFields(cfgWith(fontSize: 10))[2], '10');
    });

    test('负控制：默认值本身确实是 25（否则上一条断言失去意义）', () {
      expect(kBiliDefaultDanmakuFontSize, 25);
      expect(BiliConfig().danmakuFontSize, 25);
      expect(kBiliDefaultSubtitleFontSize, isNot(kBiliDefaultDanmakuFontSize));
    });

    test('48 这个值不是拍的：B站公式在 1920 宽下给出 47.2', () {
      // 抄自播放器 JS：fontSize = 28 * (panelWidth / 1139)
      final bili = 28 * 1920 / 1139;
      expect(bili, closeTo(47.2, 0.1));
      expect((kBiliDefaultSubtitleFontSize - bili).abs(), lessThan(1.0),
          reason: '与 B站公式的结果差了 1px 以上 → 要么公式变了要么值写错了');
    });
  });

  group('底部边距', () {
    test('默认配置下字幕边距 = 48，不是弹幕的 10', () {
      // 字段序：... BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV
      expect(styleFields(cfgWith())[20], '48');
    });

    test('用户调过弹幕边距就尊重他的选择', () {
      expect(styleFields(cfgWith(marginV: 50))[20], '50');
    });
  });

  group('描边（抄 B站 majorStrokeWidth:3 + strokeColor:#000000）', () {
    test('描边宽 = 3', () {
      expect(styleFields(cfgWith())[15], '3');
    });

    test('描边色是黑 &H00000000', () {
      expect(styleFields(cfgWith())[4], '&H00000000');
    });

    test('描边色常量与 B站 strokeColor 一致', () {
      expect(kBiliSubtitleOutlineColor, 0x000000);
      expect(kBiliSubtitleOutline, 3);
    });
  });

  group('对齐与描边（可读性）', () {
    test('底部居中、有描边与阴影', () {
      final f = styleFields(cfgWith());
      expect(f[17], '2', reason: 'Alignment=2 底部居中；改了会跑到别处');
      expect(int.parse(f[15]), greaterThanOrEqualTo(2),
          reason: 'Outline 太细 → 浅色画面上白字会糊掉');
    });

    test('字体名不带引号也不带多余空格', () {
      final f = styleFields(cfgWith());
      expect(f[1], kBiliDefaultDanmakuFontFace);
      expect(f[1].trim(), f[1]);
    });
  });

  group('Script Info 段的拼写', () {
    test('用的是 ScaledBorderAndShadow（不是 ScaledAndBorder）', () {
      final ass = biliSubtitleToAss(entryWith('测试'), cfgWith());
      expect(ass, contains('ScaledBorderAndShadow: yes'));
      // 负控制：那个拼错的名字必须不在
      expect(ass, isNot(contains('ScaledAndBorder')));
    });
  });
}
