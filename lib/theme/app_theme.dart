import 'package:flutter/material.dart';

import 'app_style.dart';
import 'style_colors.dart';
import 'winui_accent.dart';

/// 「已识别 / 已勾选」的黄色描边色。
///
/// 页面上那一圈黄框是注入脚本 `markNode` 画的，色值写死在 JS 字符串里
/// （`douyin_interceptor_js.dart`，本项目的视觉取值 `#ffb600`）。右侧抓取结果里
/// 给勾选项描的黄框**必须是同一个值** —— 用户就是靠"两边一样的框"来确认
/// "列表里这条 = 页面上那条"。改一处就会对不上，所以有一条测试比对两边。
const Color kMarkYellow = Color(0xFFFFB600);

/// 语义色板 —— 按用途命名的一组颜色。
///
/// 原则同前：组件一律通过这些语义色取色，绝不写死具体颜色，
/// 这样明暗两套主题才能一键切换。
@immutable
class AppColors {
  // ── 表面 ────────────────────────────────────────────────
  /// 窗口最底层的底色调。默认完全透明，让 Windows 材质透出来。
  final Color surfaceBase;
  /// 卡片：半透明，配合 BackdropFilter 形成毛玻璃
  final Color surfaceCard;
  final Color surfaceCardHover;
  final Color surfaceSunken;
  /// 浮动层（Dock / 弹出面板 / 对话框）
  final Color surfaceFloat;
  final Color surfaceSolid;

  /// 模态遮罩：弹层背后压暗整屏的那一层。
  ///
  /// **必须比它盖住的表面更暗**——这条不是审美偏好，是遮罩存在的意义：
  /// 它要「把背景退下去、把弹层推上来」。2026-10-15 真机撞过一次反例：
  /// 选择器浮层原先拿 `textMuted`（深色主题下是 #BCBCBC 的**浅灰**）当遮罩，
  /// 55% 不透明度压上去，整个界面被罩成一层发白的雾 —— 实测同一块侧栏的
  /// 平均亮度从 44.4 涨到 126.8（2.86 倍），与「压暗」正好相反。
  ///
  /// 所以它不能从 `text*` 或 `surface*` 反推，必须是一个独立的、恒为暗色的
  /// 槽位。两套主题都取近黑，只差不透明度：浅色底子亮，54% 就够；
  /// 深色底子本来就暗，要 60% 才拉得开层次。
  final Color scrim;

  // ── 文字 ────────────────────────────────────────────────
  final Color textStrong;
  final Color textNormal;
  final Color textMuted;
  final Color textFaint;

  // ── 描边 ────────────────────────────────────────────────
  final Color line;
  final Color lineSoft;
  final Color lineStrong;

  // ── 主色 ────────────────────────────────────────────────
  final Color accent;
  final Color accentText;

  /// 压在 [accent] **整块填充**上面的文字/图标色（主按钮、徽标底）。
  ///
  /// 2026-10-16 新增。此前全应用一律用白字压 accent，**从来没有判据覆盖**，
  /// 实测是坏的：旧 `frosted` 的 `#1D9BF0` 上白字只有 3.00，深色主题那几个
  /// 亮 accent（`#38BDF8` 之类）更是只有 2.14。
  ///
  /// 不能沿用 [textStrong] 或 `onSuccess`：这条取决于 accent 的明度方向。
  /// 浅色主题的 accent 取深一档（要让白字过 4.5），深色主题的 accent 取亮一档
  /// （要让深字过 4.5）—— 六套各自的取值见 [StyleColors]。
  ///
  /// **同一条规律也适用于 [accentText]**：它是「accent 的可读文字版」，
  /// 压在卡片上用的，与 [onAccent] 不是一回事（一个压 accent，一个压卡片）。
  final Color onAccent;

  final Color accentSoft;
  final Color accentLine;
  final Color accentGlow;

  // ── 状态色 ────────────────────────────────────────────────
  final Color danger;
  final Color dangerSoft;

