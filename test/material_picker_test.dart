import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:parse_dl/pages/settings_page.dart';
import 'package:parse_dl/services/app_prefs.dart';
import 'package:parse_dl/services/app_state.dart';
import 'package:parse_dl/services/download_store.dart';
import 'package:parse_dl/services/douyin_store.dart';
import 'package:parse_dl/services/settings_store.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/window_material.dart';
import 'package:parse_dl/widgets/material_picker.dart';

/// 「窗口材质」2×2 选择格的判据（照抄图吧工具箱 `SettingsPage.xaml:520-583`）。
///
/// 四条主判据，每条都带负控制：
///   1. 四档各渲染一格，每格有对应预览块与两行文字；
///   2. 点第 N 格 → 写进设置（数据层）+ 回调被调用一次；
///   3. 选中态：当前档边框 = 强调色，其余三格不是；
///   4. **四档预览块两两不同** —— 直接量渲染像素，不是看 widget 属性。
///
/// 第 4 条是这组里唯一能抓住「四张图画得一模一样」的判据：上一轮材质
/// 选择器被删之前，五档缩略图曾经就是同一张图换色号，靠读文字才分得出
/// （见 `appearance_controls_test.dart` 的文件头）。
void main() {
  const c = AppColors.dark;

  // ══════════════════════════════════════════════════════════
  // 泵页面
  // ══════════════════════════════════════════════════════════

  /// 泵出**真实的全局设置页**（外观卡里就装着 [MaterialPicker]）。
  ///
  /// 走整页而不是单独泵 [MaterialPicker]，是为了让「点一格 → 写设置 →
  /// 回调 → 选中态跟着变」这四步在同一次交互里被验到。
  Future<SettingsStore> pumpSettings(
    WidgetTester tester, {
    WindowMaterial initial = WindowMaterial.mica,
    List<WindowMaterial>? changes,
  }) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    AppPrefs.setMockInitialValues({});
    final appState = await AppState.restore();
    final settings = SettingsStore();
    await settings.setAppearance((a) => a.windowMaterial = initial);

    await tester.pumpWidget(
      AppTheme(
        colors: c,
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
                onMaterialChanged: (m) async => changes?.add(m),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  /// 某一格的容器（按材质 id 定位，四格各有独立 key）。
  Finder tileOf(WindowMaterial m) =>
      find.byKey(ValueKey('material-tile-${m.id}'));

  Finder swatchOf(WindowMaterial m) =>
      find.byKey(ValueKey('material-preview-${m.id}'));

  /// 某一格的边框 —— 直接读 [AnimatedContainer] 的 decoration。
  ///
  /// 读的是**构造时传进去的那个实例**（AnimatedContainer 会把它交给内部的
  /// 隐式动画容器），所以拿到的是当前这一帧的目标值，不是中间插值。
  Border borderOf(WidgetTester tester, WindowMaterial m) {
    final w = tester.widget<AnimatedContainer>(tileOf(m));
    final box = w.decoration! as BoxDecoration;
    return box.border! as Border;
  }

  /// 把一块预览渲染成像素，返回完整 RGBA 字节。
  ///
  /// 取图前先 `pump` 一帧：`toImage()` 要求目标 RenderRepaintBoundary
  /// 已经 paint 过（`card_content_painted_test.dart` 踩过这个坑）。
  Future<List<int>> pixelsOf(WidgetTester tester, Finder swatch) async {
    await tester.pump();
    late final ui.Image image;
    await tester.runAsync(() async {
      final b = tester.renderObject<RenderRepaintBoundary>(swatch);
      image = await b.toImage();
    });
    late final ByteData? bd;
    await tester.runAsync(() async {
      bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    });
    return bd!.buffer.asUint8List().toList();
  }

  // ══════════════════════════════════════════════════════════
  // 一、四档各渲染一格
  // ══════════════════════════════════════════════════════════
  group('四档各一格', () {
    testWidgets('4 格、4 个预览块、8 行文字（档位名 + 中文副标题）', (tester) async {
      await pumpSettings(tester);

      // 数据源本身就是 4 档 —— 这条先钉住「4」这个数字的来源
      expect(WindowMaterial.values.length, 4);

      expect(find.byType(MaterialPreviewSwatch), findsNWidgets(4),
          reason: '参照物是 2×2 四格，每格一块预览');
      for (final m in WindowMaterial.values) {
        expect(tileOf(m), findsOneWidget, reason: '「${m.id}」这一格没有渲染');
        expect(swatchOf(m), findsOneWidget,
            reason: '「${m.id}」这一格没有预览块');
        // 第一行：档位名（枚举 label，纯英文）
        expect(find.text(m.label), findsOneWidget,
            reason: '「${m.id}」这一格缺档位名');
        // 第二行：中文副标题（逐字照抄参照物）
        expect(find.text(materialSubtitleOf(m)), findsOneWidget,
            reason: '「${m.id}」这一格缺中文副标题');
      }

      // 副标题逐条对齐参照物 XAML 第 538/551/565/579 行
      expect(materialSubtitleOf(WindowMaterial.mica), '柔和云母');
      expect(materialSubtitleOf(WindowMaterial.micaAlt), '层次云母');
      expect(materialSubtitleOf(WindowMaterial.acrylic), '磨砂玻璃');
      expect(materialSubtitleOf(WindowMaterial.acrylicThin), '更透亮的磨砂');
    });

    testWidgets('2×2 网格：两行两列，列间距与行间距都是 8', (tester) async {
      await pumpSettings(tester);

      final mica = tester.getRect(tileOf(WindowMaterial.mica));
      final alt = tester.getRect(tileOf(WindowMaterial.micaAlt));
      final acr = tester.getRect(tileOf(WindowMaterial.acrylic));
      final thin = tester.getRect(tileOf(WindowMaterial.acrylicThin));

      // 第一行：Mica / Mica Alt 同一 y，横向间隔 8
      expect((mica.top - alt.top).abs(), lessThan(0.5),
          reason: '前两格必须在同一行');
      expect(alt.left - mica.right, closeTo(8, 0.5),
          reason: 'ColumnSpacing = 8（参照物 :520）');
      // 第二行：亚克力 / 细亚克力
      expect((acr.top - thin.top).abs(), lessThan(0.5),
          reason: '后两格必须在同一行');
      expect(thin.left - acr.right, closeTo(8, 0.5),
          reason: 'ColumnSpacing = 8');
      // 行间：RowSpacing = 8
      expect(acr.top - mica.bottom, closeTo(8, 0.5),
          reason: 'RowSpacing = 8');
      // 两列各占一等份（宽度相等）
      expect(mica.width, closeTo(alt.width, 0.5),
          reason: '两列各占一等份（Grid 的 ColumnDefinition Width="*"）');
      expect(acr.width, closeTo(thin.width, 0.5));

      // 负控制：如果四格被堆成一列，上面的「同一行」断言就会红 ——
      // 这里显式证明 mica 与 acrylic 不在同一行，说明判据能区分两种排布。
      expect((mica.top - acr.top).abs(), greaterThan(8),
          reason: '第三格必须换到下一行（负控制：证明「同一行」不是恒真）');
    });

    testWidgets('每格：CornerRadius 8 / 边框固定 2px / Padding 12,8', (tester) async {
      await pumpSettings(tester);

      for (final m in WindowMaterial.values) {
        final w = tester.widget<AnimatedContainer>(tileOf(m));
        final box = w.decoration! as BoxDecoration;
        final radius = box.borderRadius! as BorderRadius;
        expect(radius.topLeft.x, 8, reason: 'CornerRadius = 8（参照物 :529）');
        expect(w.padding, const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            reason: 'Padding = 12,8（参照物 :529）');
        // 边框宽度恒为 2，**选中与否都一样** —— 参照物 BorderThickness="2"
        // 固定，选中只换 BorderBrush。
        for (final other in WindowMaterial.values) {
          expect(borderOf(tester, m).top.width, 2);
          expect(borderOf(tester, other).top.width, 2,
              reason: '边框宽度必须恒为 2，否则选中时整格会跳一下');
        }
      }

      // 预览块尺寸 48×32
      final sw = tester.getRect(swatchOf(WindowMaterial.mica));
      expect(sw.width, 48, reason: '预览块 Width = 48（参照物 :531）');
      expect(sw.height, 32, reason: '预览块 Height = 32');
    });
  });

  // ══════════════════════════════════════════════════════════
  // 二、点击 → 写设置 + 回调
  // ══════════════════════════════════════════════════════════
  group('点击生效', () {
    testWidgets('点第 N 格 → 设置写入该档位，回调恰好调用一次', (tester) async {
      // 四档逐一点一遍：点第 0/1/2/3 格，各自写入对应档位
      for (var i = 0; i < WindowMaterial.values.length; i++) {
        final target = WindowMaterial.values[i];
        final changes = <WindowMaterial>[];
        final store = await pumpSettings(
          tester,
          initial: WindowMaterial.mica,
          changes: changes,
        );

        // 前置：初始值不是目标值（否则「写入成功」与「本来就没变」分不清）
        if (target == WindowMaterial.mica) {
          // 第 0 格本来就是选中档，先切走，证明点击真能改回来
          await store.setAppearance((a) => a.windowMaterial = WindowMaterial.acrylic);
          await tester.pumpAndSettle();
        }
        expect(store.settings.appearance.windowMaterial, isNot(target),
            reason: '前置失败：初始值已经是「${target.id}」，点击判据会恒真');

        await tester.tap(tileOf(target));
        await tester.pumpAndSettle();

        // 数据层：内存里的设置
        expect(store.settings.appearance.windowMaterial, target,
            reason: '点「${target.id}」这一格没有写进设置');
        // 数据层：落盘用的 id（定下不能改）
        expect(store.settings.appearance.toJson()['windowMaterial'], target.id,
            reason: '持久化 id 必须是「${target.id}」');

        // 回调：把材质应用到原生窗口的那一次
        expect(changes, [target],
            reason: '点一格应当恰好回调一次，且带的是该档位');
      }
    });

    testWidgets('负控制：点一格只写一格，其余三档不会跟着变', (tester) async {
      final changes = <WindowMaterial>[];
      final store = await pumpSettings(
        tester,
        initial: WindowMaterial.mica,
        changes: changes,
      );

      await tester.tap(tileOf(WindowMaterial.acrylicThin));
      await tester.pumpAndSettle();

      expect(store.settings.appearance.windowMaterial, WindowMaterial.acrylicThin);
      expect(store.settings.appearance.toJson()['windowMaterial'], 'acrylic-thin');
      // 负控制：如果「写入」是恒真的（比如把所有档位都设一遍），
      // 下面这条就会红 —— 它证明设置里只有这一个字段被改成这个值。
      for (final other in WindowMaterial.values) {
        if (other == WindowMaterial.acrylicThin) continue;
        expect(store.settings.appearance.toJson()['windowMaterial'],
            isNot(other.id));
      }
      expect(changes.length, 1, reason: '一次点击只能触发一次应用');

      // 再点另一格 → 覆盖，回调再 +1（不是恒为 1）
      await tester.tap(tileOf(WindowMaterial.acrylic));
      await tester.pumpAndSettle();
      expect(changes, [WindowMaterial.acrylicThin, WindowMaterial.acrylic],
          reason: '第二次点击应当再回调一次 —— 证明回调次数跟着点击走');
    });
  });

  // ══════════════════════════════════════════════════════════
  // 三、选中态
  // ══════════════════════════════════════════════════════════
  group('选中态', () {
    testWidgets('当前档边框 = 强调色，其余三格不是', (tester) async {
      // 先证明这两个 token 本身不同 —— 否则「是 accent / 不是 accent」
      // 这组断言会恒真（c.line == c.accent 时两句话都成立不了或都成立）。
      expect(c.line, isNot(c.accent),
          reason: '前置失败：未选中描边色与强调色相同，判据分不出选中态');

      for (final current in WindowMaterial.values) {
        await pumpSettings(tester, initial: current);

        for (final m in WindowMaterial.values) {
          final border = borderOf(tester, m);
          if (m == current) {
            expect(border.top.color, c.accent,
                reason: '「${m.id}」是当前档，边框必须是强调色');
            expect(border.top.width, 2, reason: '选中态只换颜色，不换宽度');
          } else {
            expect(border.top.color, isNot(c.accent),
                reason: '「${m.id}」不是当前档，边框不该是强调色');
            expect(border.top.color, c.line,
                reason: '未选中用次要描边色');
          }
        }
      }
    });

    testWidgets('负控制：选中态跟着数据走，不是写死在第一格', (tester) async {
      // 泵 mica 选中 → accent 边框在 mica
      await pumpSettings(tester, initial: WindowMaterial.mica);
      expect(borderOf(tester, WindowMaterial.mica).top.color, c.accent);

      // 换成 acrylicThin → accent 边框必须移到第 4 格，第 1 格退回次要色。
      // 若判据写死「第 1 格永远是 accent」，这一步会红。
      await pumpSettings(tester, initial: WindowMaterial.acrylicThin);
      expect(borderOf(tester, WindowMaterial.acrylicThin).top.color, c.accent,
          reason: '选中态必须跟随设置，不能写死在某一个格子上');
      expect(borderOf(tester, WindowMaterial.mica).top.color, isNot(c.accent),
          reason: '负控制：上一档的强调色边框必须消失');
    });

    testWidgets('点击后选中态立刻跟着变（不重启）', (tester) async {
      final store = await pumpSettings(tester, initial: WindowMaterial.mica);
      expect(borderOf(tester, WindowMaterial.mica).top.color, c.accent);

      await tester.tap(tileOf(WindowMaterial.acrylic));
      await tester.pumpAndSettle();

      expect(store.settings.appearance.windowMaterial, WindowMaterial.acrylic);
      expect(borderOf(tester, WindowMaterial.acrylic).top.color, c.accent,
          reason: '点完必须立刻是选中态');
      expect(borderOf(tester, WindowMaterial.mica).top.color, c.line,
          reason: '原来的选中格必须退回次要描边');

      // 负控制：把数据改回去但**不点界面**，界面必须跟着数据走
      await store.setAppearance((a) => a.windowMaterial = WindowMaterial.micaAlt);
      await tester.pumpAndSettle();
      expect(borderOf(tester, WindowMaterial.micaAlt).top.color, c.accent,
          reason: '选中态的数据源必须是设置，不是组件自己的局部状态');
    });
  });

  // ══════════════════════════════════════════════════════════
  // 四、四档预览块两两不同（像素级）
  // ══════════════════════════════════════════════════════════
  group('四档预览块真的不同', () {
    /// 四档预览的完整 RGBA 字节。
    Future<Map<WindowMaterial, List<int>>> signatures(
      WidgetTester tester,
    ) async {
      final out = <WindowMaterial, List<int>>{};
      for (final m in WindowMaterial.values) {
        out[m] = await pixelsOf(tester, swatchOf(m));
      }
      return out;
    }

    /// 两两比较，返回「像素完全相同的档位对」。
    List<String> identicalPairs(Map<WindowMaterial, List<int>> sigs) {
      final pairs = <String>[];
      final ms = WindowMaterial.values;
      for (var i = 0; i < ms.length; i++) {
        for (var j = i + 1; j < ms.length; j++) {
          final a = sigs[ms[i]]!;
          final b = sigs[ms[j]]!;
          if (a.length == b.length && _sameBytes(a, b)) {
            pairs.add('${ms[i].id} == ${ms[j].id}');
          }
        }
      }
      return pairs;
    }

    testWidgets('四档两两不同（6 对全部不同，逐像素比对）', (tester) async {
      await pumpSettings(tester);
      final sigs = await signatures(tester);

      // 前置：四张图确实被画出来了（尺寸对、非全同色）
      for (final m in WindowMaterial.values) {
        expect(sigs[m]!.length, 48 * 32 * 4,
            reason: '${m.id} 的预览不是 48×32');
        expect(sigs[m]!.toSet().length, greaterThan(1),
            reason: '${m.id} 的预览是一块纯色 —— 内嵌层没画出来');
      }

      final same = identicalPairs(sigs);
      expect(same, isEmpty,
          reason: '这些档位的预览块渲染结果完全相同，用户分不出材质差别：$same');
    });

    testWidgets('负控制：四格都用同一档 → 判据会判红（证明它不是恒真）', (tester) async {
      // 刻意造一个「四张图一模一样」的退化版本：四格全用 Mica。
      // 判据 identicalPairs 必须在它身上报出 6 对相同。
      tester.view.physicalSize = const Size(600, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        AppTheme(
          colors: c,
          brightness: Brightness.dark,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  for (final m in WindowMaterial.values)
                    MaterialPreviewSwatch(
                      key: ValueKey('material-preview-${m.id}'),
                      // 全部渲染成 Mica —— 正是「四张图画得一模一样」那个缺陷
                      material: WindowMaterial.mica,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final sigs = <WindowMaterial, List<int>>{
        for (final m in WindowMaterial.values)
          m: await pixelsOf(tester, swatchOf(m)),
      };
      final same = identicalPairs(sigs);
      expect(same.length, 6,
          reason: '负控制失败：四张同图没有被判成相同 —— 上一条判据是恒真的');

      // 反向再证一次：只把其中一张换成另一档，相同对就少一对。
      await tester.pumpWidget(
        AppTheme(
          colors: c,
          brightness: Brightness.dark,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  for (final m in WindowMaterial.values)
                    MaterialPreviewSwatch(
                      key: ValueKey('material-preview-${m.id}'),
                      material: m == WindowMaterial.acrylicThin
                          ? WindowMaterial.acrylicThin
                          : WindowMaterial.mica,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final mixed = <WindowMaterial, List<int>>{
        for (final m in WindowMaterial.values)
          m: await pixelsOf(tester, swatchOf(m)),
      };
      expect(identicalPairs(mixed).length, 3,
          reason: '负控制失败：把一格换成别的档位后，相同对应当从 6 降到 3');
    });

    testWidgets('内嵌层真的被画出来：预览块中心与边缘的像素不同', (tester) async {
      // 上一条判据只证明「四张图彼此不同」，**不证明内嵌层画出来了** ——
      // 四档的底色本来就不同，把 `child` 整个去掉（不画任何内嵌层）时
      // 上一条照样全绿（2026-10-19 注入实测）。所以这里单独量：
      // 预览块边缘（margin 之外，只有底色）与中心（多层叠加）必须不同。
      await pumpSettings(tester);

      for (final m in WindowMaterial.values) {
        final px = await pixelsOf(tester, swatchOf(m));
        // 48×32 RGBA；y 取中间行避开 4px 圆角
        int at(int x, int y) => (y * 48 + x) * 4;
        final edge = px.sublist(at(1, 16), at(1, 16) + 4);
        final center = px.sublist(at(24, 16), at(24, 16) + 4);

        expect(
          _sameBytes(edge, center),
          isFalse,
          reason: '${m.id}：中心像素 $center 与边缘像素 $edge 相同 —— '
              '内嵌层没有被画出来（只剩一块纯色底）',
        );
        // 参照物里内嵌层是**白色微光**，所以中心必须比边缘更亮，不是更暗。
        expect(
          center[0] + center[1] + center[2],
          greaterThan(edge[0] + edge[1] + edge[2]),
          reason: '${m.id}：内嵌层是白色微光，中心应当比边缘亮',
        );
      }
    });


    // ── 四档预览的亮度台阶跨度（2026-10-19 加）──────────────────────
    //
    // 上面那条「两两不同」**抓不住真问题**：四档取 53/58/65/88 时它们确实
    // 两两不同，判据全绿，但肉眼看着「四张图差不多」—— 跨度只有 35。
    // 参照物实测 54 / 60 / **193** / 86，跨度 139，亚克力那一档跳出去一大截。
    // 所以真正要钉的是**跨度**与**亚克力是最亮档**，不是「不相等」。
    test('四档亮度跨度 ≥ 100（参照物实测 139，我方留余量取 100）', () {
      double luma(Color c) => ((c.r + c.g + c.b) / 3) * 255;
      final ls = [
        for (final m in WindowMaterial.values)
          luma(materialPreviewSpecOf(m).resolveBase()),
      ];
      final span = ls.reduce((a, b) => a > b ? a : b) -
          ls.reduce((a, b) => a < b ? a : b);
      expect(span, greaterThanOrEqualTo(100),
          reason: '四档挤在一起时肉眼分不出来（参照物跨度 139）。实测：$ls');
    });

    test('负控制：亚克力改回旧公式的深色会让跨度判据变红', () {
      double luma(Color c) => ((c.r + c.g + c.b) / 3) * 255;
      final ls = [
        for (final m in WindowMaterial.values)
          luma(materialPreviewSpecOf(m).resolveBase()),
      ];
      final idx = WindowMaterial.values.indexOf(WindowMaterial.acrylic);
      final broken = [...ls];
      broken[idx] = 64.7; // 旧公式算出来的深灰
      final span = broken.reduce((a, b) => a > b ? a : b) -
          broken.reduce((a, b) => a < b ? a : b);
      expect(span, lessThan(100),
          reason: '负控制失效：亚克力改回深色后跨度仍 ≥100，说明判据量错了东西');
    });

    test('亚克力是四档最亮（参照物 192.6 为四档最高）', () {
      double luma(Color c) => ((c.r + c.g + c.b) / 3) * 255;
      final ls = [
        for (final m in WindowMaterial.values)
          luma(materialPreviewSpecOf(m).resolveBase()),
      ];
      final idx = WindowMaterial.values.indexOf(WindowMaterial.acrylic);
      for (var i = 0; i < ls.length; i++) {
        if (i == idx) continue;
        expect(ls[idx], greaterThan(ls[i]),
            reason: '亚克力应是四档最亮（磨砂玻璃对亮部反光）。实测：$ls');
      }
    });

    test('负控制：亚克力压到最暗会让「最亮」判据变红', () {
      final idx = WindowMaterial.values.indexOf(WindowMaterial.acrylic);
      // 构造时**把下标算进去**，不要手写数组——手写下标错位过一次，
      // 结果负控制自己变红（它确实在起作用，但测的不是想测的东西）。
      final ls = <double>[54.0, 60.0, 88.0, 86.0]..[idx] = 20.0;
      final isMax = ls[idx] == ls.reduce((a, b) => a > b ? a : b);
      expect(isMax, isFalse,
          reason: '负控制失效：亚克力取 20 后仍是最大值，判据没有区分力（$ls）');
    });

    test('两档亚克力一亮一暗（亚克力必须比细亚克力亮，参照物 192.6 > 85.8）', () {
      double luma(Color c) => ((c.r + c.g + c.b) / 3) * 255;
      final a =
          luma(materialPreviewSpecOf(WindowMaterial.acrylic).resolveBase());
      final t =
          luma(materialPreviewSpecOf(WindowMaterial.acrylicThin).resolveBase());
      expect(a, greaterThan(t),
          reason: '两档画反了就像同一张图。实测 $a vs $t');
    });

    testWidgets('层数与 margin 逐档对齐参照物（Mica 两层、亚克力一层）', (tester) async {
      // 参照物 XAML 的嵌套层数：Mica / Mica Alt 各两层内嵌，
      // 两个亚克力各一层。层数不同 → 渲染结果必然不同，
      // 但这条**单独不足以**证明「看起来不同」，所以与像素判据并存。
      for (final m in WindowMaterial.values) {
        final spec = materialPreviewSpecOf(m);
        final expected = (m == WindowMaterial.mica || m == WindowMaterial.micaAlt)
            ? 2
            : 1;
        expect(spec.layers.length, expected,
            reason: '${m.id} 的内嵌层数应当是 $expected');
        // margin：Mica 档 3 然后 2；亚克力档 4
        if (expected == 2) {
          expect(spec.layers.map((l) => l.margin).toList(), [3.0, 2.0],
              reason: '${m.id} 的 Margin 应当是 3 / 2（参照物 :532-533）');
        } else {
          expect(spec.layers.single.margin, 4,
              reason: '${m.id} 的 Margin 应当是 4（参照物 :561 / :575）');
        }
      }

      // 负控制：如果把两档的规格写成同一份，像素判据会红。
      // 这里直接证明「四档的规格对象不是同一个、参数也不同」。
      expect(kMicaPreview.layers.length, isNot(kAcrylicPreview.layers.length),
          reason: 'Mica 与亚克力必须是不同层数 —— 这是参照物里的真实差别');
      expect(kMicaPreview.tintColor, isNot(kMicaAltPreview.tintColor),
          reason: '#1A000000 与 #2A000000 必须不同');
      expect(kAcrylicPreview.tintOpacity, isNot(kAcrylicThinPreview.tintOpacity),
          reason: 'TintOpacity 0.8 与 0.4 必须不同');
      expect(
        kAcrylicPreview.luminosityOpacity,
        isNot(kAcrylicThinPreview.luminosityOpacity),
        reason: 'TintLuminosityOpacity 0.3 与 0.8 必须不同',
      );
      // 合成底色也必须不同（否则两个亚克力预览会撞色）
      expect(kAcrylicPreview.resolveBase(), isNot(kAcrylicThinPreview.resolveBase()));
      expect(kMicaPreview.resolveBase(), isNot(kMicaAltPreview.resolveBase()));
    });
  });
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
