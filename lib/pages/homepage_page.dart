import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media.dart';
import '../models/user.dart';
import '../services/app_state.dart';
import '../services/aria2_coordinator.dart';
import '../services/creation_task_store.dart';
import '../services/download_store.dart';
import '../services/homepage_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/app_toast.dart';
import '../l10n/l10n.dart';

/// 主页：搜索用户 → 加载用户信息 → 预览媒体列表 → 触发下载。
///
/// 
class HomepagePage extends StatefulWidget {
  /// 请求切换到别的页面（用于「开始下载」后直接跳到下载管理）。
  /// 由 `app.dart` 的 `_AppShellState._setRoute` 注入。
  final void Function(String routeId)? onNavigate;

  const HomepagePage({super.key, this.onNavigate});

  @override
  State<HomepagePage> createState() => _HomepagePageState();
}

class _HomepagePageState extends State<HomepagePage> {
  final TextEditingController _inputCtrl = TextEditingController();

  /// **页面级**滚动控制器。
  ///
  /// 媒体网格是嵌在这个 ListView 里的（`shrinkWrap` + 不可滚动），
  /// 所以真正滚动的只有这一层 —— 分页监听必须挂在这里。
  /// 之前挂在网格自己的 GridView 上，那里既不滚动也没有手势，
  /// 监听器一次都不会触发 → 永远停在第一页。
  final ScrollController _pageCtrl = ScrollController();

  /// 距底部多远开始预加载下一页
  static const double _loadMoreThreshold = 600;

  /// 防止「自动补页」重复调度
  bool _autoFilling = false;

  /// 单次搜索内自动补页的页数上限 —— 万一接口一直回游标却不出内容，
  /// 不至于无限请求。（用户手动滚动不受此限制）
  static const int _autoFillMaxPages = 12;
  int _autoFillCount = 0;

  HomepageStore? _hp;

  @override
  void initState() {
    super.initState();
    _hp = context.read<HomepageStore>();
    _inputCtrl.text = _hp!.keyword;
    _pageCtrl.addListener(_onPageScroll);
    // 监听 store：每次加载完成都会回调，用来做「内容撑不满一屏」的自动补页
    _hp!.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    _hp?.removeListener(_onStoreChanged);
    _pageCtrl.removeListener(_onPageScroll);
    _pageCtrl.dispose();
    _inputCtrl.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    if (!_pageCtrl.hasClients) return;
    final pos = _pageCtrl.position;
    if (pos.extentAfter < _loadMoreThreshold) {
      _hp?.loadMoreMedias();
    }
  }

  void _onStoreChanged() {
    if (_autoFilling) return;
    _autoFillIfNeeded();
  }

  /// 内容撑不满一屏时用户根本滚不动 → 再拉一页。
  ///
  /// 触发链：`loadMoreMedias()` 完成 → `notifyListeners()` → 这里再判断一次，
  /// 直到「出现滚动空间」或「没有更多」自然终止；`_autoFilling` 防并发重入。
  void _autoFillIfNeeded() {
    final hp = _hp;
    if (hp == null || hp.loadingMore || !hp.hasMore) return;
    if (_autoFillCount >= _autoFillMaxPages) return;

    _autoFilling = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoFilling = false;
      if (!mounted) return;
      // 布局完成后再看有没有滚动空间
      final pos = _pageCtrl.hasClients ? _pageCtrl.position : null;
      final noScrollRoom = pos == null || pos.maxScrollExtent <= 0;
      if (noScrollRoom && hp.hasMore && !hp.loadingMore) {
        _autoFillCount++;
        // 完成后会 notify → 再次进入本方法
        unawaited(hp.loadMoreMedias());
      }
    });
  }

  Future<void> _startSearch() async {
    final sn = _inputCtrl.text.trim();
    if (sn.isEmpty) {
      _toast(t('请输入用户 ID'));
      return;
    }
    final hp = context.read<HomepageStore>();
    final appState = context.read<AppState>();
    if (!appState.isLoggedIn) {
      _toast(t('请先在「设置」中登录 X 账号'));
      return;
    }

    await hp.loadUser(sn);
    if (!mounted) return;

    if (hp.user != null) {
      await appState.addSearchHistory(sn);
      _toast(tf('已加载 @{user}', {'user': hp.user!.screenName ?? sn}));
      _autoFillCount = 0;
      _autoFillIfNeeded();
    } else if (hp.userError != null) {
      _toast(hp.userError!);
    } else {
      _toast(t('未获取到用户信息，请检查用户 ID 是否正确'));
    }
  }

  /// 用历史记录里的 ID 搜索（同时回填输入框，避免「搜了但框里还是旧内容」）
  Future<void> _searchFromHistory(String screenName) async {
    _inputCtrl.text = screenName;
    _inputCtrl.selection =
        TextSelection.collapsed(offset: screenName.length);
    await _startSearch();
  }

  void _toast(String msg) {
    if (!mounted) return;
    // 顶部浮层，不再用底部 SnackBar（底部会撞上 Dock / 内容区下沿）
    AppToast.show(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final hp = context.watch<HomepageStore>();
    final appState = context.watch<AppState>();
    final loggedIn = appState.isLoggedIn;

    return ListView(
      controller: _pageCtrl,
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 16),
      children: [
        // ① Hero 搜索区
        AppCard(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('下载某个 X 用户的全部媒体'),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: c.textStrong,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t('输入用户 ID，加载后开始批量下载图片与视频'),
                          style: TextStyle(
                              fontSize: 13, color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _SearchBar(
                controller: _inputCtrl,
                loading: hp.loadingUser,
                hint: t(loggedIn
                    ? '请输入用户 ID，如：example_user'
                    : '未登录，点右侧按钮会提示登录'),
                onSubmit: _startSearch,
              ),
              if (appState.searchHistory.isNotEmpty) ...[
                const SizedBox(height: 14),
                _SearchHistoryRow(onPick: _searchFromHistory),
              ],
              if (hp.userError != null) ...[
                const SizedBox(height: 14),
                _ErrorBanner(text: hp.userError!, colors: c),
              ],
            ],
          ),
        ),

        // ② 用户信息卡片
        if (hp.user != null) ...[
          const SizedBox(height: 16),
          _UserCard(user: hp.user!, mediaCount: hp.media.length),
          const SizedBox(height: 12),
          // ③ 下载控制器 + 全选工具栏
          _DownloadController(
            user: hp.user!,
            totalMedia: hp.media.length,
            onNavigate: widget.onNavigate,
          ),
          const SizedBox(height: 16),
          // ④ 媒体网格
          _MediaGrid(),
        ],
      ],
    );
  }
}

