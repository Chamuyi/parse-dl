// 媒体缩略图的回归判据。
//
// 用户 2026-10-12 要求：抖音/B站抓取结果要有**图片预览**。
// 取证结论：数据层早就有了（`bili_link.dart:643` 的 `previewUrl: cover`），
// 缺的只是界面没画出来 —— 所以这里钉的是渲染层。
//
// 判据强度已用负控制验证：把 `MediaThumb` 里的 `Image.network` 换成纯色块时，
// 「有封面时渲染 Image」那条会红。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/media_thumb.dart';

Media mediaWith({
  String? previewUrl,
  MediaType type = MediaType.video,
  int? durationMs,
  int mediaIndex = 1,
}) =>
    Media(
      id: 'BV1test-$mediaIndex',
      type: type,
      url: '',
      previewUrl: previewUrl,
      source: 'bili',
      durationMs: durationMs,
      mediaIndex: mediaIndex,
    );

Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MaterialApp(home: Scaffold(body: Center(child: child))),
      ),
    );

void main() {
  group('封面渲染', () {
    testWidgets('有封面时渲染 Image（这是「图片预览」的核心判据）', (tester) async {
      await pump(tester, MediaThumb(media: mediaWith(previewUrl: 'https://x/y.jpg')));
      expect(find.byType(Image), findsOneWidget,
          reason: '没渲染 Image → 用户看不到预览图');
    });

    testWidgets('无封面时退回占位图标，不渲染 Image', (tester) async {
      await pump(tester, MediaThumb(media: mediaWith(previewUrl: null)));
      expect(find.byType(Image), findsNothing);
      expect(find.byType(Icon), findsWidgets, reason: '连占位图标都没有 → 一片空白');
    });

    testWidgets('空串封面与 null 一样走占位（接口常回空串而不是 null）', (tester) async {
      await pump(tester, MediaThumb(media: mediaWith(previewUrl: '')));
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('负控制：占位图标与封面互斥（证明上两条不是恒真）', (tester) async {
      // 有封面 → 有 Image；无封面 → 无 Image。两条同时成立才说明判据真的在看数据。
      await pump(tester, MediaThumb(media: mediaWith(previewUrl: 'https://x/y.jpg')));
      final withCover = find.byType(Image).evaluate().isNotEmpty;
      await pump(tester, MediaThumb(media: mediaWith(previewUrl: null)));
      final withoutCover = find.byType(Image).evaluate().isEmpty;
      expect(withCover && withoutCover, isTrue,
          reason: '两种输入渲染结果相同 → 判据没在看数据');
    });
  });

  group('角标', () {
    testWidgets('视频显示时长角标', (tester) async {
      await pump(tester, MediaThumb(media: mediaWith(durationMs: 622000)));
      expect(find.text('10:22'), findsOneWidget);
    });

    testWidgets('拿不到时长时不画角标（不显示 0:00 那种假数字）', (tester) async {
      await pump(tester, MediaThumb(media: mediaWith(durationMs: null)));
      expect(find.text('0:00'), findsNothing);
      expect(find.text(''), findsNothing);
    });

    testWidgets('图文显示张数角标', (tester) async {
      await pump(tester, MediaThumb(
        media: mediaWith(type: MediaType.image, mediaIndex: 9),
      ));
      expect(find.text('9'), findsOneWidget);
    });
  });

  group('选中与已下载', () {
    testWidgets('选中时描黄框，且色值就是 kMarkYellow', (tester) async {
      await pump(tester, MediaThumb(
        media: mediaWith(previewUrl: 'https://x/y.jpg'), selected: true));
      // 找那个带边框的 Container
      final boxes = tester.widgetList<Container>(find.byType(Container));
      final hasYellow = boxes.any((b) {
        final d = b.decoration;
        return d is BoxDecoration &&
            d.border is Border &&
            (d.border as Border).top.color == kMarkYellow;
      });
      expect(hasYellow, isTrue,
          reason: '选中态没描 kMarkYellow → 与页面上注入脚本画的框对不上，'
              '用户就没法靠"两边一样的框"确认是同一条');
    });

    testWidgets('未选中时不描黄框（负控制）', (tester) async {
      await pump(tester, MediaThumb(
        media: mediaWith(previewUrl: 'https://x/y.jpg'), selected: false));
      final boxes = tester.widgetList<Container>(find.byType(Container));
      final hasYellow = boxes.any((b) {
        final d = b.decoration;
        return d is BoxDecoration &&
            d.border is Border &&
            (d.border as Border).top.color == kMarkYellow;
      });
      expect(hasYellow, isFalse);
    });

    testWidgets('已下载时盖缎带', (tester) async {
      await pump(tester, MediaThumb(
        media: mediaWith(previewUrl: 'https://x/y.jpg'), downloaded: true));
      expect(find.text('已下载'), findsOneWidget);
    });

    testWidgets('未下载时没有缎带（负控制）', (tester) async {
      await pump(tester, MediaThumb(media: mediaWith(previewUrl: 'https://x/y.jpg')));
      expect(find.text('已下载'), findsNothing);
    });
  });
}
