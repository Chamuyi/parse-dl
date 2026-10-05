import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/services/aria2.dart';

/// S1 回归测试：aria2c 的**启动参数**与**残留实例清理**。
///
/// 现场（`aria2.dart:73,122-128`）：
///   - 端口写死 `static const _port = 6801;` —— 上一次没退干净的 aria2c
///     会把端口占住，于是 `bootstrap()` 抛错 → `Aria2Coordinator` 吞掉异常
///     → 之后**所有**入队都返回 notReady。用户看到「aria2 未启动，请稍候或
///     重启应用」，而重启根本没用（残留进程还在）。
///   - 启动参数只有 4 个，没有 `--continue` / `--save-session`，
///     退出即丢在途任务，半截文件被 aria2 存成 `xxx.1.mp4`。
///
/// 实测依据（`probe/aria2-session-probe.ps1` 的原始输出）：
///   1. `--rpc-listen-port=0` **不被接受**（`must be between 1024 and 65535`），
///      所以端口必须由我们自己挑一个空闲的再显式传进去；
///   2. `--save-session` 写出的会话文件**保留 `gid=`**，用 `--input-file`
///      重启后 gid 与上次完全一致（`51ec7fcaf4c6efbd`）—— 这是「任务表按 gid
///      重新绑定」成立的前提；
///   3. `--input-file` 指向**不存在**的文件时 aria2c 直接 exit(1)，
///      所以首次启动（还没有会话文件）绝不能不判断就传。
void main() {
  group('aria2BootstrapArgs', () {
    List<String> args({
      int port = 49152,
      String secret = 'sec',
      String session = r'C:\cfg\aria2.session',
      bool resume = false,
      int parentPid = 4242,
    }) =>
        aria2BootstrapArgs(
          port: port,
          secret: secret,
          sessionFile: session,
          resumeSession: resume,
          parentPid: parentPid,
        );

    test('端口必须显式传入，且不再是写死的 6801', () {
      final a = args(port: 49321);
      expect(a, contains('--rpc-listen-port'));
      expect(a[a.indexOf('--rpc-listen-port') + 1], '49321');
      expect(a.join(' '), isNot(contains('6801')),
          reason: '写死端口正是「残留进程占着 6801 导致永久无法下载」的根因');
    });

    test('端口非法时直接拒绝 —— aria2 只接受 1024~65535，传 0 它会退出', () {
      expect(() => args(port: 0), throwsArgumentError);
      expect(() => args(port: 80), throwsArgumentError);
      expect(() => args(port: 70000), throwsArgumentError);
    });

    test('续传相关参数齐全（否则退出即丢在途任务、半截文件变 xxx.1.mp4）', () {
      final a = args(session: r'C:\cfg\aria2.session');
      expect(a, contains('--continue=true'));
      expect(a, contains(r'--save-session=C:\cfg\aria2.session'));
      expect(a, contains('--auto-save-interval=30'));
      expect(a, contains('--rpc-secret=sec'));
      expect(a, contains('--enable-rpc'));
    });

    test('会话文件存在时才传 --input-file（不存在的文件会让 aria2c exit 1）', () {
      expect(args(resume: false).join(' '), isNot(contains('--input-file')));
      expect(args(resume: true), contains(r'--input-file=C:\cfg\aria2.session'));
    });

    test('绑上父进程 pid：应用被强杀 / 崩溃时 aria2c 也自己退出（不留孤儿）', () {
      // aria2 的 `--stop-with-process=PID`：父进程不在就自杀。
      // 这是「关窗后残留 aria2c」最硬的一道保险 —— 连任务管理器强杀都覆盖。
      expect(args(parentPid: 4242), contains('--stop-with-process=4242'));
    });

    test('父进程 pid 非法 → 拒绝（传 0 等于让 aria2 立刻自杀）', () {
      expect(() => args(parentPid: 0), throwsArgumentError);
      expect(() => args(parentPid: -1), throwsArgumentError);
    });

    test('会话文件定期落盘（默认只在退出时写，崩溃就全丢）', () {
      expect(args(), contains('--save-session-interval=30'));
    });
  });

  group('parseRpcListenPort', () {
    test('从 IPv4 就绪行里解析出真实端口', () {
      const line =
          '09/15 01:03:12 [NOTICE] IPv4 RPC: listening on TCP port 6899\n';
      expect(parseRpcListenPort(line), 6899);
    });

    test('只有 IPv6 就绪行时也能解析', () {
      const line =
          '09/15 01:03:12 [NOTICE] IPv6 RPC: listening on TCP port 6899\n';
      expect(parseRpcListenPort(line), 6899);
    });

    test('多行混在一起时取 RPC 那一行', () {
      const text = 'aria2 version 1.37.0\n'
          'Download progress: 0%\n'
          '09/15 01:03:12 [NOTICE] IPv4 RPC: listening on TCP port 49213\n';
      expect(parseRpcListenPort(text), 49213);
    });

    test('没有就绪行 → null（不能瞎猜一个端口去连）', () {
      expect(parseRpcListenPort(''), isNull);
      expect(parseRpcListenPort('[NOTICE] Download complete'), isNull);
      expect(parseRpcListenPort('IPv4 RPC: listening on TCP port'), isNull);
    });
  });

  group('Aria2InstanceState（残留实例的清理依据）', () {
    test('编码后能原样解回来', () {
      const s = Aria2InstanceState(pid: 1234, port: 49213, secret: 'abc');
      final back = Aria2InstanceState.decode(s.encode());
      expect(back, isNotNull);
      expect(back!.pid, 1234);
      expect(back.port, 49213);
      expect(back.secret, 'abc');
    });

    test('坏数据一律当「没有残留」—— 宁可不清理，也不能误杀无关进程', () {
      expect(Aria2InstanceState.decode(''), isNull);
      expect(Aria2InstanceState.decode('not json'), isNull);
      expect(Aria2InstanceState.decode('{}'), isNull);
      expect(Aria2InstanceState.decode('{"pid":0,"port":49213,"secret":"a"}'),
          isNull);
      expect(Aria2InstanceState.decode('{"pid":1,"port":0,"secret":"a"}'), isNull);
      expect(Aria2InstanceState.decode('{"pid":1,"port":49213,"secret":""}'),
          isNull);
    });

    test('心跳写进去、读得回来', () {
      final now = DateTime.now();
      final s = Aria2InstanceState(
          pid: 1234, port: 49213, secret: 'abc', savedAt: now);
      final back = Aria2InstanceState.decode(s.encode())!;
      expect(back.savedAt, isNotNull);
      expect(
        back.savedAt!.difference(now).inSeconds.abs(),
        lessThanOrEqualTo(1),
      );
    });

    test('心跳新鲜 = 另一个实例正在跑 → 不能当成残留去关掉它', () {
      final now = DateTime.now();
      final s = Aria2InstanceState(
        pid: 1234,
        port: 49213,
        secret: 'abc',
        savedAt: now.subtract(const Duration(seconds: 3)),
      );
      expect(s.isStale(now, const Duration(seconds: 20)), isFalse);
    });

    test('心跳过期 / 老格式没有心跳 → 认定为残留（崩溃后留下的孤儿）', () {
      final now = DateTime.now();
      expect(
        Aria2InstanceState(
          pid: 1234,
          port: 49213,
          secret: 'abc',
          savedAt: now.subtract(const Duration(minutes: 5)),
        ).isStale(now, const Duration(seconds: 20)),
        isTrue,
      );
      expect(
        const Aria2InstanceState(pid: 1234, port: 49213, secret: 'abc')
            .isStale(now, const Duration(seconds: 20)),
        isTrue,
        reason: '更早写下的文件没有心跳字段，应当作残留清理掉',
      );
    });
  });
}
