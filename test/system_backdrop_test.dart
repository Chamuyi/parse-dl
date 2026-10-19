import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parse_dl/services/system_backdrop.dart';
import 'package:parse_dl/theme/window_material.dart';

/// `SystemBackdrop` 的判据：**类型映射** + **容错路径**。
///
/// ### 为什么这两件事必须分开测
///
/// ① 映射是纯函数（[backdropTypeOf]），可以逐档钉死；
/// ② 容错（`MissingPluginException` / `PlatformException` / 非 Windows）
///    必须走**真的平台通道**才能触发 —— 用 mock handler 让它真的抛，
///    而不是在测试里假装「捕获了异常」。
///
/// 两类判据都配负控制：把实现换坏之后，同一段断言必须抛 `TestFailure`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('parse_dl/system_backdrop');

  /// 记录 mock handler 收到的调用，供「参数 map 形状」判据使用。
  final calls = <MethodCall>[];

  /// 装一个 mock handler；`reply` 决定它返回什么或抛什么。
  ///
  /// 返回的 `Future` 在 tearDown 里必须清掉 handler，否则通道会跨用例串味。
  void mockBackdrop(Future<Object?> Function(MethodCall call) reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return reply(call);
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  }

  /// 让平台探针恒为「支持」—— 判据要在任意主机（含 CI 的 Linux）上跑。
  ///
  /// 探针是静态可替换字段，**必须还原**，否则会影响同进程里的其他用例。
  void pretendWindows() {
    final original = SystemBackdrop.platformProbe;
    SystemBackdrop.platformProbe = () => true;
    addTearDown(() => SystemBackdrop.platformProbe = original);
  }

  setUp(calls.clear);

  // ══════════════════════════════════════════════════════════
  // 一、类型映射（纯函数）
  // ══════════════════════════════════════════════════════════

  /// 判据本体：四档逐档钉死到契约里的 type 字符串。
  ///
  /// 抽成函数是为了让**负控制**能拿同一段断言去跑坏实现 ——
  /// 断言要是恒真，坏实现也会绿，负控制就抓不到它。
  void assertTypeMapping(String Function(WindowMaterial?) f) {
    expect(f(WindowMaterial.mica), 'mica');
    expect(f(WindowMaterial.micaAlt), 'mica-alt');
    expect(f(WindowMaterial.acrylic), 'acrylic');
    expect(f(WindowMaterial.acrylicThin), 'acrylic-thin');
  }

  group('类型映射：WindowMaterial → 契约 type 字符串', () {
    test('四档逐档钉死', () {
      assertTypeMapping(backdropTypeOf);
    });

    test('四档互不相同（细亚克力不再与亚克力合并）', () {
      final types = WindowMaterial.values.map(backdropTypeOf).toSet();
      expect(
        types.length,
        4,
        reason: '四档必须产出四个不同的 type —— 这正是换掉 flutter_acrylic '
            '的理由：它把 acrylic-thin 与 acrylic 落到同一个 DWM 效果，'
            '真机两档像素完全相同（实测差 0）',
      );
    });

    test('null → "none"（契约里「关闭材质」那一档）', () {
      expect(backdropTypeOf(null), 'none');
      expect(kBackdropNone, 'none',
          reason: '常量与契约字符串必须一致 —— 原生侧认的是字面量');
    });

    test('四档材质**都不会**误产出 "none"', () {
      // 「none」是「关掉材质」，不是任何一档材质的落点。
      // 若映射写成「查不到就返回 none」，这条会红 —— 那时用户选了材质
      // 却得到「没有材质」，而且没有任何报错。
      for (final m in WindowMaterial.values) {
        expect(backdropTypeOf(m), isNot(kBackdropNone),
            reason: '$m 必须映射到具体材质，不能落到 none');
      }
    });

    test('负控制：四档全返回 mica 时逐档判据会红', () {
      expect(
        () => assertTypeMapping((_) => 'mica'),
        throwsA(isA<TestFailure>()),
        reason: '恒返回 mica 时逐档判据必须红 —— 否则它测不出映射退化',
      );
    });

    test('负控制：把 acrylic 与 acrylic-thin 互换也会红', () {
      expect(
        () => assertTypeMapping((m) => switch (m) {
              WindowMaterial.mica => 'mica',
              WindowMaterial.micaAlt => 'mica-alt',
              WindowMaterial.acrylic => 'acrylic-thin',
              WindowMaterial.acrylicThin => 'acrylic',
              null => 'none',
            }),
        throwsA(isA<TestFailure>()),
        reason: '两档亚克力对调后逐档判据必须红',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 二、通道调用：参数 map 的形状（与原生侧冻结的契约）
  // ══════════════════════════════════════════════════════════

  group('通道调用：方法名与参数 map 与契约一致', () {
    test('方法名是 setBackdrop，参数恰好三个键', () async {
      pretendWindows();
      mockBackdrop((_) async => true);

      await SystemBackdrop.apply(
        WindowMaterial.acrylicThin,
        dark: true,
        active: false,
      );

      expect(calls, hasLength(1));
      final call = calls.single;
      expect(call.method, 'setBackdrop',
          reason: '方法名冻结 —— 改它原生侧就认不出');
      final args = Map<String, Object?>.from(call.arguments as Map);
      expect(args.keys.toSet(), {'type', 'dark', 'active'},
          reason: '参数必须**恰好**这三个键：多传会让原生侧解析失败，'
              '少传会让材质退回默认档');
      expect(args['type'], 'acrylic-thin');
      expect(args['dark'], isTrue);
      expect(args['active'], isFalse);
    });

    test('dark / active 原样透传（不被材质类型污染）', () async {
      pretendWindows();
      mockBackdrop((_) async => true);

      // 四种「材质 × 明暗 × 焦点」组合，逐一看参数有没有被改。
      for (final dark in [true, false]) {
        for (final active in [true, false]) {
          calls.clear();
          await SystemBackdrop.apply(
            WindowMaterial.mica,
            dark: dark,
            active: active,
          );
          final args = Map<String, Object?>.from(
              calls.single.arguments as Map);
          expect(args['dark'], dark,
              reason: 'dark 必须原样透传 —— 它描述窗口外观的明暗，'
                  '与选哪种材质无关（2026-10-15 修过的真 bug）');
          expect(args['active'], active);
        }
      }
    });

    test('负控制：少传一个键的坏实现会被上面的形状判据抓住', () async {
      pretendWindows();
      // 复刻「漏了 active」的坏实现。
      mockBackdrop((call) async {
        final args = Map<String, Object?>.from(call.arguments as Map);
        return args.length == 3;
      });
      // 直接用坏实现的参数形状去断言，必须红。
      final brokenArgs = <String, Object?>{'type': 'mica', 'dark': true};
      expect(
        () => expect(brokenArgs.keys.toSet(), {'type', 'dark', 'active'}),
        throwsA(isA<TestFailure>()),
        reason: '漏掉 active 时形状判据必须红 —— 否则「恰好三个键」是恒真的',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 二之二、焦点接线：app.dart 必须把 active 跟着焦点重下发
  // ══════════════════════════════════════════════════════════
  //
  // 这一组钉的是 `app.dart` 的**调用形态** —— 纯函数判据看不到它。
  //
  // 为什么必须接：合成控制器靠 `active` 切「不活跃」档。不接的话材质会
  // 一直停在启动时那一档，失焦与聚焦长得一模一样（那正是 WinUI 招牌行为
  // 缺失的观感）。

  group('源码守卫：焦点变化重下发 active', () {
    /// 去掉 `//` 行注释，只留真正的代码。
    ///
    /// 必须先剥注释再判 —— 否则「解释旧写法」的注释本身会命中判据。
    String stripLineComments(String src) => src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('app.dart 订阅了焦点，并把 active 传给 applyWindowMaterial', () {
      final code = stripLineComments(
          File('lib/app.dart').readAsStringSync());

      expect(code, contains('windowFocus.focused.addListener('),
          reason: '没订阅焦点 ⇒ 失焦时不会重下发，材质永远停在启动档');
      expect(code, contains('windowFocus.focused.removeListener('),
          reason: '本项目硬规矩：每个 addListener 都要有 removeListener，'
              '否则监听器泄漏');
      expect(code, contains('active: windowFocus.isFocused'),
          reason: '重下发时必须带 active —— 不带就退回「启动时那一档」，'
              '焦点接线等于没做');
    });

    test('负控制：注释里的旧写法会被剥掉（否则守卫是恒绿的）', () {
      const src = '''
// windowFocus.focused.addListener(_onWindowFocusChanged);
final r = await applyWindowMaterial(m, dark: d);''';
      final code = stripLineComments(src);
      expect(code, isNot(contains('windowFocus.focused.addListener(')),
          reason: '注释里的订阅要被剥掉');
      expect(code, isNot(contains('active: windowFocus.isFocused')),
          reason: '剥完后不该还有 active 参数 —— 若这里还有，说明剥注释'
              '没生效，上面那条判据会在「只写了注释」时假绿');
    });

    test('负控制：未接焦点的实现会被上面那条判据抓住', () {
      // 复刻「只传 dark、不传 active」的坏实现。
      const broken = 'final r = await applyWindowMaterial(m, '
          'dark: brightness == Brightness.dark);';
      expect(
        () => expect(broken, contains('active: windowFocus.isFocused')),
        throwsA(isA<TestFailure>()),
        reason: '不传 active 时判据必须红 —— 否则它测不出焦点接线缺失',
      );
    });
  });

  // ══════════════════════════════════════════════════════════
  // 三、容错：任何失败都返回 false，绝不抛异常
  // ══════════════════════════════════════════════════════════

  group('容错：材质挂不上不能让界面崩', () {
    test('原生返回 true → true', () async {
      pretendWindows();
      mockBackdrop((_) async => true);
      expect(
        await SystemBackdrop.apply(WindowMaterial.mica,
            dark: false, active: true),
        isTrue,
      );
    });

    test('原生返回 false（系统不支持）→ false，不抛', () async {
      pretendWindows();
      mockBackdrop((_) async => false);
      expect(
        await SystemBackdrop.apply(WindowMaterial.mica,
            dark: false, active: true),
        isFalse,
      );
    });

    test('原生返回 null → false（不猜成「已应用」）', () async {
      pretendWindows();
      mockBackdrop((_) async => null);
      expect(
        await SystemBackdrop.apply(WindowMaterial.mica,
            dark: false, active: true),
        isFalse,
        reason: '没有返回值时猜成 true 会让窗口底保持透明，桌面从窗口里'
            '透出来 —— 必须按「没应用上」处理',
      );
    });

    test('MissingPluginException → false（原生插件没编进产物）', () async {
      pretendWindows();
      // 不装 handler ⇒ invokeMethod 真的抛 MissingPluginException，
      // 走的是真异常路径，不是测试里手工 catch。
      expect(
        await SystemBackdrop.apply(WindowMaterial.mica,
            dark: false, active: true),
        isFalse,
        reason: '通道不存在时必须返回 false 而不是把 MissingPluginException '
            '抛给界面 —— 材质挂不上不能让界面崩（项目既有约定）',
      );
    });

    test('PlatformException → false（原生侧明确报错）', () async {
      pretendWindows();
      mockBackdrop((_) async =>
          throw PlatformException(code: 'unsupported', message: 'too old'));
      expect(
        await SystemBackdrop.apply(WindowMaterial.acrylic,
            dark: true, active: true),
        isFalse,
        reason: '原生侧报错必须折成 false —— 不能把 PlatformException '
            '抛进 UI 层',
      );
    });

    test('非 Windows 平台 → false，且**根本不碰通道**', () async {
      mockBackdrop((_) async => true); // 若被调用，会返回 true
      SystemBackdrop.platformProbe = () => false;
      addTearDown(() => SystemBackdrop.platformProbe = () => Platform.isWindows);

      expect(
        await SystemBackdrop.apply(WindowMaterial.mica,
            dark: false, active: true),
        isFalse,
      );
      expect(calls, isEmpty,
          reason: '非 Windows 上不该打通道 —— 打了也没有原生实现，'
              '只会多一次无谓的异常与日志');
    });

    test('负控制：不接住异常的实现会让「MissingPluginException」判据变红',
        () async {
      // 复刻「没有 try/catch」的坏实现：直接 await 通道。
      pretendWindows();
      Future<bool> broken() async {
        final r = await channel.invokeMethod<bool>(
          'setBackdrop',
          <String, Object?>{'type': 'mica', 'dark': false, 'active': true},
        );
        return r ?? false;
      }

      // 正控制：真实现返回 false。
      expect(
        await SystemBackdrop.apply(WindowMaterial.mica,
            dark: false, active: true),
        isFalse,
      );
      // 负控制：坏实现必须真的把异常抛出来。
      await expectLater(
        broken(),
        throwsA(isA<MissingPluginException>()),
        reason: '没有 try/catch 时通道缺失会直接抛 —— 这正是要被接住的那条路径。'
            '若这里没抛，说明测试环境里通道其实存在，'
            '上面「MissingPluginException → false」就不是在测真异常',
      );
    });
  });
}
