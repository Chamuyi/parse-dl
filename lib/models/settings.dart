import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../l10n/app_locale.dart';
import '../theme/app_style.dart';
import '../theme/winui_accent.dart';
import '../theme/window_material.dart';
import 'bili_config.dart';
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

  /// 自定义色调的浓度 0~1（图吧工具箱「色调不透明度」滑块）。
  ///
  /// 越大越接近用户选的 [tintColor]，越小越接近主题底色。
  /// 默认 0.6 就是引入该参数之前写死的那档权重（见 `AppColors.tintFor`）。
  double tintOpacity;

  /// 明度层的不透明度 0~1（图吧工具箱「明度不透明度」滑块）。
  ///
  /// 越大越接近主题底色（越透、越不浓），越小越接近纯色调。
  /// 默认 0.3 是中性点 —— 取这个值时对最终颜色零偏移。
  double tintLuminosityOpacity;

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

  /// 界面风格。默认磨砂清晰；旧配置没这个字段时也是磨砂清晰 ——
  /// 拿到的就是改造前那套观感，升级不改变外观。
  AppStyle visualStyle;

  /// WinUI 风格下的强调色三选一（[WinUiAccent]）。
  ///
  /// **只对 [AppStyle.winui] 生效** —— 另三套风格各有自己的强调色令牌，
  /// 不读这个字段。旧配置没有它时回退到 Windows 官方蓝。
  WinUiAccent winUiAccent;

  AppearanceSettings({
    this.themeMode = ThemeMode2.system,
    this.windowMaterial = WindowMaterial.mica,
    this.customTint = false,
    this.tintColor = '#1d9bf0',
    this.tintOpacity = 0.6,
    this.tintLuminosityOpacity = 0.3,
    this.backgroundImage = '',
    this.backgroundImageOpacity = 0.35,
    this.navLayout = NavLayout.dock,
    this.navGroupExpanded = const {},
    this.locale = AppLocale.system,
    this.visualStyle = AppStyle.winui,
    this.winUiAccent = WinUiAccent.windows,
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

  /// 读 0~1 的比例字段：缺字段 / 坏值落 [fallback]，越界 clamp 回 0~1。
  ///
  /// NaN 与无穷也算坏值 —— 它们能穿过 `clamp` 混进颜色计算（NaN 与任何数
  /// 比较都为 false），最后表现为整块底色变黑或消失，而且不会抛异常。
  static double _unit(Object? raw, double fallback) {
    if (raw is! num) return fallback;
    final v = raw.toDouble();
    if (!v.isFinite) return fallback;
    return v.clamp(0.0, 1.0).toDouble();
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
        // 四档材质已恢复（2026-10-19 照抄图吧工具箱）。fromId 原样保留
        // mica / mica-alt / acrylic / acrylic-thin 四个 id；已删除的 none
        // 与坏值 / null 一律回落 mica（迁移不报错）。
        windowMaterial: WindowMaterial.fromId(j['windowMaterial'] as String?),
        customTint: j['customTint'] as bool? ?? false,
        tintColor: j['tintColor'] as String? ?? '#1d9bf0',
        tintOpacity: _unit(j['tintOpacity'], 0.6),
        tintLuminosityOpacity: _unit(j['tintLuminosityOpacity'], 0.3),
        backgroundImage: j['backgroundImage'] as String? ?? '',
        backgroundImageOpacity:
            (j['backgroundImageOpacity'] as num?)?.toDouble() ?? 0.35,
        navLayout: NavLayout.fromId(j['navLayout'] as String?),
        navGroupExpanded: _readExpandedMap(j['navGroupExpanded']),
        locale: AppLocale.fromId(j['locale'] as String?),
        visualStyle: AppStyle.fromId(j['visualStyle'] as String?),
        winUiAccent: WinUiAccent.fromId(j['winUiAccent'] as String?),
      );

  Map<String, dynamic> toJson() => {
    'themeMode': themeMode.id,
    'windowMaterial': windowMaterial.id,
    'customTint': customTint,
    'tintColor': tintColor,
    'tintOpacity': tintOpacity,
    'tintLuminosityOpacity': tintLuminosityOpacity,
    'backgroundImage': backgroundImage,
    'backgroundImageOpacity': backgroundImageOpacity,
    'navLayout': navLayout.id,
    'navGroupExpanded': navGroupExpanded,
    'locale': locale.id,
    'visualStyle': visualStyle.id,
    'winUiAccent': winUiAccent.id,
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

  /// B 站页的下载配置。形状与 [douyin] 同构，同样缺字段走默认值。
  ///
  /// 里面**不含 cookie**：B 站登录态只在运行时存在于内嵌 WebView2 的
  /// 会话里，不落 `settings.json`。
  BiliConfig bili;

  Settings({
    ProxySettings? proxy,
    DownloadSettings? download,
    AppOptions? app,
    AppearanceSettings? appearance,
    DouyinConfig? douyin,
    BiliConfig? bili,
  }) : proxy = proxy ?? ProxySettings(),
       download = download ?? DownloadSettings(),
       app = app ?? AppOptions(),
       appearance = appearance ?? AppearanceSettings(),
       douyin = douyin ?? DouyinConfig(),
       bili = bili ?? BiliConfig();

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
    bili: BiliConfig.fromJson(
      (j['bili'] as Map?)?.cast<String, dynamic>() ?? {},
    ),
  );

  Map<String, dynamic> toJson() => {
    'proxy': proxy.toJson(),
    'download': download.toJson(),
    'app': app.toJson(),
    'appearance': appearance.toJson(),
    'douyin': douyin.toJson(),
    'bili': bili.toJson(),
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
