import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../l10n/app_locale.dart';
import '../theme/window_material.dart';
import 'douyin_config.dart';

/// 代理设置
class ProxySettings {
  bool enable;
  String url;
  bool useSystem;

  ProxySettings({
    this.enable = true,
    this.url = 'http://127.0.0.1:7890',
    this.useSystem = true,
  });

  factory ProxySettings.fromJson(Map<String, dynamic> j) => ProxySettings(
    enable: j['enable'] as bool? ?? true,
    url: j['url'] as String? ?? 'http://127.0.0.1:7890',
    useSystem: j['useSystem'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'enable': enable,
    'url': url,
    'useSystem': useSystem,
  };
}

/// 下载设置
class DownloadSettings {
  String saveDirBase;
  String dirTemplate;
  String fileNameTemplate;
  bool sameFileSkip;

  DownloadSettings({
    this.saveDirBase = '',
    this.dirTemplate = '',
    this.fileNameTemplate =
        '%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%',
    this.sameFileSkip = true,
  });

  factory DownloadSettings.fromJson(Map<String, dynamic> j) => DownloadSettings(
    saveDirBase: j['saveDirBase'] as String? ?? '',
    dirTemplate: j['dirTemplate'] as String? ?? '',
    fileNameTemplate:
        j['fileNameTemplate'] as String? ??
        '%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%',
    sameFileSkip: j['sameFileSkip'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'saveDirBase': saveDirBase,
    'dirTemplate': dirTemplate,
    'fileNameTemplate': fileNameTemplate,
    'sameFileSkip': sameFileSkip,
  };
}

/// 应用设置
class AppOptions {
  bool autoCheckUpdate;
  bool acceptPrerelease;
  bool writeLogs;

  AppOptions({
    this.autoCheckUpdate = true,
    this.acceptPrerelease = false,
    this.writeLogs = false,
  });

  factory AppOptions.fromJson(Map<String, dynamic> j) => AppOptions(
    autoCheckUpdate: j['autoCheckUpdate'] as bool? ?? true,
    acceptPrerelease: j['acceptPrerelease'] as bool? ?? false,
    writeLogs: j['writeLogs'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'autoCheckUpdate': autoCheckUpdate,
    'acceptPrerelease': acceptPrerelease,
    'writeLogs': writeLogs,
  };
}

/// 外观设置
class AppearanceSettings {
  ThemeMode2 themeMode;
  WindowMaterial windowMaterial;
  bool customTint;

  /// 形如 #RRGGBB
  String tintColor;

  /// 背景图本地路径，空串表示未设置
  String backgroundImage;

  /// 背景图不透明度 0~1
  double backgroundImageOpacity;

  /// 主界面导航形态：悬浮 Dock / 常规侧边栏。
  /// 旧配置缺少该字段时回退到 [NavLayout.dock]。
  NavLayout navLayout;

  /// 侧边栏里各模块入口的展开状态（key = `NavGroup.id`，如 'x' / 'douyin'）。
  ///
  /// **缺省即收起**：只记"用户明确改过的那几个"，不存全部状态 ——
  /// 以后新增模块默认也是收起的，老配置不需要迁移。
  /// （2026-09-19 用户要求：侧边栏默认不要展开。）
  Map<String, bool> navGroupExpanded;

  /// 界面语言。默认跟随系统；旧配置没这个字段时也是跟随系统。
  AppLocale locale;

  AppearanceSettings({
    this.themeMode = ThemeMode2.system,
    this.windowMaterial = WindowMaterial.mica,
    this.customTint = false,
    this.tintColor = '#1d9bf0',
    this.backgroundImage = '',
    this.backgroundImageOpacity = 0.35,
    this.navLayout = NavLayout.dock,
    this.navGroupExpanded = const {},
    this.locale = AppLocale.system,
  });

  /// 某个模块入口当前是否展开（没记录过 = 收起）
  bool isNavGroupExpanded(String groupId) => navGroupExpanded[groupId] ?? false;

  /// 切换某个模块入口的展开状态。
  ///
  /// 只动传进来的那个 id —— 两个模块的展开状态互相独立，
  /// 展开/收起 A 不会顺带改变 B。
  void toggleNavGroup(String groupId) {
    navGroupExpanded = {
      ...navGroupExpanded,
      groupId: !isNavGroupExpanded(groupId),
    };
  }

