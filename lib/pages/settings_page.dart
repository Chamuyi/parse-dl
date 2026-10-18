import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_locale.dart';
import '../l10n/l10n.dart';
import '../services/app_state.dart';
import '../services/settings_store.dart';
import '../theme/app_style.dart';
import '../theme/app_theme.dart';
import '../theme/window_material.dart';
import '../widgets/account_section.dart';
import '../widgets/app_section.dart';
import '../widgets/background_picker.dart';
import '../widgets/bili_section.dart';
import '../widgets/download_section.dart';
import '../widgets/douyin_section.dart';
import '../widgets/material_picker.dart';
import '../widgets/nav_layout_picker.dart';
import '../widgets/proxy_section.dart';
import '../widgets/section_card.dart';
import '../widgets/accent_picker.dart';
import '../widgets/sub_section.dart';
import '../widgets/tint_picker.dart';
import '../widgets/app_toast.dart';
import '../widgets/page_header.dart';

/// 设置页。
///
/// **全折叠策略**：每个分区（外观 / 账号 / 下载 / 代理 / 高级 / 应用）
/// 本身就是一个可折叠块，**默认全部收起** —— 页面打开时只有分区标题，
/// 不露出任何设置内容。
///
/// 收起态只给一行**中性概要**（说明该分区管什么），
/// **不写入任何当前值**：材质、路径、模板、代理地址、登录状态都不外漏。
/// 要看具体配置，点开分区即可。
///
/// 分区内部**不再嵌套第二层折叠** —— 折叠只有一层，展开即平铺全部字段，
/// 免去「展开之后还要再展开一次」。唯一例外是「代理」分区带 `forceExpand`：
/// 代理地址变成必填时自动展开，不把必需项藏在收起态里。
/// 设置页显示哪一组设置。
///
/// 需求：「软件设置页面只保留全局设置」，而 X 下载、抖音解析下载、B 站解析下载
/// 各自作为**独立设置分组** —— 既不混进全局设置，也不互相合并。所以这里是同一个
/// 页面组件，按 scope 只渲染属于本页的那一段。
enum SettingsScope {
  /// 全局设置：外观 / 账号 / 代理 / 高级 / 应用
  global,

  /// X 下载模块自己的设置（原「下载」分区）
  xDownload,

  /// 抖音解析下载模块自己的设置（原「抖音」分区）
  douyin,

  /// B 站解析下载模块自己的设置
  bili;

  String get title => switch (this) {
    SettingsScope.global => '设置',
    SettingsScope.xDownload => 'X 下载设置',
    SettingsScope.douyin => '抖音解析下载设置',
    SettingsScope.bili => 'B 站解析下载设置',
  };

  IconData get icon => switch (this) {
    SettingsScope.global => Icons.settings_rounded,
    SettingsScope.xDownload => Icons.download_rounded,
    // 四个模块图标统一用 *_rounded 的**描边**款：play_circle_fill_rounded 是实心块，
    // 混进 download_rounded / music_note_rounded 这一排里会像一个多了底色。
    SettingsScope.douyin => Icons.music_note_rounded,
    SettingsScope.bili => Icons.play_circle_outline_rounded,
  };

  /// 页头副题 —— 预览稿 `index.html` PAGES 每页的 `s:` 字段（660-724 行），
  /// 逐个 scope 照抄。走 `t()` 由调用方翻译（[PageHeader] 不含中文字面量）。
  String get subtitle => switch (this) {
    SettingsScope.global => '外观 · 下载 · 代理 · 分模块',
    SettingsScope.xDownload => '账号 · 下载 · 接口缓存',
    SettingsScope.douyin => '下载源、筛选与命名',
    SettingsScope.bili => '画质、合并、附加与命名',
  };
}

class SettingsPage extends StatelessWidget {
  final Brightness brightness;

  /// 材质变更后需要立刻应用到原生窗口
  final Future<void> Function(WindowMaterial) onMaterialChanged;

  /// 显示哪一组设置（默认全局）
  final SettingsScope scope;

  /// 切到另一个设置页 —— **只给全局设置页的「分模块设置」入口用**。
  ///
  /// 默认 null：四个设置页共用这一个组件，模块页里没有跨页入口，
  /// 而测试里也常常只泵一个页面（不给回调就不该崩）。
  final void Function(String routeId)? onNavigate;

