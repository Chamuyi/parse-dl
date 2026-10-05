import 'dart:ui' show Locale;

/// 界面语言。持久化在 `settings.json` 的 `appearance.locale`。
///
/// 只做中英两档：本软件的两个目标站点（X、抖音）各自的受众基本就是这两种语言，
/// 再多语就得为每种语言维护 400 多条文案，没人维护的翻译比没有翻译更糟。
enum AppLocale {
  /// 跟随系统：系统语言是中文就走 [zh]，否则走 [en]
  system('system', '跟随系统'),
  zh('zh', '简体中文'),

  /// 语言名按惯例用**该语言自己**书写，所以这一项不需要翻译
  en('en', 'English');

  const AppLocale(this.id, this.label);

  /// 持久化用的标识
  final String id;

  /// 设置里显示的名字（渲染处过一遍 `t()`）
  final String label;

  static AppLocale fromId(String? id) => AppLocale.values.firstWhere(
    (l) => l.id == id,
    orElse: () => AppLocale.system,
  );

  /// [Locale.languageCode]，用于 `MaterialApp.locale`
  String get languageCode => this == AppLocale.en ? 'en' : 'zh';

  Locale get flutterLocale => Locale(languageCode);
}
