import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'style_colors.dart';

/// 风格缩略图里那块「桌面壁纸」的渐变。
///
/// 放在 `lib/theme/` 里是有意的：它是**视觉令牌**，而色板棘轮
/// （`test/visual_tokens_test.dart`）只扫 `lib/theme/` 之外 —— 缩略图的
/// 壁纸色是「预览用的数据」，不该逼着每个选择器各自登记一遍写死颜色。
const List<Color> kPreviewWallpaper = [
  Color(0xFF6C4BB0),
  Color(0xFF1E6E8C),
  Color(0xFFD9A441),
];

/// 界面风格。持久化在 `settings.json` 的 `appearance.visualStyle`。
///
/// 存进配置文件的 id 定下就不能改（同 [WindowMaterial.id] 的约定）。
///
/// ### 2026-10-19 只保留一套风格（用户裁定「你去把其他的删了」）
///
/// 曾经有 liquid / frosted / clay / winui 四套。用户连续多轮判定「不对」之后
/// 明确要求删掉其余三套，只留 Windows 原生。删掉的好处不只是少代码：
/// 所有「按风格分流」的 switch 都塌缩成单值，改观感时不必再考虑会不会
/// 影响另三套，可以放心按 WinUI3 规范调。
///
/// 仍然保留 enum（而不是直接删掉类型）的原因：settings.json 里的
/// appearance.visualStyle 字段要能读到旧值并迁移，AppTheme.style 也还在
/// 被大量组件引用。等迁移稳定后再考虑是否连类型一起去掉。
enum AppStyle {
  /// Windows 原生（WinUI3）。色板与材质取自微软官方规范 +
  /// bdlukaa/fluent_ui（BSD-3-Clause）：22 级中性灰、暖灰底、单色强调、
  /// 4/8px 圆角、1px 边线、Mica 窗口底。
  winui('winui', 'Windows 原生', 'WinUI3 观感：暖灰底、单色强调、细边线、克制阴影');

  const AppStyle(this.id, this.label, this.description);

  /// 持久化用的标识，定下就不能改
  final String id;
  final String label;
  final String description;

  /// 缺字段 / 坏值 / 旧的三套风格 id 一律回退 [AppStyle.winui]。
  ///
  /// 迁移：老配置里可能存着 liquid / frosted / clay，那些风格已经删除，
  /// 读到就落到 winui，不报错、不黑屏。
  static AppStyle fromId(String? id) => AppStyle.values.firstWhere(
        (s) => s.id == id,
        orElse: () => AppStyle.winui,
      );

  /// 这套风格的色彩令牌。
  ///
  /// 与 [AppSurface.of] 并列：色彩与材质是**两个正交维度**，都在这里取，
  /// 调用方（页面 / 组件）不自己判断风格。取值出口只有 [StyleColors.of] 一处。
  StyleColors colorsFor(Brightness brightness) => StyleColors.of(this, brightness);
}

/// 卡片材质令牌 —— 一块面「有多厚、多透、多亮」。
///
/// 与 [AppColors] 正交：色板回答「用什么颜色」，这里回答「这块面是什么材质」。
/// 调用方（[AppCard]）只读令牌，不自己判断风格 —— 要加第四套风格时只改这里。
///
/// 三套取值照预览稿实测（`tools/ui/_redesign/preview/index.html`）。
@immutable
class AppSurface {
  /// 卡片高斯模糊 sigma。**0 表示实心面**，调用方据此决定不套 `BackdropFilter`
  /// （实心面不该有模糊，顺带省一层合成开销）。
  final double blur;

  /// 卡片不透明度 0~1。`1.0` = 实心面，直接取色板的不透明底色。
  final double opacity;

  /// 半径系数：乘到调用方传的 `radius` 上（调用方的半径语义保留）。
  final double radiusScale;

  /// 是否用渐变面（液体玻璃的多层折射感）
  final bool gradient;

  /// 是否画内缘亮环
  final bool rim;

  final double shadowY, shadowBlur, shadowOpacity;

  const AppSurface({
    required this.blur,
    required this.opacity,
    required this.radiusScale,
    required this.gradient,
    required this.rim,
    required this.shadowY,
    required this.shadowBlur,
    required this.shadowOpacity,
  });

  /// 液体玻璃：模糊最重、透光最强、半径最大，带渐变面与内缘亮环。
  ///
  /// 2026-10-16 把 `blur` 从 **5 提到 28**。5 在原稿里是「模糊最轻」的意思，
  /// 但放进真机就是**几乎没模糊** —— 一块半透明的板子而已，既不像玻璃也
  /// 和 frosted 分不出来（后者 blur 18）。玻璃感来自「背景被打散成色块」，
  /// 那需要的正是强模糊；这一档现在是三套里唯一一眼可辨的「厚玻璃」。
  static const liquid = AppSurface(
    blur: 28,
    opacity: 0.60,
    radiusScale: 1.25,
    gradient: true,
    rim: true,
    shadowY: 12,
    shadowBlur: 34,
    shadowOpacity: 0.24,
  );