  const SettingsPage({
    super.key,
    required this.brightness,
    required this.onMaterialChanged,
    this.scope = SettingsScope.global,
    this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final appearance = store.settings.appearance;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        // 页头：共享 [PageHeader]（预览稿 `.head h1 .sub`）。旧版是自带 44×44
        // accentSoft 图标方块的私有 _PageHeader，2026-10-13 按用户裁定换成
        // 预览稿那一套纯文字页头。原私有页头的外边距 `only(top: 28, bottom: 24)`
        // 在这里按等量间距补回，页面高度不塌。
        Padding(
          padding: const EdgeInsets.only(top: 28, bottom: 24),
          child: PageHeader(
            title: t(scope.title),
            subtitle: t(scope.subtitle),
          ),
        ),

        // ── 全局设置：双栏平铺 ────────────────────────────────
        // 预览稿 `.cols`（`app.css:111`）：两个 `flex:1` 的 pane、间距 11px。
        // 左 pane = 外观 + 代理，右 pane = 下载 + 应用（`index.html:662-697`）。
        // 每张卡改用共享 [SectionCard] 平铺，去掉折叠壳 —— 打开设置页即见当前值。
        if (scope == SettingsScope.global)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SectionCard(
                      title: t('外观'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
              _Field(
                label: t('界面语言'),
                description:
                    t('选择应用界面的语言。选「跟随系统」时，系统语言为中文就用中文，'
                        '否则用英文。切换后立即生效，并在下次启动时保留。'),
                child: _LocalePicker(
                  value: appearance.locale,
                  onChanged: (l) => store.setAppearance((a) => a.locale = l),
                ),
              ),
              // 2026-10-19：窗口材质选择格按图吧工具箱「窗口材质」卡重建
              // （`SettingsPage.xaml:500-583`，2×2 四格）。上一轮把这档删掉
              // 是判断失误 —— 参照物证明 WinUI3 应用可以做 4 档材质，而且
              // 它的做法比原下拉框更完整（预览块逐档不同）。
              // 点击后：写设置 → 立刻应用原生窗口 → 选中态跟着变。
              _Field(
                label: t('窗口材质'),
                description: t('选择窗口背景的视觉材质效果，并可自定义色调'),
                child: MaterialPicker(
                  value: appearance.windowMaterial,
                  onChanged: (m) {
                    store.setAppearance((a) => a.windowMaterial = m);
                    onMaterialChanged(m);
                  },
                ),
              ),
              // 「界面风格」仍不设选择器：`AppStyle` 只剩 WinUI 一个值，
              // 留一个只有一项的下拉框只会让人以为坏了。
              // 强调色只在 WinUI 风格下可选 —— 另三套风格各有自己的强调色
              // 令牌，显示一个不起作用的选择器会让人以为坏了（2026-10-19）。
              if (appearance.visualStyle == AppStyle.winui)
                _Field(
                  label: t('强调色'),
                  description: t('WinUI 风格下的强调色：按钮、选中态与链接都用它。'),
                  child: AccentPicker(
                    value: appearance.winUiAccent,
                    onChanged: (a) =>
                        store.setAppearance((x) => x.winUiAccent = a),
                  ),
                ),
              _Field(
                label: t('自定义色调'),
                description:
                    t('开启后用选定颜色给窗口底色染色，让材质效果更明显。'
                        '需要先选择「云母」或「亚克力」材质。'),
                trailing: Switch(
                  value: appearance.customTint,
                  onChanged: (v) =>
                      store.setAppearance((a) => a.customTint = v),
                ),
                child: appearance.customTint
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TintPicker(
                            value: appearance.tintColor,
                            onChanged: (hex) =>
                                store.setAppearance((a) => a.tintColor = hex),
                          ),
                          // 图吧工具箱「自定义色调」展开后的第二、三行：
                          // 色调不透明度 / 明度不透明度，范围 0..1，右侧百分比整数。
                          const SizedBox(height: 16),
                          _TintSliderRow(
                            label: t('色调不透明度'),
                            value: appearance.tintOpacity,
                            onChanged: (v) => store.setAppearance(
                              (a) => a.tintOpacity = v,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _TintSliderRow(
                            label: t('明度不透明度'),
                            value: appearance.tintLuminosityOpacity,
                            onChanged: (v) => store.setAppearance(
                              (a) => a.tintLuminosityOpacity = v,
                            ),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
              _Field(
                label: t('导航形态'),
                description:
                    t('选择主界面用哪种导航：底部悬浮 Dock，或左侧常规侧边栏。'
                        '两者展示完全相同的页面与顺序，切换后立即生效，并在下次启动时保留。'),
                child: NavLayoutPicker(
                  value: appearance.navLayout,
                  onChanged: (l) => store.setAppearance((a) => a.navLayout = l),
                ),
              ),
              _Field(
                label: t('主题模式'),
                description: t('选择「跟随系统」后，应用会随 Windows 的浅色/深色设置自动切换。'),
                child: _ThemeModePicker(
                  value: appearance.themeMode,
                  onChanged: (m) => store.setAppearance((a) => a.themeMode = m),
                ),
              ),
              _Field(
                label: t('背景图片'),
                description: t('导入一张本地图片作为主界面背景，可调节不透明度以配合窗口材质。'),
                child: BackgroundPicker(
                  value: appearance.backgroundImage,
                  opacity: appearance.backgroundImageOpacity,
                  onChanged: (v) =>
                      store.setAppearance((a) => a.backgroundImage = v),
                  onOpacityChanged: (v) =>
                      store.setAppearance((a) => a.backgroundImageOpacity = v),
                ),
              ),
                        ],
                      ),
                    ),
                    SectionCard(
                      title: t('代理'),
                      child: const ProxySection(),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SectionCard(
                      title: t('下载'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SubSection(t('分模块设置')),
                          for (final m in _kModuleSettingsEntries)
                            _ModuleSettingsEntry(
                              title: t(m.title),
                              // 副标题直接复用各模块设置页里那份「收起态概要」的措辞，
                              // 不另写一套 —— 两处说的是同一件事，措辞分叉就会互相矛盾。
                              description: t(m.description),
                              onOpen: onNavigate == null
                                  ? null
                                  : () => onNavigate!(m.routeId),
                            ),
                        ],
                      ),
                    ),
                    SectionCard(
                      title: t('应用'),
                      child: const AppSection(),
                    ),
                  ],
                ),
              ),
            ],
          ),

