library;

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:window_manager/window_manager.dart';

/// 窗口**激活状态**来源 —— 照抄 WinUI3「失焦时材质变灰」的招牌行为。
///
/// ### 参照物（已核实的源码）
///
/// `F:\samples\_verify\tubatool` 里 `TubaWinUi3.WinUI3/Services/BackdropService.cs`
/// 第 51-55 行：
///
/// ```csharp
/// public void OnActivated(object sender, WindowActivatedEventArgs args) {
///     if (IsDisposed) return;
///     Configuration.IsInputActive =
///         args.WindowActivationState != WindowActivationState.Deactivated;
/// }
/// ```
///
/// WinUI 的 `MicaController` 读 `IsInputActive` 自己把材质切成「不活跃」档
/// （去饱和 + 压亮度）。用户一眼就能看出这个窗口当前不是前台窗口。
///
/// ### 我方能力边界（实测，不是没做）
///
/// 本项目的窗口材质由 DWM 画（`flutter_acrylic` 走 `DwmSetWindowAttribute`），
/// **没有 `IsInputActive` 这个开关**，无法让系统替我们切不活跃档。
///
/// ### 2026-10-19 语义变更：从「改窗口底色」改成「叠覆盖层」
///
/// 旧设计是「失焦时把窗口底色算暗一档」。那套在**窗口底透明**之后失效了 ——
/// 透明底没有颜色可改，改它等于没改（材质由 DWM 画在窗口**后面**，
/// Flutter 侧拿不到它，也就改不动它）。
///
/// 现在窗口底是 `Colors.transparent`（让材质原样透上来），失焦改由**叠一层
/// 半透明覆盖层**表达：[windowInactiveOverlay] 返回覆盖层的颜色，聚焦时是
/// 全透明（不叠任何东西）。覆盖层压在材质与背景图之上，所以两者一起变灰 ——
/// 这正是 WinUI 失焦的观感。
///
/// [windowBackdropColor] 保留并复用：它算出的「不活跃档颜色」正好就是覆盖层
/// 该用的颜色，只是不再铺成整块窗口底，而是按 [kInactiveOverlayOpacity]
/// 稀释成一层纱。

/// 覆盖层颜色相对底色**亮度**下降的绝对量，单位灰阶（0~255）。
///
/// ### 为什么用绝对量而不是乘一个系数
///
/// 深色色板的窗口底是 `#2B2B2B`（43 阶）。按 0.9 去乘只降 4 阶 ——
/// 覆盖层颜色与材质亮度差太小，叠上去肉眼与像素判据都量不出来，等于没做。
///
/// ### 64 阶的定标依据（2026-10-19 改，原值 18）
///
/// 覆盖层的可见度 = `alpha × (材质亮度 − 覆盖层亮度)`，**不是** alpha 本身。
/// 浅色材质接近纯白（实测 Windows 11 浅色 Mica 约 `#F3F3F3` = 243 阶），
/// 若覆盖层只比底色暗 18 阶（234），叠 45% 后只差 `0.45 × (243−234) ≈ 4` 阶
/// —— 那是量不出来的。取 64 阶后：
///
/// | 色板 | 底色 | 覆盖层色 | 压在材质上（alpha 0.45） | 差值 |
/// |---|---|---|---|---|
/// | 深色 | `#2B2B2B` (43) | `#000000` (0，clamp) | 32 → 17.6 | 14.4 |
/// | 浅色 | `#FCFCFC` (252) | `#BCBCBC` (188) | 243 → 218.2 | 24.8 |
///
/// 两档都 ≥ 14 阶，远超「一眼能看出」的门槛（判据取 10，见
/// `test/window_focus_test.dart`）。深色档的覆盖层会被 clamp 到纯黑 ——
/// 这不是 bug：深色窗口底本来就接近黑，再压只能压到 0。
const double kInactiveLumaDrop = 64;

/// 覆盖层的不透明度。
///
/// 0.45 是「既看得出来、又不盖死材质」的平衡点：
///   - 再低（0.2 以下）覆盖层与材质的亮度差被稀释到 5 阶以内，看不出窗口失活；
///   - 再高（0.7 以上）材质只剩不到三成，Mica 的壁纸纹路与亚克力的透光都没了
///     —— 那等于「失焦时把材质关掉」，与 WinUI 的观感相反。
///
/// 0.45 保留 55% 的材质透出，同时把整体亮度压下去一档。
const double kInactiveOverlayOpacity = 0.45;

/// 失焦时向自身灰靠拢的比例（0 = 不去饱和，1 = 完全灰）。
///
/// WinUI 不活跃材质最显眼的特征不是「暗」而是「灰」：桌面壁纸有颜色时，
/// 活跃窗口的 Mica 带壁纸色，失焦后整片变中性灰。我方覆盖层平时是中性色
/// （`surfaceSolid`），去饱和对它几乎无影响；但对**自定义色调**
/// （[`AppColors.tintFor`] 出的带彩底）效果明显 —— 那才是需要这一项的分支。
const double kInactiveDesaturate = 0.5;