  /// 磨砂清晰（默认）。
  ///
  /// `blur: 22` / `opacity: .76` **取自 morrow 源码的默认值** ——
  /// `tools/ui/_redesign/morrow/lib/appearance.dart` 里 `ComponentMaterial`
  /// 的构造默认 `this.blur = 22, this.opacity = .76`（第 44~45 行），
  /// `fromJson` 也用同一对值兜底（第 96~97 行 `?? 22` / `?? .76`）。
  /// 这是本项目「预览稿实测值」的出处，改这两个数前先去核对那份源码。
  static const frosted = AppSurface(
    blur: 18,
    opacity: 0.78,
    radiusScale: 1.0,
    gradient: false,
    rim: false,
    shadowY: 6,
    shadowBlur: 18,
    shadowOpacity: 0.12,
  );

  /// 陶土柔和：实心面 + 最重的软阴影，完全不透明。
  static const clay = AppSurface(
    blur: 0,
    opacity: 1.0,
    radiusScale: 1.0,
    gradient: false,
    rim: false,
    shadowY: 10,
    shadowBlur: 26,
    shadowOpacity: 0.20,
  );

  /// Windows 原生（WinUI3）：**实心面**，几乎无模糊，阴影极轻。
  ///
  /// 与 clay 的区别在「浮起感靠边线不靠投影」——WinUI 的卡片靠 1px 边线
  /// 与表层色差分层，投影只是极淡的一层（官方 Card 阴影几乎看不见）。
  /// 抄的是 `fluent_ui` 的观感，不是它的实现（未引入其依赖）。
  static const winui = AppSurface(
    blur: 0,
    opacity: 1.0,
    radiusScale: 1.0,
    gradient: false,
    rim: false,
    shadowY: 2,
    shadowBlur: 8,
    shadowOpacity: 0.08,
  );

  static AppSurface of(AppStyle s) => winui;

  /// 卡片实际底色。
  ///
  /// [base] 是色板给的半透明卡片色，[solid] 是不透明底色。
  ///
  /// **frosted 必须逐字节等于 [base]**：它是默认风格，不改设置的用户不该看出
  /// 任何差别，所以缩放比例以它自己的 [opacity] 为 1.0 基准。比它更透的风格
  /// 按比例减 alpha；实心风格（[opacity] ≥ 1）直接换成 [solid] —— 把半透明底色的
  /// alpha 拉满会让深色主题的卡片变成一张纯白板，那是另一个 bug。
  Color resolveCardColor(Color base, Color solid) {
    if (opacity >= 1) return solid;
    return base.withValues(
      alpha: (base.a * (opacity / frosted.opacity)).clamp(0.0, 1.0),
    );
  }

  /// 卡片投影的不透明度。
  ///
  /// 浅色主题按深色档的 23% 派生：同一档黑影压在浅底上格外显眼，改造前就是
  /// 分两档的（旧值 0.07 / 0.30，比值 0.233）。单一值会让浅色主题的卡片
  /// 突然长出一圈黑边。
  double shadowAlphaFor(Brightness brightness) =>
      shadowOpacity * (brightness == Brightness.light ? 0.23 : 1.0);

  /// 渐变面的高光端色（只有 [gradient] 为真时用）。
  Color gradientTop(Color cardColor) =>
      Color.lerp(cardColor, Colors.white, 0.18)!;

  /// 内缘亮环色（只有 [rim] 为真时用）。
  Color rimColor(Brightness brightness) => Colors.white.withValues(
        alpha: brightness == Brightness.light ? 0.55 : 0.28,
      );
}

// ══════════════════════════════════════════════════════════════
// S4 · 圆角分档 / 边框 / 投影 / 悬停
//
// 下面四组令牌的取值**逐项取证自** `tools/ui/_redesign/preview/app.css`，
// 每条注明出处行号。计划书 §1 只给了概括，这里按 CSS 原文取值。
//
// 为什么放在 [AppStyle] 的扩展里而不是塞进 [AppSurface]：`AppSurface` 的三套
// 现值（blur / opacity / radiusScale）是 P1 期已验收的，有测试钉着，不许改。
// 这四组是**新增维度**，所以另开扩展，互不干扰。
// ══════════════════════════════════════════════════════════════

/// 圆角**档位** —— 取代调用方传像素。
///
/// 三套风格对同一个档位给不同半径（液体玻璃更圆、磨砂更方、陶土居中），
/// 这是「一套设计语言」的一部分，所以对外暴露的稳定 API 是**档位**而不是像素：
/// 调用方说「我这是张卡片」，半径由当前风格决定。
enum AppRadius {
  /// `.card` —— 卡片本体。`app.css:266` / `:347` / `:408`
  card,