        // ── 账号 ──────────────────────────────────────────────
        // X 账号的登录属于 **X 下载模块**：它是 X 下载功能的前置条件
        // （没登录就抓不到媒体），所以跟保存路径、模板一起放在
        // 「X 下载 › 设置」里，不再占全局设置的位置。
        if (scope == SettingsScope.xDownload)
          SectionCard(
            title: t('账号'),
            trailing: t('登录状态、cookie 输入与验证'),
            child: const AccountSection(),
          ),

        // ── 接口缓存 ──────────────────────────────────────────
        // 顺序：账号 → 接口缓存 → 下载。
        // 「接口缓存」是**排障**用的（搜索用户或加载媒体失败时清一次），
        // 夹在「账号」（前置条件：没登录就抓不到）与「下载」（配置：存哪、叫什么）
        // 之间 —— 两端各是一次性的/日常的动作，排障项放最下面才不挡路。
        //
        // 为什么在 X 页而不是全局：这个缓存存的是 **X 的** GraphQL 接口标识
        // （见 `x_api.dart` 的 queryId 缓存），与抖音、B 站无关；而抖音 / B 站
        // 各自的设置页里也没有对应物，放在全局「高级」里等于让全局页替某一个
        // 模块背排障工具。
        if (scope == SettingsScope.xDownload)
          SectionCard(
            title: t('接口缓存'),
            trailing: t('X 接口标识缓存（搜索用户或加载媒体失败时使用）'),
            child: _Field(
                label: t('刷新 X 接口缓存'),
                description:
                    t('搜索用户或加载媒体失败时（如提示「找不到该用户」或长时间无响应），'
                        '通常是 X 更换了内部接口标识。点此清除缓存后重新搜索即可。'),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      context.read<AppState>().api.clearQueryIdCache();
                      AppToast.show(context, t('已清除 X 接口缓存，请重新搜索'),
                          kind: AppToastKind.success);
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: Text(t('清除缓存并重试')),
                  ),
                ),
              ),
          ),

        // ── 下载 ──────────────────────────────────────────────
        if (scope == SettingsScope.xDownload)
          SectionCard(
            title: t('下载'),
            trailing: t('保存路径、文件夹 / 文件名模板、同名文件处理'),
            child: const DownloadSection(),
          ),

        // ── 抖音 ──────────────────────────────────────────────
        if (scope == SettingsScope.douyin)
          SectionCard(
            title: t('抖音'),
            trailing: t('下载源、质量优先策略、图片格式、批量与筛选选项'),
            child: const DouyinSection(),
          ),

        // ── B 站 ──────────────────────────────────────────────
        if (scope == SettingsScope.bili)
          SectionCard(
            title: t('B 站'),
            trailing: t('画质上限、编码偏好、下载完合并、命名模板'),
            child: const BiliSection(),
          ),

      ],
    );
  }
}

