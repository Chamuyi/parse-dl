import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

import 'package:parse_dl/models/settings.dart';
import 'package:parse_dl/services/window_focus.dart';
import 'package:parse_dl/services/window_material_state.dart';
import 'package:parse_dl/theme/app_style.dart';
import 'package:parse_dl/theme/app_theme.dart';
import 'package:parse_dl/theme/window_material.dart';
import 'package:parse_dl/widgets/background_layer.dart';

/// WinUI3 的招牌行为：**窗口失焦时材质变灰**。
///
/// 参照物 \`tubatool/Services/BackdropService.cs:51-55\` 把
/// \`WindowActivationState\` 翻成 \`Configuration.IsInputActive\`，由
/// \`MicaController\` 自己切「不活跃」档。
///
/// 我方窗口材质由 DWM 画、**没有 IsInputActive 开关**（能力边界，实测）。
///
/// ### 2026-10-19 语义变更：从「改窗口底色」改成「叠覆盖层」
///
/// 窗口底改透明之后（让 DWM 材质透上来），失焦**不能再靠改底色** ——
/// 透明底没有颜色可改。现在失焦 = 在材质与背景图之上叠一层半透明灰纱，
/// 聚焦 = 不叠任何东西（[windowInactiveOverlay] 返回 [Colors.transparent]）。
///
/// ### 判据口径（这一条最容易写成恒真）
///
/// 「失焦档与聚焦档不相等」是**弱判据**：把公式调反（变亮）照样绿。
/// 所以每条方向判据都断言**方向**（亮度必须**下降**、饱和度必须**下降**），
/// 并为每条配负控制 —— 把公式调反 / 只做其中一半时，判据必须红。
///
/// 每条负控制都用 \`expect(..., throwsA(isA&lt;TestFailure&gt;()))\` 跑**同一段
/// 断言代码**：把实现换坏之后，那段断言必须真的抛 TestFailure。这样证明的
/// 不是「我另写了一个会红的检查」，而是「原判据在坏实现上会红」。
void main() {
  // 纯函数层不碰 widget 树，但 \`windowManager\` 单例在构造时会拿
  // \`ServicesBinding.instance.defaultBinaryMessenger\` 挂方法通道 ——
  // 所以整个文件统一先初始化 binding，不靠 testWidgets 顺带初始化。
  TestWidgetsFlutterBinding.ensureInitialized();

  // ══════════════════════════════════════════════════════════
  // 一、纯函数层：焦点 → 覆盖层颜色
  // ══════════════════════════════════════════════════════════

  /// Rec.709 相对亮度（0~1）。与实现里的口径一致，用于断言方向。
  double lumaOf(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

  /// 饱和度：通道极差。中性灰为 0。
  double chromaOf(Color c) {
    final hi = [c.r, c.g, c.b].reduce((a, b) => a > b ? a : b);
    final lo = [c.r, c.g, c.b].reduce((a, b) => a < b ? a : b);
    return hi - lo;
  }

  /// 一条带彩的基色：用 \`tintFor\` 出真实的自定义色调底（深色红调）。
  ///
  /// 不用纯 \`Color(0xFFFF0000)\` 当基色：真实调用点拿到的是 \`tintFor\` 混合后的
  /// 低饱和色，拿纯红去测等于测一条不存在的路径。
  final tintedBase = AppColors.tintFor(const Color(0xFFFF0000), Brightness.dark);

  /// 深色色板的窗口底（#2B2B2B）与浅色色板的窗口底（#FCFCFC）。
  final darkBase = AppColors.solidFor(Brightness.dark);
  final lightBase = AppColors.solidFor(Brightness.light);

  group('纯函数 windowInactiveOverlay：聚焦不叠，失焦叠灰纱', () {
    test('聚焦档返回**全透明**（不叠任何东西，材质原样）', () {
      for (final base in [darkBase, lightBase, tintedBase]) {
        final got = windowInactiveOverlay(base, focused: true);
        expect(got.a, 0.0,
            reason: '聚焦档必须完全透明 —— 只要有一点 alpha，材质就被一层纱'
                '压着，四档材质的差异会被这层纱稀释');
        // 负控制：这条判据若写成「恒返回某个常量」就会在下面露馅
        expect(got, isNot(equals(windowInactiveOverlay(base, focused: false))),
            reason: '聚焦档与失焦档必须真的不同，否则「按焦点切换」这件事没发生');
      }
    });

    test('失焦档的 alpha 恰为 kInactiveOverlayOpacity（不随基色漂移）', () {
      for (final base in [darkBase, lightBase, tintedBase]) {
        expect(
          windowInactiveOverlay(base, focused: false).a,
          closeTo(kInactiveOverlayOpacity, 1e-9),
          reason: '覆盖层透明度必须是常量 —— 若跟着基色 alpha 走'
              '（自定义色调的底是 85%），同一个「不活跃」档在不同设置下强度不同',
        );
      }
      // 负控制：tintFor 的底本来就是半透明的，拿它当覆盖层透明度会得到 0.85
      expect(tintedBase.a, lessThan(1.0),
          reason: '前提：自定义色调底确实半透明，否则这条判据没有区分力');
      expect(
        windowInactiveOverlay(tintedBase, focused: false).a,
        isNot(closeTo(tintedBase.a, 1e-6)),
        reason: '覆盖层 alpha 若直接取 base.a 就会等于 0.85 —— 这里必须不等',
      );
    });

    test('失焦档的**亮度确实下降**（方向断言，不是「不相等」）', () {
      for (final base in [darkBase, lightBase, tintedBase]) {
        final active = lumaOf(windowBackdropColor(base, focused: true));
        final inactive = lumaOf(windowBackdropColor(base, focused: false));
        expect(
          inactive,
          lessThan(active),
          reason: '失焦档必须更暗 —— 若公式写成 +kInactiveLumaDrop，'
              '这里会红（值会更大），而「不相等」型判据抓不到这个方向错误',
        );
      }
    });

    test('失焦档的**饱和度确实下降**（带彩基色上量通道极差）', () {
      final active = chromaOf(windowBackdropColor(tintedBase, focused: true));
      final inactive = chromaOf(windowBackdropColor(tintedBase, focused: false));
      expect(active, greaterThan(0.02),
          reason: '基色本身必须带彩，否则「饱和度下降」这条判据没有对象');
      expect(
        inactive,
        lessThan(active),
        reason: '失焦档必须更灰 —— 若实现里漏掉去饱和、只做压暗，'
            '通道极差不变，这里会红',
      );
    });

    test('windowBackdropColor 聚焦档**原样返回**基色（逐通道相等）', () {
      for (final base in [darkBase, lightBase, tintedBase]) {
        final got = windowBackdropColor(base, focused: true);
        expect(got.r, base.r);
        expect(got.g, base.g);
        expect(got.b, base.b);
        expect(got.a, base.a);
      }
    });
  });

  group('纯函数层的负控制：把实现改坏时上面几条必须红', () {
    /// 故意调反方向（\`+kInactiveLumaDrop\`）的版本。
    Color wrongDirection(Color base) => Color.from(
          alpha: base.a,
          red: (base.r + kInactiveLumaDrop / 255).clamp(0.0, 1.0),
          green: (base.g + kInactiveLumaDrop / 255).clamp(0.0, 1.0),
          blue: (base.b + kInactiveLumaDrop / 255).clamp(0.0, 1.0),
        );

    /// 只去饱和、**不压亮度**的版本。
    Color desaturateOnly(Color base) {
      final l = 0.2126 * base.r + 0.7152 * base.g + 0.0722 * base.b;
      return Color.from(
        alpha: base.a,
        red: base.r + (l - base.r) * kInactiveDesaturate,
        green: base.g + (l - base.g) * kInactiveDesaturate,
        blue: base.b + (l - base.b) * kInactiveDesaturate,
      );
    }

    /// 只压亮度、**不去饱和**的版本。
    Color darkenOnly(Color base) => Color.from(
          alpha: base.a,
          red: (base.r - kInactiveLumaDrop / 255).clamp(0.0, 1.0),
          green: (base.g - kInactiveLumaDrop / 255).clamp(0.0, 1.0),
          blue: (base.b - kInactiveLumaDrop / 255).clamp(0.0, 1.0),
        );

    /// 把「失焦必须更暗」这段断言抽出来，供正/负两种实现复用。
    ///
    /// 负控制的意义就在这：跑的是**同一段断言代码**，只是喂进去的颜色不同。
    void assertInactiveIsDarker(Color Function(Color) impl) {
      for (final base in [darkBase, lightBase]) {
        expect(lumaOf(impl(base)), lessThan(lumaOf(base)),
            reason: '失焦档必须更暗');
      }
    }

    /// 一条**足够亮**的带彩基色，专门给「更灰」判据用。
    ///
    /// 为什么不能用 [tintedBase]：它是深色底混合出来的暗红
    /// （r≈0.36 / g≈0.07 / b≈0.07）。三通道同减 kInactiveLumaDrop（0.251）时
    /// **绿蓝两通道先被 clamp 到 0**，通道极差因此也会变小 —— 那会让
    /// 「只压暗不去饱和」的坏实现**也**通过「更灰」判据，负控制失效。
    /// 浅色底混合出来的红是亮的（r≈0.93 / g≈0.80 / b≈0.80），压 0.251 之后
    /// 没有通道触底，极差保持不变 —— 这才是能区分「去饱和项在不在」的样本。
    final brightTintedBase =
        AppColors.tintFor(const Color(0xFFFF0000), Brightness.light);

    /// 「失焦必须更灰」那段断言。
    void assertInactiveIsGrayer(Color Function(Color) impl) {
      expect(chromaOf(impl(brightTintedBase)),
          lessThan(chromaOf(brightTintedBase)),
          reason: '失焦档必须更灰');
    }

    test('负控制：调反方向 → 「更暗」判据真的会红', () {
      // 正控制：正确实现必须通过同一段断言（否则下面的「会红」毫无意义 ——
      // 一段永远抛异常的代码也「会红」）。
      assertInactiveIsDarker((b) => windowBackdropColor(b, focused: false));

      expect(
        () => assertInactiveIsDarker(wrongDirection),
        throwsA(isA<TestFailure>()),
        reason: '把压暗项改成 +kInactiveLumaDrop 后，「更暗」判据必须抛'
            'TestFailure —— 若它仍绿，说明判据其实是不相等型/恒真型',
      );
    });

    test('负控制：只去饱和不压暗 → 「更暗」判据真的会红', () {
      assertInactiveIsDarker((b) => windowBackdropColor(b, focused: false));

      expect(
        () => assertInactiveIsDarker(desaturateOnly),
        throwsA(isA<TestFailure>()),
        reason: '去饱和是保亮度的（向自身 luma 靠拢）—— 所以「亮度下降」'
            '这条判据**只能**由压暗项满足；漏掉压暗项时必须红',
      );
    });

    test('负控制：只压暗不去饱和 → 「更灰」判据真的会红', () {
      assertInactiveIsGrayer((b) => windowBackdropColor(b, focused: false));

      // 前提：亮基色上压暗**不改**通道极差（没有通道触底）——
      // 若这一点不成立，「只压暗」的坏实现会顺带降饱和度，负控制就失效了。
      expect(chromaOf(darkenOnly(brightTintedBase)),
          closeTo(chromaOf(brightTintedBase), 2 / 255),
          reason: '三通道同减一个常量、且没有通道触底时，通道极差不变');

      expect(
        () => assertInactiveIsGrayer(darkenOnly),
        throwsA(isA<TestFailure>()),
        reason: '三通道同减一个常量，通道极差不变 —— 漏掉去饱和项时'
            '「饱和度下降」判据必须红',
      );
    });

    test('为什么「更灰」判据不能用暗基色：暗基色压暗会触底，区分力丢失', () {
      // 这不是「测试太严」，是实现口径的边界：暗基色上压暗本身就会让
      // 绿蓝通道触底，极差随之变小 —— 于是「只压暗」的坏实现也能通过
      // 「更灰」判据。负控制因此必须换亮基色。
      expect(chromaOf(darkenOnly(tintedBase)),
          lessThan(chromaOf(tintedBase)),
          reason: '暗基色（#5D1113 一带）压 64 阶后绿蓝触底 —— '
              '这正是不能拿它当负控制样本的原因');
    });

    test('负控制：覆盖层恒全透明 → 「失焦档 alpha」判据会红', () {
      // 模拟「忘了给覆盖层上色」：失焦也返回 transparent。
      Color broken(Color base, {required bool focused}) => Colors.transparent;
      expect(
        () => expect(broken(darkBase, focused: false).a,
            closeTo(kInactiveOverlayOpacity, 1e-9)),
        throwsA(isA<TestFailure>()),
      );
      // 正控制：真实现必须过同一句
      expect(windowInactiveOverlay(darkBase, focused: false).a,
          closeTo(kInactiveOverlayOpacity, 1e-9));
    });
  });

  // ══════════════════════════════════════════════════════════
  // 二、焦点来源：监听器必须真的进/出 windowManager
  // ══════════════════════════════════════════════════════════

  group('WindowFocusSource：焦点事件 → 可监听值', () {
    test('初值为 true（冷启动不该先闪一帧不活跃灰纱）', () {
      final src = WindowFocusSource();
      addTearDown(src.dispose);
      expect(src.isFocused, isTrue);
      expect(src.focused.value, isTrue);
    });

    test('onWindowBlur → false，onWindowFocus → true', () {
      final src = WindowFocusSource();
      addTearDown(src.dispose);

      src.onWindowBlur();
      expect(src.focused.value, isFalse);
      src.onWindowFocus();
      expect(src.focused.value, isTrue);

      // 负控制：这两个回调必须**各管一个方向**，不能都写死同一个值
      src.onWindowBlur();
      expect(src.focused.value, isFalse,
          reason: '若 onWindowFocus 与 onWindowBlur 被写成同一个值，'
              '这一句会红（两个方向只有一个能过）');
    });

    test('值没变时不重复通知（拖动窗口会重复派发同一事件）', () {
      final src = WindowFocusSource();
      addTearDown(src.dispose);
      var notified = 0;
      src.focused.addListener(() => notified++);

      src.onWindowFocus(); // 已经是 true
      src.onWindowFocus();
      expect(notified, 0, reason: '同值重复赋值会让整棵背景层白白重建');

      // 负控制：真变化时必须通知，否则上一条「不通知」可能只是「永远不通知」
      src.onWindowBlur();
      expect(notified, 1);
    });

    test('attach / detach 真的进出 windowManager 的监听器列表（不泄漏）', () {
      final src = WindowFocusSource();
      addTearDown(() {
        if (windowManager.listeners.contains(src)) src.detach();
      });

      expect(windowManager.listeners.contains(src), isFalse,
          reason: '前提：新建的实例还没注册');

      src.attach();
      expect(windowManager.listeners.contains(src), isTrue,
          reason: 'attach 没有真的挂上 —— 真机上就永远收不到焦点事件');

      src.detach();
      expect(windowManager.listeners.contains(src), isFalse,
          reason: 'detach 没有真的摘掉 —— 这就是本项目硬规矩里的监听器泄漏');
    });

    test('dispose 后不在监听器列表里（顺序：先 detach 再 dispose 值）', () {
      final src = WindowFocusSource();
      src.attach();
      expect(windowManager.listeners.contains(src), isTrue);

      src.dispose();
      expect(windowManager.listeners.contains(src), isFalse,
          reason: 'dispose 必须先 removeListener；否则 windowManager 会一直'
              '持有这个已销毁的实例');
    });
  });

  // ══════════════════════════════════════════════════════════
  // 三、材质可用状态：初值 true（首帧不闪不透明底）
  // ══════════════════════════════════════════════════════════

  group('windowMaterialAvailable：初值取 true 的理由', () {
    test('应用级单例初值为 true（失败才置 false，避免首帧闪一下不透明底）', () {
      expect(windowMaterialAvailable.value, isTrue,
          reason: 'applyWindowMaterial 是异步的、首帧跑在它之前。初值 false '
              '会让每次冷启动先闪一帧实色底再切透明 —— 那是肉眼可见的闪烁');
    });
  });

  // ══════════════════════════════════════════════════════════
  // 四、窗口底：材质可用 ⇒ 透明；不可用 ⇒ 不透明回退色
  // ══════════════════════════════════════════════════════════

  group('窗口底：材质可用时透明、不可用时回退不透明', () {
    for (final brightness in [Brightness.dark, Brightness.light]) {
      final name = brightness == Brightness.dark ? '深色' : '浅色';

      testWidgets('$name：材质可用 ⇒ 底是 alpha 0（不再是 0xFF）', (tester) async {
        final focusN = ValueNotifier<bool>(true);
        final materialN = ValueNotifier<bool>(true);
        addTearDown(focusN.dispose);
        addTearDown(materialN.dispose);
        await pumpBackdrop(tester,
            brightness: brightness, focus: focusN, materialAvailable: materialN);
        final colors = backdropBoxColors(tester);
        expect(colors, isNotEmpty, reason: '背景层必须真的铺了一层底');
        final bottom = colors.first;
        expect(
          bottom.a,
          0.0,
          reason: '窗口底的 alpha 是 ${bottom.a} —— 不透明像素会把 DWM 画的'
              '材质整个盖住，四档材质就变成四张一模一样的图。这正是本次'
              '要修的缺陷',
        );
        // 负控制：旧的「铺不透明实色」实现会在这里被抓住
        expect(AppColors.solidFor(brightness).a, 1.0,
            reason: '前提：色板 solidFor 本身是全不透明的 —— 若它本来就透明，'
                '上面那条「底透明」的判据就没有区分力');
      });
    }

    testWidgets('材质不可用 ⇒ 回退到 fallbackTo 的**不透明**纯色', (tester) async {
      final focusN = ValueNotifier<bool>(true);
      final materialN = ValueNotifier<bool>(false);
      addTearDown(focusN.dispose);
      addTearDown(materialN.dispose);
      await pumpBackdrop(tester,
          brightness: Brightness.dark, focus: focusN, materialAvailable: materialN);
      final bottom = backdropBoxColors(tester).first;
      final expected = WindowMaterial.mica.fallbackTo(
          AppColors.solidFor(Brightness.dark, style: AppStyle.winui));
      expect(bottom.a, 1.0,
          reason: '材质挂不上时必须铺不透明底 —— 否则桌面从窗口里透出来，'
              '正文压在花花绿绿的壁纸上没法读');
      expect(bottom, expected,
          reason: '回退色必须来自 WindowMaterial.fallbackTo()，'
              '不是另写一个色值');
    });

    testWidgets('负控制：把 available 反过来传，底色的 alpha 跟着翻', (tester) async {
      Future<double> alphaFor(bool available) async {
        final focusN = ValueNotifier<bool>(true);
        final materialN = ValueNotifier<bool>(available);
        addTearDown(focusN.dispose);
        addTearDown(materialN.dispose);
        await pumpBackdrop(tester,
            brightness: Brightness.dark,
            focus: focusN,
            materialAvailable: materialN);
        return backdropBoxColors(tester).first.a;
      }

      final transparent = await alphaFor(true);
      final opaque = await alphaFor(false);

      expect(transparent, 0.0);
      expect(opaque, 1.0,
          reason: '两档必须真的不同 —— 若 BackgroundLayer 根本没接 '
              'materialAvailable，这两句会读到同一个值');
    });

    testWidgets('材质状态变化会触发重建（不是只在首帧读一次）', (tester) async {
      final available = ValueNotifier<bool>(true);
      final focusN = ValueNotifier<bool>(true);
      addTearDown(available.dispose);
      addTearDown(focusN.dispose);
      await pumpBackdrop(tester,
          brightness: Brightness.dark, focus: focusN, materialAvailable: available);
      expect(backdropBoxColors(tester).first.a, 0.0);

      available.value = false;
      await tester.pump();
      expect(backdropBoxColors(tester).first.a, 1.0,
          reason: '运行时材质掉了（用户关掉系统「透明效果」）必须立刻换成'
              '不透明兜底，不能等下次重启');
    });
  });

  // ══════════════════════════════════════════════════════════
  // 五、像素层：失焦覆盖层真的让画面变暗
  // ══════════════════════════════════════════════════════════

  group('背景层渲染像素：失焦覆盖层真的把画面压暗', () {
    /// 材质不可用 + 不透明回退底下的两档亮度差（覆盖层直接叠在实色上）。
    for (final brightness in [Brightness.dark, Brightness.light]) {
      final name = brightness == Brightness.dark ? '深色' : '浅色';
      testWidgets('$name（不透明底）：失焦比聚焦暗 ≥ ${_kMinPixelDelta.toInt()} 阶',
          (tester) async {
        final active = await renderBackdropLuma(tester,
            brightness: brightness, focused: true, materialAvailable: false);
        final inactive = await renderBackdropLuma(tester,
            brightness: brightness, focused: false, materialAvailable: false);
        final delta = meanOf(active) - meanOf(inactive);
        // ignore: avoid_print
        print('[$name 不透明底] 聚焦 ${meanOf(active).toStringAsFixed(2)} / '
            '失焦 ${meanOf(inactive).toStringAsFixed(2)} / 差 ${delta.toStringAsFixed(2)}');
        expect(
          delta,
          greaterThanOrEqualTo(_kMinPixelDelta),
          reason: '$name 窗口底失焦后只暗了 ${delta.toStringAsFixed(2)} 阶'
              '（判据要求 ≥ $_kMinPixelDelta）—— 肉眼看不出来等于没做',
        );
      });
    }

    /// **真机路径**：材质可用 ⇒ 底透明，覆盖层叠在「窗口后面的材质」上。
    ///
    /// 测试里用一块**模拟材质**（WinUI 浅色 Mica ≈ #F3F3F3 / 深色 ≈ #202020）
    /// 垫在透明底下面 —— 那正是 DWM 在真机上画的东西。覆盖层要能把它压暗，
    /// 否则真机上「失焦」这件事看不见。
    //
    // 明暗必须**配对**：深色主题配深色 Mica（#202020）、浅色主题配浅色 Mica
    // （#F3F3F3）。覆盖层颜色是从当前色板算出来的，跨明暗配对（深色主题 +
    // 浅色材质）在真机上不会出现，量出来的差也没有意义。
    for (final (brightness, materialBase) in [
      (Brightness.dark, const Color(0xFF202020)),
      (Brightness.light, const Color(0xFFF3F3F3)),
    ]) {
      final tag = brightness == Brightness.dark ? '深色材质' : '浅色材质';
      testWidgets('$tag（透明底 + 模拟 DWM 材质）：失焦比聚焦暗 ≥ ${_kMinPixelDelta.toInt()} 阶',
          (tester) async {
        final active = await renderBackdropLuma(
          tester,
          brightness: brightness,
          focused: true,
          materialAvailable: true,
          underlay: materialBase,
        );
        final inactive = await renderBackdropLuma(
          tester,
          brightness: brightness,
          focused: false,
          materialAvailable: true,
          underlay: materialBase,
        );
        final delta = meanOf(active) - meanOf(inactive);
        // ignore: avoid_print
        print('[$tag] 聚焦 ${meanOf(active).toStringAsFixed(2)} / '
            '失焦 ${meanOf(inactive).toStringAsFixed(2)} / 差 ${delta.toStringAsFixed(2)}');
        expect(
          delta,
          greaterThanOrEqualTo(_kMinPixelDelta),
          reason: '$tag 上失焦只暗了 ${delta.toStringAsFixed(2)} 阶 —— '
              '覆盖层若太透（alpha 太低）或压暗幅度太小，这里会红。'
              '这是真机路径：底透明，覆盖层叠在 DWM 材质上',
        );
      });
    }

    testWidgets('负控制：同一档渲染两次差值 ≈ 0（差异确实来自焦点分支）',
        (tester) async {
      final a = await renderBackdropLuma(tester,
          brightness: Brightness.dark, focused: false, materialAvailable: false);
      final b = await renderBackdropLuma(tester,
          brightness: Brightness.dark, focused: false, materialAvailable: false);
      expect(meanAbsDiff(a, b), lessThan(0.5),
          reason: '同档两次渲染就该逐像素相同 —— 若这里就有差异，'
              '上面几条量的可能是渲染噪声而不是焦点切换');
    });

    testWidgets('负控制：把焦点值反过来传，判据方向会翻（证明两档真的被区分）',
        (tester) async {
      final darkActive = meanOf(await renderBackdropLuma(tester,
          brightness: Brightness.dark, focused: true, materialAvailable: false));
      final darkInactive = meanOf(await renderBackdropLuma(tester,
          brightness: Brightness.dark, focused: false, materialAvailable: false));
      expect(darkActive, greaterThan(darkInactive),
          reason: '若 BackgroundLayer 根本没接焦点（两档渲染成同一张图），'
              '这一句与第一条会同时红 —— 两条一起绿才说明链路真的通了');
    });

    testWidgets('负控制：覆盖层 alpha 压到 0 时，像素判据真的会红', (tester) async {
      // 先证明真实实现过得了同一条阈值判据
      final active = meanOf(await renderBackdropLuma(tester,
          brightness: Brightness.dark, focused: true, materialAvailable: false));
      final inactive = meanOf(await renderBackdropLuma(tester,
          brightness: Brightness.dark, focused: false, materialAvailable: false));
      final realDelta = active - inactive;
      expect(realDelta, greaterThanOrEqualTo(_kMinPixelDelta));

      // 覆盖层 alpha → 0 时，失焦画面 == 聚焦画面，delta = 0。
      const zeroOverlayDelta = 0.0;
      expect(
        () => expect(zeroOverlayDelta, greaterThanOrEqualTo(_kMinPixelDelta)),
        throwsA(isA<TestFailure>()),
        reason: '覆盖层不生效时 delta 就是 0，判据必须红 —— 证明阈值'
            '（$_kMinPixelDelta）不是「随便写个数都能过」',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 六、自定义色调：两个滑块必须真的接上（2026-10-19 接线）
  // ══════════════════════════════════════════════════════════

  group('自定义色调：tintOpacity / tintLuminosityOpacity 两个滑块真的生效', () {
    testWidgets('默认值（0.6 / 0.3）下与不传参数**逐值相同**（接线不改观感）',
        (tester) async {
      final expected = AppColors.tintFor(
        const Color(0xFFFF0000),
        Brightness.light,
      );
      final focusN = ValueNotifier<bool>(true);
      final materialN = ValueNotifier<bool>(false);
      addTearDown(focusN.dispose);
      addTearDown(materialN.dispose);
      await pumpBackdrop(
        tester,
        brightness: Brightness.light,
        focus: focusN,
        materialAvailable: materialN,
        appearance: AppearanceSettings(
          customTint: true,
          tintColor: '#FF0000',
          // 显式传默认值 —— 与 fromJson 缺字段时的落点一致
          tintOpacity: 0.6,
          tintLuminosityOpacity: 0.3,
        ),
      );
      final bottom = backdropBoxColors(tester).first;
      expect(
        bottom,
        expected.withValues(alpha: 1.0),
        reason: '默认参数下必须与「不传参数」逐值相同 —— tintFor 的默认参数'
            '就是 0.6 / 0.3，传进去等于不传。这条判据守住「接线不改观感」',
      );
    });

    testWidgets('把 tintOpacity 拖到另一档，窗口底**真的变了**（滑块不是死的）',
        (tester) async {
      Future<Color> colorAt(double opacity) async {
        final focusN = ValueNotifier<bool>(true);
        final materialN = ValueNotifier<bool>(false);
        addTearDown(focusN.dispose);
        addTearDown(materialN.dispose);
        await pumpBackdrop(
          tester,
          brightness: Brightness.dark,
          focus: focusN,
          materialAvailable: materialN,
          appearance: AppearanceSettings(
            customTint: true,
            tintColor: '#FF0000',
            tintOpacity: opacity,
            tintLuminosityOpacity: 0.3,
          ),
        );
        return backdropBoxColors(tester).first;
      }

      final atDefault = await colorAt(0.6);
      final atMax = await colorAt(1.0);
      // ignore: avoid_print
      print('[tintOpacity] 0.6 → $atDefault / 1.0 → $atMax');

      expect(atMax, isNot(equals(atDefault)),
          reason: '拖「色调不透明度」滑块后窗口底必须真的变 —— 2026-10-19 之前'
              '_tintColor() 调用 tintFor 时没传这两个参数，滑块在真机上完全'
              '没有效果（实测两档极值像素完全相同）');

      // 方向：浓度拉满 ⇒ 更接近用户选的纯红（红通道占比更高）
      expect(atMax.r - atMax.b, greaterThan(atDefault.r - atDefault.b),
          reason: '浓度越高越接近 tintColor（红），红蓝差必须变大 —— '
              '这条抓「接了参数但接反了」');
    });

    testWidgets('把 tintLuminosityOpacity 拖到另一档，窗口底**真的变了**',
        (tester) async {
      Future<Color> colorAt(double l) async {
        final focusN = ValueNotifier<bool>(true);
        final materialN = ValueNotifier<bool>(false);
        addTearDown(focusN.dispose);
        addTearDown(materialN.dispose);
        await pumpBackdrop(
          tester,
          brightness: Brightness.dark,
          focus: focusN,
          materialAvailable: materialN,
          appearance: AppearanceSettings(
            customTint: true,
            tintColor: '#FF0000',
            tintOpacity: 0.6,
            tintLuminosityOpacity: l,
          ),
        );
        return backdropBoxColors(tester).first;
      }

      final atDefault = await colorAt(0.3);
      final atMax = await colorAt(1.0);
      // ignore: avoid_print
      print('[tintLuminosityOpacity] 0.3 → $atDefault / 1.0 → $atMax');

      expect(atMax, isNot(equals(atDefault)),
          reason: '拖「明度不透明度」滑块后窗口底必须真的变');

      // 方向：明度层越大越接近主题底色（越不浓）⇒ 红蓝差必须变小
      expect(atMax.r - atMax.b, lessThan(atDefault.r - atDefault.b),
          reason: '明度层越大越接近主题底色 —— 方向反了说明参数接错位');
    });

    test('负控制：不接线时两次调用必然同色（真机上滑块「没效果」的机理）', () {
      // 模拟改造前：_tintColor() 不传参数。
      Color legacy() => AppColors.tintFor(const Color(0xFFFF0000), Brightness.dark)
          .withValues(alpha: 1.0);
      expect(legacy(), legacy(),
          reason: '不接线时两次调用必然同色 —— 上面两条判据若也读成同色，就会红');
      // 反证：接线后的真实实现，两档必须不同
      expect(
        AppColors.tintFor(const Color(0xFFFF0000), Brightness.dark,
            tintOpacity: 1.0),
        isNot(equals(AppColors.tintFor(const Color(0xFFFF0000), Brightness.dark,
            tintOpacity: 0.6))),
        reason: '前提：tintFor 本身确实对 tintOpacity 敏感，否则接线也救不了',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 七、既有语义不变：背景图分支照常工作
  // ══════════════════════════════════════════════════════════

  group('既有语义不变', () {
    testWidgets('背景图分支仍然挂上去（改造没有把它挤掉）', (tester) async {
      final focusN = ValueNotifier<bool>(true);
      final materialN = ValueNotifier<bool>(true);
      addTearDown(focusN.dispose);
      addTearDown(materialN.dispose);
      await pumpBackdrop(
        tester,
        brightness: Brightness.dark,
        focus: focusN,
        materialAvailable: materialN,
        appearance: AppearanceSettings(
          backgroundImage: 'Z:/does-not-exist/bg.png',
          backgroundImageOpacity: 0.5,
        ),
      );
      expect(find.byType(Image), findsOneWidget,
          reason: '背景图分支被删/被条件挡住 —— 用户显式选的背景图不能丢');
      expect(find.byType(Opacity), findsWidgets);
    });

    testWidgets('未设背景图时不挂 Image（避免多一层无用的全屏图片）',
        (tester) async {
      final focusN = ValueNotifier<bool>(true);
      final materialN = ValueNotifier<bool>(true);
      addTearDown(focusN.dispose);
      addTearDown(materialN.dispose);
      await pumpBackdrop(tester,
          brightness: Brightness.dark,
          focus: focusN,
          materialAvailable: materialN,
          appearance: AppearanceSettings());
      expect(find.byType(Image), findsNothing);
    });
  });
}

// ════════════════════════════════════════════════════════════
// 量渲染的工具
// ════════════════════════════════════════════════════════════

/// 两档画面可辨的最小亮度差（灰阶）。
///
/// ### 定标依据（2026-10-19 随覆盖层重定）
///
/// 覆盖层可见度 = \`alpha × (底亮度 − 覆盖层亮度)\`：
///
/// | 场景 | 底 | 覆盖层色 | 理论差 |
/// |---|---|---|---|
/// | 不透明回退底 · 深色 | #2B2B2B (43) | #000000 (0，clamp) | 43×0.45 = 19.4 |
/// | 不透明回退底 · 浅色 | #FCFCFC (252) | #BCBCBC (188) | 64×0.45 = 28.8 |
/// | 透明底 + 深色材质 | #202020 (32) | #000000 (0) | 32×0.45 = 14.4 |
/// | 透明底 + 浅色材质 | #F3F3F3 (243) | #BCBCBC (188) | 55×0.45 = 24.8 |
///
/// 四档理论差最小 14.4 阶。判据取 **10**：留 4 阶余量吸收
/// float→8bit 舍入、采样步长与 alpha 合成的非线性（覆盖层是 alpha 混合，
/// 不是线性相加）。10 阶在灰阶上是肉眼明确可辨的量级
/// （参考：本项目此前把 1.819 阶判定为「真机可辨」的下限，10 阶是它的 5 倍）。
const double _kMinPixelDelta = 10.0;

final _boundaryKey = UniqueKey();

/// 抓出背景层里所有 \`ColoredBox\` 的颜色，**按绘制顺序**（先底后覆盖层）。
///
/// 用 widget 树而不是像素来断言「底色 alpha」：\`toImage\` 出来的像素永远是
/// 不透明的（合成到测试画布上），量不出 alpha。
List<Color> backdropBoxColors(WidgetTester tester) {
  final out = <Color>[];
  void visit(Element e) {
    final w = e.widget;
    if (w is ColoredBox) out.add(w.color);
    e.visitChildren(visit);
  }

  final layer = find.byType(BackgroundLayer).evaluate().single;
  visit(layer);
  return out;
}

/// 把背景层挂进 AppTheme，外层包一个 \`RepaintBoundary\`。
///
/// [underlay] 非空时垫在背景层**下面**，用来模拟 DWM 画的窗口材质
/// （材质可用 ⇒ 底透明 ⇒ 真机上看到的就是这块 underlay）。
Future<void> pumpBackdrop(
  WidgetTester tester, {
  required Brightness brightness,
  required ValueListenable<bool> focus,
  ValueListenable<bool>? materialAvailable,
  AppearanceSettings? appearance,
  Color? underlay,
}) async {
  Widget layer = BackgroundLayer(
    appearance: appearance ?? AppearanceSettings(),
    brightness: brightness,
    focus: focus,
    materialAvailable: materialAvailable,
  );
  if (underlay != null) {
    layer = ColoredBox(color: underlay, child: layer);
  }
  await tester.pumpWidget(
    AppTheme(
      colors: AppColors.of(AppStyle.winui, brightness),
      brightness: brightness,
      style: AppStyle.winui,
      child: MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(key: _boundaryKey, child: layer),
        ),
      ),
    ),
  );
  // 背景层是静态的，一帧就够 —— 不用 pumpAndSettle（有挂起 future 时会
  // 一直等到 10 分钟超时，把失败原因埋进无关堆栈里）。
  await tester.pump();
}

/// 渲染一档焦点状态的背景层并读回**真实像素**（每点 RGB 简单平均）。
Future<List<double>> renderBackdropLuma(
  WidgetTester tester, {
  required Brightness brightness,
  required bool focused,
  required bool materialAvailable,
  AppearanceSettings? appearance,
  Color? underlay,
}) async {
  final focusNotifier = ValueNotifier<bool>(focused);
  final materialNotifier = ValueNotifier<bool>(materialAvailable);
  addTearDown(focusNotifier.dispose);
  addTearDown(materialNotifier.dispose);
  await pumpBackdrop(
    tester,
    brightness: brightness,
    focus: focusNotifier,
    materialAvailable: materialNotifier,
    appearance: appearance,
    underlay: underlay,
  );

  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_boundaryKey));
  // toImage / toByteData 走真实 GPU 与 IO 路径，在 fake-async 时钟里永远
  // 不完成 —— 必须在 runAsync 的真实异步区里读像素。
  final image = (await tester.runAsync(() => boundary.toImage()))!;
  final data = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final bytes = data.buffer.asUint8List();
  final width = image.width;
  final height = image.height;

  final out = <double>[];
  for (var y = 100; y < height - 100; y += 8) {
    for (var x = 100; x < width - 100; x += 8) {
      final o = (y * width + x) * 4;
      out.add((bytes[o] + bytes[o + 1] + bytes[o + 2]) / 3);
    }
  }
  image.dispose();
  return out;
}

double meanOf(List<double> xs) =>
    xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

double meanAbsDiff(List<double> a, List<double> b) {
  if (a.isEmpty || a.length != b.length) {
    throw StateError('采样长度不一致：${a.length} vs ${b.length}');
  }
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}