  /// `.qi` / `.opt` / `.hero` —— 小控件与首屏块。`app.css:273` / `:348` / `:409`
  qi,

  /// `.field` / `.web` / `.pill` / `.tabs2` / `.sw` / `.li` —— 输入框与胶囊。
  /// `app.css:274` / `:349` / `:410`
  field,

  /// `.hero2` / `.stat` —— 大统计块。`app.css:804` / `:805` / `:806`
  hero2,
}

/// 圆角分档表：`(风格, 档位) → 半径`。
extension AppStyleRadiusTokens on AppStyle {
  double radiusOf(AppRadius slot) => switch (slot) {
        // WinUI3 规范：卡片/浮层 8px，控件 4px。
        AppRadius.card => 8,
        AppRadius.qi => 4,
        AppRadius.field => 4,
        AppRadius.hero2 => 8,
      };
}

/// 卡片边框的两层色：顶部 1px 高光 + 其余三边的环。
///
/// 为什么分成两个槽位而不是一个 [Color]：液体玻璃的边缘来自 CSS 的
/// `border: 1px solid var(--rim)` **叠加** `inset 0 1px 0 rgba(255,255,255,.95)`
/// ——顶边被高光盖住，另外三边留 ring 色。一个 [Color] 表达不了这个差异。
///
/// **能力边界（如实记录）**：CSS 的 `inset 0 -14px 26px -18px …` 那道底部内光晕
/// 用 Flutter 的 [BoxDecoration] 无法表达（它没有 inset shadow），这里只取
/// 「可表达的 1px 顶部高光」这一半，不做近似伪造。
///
/// ### [top] 不再进 `Border`（2026-10-15 修一个真机缺陷）
///
/// 原实现把 [top] 与 [side] 分写成 `Border(top:…, left:…, right:…, bottom:…)`。
/// 只要 [top] 与 [side] 不同色，`Border.isUniform` 就是 `false`，而
/// `BoxDecoration` 在**非 uniform 边框 + `borderRadius`** 下会走逐边绘制路径，
/// **把子内容整片盖住** —— 真机表现为「液体玻璃风格下卡片里什么都没有」，
/// 而 frosted / clay（四边同色 → uniform）完全正常。
///
/// 最小复现（同一容器、只差边框形式，量渲染结果里的深色像素）：
/// ```
/// Border.all(...)                 isUniform=true   darkPixels=6725  ✅
/// 四边分写、顶边不同色（旧实现）    isUniform=false  darkPixels=361   ❌
/// 四边分写、四边同色              isUniform=true   darkPixels=6725  ✅
/// ```
///
/// 所以 [toBorder] 现在**恒返回四边同色的边框**（用 [side]），[top] 单独由
/// [AppCard] 用「顶部 1px 内阴影」表达 —— 这也更贴近 CSS 原意：
/// 预览稿里那道顶边高光本来就是 `box-shadow: inset 0 1px 0 …`，**不是 border**，
/// 当初把它译成「顶边换个颜色」才是误译。
@immutable
class StyleBorder {
  final Color top;
  final Color side;

  const StyleBorder({required this.top, required this.side});

  /// 顶部高光与三边同色时用这个（磨砂 / 陶土都没有独立的高光边）。
  const StyleBorder.uniform(this.side) : top = side;

  /// 四边同色的边框。
  ///
  /// **必须保持 uniform**：非 uniform 边框在带圆角的 `BoxDecoration` 上会让
  /// 子内容消失（见类文档的最小复现）。顶边高光不走这里。
  Border toBorder() => Border.all(color: side, width: 1);

  /// 顶部那道 1px 高光是否与三边不同（决定要不要额外画一条内阴影）。
  bool get hasTopHighlight => top != side;

  @override
  bool operator ==(Object other) =>
      other is StyleBorder && other.top == top && other.side == side;

  @override
  int get hashCode => Object.hash(top, side);
}

/// 卡片边框随风格变。
extension AppStyleBorderTokens on AppStyle {
  StyleBorder cardBorderOf(AppColors c, Brightness brightness) =>
      // WinUI3：卡片靠 1px 边线分层，没有顶部高光。取色板 line 单出处。
      StyleBorder.uniform(c.line);
}

/// 卡片投影随风格变 —— **每套是两条**（磨砂与陶土是 CSS 的双层影，
/// 液体玻璃是一条带负 spread 的大影）。
///
/// 返回值**不是常量**，调用方不该缓存；它只是把 CSS 的 `box-shadow` 列表
/// 逐条翻成 [BoxShadow]。
extension AppStyleShadowTokens on AppStyle {
  List<BoxShadow> cardShadows(Brightness brightness) => [
        // WinUI3：浮起感靠边线，投影只有极淡一层（官方 Card 几乎看不见影）。
        BoxShadow(
          color: brightness == Brightness.dark
              ? const Color(0x1F000000)
              : const Color(0x0A000000),
          offset: const Offset(0, 1),
          blurRadius: 4,
        ),
      ];
}

