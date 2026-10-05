import 'package:flutter/foundation.dart';

import '../models/douyin_config.dart';
import '../models/media.dart';
import '../models/media_variant.dart';
import 'douyin_filter.dart';
import 'douyin_groups.dart';
import 'douyin_ledger.dart';
import 'douyin_source.dart';

/// 抖音页的抓取结果仓库。
///
/// **为什么提到 app 级而不是放在页面 State 里：** 导航是「按路由重建页面」，
/// 切到「下载管理」再切回来页面会重新构造；如果抓取结果存在页面 State 里，
/// 用户刚捞到的一批结果就没了（WebView 本身也会重建并回到起始页）。
/// 所以结果、勾选状态、筛选条件、上次访问的网址都放这里，页面只做展示。
///
/// **职责边界**：这里只管「有哪些媒体 / 选了哪些 / 怎么筛」，
/// **不碰下载**。真正入队由页面调用 `Aria2Coordinator`。
class DouyinStore extends ChangeNotifier {
  /// 结果上限。抖音推荐流是无限滚动的，不设上限会一直涨。
  ///
  /// **不再有任何"页面窗口"**：一条作品算不算数，由拦截脚本看页面 DOM 决定
  /// （只认页面真渲染出来的，并给它描黄框），这里收到的就是该留下的。
  /// 曾经按来源类别截成 12/5 条，2026-09-19 真机日志显示那是在猜：
  /// 同一类页面一会儿截到 12、一会儿留到 108。
  static const int kMaxItems = 1000;

  /// 抖音首页（进入页面时的初始地址）
  static const String kHomeUrl = 'https://www.douyin.com/';

  /// 首页那一组的 key
  static const String kHomeKey = 'home';

  /// 结果分组的**页面数上限**（超出时淘汰最久没用过的）
  static const int kMaxPages = 20;

  /// 按页面分组的结果。
  ///
  /// 抖音是单页应用：推荐流、作品页、作者页共用**同一个 WebView**，只是内容
  /// 被换掉了。结果若只存一份，切页之后列表里就是「上一页 + 这一页」的混合物，
  /// 用户根本分不清哪些属于当前页面 —— 所以按页面 key 分桶，
  /// 界面只显示当前页那一桶，其它页留着，可以切回去看。
  /// 首页那一桶一开始就建好 —— 界面一进来就要显示「当前页面：首页」，
  /// 而且用户可能在还没抓到任何东西时就想切回来。
  final Map<String, DouyinPageBucket> _buckets = <String, DouyinPageBucket>{
    kHomeKey: DouyinPageBucket(key: kHomeKey, url: kHomeUrl),
  };
  String _currentKey = kHomeKey;

  /// 分组「最近使用」的单调序号。
  ///
  /// 刻意**不用时间戳**排序：Windows 的 `DateTime.now()` 精度可能只有几毫秒，
  /// 连续切几个页面很容易撞在同一刻度上，那时淘汰谁就变得不确定了。
  int _touchSeq = 0;

  void _touch(DouyinPageBucket b) => b.touchSeq = ++_touchSeq;

  /// 当前页对应的桶（不存在就建）
  DouyinPageBucket get _cur => _buckets.putIfAbsent(
    _currentKey,
    () => DouyinPageBucket(key: _currentKey, url: _lastUrl),
  );

  // 下面这几个代理让「按页面分桶」对既有代码**零侵入**：
  // 原来散落各处的 `_items` / `_selected` / `_ids` / `_dropped`
  // 照样读写，只是它们现在落在**当前页那一桶**上。
  List<Media> get _items => _cur.items;
  Set<String> get _selected => _cur.selected;
  Set<String> get _ids => _cur.ids;
  int get _dropped => _cur.dropped;
  set _dropped(int v) => _cur.dropped = v;

  /// 已下载台账（作品粒度）
  final DouyinLedger ledger = DouyinLedger();

  DouyinFilter _filter = DouyinFilter();

  String _lastUrl = kHomeUrl;

  /// 抓到的媒体（**按页面上从上到下的顺序**，见 [ingest]）。
  List<Media> get items => List.unmodifiable(_items);

  int get count => _items.length;

  /// 筛选 / 搜索条件
  DouyinFilter get filter => _filter;

