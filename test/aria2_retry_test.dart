import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/media.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';

/// 「失败之后怎么办」的决策逻辑。
///
/// 这段逻辑对齐的是参照实现：**先把作品的每一条下载地址都试一遍，
/// 全部不可用才认输**。顺序错了（先原地重试同一条失效地址）会让
/// 抖音的下载一直卡在一条 403 的 CDN 地址上白等 —— 正是「抖音无法下载」
/// 的观感来源。
void main() {
  group('decideRetry', () {
    test('还有备用地址 → 优先换源（不消耗原地重试额度）', () {
      expect(
        decideRetry(
            attempt: 0, candidateCount: 3, retryRemains: 5, permanent: false),
        RetryAction.switchSource,
      );
      expect(
        decideRetry(
            attempt: 1, candidateCount: 3, retryRemains: 5, permanent: false),
        RetryAction.switchSource,
      );
    });

    test('403/404 这类永久失败也照样换源 —— 同一条作品的另一条地址可能是好的', () {
      expect(
        decideRetry(
            attempt: 0, candidateCount: 2, retryRemains: 5, permanent: true),
        RetryAction.switchSource,
        reason: '实测抖音 v26 节点无 Referer 403，同作品 v11 节点正常',
      );
    });

    test('地址用尽 + 还有重试额度 + 非永久错误 → 原地重试', () {
      expect(
        decideRetry(
            attempt: 2, candidateCount: 3, retryRemains: 4, permanent: false),
        RetryAction.retrySame,
      );
    });

    test('地址用尽 + 永久错误 → 直接放弃', () {
      expect(
        decideRetry(
            attempt: 2, candidateCount: 3, retryRemains: 5, permanent: true),
        RetryAction.giveUp,
      );
    });

    test('地址用尽 + 重试额度用光 → 放弃', () {
      expect(
        decideRetry(
            attempt: 0, candidateCount: 1, retryRemains: 0, permanent: false),
        RetryAction.giveUp,
      );
    });

    test('只有一条地址时退化成原来的行为（原地重试）', () {
      expect(
        decideRetry(
            attempt: 0, candidateCount: 1, retryRemains: 5, permanent: false),
        RetryAction.retrySame,
        reason: 'X 的媒体只有一条直链，不能被这次改动影响',
      );
    });

    test('换源一定终止：attempt 递增、候选有限', () {
      var attempt = 0;
      var steps = 0;
      const count = 4;
      while (decideRetry(
              attempt: attempt,
              candidateCount: count,
              retryRemains: 0,
              permanent: true) ==
          RetryAction.switchSource) {
        attempt++;
        if (++steps > 20) fail('换源没有终止');
      }
      expect(attempt, count - 1);
      expect(steps, count - 1);
    });
  });

  group('Media.downloadCandidates', () {
    Media m(String url, {List<String> altUrls = const []}) => Media(
          id: '1',
          type: MediaType.video,
          url: url,
          altUrls: altUrls,
        );

    test('首选在前、备用在后', () {
      final media = m('https://a/1.mp4', altUrls: ['https://b/1.mp4']);
      expect(media.downloadCandidates, ['https://a/1.mp4', 'https://b/1.mp4']);
    });

    test('备用里混进首选时去重 —— 否则换源会原地打转', () {
      final media = m('https://a/1.mp4',
          altUrls: ['https://a/1.mp4', 'https://b/1.mp4', '']);
      expect(media.downloadCandidates, ['https://a/1.mp4', 'https://b/1.mp4']);
    });

    test('X 的图片：首选仍带 ?name=orig，备用不受影响', () {
      final img = Media(
        id: '2',
        type: MediaType.image,
        url: 'https://pbs.twimg.com/media/x.jpg',
      );
      expect(img.downloadCandidates.single, contains('name=orig'));
    });
  });

  group('isPermanentDownloadError（消息 → 永久失败）', () {
    test('404 / 403 / 410 及英文措辞都算永久失败', () {
      expect(isPermanentDownloadError('404 Not Found'), isTrue);
      expect(isPermanentDownloadError('HTTP 403'), isTrue);
      expect(isPermanentDownloadError('410 Gone'), isTrue);
      expect(isPermanentDownloadError('resource not found'), isTrue);
      expect(isPermanentDownloadError('Forbidden'), isTrue);
      expect(isPermanentDownloadError('errorCode=22, status=403'), isTrue);
    });

    test('网络抖动类错误不算永久失败（该原地重试就重试）', () {
      expect(isPermanentDownloadError('timeout'), isFalse);
      expect(isPermanentDownloadError('Connection reset by peer'), isFalse);
      expect(isPermanentDownloadError('未知错误'), isFalse);
      expect(isPermanentDownloadError(''), isFalse);
    });

    test('0 字节空响应不走这个判据（它由 forcePermanent 声明）', () {
      expect(isPermanentDownloadError('服务器返回空内容（0 字节）'), isFalse,
          reason: '同一句话里没有 4xx，正则不该误判成永久失败');
    });
  });

  group('0 字节空响应的重试语义', () {
    // 空响应 = 「换源有意义、原地重试没意义」：
    // _onCompleteAsync 发现文件 0 字节时，会以 forcePermanent: true 调 _handleFailure，
    // 也就是说下面这些用例里 permanent 恒为 true。
    const zeroByte = '服务器返回空内容（0 字节）';

    test('这句错误描述本身不会命中永久失败正则', () {
      expect(isPermanentDownloadError(zeroByte), isFalse,
          reason: '它没有 4xx，永久性是 forcePermanent 参数声明的');
    });

    test('有多条 CDN 地址时先换源（不白等 5 次原地重试）', () {
      expect(
        decideRetry(
            attempt: 0,
            candidateCount: 3,
            retryRemains: kAriaRetryTimes,
            permanent: true),
        RetryAction.switchSource,
      );
    });

    test('只有一条地址时立刻放弃 —— 而不是原地重试 5 次同一个空响应', () {
      expect(
        decideRetry(
            attempt: 0,
            candidateCount: 1,
            retryRemains: kAriaRetryTimes,
            permanent: true),
        RetryAction.giveUp,
        reason: '这正是「抖音下到 0 字节文件」时最该避免的行为',
      );
    });

    test('对照：同场景若不是永久失败，会白白原地重试 5 次', () {
      expect(
        decideRetry(
            attempt: 0,
            candidateCount: 1,
            retryRemains: kAriaRetryTimes,
            permanent: isPermanentDownloadError('timeout')),
        RetryAction.retrySame,
      );
    });
  });

  group('isProxyReachable 参数校验', () {
    test('地址不合法 → false（不能把垃圾填进 all-proxy）', () async {
      expect(await Aria2Coordinator.isProxyReachable(''), isFalse);
      expect(await Aria2Coordinator.isProxyReachable('not a url'), isFalse);
      expect(await Aria2Coordinator.isProxyReachable('http://127.0.0.1'), isFalse,
          reason: '缺端口就没法连');
    });

    test('没人监听的端口 → false', () async {
      // 1 号端口在测试机上不可能是 HTTP/SOCKS 代理
      expect(
        await Aria2Coordinator.isProxyReachable(
          'http://127.0.0.1:1',
          timeout: const Duration(milliseconds: 200),
        ),
        isFalse,
      );
    });
  });
}
