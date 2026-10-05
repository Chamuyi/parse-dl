/// 界面语言的运行时状态与查表。
///
/// **为什么拿中文原文当 key**（而不是 `nav_home_title` 这类符号名）：
/// 全应用有 400 多条界面文案散在二十几个文件里。用符号名的话，每条都要
/// ①起名字 ②填中文 ③填英文，名字还会随文案改写而腐坏；用原文当 key，
/// 中文这一份就是代码里本来就有的那句，只剩英文一遍要写。而且：
///
///   * 中文是默认语言 —— **查不到就退回原文**，漏一条只会少一条英文，不会白屏；
///   * `t('抓取结果')` 读起来仍然知道在说什么，不用跳到定义；
///   * 默认语言下（中文）输出与未接入前**逐字节相同**，现有那批按中文字面量
///     断言的界面测试因此不需要改。
///
/// 代价很明确：改中文文案就等于换 key，英文表里的旧条目会失效。
/// 这条由 `test/l10n_test.dart` 兜住 —— 它扫源码里所有 `t('…')` 字面量，
/// 要求英文表**不多不少**正好覆盖，漏了、留了旧的都会红。
library;

import 'app_locale.dart';
import 'strings_en.dart';

/// 用户在设置里选的语言（[AppLocale.system] = 跟随系统）。
///
/// 由 `app.dart` 在每次 build 时从设置写进来。之所以放全局而不是走
/// `BuildContext`：文案查询点有四百多处，其中不少在没有 context 的地方
/// （getter、列表构造参数），传 context 会把改动面扩大到整个仓库。
AppLocale preferredLocale = AppLocale.system;

/// 系统支持的语言 `languageCode` 列表，由 `app.dart` 每次 build 从
/// `PlatformDispatcher.locales` 写入。
///
/// 默认按中文处理：测试环境（`flutter test`）拿不到真实平台语言，
/// 而中文是这个应用的母语。
/// 只看 `languageCode`，所以 `zh` / `zh_CN` / `zh_TW` 都算中文 ——
/// 英文表用的是简体，繁体机器落到简体也比落到英文好。
List<String> systemLanguageCodes = const ['zh'];

/// 实际生效的语言（[AppLocale.system] 已解析）。
AppLocale get activeLocale {
  if (preferredLocale != AppLocale.system) return preferredLocale;
  return systemLanguageCodes.contains('zh') ? AppLocale.zh : AppLocale.en;
}

bool get inEnglish => activeLocale == AppLocale.en;

/// 设置 → 本库的写入口。
///
/// `app.dart` 的根 `Consumer<SettingsStore>` 每次 build 调一次；语言测试走的
/// 也是这个函数，免得「测试验的开关」和「真正生效的开关」不是同一个。
void applyLocaleSetting(AppLocale chosen) => preferredLocale = chosen;

/// 取一条文案。[zh] 同时是中文原文和查表用的 key。
///
/// [sense] 只用来消歧**同一个中文串在两个地方含义不同**的情况 ——
/// 目前只有一处：「应用」既是设置里的分区名（Application），又是筛选面板的
/// 按钮（Apply）。给了 [sense] 就查 `sense:中文` 这条 key，中文界面照旧
/// 显示原文，不用为了翻译去改用户看得见的说法。
String t(String zh, {String? sense}) {
  if (!inEnglish) return zh;
  return kStringsEn[sense == null ? zh : '$sense:$zh'] ?? zh;
}

/// 带占位符的一条文案：源串里写 `{name}`，这里替换。
///
/// 不能写成 `'页面出现 $count 条'` 再整串查表 —— 拼进数字之后的串
/// 每次都不一样，永远查不中。所以带插值的文案一律走这个函数。
String tf(String zh, Map<String, Object?> vars) {
  var s = t(zh);
  for (final e in vars.entries) {
    s = s.replaceAll('{${e.key}}', '${e.value}');
  }
  return s;
}
