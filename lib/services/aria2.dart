import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'app_paths.dart';

/// aria2 任务状态
enum AriaStatus {
  waiting('waiting'),
  active('active'),
  paused('paused'),
  error('error'),
  complete('complete'),
  removed('removed');

  const AriaStatus(this.id);
  final String id;

  static AriaStatus fromId(String? id) => AriaStatus.values.firstWhere(
    (s) => s.id == id,
    orElse: () => AriaStatus.waiting,
  );
}

/// aria2 任务（只取用得到的字段）
class AriaTask {
  final String gid;
  final AriaStatus status;
  final int completeSize;
  final int totalSize;
  final String fileName;
  final String dir;
  final String error;

  AriaTask({
    required this.gid,
    required this.status,
    required this.completeSize,
    required this.totalSize,
    required this.fileName,
    required this.dir,
    required this.error,
  });

  factory AriaTask.fromJson(Map<String, dynamic> j) {
    final files = (j['files'] as List?) ?? const [];
    final firstPath = files.isNotEmpty
        ? (files.first as Map)['path'] as String? ?? ''
        : '';
    return AriaTask(
      gid: j['gid'] as String? ?? '',
      status: AriaStatus.fromId(j['status'] as String?),
      completeSize: int.tryParse('${j['completedLength'] ?? 0}') ?? 0,
      totalSize: int.tryParse('${j['totalLength'] ?? 0}') ?? 0,
      fileName: firstPath.split(RegExp(r'[\\/]')).last,
      dir: j['dir'] as String? ?? '',
      error: j['errorMessage'] as String? ?? '',
    );
  }
}

/// aria2 允许的 RPC 端口范围（aria2 自己强制的约束，
/// `--rpc-listen-port=0` 会被它拒绝）。
const int kAria2MinPort = 1024;
const int kAria2MaxPort = 65535;

/// 实例信息的心跳间隔（运行中定期刷新，证明「我还活着」）。
const Duration kAria2Heartbeat = Duration(seconds: 5);

/// 心跳超过这个时间没刷新 → 认定为上次崩溃留下的孤儿实例，下次启动时清理。
const Duration kAria2StaleAfter = Duration(seconds: 20);

