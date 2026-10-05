import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/douyin_config.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/models/media_variant.dart';
import 'package:parse_dl/services/douyin_filter.dart';
import 'package:parse_dl/services/douyin_parser.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/services/file_name_template.dart';

/// 抖音模块的解析与仓库测试。
///
/// 上游 JS 那半（hook XHR/fetch、从 JSON 里递归捞 aweme）没法在 Dart 测试里跑，
/// 但**契约**在这里钉住：只要拦到的载荷长这个样子（见 `douyin_interceptor_js.dart`
/// 的 `normalize()`），就必须转成这样的 Media。
/// 以后改拦截脚本的输出字段，这里会立刻炸。
///
/// ⚠️ 载荷结构升级为「变体列表」：
///   - `videos: [{urls, kind, w, h, fps, br, size, format, gear, bytevc1}, ...]`
///     —— 一条视频的全部码率/编码/CDN 变体，下载时才由 `douyin_source.dart` 挑
///   - `images: [{urls, live}, ...]` —— 每张图是一个镜像列表 + 实况图配对视频变体
///   - `musicUrls: [...]` —— BGM 地址（多条镜像）
void main() {
  /// 一个「下载源变体」——键名对齐 `MediaVariant.fromJson`。
  Map<String, dynamic> variant({
    String kind = 'default',
    List<String>? urls,
    int w = 1080,
    int h = 1920,
    int fps = 30,
    int br = 2500000,
    int size = 3145728,
    String format = 'mp4',
    String gear = 'normal_1080p',
    bool bytevc1 = false,
  }) =>
      {
        'urls': urls ??
            ['https://www.douyin.com/aweme/v1/play/?video_id=v0300&ratio=1080p'],
        'kind': kind,
        'w': w,
        'h': h,
        'fps': fps,
        'br': br,
        'size': size,
        'format': format,
        'gear': gear,
        'bytevc1': bytevc1,
      };

  Map<String, dynamic> videoAweme({
    String id = '7300000000000000001',
    String desc = '一条视频 #测试',
    String url = 'https://www.douyin.com/aweme/v1/play/?video_id=v0300&ratio=1080p',
  }) =>
      {
        'id': id,
        'kind': 'video',
        'desc': desc,
        'createTime': 1700000000,
        'authorUid': '111',
        'authorName': '张三',
        'authorId': 'zhangsan',
        'durationMs': 12000,
        'cover': 'https://p3.douyinpic.com/cover.jpeg',
        'videos': [variant(urls: [url])],
        'images': <dynamic>[],
        'musicUrls': ['https://sf3.douyinstatic.com/music/bgm.mp3'],
        'tags': ['测试'],
        'digg': 100,
        'comment': 5,
        'collect': 7,
        'share': 3,
        'episode': 0,
      };

  Map<String, dynamic> imagesAweme({String id = '7300000000000000002'}) => {
        'id': id,
        'kind': 'images',
        'desc': '一组图集',
        'createTime': 1700000100,
        'authorUid': '222',
        'authorName': '李四',
        'authorId': 'lisi',
        'durationMs': 0,
        'cover': '',
        'videos': <dynamic>[],
        'images': [
          {
            'urls': ['https://p3.douyinpic.com/1.jpeg'],
            'live': <dynamic>[],
          },
          {
            'urls': ['https://p3.douyinpic.com/2.jpeg'],
            'live': <dynamic>[],
          },
          {
            'urls': ['https://p3.douyinpic.com/3.jpeg'],
            'live': <dynamic>[],
          },
        ],
        'musicUrls': <String>[],
        'tags': <String>[],
        'digg': 0,
        'comment': 0,
        'collect': 0,
        'share': 0,
      };

  Map<String, dynamic> payload(List<dynamic> items) =>
      {'__pd': 'douyin', 'items': items};

  group('parseDouyinPayload', () {
    test('视频：一条 aweme → 一个 video Media，字段映射正确', () {
      final r = parseDouyinPayload(payload([videoAweme()]));

      expect(r.awemeCount, 1);
      expect(r.media, hasLength(1));

      final m = r.media.single;
      expect(m.id, '7300000000000000001');
      expect(m.type, MediaType.video);
      expect(m.mediaIndex, 1);
      expect(m.source, 'douyin');
      expect(m.tweetId, '7300000000000000001', reason: '%POST_ID% 用它');
      expect(m.tweetText, '一条视频 #测试', reason: '%CONTENT% 用它');
      expect(m.userId, '111');
      expect(m.userName, '张三');
      expect(m.userScreenName, 'zhangsan');
      expect(m.tags, ['测试']);
      expect(m.width, 1080);
      expect(m.height, 1920);
      expect(m.durationMs, 12000);
      expect(m.previewUrl, 'https://p3.douyinpic.com/cover.jpeg');
      expect(m.url, contains('video_id=v0300'));
    });

    test('视频：统计字段四个都落到 Media 上', () {
      final m = parseDouyinPayload(payload([videoAweme()])).media.single;
      expect(m.likeCount, 100);
      expect(m.commentCount, 5);
      expect(m.collectCount, 7);
      expect(m.shareCount, 3);
      expect(m.collectionEpisode, 0);
    });

    test('视频：变体全部保留（含 BGM 音频变体），下载时才挑', () {
      final m = parseDouyinPayload(payload([videoAweme()])).media.single;
      final kinds = m.variants.map((v) => v.kind).toList();

      expect(kinds, contains(VariantKind.defaultAddr));
      expect(kinds, contains(VariantKind.audio),
          reason: 'BGM 不单独成条，而是挂成 audio 变体');
      expect(m.chosen, isNull, reason: '抓取阶段不挑源，改设置才对已抓到的条目生效');
    });

    test('视频：create_time 是 Unix 秒（UTC），要转成本地时间', () {
      final r = parseDouyinPayload(payload([videoAweme()]));
      expect(
        r.media.single.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true)
            .toLocal(),
      );
    });

    test('图集：一条 aweme 展开成 n 个 image Media，索引从 1 起', () {
      final r = parseDouyinPayload(payload([imagesAweme()]));

      expect(r.awemeCount, 1, reason: '图集只算一条作品');
      expect(r.media, hasLength(3));
      expect(r.media.map((m) => m.id).toList(), [
        '7300000000000000002_1',
        '7300000000000000002_2',
        '7300000000000000002_3',
      ]);
      expect(r.media.map((m) => m.mediaIndex).toList(), [1, 2, 3]);
      for (final m in r.media) {
        expect(m.type, MediaType.image);
        expect(m.source, 'douyin');
        expect(m.previewUrl, m.url, reason: '图片自己就是缩略图');
      }
    });

    test('图集：多镜像时首个当主地址、其余进 altUrls', () {
      final multi = imagesAweme(id: '7300000000000000009');
      (multi['images'] as List)[0] = {
        'urls': [
          'https://p3.douyinpic.com/a.webp',
          'https://p6.douyinpic.com/a.jpeg',
        ],
        'live': <dynamic>[],
      };

      final m = parseDouyinPayload(payload([multi])).media.first;
      expect(m.url, 'https://p3.douyinpic.com/a.webp');
      expect(m.altUrls, ['https://p6.douyinpic.com/a.jpeg']);
    });

    test('实况图：静态图与配对视频共用同一个 mediaIndex', () {
      final live = {
        'id': '7300000000000000010',
        'kind': 'images',
        'desc': '实况图',
        'createTime': 1700000200,
        'videos': <dynamic>[],
        'images': [
          {
            'urls': ['https://p3.douyinpic.com/live1.jpeg'],
            'live': [
              variant(
                kind: 'live',
                urls: ['https://v11.douyinvod.com/live1.mp4'],
                w: 720,
                h: 1280,
              ),
            ],
          },
        ],
        'musicUrls': <String>[],
        'tags': <String>[],
      };

      final r = parseDouyinPayload(payload([live]));
      expect(r.media, hasLength(2), reason: '静态图 + 配对视频');

      final img = r.media.first;
      final vid = r.media.last;
      expect(img.type, MediaType.image);
      expect(vid.type, MediaType.video);
      expect(vid.mediaIndex, img.mediaIndex,
          reason: '%MEDIA_INDEX%%EXT% 要能拼出 _1.jpg / _1.mp4 的配对');
      expect(vid.width, 720);
      expect(vid.height, 1280);
    });

    test('混合（图集带视频）：图片在前、视频排在最后', () {
      final mixed = imagesAweme(id: '7300000000000000003')
        ..['kind'] = 'mixed'
        ..['videos'] = [
          variant(urls: ['https://www.douyin.com/aweme/v1/play/?video_id=v9']),
        ];

      final r = parseDouyinPayload(payload([mixed]));
      expect(r.media, hasLength(4));
      expect(r.media.last.type, MediaType.video);
      expect(r.media.last.id, '7300000000000000003',
          reason: '视频条目直接用 aweme_id（对齐参照实现的 %AWEME_ID%）');
      expect(r.media.last.mediaIndex, 4, reason: '接在 3 张图之后');
    });

    test('兼容裸数组 / 单条对象 / 空载荷', () {
      expect(parseDouyinPayload([videoAweme()]).media, hasLength(1));
      expect(parseDouyinPayload(videoAweme()).media, hasLength(1));
      expect(parseDouyinPayload(null).media, isEmpty);
      expect(parseDouyinPayload(payload([])).media, isEmpty);
      expect(parseDouyinPayload({'__pd': 'douyin'}).media, isEmpty);
    });

    test('缺 id / 没有任何直链的条目直接丢弃，不产生空 Media', () {
      final junk = {
        'id': '',
        'kind': 'video',
        'videos': [variant()],
      };
      final noUrl = {
        'id': '999',
        'kind': 'video',
        'videos': <dynamic>[],
        'images': <dynamic>[],
      };
      final r = parseDouyinPayload(payload([junk, noUrl]));
      expect(r.media, isEmpty);
      expect(r.awemeCount, 0);
    });

    test('同一载荷内重复的 id 只留一条', () {
      final a = videoAweme();
      final r = parseDouyinPayload(payload([a, a]));
      expect(r.media, hasLength(1));
    });

    test('视频的多条候选直链：首选 url，其余进 altUrls（换源重试用）', () {
      final multi = videoAweme()
        ..['videos'] = [
          variant(kind: 'default', urls: [
            'https://v11-weba.douyinvod.com/a.mp4',
            'https://v26-web.douyinvod.com/b.mp4',
          ]),
        ];

      final m = parseDouyinPayload(payload([multi])).media.single;
      expect(m.url, 'https://v11-weba.douyinvod.com/a.mp4');
      expect(m.altUrls, ['https://v26-web.douyinvod.com/b.mp4']);
      expect(m.downloadCandidates, [
        'https://v11-weba.douyinvod.com/a.mp4',
        'https://v26-web.douyinvod.com/b.mp4',
      ]);
    });

    test('只有一条直链时 altUrls 为空，downloadCandidates 只有它自己', () {
      final m = parseDouyinPayload(payload([videoAweme()])).media.single;
      expect(m.altUrls, isEmpty);
      expect(m.downloadCandidates, [m.url]);
    });

    test('跨变体的地址也会进候选（换源范围不限于同一码率）', () {
      final multi = videoAweme()
        ..['videos'] = [
          variant(kind: 'default', urls: ['https://a.com/1.mp4']),
          variant(kind: 'bit_rate', urls: ['https://b.com/2.mp4'], w: 720, h: 1280),
        ];

      final m = parseDouyinPayload(payload([multi])).media.single;
      expect(m.url, 'https://a.com/1.mp4');
      expect(m.altUrls, ['https://b.com/2.mp4']);
      expect(m.variants, hasLength(3), reason: '2 个视频变体 + 1 个 BGM 变体');
    });
  });

  group('模板变量对新来源可用', () {
    test('%SOURCE% 输出 douyin，%EXT% 对无扩展名的播放地址退回 mp4', () {
      final m = parseDouyinPayload(payload([videoAweme()])).media.single;
      expect(resolveVariables('%SOURCE%', m), 'douyin');
      expect(
        resolveVariables('%EXT%', m),
        '.mp4',
        reason: '抖音播放地址没有扩展名，不能把整条路径当成后缀',
      );
      expect(
        resolveVariables('%POST_TIME,d=1% %USER_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%', m),
        '2023-11-15 张三 7300000000000000001-1.mp4',
      );
    });

    test('图集按 jpeg 链接取到 .jpeg', () {
      final m = parseDouyinPayload(payload([imagesAweme()])).media.first;
      expect(resolveVariables('%EXT%', m), '.jpeg');
    });

    test('16 个抖音专有变量在真实解析结果上取值正确', () {
      final r = parseDouyinPayload(payload([videoAweme()]));
      final m = r.media.single;
      final createdAt = m.createdAt!;

      expect(resolveVariables('%AUTHOR%', m), '@张三');
      expect(resolveVariables('%AUTHOR_ID%', m), '111');
      expect(resolveVariables('%AUTHOR_UNIQUE_ID%', m), 'zhangsan');
      expect(
        resolveVariables('%CREATE_TIME%', m),
        formatCreateTime(createdAt),
        reason: '%CREATE_TIME% 必须走同一个格式化函数（YYYYMMDDHHmmss）',
      );
      expect(resolveVariables('%DESCRIPTION%', m), '一条视频 #测试');
      expect(resolveVariables('%AWEME_ID%', m), '7300000000000000001');
      expect(resolveVariables('%RESOLUTION%', m), '1080x1920');
      expect(resolveVariables('%DURATION%', m), '12s');
      expect(resolveVariables('%LIKE_COUNT%', m), '100点赞');
      expect(resolveVariables('%COMMENT_COUNT%', m), '5评论');
      expect(resolveVariables('%COLLECT_COUNT%', m), '7收藏');
      expect(resolveVariables('%SHARE_COUNT%', m), '3分享');
      // 这三项读 chosen，而抓取阶段还没挑源 → 空串
      expect(resolveVariables('%BITRATE%', m), '');
      expect(resolveVariables('%FPS%', m), '');
      expect(resolveVariables('%FILE_SIZE%', m), '');
      expect(resolveVariables('%CUSTOM_TEXT%', m), '',
          reason: '自定义文本是下载时注入的，解析阶段为空');
    });

    test('%DESCRIPTION% 超长截断加 ...，缺字段出空串', () {
      final long = parseDouyinPayload(payload([
        videoAweme(desc: '一二三四五六七八九十')
      ])).media.single;
      expect(resolveVariables('%DESCRIPTION,t=4%', long), '一二三四...');
      expect(resolveVariables('%DESCRIPTION,t=1%', long), '一...');
      // 越界参数被 clamp 到 1~120
      expect(resolveVariables('%DESCRIPTION,t=999%', long), '一二三四五六七八九十');
      expect(resolveVariables('%DESCRIPTION,t=0%', long), '一...');
    });
  });

  group('DouyinStore', () {
    Media media(String id) =>
        Media(id: id, type: MediaType.video, url: 'https://x/$id.mp4');

    test('批内保持载荷顺序接到列表末尾，重复 id 被丢弃', () {
      final s = DouyinStore();
      // 拦截脚本按页面从上到下回传，载荷顺序就是版面顺序
      expect(s.ingest([media('a'), media('b')]), 2);
      expect(s.items.map((m) => m.id).toList(), ['a', 'b']);

      // 第二批接在末尾；其中 'a' 已存在
      expect(s.ingest([media('c'), media('a')]), 1);
      expect(s.items.map((m) => m.id).toList(), ['a', 'b', 'c']);
      expect(s.count, 3);
    });

    test('超出硬上限从头部（页面最上面那批）开始丢，并计入 dropped', () {
      final s = DouyinStore();
      s.setCurrentUrl('https://www.douyin.com/user/MS4wLjABAAAAtest');
      // 一批数据按页面从上到下排：m0 在最上面，m1004 在最下面
      s.ingest(List.generate(DouyinStore.kMaxItems + 5, (i) => media('m$i')));

      expect(s.count, DouyinStore.kMaxItems);
      expect(s.dropped, 5);
      expect(s.overflowed, isTrue);
      expect(s.items.first.id, 'm5', reason: '最上面的 5 条被挤掉');
      expect(s.items.any((m) => m.id == 'm0'), isFalse);
      expect(s.items.last.id, 'm1004', reason: '最后进来的那条留着');
    });

    test('一批数据按页面顺序接在列表末尾，不是插到最前', () {
      final s = DouyinStore();
      s.ingest([media('top'), media('mid')]);
      s.ingest([media('bottom1'), media('bottom2')]);
      expect(
        s.items.map((m) => m.id).join(','),
        'top,mid,bottom1,bottom2',
        reason: '用户往下滚，新卡片往下接 —— 列表要跟页面对得上',
      );
    });

    test('勾选 / 全选 / 取消全选，selectedMedia 保持列表顺序', () {
      final s = DouyinStore();
      s.ingest([media('a'), media('b'), media('c')]); // 列表 = a b c

      s.toggle('a');
      s.toggle('c');
      expect(s.selectedCount, 2);
      expect(s.selectedMedia.map((m) => m.id).toList(), ['a', 'c']);

      s.toggle('a');
      expect(s.selectedCount, 1);

      s.setAllSelected(true);
      expect(s.allSelected, isTrue);
      expect(s.selectedCount, 3);

      s.setAllSelected(false);
      expect(s.allSelected, isFalse);
      expect(s.selectedCount, 0);
    });

    test('selectAllOfType 只选中视频或只选中图片', () {
      final s = DouyinStore();
      s.ingest([
        Media(id: 'v', type: MediaType.video, url: 'https://x/v.mp4'),
        Media(id: 'i', type: MediaType.image, url: 'https://x/i.jpeg'),
        Media(id: 'g', type: MediaType.animatedGif, url: 'https://x/g.gif'),
      ]);

      s.selectAllOfType(video: true);
      expect(s.selectedIds, {'v', 'g'});

      s.clearSelection();
      s.selectAllOfType(video: false);
      expect(s.selectedIds, {'i'});
    });

    test('清空结果会同时清掉勾选与计数', () {
      final s = DouyinStore();
      s.ingest([media('a')]);
      s.toggle('a');

      s.clear();
      expect(s.count, 0);
      expect(s.selectedCount, 0);
      expect(s.dropped, 0);
    });

    test('lastUrl 空值不覆盖已有值（避免被 WebView 的空事件清掉）', () {
      final s = DouyinStore();
      expect(s.lastUrl, DouyinStore.kHomeUrl);
      s.lastUrl = 'https://www.douyin.com/video/123';
      s.lastUrl = '';
      expect(s.lastUrl, 'https://www.douyin.com/video/123');
    });

    test('被挤出上限的 id 会从去重集合里移除（否则重新抓到也会被当成重复）',
        () {
      final s = DouyinStore();
      s.setCurrentUrl('https://www.douyin.com/user/MS4wLjABAAAAtest');
      s.ingest(List.generate(DouyinStore.kMaxItems + 1, (i) => media('m$i')));
      expect(s.items.any((m) => m.id == 'm0'), isFalse, reason: '从头（页面最上面）挤掉');

      // 重新抓到已被挤出的那条，应当算新增
      expect(s.ingest([media('m0')]), 1);
      expect(s.items.last.id, 'm0', reason: '新抓到的一条接在列表末尾');
      // dropped 是**累计**丢弃条数：第一次溢出丢掉 m0，
      // 回加 m0 后长度又到 1001，于是把最上面的 m1 挤掉 —— 共 2 条。
      expect(s.dropped, 2);
      expect(s.items.any((m) => m.id == 'm1'), isFalse);
      expect(s.count, DouyinStore.kMaxItems);
    });
  });

  // ── 下载组装（参照实现「批量下载」弹窗点开始之后做的全部事情）─────────
  group('DouyinStore.buildDownloadList', () {
    Media post(
      String id, {
      String tweetId = 'w1',
      MediaType type = MediaType.video,
      int? durationMs,
      List<MediaVariant> variants = const [],
    }) =>
        Media(
          id: id,
          type: type,
          url: 'https://x/$id.mp4',
          source: 'douyin',
          tweetId: tweetId,
          durationMs: durationMs,
          variants: variants,
        );

    MediaVariant bgm(String url) =>
        MediaVariant(urls: [url], kind: VariantKind.audio);

    test('勾选优先于「全部可见」', () {
      final s = DouyinStore();
      s.ingest([post('a'), post('b'), post('c')]);
      s.toggle('b');

      final r = s.buildDownloadList(DouyinConfig());
      expect(r.items.map((m) => m.id).toList(), ['b']);
    });

    test('没有勾选时用当前可见（筛选后）的条目', () {
      final s = DouyinStore();
      s.ingest([post('a'), post('b')]);
      final r = s.buildDownloadList(DouyinConfig());
      expect(r.items.map((m) => m.id).toList(), ['a', 'b']);
    });

    test('跳过已下载：按作品粒度，并给出跳过计数', () async {
      final s = DouyinStore();
      s.ingest([post('a', tweetId: 'w1'), post('b', tweetId: 'w2')]);
      await s.ledger.markAll(['w1']);

      final r = s.buildDownloadList(DouyinConfig(skipDownloaded: true));
      expect(r.items.map((m) => m.tweetId).toList(), ['w2']);
      expect(r.skippedDownloaded, 1);

      // 关掉开关就全都要（默认是开的，所以这里显式关掉）
      final all = s.buildDownloadList(DouyinConfig(skipDownloaded: false));
      expect(all.items, hasLength(2));
      expect(all.skippedDownloaded, 0);
    });

    test('时长筛选只作用于视频，图片不受影响', () {
      final s = DouyinStore();
      s.ingest([
        post('v1', type: MediaType.video, durationMs: 12000),
        post('v2', type: MediaType.video, durationMs: 3000),
        post('i1', type: MediaType.image),
      ]);

      final r = s.buildDownloadList(DouyinConfig(
        timeRangeEnabled: true,
        timeStartSec: 5,
        timeEndSec: 20,
      ));

      expect(r.items.map((m) => m.id).toList(), ['v1', 'i1']);
      expect(r.skippedDuration, 1, reason: '3 秒那条被时长下限筛掉');
    });

    test('超过上限的视频也被筛掉', () {
      final s = DouyinStore();
      s.ingest([post('v1', type: MediaType.video, durationMs: 12000)]);

      final r = s.buildDownloadList(DouyinConfig(
        timeRangeEnabled: true,
        timeStartSec: 0,
        timeEndSec: 10,
      ));
      expect(r.items, isEmpty);
      expect(r.skippedDuration, 1);
    });

    test('时长缺省的视频在启用筛选时被排除（判据与筛选面板一致）', () {
      final s = DouyinStore();
      s.ingest([post('v0', type: MediaType.video)]);

      final r = s.buildDownloadList(DouyinConfig(
        timeRangeEnabled: true,
        timeStartSec: 0,
        timeEndSec: 300,
      ));
      expect(r.items, isEmpty);
      expect(r.skippedDuration, 1);
    });

    test('自定义文本在组装阶段注入（含自动追加的 BGM 条目）', () {
      final s = DouyinStore();
      s.ingest([
        post('i1',
            type: MediaType.image,
            variants: [bgm('https://a.com/bgm.mp3')]),
      ]);

      final r = s.buildDownloadList(DouyinConfig(
        customText: '我的文本',
        includeBgm: true,
      ));

      expect(r.items, hasLength(2), reason: '1 张图 + 1 条 BGM');
      for (final m in r.items) {
        expect(m.customText, '我的文本');
      }
    });

    test('自定义文本为空时不写进 Media（保持 null 语义）', () {
      final s = DouyinStore();
      s.ingest([post('a')]);
      final r = s.buildDownloadList(DouyinConfig());
      expect(r.items.single.customText, isNull);
    });

    test('附带 BGM：仅图文作品追加，按地址在整批内去重', () {
      final s = DouyinStore();
      s.ingest([
        post('i1',
            tweetId: 'w1',
            type: MediaType.image,
            variants: [bgm('https://a.com/same.mp3')]),
        post('i2',
            tweetId: 'w2',
            type: MediaType.image,
            variants: [bgm('https://a.com/same.mp3')]),
        post('v1',
            tweetId: 'w3',
            type: MediaType.video,
            variants: [bgm('https://a.com/other.mp3')]),
      ]);

      final r = s.buildDownloadList(DouyinConfig(includeBgm: true));
      final audios = r.items.where((m) => m.type == MediaType.audio).toList();

      expect(audios, hasLength(1), reason: '两条图文共用同一 BGM，只下一份');
      expect(audios.single.url, 'https://a.com/same.mp3');
      expect(audios.single.id, 'w1_bgm');
      expect(r.items, hasLength(4), reason: '3 条原始 + 1 条 BGM');
    });

    test('不带 BGM 开关时不追加音频条目', () {
      final s = DouyinStore();
      s.ingest([
        post('i1',
            type: MediaType.image,
            variants: [bgm('https://a.com/bgm.mp3')]),
      ]);
      final r = s.buildDownloadList(DouyinConfig());
      expect(r.items.where((m) => m.type == MediaType.audio), isEmpty);
    });

    test('按作品归组：同一作品的条目连续，作品间相对顺序不变', () {
      final s = DouyinStore();
      s.ingest([
        post('a1', tweetId: 'wa'),
        post('b1', tweetId: 'wb'),
        post('a2', tweetId: 'wa'),
      ]);

      // 页面级的 `DouyinFilter.groupByAweme` 与下载组装是**同一件事**，
      // 两个开关都开时结果一致
      final r = s.buildDownloadList(DouyinConfig(groupByAweme: true));
      expect(r.items.map((m) => m.id).toList(), ['a1', 'a2', 'b1']);

      // 两边都关掉才回到「抓取顺序」
      s.setFilter(DouyinFilter(groupByAweme: false));
      final raw = s.buildDownloadList(DouyinConfig(groupByAweme: false));
      expect(raw.items.map((m) => m.id).toList(), ['a1', 'b1', 'a2']);
    });

    test('awemeIds 收集这批涉及的作品（写台账用）', () {
      final s = DouyinStore();
      s.ingest([post('a1', tweetId: 'wa'), post('b1', tweetId: 'wb')]);
      expect(s.buildDownloadList(DouyinConfig()).awemeIds, {'wa', 'wb'});
    });

    test('空仓库产出空结果，不抛异常', () {
      final s = DouyinStore();
      final r = s.buildDownloadList(DouyinConfig());
      expect(r.items, isEmpty);
      expect(r.awemeIds, isEmpty);
    });
  });
}