  /// 把勾选交给筛选 —— 条件变化后调用，**会自动剔除已经看不见的勾选**，
  /// 否则用户筛掉一批之后点下载，会把看不见的条目也一起下走。
  void setFilter(DouyinFilter f) {
    _filter = f;
    _pruneSelection();
    notifyListeners();
  }

  void clearFilter() => setFilter(DouyinFilter());

  /// 通过筛选的媒体（页面网格与「下载全部」用的都是它）。
  List<Media> get visibleItems =>
      applyFilter(_items, _filter, group: _filter.groupByAweme);

  int get visibleCount => visibleItems.length;

  /// 筛选结果计数文案用（「筛选结果: N」）
  bool get hasFilter => !_filter.isEmpty;

  /// 作者 / 标签候选（筛选面板的多选项）
  ({List<String> authors, List<String> tags}) get facets =>
      filterFacets(_items);

  /// 因为超出上限被丢弃的条数
  int get dropped => _dropped;

  /// 因超上限被丢弃过 —— 页面据此提示用户可以清空
  bool get overflowed => _dropped > 0;

  Set<String> get selectedIds => Set.unmodifiable(_selected);

  int get selectedCount => _selected.length;

  /// 上次访问的网址，重新进入页面时恢复
  String get lastUrl => _lastUrl;
  set lastUrl(String v) {
    if (v.isEmpty || v == _lastUrl) return;
    _lastUrl = v;
  }

  /// 当前页面的分组 key（见 [douyinPageKey]）
  String get currentPageKey => _currentKey;

  /// 已经抓过结果的页面（最近的在前）
  List<DouyinPageBucket> get pages {
    final list = _buckets.values.toList()
      ..sort((a, b) => b.touchSeq.compareTo(a.touchSeq));
    return List.unmodifiable(list);
  }

  int get pageCount => _buckets.length;

  /// WebView 地址变化时调用：切到（或新建）该页面的结果分组。
  ///
  /// 这就是「切页后结果要刷新」的入口 —— 换页即刻换桶，
  /// 于是列表里只会是**当前页面**的内容。
  void setCurrentUrl(String url) {
    if (url.trim().isEmpty) return;
    _lastUrl = url;
    final key = douyinPageKey(url);

    if (!_buckets.containsKey(key)) {
      _evictPages(keeping: key);
    }
    final b = _buckets.putIfAbsent(
      key,
      () => DouyinPageBucket(key: key, url: url),
    );
    b.url = url;
    _touch(b);

    if (key != _currentKey) {
      _currentKey = key;
      notifyListeners();
    }
  }

  /// 手动切换到某个已抓过的页面分组
  void selectPage(String key) {
    if (key == _currentKey || !_buckets.containsKey(key)) return;
    _currentKey = key;
    _touch(_cur);
    notifyListeners();
  }

  /// 淘汰最久没用的分组（当前页与 [keeping] 绝不淘汰）
  void _evictPages({required String keeping}) {
    if (_buckets.length < kMaxPages) return;
    final victims =
        _buckets.values
            .where((b) => b.key != keeping && b.key != _currentKey)
            .toList()
          ..sort((a, b) => a.touchSeq.compareTo(b.touchSeq));
    var excess = _buckets.length - kMaxPages + 1;
    for (final v in victims) {
      if (excess <= 0) break;
      _buckets.remove(v.key);
      excess--;
    }
  }

  bool isSelected(String id) => _selected.contains(id);

  /// 这条媒体所属作品是否已下载（台账是**作品粒度**）
  bool isDownloaded(Media m) => ledger.containsMedia(m.tweetId);

  /// 台账变更后强制刷新视图。
  ///
  /// `DouyinLedger` 自己是 `ChangeNotifier`，但 [DouyinStore] 不转发它的
  /// 通知（那个通知只服务于设置页里那个小计数）。网格要重画「已下载」
  /// 角标，就得由调用方显式踢一脚。
  void refreshLedgerView() => notifyListeners();

  /// 勾选/取消勾选一条。
  void toggle(String id) {
    if (!_selected.remove(id)) _selected.add(id);
    notifyListeners();
  }

  /// 全选 / 全不选 —— **只作用于当前可见（筛选后）的条目**。
  void setAllSelected(bool value) {
    if (value) {
      _selected
        ..clear()
        ..addAll(visibleItems.map((m) => m.id));
    } else {
      _selected.clear();
    }
    notifyListeners();
  }