/// 悬停底色随风格变。
///
/// 改造前三套风格共用色板的 `surfaceCardHover`，**而浅色三套的那个值恰好
/// 完全相同**（都是白 78%）—— 也就是说浅色下悬停反馈根本分不出风格。
/// 这里按各套 CSS 的 `:hover` 规则取值。
///
/// 浅色三套的 hover 都是**往亮里加**：[AppColors.surfaceCard] 本身是半透明白，
/// 再叠一层更亮的白 → 压在卡片上的文字对比度只会升高，不会跌地板。
extension AppStyleHoverTokens on AppStyle {
  Color hoverColor(Brightness brightness) =>
      // WinUI3 的 hover 是"表层提亮一档"：浅色叠极淡黑，深色叠极淡白。
      brightness == Brightness.dark
          ? const Color(0x0FFFFFFF)
          : const Color(0x0A000000);
}

// ══════════════════════════════════════════════════════════════
// S5 · 导航激活态 / 侧边栏底色 / 按钮
//
// 取值**逐行取证自** `tools/ui/_redesign/preview/app.css`（每条注明行号）。
//
// 关键设计约束（既有测试钉着，不许破）：
// 1. 选中底色**只有 `selectedDecoration` 一个出处** —— frosted（默认风格）的
//    导航激活态**必须继续走它**（`appearance_controls_test` 源码层检查
//    `contains('selectedDecoration(')`）；liquid / clay 是本批新增的取值，
//    集中在这组令牌里，`navItemDecoration` 按风格分流。
// 2. **竖条不进令牌**：三套 CSS 的左侧 3×15px 竖条逐字节相同（`:288-292` /
//    `:359-363` / `:422-426`），它不是风格区分点，由 `nav_items.dart` 的
//    既有结构表达，不在这里重复一份。
// ══════════════════════════════════════════════════════════════

/// 导航**激活态**装饰（侧边栏 / Dock 共用一份，经 `navItemDecoration`）。
@immutable
class StyleNavActive {
  /// 激活底色。frosted 是纯色 12%（CSS `:356`）；liquid/clay 见下。
  final Color color;

  /// liquid 浅色用（`linear-gradient(135deg, …)`，CSS `:284`）。
  /// 其余七套为 null（纯色，走 [color]）。
  final Gradient? gradient;

  /// 内描边（CSS `inset 0 0 0 1px …`）。
  final Color borderColor;

  /// 外发光（CSS `box-shadow` 里 `inset` 之外的那条）。**frosted / clay 没有**
  /// （CSS `:357` / `:420` 只有内描边一条）—— 激活态「要发光」的老断言
  /// 是对 frosted（旧默认）说的，frosted 分支继续走 `selectedDecoration`
  /// 自带柔光；liquid 才有真正的外发光（`:286`）。
  final Color? glow;

  const StyleNavActive({
    required this.color,
    this.gradient,
    required this.borderColor,
    this.glow,
  });

  /// WinUI3 · 浅色。选中底 = 强调色 **10%**，**无描边、无发光**。
  ///
  /// 2026-10-19 修正：原先这里还带一圈 40% 的强调色描边，那是「玻璃卡」
  /// 的设计语言（用描边把卡片从背景里勾出来）。WinUI3 的 NavigationView
  /// 选中项**只有一层极淡底色**，指示靠左侧竖条 —— 描边会把行变成「小卡片」，
  /// 正是用户说「这不像 WinUI」的观感来源之一。
  static const winuiLight = StyleNavActive(
    color: Color(0x1A0078D4),
    borderColor: Color(0x00000000),
  );

  /// WinUI3 · 深色。深色下强调色亮一档（#4CC2FF），同样无描边。
  static const winuiDark = StyleNavActive(
    color: Color(0x264CC2FF),
    borderColor: Color(0x00000000),
  );

  /// liquid · 浅色。CSS `:284-286`：
  /// `linear-gradient(135deg, rgba(91,108,255,.20), rgba(139,92,246,.12))`
  /// + `inset 0 0 0 1px rgba(91,108,255,.28), 0 4px 14px -8px var(--ac)`。
  /// [color] 在有渐变时不被使用，但构造要求必填 —— 取渐变首色保持一致性。
  static const liquidLight = StyleNavActive(
    color: Color(0x335B6CFF),
    gradient: LinearGradient(
      begin: Alignment(-0.707, -0.707), // 135°
      end: Alignment(0.707, 0.707),
      colors: [Color(0x335B6CFF), Color(0x1F8B5CF6)],
    ),
    borderColor: Color(0x475B6CFF),
    glow: Color(0xFF5B6CFF),
  );