  /// 「成功 / 已完成」与「暂停 / 需注意」。
  ///
  /// 之前这两个颜色是各处手写的，而且是**两套绿**（#34C759 与 #1FA85C）加
  /// 一套琥珀 #E0A040 —— 同一个"完成"在不同页面深浅不一样。槽位化之后，
  /// 浅色主题还能顺带修掉可读性：#34C759 压在浅色卡片上只有 1.89:1。
  final Color success;
  final Color warning;

  /// 压在 [success] 整块填充**上面**要用的文字色。
  ///
  /// 不能沿用 `textStrong` 或白：暗色主题的 success 是亮绿 #34C759，
  /// 白字压上去只有 2.20:1（那条「已下载」缎带就是这么糊的），换成近黑的
  /// 深绿才到 6.7。浅色主题反过来 —— 深绿底配白字 5.29。
  final Color onSuccess;

  const AppColors({
    required this.surfaceBase,
    required this.surfaceCard,
    required this.surfaceCardHover,
    required this.surfaceSunken,
    required this.surfaceFloat,
    required this.surfaceSolid,
    required this.scrim,
    required this.textStrong,
    required this.textNormal,
    required this.textMuted,
    required this.textFaint,
    required this.line,
    required this.lineSoft,
    required this.lineStrong,
    required this.accent,
    required this.accentText,
    required this.onAccent,
    required this.accentSoft,
    required this.accentLine,
    required this.accentGlow,
    required this.danger,
    required this.dangerSoft,
    required this.success,
    required this.warning,
    required this.onSuccess,
  });

  /// 换掉整套强调色（**只有 winui 风格需要**，见 [WinUiAccent]）。
  ///
  /// 六个 accent 槽位一起换，派生规则与原色板一致：
  /// - `accentSoft` = 主色 0x33（浅）/ 0x59（深）
  /// - `accentLine` = 主色 0x66（浅）/ 0x80（深）
  /// - `accentGlow` = 主色 0x1A（浅）/ 0x26（深）
  ///
  /// **系数必须写成「十六进制 alpha ÷ 255」，不能写 0.35 这类小数**：
  /// [StyleColors.winuiLight] / [StyleColors.winuiDark] 里这几个槽位是用
  /// `Color(0x594CC2FF)` 写死的，0.35 ≠ 0x59/255（差 1/255），于是「用户不
  /// 换强调色」时渲染出来的色与色板定义**不是同一个值**，两处各自演化。
  /// 判据 `winui 默认档与色板逐值相等` 就是抓这个的，别改回去。
  ///
  /// 透明度按明暗分档不是随意的：A16 判据要求「选中底比悬停底朝主色推进
  /// ≥0.10」，实测 0x33/0x59 是能同时过判据又不显得浓的值。
  AppColors withAccent(
    ({Color accent, Color accentText, Color onAccent}) t,
    Brightness brightness,
  ) {
    final dark = brightness == Brightness.dark;
    final softA = (dark ? 0x59 : 0x33) / 255;
    final lineA = (dark ? 0x80 : 0x66) / 255;
    final glowA = (dark ? 0x26 : 0x1A) / 255;
    return AppColors(
      surfaceBase: surfaceBase,
      surfaceCard: surfaceCard,
      surfaceCardHover: surfaceCardHover,
      surfaceSunken: surfaceSunken,
      surfaceFloat: surfaceFloat,
      surfaceSolid: surfaceSolid,
      scrim: scrim,
      textStrong: textStrong,
      textNormal: textNormal,
      textMuted: textMuted,
      textFaint: textFaint,
      line: line,
      lineSoft: lineSoft,
      lineStrong: lineStrong,
      accent: t.accent,
      accentText: t.accentText,
      onAccent: t.onAccent,
      accentSoft: t.accent.withValues(alpha: softA),
      accentLine: t.accent.withValues(alpha: lineA),
      accentGlow: t.accent.withValues(alpha: glowA),
      danger: danger,
      dangerSoft: dangerSoft,
      success: success,
      warning: warning,
      onSuccess: onSuccess,
    );
  }