/// 组装 aria2c 的启动参数。
///
/// **端口必须由调用方挑一个空闲的再传进来。** 实测（aria2 1.37.0）：
/// `--rpc-listen-port=0` 会被拒绝并直接退出
/// （`rpc-listen-port must be between 1024 and 65535`），
/// 所以「让系统随机分配端口」这条路走不通，只能 `ServerSocket.bind(0)`
/// 探一个空闲端口、立刻释放、再显式告诉 aria2。
///
/// [resumeSession] 为真时才带 `--input-file`：会话文件不存在时 aria2c 会
/// `Failed to open the file ...` 然后 exit(1)（实测），首次启动必须不带。
///
/// [parentPid] 是本应用的进程号，交给 aria2 的 `--stop-with-process`：
/// **父进程一消失，aria2c 自己退出** —— 这是「关窗 / 崩溃 / 被任务管理器强杀
/// 之后残留孤儿 aria2c」最硬的一道保险，不依赖任何退出回调能不能跑到。
List<String> aria2BootstrapArgs({
  required int port,
  required String secret,
  required String sessionFile,
  required bool resumeSession,
  required int parentPid,
}) {
  if (port < kAria2MinPort || port > kAria2MaxPort) {
    throw ArgumentError.value(
      port,
      'port',
      'aria2 只接受 $kAria2MinPort~$kAria2MaxPort',
    );
  }
  if (parentPid <= 0) {
    throw ArgumentError.value(parentPid, 'parentPid', '传 0/负数会让 aria2 立刻自杀');
  }
  return [
    '--enable-rpc',
    '--rpc-secret=$secret',
    '--rpc-listen-port',
    '$port',
    // 续传：明确打开。aria2 1.37 的默认值本来就是 true（`--help=#all` 里
    // 写着 `Default: true`），这里显式传是为了不被外部配置 / 以后改默认值影响。
    '--continue=true',
    // 会话：定时落盘 + 退出落盘。重启时用 `--input-file` 读回 ——
    // **会话文件里保留了 gid**，实测重启后 gid 与上次逐字一致
    // （`51ec7fcaf4c6efbd`），所以本地任务表能按 gid 重新绑定。
    '--save-session=$sessionFile',
    // `--save-session-interval` 才是「会话文件定期落盘」，
    // `--auto-save-interval` 管的是每个任务的 `.aria2` 控制文件。
    '--save-session-interval=30',
    '--auto-save-interval=30',
    // 父进程（本应用）没了就自杀 —— 不留孤儿进程。
    '--stop-with-process=$parentPid',
    // **引擎自己的重试次数与间隔。** 两个都不传时 aria2 用的是
    // `--max-tries=5 --retry-wait=0`，也就是「失败后立刻再试 5 次」。
    // 开机走 `--input-file` 时这个默认值最要命：会话里攒下来的死任务
    // （源站早已 404）会在几毫秒内各自跑完 5 次重试，每次都往日志里写
    // 一行「开始下载」+ 一行「下载失败」，而这一刻正是系统最忙的时候
    // （2026-10-02 装机版开机后 3 分 17 秒写了 12,396 行日志）。
    // 压到 3 次、每次间隔 2 秒：网络抖动仍有救，开机风暴有了上限。
    // aria2 只有固定间隔、没有指数退避，指数退避在应用层
    // （`aria2_coordinator.dart` 的 `retryBackoffDelay`）做。
    '--max-tries=3',
    '--retry-wait=2',
    // **停滞判据。** aria2 默认 `--lowest-speed-limit=0`（关闭），于是「TCP 连接还
    // 活着、但服务器一个字节都不吐」的下载永远不会被判失败 —— 2026-10-06 真机就
    // 有一条 474 MB 的抖音任务停在 246/474 MB、`downloadSpeed=0`，从 03:27 一直挂到
    // 21:50（18 小时），白占一个并发槽，界面上看就是「卡住」。
    // 2 KiB/s 这个下限对真实下载毫无影响（本机实测 1–57 MB/s），只用来掐死连接；
    // 掐掉后按上面的 max-tries 重连，`--continue` + `.aria2` 控制文件会从已下的
    // 位置续上，所以误判的代价只是一次重连，不丢数据。
    '--lowest-speed-limit=2K',
    if (resumeSession) '--input-file=$sessionFile',
  ];
}

