import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/l10n/app_locale.dart';
import 'package:parse_dl/l10n/l10n.dart';
import 'package:parse_dl/l10n/strings_en.dart';
import 'package:parse_dl/models/douyin_auto_task.dart';
import 'package:parse_dl/models/douyin_config.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/services/douyin_filter.dart';
import 'package:parse_dl/services/file_name_template.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/window_material.dart';
import 'package:parse_dl/widgets/nav_items.dart';
import 'package:parse_dl/widgets/sidebar_nav.dart';

/// 界面中英双语的骨架测试。
///
/// 三件事各钉一处：
///   1. 查表行为（默认中文、英文命中、**漏翻退回原文**、占位符替换）；
///   2. 语言选择的持久化与「跟随系统」的解析；
///   3. **英文表的覆盖面** —— 扫源码里所有 `t('…')` / `tf('…'` 的字面量，
///      要求每条都能在表里查到，同时表里不许留着源码已经不用了的旧条目。
///
/// 第 3 条是这套「中文原文当 key」方案唯一的腐坏点（改文案 = 换 key），
/// 所以做成硬失败，而不是靠人自觉。
void main() {
  tearDown(() {
    preferredLocale = AppLocale.system;
    systemLanguageCodes = const ['zh'];
  });

  group('查表', () {
    test('中文档：原样返回，逐字节等于传入的串', () {
      preferredLocale = AppLocale.zh;
      expect(t('抓取结果'), '抓取结果');
      expect(t('English'), 'English');
    });

    test('英文档：命中查表，漏翻退回中文原文', () {
      preferredLocale = AppLocale.en;
      expect(t('主页'), 'Home');
      // 表里没有这句 —— 必须退回中文，而不是抛异常或返回空串
      expect(t('这句没有英文对照'), '这句没有英文对照');
    });

    test('跟随系统：系统有中文走中文，没有走英文', () {
      preferredLocale = AppLocale.system;
      systemLanguageCodes = const ['zh', 'en'];
      expect(activeLocale, AppLocale.zh);
      expect(inEnglish, isFalse);

      systemLanguageCodes = const ['en', 'fr'];
      expect(activeLocale, AppLocale.en);
      expect(t('主页'), 'Home');
    });

    test('显式选一种语言时，系统语言不再参与判断', () {
      preferredLocale = AppLocale.zh;
      systemLanguageCodes = const ['en'];
      expect(activeLocale, AppLocale.zh);
    });

    test('tf：先查表再替换占位符，可重复出现', () {
      preferredLocale = AppLocale.en;
      expect(tf('切换到{label}', {'label': t('Home')}), 'Switch to Home');
      expect(tf('{a} 与 {a} 与 {b}', {'a': 1, 'b': 'x'}), '1 与 1 与 x');
      // 没传对应变量时占位符原样留着 —— 比抛异常好，界面不至于整块没了
      expect(tf('缺变量 {missing}', const {}), '缺变量 {missing}');
    });

    test('每个档位的 languageCode 与 MaterialApp.locale 对得上', () {
      expect(AppLocale.zh.flutterLocale.languageCode, 'zh');
      expect(AppLocale.en.flutterLocale.languageCode, 'en');
      expect(AppLocale.system.flutterLocale.languageCode, 'zh');
    });
  });

  group('语言选择的持久化', () {
    test('默认跟随系统', () {
      expect(AppearanceSettings().locale, AppLocale.system);
      expect(Settings().appearance.locale, AppLocale.system);
    });

    test('旧配置没有 locale 字段 → 跟随系统（升级后观感不变）', () {
      final a = AppearanceSettings.fromJson({'themeMode': 'dark'});
      expect(a.locale, AppLocale.system);
    });

    test('往返编解码保留选择', () {
      for (final l in AppLocale.values) {
        expect(
          AppearanceSettings.fromJson(
            AppearanceSettings(locale: l).toJson(),
          ).locale,
          l,
        );
      }
      expect(AppearanceSettings(locale: AppLocale.en).toJson()['locale'], 'en');
    });

    test('未知值 / 坏值回退到跟随系统', () {
      expect(AppLocale.fromId(null), AppLocale.system);
      expect(AppLocale.fromId(''), AppLocale.system);
      expect(AppLocale.fromId('fr'), AppLocale.system);
    });

    test('走真实 SettingsStore 改语言会立刻通知监听者', () {
      final store = SettingsStore();
      var notified = 0;
      store.addListener(() => notified++);
      store.setAppearance((a) => a.locale = AppLocale.en);
      expect(notified, 1);
      expect(store.settings.appearance.locale, AppLocale.en);
    });
  });

  // ────────────────────────────────────────────────────────────
  // 覆盖面：源码扫描
  // ────────────────────────────────────────────────────────────
  final libSource = _readLib();

  group('扫描器自己', () {
    // 上面两条覆盖面测试都建立在「扫描器扫得到」之上，所以先单独验它 ——
    // 扫描器一坏，覆盖面那两条会因为什么都扫不到而绿得毫无意义。
    test('认得 t(…) / tf(…)，跳过注释、变量参数与不含中文的串', () {
      const src = '''
/// 注释里的 t('假文案')
final a = t('外观'); // 尾注 t('也是假的')
final b = tf('切换到{label}', {'label': t(group.label)});
final c = t('English');
final d = t(variable);
''';
      expect(_translatedKeys(src), ['外观', '切换到{label}']);
    });

    test('相邻字面量算一条 key；三元里的两条各算一条', () {
      const src = "final a = t('前半段，' '后半段。');"
          "final b = t(cond ? '甲' : '乙');";
      expect(_translatedKeys(src), ['前半段，后半段。', '甲', '乙']);
    });

    test('扫 lib/ 确实扫到了东西', () {
      final keys = {
        for (final e in libSource.entries) ..._translatedKeys(e.value),
      };
      expect(
        keys,
        containsAll(['外观', '界面语言', '关于', '解析下载器']),
        reason: '这几条就在 app.dart / settings_page.dart 里',
      );
      expect(
        keys.length,
        greaterThan(60),
        reason: '只扫到 ${keys.length} 条，提取器多半跟不上源码写法了',
      );
    });
  });

  group('英文表覆盖面', () {
    test('源码里每条 t(…) / tf(…) 的中文文案都有英文对照', () {
      final missing = <String>[];
      for (final e in libSource.entries) {
        for (final key in _translatedKeys(e.value)) {
          if (!kStringsEn.containsKey(key)) {
            missing.add('${e.key}: 「$key」');
          }
        }
      }
      expect(missing, isEmpty, reason: '漏翻会让英文界面夹中文：\n${missing.join('\n')}');
    });

    test('英文表里没有源码已经不再使用的旧条目', () {
      // 干草堆取「全部字面量的反转义值、按出现顺序首尾相接」，而不是原始源码：
      // 表里的 key 是运行时的值（真换行、单反斜杠），源码里写的是 `\n`、`\\`，
      // 直接比源码会错判；而 `'A' 'B'` 这种拆行写法拼起来正好就是整条 key。
      // 排除表自己 —— 否则每个 key 都能在文件里原样找到，这条永远绿。
      final haystack = _normalize([
        for (final e in libSource.entries)
          if (!e.key.endsWith('strings_en.dart'))
            ..._literalRe.allMatches(_stripComments(e.value))
                .map((m) => _unquote(m[0]!)),
      ].join());
      final orphans = [
        for (final key in kStringsEn.keys)
          if (!haystack.contains(_normalize(_bareKey(key)))) key,
      ];
      expect(
        orphans,
        isEmpty,
        reason: '改中文文案等于换 key，旧条目留在表里没人维护：\n${orphans.join('\n')}',
      );
    });

    test('占位符两边必须一一对应（英文漏了 {x} 就是把数据弄丢）', () {
      final bad = <String>[];
      for (final e in kStringsEn.entries) {
        final src = _placeholders(e.key);
        final dst = _placeholders(e.value);
        if (src.difference(dst).isNotEmpty || dst.difference(src).isNotEmpty) {
          bad.add('${e.key} → ${e.value}');
        }
      }
      expect(bad, isEmpty, reason: '占位符不匹配：\n${bad.join('\n')}');
    });

    test('数据位标签（枚举 / 常量表）全都有英文对照', () {
      // 这些 label 存在 `const` 数据里，渲染处才 t(label) —— 上面那条扫的是
      // 字面量形式的调用点，抓不到「变量传进 t()」这条路，所以逐个数据源点名。
      preferredLocale = AppLocale.en;
      final gaps = <String>[];
      for (final where in <String, List<String>>{
        'WindowMaterial': [...WindowMaterial.values.map((e) => e.label),
              ...WindowMaterial.values.map((e) => e.description)],
        'NavLayout': [...NavLayout.values.map((e) => e.label),
              ...NavLayout.values.map((e) => e.description)],
        'ThemeMode2': ThemeMode2.values.map((e) => e.label).toList(),
        'DouyinSource': DouyinSource.values.map((e) => e.label).toList(),
        'DouyinQualityMode':
            DouyinQualityMode.values.map((e) => e.label).toList(),
        'DouyinImageFormat':
            DouyinImageFormat.values.map((e) => e.label).toList(),
        'TagMode': TagMode.values.map((e) => e.label).toList(),
        'DateQuickRange': DateQuickRange.values.map((e) => e.label).toList(),
        'DouyinAutoStatus':
            DouyinAutoStatus.values.map((e) => e.label).toList(),
        '模板预设': kDouyinTemplatePresets.map((e) => e.label).toList(),
        '模板变量说明': [
          ...kXTemplateVars.map((e) => e.desc),
          ...kDouyinTemplateVars.map((e) => e.desc),
          for (final v in [...kXTemplateVars, ...kDouyinTemplateVars])
            for (final p in v.params) p.desc,
        ],
      }.entries) {
        gaps.addAll([
          for (final label in where.value)
            // 不含汉字的标签（Mica、H.264）本来就不需要翻 —— 和扫描器同一判据
            if (_cjk.hasMatch(label) && t(label) == label)
              '${where.key} 的「$label」',
        ]);
      }
      expect(gaps, isEmpty,
          reason: '这些标签没有英文对照，英文界面会夹中文：\n${gaps.join('\n')}');
    });

    test('导航项的中文标签全都有英文对照', () {
      // 导航的 label 是 `const` 数据，渲染处才 t(label) —— 上一条测试扫的是
      // 字面量形式的调用点，扫不到这种「变量传进 t()」的路径，所以单独查。
      preferredLocale = AppLocale.en;
      for (final g in kNavGroups) {
        expect(t(g.label), isNot(g.label), reason: '模块「${g.label}」没有英文对照');
        for (final c in g.children) {
          expect(t(c.label), isNot(c.label), reason: '导航项「${c.label}」没有英文对照');
        }
      }
      for (final c in kNavStandalone) {
        expect(t(c.label), isNot(c.label), reason: '全局项「${c.label}」没有英文对照');
      }
    });

    test('三档语言名在英文界面下分别是 Follow system / Simplified Chinese / English',
        () {
      preferredLocale = AppLocale.en;
      expect(t(AppLocale.system.label), 'Follow system');
      expect(t(AppLocale.zh.label), 'Simplified Chinese');
      // 语言名按惯例用该语言自己书写，所以 English 不需要（也不该有）对照
      expect(t(AppLocale.en.label), 'English');
    });
  });

  // ────────────────────────────────────────────────────────────
  // 渲染：语言真的能切
  // ────────────────────────────────────────────────────────────
  group('导航按语言渲染', () {
    late SettingsStore store;

    setUp(() => store = SettingsStore());

    /// 与 `app.dart` 同构：**根 `Consumer<SettingsStore>`** 里写一次语言、
    /// 下面整棵子树重建。少了这层 Consumer，改设置是不会反映到界面上的 ——
    /// 所以这个 harness 故意不复用 nav_layout_test 那个静态版本。
    Future<void> pumpSidebar(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsStore>.value(
          value: store,
          child: AppTheme(
            colors: AppColors.dark,
            brightness: Brightness.dark,
            child: MaterialApp(
              home: Scaffold(
                body: Consumer<SettingsStore>(
                  builder: (context, s, _) {
                    applyLocaleSetting(s.settings.appearance.locale);
                    return SizedBox(
                      height: 800,
                      child: SidebarNav(
                        currentRouteId: 'home',
                        onSelect: (_) {},
                        isGroupExpanded: (_) => true,
                        onToggleGroup: (_) {},
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('默认（跟随系统 + 系统为中文）看到的是中文标签', (tester) async {
      await pumpSidebar(tester);
      expect(find.text('X 下载'), findsOneWidget);
      expect(find.text('主页'), findsOneWidget);
      expect(find.text('Home'), findsNothing);
    });

    testWidgets('设置里改成英文 → 同一批导航项换成英文，中文标签一个都不留',
        (tester) async {
      await store.setAppearance((a) => a.locale = AppLocale.en);
      await pumpSidebar(tester);
      expect(find.text('X Downloads'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
      expect(find.text('X 下载'), findsNothing);
      expect(find.text('主页'), findsNothing);
    });

    testWidgets('中文档没有任何一条导航被截断', (tester) async {
      // 为什么只测中文：`flutter test` 用 Ahem 字体，每个字符都是一个等宽方块。
      // 中日韩字形本来就接近 1em 见方，所以中文标签的测量与真机的微软雅黑基本一致；
      // 拉丁字符 Ahem 比雅黑宽得多 —— 同一份代码在真机上 'Parse & Download'
      // 完整显示，在这里却报"被截断"。所以英文档的宽度只能靠真机截图核
      // （2026-09-24：240px 时组标题 `Douyin Downloa…` 就是这样被截图发现的，
      // 已加宽到 252）。这条测试守的是"有人把侧边栏改窄到连中文都放不下"。
      await pumpSidebar(tester);
      final labels = <String>[
        for (final g in kNavGroups) ...[g.label, ...g.children.map((c) => c.label)],
        ...kNavStandalone.map((c) => c.label),
      ];
      final truncated = <String>[
        for (final label in labels)
          for (final para in _paragraphsOf(tester, label))
            if (para.didExceedMaxLines) label,
      ];
      expect(truncated, isEmpty,
          reason: 'SidebarNav.width=${SidebarNav.width.toInt()} 连中文标签都放不下：'
              '${truncated.toSet().join('、')}');
    });

    testWidgets('改语言即时生效，切回中文也即时生效（不用重启）', (tester) async {
      await pumpSidebar(tester);
      expect(find.text('主页'), findsOneWidget);

      await store.setAppearance((a) => a.locale = AppLocale.en);
      await tester.pump();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('主页'), findsNothing);

      await store.setAppearance((a) => a.locale = AppLocale.zh);
      await tester.pump();
      expect(find.text('主页'), findsOneWidget);
      expect(find.text('Home'), findsNothing);
    });
  });
}

/// 找出渲染 [text] 的所有 [RenderParagraph]（`Text` → `RichText` → 段落）。
///
/// 用复数是因为同一个标签在侧边栏里会出现多次（'Settings' 三处：X 组、
/// 抖音组、全局项），`tester.element()` 遇到多元素直接抛
/// `Bad state: Too many elements`。
List<RenderParagraph> _paragraphsOf(WidgetTester tester, String text) {
  final out = <RenderParagraph>[];
  for (final e in find.text(text).evaluate()) {
    e.visitChildElements((c) {
      final r = c.renderObject;
      if (r is RenderParagraph) out.add(r);
    });
  }
  return out;
}

// ────────────────────────────────────────────────────────────
// 源码扫描
// ────────────────────────────────────────────────────────────

/// `lib/` 下全部 dart 源码（含 l10n 自己），key 是文件路径。
///
/// 唯一排除的是 `douyin_interceptor_js.dart`：那是一整块 `r'''…'''` 的
/// 注入用 JavaScript，里面的中文全是 JS 注释， Dart 侧的字面量扫描器
/// 分不清那些注释，会误报。
Map<String, String> _readLib() {
  const skip = {'lib/services/douyin_interceptor_js.dart'};
  final out = <String, String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll(r'\', '/');
    if (skip.contains(path)) continue;
    out[path] = entity.readAsStringSync();
  }
  return out;
}

final _cjk = RegExp(r'[一-鿿]');
final _callRe = RegExp(r'\btf?\(');

/// 三单引号串 | 双引号串 | 单引号串。两种引号都要：`lib/` 里以单引号为主，
/// 但表里偶尔有含单引号的英文值。
final _literalRe =
    RegExp(r"""'''[\s\S]*?'''|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'""");

/// 一段源码里所有被 `t()` / `tf()` 拿去查表的中文串。
///
/// 三条规矩，都是踩出来的：
///   * **跳过注释** —— `l10n.dart` 的库注释里就举了个 `t('抓取结果')` 的例子，
///     那是说明文字，不是调用点；
///   * 参数里只有一条**由相邻字面量拼成**的串时按拼接结果算 key
///     （长文案在源码里为了行宽会拆成 `'A' 'B'`，Dart 编译期就拼成一条）；
///     有别的表达式（三元）时每个字面量各是一个 key；
///   * `tf('…', {…})` 只看第一个参数，后面的变量表不参与。
///
/// 只认含汉字的串：`t('English')` 这种本来就不用翻。
List<String> _translatedKeys(String src) {
  final clean = _stripComments(src);
  final keys = <String>[];
  for (final m in _callRe.allMatches(clean)) {
    final open = m.start + m[0]!.length - 1;
    final close = _matchingParen(clean, open);
    if (close < 0) continue;
    final arg = clean.substring(open + 1, close);
    final first = _firstTopLevelSegment(arg);
    if (first == null) continue;
    final literals =
        _literalRe.allMatches(first).map((e) => _unquote(e[0]!)).toList();
    if (literals.isEmpty) continue;
    // 去掉字面量后什么都不剩 = 纯相邻拼接，是一条 key；否则是多个候选
    final single = first.replaceAll(_literalRe, '').trim().isEmpty;
    // t('应用', sense: 'filter') → 查的 key 是 'filter:应用'
    final sense = RegExp(r"""\bsense\s*:\s*['"](\w+)['"]""").firstMatch(arg);
    for (var lit in single ? [literals.join()] : literals) {
      if (!_cjk.hasMatch(lit)) continue;
      if (sense != null) lit = '${sense.group(1)}:$lit';
      keys.add(lit);
    }
  }
  return keys;
}

/// 字面量本体：去掉外层引号并**反转义**。
///
/// 必须反转义 —— 表里的 key 是 Dart 运行时的值（真换行、单反斜杠），而源码里
/// 写的是 `\n`、`\\`。之前拿源码形式直接比，六条带换行的长文案全被判成漏翻。
String _unquote(String raw) {
  final body = (raw.startsWith("'''") || raw.startsWith('"""'))
      ? raw.substring(3, raw.length - 3)
      : raw.substring(1, raw.length - 1);
  return _unescape(body);
}

/// Dart 字符串转义还原。够用的子集：本项目文案里只出现这几个。
String _unescape(String s) => s.replaceAllMapped(
  RegExp(r'\\(.)'),
  (m) => switch (m.group(1)) {
    'n' => '\n',
    't' => '\t',
    'r' => '\r',
    '0' => '\x00',
    _ => m.group(1)!,
  },
);

/// 从 `open` 处的 `(` 找到配对的 `)`（跳过字符串内的括号）。-1 表示没找到。
int _matchingParen(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// 从 [start] 处的引号跳到该字符串字面量结束的下一个字符。
int _skipString(String s, int start) {
  final q = s[start];
  final triple = start + 2 < s.length && s[start + 1] == q && s[start + 2] == q;
  final d = triple ? q * 3 : q;
  for (var i = start + d.length; i < s.length - d.length + 1; i++) {
    if (s[i] == r'\') {
      i++;
      continue;
    }
    if (s.startsWith(d, i)) return i + d.length - 1;
  }
  return s.length;
}

/// 顶层第一个逗号之前（含三元表达式）；没有逗号就整段返回。
String? _firstTopLevelSegment(String arg) {
  var depth = 0;
  for (var i = 0; i < arg.length; i++) {
    final c = arg[i];
    if (c == "'" || c == '"') {
      i = _skipString(arg, i);
      continue;
    }
    if (c == '(' || c == '{' || c == '[') {
      depth++;
    } else if (c == ')' || c == '}' || c == ']') {
      depth--;
    } else if (c == ',' && depth == 0) {
      return arg.substring(0, i);
    }
  }
  return arg;
}

/// 行注释与块注释都清掉，但**字符串里的 `//` 不算注释**（`https://…` 到处都是）。
String _stripComments(String src) {
  final out = StringBuffer();
  var inBlock = false;
  for (final line in src.split('\n')) {
    var text = line;
    if (inBlock) {
      final end = text.indexOf('*/');
      if (end < 0) {
        out.writeln();
        continue;
      }
      inBlock = false;
      text = text.substring(end + 2);
    }
    text = text.replaceAll(RegExp(r'/\*.*?\*/'), '');
    final start = _lineCommentStart(text);
    if (start != null) {
      text = text.substring(0, start);
      if (text.contains('/*')) inBlock = true;
    } else if (text.contains('/*')) {
      inBlock = true;
    }
    out.writeln(text);
  }
  return out.toString();
}

/// 该行 `//` 注释的起点；引号里面的 `//` 跳过。
int? _lineCommentStart(String line) {
  var quote = '';
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote.isNotEmpty) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = '';
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
    } else if (c == '/' && i + 1 < line.length && line[i + 1] == '/') {
      return i;
    }
  }
  return null;
}

Set<String> _placeholders(String s) =>
    RegExp(r'\{\w+\}').allMatches(s).map((e) => e[0]!).toSet();

/// 归一化：空白与引号不参与比较。两边都已经是**反转义后的值**，所以这里
/// 不需要（也不能）再解一次转义 —— 会把 key 里的真反斜杠吃掉。
String _normalize(String s) => s.replaceAll(RegExp("[\\s'\"]+"), '');

/// 消歧前缀不算进「源码里还找不找得到」的判断：`filter:应用` 在源码里是
/// `t('应用', sense: 'filter')`，两个 token 分开写，所以只拿中文那段去比。
String _bareKey(String key) {
  final i = key.indexOf(':');
  return i < 0 ? key : key.substring(i + 1);
}
