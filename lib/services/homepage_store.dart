import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/download_filter.dart';
import '../models/media.dart';
import '../models/user.dart';
import 'app_logger.dart';
import 'app_state.dart';
import 'x_api.dart';

/// 主页状态机。
///
/// 管理当前搜索用户、媒体列表与加载态。
/// **重要：** 状态需要跨页面共享，所以做成全局单例，这样下载页也能看到当前用户。
/// Flutter 同样在 main 里把 AppState 和 HomepageStore 都作为根级 Provider，
/// 实现跨页面共享。
class HomepageStore extends ChangeNotifier {
  final AppState appState;

  HomepageStore(this.appState);

  String _keyword = '';
  String get keyword => _keyword;

  /// 当前搜索的用户（已加载）。
  TwitterUser? _user;
  TwitterUser? get user => _user;

  /// 媒体列表（已去重）。
  final List<Media> _media = [];
  List<Media> get media => List.unmodifiable(_media);

  /// 是否正在加载用户信息。
  bool _loadingUser = false;
  bool get loadingUser => _loadingUser;

  /// 是否正在加载更多媒体。
  bool _loadingMore = false;
  bool get loadingMore => _loadingMore;

  /// 加载用户时遇到的错误（用于 UI 提示）。
  String? _userError;
  String? get userError => _userError;

  /// 媒体列表分页游标。
  String? _nextCursor;

  /// 是否已经成功拉过至少一页。
  ///
  /// **必须有这个标志**：首次加载时 `_nextCursor` 必然是 null，
  /// 若直接用 `_nextCursor != null` 当「还有更多」的条件，
  /// 就会形成「UI 等 hasMore 才发起首次请求、而首次请求前 hasMore 必为 false」的死锁
  /// —— 表现就是搜到用户后媒体网格永远空白。
  bool _hasLoadedOnce = false;

  /// 已连续翻到几页「0 条媒体」—— X 到底之后每页只回游标，靠这个收工
  /// （见 `mediaPageHasMore`）。换用户 / 清空时归零。
  int _emptyStreak = 0;

  /// 是否还能继续加载（尚未加载过也算「可以加载」）
  bool get hasMore => !_hasLoadedOnce || _nextCursor != null;

  /// 当前正在请求的协程。中途切关键词时取消旧的请求。
  int _requestSeq = 0;

  /// 已勾选的媒体 id 集合。空 = 全选模式。
  final Set<String> _selectedIds = {};
  Set<String> get selectedIds => Set.unmodifiable(_selectedIds);

  bool isSelected(String id) => _selectedIds.contains(id);

  void toggleSelected(String id) {
    if (_selectedIds.contains(id)) {
      _selectedIds.remove(id);
    } else {
      _selectedIds.add(id);
    }
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedIds.isEmpty) return;
    _selectedIds.clear();
    notifyListeners();
  }

  /// 当前过滤后命中的媒体列表（应用 DownloadFilter）
  List<Media> get acceptedMedia =>
      _media.where((m) => _filter.accepts(m)).toList(growable: false);

  /// 下载过滤器（主页 + 自动执行共享）。默认：全部媒体，不限日期。
  DownloadFilter _filter = const DownloadFilter(
    mediaTypes: {MediaType.image, MediaType.video, MediaType.animatedGif},
  );
  DownloadFilter get filter => _filter;

  void setFilter(DownloadFilter v) {
    _filter = v;
    notifyListeners();
  }

  void setKeyword(String v) {
    _keyword = v;
    notifyListeners();
  }

  /// 加载用户信息。会自动清空旧的媒体列表。
  Future<void> loadUser(String screenName) async {
    if (!appState.isLoggedIn) {
      _userError = '请先登录';
      notifyListeners();
      return;
    }

    _keyword = screenName;
    _loadingUser = true;
    _userError = null;
    _user = null;
    _media.clear();
    _nextCursor = null;
    _emptyStreak = 0;
    _hasLoadedOnce = false;
    notifyListeners();

    final seq = ++_requestSeq;
    try {
      final user = await appState.api.getUser(screenName);
      if (seq != _requestSeq) return; // 已被新的请求覆盖
      _user = user;
      // 用户加载成功后立刻拉第一页媒体。
      // 不能只靠 _MediaGrid 的 initState —— 切换用户时组件已挂载、不会重新 initState。
      unawaited(loadMoreMedias());
    } on XApiException catch (e) {
      _userError = _mapUserError(e);
    } catch (e) {
      _userError = friendlyNetworkError(e) ?? '加载失败：$e';
    } finally {
      _loadingUser = false;
      notifyListeners();
    }
  }

  /// 加载下一页媒体（首次调用时 cursor 为 null，即加载第一页）。
  Future<void> loadMoreMedias() async {
    final user = _user;
    if (user == null || user.id == null) return;
    if (_loadingMore) return;
    // 已加载过、且没有下一页游标 → 真的到末尾了
    if (_hasLoadedOnce && _nextCursor == null) return;

    _loadingMore = true;
    notifyListeners();

    final seq = _requestSeq;
    try {
      final page = await appState.api.getUserMedias(
        user.id!,
        cursor: _nextCursor,
      );
      if (seq != _requestSeq) return;

      // 去重
      final seen = _media.map((m) => m.id).toSet();
      for (final m in page.tweets) {
        if (seen.add(m.id)) _media.add(m);
      }
      // 收工条件见 mediaPageHasMore：游标不前进、或连续几页翻不出任何媒体
      // （X 到底之后就是每页只回一个还在变的游标）
      final more = mediaPageHasMore(
        requestedCursor: _nextCursor,
        page: page,
        emptyPagesBefore: _emptyStreak,
      );
      _emptyStreak = page.tweets.isEmpty ? _emptyStreak + 1 : 0;
      _nextCursor = more ? page.nextCursor : null;
      _hasLoadedOnce = true;
    } catch (e) {
      // 不重置游标，用户可重试
      AppLogger.log('HOME', 'loadMoreMedias 失败：$e');
      debugPrint('loadMoreMedias failed: $e');
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  /// 清空当前用户与媒体列表（保留搜索关键词）。
  void clearUser() {
    _user = null;
    _media.clear();
    _nextCursor = null;
    _emptyStreak = 0;
    _hasLoadedOnce = false;
    notifyListeners();
  }

  /// 清空媒体列表（保留用户）。
  void clearMedia() {
    _media.clear();
    _nextCursor = null;
    _emptyStreak = 0;
    _hasLoadedOnce = false;
    notifyListeners();
  }

  String _mapUserError(XApiException e) {
    // 网络层问题（TLS 握手失败 / 不可达 / 超时）优先给出可操作的提示
    final friendly = friendlyNetworkError(e);
    if (friendly != null) return friendly;

    switch (e.statusCode) {
      case 401:
        return '登录已失效，请到「设置 → 账号」重新登录';
      case 403:
        // 403 不一定是 cookie 失效 —— X 对异常请求也有风控
        return '被 X 拒绝访问（403）：登录可能已失效，或请求过于频繁。请重新登录或稍后再试';
      case 404:
        return '找不到该用户';
      case 429:
        return '请求过于频繁，请稍后再试';
      default:
        return '加载失败，请检查用户 ID 是否正确';
    }
  }
}