  /// 浅色（默认 `frosted` 那一套的中性版；风格化的取值见 [StyleColors]）。
  ///
  /// ### 2026-10-16 全量重做（用户裁定「所有材质与风格都不满意」）
  ///
  /// 与旧值的差别不是"调了几个数"，是换了三条原则：
  ///
  /// 1. **面要够不透明**。旧卡片是 62% 白，压在窗口底上时，纯黑壁纸给出
  ///    #EDEDED、纯白壁纸给出 #FBFBFB —— 同一份色板，读得清读不清取决于
  ///    用户桌面。现在卡片 91%、凹面 95%：底层的漂移被按比例压掉一个数量级，
  ///    两种壁纸下卡片只差 3/255，文字对比度因此**可计算、可保证**。
  /// 2. **中性色带色相**。旧值是纯灰（#F3F3F3 / #1A1A1A），看着就是"没设计过"。
  ///    现在浅色偏冷蓝、深色偏深蓝黑，与 accent 同族。
  /// 3. **四档文字按对比度排布，而不是按"看着差不多"**。压在最暗的面（凹面，
  ///    纯黑壁纸下 #F0F2F5）上时四档仍分别是 15.9 / 9.2 / 6.8 / 4.8、
  ///    相邻档 ≥1.34。旧值在同一位置是 11.8 / 7.7 / 6.4 / 3.4——`faint` 破 4.5。
  static const light = AppColors(
    surfaceBase: Colors.transparent,
    surfaceCard: Color(0xE8F8FAFC), // 91%
    surfaceCardHover: Color(0xF5FBFCFE), // 96%
    surfaceSunken: Color(0xF2F2F4F7), // 95%，刻意保留「凹下去」的那半档
    surfaceFloat: Color(0xFAFFFFFF), // 98%
    surfaceSolid: Color(0xFFF8FAFC),
    scrim: Color(0x8A000000), // 54% 近黑
    textStrong: Color(0xFF0F172A),
    textNormal: Color(0xFF334155),
    textMuted: Color(0xFF475569),
    textFaint: Color(0xFF5B6C82),
    line: Color(0x1A0F172A),
    lineSoft: Color(0x0E0F172A),
    lineStrong: Color(0x290F172A),
    // Windows 11 Fluent 自己的标准强调色。选它不只是"抄系统"：它在白字下
    // 5.40，而旧值 #1D9BF0 只有 3.00 —— 主按钮一直是不可读的。
    accent: Color(0xFF0F6CBD),
    accentText: Color(0xFF0F6CBD),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0x330F6CBD),
    accentLine: Color(0x730F6CBD),
    accentGlow: Color(0x2E0F6CBD),
    danger: Color(0xFFB91C1C),
    dangerSoft: Color(0x14B91C1C),
    success: Color(0xFF166534),
    warning: Color(0xFF92400E),
    onSuccess: Color(0xFFFFFFFF),
  );

  /// 深色。
  ///
  /// 与旧值的两条关键差别：**面比以前暗得多**（旧卡片 ≈ #2A2A2A，新卡片
  /// 在黑壁纸下 #1A1E26、白壁纸下 #1E2229），**四档文字比以前亮得多**
  /// （旧的 faint 在 hover 面只有 3.04）。暗底 + 亮字才能同时拿到层次与对比度：
  /// 面越暗，最弱那档文字允许越暗，四档才有排布空间。
  static const dark = AppColors(
    surfaceBase: Colors.transparent,
    surfaceCard: Color(0xE61B1F27), // 90%
    surfaceCardHover: Color(0xEE232833), // 93%
    surfaceSunken: Color(0xF0151820), // 94%
    surfaceFloat: Color(0xFF252A38), // 实心
    surfaceSolid: Color(0xFF14171E),
    scrim: Color(0x99000000), // 60%
    textStrong: Color(0xFFFFFFFF),
    textNormal: Color(0xFFDFE6EE),
    textMuted: Color(0xFFB9C6D6),
    textFaint: Color(0xFF93A3B8),
    line: Color(0x1AFFFFFF),
    lineSoft: Color(0x0FFFFFFF),
    lineStrong: Color(0x29FFFFFF),
    accent: Color(0xFF38BDF8),
    accentText: Color(0xFF7DD3FC),
    // 深色主题的 accent 是**亮**色，所以它上面要压深字（白字只有 2.14）。
    onAccent: Color(0xFF0B1220),
    accentSoft: Color(0x2E38BDF8),
    accentLine: Color(0x8038BDF8),
    accentGlow: Color(0x4D38BDF8),
    danger: Color(0xFFFCA5A5),
    dangerSoft: Color(0x29FCA5A5),
    success: Color(0xFF86EFAC),
    warning: Color(0xFFFCD34D),
    onSuccess: Color(0xFF0A2E16),
  );

  /// 按「风格 + 亮度」取该风格的整套色板。
  ///
  /// **注意 [light] / [dark] 与 frosted 不是同一套值**，这是有意的分工：
  ///
  /// | 东西 | 用途 | 值 |
  /// |---|---|---|
  /// | [light] / [dark] | 40 多个既有测试文件的引用（含 `theme_contrast_test` 里那 2 组地板） | **改造前的现值，一字不改** |
  /// | [of]`(frosted, ·)` | 应用**实际渲染** frosted 时的色板 | 预览稿 `#v-b` 的冷灰蓝 |
  ///
  /// frosted 是默认风格 —— 用户不切风格时看到的就是它，所以它必须与 liquid/clay
  /// 同等待遇地取预览稿取值，否则「三套风格」对默认用户等于没做。
  static AppColors of(
    AppStyle style,
    Brightness brightness, {
    WinUiAccent accent = WinUiAccent.windows,
  }) {
    if (style == AppStyle.winui) {
      // winui 的强调色是**用户自选**的三档（[WinUiAccent]），所以不能像
      // 另三套那样直接返回常量 —— 要在这层换上 accent 槽位。
      return StyleColors.of(style, brightness)
          .colors
          .withAccent(accent.colorsFor(brightness), brightness);
    }
    return switch ((style, brightness)) {
      (AppStyle.frosted, Brightness.light) => StyleColors.frostedLight.colors,
      (AppStyle.frosted, Brightness.dark) => StyleColors.frostedDark.colors,
      _ => StyleColors.of(style, brightness).colors,
    };
  }

  /// 按「强调色 + 明暗」算出一个合适的底色调。
  ///
  /// 关键：**不能**把强调色按固定不透明度直接铺满窗口。
  /// 深色模式下 #1d9bf0 铺 55% 会变成一大片刺眼的亮蓝，浅色文字压上去几乎看不见
  /// —— 这里踩过坑。正确做法是与主题底色按比例混合。
  static Color tintFor(Color tint, Brightness brightness) {
    final base = brightness == Brightness.dark
        ? const Color(0xFF18181B)
        : const Color(0xFFF3F3F3);
    final w = brightness == Brightness.dark ? 0.30 : 0.18;
    // 用 .r/.g/.b（0~1 浮点）做混合，避免已废弃的 .red/.green/.blue
    int mix(double t, double b) =>
        ((t * w + b * (1 - w)) * 255).round().clamp(0, 255);
    return Color.fromARGB(
      217, // 0.85 不透明度：与 background_layer 的默认底色保持一致，
           // 只留 15% 让窗口材质透出来（0.75 时浅色壁纸会把底色抬到读不清）
      mix(tint.r, base.r),
      mix(tint.g, base.g),
      mix(tint.b, base.b),
    );
  }

  /// 纯色材质时用的不透明底色，也用作「窗口底压在壁纸上」的那一层。
  ///
  /// ### 2026-10-16 收掉旧分叉
  ///
  /// 这里此前是「frosted 返回硬编码 #F3F3F3 / #202020，其余风格走色板」——
  /// 一个概念两处出处，于是 frosted 的卡片底（`StyleColors.frostedLight` 的
  /// `#F7F9FC`）与窗口底（`#F3F3F3`）**根本不是同一个色**，两套值各自演化。
  /// 现在统一取色板：改风格只改一处。
  ///
  /// [style] 有默认值 [AppStyle.frosted]，既有调用点（`background_layer.dart`、
  /// `theme_contrast_test.dart`、`nav_keyboard_test.dart`）零改动。
  static Color solidFor(
    Brightness brightness, {
    AppStyle style = AppStyle.frosted,
  }) =>
      of(style, brightness).surfaceSolid;
}