  /// 「选择全部视频」/「选择全部图文」—— 对齐参照实现的两个按钮。
  ///
  /// [video] 为 true 时选中视频（含实况图的配对视频），否则选中图片。
  void selectAllOfType({required bool video}) {
    for (final m in visibleItems) {
      if (video ? m.type.isVideo : m.type.isImage) {
        _selected.add(m.id);
      }
    }
    notifyListeners();
  }

  /// 抓取结果按**作品**折叠后的列表 —— 一行一个作品，图文不把每张图摊开。
  ///
  /// 只影响展示：下载、台账、文件名模板仍然按媒体粒度走（`selectedMedia`）。
  List<DouyinAwemeGroup> get awemeGroups => groupByAweme(visibleItems);

  /// 不受筛选影响的**作品**总数（界面据此说"隐藏了几个作品"）
  int get allAwemeGroupCount => groupByAweme(_items).length;

  /// 整条作品勾选 / 取消（列表是一行一个作品，勾也就按作品勾）
  void toggleGroup(DouyinAwemeGroup g) {
    if (isGroupSelected(g)) {
      for (final m in g.items) {
        _selected.remove(m.id);
      }
    } else {
      for (final m in g.items) {
        _selected.add(m.id);
      }
    }
    notifyListeners();
  }

  /// 一条作品的勾选状态（三态，见 [DouyinSelection]）。
  DouyinSelection groupSelectionOf(DouyinAwemeGroup g) {
    if (g.items.isEmpty) return DouyinSelection.none;
    final hit = g.items.where((m) => _selected.contains(m.id)).length;
    if (hit == 0) return DouyinSelection.none;
    return hit == g.items.length ? DouyinSelection.all : DouyinSelection.some;
  }

  /// 一条作品是否已经整组勾上。
  ///
  /// 注意：**界面画勾选标记时别用这个**，要用 [groupSelectionOf] —— 它只认
  /// 整组全选，部分勾选的组会被画成"没选"，那正是 2026-09-24 那个 bug。
  /// 留着它是给 [toggleGroup] 判断"再点一次是补全还是清空"用的。
  bool isGroupSelected(DouyinAwemeGroup g) =>
      groupSelectionOf(g) == DouyinSelection.all;

  /// 「全选」那个复选框该显示成什么：`null` = 半选（横杠）。
  ///
  /// 原先是 `bool get allSelected`，145/156 的时候它是 false，于是全选框看着
  /// 像没勾 —— 和旁边的「已选 145」自相矛盾。
  bool? get selectionState {
    final vis = visibleItems;
    if (vis.isEmpty) return false;
    final hit = vis.where((m) => _selected.contains(m.id)).length;
    if (hit == 0) return false;
    return hit == vis.length ? true : null;
  }

  /// 这条作品是否已下载 —— 台账本来就是**作品粒度**，直接查即可
  bool isGroupDownloaded(DouyinAwemeGroup g) => ledger.contains(g.awemeId);

  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  bool get allSelected =>
      visibleItems.isNotEmpty &&
      visibleItems.every((m) => _selected.contains(m.id));

  /// 勾选了的媒体，**保持列表顺序**（这样入队顺序与界面一致）。
  List<Media> get selectedMedia =>
      _items.where((m) => _selected.contains(m.id)).toList(growable: false);

  /// 去掉「已被筛掉 / 已不存在」的勾选。
  void _pruneSelection() {
    if (_selected.isEmpty) return;
    final visible = visibleItems.map((m) => m.id).toSet();
    _selected.removeWhere((id) => !visible.contains(id));
  }