/// 从 aria2c 的 stdout 里解析它**真正**监听的 RPC 端口。
///
/// 只认 `IPv4/IPv6 RPC: listening on TCP port N` 这一行；
/// 解析不到就返回 null —— 不能瞎猜一个端口去连。
int? parseRpcListenPort(String text) {
  final m = RegExp(r'(?:IPv4|IPv6) RPC: listening on TCP port (\d+)')
      .firstMatch(text);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// 上一次启动留下的 aria2c 实例信息 —— 用于清理**没退干净的自己**。
///
/// 只记 pid / port / secret / 心跳时间。清理时**不用 pid 去杀进程**
/// （PID 会被复用，有误杀无关进程的风险），而是拿 port + secret 去 RPC 探活：
/// 能应答 `aria2.getVersion` 的才认定为我们的 aria2c；再看心跳是否还新鲜，
/// 新鲜的说明**另一个实例正在运行**，不能去动它。
@immutable
class Aria2InstanceState {
  final int pid;
  final int port;
  final String secret;

  /// 最后一次心跳（每隔 [kAria2Heartbeat] 由运行中的实例刷新）。
  /// null 表示更早写下的文件 / 从没刷新过 —— 一律按「残留」处理。
  final DateTime? savedAt;

  const Aria2InstanceState({
    required this.pid,
    required this.port,
    required this.secret,
    this.savedAt,
  });

  /// 心跳已经过期（或干脆没有心跳）→ 这个实例多半已经不在了。
  ///
  /// 反过来说：心跳新鲜时**必须假设另一个实例正在运行**，
  /// 否则第二个实例启动时会把第一个实例的下载全部关掉。
  bool isStale(DateTime now, Duration threshold) {
    final at = savedAt;
    if (at == null) return true;
    return now.difference(at) > threshold;
  }

  String encode() => jsonEncode({
    'version': 1,
    'pid': pid,
    'port': port,
    'secret': secret,
    if (savedAt != null) 'savedAt': savedAt!.toIso8601String(),
  });

  /// 解析失败 / 字段非法一律返回 null：宁可不清理，也不能误杀无关进程。
  static Aria2InstanceState? decode(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return null;
      final pid = (v['pid'] as num?)?.toInt() ?? 0;
      final port = (v['port'] as num?)?.toInt() ?? 0;
      final secret = v['secret'] as String? ?? '';
      if (pid <= 0 || port <= 0 || secret.isEmpty) return null;
      return Aria2InstanceState(
        pid: pid,
        port: port,
        secret: secret,
        savedAt: DateTime.tryParse(v['savedAt'] as String? ?? ''),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'Aria2InstanceState(pid: $pid, port: $port)';
}

/// aria2 JSON-RPC 客户端。
///
/// 走 aria2 的 JSON-RPC 协议，调用形状如下：
///   1. 拉起 aria2c 子进程（`--enable-rpc`、随机 `--rpc-secret`、
///      **每次启动现挑的空闲端口**、`--continue` + `--save-session`）
///   2. 等它输出 "IPv4 RPC: listening on TCP port"
///   3. 连接 `ws://127.0.0.1:<port>/jsonrpc`
///   4. 每次调用的第一个参数带上 `token:` 加密钥
///
/// 两处关键设计（都是为了「退出后残留进程让下载永久损坏」）：
///   - 端口不再写死 6801：残留的旧进程占不住新端口，启动不会再被拖死；
///   - 启动前用 [Aria2InstanceState] 探活并关掉上次没退干净的自己。
class Aria2 {
  final String _secret = const Uuid().v4();
  Process? _child;
  WebSocketChannel? _ws;
  bool _ready = false;
  bool _disposed = false;
  int _invokeId = 0;
  final Map<int, void Function(Map<String, dynamic>)> _callbacks = {};
  Map<String, String> _globalOptions = {};

  /// 本次实际使用的 RPC 端口（启动时现挑，见 [bootstrap]）。
  int _port = 0;
  int get port => _port;

  /// aria2 自己的会话文件（未完成任务清单），与 sidecar 同目录。
  File? _sessionFile;

  /// 我们自己的实例信息（pid / port / secret），供下次启动清理残留。
  File? _stateFile;

  /// 心跳：定期刷新实例信息，让「另一个实例正在跑」这件事可被识别。
  Timer? _heartbeat;

  bool get ready => _ready;

  // ── 事件流 ───────────────────────────────────────────────
  final _downloadStart = StreamController<String>.broadcast();
  final _downloadPause = StreamController<String>.broadcast();
  final _downloadStop = StreamController<String>.broadcast();
  final _downloadComplete = StreamController<String>.broadcast();
  final _downloadError = StreamController<String>.broadcast();

  Stream<String> get onDownloadStart => _downloadStart.stream;
  Stream<String> get onDownloadPause => _downloadPause.stream;
  Stream<String> get onDownloadStop => _downloadStop.stream;
  Stream<String> get onDownloadComplete => _downloadComplete.stream;
  Stream<String> get onDownloadError => _downloadError.stream;

  String get _tokenParam => 'token:$_secret';

  /// 把打包进 assets 的 aria2c.exe 释放到磁盘，返回可执行文件路径。
  ///
  /// 资源在 Flutter 里是打包进 bundle 的，不能直接执行，必须先落盘。
  /// 同时在这里定下会话文件与实例信息文件的位置（同目录）。
  Future<String> _ensureSidecar() async {
    final dir = AppPaths.configDir;
    final target = File('${dir.path}\\aria2c.exe');
    _sessionFile = File('${dir.path}\\aria2.session');
    _stateFile = File('${dir.path}\\aria2.state.json');

    if (!await target.exists()) {
      final data = await rootBundle.load('assets/aria2c.exe');
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return target.path;
  }

  Future<void> bootstrap() async {
    if (_ready) return;

    final exePath = await _ensureSidecar();

    // 先清掉上次没退干净的自己（崩溃 / 强杀 / 任务管理器结束进程）。
    await _reapStaleInstance();

    // 换端口重试：`_pickFreePort()` 释放端口与 aria2 重新绑定之间，
    // 理论上可能被别的进程抢走（概率极低，但代价只是重来一次）。
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      final port = await _pickFreePort();
      try {
        await _startOnce(exePath, port);
        _port = port;
        await _connectWebSocket(port);
        _ready = true;
        await _writeStateFile();
        _heartbeat = Timer.periodic(
          kAria2Heartbeat,
          (_) => unawaited(_writeStateFile()),
        );
        return;
      } catch (e) {
        lastError = e;
        debugPrint('[aria2] 第 ${attempt + 1} 次启动失败：$e');
        await _stopChild();
      }
    }
    throw StateError('aria2c 启动失败（已换端口重试 3 次）：$lastError');
  }

  /// 让系统分配一个空闲端口，然后**立刻释放**。
  ///
  /// aria2 不能自己选端口（`--rpc-listen-port=0` 被拒），所以只能这样探。
  static Future<int> _pickFreePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  Future<void> _startOnce(String exePath, int port) async {
    final session = _sessionFile!;
    // 会话文件不存在时**不能**传 --input-file：aria2c 会直接 exit(1)（实测）。
    final resume = await session.exists();

    _child = await Process.start(
      exePath,
      aria2BootstrapArgs(
        port: port,
        secret: _secret,
        sessionFile: session.path,
        resumeSession: resume,
        parentPid: pid,
      ),
      workingDirectory: File(exePath).parent.path,
    );

    // 等 RPC 端口就绪
    final readyCompleter = Completer<void>();
    _child!.stdout.transform(utf8.decoder).listen((chunk) {
      final actual = parseRpcListenPort(chunk);
      if (actual == null || readyCompleter.isCompleted) return;
      if (actual != port) {
        // 不该发生；真发生了就如实记下来，别让后面的连接悄悄连错端口
        debugPrint('[aria2] 实际监听端口 $actual != 请求的 $port');
      }
      readyCompleter.complete();
    });
    _child!.stderr.transform(utf8.decoder).listen((chunk) {
      debugPrint('[aria2] $chunk');
    });
    _child!.exitCode.then((code) {
      if (!readyCompleter.isCompleted) {
        readyCompleter.completeError(StateError('aria2c 退出，代码 $code'));
      }
      _ready = false;
    });

    await readyCompleter.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw StateError('aria2c 启动超时'),
    );
  }

  Future<void> _connectWebSocket(int port) async {
    final ws = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port/jsonrpc'),
    );
    await ws.ready;
    _ws = ws;

    ws.stream.listen(
      _onMessage,
      onError: (e) {
        debugPrint('[aria2] ws error: $e');
        _ready = false;
      },
      onDone: () {
        // 早期实现只处理了 onError：连接被对端正常关闭（aria2 重启 / shutdown）
        // 时 `_ready` 仍是 true，之后每次调用都要等满 30 秒超时。
        debugPrint('[aria2] ws 已关闭');
        _ready = false;
      },
    );
  }

  // ── 实例信息：写 / 探活 / 清理 ──────────────────────────────

  Future<void> _writeStateFile() async {
    final f = _stateFile;
    final child = _child;
    if (f == null || child == null) return;
    try {
      await f.writeAsString(
        Aria2InstanceState(
          pid: child.pid,
          port: _port,
          secret: _secret,
          savedAt: DateTime.now(),
        ).encode(),
        flush: true,
      );
    } catch (e) {
      debugPrint('[aria2] 写实例信息失败：$e');
    }
  }

  /// 关掉上一次遗留下来的 aria2c。
  ///
  /// 判定分两步（**都不依赖 pid**：PID 会被系统复用，照 pid 杀可能误伤无关进程）：
  ///   1. 用上次的端口 + 密钥问 `aria2.getVersion` —— 能应答才是我们的 aria2c；
  ///   2. 看心跳是否过期 —— 心跳新鲜的说明**另一个实例正在运行**，
  ///      那就只跳过、不动它（多开时不能互相残杀）。
  Future<void> _reapStaleInstance() async {
    final f = _stateFile;
    if (f == null || !await f.exists()) return;

    final state = Aria2InstanceState.decode(await f.readAsString());
    if (state == null) {
      await _deleteQuietly(f);
      return;
    }

    if (!state.isStale(DateTime.now(), kAria2StaleAfter)) {
      debugPrint(
        '[aria2] 检测到另一个实例仍在运行'
        '（pid=${state.pid}, port=${state.port}，心跳未过期），跳过清理',
      );
      return;
    }

    if (await _isOurInstance(state.port, state.secret)) {
      debugPrint(
        '[aria2] 发现上次遗留的 aria2c'
        '（pid=${state.pid}, port=${state.port}），正在关闭',
      );
      await _rpcHttp(state.port, state.secret, 'aria2.shutdown');
    }
    await _deleteQuietly(f);
  }

  /// 这个端口上跑的到底是不是我们的 aria2c？
  ///
  /// 密钥是每次启动随机生成的、只存在于本机实例信息文件里，
  /// 所以「能拿着它问出 `aria2.getVersion`」就是足够强的证据。
  static Future<bool> _isOurInstance(int port, String secret) async {
    final r = await _rpcHttp(
      port,
      secret,
      'aria2.getVersion',
      timeout: const Duration(milliseconds: 800),
    );
    return r != null && r['version'] != null;
  }

  /// 一次性 HTTP JSON-RPC 调用（不走常驻 WebSocket）。
  ///
  /// 用于「aria2 还没起来 / 上次的进程还活着」这两种 WebSocket 用不了的情况。
  static Future<Map<String, dynamic>?> _rpcHttp(
    int port,
    String secret,
    String method, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 600);
    try {
      final req = await client
          .postUrl(Uri.parse('http://127.0.0.1:$port/jsonrpc'))
          .timeout(timeout);
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 'probe',
          'method': method,
          'params': ['token:$secret'],
        }),
      );
      final resp = await req.close().timeout(timeout);
      final text = await resp.transform(utf8.decoder).join().timeout(timeout);
      final v = jsonDecode(text);
      if (v is! Map) return null;
      final result = v['result'];
      return result is Map ? result.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _deleteQuietly(File? f) async {
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 结束当前子进程（启动重试之间用）。
  Future<void> _stopChild() async {
    _ready = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    try {
      await _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    final child = _child;
    _child = null;
    if (child != null) {
      try {
        child.kill();
      } catch (_) {}
    }
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[aria2] 解析消息失败: $e');
      return;
    }

    if (data['id'] != null) {
      final id = int.tryParse('${data['id']}') ?? -1;
      final cb = _callbacks.remove(id);
      cb?.call(data);
    } else if (data['method'] != null) {
      final params = data['params'] as List?;
      final gid = params != null && params.isNotEmpty
          ? (params.first as Map)['gid'] as String? ?? ''
          : '';
      _emit(data['method'] as String, gid);
    }
  }

  void _emit(String method, String gid) {
    switch (method) {
      case 'aria2.onDownloadStart':
        _downloadStart.add(gid);
      case 'aria2.onDownloadPause':
        _downloadPause.add(gid);
      case 'aria2.onDownloadStop':
        _downloadStop.add(gid);
      case 'aria2.onDownloadComplete':
        _downloadComplete.add(gid);
      case 'aria2.onDownloadError':
        _downloadError.add(gid);
    }
  }

  Future<dynamic> _invoke(String method, List<dynamic> params) {
    if (!_ready) throw StateError('aria2 尚未就绪');
    final id = _invokeId++;
    final completer = Completer<dynamic>();

    _callbacks[id] = (data) {
      if (data['error'] != null) {
        final msg = (data['error'] as Map)['message'];
        completer.completeError(StateError('aria2 调用 $method 失败：$msg'));
        return;
      }
      completer.complete(data['result']);
    };

    _ws!.sink.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': '$id',
        'method': method,
        'params': params,
      }),
    );

    return completer.future.timeout(const Duration(seconds: 30));
  }

  /// 带 token 的调用
  Future<dynamic> invoke(String method, [List<dynamic> args = const []]) =>
      _invoke(method, [_tokenParam, ...args]);

  /// 批量调用（system.multicall）
  Future<List<dynamic>> batchInvoke(
    List<({String method, List<dynamic> params})> payload,
  ) async {
    final result = await _invoke('system.multicall', [
      payload
          .map(
            (e) => {
              'methodName': e.method,
              'params': [_tokenParam, ...e.params],
            },
          )
          .toList(),
    ]);
    return (result as List).cast<dynamic>();
  }

  /// 查询单个任务
  Future<AriaTask> tellStatus(String gid) async {
    final r = await invoke('aria2.tellStatus', [gid]);
    return AriaTask.fromJson((r as Map).cast<String, dynamic>());
  }

  /// 批量查询任务，返回 gid → AriaTask
  Future<Map<String, AriaTask>> tellStatusBatch(List<String> gids) async {
    if (gids.isEmpty) return {};
    final results = await batchInvoke(
      gids
          .map((g) => (method: 'aria2.tellStatus', params: <dynamic>[g]))
          .toList(),
    );
    final map = <String, AriaTask>{};
    for (final item in results) {
      // multicall 每项形如 [ {..} ]
      final obj = item is List && item.isNotEmpty ? item.first : item;
      if (obj is Map) {
        final t = AriaTask.fromJson(obj.cast<String, dynamic>());
        if (t.gid.isNotEmpty) map[t.gid] = t;
      }
    }
    return map;
  }

  /// 添加下载任务，返回 gid。
  ///
  /// [options] 是 aria2 的**单任务**选项表，直接透传给 `aria2.addUri` 的第二个
  /// 参数 —— 本项目用来给抖音的下载带上来源头 `referer` / `user-agent`
  /// （抖音的部分 CDN 节点会校验请求来源，不带就不返回文件；这与浏览器在
  /// 页面里发起下载时自动带上来源头是同一回事）。刻意用单任务选项而不是全局选项，
  /// 避免污染 X 的下载。
  Future<String> addUri(
    String url, {
    required String dir,
    required String out,
    Map<String, String>? options,
  }) async {
    final r = await invoke('aria2.addUri', [
      [url],
      {'dir': dir, 'out': out, ...?options},
    ]);
    return r as String;
  }

  /// 批量添加下载任务，返回 gid 列表
  Future<List<String>> addUriBatch(
    List<({String url, String dir, String out})> items,
  ) async {
    if (items.isEmpty) return [];
    final results = await batchInvoke(
      items
          .map(
            (e) => (
              method: 'aria2.addUri',
              params: <dynamic>[
                [e.url],
                {'dir': e.dir, 'out': e.out},
              ],
            ),
          )
          .toList(),
    );
    return results.map((r) {
      final v = r is List && r.isNotEmpty ? r.first : r;
      return '$v';
    }).toList();
  }

  Future<void> pause(String gid) => invoke('aria2.pause', [gid]);
  Future<void> unpause(String gid) => invoke('aria2.unpause', [gid]);
  Future<void> pauseAll() => invoke('aria2.pauseAll');
  Future<void> unpauseAll() => invoke('aria2.unpauseAll');
  Future<void> remove(String gid) => invoke('aria2.remove', [gid]);

  Future<void> removeBatch(List<String> gids) => batchInvoke(
    gids.map((g) => (method: 'aria2.remove', params: <dynamic>[g])).toList(),
  );

  /// 合并写入**全局**选项（`aria2.changeGlobalOption`）。
  ///
  /// 传进来的项会被记住并一起下发 —— aria2 的 `changeGlobalOption`
  /// 是「增量设置」，但每次都要带完整的 options 对象才不会把上一次的项冲掉，
  /// 所以在 Dart 侧自己维护累积值。
  Future<void> applyGlobalOptions(Map<String, String> options) async {
    if (options.isEmpty) return;
    _globalOptions = {..._globalOptions, ...options};
    await invoke('aria2.changeGlobalOption', [_globalOptions]);
  }

  /// 设置全局代理
  Future<void> updateProxy(String proxyUrl) =>
      applyGlobalOptions({'all-proxy': proxyUrl});

  /// 最大同时下载数 —— 对应参照实现的「并发数」（`limit`，默认 4）。
  Future<void> updateConcurrency(int value) =>
      applyGlobalOptions({'max-concurrent-downloads': '$value'});

  /// 优雅退出：让 aria2 自己收尾（落盘会话文件、删掉 `.aria2` 控制文件），
  /// 超时再强杀。返回「确认进程已经不在」。
  ///
  /// **必须在窗口真正关闭之前调用** —— 否则 Dart VM 结束时子进程会变成
  /// 孤儿进程继续跑（实测到过那种进程，它会让下次启动再也下不动）。
  ///
  /// 超时刻意压得短（默认 2 秒 + 强杀后 1 秒）：这一步卡在关窗路径上，
  /// 用户点关闭后长期没反应比「少刷一次会话」更糟；会话文件还有
  /// `--auto-save-interval=30` 兜底。
  Future<bool> shutdown({Duration timeout = const Duration(seconds: 2)}) async {
    final child = _child;
    if (child == null) return true;

    if (_ready) {
      _ready = false;
      // **不 await**：这里只负责把「请退出」发出去。
      //
      // 回包本来就不保证送达（`_invoke` 默认超时 30 秒，等它能让关窗卡
      // 半分钟 —— 实测踩到过；后来限时 700ms，但那是**白白串行等**一次）。
      // 真正的判据是下面「子进程有没有退出」，所以让发指令和等退出
      // 并发进行：关窗从实测 2008ms 降到 ~1300ms。
      unawaited(_requestShutdownQuietly());
    }

    var exited = false;
    try {
      await child.exitCode.timeout(timeout);
      exited = true;
    } catch (_) {
      try {
        child.kill();
      } catch (_) {}
      try {
        await child.exitCode.timeout(const Duration(seconds: 1));
        exited = true;
      } catch (_) {}
    }
    _child = null;
    return exited;
  }

  /// 发一条「请优雅退出」就完事，**不关心回包**。
  ///
  /// 单拎出来是为了能不 await 地调用：退出与否由子进程的 exitCode 判定
  /// （见 [shutdown]），这里只负责把话带到 —— 发完立刻返回，
  /// 于是「等 aria2 收尾」那条线可以和它并行推进。
  Future<void> _requestShutdownQuietly() async {
    try {
      await invoke('aria2.shutdown').timeout(const Duration(milliseconds: 700));
    } catch (_) {
      // 超时 / 连不上：无所谓，退出与否由子进程兜底
    }
  }

  /// 退出：关 ws、优雅停掉子进程。返回「确认子进程已经不在」。
  ///
  /// 幂等 —— 退出钩子可能被触发不止一次（`onWindowClose` 与 dispose 兜底）。
  Future<bool> dispose() async {
    if (_disposed) return true;
    _disposed = true;

    _heartbeat?.cancel();
    _heartbeat = null;

    final stopped = await shutdown();
    try {
      await _ws?.sink.close();
    } catch (_) {}
    _ws = null;

    // 只有确认进程真的没了才删实例信息 —— 万一没杀干净，
    // 留着它下次启动还能被 `_reapStaleInstance()` 探活清理掉。
    if (stopped) await _deleteQuietly(_stateFile);

    await _downloadStart.close();
    await _downloadPause.close();
    await _downloadStop.close();
    await _downloadComplete.close();
    await _downloadError.close();
    return stopped;
  }
}
