import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/models/bili_config.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/widgets/bili_download_options_dialog.dart';

/// 下载选项弹窗的接线语义。
///
/// 钉三件事，都是这个弹窗存在的全部理由：
///   1. **只对本批生效**：改完点「开始下载」，返回的副本变了，而 `SettingsStore`
///      里那一份**一个字节都不许动**。反过来（顺手写盘）就是把用户的默认设置改坏。
///   2. 只有点「同步为默认并下载」才写盘。
///   3. 取消 → 什么都不发生（调用方整批不投）。
///   4. 内封的前提缺哪一条，那句话要**在界面上**，不是只在代码里。
///
/// 刻意只驱动页签与开关，不驱动下拉：`DropdownButtonFormField` 在 widget 测试里
/// 要先展开再点菜单项，脆；而上面四条断言的都不是手势，是接线。
/// 断言只比文本内容存在与否，不比宽度（`flutter test` 用 Ahem 等宽字体）。
void main() {
  late BuildContext hostCtx;

  Future<void> prime(WidgetTester tester, SettingsStore s) async {
    // AppTheme 必须在最外层：弹窗 build 第一行就是 AppTheme.colorsOf(context)，
    // 少这一层就报「AppTheme 未挂载」，看着像弹窗坏了，其实缺的是脚手架。
    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.dark,
        brightness: Brightness.dark,
        child: ChangeNotifierProvider<SettingsStore>.value(
          value: s,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  hostCtx = c;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 打开弹窗并返回那个 future（调用方自己决定点哪个按钮收尾）。
  Future<BiliOptionsResult?> open(WidgetTester tester, BiliConfig current) {
    // 弹窗内部改的是它自己那份副本，所以传进去的对象在断言时仍是原样 ——
    // 这本身就是「不能就地改传入对象」的一条隐性约束，用这里顺手钉住。
    return showBiliDownloadOptions(hostCtx, current);
  }

  SettingsStore freshStore() => SettingsStore();

  testWidgets('直接按「按默认开始下载」：副本没变，设置也没被写', (tester) async {
    final s = freshStore();
    await prime(tester, s);
    final current = BiliConfig();
    final f = open(tester, current);
    await tester.pumpAndSettle();

    await tester.tap(find.text('按默认开始下载'));
    await tester.pumpAndSettle();

    final r = await f;
    expect(r!.action, BiliOptionsAction.confirm);
    expect(r.config!.toJson(), current.toJson(), reason: '没动任何格子就该原样交回');
    expect(s.settings.bili.saveDanmaku, isFalse, reason: '只对本批生效，不许顺手写默认');
    expect(identical(r.config, current), isFalse, reason: '必须是新对象，不能就地改传入那份');
  });

  testWidgets('打开附加文件页签勾弹幕：返回的副本变了，设置里那份没变', (tester) async {
    final s = freshStore();
    await prime(tester, s);
    final f = open(tester, BiliConfig());
    await tester.pumpAndSettle();

    await tester.tap(find.text('附加文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, '弹幕'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('开始下载'));
    await tester.pumpAndSettle();

    final r = await f;
    expect(r!.config!.saveDanmaku, isTrue);
    expect(s.settings.bili.saveDanmaku, isFalse);
    // 改过东西之后主按钮的文案会换，用户才知道自己点的不是「原样下载」
    expect(r.action, BiliOptionsAction.confirm);
  });

  testWidgets('按「同步为默认并下载」才会写进设置', (tester) async {
    final s = freshStore();
    await prime(tester, s);
    final f = open(tester, BiliConfig());
    await tester.pumpAndSettle();

    await tester.tap(find.text('附加文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, '封面'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('同步为默认并下载'));
    await tester.pumpAndSettle();

    final r = await f;
    expect(r!.action, BiliOptionsAction.confirmAndSync);
    expect(r.config!.saveCover, isTrue);
    // 弹窗**自己不写盘**，写盘是调用方的事（`bili_page.dart` 里那句
    // `setBili((b) => b.applyFrom(...))`）。这里只钉「意图与配置交回来了」，
    // 落盘那一段由 `bili_config_test.dart` 的 applyFrom 逐键覆盖。
    expect(s.settings.bili.saveCover, isFalse,
        reason: '弹窗里直接改 settings 会让「取消」和「同步」两条路混在一起');
  });

  testWidgets('取消：action 是 cancel，设置一个字节没动', (tester) async {
    final s = freshStore();
    await prime(tester, s);
    final f = open(tester, BiliConfig());
    await tester.pumpAndSettle();

    await tester.tap(find.text('附加文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, '章节'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    final r = await f;
    expect(r!.action, BiliOptionsAction.cancel);
    expect(s.settings.bili.saveChapter, isFalse);
  });

  testWidgets('MP4 下勾内封：缺的那条前提要写在界面上，不许静默', (tester) async {
    await prime(tester, freshStore());
    open(tester, BiliConfig()..embedSubtitleTrack = true);
    await tester.pumpAndSettle();

    // 默认字幕格式是 srt，所以缺的不止容器一条 —— 断言按「提到了哪几条」判，
    // 不把整串文案钉死，否则改一个字就要来改测试。
    final shown = tester
        .widgetList<Text>(find.textContaining('内封现在还差'))
        .map((w) => w.data ?? '')
        .toList();
    expect(shown, hasLength(1));
    expect(shown.single, contains('MKV'),
        reason: '参照实现这里是静默跳过，用户只知道成品里没有轨');
    expect(shown.single, contains('ASS'));
  });

  testWidgets('前提齐全（MKV + 开合并 + ass）时那句提醒要消失', (tester) async {
    await prime(tester, freshStore());
    open(
      tester,
      BiliConfig()
        ..container = BiliContainer.mkv
        ..subtitleFormat = BiliSubtitleFormat.ass
        ..embedSubtitleTrack = true,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('内封现在还差'), findsNothing);
  });

  testWidgets('只改一格时，语言筛选那片的芯片要跟着开关出现/消失', (tester) async {
    await prime(tester, freshStore());
    open(tester, BiliConfig()..saveSubtitle = true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('附加文件'));
    await tester.pumpAndSettle();

    expect(find.text('仅人工字幕'), findsOneWidget);
    expect(find.text('中文'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, '字幕'));
    await tester.pumpAndSettle();
    expect(find.text('仅人工字幕'), findsNothing,
        reason: '关掉总开关后不该继续摊一堆用不上的格子');
  });
}