  /// 把新解析出来的一批媒体并进仓库。
  ///
  /// 返回真正新增的条数。已存在的 id 直接丢弃 —— 抖音一个页面会反复拉
  /// 同一批数据（推荐流、详情、相关推荐），不去重的话列表会瞬间爆掉。
  ///
  /// **进来的一定是页面真渲染出来的**：判据在拦截脚本里（拿页面上的卡片和
  /// 接口结果对齐，命中的还顺手描了黄框），所以这里只管去重和硬上限，
  /// 不再按页面类型挑数量。
  ///
  /// **顺序约定：追加到尾部，批内保持载荷顺序。** 拦截脚本是按 DOM 文档顺序
  /// 回传的，所以列表天然就是"页面上从上到下"；用户往下滚，新卡片往下接。
  /// 溢出时从**头部**（最早抓到的那批）丢。
  int ingest(List<Media> incoming) {
    if (incoming.isEmpty) return 0;

    var added = 0;
    final fresh = <Media>[];
    for (final m in incoming) {
      if (_ids.add(m.id)) {
        fresh.add(m);
        added++;
      }
    }
    if (added == 0) return 0;

    _items.addAll(fresh);
    // 有内容进来就算「用过这一组」，淘汰时不会先丢它
    _touch(_cur);

    while (_items.length > kMaxItems) {
      final removed = _items.removeAt(0);
      _ids.remove(removed.id);
      _selected.remove(removed.id);
      _dropped++;
    }

    notifyListeners();
    return added;
  }

  /// 清空结果（**不动**已下载台账，也不动已入队的下载任务）。
  void clear() {
    if (_items.isEmpty && _selected.isEmpty) return;
    _items.clear();
    _ids.clear();
    _selected.clear();
    _dropped = 0;
    notifyListeners();
  }

  // ── 下载组装 ────────────────────────────────────────────────

  /// 把「当前选择」组装成**可以直接交给 aria2 的媒体列表**。
  ///
  /// 这一步承担了参照实现「批量下载」弹窗点「开始下载」之后做的全部事情：
  ///
  ///   1. **跳过已下载**（作品粒度台账）→ [DouyinAssembleResult.skippedDownloaded]
  ///   2. **时长范围过滤**（只作用于视频本身时长，图片不受影响 —— 与参照实现一致）
  ///      → [DouyinAssembleResult.skippedDuration]
  ///   3. **按设置解析下载源**（6 源 + 4 档评分 + 图片格式重排）
  ///   4. **附带 BGM**（仅图文作品，按地址在整批内去重）
  ///   5. **按作品聚合排序**（同一作品的条目连续）
  DouyinAssembleResult buildDownloadList(DouyinConfig cfg) {
    final source = selectedCount > 0 ? selectedMedia : visibleItems;
    return assemble(source, cfg, isDownloaded: isDownloaded);
  }

  /// [buildDownloadList] 的**纯函数版** —— 给定一批媒体 + 「是否已下载」的判据，
  /// 产出可直接交给 aria2 的列表。
  ///
  /// 「自动下载」也走这里：那边每个目标收集到的媒体不属于本 store，但用户设置
  /// （下载源 / 时长范围 / 附带 BGM / 按作品聚合）必须与手动下载**同一套规则**，
  /// 否则两个入口下出来的文件会不一样。
  static DouyinAssembleResult assemble(
    Iterable<Media> source,
    DouyinConfig cfg, {
    required bool Function(Media) isDownloaded,
  }) {
    final list = source.toList(growable: false);
    if (list.isEmpty) return DouyinAssembleResult.empty;

    var skippedDownloaded = 0;
    var skippedDuration = 0;

    final kept = <Media>[];
    for (final m in list) {
      if (cfg.skipDownloaded && isDownloaded(m)) {
        skippedDownloaded++;
        continue;
      }
      // 时长范围只筛视频 —— 参照实现的判据写在视频分支里，图片不受影响。
      // 副作用：实况图的配对视频也会被时长筛掉（它没有独立时长）。
      if (cfg.timeRangeEnabled && m.type.isVideo) {
        final sec = (m.durationMs ?? 0) / 1000.0;
        if (sec <= 0 || sec < cfg.timeStartSec || sec > cfg.timeEndSec) {
          skippedDuration++;
          continue;
        }
      }
      kept.add(m);
    }

    if (cfg.groupByAweme) {
      kept.sort(_byAwemeOrder(kept));
    }

    final resolved = <Media>[];
    for (final m in kept) {
      final r = resolveDouyinMedia(m, cfg);
      // 解析后没有可用地址的条目直接丢掉（否则会产出必然失败的任务）
      if (r.downloadUrl.isEmpty && r.altUrls.isEmpty) continue;
      resolved.add(_withCustomText(r, cfg.customText));
    }

    final withBgm = <Media>[...resolved];
    if (cfg.includeBgm) {
      final seen = <String>{};
      // 按作品取一次 BGM：只在**图文作品**上追加（对齐参照实现），
      // 并按首个地址在整批内去重
      final imagePosts = <String>{};
      for (final m in resolved) {
        if (m.type.isImage && m.tweetId != null) imagePosts.add(m.tweetId!);
      }
      for (final tweetId in imagePosts) {
        final anchor = resolved.firstWhere(
          (m) => m.tweetId == tweetId && m.type.isImage,
          orElse: () => resolved.first,
        );
        final audio = _audioVariantOf(anchor);
        if (audio == null) continue;
        final key = audio.urls.first;
        if (!seen.add(key)) continue;
        withBgm.add(_buildBgmMedia(anchor, audio, cfg.customText));
      }
    }

    return DouyinAssembleResult(
      items: withBgm,
      skippedDownloaded: skippedDownloaded,
      skippedDuration: skippedDuration,
    );
  }

