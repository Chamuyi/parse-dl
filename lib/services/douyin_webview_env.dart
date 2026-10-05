import 'dart:io';

import 'package:webview_windows/webview_windows.dart';

import 'app_logger.dart';
import 'app_paths.dart';

/// 准备抖音页用的 WebView2 运行环境。
///
/// **必须在创建任何 [WebviewController] 之前调用**，而且**全局只能调一次** ——
/// 底层是 WebView2 的 `CreateCoreWebView2EnvironmentWithOptions`，
/// 环境一旦建好就不能再改用户数据目录。所以放在 `main()` 里、`runApp` 之前。
///
/// 把用户数据目录指到 [AppPaths.webviewDir]，也就是 `<数据目录>\webview`
/// （数据目录默认是 exe 同级的 `userdata`，安装目录不可写时才回退到
/// 系统应用数据目录 —— 规则只在 [AppPaths] 一处）：
///   - 抖音登录态（Cookie）落在这里 → 用户扫码登录**一次**即可长期有效；
///   - 不落在 WebView2 默认的 `%LOCALAPPDATA%\Microsoft\EdgeWebView`，
///     免得和应用自己的配置分家。
///
/// 返回用户数据目录；检测不到 WebView2 运行时或初始化失败时返回 `null`
/// （抖音页会自己显示「内嵌浏览器不可用」的占位面板）。
Future<String?> prepareDouyinWebViewEnvironment() async {
  try {
    final version = await WebviewController.getWebViewVersion();
    if (version == null) {
      AppLogger.log('DOUYIN', '未检测到 Edge WebView2 运行时，抖音页不可用');
      return null;
    }

    final dir = await _userDataDir();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    await WebviewController.initializeEnvironment(userDataPath: dir.path);
    AppLogger.log('DOUYIN', 'WebView2 $version；用户数据目录 = ${dir.path}');
    return dir.path;
  } catch (e) {
    // 已初始化过 / 运行时缺失 / 建目录失败都从这里出去，不阻塞启动
    AppLogger.log('DOUYIN', 'WebView2 环境初始化失败：$e');
    return null;
  }
}

/// WebView2 用户数据目录：数据目录下的 `webview\`（由 [AppPaths] 决定）。
///
/// 抖音登录态就落在这里，所以它必须跟着软件目录走（升级时由迁移逻辑带过来），
/// 否则用户每次升级都要重新扫码登录。
Future<Directory> _userDataDir() async => AppPaths.webviewDir;