class _SearchBar extends StatefulWidget {
  final TextEditingController controller;
  final bool loading;
  final String hint;
  final VoidCallback onSubmit;

  const _SearchBar({
    required this.controller,
    required this.loading,
    required this.hint,
    required this.onSubmit,
  });

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  @override
  void initState() {
    super.initState();
    // 只有输入框自己重建 —— 不再通过 store.notifyListeners 触发整页重建
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final controller = widget.controller;
    final loading = widget.loading;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: !loading,
            onSubmitted: (_) => widget.onSubmit(),
            style: TextStyle(color: c.textStrong, fontSize: 14.5),
            cursorColor: c.accent,
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: TextStyle(color: c.textMuted, fontSize: 14),
              filled: true,
              fillColor: c.surfaceSunken,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: c.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: c.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: c.accent, width: 1.4),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 46,
          child: FilledButton(
            onPressed: loading || controller.text.trim().isEmpty
                ? null
                : widget.onSubmit,
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 22),
            ),
            child: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(t('加载'), style: TextStyle(fontSize: 14)),
          ),
        ),
      ],
    );
  }
}

class _SearchHistoryRow extends StatelessWidget {
  final ValueChanged<String> onPick;
  const _SearchHistoryRow({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final history = context.watch<AppState>().searchHistory;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(t('历史'),
              style: TextStyle(fontSize: 12.5, color: c.textMuted)),
        ),
        ...history.map((sn) => _HistoryChip(label: sn, onPick: onPick)),
        GestureDetector(
          onTap: () => context.read<AppState>().clearSearchHistory(),
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(t('清空'),
                style: TextStyle(
                    fontSize: 12.5,
                    color: c.textMuted,
                    decoration: TextDecoration.underline)),
          ),
        ),
      ],
    );
  }
}

