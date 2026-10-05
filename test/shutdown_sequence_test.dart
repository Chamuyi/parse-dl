import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/shutdown_guard.dart';

/// S1 回归测试：退出清理的**步骤编排**。
///
/// 为什么只测编排、不测 `onWindowClose()`：那个回调要 window_manager 的平台
/// 通道，单测里起不来。但真正容易写错、后果也最难看的部分恰好是编排 ——
/// 「某一步失败就把后面全跳掉」会让窗口留在屏幕上不退出，用户只会以为
/// 程序卡死（这比少清理一次严重得多）。
///
/// 判据：
///   1. 三步按序执行，`destroy` 一定在最后；
///   2. **中间任何一步抛错都不阻止后续步骤**，`destroy` 照样执行；
///   3. 每一步的失败都上报出去（能写进日志）。
void main() {
  test('按「存任务表 → 停 aria2 → 刷日志 → 销毁窗口」的顺序执行', () async {
    final order = <String>[];
    Future<void> step(String name) async => order.add(name);

    await runShutdownSequence(
      saveTasks: () => step('save'),
      stopAria2: () => step('aria2'),
      flushLogs: () => step('logs'),
      destroy: () => step('destroy'),
    );

    expect(order, ['save', 'aria2', 'logs', 'destroy']);
  });

  test('存任务表失败 → 后面照常，窗口仍然被销毁', () async {
    final order = <String>[];
    final errors = <String, Object>{};

    await runShutdownSequence(
      saveTasks: () async => throw StateError('磁盘满'),
      stopAria2: () async => order.add('aria2'),
      flushLogs: () async => order.add('logs'),
      destroy: () async => order.add('destroy'),
      onError: (step, e) => errors[step] = e,
    );

    expect(order, ['aria2', 'logs', 'destroy'], reason: '一步失败就卡住不关窗，用户会以为程序死机');
    expect(errors.keys, ['保存任务表']);
  });

  test('停 aria2 失败 → 日志照刷、窗口照样销毁', () async {
    final order = <String>[];
    final errors = <String, Object>{};

    await runShutdownSequence(
      saveTasks: () async => order.add('save'),
      stopAria2: () async => throw StateError('aria2 不理我'),
      flushLogs: () async => order.add('logs'),
      destroy: () async => order.add('destroy'),
      onError: (step, e) => errors[step] = e,
    );

    expect(order, ['save', 'logs', 'destroy']);
    expect(errors.keys, ['停止 aria2c']);
  });

  test('三步全炸 → 仍然销毁窗口（这是最后的底线）', () async {
    var destroyed = false;

    await runShutdownSequence(
      saveTasks: () async => throw StateError('x'),
      stopAria2: () async => throw StateError('y'),
      flushLogs: () async => throw StateError('z'),
      destroy: () async {
        destroyed = true;
      },
      onError: (_, _) {},
    );

    expect(destroyed, isTrue);
  });

  test('销毁窗口本身失败 → 错误向上抛（没有下一步可做了）', () async {
    await expectLater(
      runShutdownSequence(
        saveTasks: () async {},
        stopAria2: () async {},
        flushLogs: () async {},
        destroy: () async => throw StateError('destroy 失败'),
      ),
      throwsStateError,
    );
  });

  // ── 关窗「未响应」修复：先藏窗口，再慢慢清理 ────────────────
  //
  // 实测日志：用户点关闭后窗口僵在原地 2008ms（其中 700ms 是白等 RPC
  // 回包、1308ms 是等 aria2c 收尾），期间用户会再点一次关闭。
  // 修法是把窗口**立刻**从屏幕上拿掉，清理放到用户看不见的地方继续。

  test('隐藏窗口排在所有清理之前（用户先看到窗口消失）', () async {
    final order = <String>[];
    Future<void> step(String name) async => order.add(name);

    await runShutdownSequence(
      hideWindow: () => step('hide'),
      saveTasks: () => step('save'),
      stopAria2: () => step('aria2'),
      flushLogs: () => step('logs'),
      destroy: () => step('destroy'),
    );

    expect(order, [
      'hide',
      'save',
      'aria2',
      'logs',
      'destroy',
    ], reason: 'hide 必须是第一步，否则用户仍要盯着一个不动的窗口');
  });

  test('隐藏窗口失败 → 清理照常，窗口仍然被销毁', () async {
    final order = <String>[];
    final errors = <String, Object>{};

    await runShutdownSequence(
      hideWindow: () async => throw StateError('hide 失败'),
      saveTasks: () async => order.add('save'),
      stopAria2: () async => order.add('aria2'),
      flushLogs: () async => order.add('logs'),
      destroy: () async => order.add('destroy'),
      onError: (step, e) => errors[step] = e,
    );

    expect(order, [
      'save',
      'aria2',
      'logs',
      'destroy',
    ], reason: '窗口藏不掉更要继续关，不能因此反而关不掉');
    expect(errors.keys, ['隐藏窗口']);
  });

  test('不传 hideWindow 时编排不变（老调用点不受影响）', () async {
    final order = <String>[];
    Future<void> step(String name) async => order.add(name);

    await runShutdownSequence(
      saveTasks: () => step('save'),
      stopAria2: () => step('aria2'),
      flushLogs: () => step('logs'),
      destroy: () => step('destroy'),
    );

    expect(order, ['save', 'aria2', 'logs', 'destroy']);
  });
}
