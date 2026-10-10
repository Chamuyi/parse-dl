/// B 站台账 ↔ 下载协调器 之间的桥。
///
/// 抽成独立文件的原因与 `douyin_ledger_bridge.dart` 一样：这段接线原先内联在
/// 启动流程里的话，「收口 → 进已下载」这条链的中间一环就没有任何测试能碰到。
/// 而这一环恰好是整个 B 站下载链路里**唯一允许把 pending 转成 done 的地方**，
/// 必须能被单独钉住。
///
/// ## 红线：为什么不能用 `BiliLedger.advance` 转 done
/// `advance()` 只看任务行自己的状态（抖音那条链就是这么收的）。B 站一条 DASH
/// 分 P 落的是**两行 `.m4s`**（视频流 + 音频流），两行都会先变成 `complete` ——
/// 而真正的成品 `<base>.mp4` 要等 ffmpeg 合完才存在。用 `advance` 的话，
/// **合并失败**（ffmpeg 缺失 / 被安全软件拦下 / 裸流被移走）也会因为
/// 「两条任务行都完成了」被算成已下载：台账从此认为这条下过了，
/// 开着「跳过已下载」就再也不重试，而用户手里只有两个不能单独播放的裸流。
/// 所以 done 只认协调器的收口结局（见 [biliSettlesAsDownloaded]）。
library;

import 'dart:async';

import '../models/media.dart';
import 'app_logger.dart';
import 'aria2_coordinator.dart';
import 'bili_ledger.dart';

/// 收口结局 → 这条分 P 算不算「已经拿到手」。
///
/// [BiliSettleKind.mergeFailed] **不算**：它的含义是「字节都下完了但合不出成品」，
/// 此时协调器保留两条裸流与两行任务，用户重试其中一行就会重新走合并。
/// 台账那条记录继续留在 pending（既不进「已下载」历史，也不会被误标成成功），
/// 界面上重试的路径由下载管理页承担，而不是让页面把整批重新投一遍。
bool biliSettlesAsDownloaded(BiliSettleKind kind) => switch (kind) {
      BiliSettleKind.merged => true,
      BiliSettleKind.streamsKept => true,
      // durl 退化路径的那一条完整 mp4 也归 merged，所以这里不会漏掉它。
      BiliSettleKind.mergeFailed => false,
    };

/// 这条分 P 的台账键组（`bvid` + `cid`，与「跳过已下载」同一个口径）。
BiliKeyGroup biliLedgerKeyOf(Media media) =>
    biliPartKey(bvid: media.bili?.bvid, cid: media.bili?.cid);

/// 把协调器的收口回调接到台账上。
///
/// 挂在 app 级而不是解析下载页的 State 里：**页面切走时收口照样会发生**
/// （合并是在 aria2 的事件流上跑的）。绑在页面上就等于「看着下载列表里的
/// 成品生成了，台账里那条却永远停在『在下』」—— 而下次批量下载会因为
/// 「跳过已下载」把它当成处理过，用户既拿不到成品也等不到重试。
void bindBiliLedgerToSettled(Aria2Coordinator coordinator, BiliLedger ledger) {
  coordinator.onBiliSettled = (info) {
    final key = biliLedgerKeyOf(info.media);
    if (!biliKeyGroupUsable(key)) {
      // 键组缺段（没有 bvid 或没有 cid）时 markDone 会自己跳过，
      // 但那样这条收口就没留任何痕迹 —— 用户主动动作的失败必须可取证。
      AppLogger.log('BILI', '收口了但台账记不下去（键组不完整）：${info.outBase}');
      return;
    }
    if (!biliSettlesAsDownloaded(info.kind)) {
      AppLogger.log(
        'BILI',
        '合并没收口，台账保持「在下」不转已下载：${info.outBase}'
        ' —— ${info.message}'
        '${info.commandLine == null ? '' : '\n  可复现命令：${info.commandLine}'}',
      );
      return;
    }
    final hash = ledger.hashOf(key);
    unawaited(
      ledger.markDone(
        [key],
        meta: {
          hash: (
            title: info.media.bili?.workTitle,
            author: info.media.userName,
          ),
        },
      ),
    );
    AppLogger.log(
      'BILI',
      '分 P 收口（${info.kind.name}）→ 台账记为已下载：${info.outBase}',
    );
  };
}
