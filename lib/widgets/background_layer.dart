import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/settings.dart';
import '../services/window_focus.dart';
import '../services/window_material_state.dart';
import '../theme/app_theme.dart';
import '../theme/window_material.dart';

/// 窗口最底层的底与背景图，以及失焦覆盖层。
///
/// ### 2026-10-19 大瘦身（用户裁定「窗口材质怎么没删」）
///
/// 曾经这里有一整套「按材质画窗口底」的绘制器：`_StyleBackdropWash` +
/// `_BackdropPainter` + `_MaterialSheetPainter`（含磨砂颗粒纹理、Mica Alt
/// 分层接缝、四种材质各自的底色与透光率），约 280 行。
///
/// 材质只剩 Mica 一档之后，那一整套**全部没有对象了**：微软官方文档规定
/// 长驻窗口的底由 DWM 画一层 Mica（`DWMSBT_MAINWINDOW`），应用侧不该再画
/// 自己的材质 —— 自己画反而会和系统那层打架。
///
/// ### 2026-10-19 第二轮：窗口底改**透明**（用户裁定「照抄图吧」）
///
/// 上一版仍然铺一层**完全不透明**的实色底（`solidFor()`，alpha 0xFF）。
/// 后果是四档材质在真机上是四张一模一样的图 —— Flutter 画的不透明像素
/// 会把 DWM 画的材质**整个盖住**。
///
/// 参照物 `tubatool/TubaWinUi3.WinUI3/MainWindow.xaml:279-281` 的做法是
/// 把内容区背景**显式改成透明`Transparent``，让 DWM 材质直接透上来：
///
/// ```xml
/// <NavigationView.Resources>
///     <SolidColorBrush x:Key="NavigationViewContentBackground" Color="Transparent" />
/// </NavigationView.Resources>
/// ```
///
/// 现在本层按 [windowMaterialAvailable] 二选一：
///
/// | 材质 | 底 |
/// |---|---|
/// | 可用 | `Colors.transparent`（DWM 材质原样透出） |
/// | 不可用 | `WindowMaterial.fallbackTo()` 的**不透明**纯色兜底 |
///
/// 后者是必需的：系统关掉「透明效果」/ 远程桌面 / Win10 上材质挂不上，
/// 此时底若还透明，桌面就从窗口里透出来，正文没法读。
///
/// ### 失焦变灰（照抄 WinUI3 的 `IsInputActive` 行为）
///
/// 底透明之后，失焦**不能再靠「改底色」**（底色已经没有颜色可改）。
///
/// **2026-10-19 改：材质可用时不再自己叠灰纱。**
///
/// 材质改由 WinUI 3 的合成控制器画（`MicaController` /
/// `DesktopAcrylicController`，见 `services/system_backdrop.dart`），
/// 它们自己读 `IsInputActive` 把材质切成不活跃档 —— 系统已经做了，
/// Flutter 再叠一层就是双重压暗，而且那层纱会盖住材质本身。
///
/// | 材质 | 失焦覆盖层 |
/// |---|---|
/// | 可用 | **不叠**（系统按 `IsInputActive` 处理） |
/// | 不可用 | 保留灰纱（[windowInactiveOverlay]） |
///
/// 后者必须保留：材质挂不上时窗口底是不透明回退色，没有任何系统材质可看，
/// 失焦不给视觉反馈的话用户分不清窗口在不在前台。
///
/// [windowInactiveOverlay] / [windowBackdropColor] 两个纯函数本身**保留**
/// 且签名不变（`test/window_focus_test.dart` 钉着它们）。
class BackgroundLayer extends StatelessWidget {
  final AppearanceSettings appearance;
  final Brightness brightness;

  /// 焦点来源。默认读应用级单例 [windowFocus]。
  ///
  /// 留这个口子是为了能测：像素判据要分别渲染「聚焦 / 失焦」两档并量差值，
  /// 而全局单例的值只能靠平台事件改 —— 测试里塞一个 [ValueNotifier] 就能
  /// 精确驱动，不必伪造平台通道。
  final ValueListenable<bool>? focus;

  /// 材质是否可用。默认读应用级单例 [windowMaterialAvailable]。
  ///
  /// 同上，留口子是为了能测「不可用时回退到不透明底」这条分支 ——
  /// 测试里塞一个值为 `false` 的 notifier 就行。
  final ValueListenable<bool>? materialAvailable;

