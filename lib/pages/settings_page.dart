import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_locale.dart';
import '../l10n/l10n.dart';
import '../services/app_state.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../theme/window_material.dart';
import '../widgets/account_section.dart';
import '../widgets/app_section.dart';
import '../widgets/background_picker.dart';
import '../widgets/collapsible_group.dart';
import '../widgets/download_section.dart';
import '../widgets/douyin_section.dart';
import '../widgets/material_picker.dart';
import '../widgets/nav_layout_picker.dart';
import '../widgets/proxy_section.dart';
import '../widgets/tint_picker.dart';
import '../widgets/app_toast.dart';

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
/// 需求：「软件设置页面只保留全局设置」，而 X 下载与抖音解析下载各自作为
/// **独立设置分组** —— 既不混进全局设置，也不互相合并。所以这里是同一个
/// 页面组件，按 scope 只渲染属于本页的那一段。
enum SettingsScope {
  /// 全局设置：外观 / 账号 / 代理 / 高级 / 应用
  global,

  /// X 下载模块自己的设置（原「下载」分区）
  xDownload,

  /// 抖音解析下载模块自己的设置（原「抖音」分区）
  douyin;

  String get title => switch (this) {
    SettingsScope.global => '设置',
    SettingsScope.xDownload => 'X 下载设置',
    SettingsScope.douyin => '抖音解析下载设置',
  };

  IconData get icon => switch (this) {
    SettingsScope.global => Icons.settings_rounded,
    SettingsScope.xDownload => Icons.download_rounded,
    SettingsScope.douyin => Icons.music_note_rounded,
  };
}

class SettingsPage extends StatelessWidget {
  final Brightness brightness;

  /// 材质变更后需要立刻应用到原生窗口
  final Future<void> Function(WindowMaterial) onMaterialChanged;

  /// 显示哪一组设置（默认全局）
  final SettingsScope scope;


  const SettingsPage({
    super.key,
    required this.brightness,
    required this.onMaterialChanged,
    this.scope = SettingsScope.global,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final appearance = store.settings.appearance;
    final proxy = store.settings.proxy;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _PageHeader(title: t(scope.title), icon: scope.icon),

        // ── 外观 ──────────────────────────────────────────────
        if (scope == SettingsScope.global)
          CollapsibleGroup(
            storageId: 'section.appearance',
            variant: CollapsibleVariant.section,
            title: t('外观'),
            icon: Icons.palette_rounded,
            summary: t('窗口材质、自定义色调、导航形态、主题模式、背景图片、界面语言'),
            expandLabel: t('展开设置'),
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
              _Field(
                label: t('窗口材质'),
                description:
                    t('云母材质需要 Windows 11，亚克力需要 Windows 10 1809 以上；'
                        '系统不支持时会退回纯色背景。'),
                child: MaterialPicker(
                  value: appearance.windowMaterial,
                  brightness: brightness,
                  onChanged: (m) async {
                    await store.setAppearance((a) => a.windowMaterial = m);
                    await onMaterialChanged(m);
                  },
                ),
              ),
              _Field(
                label: t('自定义色调'),
                description:
                    t('开启后用选定颜色给窗口底色染色，让材质效果更明显。'
                        '需要先选择「云母」或「亚克力」材质。'),
                trailing: Switch(
                  value: appearance.customTint,
                  onChanged: appearance.windowMaterial == WindowMaterial.none
                      ? null
                      : (v) => store.setAppearance((a) => a.customTint = v),
                ),
                child:
                    appearance.customTint &&
                        appearance.windowMaterial != WindowMaterial.none
                    ? TintPicker(
                        value: appearance.tintColor,
                        onChanged: (hex) =>
                            store.setAppearance((a) => a.tintColor = hex),
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

        // ── 账号 ──────────────────────────────────────────────
        // X 账号的登录属于 **X 下载模块**：它是 X 下载功能的前置条件
        // （没登录就抓不到媒体），所以跟保存路径、模板一起放在
        // 「X 下载 › 设置」里，不再占全局设置的位置。
        if (scope == SettingsScope.xDownload)
          CollapsibleGroup(
            storageId: 'section.account',
            variant: CollapsibleVariant.section,
            title: t('账号'),
            icon: Icons.account_circle_outlined,
            summary: t('登录状态、cookie 输入与验证'),
            expandLabel: t('展开设置'),
            children: const [AccountSection()],
          ),

        // ── 下载 ──────────────────────────────────────────────
        if (scope == SettingsScope.xDownload)
          CollapsibleGroup(
            storageId: 'section.download',
            variant: CollapsibleVariant.section,
            title: t('下载'),
            icon: Icons.download_rounded,
            summary: t('保存路径、文件夹 / 文件名模板、同名文件处理'),
            expandLabel: t('展开设置'),
            children: const [DownloadSection()],
          ),

        // ── 抖音 ──────────────────────────────────────────────
        if (scope == SettingsScope.douyin)
          CollapsibleGroup(
            storageId: 'section.douyin',
            variant: CollapsibleVariant.section,
            title: t('抖音'),
            icon: Icons.music_video_rounded,
            summary: t('下载源、质量优先策略、图片格式、批量与筛选选项'),
            expandLabel: t('展开设置'),
            children: const [DouyinSection()],
          ),

        // ── 代理 ──────────────────────────────────────────────
        if (scope == SettingsScope.global)
          CollapsibleGroup(
            storageId: 'section.proxy',
            variant: CollapsibleVariant.section,
            title: t('代理'),
            icon: Icons.public_rounded,
            summary: t('启用代理、使用系统代理、自定义代理地址、连通性测试'),
            expandLabel: t('展开设置'),
            // 「启用代理 + 不用系统代理 + 地址为空」时地址是必填项 →
            // 自动展开，保证收起状态不会把必需项藏起来。
            forceExpand:
                proxy.enable && !proxy.useSystem && proxy.url.trim().isEmpty,
            children: const [ProxySection()],
          ),

        // ── 高级 ──────────────────────────────────────────────
        if (scope == SettingsScope.global)
          CollapsibleGroup(
            storageId: 'section.advanced',
            variant: CollapsibleVariant.section,
            title: t('高级'),
            // 其余分组都是 *_rounded，只有这里是 outline —— 一排图标里
            // 混一种描边风格，看着像少画了一个。
            icon: Icons.build_circle_rounded,
            summary: t('X 接口标识缓存（搜索用户或加载媒体失败时使用）'),
            // 五个分组里只有这个写「展开诊断工具」，措辞统一；
            // 「诊断工具」的含义由上面的 summary 承担。
            expandLabel: t('展开设置'),
            children: [
              _Field(
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
            ],
          ),

        // ── 应用 ──────────────────────────────────────────────
        if (scope == SettingsScope.global)
          CollapsibleGroup(
            storageId: 'section.app',
            variant: CollapsibleVariant.section,
            title: t('应用'),
            icon: Icons.tune_rounded,
            summary: t('日志记录、日志目录与文件'),
            expandLabel: t('展开设置'),
            children: const [AppSection()],
          ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────
// 以下为通用布局组件，PageHeader / Section / Item
// ────────────────────────────────────────────────────────────

class _PageHeader extends StatelessWidget {
  final String title;
  final IconData icon;

  const _PageHeader({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);

    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 24),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.accentLine),
              boxShadow: [BoxShadow(color: c.accentGlow, blurRadius: 18)],
            ),
            child: Icon(icon, size: 21, color: c.accentText),
          ),
          const SizedBox(width: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
              color: c.textStrong,
            ),
          ),
        ],
      ),
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