  /// liquid · 深色。CSS 深色段（`:848`）只改了文字色，底/描边/发光沿用浅色
  /// 令牌但按深色主色换算 —— `--ac: #7C8DFF`（`:831`）。
  static const liquidDark = StyleNavActive(
    color: Color(0x337C8DFF),
    gradient: LinearGradient(
      begin: Alignment(-0.707, -0.707),
      end: Alignment(0.707, 0.707),
      colors: [Color(0x337C8DFF), Color(0x1F9B7CFF)],
    ),
    borderColor: Color(0x477C8DFF),
    glow: Color(0xFF7C8DFF),
  );

  /// frosted · 两亮度同值。CSS `:355-357`：纯色 12% + 仅内描边，**无外发光**。
  /// 浅色/深色的 `--ac` 都是 `#1D9BF0`（`:330` / `:883`），alpha 也同（.12/.30）。
  static const frosted = StyleNavActive(
    color: Color(0x1F1D9BF0),
    borderColor: Color(0x4D1D9BF0),
  );

  /// clay · 浅色。CSS `:418-420`：纯色 10% + 仅内描边，无外发光。
  static const clayLight = StyleNavActive(
    color: Color(0x1AC2410C),
    borderColor: Color(0x42C2410C),
  );

  /// clay · 深色。CSS 深色 `--ac: #EA580C`（`:931`）。
  static const clayDark = StyleNavActive(
    color: Color(0x1AEA580C),
    borderColor: Color(0x42EA580C),
  );
}

/// 外发光阴影的几何常量（liquid 激活态专用，CSS `0 4px 14px -8px var(--ac)`）。
const kNavActiveGlow = BoxShadow(
  blurRadius: 14,
  offset: Offset(0, 4),
  spreadRadius: -8,
  color: Colors.transparent, // color 由 StyleNavActive.glow 覆盖
);

/// 导航激活态令牌入口（[AppStyle] 的第五组扩展）。
extension AppStyleNavTokens on AppStyle {
  /// 激活态取值。**frosted 不在这里取** —— 它必须走 `selectedDecoration`
  /// （选中底色唯一出处，`appearance_controls_test` 源码层检查着）；
  /// 这个入口只服务 liquid / clay 两套新增画法。
  StyleNavActive navActiveOf(Brightness brightness) =>
      brightness == Brightness.dark
          ? StyleNavActive.winuiDark
          : StyleNavActive.winuiLight;
}

/// 侧边栏底色（CSS `.side`，含右分隔线随风格的有无）。
@immutable
class StyleSidebar {
  /// 侧边栏底色（CSS `.side { background: … }`）。
  final Color color;

  /// liquid 浅色用（`linear-gradient(160deg, …)`，CSS `:255`）。
  final Gradient? gradient;

  /// 是否画右边分隔线（frosted / clay 的 CSS 带 `border-right: 1px solid var(--ln)`，
  /// liquid 的不带 —— 它靠渐变自身收边）。
  final bool borderRight;

  const StyleSidebar({
    required this.color,
    this.gradient,
    required this.borderRight,
  });

  /// WinUI3 · 浅色。`fluent_ui` theme.dart:469 `#F9F9F9`，带右分隔线。
  static const winuiLight = StyleSidebar(
    color: Color(0xFFF9F9F9),
    borderRight: true,
  );

  /// WinUI3 · 深色。**实测自真实 Windows 11 设置页**：侧栏 `#21201F`(33,32,31)，
  /// 比内容区（`#2B2B2B`，43,43,43）**更暗**。
  ///
  /// 2026-10-19 修正：原值 `#2C2C2C` 是我按理解取的，与内容区同色 —— 侧栏
  /// 于是完全看不出边界。真实系统里侧栏是**更暗的一层**，靠色差分层。
  static const winuiDark = StyleSidebar(
    color: Color(0xFF21201F),
    borderRight: true,
  );

  /// liquid · 浅色。CSS `:255`
  /// `linear-gradient(160deg, rgba(255,255,255,.5), rgba(255,255,255,.24))`。
  static const liquidLight = StyleSidebar(
    color: Colors.transparent,
    gradient: LinearGradient(
      begin: Alignment(-0.342, -0.940), // 160°
      end: Alignment(0.342, 0.940),
      colors: [Color(0x80FFFFFF), Color(0x3DFFFFFF)],
    ),
    borderRight: false,
  );

  /// liquid · 深色。CSS `:841`（白 .07 → .028）。
  static const liquidDark = StyleSidebar(
    color: Colors.transparent,
    gradient: LinearGradient(
      begin: Alignment(-0.342, -0.940),
      end: Alignment(0.342, 0.940),
      colors: [Color(0x12FFFFFF), Color(0x07FFFFFF)],
    ),
    borderRight: false,
  );

  /// frosted · 浅色。CSS `:336` `rgba(255,255,255,.55)` + 右分隔线。
  static const frostedLight = StyleSidebar(
    color: Color(0x8CFFFFFF),
    borderRight: true,
  );