  /// `%CUSTOM_TEXT%` 是「下载时按当前设置解析」出来的，不是媒体自带属性，
  /// 所以在这里（而不是解析器里）写进去 —— 与 `chosen` 同一时机。
  static Media _withCustomText(Media m, String text) =>
      text.isEmpty ? m : m.copyWith(customText: text);

  /// 同一作品排在一起，作品之间的相对顺序不变。
  static int Function(Media, Media) _byAwemeOrder(List<Media> list) {
    final order = <String, int>{};
    for (final m in list) {
      order.putIfAbsent(m.tweetId ?? m.id, () => order.length);
    }
    final index = <String, int>{};
    for (var i = 0; i < list.length; i++) {
      index[list[i].id] = i;
    }
    return (a, b) {
      final oa = order[a.tweetId ?? a.id] ?? 0;
      final ob = order[b.tweetId ?? b.id] ?? 0;
      if (oa != ob) return oa.compareTo(ob);
      return (index[a.id] ?? 0).compareTo(index[b.id] ?? 0);
    };
  }

  static MediaVariant? _audioVariantOf(Media m) {
    for (final v in m.variants) {
      if (v.kind == VariantKind.audio && v.usable) return v;
    }
    return null;
  }

  /// 由 BGM 变体派生一条可下载的音频媒体（复用原作品的全部元数据）。
  static Media _buildBgmMedia(
    Media anchor,
    MediaVariant audio,
    String customText,
  ) {
    return Media(
      id: '${anchor.tweetId ?? anchor.id}_bgm',
      type: MediaType.audio,
      url: audio.urls.first,
      altUrls: audio.urls.length > 1 ? audio.urls.sublist(1) : const [],
      variants: [audio],
      chosen: audio,
      tweetId: anchor.tweetId,
      tweetText: anchor.tweetText,
      createdAt: anchor.createdAt,
      userId: anchor.userId,
      userName: anchor.userName,
      userScreenName: anchor.userScreenName,
      tags: anchor.tags,
      // 序号排在图片之后，避免与图片/视频抢同一个 `%MEDIA_INDEX%`
      mediaIndex: anchor.mediaIndex + 900,
      source: 'douyin',
      durationMs: anchor.durationMs,
      likeCount: anchor.likeCount,
      commentCount: anchor.commentCount,
      collectCount: anchor.collectCount,
      shareCount: anchor.shareCount,
      collectionEpisode: anchor.collectionEpisode,
      customText: customText.isEmpty ? null : customText,
    );
  }
}

