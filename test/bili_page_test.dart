import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/models/bili_meta.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/bili_api.dart';
import 'package:parse_dl/services/bili_web.dart';
import 'package:parse_dl/pages/bili_page.dart';
import 'package:parse_dl/services/file_name_template.dart';

/// 页面上那四个**纯函数**。
///
/// 页面本身嵌 WebView2，不适合在 widget 测试里构造（`WebviewController` 起不来
/// 会把测试挂成 `did not complete`）。所以钉的是这些被拎出来的判据 —— 它们恰好
/// 是"文案会不会说谎"的地方。
void main() {
  group('登录态文案', () {
    test('三态分开说：null / 检测不到 / 未登录 / 已登录', () {
      expect(biliLoginLineText(null), '登录状态还没检测');
      expect(biliLoginLineText(const BiliLoginState(noData: true)),
          contains('检测不到'));
      expect(biliLoginLineText(const BiliLoginState()), '未登录（只能取到 480P）');
      expect(
          biliLoginLineText(const BiliLoginState(
              isLoggedIn: true, uname: '海边的猫', mid: '1')),
          '已登录：海边的猫');
    });

    test('「检测不到」不能写成「未登录」（会让人白扫一次码）', () {
      final undetectable = biliLoginLineText(const BiliLoginState(noData: true));
      expect(undetectable.contains('未登录'), isFalse);
      expect(biliLoginLineText(BiliLoginState.failed('超时'))
          .contains('未登录'), isFalse);
    });

    test('已登录但昵称取不到时不显示空白', () {
      final s = biliLoginLineText(
          const BiliLoginState(isLoggedIn: true, uname: '', mid: '1'));
      expect(s.trim().isEmpty, isFalse);
      expect(s, contains('已登录'));
    });
  });

  group('时长显示', () {
    test('mm:ss 与 h:mm:ss', () {
      expect(biliClockText(213 * 1000), '3:33');
      expect(biliClockText(3735 * 1000), '1:02:15');
      expect(biliClockText(60 * 1000), '1:00');
    });

    test('拿不到时长给空串，不给 0:00 这种假数字', () {
      expect(biliClockText(null), isEmpty);
      expect(biliClockText(0), isEmpty);
      expect(biliClockText(-1), isEmpty);
    });
  });

  group('分P标记', () {
    Media part({int total = 12, int index = 3}) => biliExampleMedia().copyWith(
      mediaIndex: index,
      bili: BiliMeta(
        workTitle: 't', partTitle: 'p', bvid: 'BV1ofPY3Thnr',
        partTotal: total,
      ),
    );

    test('多 P 给出补零过的号，且与文件名里那段同源', () {
      expect(biliPartBadgeText(part()), 'P03');
      // 同一个模板引擎同一条规则：不是这里另算一遍
      expect(
        resolveVariables('<P%P%>', part()),
        biliPartBadgeText(part()),
      );
    });

    test('单 P 回空串（界面因此不画这枚标记）', () {
      expect(biliPartBadgeText(part(total: 1, index: 1)), isEmpty);
    });

    test('非 B 站媒体上也回空串，不渲染出 P0', () {
      expect(biliPartBadgeText(xExampleMedia()), isEmpty);
      expect(biliPartBadgeText(douyinExampleMedia()), isEmpty);
    });
  });

  group('选流之后才补画质与编码标签', () {
    BiliPlayUrl resp({String label = '480P 清晰'}) => BiliPlayUrl.fromJson({
          'quality': 64,
          'timelength': 2172000,
          'support_formats': [
            {'quality': 32, 'new_description': label},
          ],
          'dash': {
            'duration': 2172,
            'video': [
              {
                'id': 32,
                'codecs': 'avc1.640033',
                'bandwidth': 350352,
                'width': 854,
                'height': 480,
                'baseUrl': 'https://mcdn.example/v.m4s',
                if (label.isNotEmpty) 'codecid': 7,
              },
            ],
            'audio': [
              {
                'id': 30280,
                'codecs': 'mp4a.40.2',
                'bandwidth': 164211,
                'baseUrl': 'https://mcdn.example/a.m4s',
              },
            ],
          },
        }, cid: 1);

    Media unlabeled() => biliExampleMedia().copyWith(
      bili: const BiliMeta(
        workTitle: 't', partTitle: 'p', bvid: 'BV1ofPY3Thnr', partTotal: 12,
        // 刻意不给 qualityLabel / codecLabel：列表阶段就该是空的
      ),
    );

    test('列表阶段的媒体没有标签，选完流才有', () {
      expect(unlabeled().bili!.qualityLabel ?? '', isEmpty);
      final out = biliPartWithLabels(
        unlabeled(),
        videoQn: 32,
        codec: BiliCodec.avc,
        r: resp(),
      );
      expect(out.bili!.qualityLabel, isNotEmpty);
      expect(out.bili!.codecLabel, isNotEmpty);
    });

    test('优先用响应里 support_formats 的说法，不是内置短标签', () {
      final out = biliPartWithLabels(
        unlabeled(),
        videoQn: 32,
        codec: BiliCodec.avc,
        r: resp(label: '480P 清晰（响应给的）'),
      );
      expect(out.bili!.qualityLabel, '480P 清晰（响应给的）');
    });

    test('档位对不上响应时不编一个标签出来', () {
      final out = biliPartWithLabels(
        unlabeled(),
        videoQn: 999,
        codec: null,
        r: resp(),
      );
      expect(out.bili!.qualityLabel ?? '', isEmpty);
      expect(out.bili!.codecLabel ?? '', isEmpty);
    });

    test('没有 bili 块的媒体原样退回，不抛', () {
      final x = xExampleMedia();
      expect(identical(biliPartWithLabels(x, videoQn: 32, codec: null, r: resp()), x),
          isTrue);
    });
  });
}