  /// 读展开状态的持久化字段：不是 Map 就当没记过（全展开）。
  static Map<String, bool> _readExpandedMap(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries) e.key.toString(): e.value == true,
    };
  }

  factory AppearanceSettings.fromJson(Map<String, dynamic> j) =>
      AppearanceSettings(
        themeMode: ThemeMode2.fromId(j['themeMode'] as String?),
        windowMaterial: WindowMaterial.fromId(j['windowMaterial'] as String?),
        customTint: j['customTint'] as bool? ?? false,
        tintColor: j['tintColor'] as String? ?? '#1d9bf0',
        backgroundImage: j['backgroundImage'] as String? ?? '',
        backgroundImageOpacity:
            (j['backgroundImageOpacity'] as num?)?.toDouble() ?? 0.35,
        navLayout: NavLayout.fromId(j['navLayout'] as String?),
        navGroupExpanded: _readExpandedMap(j['navGroupExpanded']),
        locale: AppLocale.fromId(j['locale'] as String?),
      );

  Map<String, dynamic> toJson() => {
    'themeMode': themeMode.id,
    'windowMaterial': windowMaterial.id,
    'customTint': customTint,
    'tintColor': tintColor,
    'backgroundImage': backgroundImage,
    'backgroundImageOpacity': backgroundImageOpacity,
    'navLayout': navLayout.id,
    'navGroupExpanded': navGroupExpanded,
    'locale': locale.id,
  };
}

/// 顶层设置。
///
/// **配置文件只认 `{ state: {...}, version: 3 }` 这一种格式**，
/// 缺字段走默认值，多字段忽略。
class Settings {
  ProxySettings proxy;
  DownloadSettings download;
  AppOptions app;
  AppearanceSettings appearance;

  /// 抖音页的下载配置（对齐参照实现「下载设置」）。
  /// 旧配置缺该字段时用默认值，不影响升级。
  DouyinConfig douyin;

  Settings({
    ProxySettings? proxy,
    DownloadSettings? download,
    AppOptions? app,
    AppearanceSettings? appearance,
    DouyinConfig? douyin,
  }) : proxy = proxy ?? ProxySettings(),
       download = download ?? DownloadSettings(),
       app = app ?? AppOptions(),
       appearance = appearance ?? AppearanceSettings(),
       douyin = douyin ?? DouyinConfig();

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
    proxy: ProxySettings.fromJson(
      (j['proxy'] as Map?)?.cast<String, dynamic>() ?? {},
    ),
    download: DownloadSettings.fromJson(
      (j['download'] as Map?)?.cast<String, dynamic>() ?? {},
    ),
    app: AppOptions.fromJson((j['app'] as Map?)?.cast<String, dynamic>() ?? {}),
    appearance: AppearanceSettings.fromJson(
      (j['appearance'] as Map?)?.cast<String, dynamic>() ?? {},
    ),
    douyin: DouyinConfig.fromJson(
      (j['douyin'] as Map?)?.cast<String, dynamic>() ?? {},
    ),
  );

  Map<String, dynamic> toJson() => {
    'proxy': proxy.toJson(),
    'download': download.toJson(),
    'app': app.toJson(),
    'appearance': appearance.toJson(),
    'douyin': douyin.toJson(),
  };

  /// 持久化包装：{ state: {...}, version: 3 }
  String encode() => jsonEncode({'state': toJson(), 'version': 3});

  static Settings decode(String raw) {
    try {
      final root = jsonDecode(raw);
      if (root is! Map) return Settings();
      // 兼容两种形态：带 state 包装的，以及直接是设置的
      final state =
          (root['state'] as Map?)?.cast<String, dynamic>() ??
          root.cast<String, dynamic>();
      return Settings.fromJson(state);
    } catch (e) {
      // 配置文件损坏 / 被手工改坏时退回默认值。
      // `SettingsStore.load()` 外面也有一层 try/catch，但这是个公开静态方法，
      // 不该让任何调用方踩到 FormatException。
      debugPrint('解析设置失败，使用默认值: $e');
      return Settings();
    }
  }
}