class _HistoryChip extends StatelessWidget {
  final String label;
  final ValueChanged<String> onPick;
  const _HistoryChip({required this.label, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => onPick(label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: c.surfaceSunken,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.line, width: 0.6),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 12.5, color: c.textMuted)),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String text;
  final AppColors colors;
  const _ErrorBanner({required this.text, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: colors.danger),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 13, color: colors.danger))),
        ],
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  final TwitterUser user;
  final int mediaCount;
  const _UserCard({required this.user, required this.mediaCount});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return AppCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.surfaceSunken,
              boxShadow: [
                BoxShadow(
                    color: c.accent.withValues(alpha: 0.25),
                    blurRadius: 16,
                    spreadRadius: -4),
              ],
            ),
            child: ClipOval(
              child: user.avatar != null
                  ? Image.network(
                      user.avatar!,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Icon(Icons.person, color: c.textMuted, size: 28),
                    )
                  : Icon(Icons.person, color: c.textMuted, size: 28),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        user.name ?? '未知用户',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: c.textStrong,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      tf('共 {n} 个媒体', {'n': user.mediaCount ?? mediaCount}),
                      style: TextStyle(
                          fontSize: 13, color: c.textMuted),
                    ),
                  ],
                ),
                if (user.screenName != null) ...[
                  const SizedBox(height: 2),
                  Text('@${user.screenName}',
                      style: TextStyle(
                          fontSize: 13, color: c.accent)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 媒体网格。
///
/// **注意：它自己不滚动** —— `shrinkWrap` + `NeverScrollableScrollPhysics`，
/// 高度完全撑开，滚动由外层页面的 ListView 负责（分页监听也挂在那边）。
/// 这里只负责渲染 + 末尾放一个「正在加载」占位格子。
class _MediaGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final hp = context.watch<HomepageStore>();
    final media = hp.media;

    if (media.isEmpty && !hp.loadingMore) {
      return _EmptyHint(colors: c);
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1,
      ),
      itemCount: media.length + (hp.hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= media.length) {
          return _LoadingTile(colors: c);
        }
        return _MediaTile(
          media: media[i],
          colors: c,
          selected: hp.isSelected(media[i].id),
          onTap: () => hp.toggleSelected(media[i].id),
        );
      },
    );
  }
}

class _MediaTile extends StatelessWidget {
  final Media media;
  final AppColors colors;
  final bool selected;
  final VoidCallback onTap;

  const _MediaTile({
    required this.media,
    required this.colors,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final preview = media.previewUrl ?? media.url;
    final isVideo = media.type.isVideo;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: colors.surfaceSunken,
          border: Border.all(
            color: selected ? colors.accent : colors.line,
            width: selected ? 2.0 : 0.5,
          ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (preview.isNotEmpty)
            Image.network(
              preview,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Center(
                child: Icon(Icons.broken_image,
                    color: colors.textMuted, size: 24),
              ),
              loadingBuilder: (_, child, p) =>
                  p == null ? child : Container(color: colors.surfaceSunken),
            )
          else
            Center(
              child: Icon(Icons.broken_image,
                  color: colors.textMuted, size: 24),
            ),
          if (isVideo)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(media.type == MediaType.animatedGif
                        ? Icons.gif_box_outlined
                        : Icons.play_circle_outline),
                    const SizedBox(width: 3),
                    Text(
                      media.type == MediaType.animatedGif ? 'GIF' : 'MP4',
                      style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          if (selected)
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: colors.accent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: colors.accentGlow, blurRadius: 8),
                  ],
                ),
                child: const Icon(Icons.check_rounded,
                    size: 14, color: Colors.white),
              ),
            ),
        ],
      ),
    ),
    );
  }
}

class _LoadingTile extends StatelessWidget {
  final AppColors colors;
  const _LoadingTile({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: colors.surfaceSunken,
      ),
      alignment: Alignment.center,
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2, color: colors.accent),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final AppColors colors;
  const _EmptyHint({required this.colors});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      child: Column(
        children: [
          Icon(Icons.image_not_supported_outlined,
              size: 40, color: colors.textMuted),
          const SizedBox(height: 12),
          Text(t('该用户暂无媒体'),
              style: TextStyle(fontSize: 14, color: colors.textMuted)),
        ],
      ),
    );
  }
}

// ── 下载控制器 ─────────────────────────────────────────────

/// 「下载控制器」+ 全选工具栏：
///
///   - 默认下 acceptedMedia 全部
///   - 网格里勾选了若干项 → 只下选中的
///   - 提供「全选 / 全不选」按钮
class _DownloadController extends StatefulWidget {
  final TwitterUser user;
  final int totalMedia;
  final void Function(String routeId)? onNavigate;

  const _DownloadController({
    required this.user,
    required this.totalMedia,
    this.onNavigate,
  });

  @override
  State<_DownloadController> createState() => _DownloadControllerState();
}