/// 把用户输入补全成可导航的网址；**认不出来就返回 null**。
///
/// 三种贴法都认：
///   1. 完整链接 `https://www.douyin.com/video/7592...`；
///   2. `v.douyin.com/xxxx/` 短链（WebView 自己会跟 302）；
///   3. 一串纯数字的作品 ID。
///
/// 另外会从**分享口令**里把链接抠出来 —— 抖音复制出来的分享文本长这样：
///   `7.32 复制打开抖音，看看【某某的作品】 https://v.douyin.com/xxxx/`
/// 用户直接把整段粘进来是常事，不该要求他自己删前缀。
///
/// [DouyinPage] 的地址栏与「自动下载」的目标解析**共用这一个函数**，
/// 免得两处对「什么算合法输入」的判断慢慢跑偏。
String? normalizeDouyinUrl(String raw) {
  var t = raw.trim();
  if (t.isEmpty) return null;

  if (RegExp(r'^\d{15,25}$').hasMatch(t)) {
    return 'https://www.douyin.com/video/$t';
  }

  // 分享口令：把链接片段抠出来（中文标点当边界，别把句号粘进地址）
  final m = RegExp(r'https?://[^\s，,。、；;：:）)】\]}]+').firstMatch(t);
  if (m != null) return m.group(0);

  // 剩下的只接受「长得像域名」的：必须有点号 + 顶级域，且不能夹中文/空格。
  //
  // 这一步是**保守**的：自动下载的目标框里用户可能粘进各种说明文字，
  // 一律兜底成 `https://<原文>` 只会产出一堆必然失败的导航。
  if (!RegExp(r'^[A-Za-z0-9.-]+\.[A-Za-z]{2,}(:\d+)?([/?#].*)?$').hasMatch(t)) {
    return null;
  }
  return 'https://$t';
}

/// 组装结果：可下载列表 + 两类跳过计数（用于「开始下载（跳过 N 个已下载项目）」文案）。
class DouyinAssembleResult {
  final List<Media> items;
  final int skippedDownloaded;
  final int skippedDuration;

  const DouyinAssembleResult({
    required this.items,
    this.skippedDownloaded = 0,
    this.skippedDuration = 0,
  });

  static const empty = DouyinAssembleResult(items: <Media>[]);

  /// 这批涉及的作品 id（下载完成后写台账用）
  Set<String> get awemeIds => {
    for (final m in items)
      if (m.tweetId != null && m.tweetId!.isNotEmpty) m.tweetId!,
  };
}

/// 一个页面（URL 归一化后的分组）的抓取结果。
class DouyinPageBucket {
  DouyinPageBucket({required this.key, required this.url});

  /// 归一化后的页面 key（见 [douyinPageKey]）
  final String key;

  /// 最近一次见到的原始 URL（展示 / 回访用）
  String url;

  /// 「最近使用」的单调序号（越大越新）。淘汰时丢序号最小的那组。
  /// 用序号而不是时间戳：连续切页时时间戳可能撞在同一毫秒，淘汰谁就随机了。
  int touchSeq = 0;

  final List<Media> items = [];
  final Set<String> ids = {};
  final Set<String> selected = {};

  int dropped = 0;

  int get count => items.length;
  int get selectedCount => selected.length;

  /// 界面上的短标签
  String get label {
    if (key == DouyinStore.kHomeKey) return '首页';
    if (key.startsWith('video:')) return '作品 ${key.substring(6)}';
    if (key.startsWith('user:')) return '作者 ${key.substring(5)}';
    return kDouyinPageNames[key] ?? key;
  }
}

/// 常见页面的中文名（认不出来就照原样显示路径段，不硬编造）
const Map<String, String> kDouyinPageNames = {
  'jingxuan': '精选',
  'discover': '推荐',
  'recommend': '推荐',
  'following': '关注',
  'friend': '朋友',
  'search': '搜索',
  'message': '消息',
  'collection': '收藏',
  'like': '喜欢',
  'mine': '我的',
};

/// 把 WebView 的 URL 归一成「页面分组 key」。
///
/// 抖音是单页应用，URL 上挂着一堆追踪参数（`?from=...`），同一个页面还有好几种
/// 写法；不归一的话，每点一下视频就会多出一组。
///   - 空 / 根路径         → `home`
///   - `/video/<id>`       → `video:<id>`
///   - `/note/<id>`（图文）→ `video:<id>`（与视频作品归为同一类）
///   - `/user/<sec_uid>`   → `user:<sec_uid>`
///   - 其它                → 去掉 query / hash 后的一级路径
String douyinPageKey(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return DouyinStore.kHomeKey;

  Uri uri;
  try {
    uri = Uri.parse(raw);
  } catch (_) {
    return DouyinStore.kHomeKey;
  }

  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return DouyinStore.kHomeKey;

  if (segs.length >= 2) {
    final head = segs.first;
    if (head == 'video' || head == 'note') return 'video:${segs[1]}';
    if (head == 'user') return 'user:${segs[1]}';
  }
  return segs.first;
}