/// 全局设置页「分模块设置」里的一个入口。
class _ModuleSettingsEntryData {
  /// 入口名（模块的通用叫法）
  final String title;

  /// 副标题：这个模块的设置页管什么
  final String description;

  /// 点「打开」要去的路由 id（`app.dart` 的 `_pageFor` 认得这些 id）
  final String routeId;

  const _ModuleSettingsEntryData(this.title, this.description, this.routeId);
}

/// 三个下载模块的设置入口 —— **顺序与侧边栏里的模块顺序一致**（X / 抖音 / B 站）。
///
/// `description` 逐字复用各模块设置页分区的收起态概要：两处说的是同一件事，
/// 各自维护一份措辞早晚会分叉，而 `settings_collapsed_test.dart` 正是拿那些
/// 字面量钉住概要的 —— 改一处漏一处就会被撞出来。
const List<_ModuleSettingsEntryData> _kModuleSettingsEntries = [
  _ModuleSettingsEntryData(
    'X 下载',
    '登录状态、cookie 输入与验证、保存路径、文件夹 / 文件名模板、同名文件处理',
    'x-settings',
  ),
  _ModuleSettingsEntryData(
    '抖音解析下载',
    '下载源、质量优先策略、图片格式、批量与筛选选项',
    'douyin-settings',
  ),
  _ModuleSettingsEntryData(
    'B 站解析下载',
    '画质上限、编码偏好、下载完合并、命名模板',
    'bili-settings',
  ),
];

// ────────────────────────────────────────────────────────────
// 以下为通用布局组件，Section / Item
// ────────────────────────────────────────────────────────────

/// 色调滑块行：标签 + Slider(0..1) + 右侧百分比整数。
///
/// 形态照抄图吧工具箱「自定义色调」展开面板的第二、三行：标签在左、
/// 轨道占中间剩余宽度、百分比靠右对齐；范围 0..1，显示为 `xx%`。
///
/// 轨道样式与 [BackgroundPicker] 里的不透明度滑块保持一致（3px 轨、
/// 6px 滑块），两处滑块在同一页上不至于像两套控件。
class _TintSliderRow extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _TintSliderRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    // 旧配置 / 手改配置可能越界；Slider 的 value 必须落在 min..max 内，
    // 否则断言直接抛，整页白屏。
    final v = value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.0;

    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, color: c.textMuted),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              min: 0,
              max: 1,
              value: v,
              activeColor: c.accent,
              inactiveColor: c.line,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            '${(v * 100).round()}%',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 12,
              color: c.textFaint,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String description;
  final Widget child;
  final Widget? trailing;

  const _Field({
    required this.label,
    required this.description,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final tail = trailing;

    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: c.textStrong,
                ),
              ),
              // 开关紧跟标题，不推到行尾：整行约 1100px 宽，两端一分离，
              // 视线就得横穿整个页面才对上「这个开关是哪一项的」。
              if (tail != null) ...[const SizedBox(width: 10), tail],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(fontSize: 12.5, color: c.textMuted, height: 1.5),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// 「分模块设置」里的一行 —— 模块名 + 一句说明 + 右侧「打开」。
