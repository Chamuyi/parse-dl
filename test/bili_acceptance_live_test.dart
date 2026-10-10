import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/pages/bili_page.dart' show biliPartWithLabels;
import 'package:parse_dl/services/aria2.dart';
import 'package:parse_dl/services/aria2_coordinator.dart';
import 'package:parse_dl/services/app_logger.dart';
import 'package:parse_dl/services/app_paths.dart';
import 'package:parse_dl/services/bili_api.dart';
import 'package:parse_dl/services/bili_download_plan.dart';
import 'package:parse_dl/services/bili_ledger.dart';
import 'package:parse_dl/services/bili_ledger_bridge.dart';
import 'package:parse_dl/services/bili_link.dart';
import 'package:parse_dl/services/bili_merger.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/settings_store.dart';

/// 真机验收执行器：**扫码登录 → 取流 → aria2 下载 → ffmpeg 合并 → 台账收口**。
///
/// 为什么要扫码而不是复用外部浏览器的登录态：验收要看的是**这个程序**产出的文件。
/// 从外部把接口 JSON 搬进来跑，测的就只剩选流与命名，下载链路（`BiliApi` 的
/// 签名与重试、协调器的配对与收口、合并、台账时序）全在搬运那一步被绕开了。
///
/// 凭据纪律（这条是这个文件存在的主要约束）：
///   * 登录态只来自 `qrcodePoll` 响应的 **set-cookie 头**，拼成字符串后只进
///     [BiliApi.setCookie] 那个内存字段；不写文件、不打日志、不进异常文本，
///     进程退出即消失。
///   * 下载阶段 **不带 cookie**：这是产品自己的口径（aria2 的 per-task header
///     会被 `--save-session` 原样写盘，见 `_requestOptions` 的注释与实测）。
///     所以登录态只在「问接口要哪些流」这一步用到，拿到地址就用不上了。
///
/// 只在环境变量给出验收目录时才跑（`PD_BILI_ACCEPT`），否则整个文件跳过 ——
/// 它要真人扫码、要外网、要落几百 MB 文件，不能混进日常回归。
///
///     PD_BILI_ACCEPT=F:/qoder/_tools/bili/live \
///       flutter test test/bili_acceptance_live_test.dart
///
/// `PD_BILI_SMOKE=1`：不扫码、匿名只取 480P、且只跑前 [kBiliSmokePicks] 条。
/// 存在的理由是**登录这一步要人在屏幕前点确认**，而等待窗口里我应该先把
/// 「取流之后那段」（aria2 起进程、两条流入队、收口、ffmpeg 合并、台账）
/// 跑通一遍 —— 那半段与登录态无关，出错却不该等到他点完确认才暴露。
/// 它**不是**验收本身：档位是匿名的，题面要的随机高清档位仍要登录那一跑。
void main() {
  const int kBiliSmokePicks = 2;
  final live = Platform.environment['PD_BILI_ACCEPT'];
  final smoke = Platform.environment['PD_BILI_SMOKE'] == '1';

  test(
    '真机验收：主页推荐随机 9 条 × 3 轮随机档位',
    timeout: const Timeout(Duration(minutes: 45)),
    skip: live == null ? '没给 PD_BILI_ACCEPT，验收执行器不跑' : false,
    () async {
      // **刻意不初始化 TestWidgetsFlutterBinding**：那个 binding 会把所有
      // `HttpClient` 请求直接打回 400（Flutter 为可重放测试做的拦截），
      // 一整条真网络链路就假掉了 —— 表现为 `qrcode/generate -> 400`，
      // 看着像 B 站限流，其实一行 binding 的事。
      // 代价是 `rootBundle` 不可用，所以随包二进制改成下面预先落盘。
      final liveDir = Directory(live!);
      final outDir = Directory(smoke
          ? '${liveDir.path}/smoke'
          : (Platform.environment['PD_BILI_OUT'] ?? '${liveDir.path}/out'));
      if (!outDir.existsSync()) outDir.createSync(recursive: true);

      await AppPaths.init(exeDirOverride: outDir, fallbackOverride: outDir);
      await AppLogger.init(enabled: true);

      // 把**同一份**随包二进制预先放到程序会释放它的位置。
      //
      // 「从 bundle 释放」那段靠的是打包后的资产清单，`flutter test` 里没有那份清单；
      // 预先落好之后 `_ensureSidecar` / `ensureBiliFfmpeg` 的「已存在就不重复释放」
      // 分支接得住，后面启动 aria2、起 ffmpeg 合并仍全是生产代码。
      // 释放动作本身由出包那边的校验（`verify_release.py`）管，不在这里验。
      for (final name in const ['aria2c.exe', 'ffmpeg.exe']) {
        final dst = File('${AppPaths.configDir.path}\\$name');
        if (dst.existsSync()) continue;
        for (final base in const [
          'F:\\parse-dl\\assets',
          'D:\\app\\Bili23 Downloader\\bundle',
        ]) {
          final cand = File('$base\\$name');
          if (!cand.existsSync()) continue;
          dst.parent.createSync(recursive: true);
          cand.copySync(dst.path);
          break;
        }
      }

      final picked = (jsonDecode(
        File('${liveDir.path}/picked.json').readAsStringSync(),
      ) as List)
          .cast<Map<String, dynamic>>();
      final todo = smoke ? picked.take(kBiliSmokePicks).toList() : picked;
      if (smoke) {
        // 匿名冒烟只验「取流之后那段」，所以档位压到 480P（匿名的上限）。
        // 留着 720P/4K 的话选流层按「这一档要登录/要大会员」判不可用，
        // 一条都投不出去 —— 那不是链路通了，那是根本没跑到链路。
        for (final m in todo) {
          m['quality'] = '480p';
          m['codec'] = 'avc';
        }
      }

      final api = BiliApi();
      // 预取模式：`view` / `playurl` 的响应由**浏览器页内**取回来落在目录里
      // （带 cookie 的 dart:io 请求会被 B 站 WAF 打成验证页，实测见文件头），
      // 本执行器只负责它之后的每一步：解析 → 选流 → 命名 → aria2 → 合并 → 台账。
      final preplan = Platform.environment['PD_BILI_PREPLAN'];
      final envCookie = Platform.environment['PD_BILI_COOKIE'] ?? '';
      final bool login;
      if (preplan != null && preplan.isNotEmpty) {
        stdout.writeln('LOGIN skipped（预取模式：$preplan）');
        login = true;
      } else if (envCookie.isNotEmpty) {
        // 登录态由外部进程经**环境变量**交进来：只活在本进程的内存里，
        // 不写盘、不打值、不进日志（只报字节数，够定位「拿没拿到整串」），
        // 进程退出即消失。走这条路是因为扫码那 180 秒的窗口不适合无人值守。
        api.setCookie(envCookie);
        stdout.writeln('LOGIN env bytes=${envCookie.length}');
        login = true;
      } else if (Platform.environment['PD_BILI_ANON'] == '1') {
        // 匿名档：480P/360P 本来就是匿名的上限，要验这一档不需要登录态。
        // 做成显式开关，是为了不让人把「扫码没成功」误当成「匿名跑通了」。
        stdout.writeln('LOGIN skipped（匿名：只拿得到 480P/360P）');
        login = true;
      } else {
        login = smoke || await _scanLogin(api, liveDir);
      }
      expect(login, isTrue, reason: '没拿到登录态，验收跑不了登录档位');

      final store = DownloadStore()..setSaveDir(outDir.path);
      final settings = SettingsStore();
      final ledger = BiliLedger();
      // 合并用的 ffmpeg 显式指到**已落盘的那一份**（上面 seed 循环放的）。
      // 不指的话 `ensureBiliFfmpeg()` 在 flutter test 里 rootBundle 不可用，
      // 会退回按 `Platform.resolvedExecutable` 猜候选 —— 那在测试里是 flutter
      // 引擎的 artifacts 目录，里面根本没有 ffmpeg.exe，表现就是 9 对裸流
      // 全报 `ffmpegMissing`、一条 mp4 都不出。
      final coordinator = Aria2Coordinator.withAria2(
        Aria2(),
        biliMerger: BiliMerger(
          ffmpegPath: '${AppPaths.configDir.path}\\ffmpeg.exe',
        ),
      );
      await coordinator.bootstrap(store: store, settings: settings);
      expect(coordinator.booted, isTrue, reason: 'aria2 没起来（随包 aria2c.exe 没释放成功？）');

      // 收口回调：先接生产的台账绑定，再套一层自己的记录 —— 台账时序
      // （「合并成功之后才转 done」）必须原样是产品那条，不能被测试替身顶掉。
      final settled = <Map<String, dynamic>>[];
      bindBiliLedgerToSettled(coordinator, ledger);
      final toLedger = coordinator.onBiliSettled;
      coordinator.onBiliSettled = (info) {
        settled.add(<String, dynamic>{
          'kind': info.kind.name,
          'outBase': info.outBase,
          'saveDir': info.saveDir,
          'bvid': info.media.bili?.bvid,
          'cid': info.media.bili?.cid,
          'message': info.message,
        });
        toLedger?.call(info);
      };

      final report = <Map<String, dynamic>>[];
      var submitted = 0;
      for (final e in picked) {
        final round = e['round'] as int;
        final bvid = e['bvid'] as String;
        final cid = e['cid'] as int;
        final cfg = BiliConfig(
          quality: BiliQuality.fromId(e['quality'] as String),
          codec: BiliCodec.fromId(e['codec'] as String),
          mergeAfterDownload: e['merge'] as bool,
          skipDownloaded: false, // 9 条互不相同，跳过逻辑本身另有单测钉着
          saveDirBase: outDir.path,
          enableSaveFolder: (e['dirTemplate'] as String).isNotEmpty,
          dirTemplate: e['dirTemplate'] as String,
          fileNameTemplate: e['fileNameTemplate'] as String,
          concurrency: e['concurrency'] as int,
          // 真机验限速用的开关：单测只能证明我们把 option 递出去了，
          // 「aria2 收不收这个键」只有真进程能回答（不收的话是 addUri 直接报错）。
          speedLimitKbps:
              int.tryParse(Platform.environment['PD_BILI_SPEED'] ?? '') ?? 0,
        );
        final row = <String, dynamic>{
          'round': round,
          'pick': e['pick'],
          'bvid': bvid,
          'cid': cid,
          'wantQuality': cfg.quality.id,
          'wantCodec': cfg.codec.id,
          'merge': cfg.mergeAfterDownload,
          'nameTemplate': cfg.fileNameTemplate,
          'dirTemplate': cfg.dirTemplate,
        };
        try {
          await coordinator.applyConcurrency(cfg.concurrency);
          final tag = 'r${round}_p${e['pick']}';
          final bool usePre = (preplan ?? '').isNotEmpty;
          Map<String, dynamic> preData(String kind) => (jsonDecode(
                File('$preplan/${kind}_$tag.json').readAsStringSync(),
              ) as Map<String, dynamic>)['data'] as Map<String, dynamic>;
          final view = File('$preplan/view_$tag.json').existsSync()
              ? BiliVideoView.fromJson(preData('view'))
              : await api.view(bvid: bvid);
          final pg = view.pages.firstWhere(
            (p) => p.cid == cid,
            orElse: () => view.pages.isEmpty
                ? const BiliPage(
                    cid: 0, index: 1, partTitle: '', durationMs: 0, pic: '')
                : view.pages.first,
          );
          final part = biliPartMedia(
            bvid: view.bvid,
            aid: view.aid,
            workTitle: view.title,
            upperName: view.upperName,
            upperMid: view.upperMid,
            publishTime: view.publishTime,
            cover: pg.pic.isNotEmpty ? pg.pic : view.cover,
            partTotal: view.partTotal,
            partIndex: pg.index,
            cid: pg.cid,
            partTitle: pg.partTitle,
            durationMs: pg.durationMs,
          );
          final r = usePre
              ? BiliPlayUrl.fromJson(preData('play'),
                  cid: cid, preferredCodec: cfg.codec)
              : await api.playurl(
                  cid: cid,
                  qn: cfg.quality.qn,
                  codec: cfg.codec,
                  bvid: bvid,
                  aid: view.aid,
                );
          final pair = planBiliStreams(r, cfg.quality, cfg.codec);
          row['gotQn'] = r.currentQn;
          row['usable'] = pair.usable;
          if (!pair.usable) {
            row['why'] = pair.message;
            report.add(row);
            continue;
          }
          final labeled = biliPartWithLabels(
            part,
            videoQn: pair.videoQn,
            codec: pair.videoCodec,
            r: r,
          );
          final base = Aria2Coordinator.biliOutBase(
            cfg.fileNameTemplate, labeled, cfg);
          final medias = biliPairToMedias(part: labeled, pair: pair);
          final res = await coordinator.enqueueBiliMedia(
            medias.video,
            // durl 退化路径没有第二条流：给一条 url 为空的占位，
            // 协调器据此走「投一条、不建配对、不合并」（与页面里
            // `_noStreamAudio(part)` 同一形态 —— 分 P 那层的 url 本来就是空串）。
            medias.audio ?? part,
            base,
            cfg,
          );
          row['outcome'] = res.outcome.name;
          row['base'] = base;
          row['outPath'] = res.outPath;
          row['note'] = res.message;
          if (res.outcome == EnqueueOutcome.queued) {
            submitted++;
            await ledger.markPending([
              biliPartKey(bvid: labeled.bili?.bvid, cid: labeled.bili?.cid),
            ]);
          }
        } catch (err) {
          row['error'] = '$err';
        }
        report.add(row);
        _writeJson('${liveDir.path}/run_report.json', {
          'submitted': submitted,
          'settled': settled,
          'rows': report,
        });
      }

      // 等收口：合并是异步的，每条最多再等 6 分钟（4K 那条要久一些）。
      final deadline = DateTime.now().add(const Duration(minutes: 36));
      while (settled.length < submitted && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      _writeJson('${liveDir.path}/run_report.json', {
        'submitted': submitted,
        'settledCount': settled.length,
        'settled': settled,
        'rows': report,
        'finishedAt': DateTime.now().toIso8601String(),
      });
      stdout.writeln('ACCEPT submitted=$submitted settled=${settled.length}');

      coordinator.dispose();
      await AppLogger.dispose();

      expect(submitted, greaterThan(0), reason: '一条都没投出去，看 run_report.json 的 rows');
      expect(settled.length, submitted,
          reason: '投出去 $submitted 条只收口 ${settled.length} 条（超时或失败）');
    },
  );
}

/// 扫码登录：出码 → 轮询 → 过期就换码重出。
///
/// 窗口给得很宽（24 张 ≈ 80 分钟）：这张码要人在屏幕前点确认，
/// 而人什么时候回来不是代码能决定的。收紧到几张就会出现「码刚好在他回来前
/// 全部过期、执行器自己判失败」的假故障 —— 那既不是产品缺陷也不是他没点上。
///
/// 码的内容写进 `live/qr.txt`（那张码只在这个链接里，谁拿到都能登，
/// 所以它和 cookie 一样短命：验收结束由外层脚本删掉整个 live 目录）。
Future<bool> _scanLogin(BiliApi api, Directory liveDir) async {
  for (var attempt = 1; attempt <= 24; attempt++) {
    final BiliQr qr;
    try {
      qr = await api.qrcodeGenerate();
    } catch (e) {
      // 连续换码会被 passport 打回 400（限流）。这里不能让它掀掉整轮验收：
      // 退 25 秒再要一张，实在要不到就当这一张没出。
      stdout.writeln('QR_GENERATE_FAILED attempt=$attempt $e');
      await Future<void>.delayed(const Duration(seconds: 25));
      continue;
    }
    File('${liveDir.path}/qr.txt')
        .writeAsStringSync('${qr.url}\n${qr.qrcodeKey}\n', flush: true);
    stdout.writeln('QR_READY attempt=$attempt url=${qr.url}');
    final until = DateTime.now().add(const Duration(minutes: 3, seconds: 20));
    while (DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final BiliQrStatus st;
      try {
        st = await api.qrcodePoll(qr.qrcodeKey);
      } catch (e) {
        stdout.writeln('QR_POLL_FAILED $e');
        continue;
      }
      if (st.code == 0) {
        final cookie = _joinCookies(st.setCookieHeaders);
        if (cookie.isEmpty) {
          stdout.writeln('LOGIN code=0 但没有 set-cookie，换一张码');
          break;
        }
        api.setCookie(cookie);
        // 只报「拿到几个字段」，值一个都不打。
        stdout.writeln('LOGIN ok fields=${cookie.split(';').length}');
        return true;
      }
      if (st.code == 86038) {
        stdout.writeln('QR_EXPIRED attempt=$attempt');
        break;
      }
    }
  }
  stdout.writeln('LOGIN failed');
  return false;
}

String _joinCookies(List<String> headers) {
  final out = <String>[];
  for (final h in headers) {
    final pair = h.split(';').first;
    if (pair.contains('=')) out.add(pair.trim());
  }
  return out.join('; ');
}

void _writeJson(String path, Object data) {
  File(path).writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert(data),
    flush: true,
  );
}
