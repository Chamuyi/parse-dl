import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/models/douyin_config.dart';
import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/pages/settings_page.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/services/template_source.dart';
import 'package:parse_dl/theme/app_theme.dart';

/// 抖音「保存与命名」回归测试。
///
/// 需求：抖音设置里要有和 X 下载一致的**文件夹模板**、**文件模板**，
/// 提供**启用模版**，并有**启用保存文件夹**开关。
///
/// 三条硬约束：
///   1. **两个模块各自独立** —— 改抖音的模板不影响 X 的，反之亦然；
///   2. **开关语义** —— 开：按文件夹模板建子目录；关：**忽略文件夹模板**，
///      文件平铺在保存根目录（用户明确过的说法）；
///   3. **老配置能读** —— 缺这三个字段的旧 settings.json 必须照常加载，
///      落到默认值而不是报错。
void main() {
  // ══════════════════════════════════════════════════════════
  // 一、数据层
  // ══════════════════════════════════════════════════════════
  group('DouyinConfig 新字段', () {
    test('默认值：开启保存文件夹 + 按作者分文件夹 + 时间_描述', () {
      final d = DouyinConfig();
      expect(d.enableSaveFolder, isTrue);
      expect(d.dirTemplate, '%AUTHOR%');
      expect(d.fileNameTemplate, kDouyinDefaultFileNameTemplate);
    });

    test('默认值正好等于「按作者分文件夹」预设 —— 初始下拉就停在它上面', () {
      final d = DouyinConfig();
      final p = kDouyinTemplatePresets.first;
      expect(p.id, 'author');
      expect(d.dirTemplate, p.dirTemplate);
      expect(d.fileNameTemplate, p.fileNameTemplate);
    });

    test('JSON 往返不丢字段', () {
      final d = DouyinConfig()
        ..enableSaveFolder = false
        ..dirTemplate = '%AWEME_ID%'
        ..fileNameTemplate = '%DESCRIPTION%%EXT%';
      final back = DouyinConfig.fromJson(d.toJson());
      expect(back.enableSaveFolder, isFalse);
      expect(back.dirTemplate, '%AWEME_ID%');
      expect(back.fileNameTemplate, '%DESCRIPTION%%EXT%');
    });

    test('旧配置缺字段 → 落到默认值，不抛异常', () {
      // 早期写出来的 JSON：完全没有这三个 key
      final legacy = {
        'source': 'default',
        'qualityMode': 'auto',
        'imageFormat': 'jpg',
        'skipDownloaded': true,
        'concurrency': 4,
        'customText': '',
      };
      final d = DouyinConfig.fromJson(legacy);
      expect(d.enableSaveFolder, isTrue);
      expect(d.dirTemplate, '%AUTHOR%');
      expect(d.fileNameTemplate, kDouyinDefaultFileNameTemplate);
      // 旧字段也要还在
      expect(d.imageFormat, DouyinImageFormat.jpgFirst);
      expect(d.skipDownloaded, isTrue);
    });

    test('isDefault：新字段参与判断', () {
      expect(DouyinConfig().isDefault, isTrue);
      final a = DouyinConfig()..enableSaveFolder = false;
      expect(a.isDefault, isFalse, reason: '关掉开关后就不该再算「全是默认值」');
      final b = DouyinConfig()..dirTemplate = '%AWEME_ID%';
      expect(b.isDefault, isFalse);
      final c = DouyinConfig()..fileNameTemplate = '%EXT%';
      expect(c.isDefault, isFalse);
    });

    test('预设列表：id 唯一，且「自定义」不混进可选项', () {
      final ids = kDouyinTemplatePresets.map((e) => e.id).toSet();
      expect(ids.length, kDouyinTemplatePresets.length, reason: 'id 必须唯一');
      for (final p in kDouyinTemplatePresets) {
        expect(p.label.trim(), isNotEmpty);
      }
      expect(kDouyinTemplatePresets.map((e) => e.id), contains('author'));
      expect(
        kDouyinTemplatePresets.map((e) => e.id),
        isNot(contains(kDouyinCustomPresetId)),
        reason: '「自定义」是状态提示，不该混进可选项里',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 二、按来源选模板（下载真正走的那条规则）
  // ══════════════════════════════════════════════════════════
  group('pickTemplates', () {
    DownloadSettings xConfig() => DownloadSettings()
      ..dirTemplate = '%USER_SCREEN_NAME%'
      ..fileNameTemplate = '%POST_ID%%EXT%';

    test('X 侧（douyin == null）用全局「下载」设置', () {
      final t = pickTemplates(download: xConfig(), douyin: null);
      expect(t.dirTemplate, '%USER_SCREEN_NAME%');
      expect(t.fileNameTemplate, '%POST_ID%%EXT%');
    });

    test('抖音侧用抖音自己的模板 —— 与 X 完全无关', () {
      final d = DouyinConfig()
        ..dirTemplate = '%AUTHOR%'
        ..fileNameTemplate = '%AWEME_ID%%EXT%';
      final t = pickTemplates(download: xConfig(), douyin: d);
      expect(t.dirTemplate, '%AUTHOR%');
      expect(t.fileNameTemplate, '%AWEME_ID%%EXT%');
      expect(
        t.dirTemplate,
        isNot('%USER_SCREEN_NAME%'),
        reason: 'X 的文件夹模板不能串到抖音这边',
      );
    });

    test('「启用保存文件夹」关掉 → 忽略文件夹模板（效果是平铺）', () {
      final d = DouyinConfig()
        ..enableSaveFolder = false
        ..dirTemplate = '%AUTHOR%'
        ..fileNameTemplate = '%AWEME_ID%%EXT%';
      final t = pickTemplates(download: xConfig(), douyin: d);
      expect(t.dirTemplate, '', reason: '关掉开关时文件夹模板必须为空 —— 文件才平铺在保存根目录');
      expect(
        t.fileNameTemplate,
        '%AWEME_ID%%EXT%',
        reason: '关的只是「保存文件夹」，文件模板照常生效',
      );
    });

    test('重新开启 → 文件夹模板恢复生效', () {
      final d = DouyinConfig()
        ..dirTemplate = '%AUTHOR%'
        ..enableSaveFolder = false;
      expect(pickTemplates(download: xConfig(), douyin: d).dirTemplate, '');
      d.enableSaveFolder = true;
      expect(
        pickTemplates(download: xConfig(), douyin: d).dirTemplate,
        '%AUTHOR%',
      );
    });

    test('抖音文件夹模板留空 → 与关掉开关等效（都平铺）', () {
      final d = DouyinConfig()..dirTemplate = '';
      final t = pickTemplates(download: xConfig(), douyin: d);
      expect(t.dirTemplate.trim().isEmpty, isTrue);
    });

    test('两个模块的模板互不影响（改一边另一边不动）', () {
      final x = xConfig();
      final d = DouyinConfig()
        ..dirTemplate = '%AWEME_ID%'
        ..fileNameTemplate = '%DESCRIPTION%%EXT%';
      final before = pickTemplates(download: x, douyin: null);
      // 改抖音
      d.dirTemplate = '%AUTHOR%/%CREATE_TIME,d=1%';
      d.fileNameTemplate = '%CUSTOM_TEXT%_%EXT%';
      final after = pickTemplates(download: x, douyin: null);
      expect(after.dirTemplate, before.dirTemplate);
      expect(after.fileNameTemplate, before.fileNameTemplate);
    });
  });

  // ══════════════════════════════════════════════════════════
  // 二·五、保存根目录怎么定（抖音有自己的一份）
  // ══════════════════════════════════════════════════════════
  group('resolveSaveBase', () {
    DouyinConfig dy(String dir) => DouyinConfig()..saveDirBase = dir;
    String r({
      DouyinConfig? douyin,
      String session = '',
      String x = '',
      String fallback = r'D:\default',
    }) => resolveSaveBase(
      douyin: douyin,
      sessionSaveDir: session,
      xSaveDirBase: x,
      fallback: fallback,
    );

    test('抖音自己填了就用它，优先级最高', () {
      expect(
        r(douyin: dy(r'D:\dy'), session: r'D:\x', x: r'D:\x'),
        r'D:\dy',
      );
    });

    test('抖音留空 → 沿用旧规则落到另一侧的根目录（兼容老用户）', () {
      expect(r(douyin: dy('  '), x: r'D:\x'), r'D:\x');
      expect(r(douyin: dy(''), session: r'D:\session', x: r'D:\x'),
          r'D:\session');
      // 会话值优先于持久化值 —— 与 X 设置页显示的口径一致
      expect(r(douyin: dy(''), session: r'D:\session', x: r'D:\old'),
          r'D:\session');
    });

    test('哪都没设过才退回默认目录', () {
      expect(r(douyin: dy('')), r'D:\default');
      expect(r(), r'D:\default'); // X 侧同样空
    });

    test('X 侧（douyin 为 null）的行为与改动前完全一致', () {
      expect(r(session: r'D:\session', x: r'D:\x'), r'D:\session');
      expect(r(x: r'D:\x'), r'D:\x');
      expect(r(), r'D:\default');
    });

    test('saveDirBase 会序列化，缺字段的旧配置照常读成空', () {
      final d = DouyinConfig()..saveDirBase = r'D:\dy';
      final back = DouyinConfig.fromJson(d.toJson());
      expect(back.saveDirBase, r'D:\dy');
      expect(DouyinConfig.fromJson({}).saveDirBase, '');
      expect(DouyinConfig().isDefault, isTrue);
      expect(d.isDefault, isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════
  // 三、设置界面
  // ══════════════════════════════════════════════════════════
  group('抖音设置界面的四个新项', () {
    Future<void> pumpDouyinSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 5000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      AppPrefs.setMockInitialValues({});
      final appState = await AppState.restore();
      final settings = SettingsStore();
      // 预置一个抖音自己的保存根目录（未绑定落盘文件，update 只改内存）
      await settings.update((s) => s.douyin.saveDirBase = r'D:\抖音下载');

      await tester.pumpWidget(
        AppTheme(
          colors: AppColors.dark,
          brightness: Brightness.dark,
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<AppState>.value(value: appState),
              ChangeNotifierProvider<SettingsStore>.value(value: settings),
              ChangeNotifierProvider<DownloadStore>(
                  create: (_) => DownloadStore()),
              ChangeNotifierProvider<DouyinStore>(create: (_) => DouyinStore()),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SettingsPage(
                  brightness: Brightness.dark,
                  onMaterialChanged: (_) async {},
                  scope: SettingsScope.douyin,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 展开「抖音」分区
      await tester.tap(find.text('抖音'));
      await tester.pumpAndSettle();
    }

    testWidgets('五项都在：保存路径框 / 启用保存文件夹 / 启用模版 / 文件夹模板 / 文件模板',
        (tester) async {
      await pumpDouyinSettings(tester);

      // 与 X 侧同构：保存路径是「一个只读框 + 选择按钮」，不另外加小标题
      expect(find.text('选择'), findsOneWidget);
      expect(find.text('启用保存文件夹'), findsOneWidget);
      expect(find.text('启用模版'), findsOneWidget);
      expect(find.text('文件夹模板'), findsOneWidget);
      expect(find.text('文件模板'), findsOneWidget);
      expect(find.text('保存与命名'), findsOneWidget, reason: '这几项归在「保存与命名」小标题下');
    });

    testWidgets('保存路径框里显示的是设置里的值', (tester) async {
      // 由 pumpDouyinSettings 的 settings.douyin.saveDirBase 预置
      await pumpDouyinSettings(tester);
      expect(find.text(r'D:\抖音下载'), findsOneWidget);
    });

    testWidgets('开关默认是开的，点一下能关掉', (tester) async {
      await pumpDouyinSettings(tester);

      final sw = find.ancestor(
        of: find.text('启用保存文件夹'),
        matching: find.byType(SwitchListTile),
      );
      expect(sw, findsOneWidget);
      expect(tester.widget<SwitchListTile>(sw).value, isTrue);

      await tester.tap(find.text('启用保存文件夹'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    });

    testWidgets('启用模版下拉默认停在「按作者分文件夹」', (tester) async {
      await pumpDouyinSettings(tester);

      expect(find.text('按作者分文件夹（推荐）'), findsWidgets);
    });

    testWidgets('模板框显示当前值，且各自带一份可用变量表', (tester) async {
      await pumpDouyinSettings(tester);

      // 默认模板会出现在输入框里
      expect(find.text('%AUTHOR%'), findsWidgets);
      expect(find.text(kDouyinDefaultFileNameTemplate), findsWidgets);
      // 两个模板字段各带一份变量表（与 X 侧同款组件）
      expect(find.text('可用变量'), findsNWidgets(2));
    });
  });
}