///
/// [onOpen] 为 null 时按钮置灰：没有跨页跳转能力时（测试里只泵这一页、
/// 或将来把设置页嵌进别的壳里）按钮**可见但不可点**，而不是凭空消失 ——
/// 消失会让「有三个模块设置」这件事在那一页上看不出来。
class _ModuleSettingsEntry extends StatelessWidget {
  final String title;
  final String description;
  final VoidCallback? onOpen;

  const _ModuleSettingsEntry({
    required this.title,
    required this.description,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: c.textStrong,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: c.textMuted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonalIcon(
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text(t('打开'), style: const TextStyle(fontSize: 13.5)),
          ),
        ],
      ),
    );
  }
}

/// 三档主题模式：浅色 / 深色 / 跟随系统
class _ThemeModePicker extends StatelessWidget {
  final ThemeMode2 value;
  final ValueChanged<ThemeMode2> onChanged;

  const _ThemeModePicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const options = <(ThemeMode2, String, IconData)>[
      (ThemeMode2.light, '浅色', Icons.wb_sunny_rounded),
      (ThemeMode2.dark, '深色', Icons.nightlight_round),
      (ThemeMode2.system, '跟随系统', Icons.desktop_windows_rounded),
    ];

    return _SegmentedPicker(
      segments: [
        for (final (mode, label, icon) in options)
          _Segment(
            label: t(label),
            icon: icon,
            selected: value == mode,
            onTap: () => onChanged(mode),
          ),
      ],
    );
  }
}

/// 三档界面语言：跟随系统 / 简体中文 / English
///
/// 与 [_ThemeModePicker] 共用 [_SegmentedPicker]，只是数据源不同 ——
/// 两处各自列自己的选项，比抽一个泛型分段控件更直白（选项要配图标）。
class _LocalePicker extends StatelessWidget {
  final AppLocale value;
  final ValueChanged<AppLocale> onChanged;

  const _LocalePicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const options = <(AppLocale, IconData)>[
      (AppLocale.system, Icons.desktop_windows_rounded),
      (AppLocale.zh, Icons.translate_rounded),
      (AppLocale.en, Icons.translate_rounded),
    ];

    return _SegmentedPicker(
      segments: [
        for (final (locale, icon) in options)
          _Segment(
            label: t(locale.label),
            icon: icon,
            selected: value == locale,
            onTap: () => onChanged(locale),
          ),
      ],
    );
  }
}

/// 分段控件里的一个选项
class _Segment {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _Segment({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
}

/// 互斥单选的**分段控件**：一个描边底框把几档选项框成一组，段与段之间
/// 画一道分隔线。
///
/// 之前只是把三个胶囊并排放，选中项整块铺满主色，看着像三个独立按钮，
/// 读不出「三选一」。分隔线在紧挨选中段的那一侧不画 —— 否则等于
/// 给选中态又描了一圈边，反而糊掉了「哪一段是被选的」。
class _SegmentedPicker extends StatelessWidget {
  final List<_Segment> segments;

  const _SegmentedPicker({required this.segments});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.lineStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0 && !segments[i - 1].selected && !segments[i].selected)
              Container(width: 1, height: 18, color: c.lineStrong),
            _ModeButton(
              label: segments[i].label,
              icon: segments[i].icon,
              selected: segments[i].selected,
              onTap: segments[i].onTap,
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ModeButton> createState() => _ModeButtonState();
}

class _ModeButtonState extends State<_ModeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          // 选中态走主题里那一个定义，不再自己另画一套高饱和铺底 + 白字
          decoration: widget.selected
              ? selectedDecoration(c, radius: 9)
              : BoxDecoration(
                  color: _hover ? c.surfaceCardHover : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  // 透明描边占住选中态那 1px 边框，切换选项时胶囊不跳格
                  border: Border.all(color: Colors.transparent, width: 1),
                ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 14,
                color: widget.selected ? c.accentText : c.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: widget.selected ? FontWeight.w600 : null,
                  color: widget.selected ? c.accentText : c.textMuted,
                ),
              ),
              if (widget.selected) ...[
                const SizedBox(width: 4),
                Icon(Icons.check_rounded, size: 12, color: c.accentText),
              ],
            ],
          ),
        ),
      ),
    );
  }
}