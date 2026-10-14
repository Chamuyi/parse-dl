import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/l10n/strings_en.dart';
import 'package:parse_dl/pages/settings_page.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/section_card.dart';

/// P5 设置页重组的归属判据。
///
/// **用户提的两条**（原话）：
///   1. 「x账号管理要放在x的设置里，以及x接口缓存」
///      → 账号已在 X 页（`settings_page.dart` 的 `scope == xDownload`），
///        接口缓存从全局「高级」搬进 X 页；
///   2. 「你写的分模块设置少一个x的」
///      → 全局设置里的「分模块设置」入口必须是 **三个**（X / 抖音 / B 站）。
///
/// **判据怎么才算能判错**：每条都写成「这一页**有**什么」+「那一页**没有**什么」，
/// 且「没有」那一侧必须指向**本页真实会渲染的**特征串 —— 否则把整块删掉也照样绿。
/// 例如「全局页不含账号」用的是 `auth_token`：它是 `AccountSection` 里的
/// 输入框标签，账号分区一搬走它就整块消失（负控制实测会红，见下方注释）。
void main() {
  /// 按**卡头标题**定位那一张卡的子树。
  ///
  /// 2026-10-14 平铺改造后，折叠容器（`collapsible-content-<id>`）连同它的
  /// key 一起退役 —— 设置页每块内容现在都是 [SectionCard]，卡头标题就是
  /// 那一块的名字。用「标题 → 最近的 SectionCard」当锚点，搜索范围仍然
  /// **限定在这一张卡里**，与原来按分区 key 定位是同一个用途：
  /// 别处的同名文字（如变量表里的「自定义文本」）不会撞进来。
  Finder cardOf(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byType(SectionCard),
  );

  Future<SettingsStore> pumpPage(
    WidgetTester tester, {
    SettingsScope scope = SettingsScope.global,
    void Function(String routeId)? onNavigate,
  }) async {
    // 画布要够高：`ListView` 懒构建，画布只放得下前半截时后面的分区不在树上。
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    AppPrefs.setMockInitialValues({});
    final appState = await AppState.restore();
    final settings = SettingsStore();

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: appState),
            ChangeNotifierProvider<SettingsStore>.value(value: settings),
            ChangeNotifierProvider<DownloadStore>(create: (_) => DownloadStore()),
            ChangeNotifierProvider<DouyinStore>(create: (_) => DouyinStore()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SettingsPage(
                brightness: Brightness.dark,
                onMaterialChanged: (_) async {},
                scope: scope,
                onNavigate: onNavigate,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  // ══════════════════════════════════════════════════════════
  // 一、P5-1：X 账号与接口缓存都在 X 设置页
  // ══════════════════════════════════════════════════════════
  group('P5-1 X 设置页含账号与接口缓存', () {
    testWidgets('X 下载设置页：账号 + 接口缓存两块都在', (tester) async {
      await pumpPage(tester, scope: SettingsScope.xDownload);

      expect(
        cardOf('账号'),
        findsOneWidget,
        reason: 'X 账号登录属于 X 下载模块，必须在 X 设置页里',
      );
      expect(
        cardOf('接口缓存'),
        findsOneWidget,
        reason: 'X 接口缓存是 X 自己的排障项，必须在 X 设置页里',
      );
    });

    testWidgets('接口缓存卡里能看到清除按钮与说明', (tester) async {
      await pumpPage(tester, scope: SettingsScope.xDownload);

      // 平铺后内容直接可见，不再需要「先点开分区」这一步 —— 判据本身
      // （按钮与说明随这一块一起在）不变，只是不用再展开。
      final inSection = find.descendant(
        of: cardOf('接口缓存'),
        matching: find.text('刷新 X 接口缓存'),
      );
      expect(inSection, findsOneWidget, reason: '「刷新 X 接口缓存」字段应随这一块一起在');
      expect(find.text('清除缓存并重试'), findsOneWidget, reason: '清除按钮不能丢');
    });

    testWidgets('全局设置页：接口缓存与「高级」壳子都不在', (tester) async {
      await pumpPage(tester);

      expect(
        cardOf('接口缓存'),
        findsNothing,
        reason: '接口缓存属于 X 模块，不该留在全局设置里',
      );
      // 「高级」分区移空后整块去掉 —— 空壳留着比去掉更糟：点开是空的
      expect(
        cardOf('高级'),
        findsNothing,
        reason: '「高级」移空后应当整块删除，不留空壳',
      );
      expect(find.text('高级'), findsNothing);
      // 正文串也不该在全局页出现（分区删了但字段被漏在别处，这条会红）
      expect(find.text('刷新 X 接口缓存'), findsNothing);
    });

    // ── 负控制 ────────────────────────────────────────────────
    testWidgets('负控制：全局设置页不含账号特征 auth_token', (tester) async {
      // `auth_token` 是 AccountSection 里那两个输入框的标签（account_section.dart:467），
      // 折叠组「只裁剪不销毁」，所以账号分区只要**在树上**，这个字串就找得到 ——
      // 这条断言因此真的能判错：把账号分区挪回全局页（或在全局页多渲染一次），
      // 它立刻变红。实测见交付说明里的负控制记录。
      await pumpPage(tester);

      expect(
        find.text('auth_token'),
        findsNothing,
        reason: '账号只在 X 设置页：全局设置里不该出现 auth_token 输入框',
      );
      expect(
        find.text('ct0'),
        findsNothing,
        reason: '同上：ct0 是账号分区的另一半，一起证明账号不在全局页',
      );

      // 正控制：同一个判据在 X 页必须**找得到** —— 否则上面两条「找不到」
      // 可能只是因为探针本身失效（例如标签被改成了别的字串）。
      await pumpPage(tester, scope: SettingsScope.xDownload);
      expect(
        find.text('auth_token'),
        findsOneWidget,
        reason: '正控制：X 设置页里必须能找到 auth_token，否则上面的负判据是假绿',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 二、P5-2：全局设置的分模块入口有三个
  // ══════════════════════════════════════════════════════════
  group('P5-2 分模块设置入口', () {
    testWidgets('三个入口都在，且各自跳到对应的设置页', (tester) async {
      final opened = <String>[];
      await pumpPage(tester, onNavigate: opened.add);

      // 平铺后「分模块设置」是「下载」卡里的一个小节（预览稿 `:681` 的
      // `.sec`），不再有自己的折叠壳 —— 三个入口就在这张卡里。
      final inSection = find.descendant(
        of: cardOf('下载'),
        matching: find.text('打开'),
      );
      expect(inSection, findsNWidgets(3), reason: 'X / 抖音 / B 站 三个入口，一个都不能少');

      // 三个入口都在这一块里（模块名逐个点名 —— 少一个就红）
      for (final name in ['X 下载', '抖音解析下载', 'B 站解析下载']) {
        expect(
          find.descendant(of: cardOf('下载'), matching: find.text(name)),
          findsOneWidget,
          reason: '分模块设置里必须有「$name」这个入口',
        );
      }

      // 跳转方式一致：都是同一个 onNavigate，按**显示顺序**传三个路由 id
      for (var i = 0; i < 3; i++) {
        await tester.tap(inSection.at(i));
        await tester.pumpAndSettle();
      }
      expect(
        opened,
        ['x-settings', 'douyin-settings', 'bili-settings'],
        reason: '三个入口必须分别跳各自的设置页（顺序 = 页面里的显示顺序）',
      );
    });

    testWidgets('没有跨页能力时按钮置灰而不是消失（三个入口仍可见）', (tester) async {
      await pumpPage(tester);

      final inSection = find.descendant(
        of: cardOf('下载'),
        matching: find.text('打开'),
      );
      expect(inSection, findsNWidgets(3), reason: '按钮不该因为点不动就消失');

      for (var i = 0; i < 3; i++) {
        final btn = tester.widget<FilledButton>(
          find
              .ancestor(of: inSection.at(i), matching: find.byType(FilledButton))
              .first,
        );
        expect(btn.onPressed, isNull, reason: '没有 onNavigate 时按钮应当置灰');
      }
    });
  });

  // ══════════════════════════════════════════════════════════
  // 三、新文案的英文对照
  // ══════════════════════════════════════════════════════════
  group('新文案有英文', () {
    test('P5 新增/改名的中文文案都在英文表里', () {
      // l10n_test 扫的是源码里的 t('…') 字面量，这里点名核对 P5 这一批 ——
      // 两处判据不同（那边扫调用点，这边钉具体串），任一处漏了都会红。
      //
      // 这里**不能**用 `t(key)` 断言：`t()` 走的是当前语言档，测试里默认是
      // 中文档（原样返回），拿它比会永远等于原文 —— 直接查表才判得动。
      //
      // 2026-10-14 平铺改造后，`'X 下载、抖音解析下载、B 站解析下载各自的设置页入口'`
      // 从这份点名清单里退役：它原本是「分模块设置」折叠壳的收起态概要，平铺后
      // 那一块按预览稿 `index.html:681` 只剩一个 `.sec` 小节标题（没有 trailing），
      // 该文案在 lib/ 里已零引用。留着这条 pin 会与 l10n_test 的
      // 「英文表里没有源码已经不再使用的旧条目」**直接冲突** —— 一边要求它存在、
      // 一边要求它不存在。所以按退役处理，不再点名。
      for (final key in const ['接口缓存', '分模块设置']) {
        expect(kStringsEn.containsKey(key), isTrue, reason: '「$key」缺英文对照');
        expect(
          kStringsEn[key],
          isNot(key),
          reason: '「$key」的英文条目不能还是中文原文',
        );
      }
      // 随折叠结构一起退役的 key —— 英文表里留着就是死条目
      // （l10n_test 的「英文表里没有源码已经不再使用的旧条目」会红）。
      for (final key in const [
        '高级',
        '展开设置',
        'X 下载、抖音解析下载、B 站解析下载各自的设置页入口',
      ]) {
        expect(
          kStringsEn.containsKey(key),
          isFalse,
          reason: '「$key」随折叠结构退役，英文表里的旧条目要一起清掉',
        );
      }
    });
  });
}