/// 「选中 / 激活」的统一画法：低饱和主色底 + 主色描边 + 柔光。
///
/// 侧边栏与 Dock 的导航项、材质卡片、导航形态卡片、分段控件都走这里。
/// 之前分段控件是 `c.accent` 整块铺底配白字，跟其余几处的低饱和底属于
/// 两套画法 —— 同一屏里「被选中的东西」长得不一样。
BoxDecoration selectedDecoration(AppColors c, {double radius = 12}) =>
    BoxDecoration(
      color: c.accentSoft,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: c.accentLine, width: 1),
      boxShadow: [BoxShadow(color: c.accentGlow, blurRadius: 16)],
    );

/// 通过 InheritedWidget 把色板下发给子树，等价于 CSS 变量挂在 `[data-theme]` 上。
class AppTheme extends InheritedWidget {
  final AppColors colors;
  final Brightness brightness;

  /// 当前界面风格。默认 [AppStyle.frosted] —— 没显式传的调用点（含测试里的
  /// 二十多处 `AppTheme(...)`）拿到的就是改造前的观感，不必逐个改。
  final AppStyle style;

  const AppTheme({
    super.key,
    required this.colors,
    required this.brightness,
    this.style = AppStyle.frosted,
    required super.child,
  });

  static AppTheme of(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<AppTheme>();
    assert(t != null, 'AppTheme 未挂载：请检查根 Widget 是否包了 AppTheme');
    return t!;
  }

