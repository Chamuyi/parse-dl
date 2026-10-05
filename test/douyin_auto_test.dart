import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/douyin_auto_task.dart';
import 'package:parse_dl/models/douyin_config.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/douyin_auto_store.dart';
import 'package:parse_dl/services/douyin_store.dart';

/// 抖音「自动下载」的回归测试。
///
/// 三块纯逻辑（不弹 WebView、不起 aria2）：
///   1. 目标解析：各种粘贴写法、去重、认不出来的行、上限；
///   2. 收集器：按媒体 id 去重、作品数口径；
///   3. store 状态机：开始 / 停止 / 推进 / 统计。
void main() {
  group('目标解析', () {
    test('完整链接照原样用', () {
      final p = parseDouyinTargets(
        'https://www.douyin.com/video/7412345678901234567',
      );
      expect(p.tasks, hasLength(1));
      expect(
        p.tasks.single.url,
        'https://www.douyin.com/video/7412345678901234567',
      );
      expect(p.rejected, isEmpty);
    });

    test('纯数字的作品 ID 补成作品链接', () {
      final p = parseDouyinTargets('7412345678901234567');
      expect(
        p.tasks.single.url,
        'https://www.douyin.com/video/7412345678901234567',
      );
    });

    test('短链补 https', () {
      final p = parseDouyinTargets('v.douyin.com/iRxxxxx/');
      expect(p.tasks.single.url, 'https://v.douyin.com/iRxxxxx/');
    });

    test('分享口令里能把链接抠出来', () {
      final p = parseDouyinTargets(
        '7.32 复制打开抖音，看看【某某的作品】 https://v.douyin.com/iRxxxxx/ 快去看看吧',
      );
      expect(p.tasks, hasLength(1));
      expect(p.tasks.single.url, 'https://v.douyin.com/iRxxxxx/');
      expect(p.rejected, isEmpty, reason: '整段口令应当被认出来，而不是当成垃圾行');
    });

    test('链接末尾的中文标点不会被粘进地址', () {
      final p = parseDouyinTargets(
        '看看这个 https://www.douyin.com/video/7412345678901234567。',
      );
      expect(p.tasks.single.url, endsWith('7412345678901234567'));
    });

    test('空行忽略', () {
      final p = parseDouyinTargets('\n\n  \nhttps://v.douyin.com/a/\n\n');
      expect(p.tasks, hasLength(1));
      expect(p.rejected, isEmpty);
    });

    test('同一个地址只保留第一次', () {
      final p = parseDouyinTargets(
        'https://v.douyin.com/a/\n'
        'https://v.douyin.com/a/\n'
        '7412345678901234567\n'
        'https://www.douyin.com/video/7412345678901234567',
      );
      // 后两条一个是纯 ID、一个是链接，归一化之后是同一个地址
      expect(p.tasks, hasLength(2));
    });

    test('认不出来的行进 rejected，且原样保留', () {
      final p = parseDouyinTargets('这不是链接\nhttps://v.douyin.com/a/');
      expect(p.tasks, hasLength(1));
      expect(p.rejected, ['这不是链接']);
    });

    test('超出上限的部分被截断并计数', () {
      final text = List.generate(
        5,
        (i) => 'https://v.douyin.com/x$i/',
      ).join('\n');
      final p = parseDouyinTargets(text, maxTargets: 3);
      expect(p.tasks, hasLength(3));
      expect(p.truncated, 2);
    });
  });

  group('地址归一化', () {
    test('空串返回 null', () {
      expect(normalizeDouyinUrl(''), isNull);
      expect(normalizeDouyinUrl('   '), isNull);
    });

    test('带空格的说明文字返回 null', () {
      expect(normalizeDouyinUrl('复制打开抖音 看看这个'), isNull);
    });

    test('纯数字才当作品 ID（位数不够不算）', () {
      expect(normalizeDouyinUrl('123'), isNull);
      expect(
        normalizeDouyinUrl('7412345678901234567'),
        'https://www.douyin.com/video/7412345678901234567',
      );
    });
  });

  group('目标短标签', () {
    test('按类型给出可辨认的标签', () {
      expect(
        douyinTargetLabel('https://www.douyin.com/video/7412345678901234567'),
        '作品 · 7412345678901234567',
      );
      expect(
        douyinTargetLabel('https://www.douyin.com/user/MS4wLjABAAAAxyz'),
        startsWith('作者 · '),
      );
      expect(
        douyinTargetLabel('https://www.douyin.com/note/7412345678901234567'),
        '图文 · 7412345678901234567',
      );
    });

    test('长 sec_uid 会被截断', () {
      final long = 'M' * 60;
      final label = douyinTargetLabel('https://www.douyin.com/user/$long');
      expect(label.length, lessThan(30));
      expect(label, endsWith('…'));
    });
  });

  group('任务摘要', () {
    DouyinAutoTask mkTask() => DouyinAutoTask(
      input: '作者主页',
      url: 'https://www.douyin.com/user/MS4wLjABAAAAtest',
    );

    test('轮数用尽时，摘要要说出「可能没翻完」', () {
      final t = mkTask()
        ..setStatus(DouyinAutoStatus.done)
        ..queued = 120;

      expect(t.summary, '下载 120 个');
      t.incomplete = true;
      expect(t.summary, contains('可能没翻完'));
    });

    test('重跑要清掉上一轮的未翻完标记', () {
      final t = mkTask()..incomplete = true;
      t.reset();
      expect(t.incomplete, isFalse);
    });
  });

  group('收集器', () {
    Media mk(String id) => Media(
      id: id,
      type: MediaType.video,
      url: 'https://example.com/$id.mp4',
      tweetId: id,
      source: 'douyin',
    );

    test('按媒体 id 去重，返回新增条数', () {
      final c = DouyinAutoCollector();
      expect(c.ingest([mk('a'), mk('b')]), 2);
      expect(c.ingest([mk('b'), mk('c')]), 1);
      expect(c.count, 3);
    });

    test('作品数单独累计（一个图集算一条）', () {
      final c = DouyinAutoCollector();
      c.noteAweme(1);
      c.ingest([mk('img1'), mk('img2'), mk('img3')]);
      expect(c.count, 3, reason: '图集展开成 3 条媒体');
      expect(c.awemeCount, 1, reason: '但只算 1 个作品');
    });

    test('noteAweme 忽略非正数', () {
      final c = DouyinAutoCollector();
      c.noteAweme(0);
      c.noteAweme(-5);
      expect(c.awemeCount, 0);
    });

    test('items 是不可修改视图', () {
      final c = DouyinAutoCollector();
      c.ingest([mk('a')]);
      expect(() => c.items.add(mk('b')), throwsUnsupportedError);
    });
  });

  group('store 状态机', () {
    test('填文本就解析出目标', () {
      final s = DouyinAutoStore();
      s.setRawText('https://v.douyin.com/a/\n7412345678901234567');
      expect(s.total, 2);
      expect(s.hasTargets, isTrue);
      expect(s.running, isFalse);
      expect(s.currentIndex, -1);
    });

    test('开始后所有目标回到 waiting，下标归零', () {
      final s = DouyinAutoStore();
      s.setRawText('https://v.douyin.com/a/\nhttps://v.douyin.com/b/');
      s.start();
      expect(s.running, isTrue);
      expect(s.currentIndex, 0);
      expect(s.tasks.every((t) => t.status == DouyinAutoStatus.waiting), isTrue);
    });

    test('空列表不启动', () {
      final s = DouyinAutoStore();
      s.start();
      expect(s.running, isFalse);
    });

    test('运行中不接受改文本（换掉列表会让下标错位）', () {
      final s = DouyinAutoStore();
      s.setRawText('https://v.douyin.com/a/');
      s.start();
      s.setRawText('https://v.douyin.com/b/\nhttps://v.douyin.com/c/');
      expect(s.total, 1, reason: '运行中的修改应当被忽略');
    });

    test('停止后 running 归假', () {
      final s = DouyinAutoStore();
      s.setRawText('https://v.douyin.com/a/');
      s.start();
      s.stop();
      expect(s.running, isFalse);
    });

    test('advance 推进下标', () {
      final s = DouyinAutoStore();
      s.setRawText('https://v.douyin.com/a/\nhttps://v.douyin.com/b/');
      s.start();
      expect(s.current?.url, 'https://v.douyin.com/a/');
      s.advance();
      expect(s.currentIndex, 1);
      expect(s.current?.url, 'https://v.douyin.com/b/');
    });

    test('统计：已完成条数 / 失败数 / 累计下载与跳过', () {
      final s = DouyinAutoStore();
      s.setRawText('https://v.douyin.com/a/\nhttps://v.douyin.com/b/');
      s.start();
      final a = s.tasks[0];
      a.status = DouyinAutoStatus.done;
      a.awemeCount = 3;
      a.queued = 5;
      a.skippedDownloaded = 2;
      final b = s.tasks[1];
      b.fail('网络错误');

      expect(s.settledCount, 2);
      expect(s.failedCount, 1);
      expect(s.totalAweme, 3);
      expect(s.totalQueued, 5);
      expect(s.totalSkipped, 2);
      expect(s.allSettled, isTrue);
    });

    test('clearText 清掉目标', () {
      final s = DouyinAutoStore();
      s.setRawText('https://v.douyin.com/a/');
      s.clearText();
      expect(s.total, 0);
      expect(s.hasTargets, isFalse);
    });

    test('选项有默认值且可改', () {
      final s = DouyinAutoStore();
      expect(s.maxRounds, 15);
      expect(s.autoDownload, isTrue);
      s.setMaxRounds(25);
      s.setAutoDownload(false);
      expect(s.maxRounds, 25);
      expect(s.autoDownload, isFalse);
    });
  });

  group('与手动下载共用同一套组装规则', () {
    Media video() => Media(
      id: 'v1',
      type: MediaType.video,
      url: 'https://v3-web.douyinvod.com/a.mp4',
      tweetId: '7412345678901234567',
      source: 'douyin',
      durationMs: 30000,
    );

    test('assemble 是纯函数：跳过已下载的判据由调用方给', () {
      // 判据为「都已下载」→ 全部被跳过
      final allSkipped = DouyinStore.assemble(
        [video()],
        DouyinConfig(),
        isDownloaded: (_) => true,
      );
      expect(allSkipped.items, isEmpty);
      expect(allSkipped.skippedDownloaded, 1);

      // 判据为「都没下载」→ 保留
      final kept = DouyinStore.assemble(
        [video()],
        DouyinConfig(),
        isDownloaded: (_) => false,
      );
      expect(kept.items, isNotEmpty);
      expect(kept.skippedDownloaded, 0);
    });

    test('空输入返回空结果', () {
      final r = DouyinStore.assemble(
        const <Media>[],
        DouyinConfig(),
        isDownloaded: (_) => false,
      );
      expect(r.items, isEmpty);
      expect(r.skippedDownloaded, 0);
    });
  });
}
