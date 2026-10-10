import 'package:flutter/foundation.dart';

import '../models/media.dart';

/// B 站页的解析结果仓库。
///
/// **为什么提到 app 级**：导航按路由重建页面，切到「下载管理」再切回来页面会
/// 重新构造；结果存在页面 State 里就等于「看一眼进度就丢掉刚解析的东西」。
///
/// **为什么不照抄 `douyin_store.dart`**：抖音那边是无限滚动的单页应用，要按
/// 「当前是哪个页面」分桶，还得淘汰最久没用的桶。B 站这条路是**粘链接 → 一次
/// 性解析出这个稿件的分 P 列表**，没有滚动、没有多页共存，所以这里只有一份
/// 结果 + 一个「上一次解析的是哪条」的历史，刻意不分桶。
///
/// **职责边界**：只管「有哪些媒体 / 选了哪些」，**不碰下载**。入队由页面调用
/// `Aria2Coordinator`（照抖音的做法）。
class BiliStore extends ChangeNotifier {
  /// 解析出来的媒体，**按 (稿件序号, 分P序号) 稳定排序**。
  final List<Media> items = [];

  /// 勾选集（存 `Media.id`，与抖音侧同一口径）。
  final Set<String> selected = {};

  /// 正在解析（用于禁用按钮与显示进度）。
  bool busy = false;

  /// 上一次解析失败的可读原因（`null` = 没有错误）。
  ///
  /// 刻意留成字符串而不是异常：界面上要原样显示给用户看，而这项目的纪律是
  /// 「用户主动动作的失败不能只进 debugPrint」。
  String? error;

  /// 最近解析过的链接（地址栏的历史提示用）。
  final List<String> recentLinks = [];

  static const int kMaxRecentLinks = 10;

  /// 按稿件（`bvid`）聚合后的视图，顺序 = 首次出现的顺序。
  ///
  /// 界面按稿件分组显示：一个稿件一行标题 + 它下面若干分 P，勾「全选这稿」
  /// 比让用户在一长串 `P01…P12` 里逐个点要省事。
  List<BiliWorkGroup> get groups {
    final out = <String, BiliWorkGroup>{};
    final order = <String>[];
    for (final m in items) {
      final key = m.bili?.bvid ?? m.tweetId ?? m.id;
      final g = out.putIfAbsent(key, () {
        order.add(key);
        return BiliWorkGroup(
          key: key,
          title: m.bili?.workTitle ?? m.tweetText ?? key,
          upName: m.userName ?? '',
        );
      });
      g.parts.add(m);
    }
    return [for (final k in order) out[k]!];
  }

  /// 一组里已勾的数量（给「这稿全选了吗」用）。
  int selectedIn(String groupKey) {
    final g = groups.where((e) => e.key == groupKey);
    if (g.isEmpty) return 0;
    return g.first.parts.where((m) => selected.contains(m.id)).length;
  }

  /// 新解析结果整体替换旧结果（B 站一次只看一个稿件，留着上一批只会让人勾错）。
  void replaceAll(List<Media> next, {String? link}) {
    items
      ..clear()
      ..addAll(next);
    selected
      ..clear()
      ..addAll(next.map((m) => m.id));
    error = null;
    if (link != null && link.isNotEmpty) {
      recentLinks.remove(link);
      recentLinks.insert(0, link);
      if (recentLinks.length > kMaxRecentLinks) {
        recentLinks.removeRange(kMaxRecentLinks, recentLinks.length);
      }
    }
    notifyListeners();
  }

  void clear() {
    items.clear();
    selected.clear();
    error = null;
    notifyListeners();
  }

  void setError(String message) {
    error = message;
    busy = false;
    notifyListeners();
  }

  void setBusy(bool value) {
    busy = value;
    if (value) error = null;
    notifyListeners();
  }

  void toggle(String id, {bool? value}) {
    final on = value ?? !selected.contains(id);
    if (on) {
      selected.add(id);
    } else {
      selected.remove(id);
    }
    notifyListeners();
  }

  /// 整组勾选 / 取消。
  void toggleGroup(String groupKey, {bool? value}) {
    final g = groups.where((e) => e.key == groupKey);
    if (g.isEmpty) return;
    final parts = g.first.parts;
    final allOn = parts.every((m) => selected.contains(m.id));
    final on = value ?? !allOn;
    for (final m in parts) {
      if (on) {
        selected.add(m.id);
      } else {
        selected.remove(m.id);
      }
    }
    notifyListeners();
  }

  void selectAll() {
    selected.addAll(items.map((m) => m.id));
    notifyListeners();
  }

  void selectNone() {
    selected.clear();
    notifyListeners();
  }

  /// 当前勾选的媒体，**保持 [items] 的顺序**。
  List<Media> get chosen =>
      items.where((m) => selected.contains(m.id)).toList(growable: false);
}

/// 一个稿件的聚合视图（只给界面用，不落盘）。
class BiliWorkGroup {
  BiliWorkGroup({
    required this.key,
    required this.title,
    required this.upName,
  });

  final String key;
  final String title;
  final String upName;
  final List<Media> parts = [];
}