/// 焦点 → **失焦覆盖层**的颜色。**纯函数**：不碰 `BuildContext`、不读全局
/// 状态、不碰平台通道，因此可以脱离 widget 树直接单测
/// （`test/window_focus_test.dart`）。
///
/// [focused] 为真时返回 [Colors.transparent] —— 聚焦档**不叠任何东西**，
/// DWM 材质原样呈现。这一条是判据「聚焦档不叠覆盖层」的唯一出处。
///
/// 失焦档做三件事，顺序固定：
///   1. **去饱和**：每个通道向自身亮度靠拢 [kInactiveDesaturate]；
///   2. **压亮度**：三通道同减 [kInactiveLumaDrop] / 255（绝对值，clamp 到 0）；
///   3. **稀释成纱**：alpha 取 [kInactiveOverlayOpacity]（不用 [base] 的 alpha
///      —— 自定义色调的底是 85% 不透明，拿它当覆盖层透明度会让覆盖层随
///      色调设置漂移，同一个「不活跃」档在不同设置下强度不同）。
Color windowInactiveOverlay(Color base, {required bool focused}) {
  if (focused) return Colors.transparent;
  return windowBackdropColor(base, focused: false)
      .withValues(alpha: kInactiveOverlayOpacity);
}

/// 底色 → **不活跃档**颜色。纯函数。
///
/// 这是 [windowInactiveOverlay] 的颜色内核，单独暴露是为了让「去饱和」与
/// 「压亮度」两步能各自被断言方向（`test/window_focus_test.dart` 的负控制
/// 会分别把这两步改坏，证明判据真的抓得到）。
///
/// [focused] 为真时**原样返回 [base]**（不是「重算出一个相等的值」）——
/// 聚焦档必须与色板逐值相同，否则「聚焦时外观不变」这条前提就没了。
///
/// 失焦档：先去饱和（每通道向 Rec.709 亮度靠拢 [kInactiveDesaturate]），
/// 再三通道同减 [kInactiveLumaDrop] / 255（绝对值，clamp 到 0）。
/// alpha 原样保留 —— 透明度由 [windowInactiveOverlay] 统一决定。
Color windowBackdropColor(Color base, {required bool focused}) {
  if (focused) return base;

  final double r = base.r;
  final double g = base.g;
  final double b = base.b;

  // Rec.709 相对亮度（0~1）。与「三通道简单平均」不同：人眼对绿最敏感，
  // 用等权平均会把 #FF0000 与 #00FF00 算成同一个亮度。
  final double luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;

  final double dr = r + (luma - r) * kInactiveDesaturate;
  final double dg = g + (luma - g) * kInactiveDesaturate;
  final double db = b + (luma - b) * kInactiveDesaturate;

  final double drop = kInactiveLumaDrop / 255;

  return Color.from(
    alpha: base.a,
    red: _clamp01(dr - drop),
    green: _clamp01(dg - drop),
    blue: _clamp01(db - drop),
  );
}

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// 窗口焦点状态来源：把 `window_manager` 的焦点事件转成一个可监听的值。
///
/// `window_manager` 0.4.3 的 [WindowListener] 提供 `onWindowFocus` /
/// `onWindowBlur`（见其 `lib/src/window_listener.dart:6,9`），由
/// `WindowManager.instance.addListener` 注册、`removeListener` 移除。
///
/// ### 为什么 `attach` 不写在构造函数里
///
/// 写进去就没法单测了：构造即注册，测「失焦值对不对」也得先碰全局
/// `WindowManager.instance`。拆成显式 [attach] / [detach] 之后，
/// 测试可以直接 new 一个实例、手工调 `onWindowBlur()` 驱动状态，
/// 另用一条独立判据守「attach/detach 真的进了/出了监听器列表」。
class WindowFocusSource with WindowListener {
  WindowFocusSource();

  final ValueNotifier<bool> _focused = ValueNotifier<bool>(true);

  /// 当前窗口是否处于激活（有焦点）状态。
  ///
  /// 初值 `true`：应用刚起来时窗口是激活的。反过来的初值会让每次冷启动
  /// 先闪一帧「不活跃」的灰纱，再被 `onWindowFocus` 纠正 —— 那才是 bug。
  ValueListenable<bool> get focused => _focused;

  bool get isFocused => _focused.value;

  /// 挂到 `windowManager` 上。**必须与 [detach] 配对**：本项目硬规矩是
  /// 每个 `addListener` 都要有对应的 `removeListener`，否则监听器泄漏
  /// （[WindowManager] 内部是 `ObserverList`，持有引用不放）。
  void attach() => windowManager.addListener(this);

  void detach() => windowManager.removeListener(this);

  /// 卸载并释放。销毁顺序固定：先 [detach] 再 dispose —— 反过来的话，
  /// 已 dispose 的 [ValueNotifier] 再收到一次事件就会抛
  /// 「A `ValueNotifier<bool>` was used after being disposed」。
  void dispose() {
    detach();
    _focused.dispose();
  }

  @override
  void onWindowFocus() => _set(true);

  @override
  void onWindowBlur() => _set(false);

  /// 只在**值真的变了**时才通知。`window_manager` 在窗口拖动、连续点击时
  /// 可能重复派发同一个事件，无条件赋值会让整棵背景层白白重建。
  void _set(bool v) {
    if (_focused.value == v) return;
    _focused.value = v;
  }
}

/// 应用级单例，[BackgroundLayer] 从这里读焦点状态。
///
/// 顶层 `final` 在 Dart 里是**懒初始化**：第一次被读到时才构造并 [attach]。
/// 所以纯 Dart 单测（只测 [windowInactiveOverlay]）不会碰到 `windowManager`，
/// 也不需要 `TestWidgetsFlutterBinding`。
final WindowFocusSource windowFocus = WindowFocusSource()..attach();