import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/douyin_config.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/file_name_template.dart';

/// 抖音文件名的**输出形状**必须稳定：同一组输入永远洗出同一个名字。
///
/// 下面几条样例是本项目自己钉住的参照输入 / 输出（作者与标题均为虚构），
/// 覆盖模板展开与整串清洗两步。
void main() {
  Media dy({
    required String id,
    required MediaType type,
    String? desc,
    String author = 'demo作者甲',
    int index = 1,
    DateTime? at,
  }) => Media(
    id: id,
    type: type,
    // %EXT% 是从下载链接里取扩展名的，测试数据得带上，否则预览的是兜底值
    url: 'https://p/$id.${type == MediaType.video ? 'mp4' : 'jpg'}',
    source: 'douyin',
    tweetId: '7592000000000000000',
    tweetText: desc,
    userName: author,
    mediaIndex: index,
    createdAt: at ?? DateTime(2026, 8, 24, 12, 30, 0),
  );

  /// 样例①②的发布时间是 8 月 19 / 24，日期由调用方给
  final d19 = DateTime(2026, 8, 19, 9, 0, 0);

  String name(Media m, [String? tpl]) =>
      resolveDouyinFileName(tpl ?? kDouyinDefaultFileNameTemplate, m);

  group('douyinFilenamify —— 整串清洗', () {
    test('Windows 非法字符换成下划线（不是 X 侧那个感叹号）', () {
      expect(douyinFilenamify('a<b>c:d"e|f?g*h/i'), 'a_b_c_d_e_f_g_h_i');
    });

    test('半角冒号被换、全角冒号保留（原版字符集里就带着它）', () {
      expect(douyinFilenamify('标题:副标题'), '标题_副标题');
      expect(douyinFilenamify('标题：副标题'), '标题：副标题');
    });

    test('连续空白折成一个下划线', () {
      expect(douyinFilenamify('a   b'), 'a_b');
    });

    test('白名单之外的字符（emoji / 全角标点）换成下划线', () {
      expect(douyinFilenamify('最好🌟青春'), '最好_青春');
      expect(douyinFilenamify('遇到多少人，才能发现'), '遇到多少人_才能发现');
    });

    test('保留点号、at、连字符、下划线和 CJK', () {
      expect(douyinFilenamify('@a-b_c.中文'), '@a-b_c.中文');
    });

    test('相邻的两个替换符压成一个', () {
      expect(douyinFilenamify('好🌟，青'), '好_青');
    });

    test('首尾下划线去掉', () {
      expect(douyinFilenamify('__abc__'), 'abc');
    });

    test('截断到 200 个字符', () {
      expect(douyinFilenamify('x' * 250).length, 200);
    });
  });

  group('默认模板展开', () {
    test('样例①：短描述、图集第 1 张', () {
      final m = dy(
        id: '7591111111111111111_1',
        type: MediaType.image,
        desc: '前方恶魔拦截',
        author: 'Weaston',
        index: 1,
        at: DateTime(2026, 8, 19),
      );
      expect(name(m), '@Weaston_20260819_前方恶魔拦截_0.jpg', reason: '实际：${name(m)}');
    });

    test('样例②：长描述截断补省略号', () {
      final m = dy(
        id: '7592222222222222222_1',
        type: MediaType.image,
        desc: '这是第一段示例文字，这是第二段的文字🌟这是第三段的内容',
        index: 1,
      );
      expect(
        name(m),
        '@demo作者甲_20260824_这是第一段示例文字_这是第二段的文字_这是第三段..._0.jpg',
        reason: '实际：${name(m)}',
      );
    });

    test('图集序号从 0 起，第 4 张是 _3', () {
      final m = dy(
        id: '7592222222222222222_4',
        type: MediaType.image,
        desc: '前方恶魔拦截',
        author: 'Weaston',
        index: 4,
        at: d19,
      );
      expect(name(m), '@Weaston_20260819_前方恶魔拦截_3.jpg');
    });

    test('作品主视频不带序号', () {
      final m = dy(
        // 主视频的 id 就是作品 id（见 douyin_parser.dart）
        id: '7592000000000000000',
        type: MediaType.video,
        desc: '前方恶魔拦截',
        author: 'Weaston',
        at: d19,
      );
      expect(name(m), '@Weaston_20260819_前方恶魔拦截.mp4');
    });

    test('实况图的配对视频与静态图共用同一个序号', () {
      final m = dy(
        id: '7592000000000000000_2v',
        type: MediaType.video,
        desc: '前方恶魔拦截',
        author: 'Weaston',
        index: 2,
        at: d19,
      );
      expect(name(m), '@Weaston_20260819_前方恶魔拦截_1.mp4');
    });

    test('昵称为空时用 unknown_author 兜底', () {
      final m = dy(
        id: 'x_1',
        type: MediaType.image,
        desc: '前方恶魔拦截',
        author: '',
      );
      expect(name(m).startsWith('@unknown_author_20260824_'), isTrue);
    });

    test('描述为空时用作品 id 兜底，不留挂尾下划线', () {
      final m = dy(id: 'x_1', type: MediaType.image, desc: '');
      expect(name(m), '@demo作者甲_20260824_7592000000000000000_0.jpg');
    });

    test('没有创建时间时不挂空日期段', () {
      final m = dy(
        id: 'x_1',
        type: MediaType.image,
        desc: '前方恶魔拦截',
        author: 'Weaston',
        at: d19,
      );
      final noTime = Media(
        id: m.id,
        type: m.type,
        url: m.url,
        source: 'douyin',
        tweetId: m.tweetId,
        tweetText: m.tweetText,
        userName: m.userName,
        mediaIndex: m.mediaIndex,
      );
      expect(name(noTime), '@Weaston_前方恶魔拦截_0.jpg');
    });
  });

  group('旧默认模板升级', () {
    test('设置里存着旧默认值 → 读出来就是参照实现模板', () {
      final c = DouyinConfig.fromJson({
        'fileNameTemplate': '%CREATE_TIME%_%DESCRIPTION%%EXT%',
      });
      expect(c.fileNameTemplate, kDouyinDefaultFileNameTemplate);
    });

    test('压根没存过这个字段 → 也是参照实现模板', () {
      expect(
        DouyinConfig.fromJson({}).fileNameTemplate,
        kDouyinDefaultFileNameTemplate,
      );
    });

    test('用户自己改过的模板原样保留，不被升级顶掉', () {
      const mine = '%AWEME_ID%_%DESCRIPTION%%EXT%';
      expect(
        DouyinConfig.fromJson({'fileNameTemplate': mine}).fileNameTemplate,
        mine,
      );
    });
  });

  group('X 侧不受影响', () {
    test('X 的模板仍走逐变量净化（感叹号那套）', () {
      final m = Media(
        id: '1',
        type: MediaType.image,
        url: 'https://t/1.jpg',
        source: 'x',
        tweetText: 'a<b>c',
        mediaIndex: 1,
      );
      expect(resolveVariables('%CONTENT%%EXT%', m), 'a!b!c.jpg');
    });
  });

  group('整串清洗的保留集（本项目自己的规则）', () {
    test('任意语言的字母与数字都留下', () {
      expect(douyinFilenamify('テスト'), 'テスト');
      expect(douyinFilenamify('테스트'), '테스트');
      expect(douyinFilenamify('café'), 'café');
      expect(douyinFilenamify('１２３'), '１２３');
    });

    test('标点、符号、emoji 换成下划线并归并', () {
      expect(douyinFilenamify('a★b'), 'a_b');
      expect(douyinFilenamify('a😀b'), 'a_b');
      expect(douyinFilenamify('a  !!  b'), 'a_b');
    });

    test('保住文件名有用的标点，但 Windows 保留字符必须换', () {
      expect(douyinFilenamify('v1.2-final@x：y'), 'v1.2-final@x：y');
      expect(douyinFilenamify(r'a:b/c\d'), 'a_b_c_d');
    });

    test('结尾不能留点或空格（Windows 会静默裁掉）', () {
      expect(douyinFilenamify('标题...'), '标题');
      expect(douyinFilenamify('标题   '), '标题');
    });

    test('整串为空时回落到 fallback，而不是交出空名', () {
      expect(douyinFilenamify('★ 😀', fallback: '7412345'), '7412345');
      expect(douyinFilenamify('___', fallback: '7412345'), '7412345');
      // 没给 fallback 时仍是空串 —— 调用方（模板路径）负责传
      expect(douyinFilenamify('★'), '');
    });

    test('上限 200 个码元，维持原设置不变', () {
      expect(douyinFilenamify('字' * 260).length, 200);
    });
  });

}
