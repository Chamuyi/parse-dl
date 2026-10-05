import 'package:flutter/material.dart';

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
    required this.textStrong,
    required this.textNormal,
    required this.textMuted,
    required this.textFaint,
    required this.line,
    required this.lineSoft,
    required this.lineStrong,
    required this.accent,
    required this.accentText,
    required this.accentSoft,
    required this.accentLine,
    required this.accentGlow,
    required this.danger,
    required this.dangerSoft,
    required this.success,
    required this.warning,
    required this.onSuccess,
  });

  /// 浅色：卡片用半透明白，压在材质/背景图上有通透感
  static const light = AppColors(
    surfaceBase: Colors.transparent,
    surfaceCard: Color(0x9EFFFFFF), // 62%
    surfaceCardHover: Color(0xC7FFFFFF), // 78%
    surfaceSunken: Color(0x09000000),
    surfaceFloat: Color(0xD1FAFAFA),
    surfaceSolid: Color(0xFFF3F3F3),
    textStrong: Color(0xFF1A1A1A),
    textNormal: Color(0xFF2F2F2F),
    textMuted: Color(0xFF5A5A5A),
    // 这两档要在「浅色壁纸」和「深色壁纸」两端都读得清、还分得出层次。
    // 窗口底色 = 壁纸×0.15 + #F3F3F3×0.85，卡片再叠 62% 白 —— 纯黑壁纸时卡片只有
    // #EDEDED（不是 #FBFBFB），而 #EDEDED 正是短板：旧值 #737373 对它只有 4.03，
    // 压到 #696969 才过 4.5；但只动 faint 会让 muted/faint 并成一种灰（1.16），
    // 所以 muted 同步压到 #5A5A5A，把相邻档的间距拉回 1.2 以上。
    textFaint: Color(0xFF696969),
    line: Color(0x1A000000),
    lineSoft: Color(0x0E000000),
    lineStrong: Color(0x29000000),
    accent: Color(0xFF1D9BF0),
    accentText: Color(0xFF0F6FA8),
    // 20% 而不是 12%：浅色主题下「选中」要一眼看出是蓝的。12% 时选中底与
    // 悬停底（78% 白）的 sRGB 距离只有 0.076，两种状态看着一样（真机复核 2026-09-30）。
    accentSoft: Color(0x331D9BF0),
    accentLine: Color(0x731D9BF0),
    accentGlow: Color(0x2E1D9BF0),
    danger: Color(0xFFD93B3B),
    dangerSoft: Color(0x14D93B3B),
    // 浅色这两档不能沿用暗色值：#34C759 对浅色卡片只有 1.89、#E0A040 只有 1.93，
    // 压到 #0F7A38 / #9A5B00 才到 4.6 一线。
    success: Color(0xFF0F7A38),
    warning: Color(0xFF9A5B00),
    onSuccess: Color(0xFFFFFFFF),
  );

  /// 深色：卡片用极低不透明度的白，靠材质提供底色
  static const dark = AppColors(
    surfaceBase: Colors.transparent,
    surfaceCard: Color(0x0EFFFFFF), // 5.5%
    surfaceCardHover: Color(0x16FFFFFF), // 8.5%
    surfaceSunken: Color(0x09FFFFFF),
    surfaceFloat: Color(0xE0262626),
    surfaceSolid: Color(0xFF202020),
    textStrong: Color(0xFFF2F2F2),
    textNormal: Color(0xFFDCDCDC),
    // 这两档要扛住「浅色壁纸透进来」：窗口底色 = 壁纸×(1-0.85) + #202020×0.85，
    // 纯白壁纸时卡片底约 #4C4C4C，再暗就掉到 3:1 以下读不清了。
    textMuted: Color(0xFFBCBCBC),
    textFaint: Color(0xFFA0A0A0),
    line: Color(0x1AFFFFFF),
    lineSoft: Color(0x0FFFFFFF),
    lineStrong: Color(0x29FFFFFF),
    accent: Color(0xFF1D9BF0),
    accentText: Color(0xFF57B9FF),
    accentSoft: Color(0x2E1D9BF0),
    accentLine: Color(0x801D9BF0),
    accentGlow: Color(0x4D1D9BF0),
    danger: Color(0xFFFF6B6B),
    dangerSoft: Color(0x29FF6B6B),
    success: Color(0xFF34C759),
    warning: Color(0xFFE0A040),
    onSuccess: Color(0xFF0A2E16),
  );

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

  /// 纯色材质时用的不透明底色
  static Color solidFor(Brightness brightness) =>
      brightness == Brightness.dark
          ? const Color(0xFF202020)
          : const Color(0xFFF3F3F3);
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

  const AppTheme({
    super.key,
    required this.colors,
    required this.brightness,
    required super.child,
  });

  static AppTheme of(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<AppTheme>();
    assert(t != null, 'AppTheme 未挂载：请检查根 Widget 是否包了 AppTheme');
    return t!;
  }

  static AppColors colorsOf(BuildContext context) => of(context).colors;

  @override
  bool updateShouldNotify(AppTheme oldWidget) =>
      oldWidget.colors != colors || oldWidget.brightness != brightness;
}