  static AppColors colorsOf(BuildContext context) => of(context).colors;

  /// 当前风格的材质令牌。
  static AppSurface surfaceOf(BuildContext context) => of(context).surface;

  /// 由 [style] 派生的材质令牌
  AppSurface get surface => AppSurface.of(style);

  @override
  bool updateShouldNotify(AppTheme oldWidget) =>
      oldWidget.colors != colors ||
      oldWidget.brightness != brightness ||
      oldWidget.style != style;
}

/// 应用级 Material 主题。**从 [AppColors] 派生，别再在别处手搓 ThemeData。**
///
/// [style] 决定按钮主题取哪一套 [StyleButton] 令牌（`.btn` / `.btn.primary`
/// 的 Flutter 对应物）。默认 [AppStyle.frosted] 与 `AppColors.solidFor` 的
/// 先例一致 —— 既有调用点（含测试）零改动，拿到的就是 frosted 的按钮观感。
///
/// 抽出来只为了一条可跑的判据：`canvasColor` 必须实心（见下），而它藏在
/// `app.dart` 的私有方法里就没法被测试钉住。
///
/// 渐变的能力边界（如实记录）：liquid / clay 的主按钮 CSS 是
/// `linear-gradient(135deg, var(--ac), var(--ac2))`，而 Material 3 的
/// `ButtonStyle.backgroundColor` 只接受一个 [Color]，`FilledButtonThemeData`
/// 无法下发渐变（真渐变需要包一层 Ink/DecoratedBox 装饰，属于逐调用点改造，
/// 本期明确不做）。这里取渐变**主色段**（CSS `--ac`，即 `c.accent`）做实色近似。
ThemeData buildAppTheme(
  AppColors c,
  Brightness brightness, {
  AppStyle style = AppStyle.frosted,
}) {
  final StyleButton button = style.buttonOf(brightness);
  // 43 处原生按钮（FilledButton / FilledButton.tonal* / TextButton / OutlinedButton）
  // 的观感全部由这三组主题下发，任何调用点都不需要改动。
  //
  // 分组方式的一个 SDK 事实（filled_button.dart `themeStyleOf`）：filled 与
  // tonal **共用** `FilledButtonThemeData.style`，主题层无法区分二者 —— 所以
  // 主按钮实色与 tonal 的低饱和底都从 ColorScheme 槽位取：
  //   FilledButton      → 读 `primary`（主按钮：--ac 实色，白字）
  //   FilledButton.tonal* → 读 `secondaryContainer` / `onSecondaryContainer`
  //     （普通按钮：StyleButton.color 半透面 + 该套 --ink2 字色；
  //     liquid 浅色的半透白 0xB3 不满足 SDK 的 disabled/onPrimary 压字前提，
  //     压实成白面板底再保留 18% 通透 —— 偏差如实记录）
  final Color tonalSurface = style == AppStyle.liquid &&
          brightness == Brightness.light
      ? Color.lerp(button.color, c.surfaceSolid, 0.18)!
      : button.color;
  final ButtonStyle ordinaryButtonStyle = ButtonStyle(
    backgroundColor: WidgetStatePropertyAll<Color>(tonalSurface),
    foregroundColor: WidgetStatePropertyAll<Color>(c.textNormal),
    overlayColor: WidgetStateProperty.resolveWith(
      (Set<WidgetState> states) => states.contains(WidgetState.hovered)
          ? c.surfaceCardHover.withValues(alpha: 0.35)
          : null,
    ),
    side: WidgetStatePropertyAll<BorderSide>(
      BorderSide(color: button.borderColor),
    ),
    shape: WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(style.radiusOf(AppRadius.field)),
      ),
    ),
    elevation: const WidgetStatePropertyAll<double>(0),
    shadowColor: WidgetStatePropertyAll<Color>(button.shadow.color),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Microsoft YaHei',
    scaffoldBackgroundColor: Colors.transparent,
    // **这一行不能留 transparent。** Flutter 的 `DropdownButton` 展开层取色是
    // `widget.dropdownColor ?? Theme.of(context).canvasColor`
    // （SDK `packages/flutter/lib/src/material/dropdown.dart:341`），
    // 留透明就等于全应用每一个下拉菜单都是全透的 —— 叠在 B 站 / 抖音的网页上
    // 直接看不清字（2026-10-11 用户实拍）。
    // 窗口材质是靠 `scaffoldBackgroundColor: transparent` 透出去的，与此字段无关。
    canvasColor: c.surfaceSolid,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: c.accent,
          brightness: brightness,
        ).copyWith(
          primary: c.accent,
          surface: c.surfaceSolid,
          onSurface: c.textStrong,
          // FilledButton（非 tonal）= 主按钮：--ac 实色底（见上方渐变能力边界）。
          //
          // 2026-10-16 修：这里此前硬编码 `Colors.white`，而它**从来没有判据覆盖**。
          // 实测旧 `#1D9BF0` 上白字只有 3.00，深色主题的亮 accent（`#38BDF8`）
          // 上更只有 2.14 —— 主按钮一直是不可读的。现在取色板的 [AppColors.onAccent]：
          // 浅色主题的 accent 是深色（配白字），深色主题的 accent 是亮色（配深字）。
          // 这也与 WinUI 官方的 `TextOnAccentFillColorPrimary` 同向
          // （浅色 `#FFFFFF` / 深色 `#000000`）。
          onPrimary: c.onAccent,
          onError: Colors.white,
          // FilledButton.tonal* = 普通按钮（见上方 tonalSurface 的说明）。
          secondaryContainer: tonalSurface,
          onSecondaryContainer: c.textNormal,
        ),
    textButtonTheme: TextButtonThemeData(style: ordinaryButtonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: ordinaryButtonStyle),
    filledButtonTheme: FilledButtonThemeData(style: ordinaryButtonStyle),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
  );
}