  /// frosted · 深色。CSS `:888` 白 .05 + 右分隔线。
  static const frostedDark = StyleSidebar(
    color: Color(0x0DFFFFFF),
    borderRight: true,
  );

  /// clay · 浅色。CSS `:402` `#f3ece4` + 右分隔线。
  static const clayLight = StyleSidebar(
    color: Color(0xFFF3ECE4),
    borderRight: true,
  );

  /// clay · 深色。CSS `:935` `#2A231D` + 右分隔线。
  static const clayDark = StyleSidebar(
    color: Color(0xFF2A231D),
    borderRight: true,
  );
}

/// 侧边栏底色令牌入口。
extension AppStyleSidebarTokens on AppStyle {
  StyleSidebar sidebarOf(Brightness brightness) =>
      brightness == Brightness.dark
          ? StyleSidebar.winuiDark
          : StyleSidebar.winuiLight;
}

/// 按钮装饰随风格变（CSS `.btn` / `.btn.primary`）。
///
/// 改造前按钮没有独立令牌，全应用共用一套 `FilledButton.styleFrom` 取值；
/// 这组令牌是 S5 的新增维度。**几何**（圆角档位、高度）不在这里 —— 那是
/// [AppRadius] 的事，这里只管「面 / 边 / 影」。
@immutable
class StyleButton {
  final Color color;

  /// liquid / clay 主按钮用（`linear-gradient(135deg, var(--ac), var(--ac2))`）。
  final Gradient? primaryGradient;

  /// 主按钮底色（frosted 是实色 `var(--ac)`，无渐变）。
  final Color? primaryColor;

  final Color borderColor;

  /// 普通按钮阴影（CSS 每套一条）。
  final BoxShadow shadow;

  /// 主按钮阴影（CSS 每套一条）。
  final BoxShadow primaryShadow;

  /// 主按钮顶边高光（liquid 的 `inset 0 1px 0 rgba(255,255,255,.35)`；
  /// Flutter 无 inset shadow，取叠加一条 1px 顶描边的近似 —— 偏差如实记录）。
  final Color? primaryTopHighlight;

  const StyleButton({
    required this.color,
    this.primaryGradient,
    this.primaryColor,
    required this.borderColor,
    required this.shadow,
    required this.primaryShadow,
    this.primaryTopHighlight,
  });

  /// WinUI3 · 浅色。主按钮是**纯强调色实心**，没有渐变（这是与 liquid/clay
  /// 最大的形态差异）；普通按钮是极淡表层色 + 1px 边线，阴影几乎为零。
  static const winuiLight = StyleButton(
    color: Color(0x0A000000),
    primaryColor: Color(0xFF0078D4),
    borderColor: Color(0x14000000),
    shadow: BoxShadow(color: Color(0x08000000), offset: Offset(0, 1), blurRadius: 2),
    primaryShadow: BoxShadow(color: Color(0x14000000), offset: Offset(0, 1), blurRadius: 2),
  );

  /// WinUI3 · 深色。主按钮用亮一档的强调色（配深字，见色板 onAccent）。
  static const winuiDark = StyleButton(
    color: Color(0x0FFFFFFF),
    primaryColor: Color(0xFF4CC2FF),
    borderColor: Color(0x1FFFFFFF),
    shadow: BoxShadow(color: Color(0x1A000000), offset: Offset(0, 1), blurRadius: 2),
    primaryShadow: BoxShadow(color: Color(0x1F000000), offset: Offset(0, 1), blurRadius: 2),
  );

  /// liquid · 浅色。CSS `:293-302`。
  static const liquidLight = StyleButton(
    color: Color(0xB3FFFFFF), // rgba(255,255,255,.7)
    primaryGradient: LinearGradient(
      begin: Alignment(-0.707, -0.707),
      end: Alignment(0.707, 0.707),
      colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
    ),
    borderColor: Color(0xD9FFFFFF), // rgba(255,255,255,.85)
    shadow: BoxShadow(
      color: Color(0x4D362650), // 0 3px 10px -6px rgba(38,38,80,.3)
      offset: Offset(0, 3),
      blurRadius: 10,
      spreadRadius: -6,
    ),
    primaryShadow: BoxShadow(
      color: Color(0xFF4F46E5),
      offset: Offset(0, 10),
      blurRadius: 26,
      spreadRadius: -10,
    ),
    primaryTopHighlight: Color(0x59FFFFFF),
  );

