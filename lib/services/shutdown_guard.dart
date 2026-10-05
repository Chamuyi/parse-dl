import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'app_logger.dart';
import 'aria2_coordinator.dart';
import 'download_store.dart';

/// 退出清理里的一步。
typedef ShutdownStep = Future<void> Function();

/// 退出清理的步骤编排（与 window_manager / 单例解耦，便于单测）。
///
/// **每一步失败都只记录、不中断**：清理失败最多是「少存一次任务表 / 少刷几行
/// 日志」，而「因为清理失败就不关窗」会让用户看着一个点不掉的窗口以为程序死机。
/// 所以无论前面发生什么，[destroy] 都会被执行。
///
/// [destroy] 自身的失败会向上抛 —— 到这一步已经没有别的补救手段了。
Future<void> runShutdownSequence({
  ShutdownStep? hideWindow,
  required ShutdownStep saveTasks,
  required ShutdownStep stopAria2,
  required ShutdownStep flushLogs,
  required ShutdownStep destroy,
  void Function(String step, Object error)? onError,
}) async {
  void report(String name, Object e) {
    if (onError != null) {
      onError(name, e);
    } else {
      debugPrint('[ShutdownGuard] $name 失败：$e');
    }
  }

  // ⓪ **先把窗口从屏幕上拿掉**，再开始清理。
  //
  // 这一步专治「点关闭后窗口僵在那儿好几秒，看着像卡死」：
  // 用户点关闭的瞬间窗口就消失，而等 aria2c 收尾的那一两秒在后台跑，
  // 用户根本看不见。放在最前面，且**失败也继续清理** ——
  // 窗口藏不掉还是要关，不能因为这一步反而关不掉。
  if (hideWindow != null) {
    try {
      await hideWindow();
    } catch (e) {
      report('隐藏窗口', e);
    }
  }

  final steps = <(String, ShutdownStep)>[
    ('保存任务表', saveTasks),
    ('停止 aria2c', stopAria2),
    ('刷新日志', flushLogs),
  ];
  for (final (name, step) in steps) {
    try {
      await step();
    } catch (e) {
      report(name, e);
    }
  }
  await destroy();
}

/// 退出清理守卫：**在窗口真的销毁之前**把 aria2c 子进程与任务表收干净。
///
/// 为什么必须有它：没有退出钩子时 ——
/// `Aria2Coordinator.dispose()`（内部会 kill 子进程）与 `AppLogger.dispose()`
/// 都没有调用点。关窗只结束 Dart VM，随之被拉起的 `aria2c.exe` 就成了
/// **孤儿进程继续跑**：它占着下载文件、继续吃带宽，用户下次启动时如果端口
/// 对不上还会表现为「下载功能永久损坏」（实测到过父进程已消失的 aria2c）。
///
/// 安装方式（`main()` 里，窗口就绪之后）：
/// ```dart
/// await ShutdownGuard.install(downloadStore: downloadStore);
/// ```
/// 它会把 `preventClose` 打开，于是用户点关闭时窗口**不会**立刻销毁，
/// 而是走到 [onWindowClose] —— 清理完成后再 `destroy()`。
class ShutdownGuard with WindowListener {
  ShutdownGuard({required this.downloadStore});

  final DownloadStore downloadStore;

  /// 用户连点关闭 / 清理过程中再次触发时的护栏。
  bool _closing = false;

  /// 装到 windowManager 上（`preventClose` + 监听器）。
  static Future<void> install({required DownloadStore downloadStore}) async {
    await windowManager.setPreventClose(true);
    windowManager.addListener(ShutdownGuard(downloadStore: downloadStore));
    // 落一行日志：`preventClose` 是整条退出链路的开关，出问题时先查它。
    AppLogger.log(
      'APP',
      '退出钩子已安装；preventClose=${await windowManager.isPreventClose()}',
    );
  }

  @override
  void onWindowClose() {
    AppLogger.log('APP', '收到关闭窗口事件，开始退出清理');
    // WindowListener 的回调是同步的，清理是异步的 —— 这里不 await，
    // 清理完成后由 _run() 自己 destroy 窗口。
    unawaited(_run());
  }

  Future<void> _run() async {
    if (_closing) return;
    _closing = true;

    await runShutdownSequence(
      // ① **先把窗口藏起来**：用户点关闭的那一刻界面就消失。
      //    实测关窗要 2 秒（等 aria2c 收尾），这 2 秒窗口若还杵在那儿，
      //    用户会以为程序卡死并再点一次关闭 —— 藏起来就没这问题。
      hideWindow: () async {
        await windowManager.hide();
        // 落一行日志：这条与下面「任务表已保存」的**时间差**，就是
        // 用户看到窗口消失所需的时间（真机验证关窗感知时看它）。
        AppLogger.log('APP', '退出清理：窗口已隐藏');
      },
      saveTasks: () async {
        await downloadStore.save();
        AppLogger.log('APP', '退出清理：任务表已保存（${downloadStore.tasks.length} 条）');
      },
      stopAria2: () async {
        // 让 aria2 自己收尾（落盘会话文件、删掉 .aria2 控制文件）再退出。
        final stopped = await Aria2Coordinator.instance.dispose();
        AppLogger.log('APP', '退出清理：aria2c 已停止=$stopped');
      },
      flushLogs: () async {
        AppLogger.log('APP', '退出清理：完成，销毁窗口');
        await AppLogger.dispose();
      },
      destroy: () async {
        await windowManager.destroy();
        // 窗口销毁之后，引擎自己的拆解流程必然踩空：实测每次正常关窗约 3 秒后在
        // flutter_windows.dll+0x1e220 抛 c0000005、约 9 秒后补一个 c000041d，
        // 进程拖 14 秒才死，用户看到的是「关掉程序弹一次已停止工作」。
        // 跳过 WebView2 环境／亚克力材质／15 秒代理定时器都照样崩在同一偏移，
        // 所以不是我们某一步写错了，应用层只能不进那段拆解 —— 而到这里任务表
        // 已落盘、aria2c 确认真停、日志 sink 已关，直接结束进程不丢东西。
        // （WebView2 不归我们管：实测它在宿主退出后自己写完 EBWebView 才退。）
        if (Platform.isWindows) exit(0);
      },
      onError: (step, e) {
        debugPrint('[ShutdownGuard] $step 失败：$e');
        AppLogger.log('APP', '退出清理：$step 失败：$e');
      },
    );
  }
}