class _DownloadControllerState extends State<_DownloadController> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final hp = context.watch<HomepageStore>();
    final accepted = hp.acceptedMedia;
    final aria2Ready = Aria2Coordinator.instance.booted;
    final hasSelection = hp.selectedIds.isNotEmpty;
    final selectedCount = hp.selectedIds
        .where((id) => accepted.any((m) => m.id == id))
        .length;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.download_rounded, color: c.accent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tf('下载 @{user} 的媒体', {
                        'user': widget.user.screenName ??
                            widget.user.name ??
                            t('该用户'),
                      }),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.textStrong,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _statusLine(aria2Ready, accepted, hasSelection,
                          selectedCount, hp.hasMore),
                      style: TextStyle(fontSize: 12, color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                // 不再要求「已加载的媒体非空」—— 默认下载是后台任务，
                // 媒体可以边翻页边发现（原版只校验用户与媒体类型）。
                onPressed: (!aria2Ready || (hasSelection && selectedCount == 0))
                    ? null
                    : () => _start(accepted, hasSelection),
                icon: Icon(
                  hasSelection
                      ? Icons.play_arrow_rounded
                      : Icons.bolt_rounded,
                  size: 18,
                ),
                label: Text(t(hasSelection ? '下载所选' : '开始下载'),
                    style: const TextStyle(fontSize: 13.5)),
              ),
            ],
          ),
          if (accepted.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  hasSelection
                      ? '已选 $selectedCount / ${accepted.length}'
                      : '网格内点击即可选择',
                  style: TextStyle(fontSize: 12, color: c.textMuted),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    if (hasSelection) {
                      hp.clearSelection();
                    } else {
                      for (final m in accepted) {
                        if (!hp.isSelected(m.id)) hp.toggleSelected(m.id);
                      }
                    }
                  },
                  icon: Icon(
                    hasSelection
                        ? Icons.deselect_outlined
                        : Icons.select_all_outlined,
                    size: 14,
                  ),
                  label: Text(t(hasSelection ? '清空选择' : '全选')),
                  style: TextButton.styleFrom(
                    foregroundColor: c.textMuted,
                    textStyle: const TextStyle(fontSize: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _statusLine(bool aria2Ready, List<Media> accepted,
      bool hasSelection, int selectedCount, bool hasMore) {
    if (!aria2Ready) return 'aria2 启动中…请稍候';
    if (hasSelection) return '已选 $selectedCount 项，将只下这 $selectedCount 个';
    // 「默认下载」= 交给后台创建任务去翻页 —— 与下载页的进度实时联动
    if (hasMore) {
      return '已加载 ${accepted.length} 个 · 点「开始下载」创建后台任务，自动拉取该用户的全部媒体';
    }
    return '共 ${accepted.length} 个符合过滤条件 · 任务会进入后台队列';
  }

  void _toast(String msg) {
    if (!mounted) return;
    // 顶部浮层，不再用底部 SnackBar（底部会撞上 Dock / 内容区下沿）
    AppToast.show(context, msg);
  }

  /// 点「开始下载 / 下载所选」。
  ///
  /// 两条路径（对应原版的两处调用）：
  ///
  /// 1. **有勾选** → 只下勾中的这些（它们必然是已加载的），逐条入队即可，
  ///    没有翻页动作，所以是同步的、瞬间完成。
  /// 2. **没勾选（默认下载）** → 交给 [CreationTaskStore] 建一个后台任务
  ///    （= 原版 `createCreationTask(user, filter)`），**立刻返回并跳到下载管理**，
  ///    翻页与入队在后台跑。这正是「点一下就能在下载管理里看到任务」的原因。
  Future<void> _start(List<Media> accepted, bool hasSelection) async {
    if (_busy) return;

    final coordinator = Aria2Coordinator.instance;
    final store = context.read<DownloadStore>();
    final hp = context.read<HomepageStore>();
    final creation = context.read<CreationTaskStore>();

    // ── ① 勾选模式：只下选中的，立即入队 ──────────────────────
    if (hasSelection) {
      setState(() => _busy = true);

      final toEnqueue = accepted.where((m) => hp.isSelected(m.id)).toList();
      var queued = 0;
      var skipped = 0;
      var notReady = 0;
      var failed = 0;
      for (final m in toEnqueue) {
        final r = await coordinator.enqueueMedia(m);
        switch (r.outcome) {
          case EnqueueOutcome.queued:
            queued++;
          case EnqueueOutcome.skippedExisting:
            skipped++;
          case EnqueueOutcome.notReady:
            notReady++;
          case EnqueueOutcome.rejected:
          // removeFailed 只出自 retryTask，入队路径不会遇到 —— 一并计入失败。
          case EnqueueOutcome.removeFailed:
            failed++;
        }
      }

      store.setCurrentTab('下载中');
      if (!mounted) return;
      final parts = <String>['已入队 $queued 个'];
      if (skipped > 0) parts.add('跳过 $skipped 个已存在');
      if (notReady > 0) parts.add('$notReady 个因 aria2 未就绪没入队');
      if (failed > 0) parts.add('$failed 个被 aria2 拒绝（见「下载管理 → 失败」）');
      _toast(parts.join('，'));
      widget.onNavigate?.call('download-management');
      setState(() => _busy = false);
      return;
    }

    // ── ② 默认下载：创建后台任务（同原版 createCreationTask）────────
    final task = creation.create(widget.user, hp.filter);
    store.setCurrentTab('下载中');
    _toast(tf('已创建下载任务「{name}」，正在后台读取媒体…',
        {'name': task.displayName}));
    widget.onNavigate?.call('download-management');
  }
}