  /// liquid · 深色。CSS `:849` 只改了面与边（.07 白 / 边 .12）；
  /// 主按钮深色段未覆盖，沿用浅色渐变（`--ac` 深色即 `#7C8DFF`，由
  /// 色板派的渐变在此处无法逐字节复刻 CSS —— CSS 深色本就没写）。
  static const liquidDark = StyleButton(
    color: Color(0x12FFFFFF),
    primaryGradient: LinearGradient(
      begin: Alignment(-0.707, -0.707),
      end: Alignment(0.707, 0.707),
      colors: [Color(0xFF818CF8), Color(0xFFA78BFA)],
    ),
    borderColor: Color(0x1FFFFFFF),
    shadow: BoxShadow(
      color: Color(0x00000000), // 深色段未给 .btn 阴影，取无
      offset: Offset(0, 3),
      blurRadius: 10,
      spreadRadius: -6,
    ),
    primaryShadow: BoxShadow(
      color: Color(0xFF818CF8),
      offset: Offset(0, 10),
      blurRadius: 26,
      spreadRadius: -10,
    ),
    primaryTopHighlight: Color(0x26FFFFFF),
  );

  /// frosted · 浅色。CSS `:364-370`：白 .9 + `var(--ln)` 边 + 单条小影；
  /// 主按钮实色 `var(--ac)`。
  static const frostedLight = StyleButton(
    color: Color(0xB3FFFFFF),
    primaryColor: Color(0xFF0F6CBD),
    borderColor: Color(0x0F0F172A),
    shadow: BoxShadow(
      color: Color(0x0D101014), // 0 1px 2px rgba(16,16,20,.05)
      offset: Offset(0, 1),
      blurRadius: 2,
    ),
    primaryShadow: BoxShadow(
      color: Color(0xFF0F6CBD),
      offset: Offset(0, 6),
      blurRadius: 18,
      spreadRadius: -8,
    ),
  );

  /// frosted · 深色。CSS `:898`：白 .08 面、`--ln` 边（rgba(242,242,244,.12)）。
  static const frostedDark = StyleButton(
    color: Color(0x0FFFFFFF),
    primaryColor: Color(0xFF38BDF8),
    borderColor: Color(0x12FFFFFF),
    shadow: BoxShadow(
      color: Color(0x00000000), // 深色段未给 .btn 阴影
      offset: Offset(0, 1),
      blurRadius: 2,
    ),
    primaryShadow: BoxShadow(
      color: Color(0xFF38BDF8),
      offset: Offset(0, 6),
      blurRadius: 18,
      spreadRadius: -8,
    ),
  );

  /// clay · 浅色。CSS `:427-435`：#fffdfa 面 + `var(--ln)` 边 + 小影；
  /// 主按钮渐变 `--ac→--ac2`。
  static const clayLight = StyleButton(
    color: Color(0xFFFFFDFA),
    primaryGradient: LinearGradient(
      begin: Alignment(-0.707, -0.707),
      end: Alignment(0.707, 0.707),
      colors: [Color(0xFFC2410C), Color(0xFFEA580C)],
    ),
    borderColor: Color(0x141C1917),
    shadow: BoxShadow(
      color: Color(0x0F574E46), // 0 1px 2px rgba(87,78,70,.06)
      offset: Offset(0, 1),
      blurRadius: 2,
    ),
    primaryShadow: BoxShadow(
      color: Color(0xFFC2410C), // 0 8px 20px -10px var(--ac)
      offset: Offset(0, 8),
      blurRadius: 20,
      spreadRadius: -10,
    ),
  );

  /// clay · 深色。CSS `:945` `#2F2720` 面 + `--ln` 边。
  static const clayDark = StyleButton(
    color: Color(0xFF2B251E),
    primaryGradient: LinearGradient(
      begin: Alignment(-0.707, -0.707),
      end: Alignment(0.707, 0.707),
      colors: [Color(0xFFFB923C), Color(0xFFFDBA74)],
    ),
    borderColor: Color(0x12FFFDFB),
    shadow: BoxShadow(
      color: Color(0x00000000), // 深色段未给 .btn 阴影
      offset: Offset(0, 1),
      blurRadius: 2,
    ),
    primaryShadow: BoxShadow(
      color: Color(0xFFEA580C),
      offset: Offset(0, 8),
      blurRadius: 20,
      spreadRadius: -10,
    ),
  );
}

/// 按钮令牌入口。
extension AppStyleButtonTokens on AppStyle {
  StyleButton buttonOf(Brightness brightness) =>
      brightness == Brightness.dark
          ? StyleButton.winuiDark
          : StyleButton.winuiLight;
}

// ══════════════════════════════════════════════════════════════
// S6 · 组件形态令牌（几何：高度 / 圆角 / 边线 / 底色策略）
//
// 前三组令牌（AppSurface 材质、AppColors 颜色、AppStyleRadiusTokens 半径）
// 只覆盖到「一块面长什么样」。但 2026-10-19 用户裁定「照抄窗口材质和界面
// 风格、连布局/组件形态一起换」之后，光有面不够 —— WinUI3 与另三套的差别
// 有一半在控件形态上：
//
//   组件     | 另三套                    | WinUI3
//   标题栏   | 44px 高、圆角按钮内缩 2px | 32px 高、直角按钮 flush 到窗口边
//   开关     | Material Switch.adaptive  | 40x20 胶囊 + 12px 圆滑块
//   选项格   | 9px 圆角 + 凹面底         | 4px 圆角 + 1px 边线
//   徽章     | 999 胶囊                  | 4px 圆角矩形
//   导航行   | 12px 圆角                 | 4px 圆角
//
// 所以这里再加一组几何令牌。与 AppStyleRadiusTokens 的分工：后者是
// 「卡片级」的大半径档位，这里是控件级的具体尺寸，一个槽位只服务一个
// 组件 —— 不做通用化，通用化会把「WinUI 的标题栏就是 32px」这条事实稀释成
// 「一个可调参数」。
// ══════════════════════════════════════════════════════════════