  const BackgroundLayer({
    super.key,
    required this.appearance,
    required this.brightness,
    this.focus,
    this.materialAvailable,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final focusListenable = focus ?? windowFocus.focused;
    final materialListenable = materialAvailable ?? windowMaterialAvailable;

    return Stack(
      fit: StackFit.expand,
      children: [
        // ① 底：材质可用时**透明**（让 DWM 材质原样透出）；不可用时铺
        //    不透明的回退色兜底，不至于露出桌面。
        ValueListenableBuilder<bool>(
          valueListenable: materialListenable,
          builder: (_, available, _) => ColoredBox(
            color: _backdropColor(t, materialAvailable: available),
          ),
        ),

        // ①-b 细亚克力的通透膜（只有这一档非 null）。
        //
        // DWM 只有一档亚克力，细亚克力靠这层膜与普通亚克力区分开。
        // 见 backdropVeilOf 的注释：这是「材质差异做在调色层之上的可见层」
        // 那条架构结论的落地。
        //
        // 只在材质可用时叠：材质不可用时底色已是不透明回退色，再叠膜没有
        // 意义，还会让回退色偏离主题。
        ValueListenableBuilder<bool>(
          valueListenable: materialListenable,
          builder: (_, available, _) {
            if (!available) return const SizedBox.shrink();
            final veil = backdropVeilOf(appearance.windowMaterial, brightness);
            return veil == null
                ? const SizedBox.shrink()
                : IgnorePointer(child: ColoredBox(color: veil));
          },
        ),

        // ② 用户导入的背景图
        if (appearance.backgroundImage.isNotEmpty)
          Opacity(
            opacity: appearance.backgroundImageOpacity.clamp(0.0, 1.0),
            child: _BackgroundImage(path: appearance.backgroundImage),
          ),

        // ③ 失焦覆盖层。**只在材质不可用时叠**（2026-10-19 改）。
        //
        // 材质可用时失焦压暗由系统负责：WinUI 3 的 MicaController /
        // DesktopAcrylicController 读 IsInputActive 自己把材质切成不活跃档
        // （去饱和 + 压亮度）。我方再叠一层灰纱就是**双重压暗**，而且那层
        // 纱会盖住合成控制器画出来的材质 —— 正是本轮要消掉的东西。
        //
        // 材质不可用时保留原样：窗口底是不透明回退色，没有任何系统材质
        // 可看，失焦不给点视觉反馈的话用户分不清窗口在不在前台。
        //
        // 两个纯函数（windowInactiveOverlay / windowBackdropColor）都**保留**
        // 且签名不变 —— test/window_focus_test.dart 钉着它们。
        ValueListenableBuilder<bool>(
          valueListenable: materialListenable,
          builder: (_, available, _) => available
              ? const SizedBox.shrink()
              : ValueListenableBuilder<bool>(
                  valueListenable: focusListenable,
                  builder: (_, focused, _) => IgnorePointer(
                    child: ColoredBox(
                      color:
                          windowInactiveOverlay(_baseColor(t), focused: focused),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// 窗口底。
  ///
  /// 材质可用 ⇒ 透明（DWM 材质透上来）。**不铺任何颜色**是这套设计的关键：
  /// Flutter 画的不透明像素会把 DWM 那层整个盖住，四档材质就变成同一张图。
  ///
  /// 材质不可用 ⇒ [WindowMaterial.fallbackTo] 的**不透明**回退色。
  /// 回退色由主题底色派生（与材质档位无关，照抄参照物的
  /// `BackdropSettings.DeriveFallbackColor`）。
  Color _backdropColor(AppTheme t, {required bool materialAvailable}) {
    if (materialAvailable) return Colors.transparent;
    return appearance.windowMaterial.fallbackTo(_baseColor(t));
  }

  /// 基色：失焦覆盖层从它派生，材质不可用时也是回退色的来源。
  Color _baseColor(AppTheme t) => appearance.customTint
      ? _tintColor(t.colors, appearance.tintColor, brightness)
      : AppColors.solidFor(brightness, style: t.style);

  /// 自定义色调：强调色与主题底色按比例混合（不是直接铺强调色）。
  ///
  /// 直接铺满会在深色下变成一大片刺眼的亮色，浅色文字压上去几乎看不见 ——
  /// 这里踩过坑，所以走 [AppColors.tintFor]。
  ///
  /// 两个滑块参数必须**真的传进去**：2026-10-19 之前这里调用时没传，
  /// 用户在设置里拖「色调不透明度 / 明度不透明度」两档在真机上毫无反应
  /// （滑块是死的）。默认值 0.6 / 0.3 恰好是 [AppColors.tintFor] 的默认
  /// 参数，所以默认配置下的输出与改造前逐值相同。
  Color _tintColor(AppColors c, String hex, Brightness brightness) {
    final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
    if (v == null) return AppColors.solidFor(brightness);
    return AppColors.tintFor(
      Color(0xFF000000 | v),
      brightness,
      tintOpacity: appearance.tintOpacity,
      tintLuminosityOpacity: appearance.tintLuminosityOpacity,
    );
  }
}

/// 背景图。用 Image.file 直接读本地文件。
class _BackgroundImage extends StatelessWidget {
  final String path;

  const _BackgroundImage({required this.path});

  @override
  Widget build(BuildContext context) {
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
}