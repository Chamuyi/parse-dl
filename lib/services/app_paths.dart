import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 数据目录决策（**全应用唯一入口**）。
///
/// 规则：**数据跟着软件走**。
///   1. 首选 `exe 同级\userdata` —— 软件装在哪个盘，设置/日志/台账/登录态就
///      在哪个盘，不往系统的 roaming 目录写；
///   2. 安装目录不可写时（典型：装进 `C:\Program Files` 且非管理员），
///      回退到系统给的应用数据目录，并把原因记在 [fallbackReason] 里，
///      界面上要如实告诉用户 —— 否则用户只会看到「设置又丢了」。
///
/// 为什么数据目录名不叫 `data`：Flutter 的可执行文件旁边已经有一个
/// `data\`（`data\flutter_assets`、`data\app.so`），那是**框架资源目录**，
/// 安装器卸载时会清理它。用户数据放进去会跟框架资源混在一起。
class AppPaths {
  AppPaths._();

  /// 数据目录名（exe 同级）
  static const String kDataDirName = 'userdata';

  /// 可写性探测用的临时文件名（探测完即删）
  static const String kWriteProbeName = '.writable-probe';

  static Directory? _root;
  static bool _fallback = false;
  static String? _fallbackReason;

  /// 是否已经 [init]
  static bool get ready => _root != null;

  /// 数据根目录（`init` 之后可用）
  static Directory get root {
    final r = _root;
    if (r == null) {
      throw StateError('AppPaths 还没初始化，请先在 main() 里 await AppPaths.init()');
    }
    return r;
  }

  /// 是否回退到了系统应用数据目录（即安装目录不可写）
  static bool get usingFallback => _fallback;

  /// 回退原因（未回退时为 null）
  static String? get fallbackReason => _fallbackReason;

  /// 配置文件目录（`settings.json` / `prefs.json` / `download_tasks.json` 同目录）
  static Directory get configDir => root;

  /// 日志目录
  static Directory get logsDir =>
      Directory('${root.path}${Platform.pathSeparator}logs');

  /// WebView2 用户数据目录（抖音登录态落在这里）
  static Directory get webviewDir =>
      Directory('${root.path}${Platform.pathSeparator}webview');

  /// 目录选择的**纯决策**部分，便于单测注入可写性。
  @visibleForTesting
  static AppPathsPlan plan({
    required Directory exeDir,
    required Directory fallbackDir,
    bool Function(Directory dir)? canWrite,
  }) {
    final probe = canWrite ?? _canWrite;
    final candidate = Directory(
        '${exeDir.path}${Platform.pathSeparator}$kDataDirName');
    if (probe(candidate)) {
      return AppPathsPlan(root: candidate, fallback: false);
    }
    return AppPathsPlan(
      root: fallbackDir,
      fallback: true,
      fallbackReason: '安装目录不可写（${candidate.path}），'
          '数据已回退到 ${fallbackDir.path}。'
          '把软件装到用户可写的盘（如 D:\\) 即可恢复「数据跟着软件走」。',
    );
  }

  /// 初始化（**必须在任何 store / 日志之前调用**）。
  ///
  /// [exeDirOverride] / [fallbackOverride] 仅供测试注入。
  static Future<void> init({
    Directory? exeDirOverride,
    Directory? fallbackOverride,
  }) async {
    // 先清掉上一次的状态：init 不该把上一轮的回退原因残留下来
    // （测试里连续 init 会串味，生产里若将来支持重启也会误导用户）。
    _fallback = false;
    _fallbackReason = null;

    final exeDir = exeDirOverride ?? File(Platform.resolvedExecutable).parent;
    final fallbackDir = fallbackOverride ?? await getApplicationSupportDirectory();

    final p = plan(exeDir: exeDir, fallbackDir: fallbackDir);
    _root = p.root;
    _fallback = p.fallback;
    _fallbackReason = p.fallbackReason;

    _ensureDir(p.root);
  }

  // ── 内部实现 ──────────────────────────────────────────────

  static void _ensureDir(Directory dir) {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (e) {
      debugPrint('[AppPaths] 建目录失败：${dir.path} — $e');
    }
  }

  /// 能不能在这个目录里真正写文件（只 exists 不够：Program Files 下
  /// 目录可能存在但没有写权限）。探测文件写完即删，不留垃圾。
  static bool _canWrite(Directory dir) {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final probe = File('${dir.path}${Platform.pathSeparator}$kWriteProbeName');
      probe.writeAsStringSync('probe', flush: true);
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// [AppPaths.plan] 的结果
@immutable
class AppPathsPlan {
  const AppPathsPlan({
    required this.root,
    required this.fallback,
    this.fallbackReason,
  });

  /// 选定的数据根目录
  final Directory root;

  /// 是否回退到了系统应用数据目录
  final bool fallback;

  /// 回退原因（展示给用户）
  final String? fallbackReason;
}