/// 组件形态令牌 —— 几何与「用底色还是用边线」的策略。
///
/// 全部字段都是具体尺寸/布尔，没有相对系数：每个槽位对应一个真实控件，
/// 值直接取自 WinUI3 规范或既有预览稿，改动时一眼能核对。
@immutable
class StyleShape {
  /// 标题栏高度。WinUI3 = 32（Windows 11 标准标题栏），另三套 44。
  final double titleBarHeight;

  /// 窗口按钮尺寸。WinUI3 = 46x32（flush 到窗口右上角）。
  final double captionWidth;
  final double captionHeight;

  /// 窗口按钮圆角。WinUI3 = 0（直角），另三套 6。
  final double captionRadius;

  /// 窗口按钮的外边距。WinUI3 = 0（按钮之间无缝），另三套 2。
  final double captionMargin;

  /// 标题栏底色是否取侧栏同色（WinUI3 的标题栏与 NavigationView 连成一片）。
  /// false = 取 surfaceSolid 85%（另三套的既有画法）。
  final bool titleBarTintedLikeSidebar;

  /// 开关轨道尺寸。WinUI3 = 40x20。
  final double switchWidth;
  final double switchHeight;

  /// 滑块直径。WinUI3 = 12（轨道内缩 4）。
  final double switchThumb;

  /// 选项格圆角。WinUI3 = 4，另三套 9。
  final double optCellRadius;

  /// 选项格是否画 1px 边线（WinUI3 用边线分层，另三套用凹面底色）。
  final bool optCellBordered;

  /// 徽章圆角。WinUI3 = 4（矩形），另三套 999（胶囊）。
  final double badgeRadius;

  /// 徽章内边距。
  final double badgePadH;
  final double badgePadV;

  /// 导航行圆角。WinUI3 = 4，另三套 12。
  final double navRowRadius;

  const StyleShape({
    required this.titleBarHeight,
    required this.captionWidth,
    required this.captionHeight,
    required this.captionRadius,
    required this.captionMargin,
    required this.titleBarTintedLikeSidebar,
    required this.switchWidth,
    required this.switchHeight,
    required this.switchThumb,
    required this.optCellRadius,
    required this.optCellBordered,
    required this.badgeRadius,
    required this.badgePadH,
    required this.badgePadV,
    required this.navRowRadius,
  });

  /// WinUI3 形态。取值来源：
  /// - 标题栏 32px / 按钮 46x32：Windows 11 标准标题栏（fluent_ui 的
  ///   NavigationView 与系统窗口一致）。
  /// - 开关 40x20 / 滑块 12：fluent_ui 的 ToggleSwitch 尺寸。
  /// - 选项格 / 徽章 / 导航行 4px：WinUI3 的「控件圆角 4px」规范。
  static const winui = StyleShape(
    titleBarHeight: 32,
    captionWidth: 46,
    captionHeight: 32,
    captionRadius: 0,
    captionMargin: 0,
    titleBarTintedLikeSidebar: true,
    switchWidth: 40,
    switchHeight: 20,
    switchThumb: 12,
    optCellRadius: 4,
    optCellBordered: true,
    badgeRadius: 4,
    badgePadH: 7,
    badgePadV: 2,
    navRowRadius: 4,
  );

  /// 另三套（liquid / frosted / clay）共用一份 —— 它们改造前就是同一套形态，
  /// 差别只在材质与颜色上。这不是「懒得分开」：既有 12 个测试文件钉着这些
  /// 尺寸，把三套拆开会让「改形态」变成「改三套形态」，而用户要的是
  /// 「一次只做一个风格」。
  static const legacy = StyleShape(
    titleBarHeight: 44,
    captionWidth: 46,
    captionHeight: 32,
    captionRadius: 6,
    captionMargin: 2,
    titleBarTintedLikeSidebar: false,
    switchWidth: 36,
    switchHeight: 20,
    switchThumb: 14,
    optCellRadius: 9,
    optCellBordered: false,
    badgeRadius: 999,
    badgePadH: 8,
    badgePadV: 2,
    navRowRadius: 12,
  );
}

/// 形态令牌入口（AppStyle 的第六组扩展）。
extension AppStyleShapeTokens on AppStyle {
  StyleShape shapeOf() => StyleShape.winui;
}
