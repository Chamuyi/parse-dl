import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../l10n/l10n.dart';
import '../models/bili_config.dart';
import '../services/aria2_coordinator.dart';
import '../services/app_logger.dart';
import '../services/bili_api.dart';
import '../services/bili_batch_runner.dart';
import '../services/bili_batch_store.dart';
import '../services/bili_ledger.dart';
import '../services/bili_list_api.dart';
import '../services/bili_link.dart';
import '../services/bili_web.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/bili_download_options_dialog.dart';
import 'bili_page.dart' show kBiliHomeUrl;

/// 「B 站批量下载」页：一次贴多条主页 / 合集 / 系列 / 收藏夹，逐条翻到尽并投队列。
///
/// **左边那个 WebView 不是给用户逛的**，虽然它确实能逛。它在的这一页里只有一个
/// 用途：`x/space/wbi/arc/search` 匿名直连实测回 HTTP 412，而「列出我自己的自建
/// 收藏夹」要登录态 —— 这两支都得让**页面自己**去发 `fetch`（见 [BiliInPage]）。
/// 我们因此不需要碰 cookie，也就不用担心它被抄进任何文件或日志。
/// 其余四支列表接口匿名可通，走 [BiliApi] 的纯 HTTP 那条路。
///
/// 下载阶段与解析页**同一条管线**（[biliDownloadParts]）：容器、限速、附加文件、
/// 台账红线都从那份配置走，所以这一页没有第二套「B 站怎么下载」的口径。
/// 弹窗在这条路上只出现一次（点「开始批量」那一瞬），选出来的配置对**整批**生效。
class BiliBatchPage extends StatefulWidget {
  const BiliBatchPage({super.key, this.onNavigate});

  final void Function(String routeId)? onNavigate;

  @override
  State<BiliBatchPage> createState() => _BiliBatchPageState();
}

class _BiliBatchPageState extends State<BiliBatchPage> {
  WebviewController? _web;
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _wvReady = false;
  String? _wvError;
  bool _loading = false;

  BiliApi? _api;
  BiliListApi? _listApi;
  BiliLoginState? _login;
  bool _loginProbed = false;
  bool _foldersLoading = false;

  /// 目标文本框自己攴着的 controller：store 里那份是**已经解析过**的目标，
  /// 而用户敲到一半的字符不该每次都重新解析一遍。
  final TextEditingController _text = TextEditingController();

  /// 跑批的重入闸门。与 `store.running` 的分工同解析页：那个是给界面显示的，
  /// 这个才是防连点两次「开始批量」的。
  bool _working = false;

  @override
  void initState() {
    super.initState();
    final api = BiliApi(cookie: null);
    _api = api;
    // 默认先挂纯 HTTP 那条口；WebView 就绪后 _attachInPage 会把签名口换成页内 fetch。
    _listApi = BiliListApi(api: api);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 切回来时把 store 里那份目标文本补回框子（store 比页面活得久）
      final saved = context.read<BiliBatchStore>().rawText;
      if (saved.isNotEmpty && _text.text.isEmpty) _text.text = saved;
      unawaited(_initWebView());
    });
  }

  @override
  void dispose() {
    _text.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    try {
      _web?.dispose();
    } catch (_) {
      // 原生侧可能已经随窗口销毁，忽略
    }
    super.dispose();
  }

  // ── WebView ────────────────────────────────────────────────

  Future<void> _initWebView() async {
    if (!mounted) return;
    try {
      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        setState(() => _wvError = t('未检测到 Edge WebView2 运行时。\n'
            '这一页的「UP 主主页投稿」与「我的自建收藏夹」要用到它；'
            '合集 / 系列 / 贴收藏夹 id 这几支仍然可以用纯接口那条路。'));
        return;
      }
      final ctrl = WebviewController();
      _web = ctrl;
      await ctrl.initialize();
      await ctrl.setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
      try {
        await ctrl.setUserAgent(kBiliUserAgent);
      } catch (_) {
        // 设不上 UA 不影响使用
      }
      _subs.add(ctrl.loadingState.listen((s) {
        if (!mounted) return;
        final loading = s == LoadingState.loading;
        setState(() => _loading = loading);
        if (!loading && !_loginProbed) {
          _loginProbed = true;
          unawaited(_checkLogin());
          unawaited(_attachInPage());
        }
      }));
      await ctrl.loadUrl(kBiliHomeUrl);
      if (mounted) setState(() => _wvReady = true);
    } catch (e) {
      AppLogger.log('BILI', '批量页 WebView 初始化失败：$e');
      if (mounted) setState(() => _wvError = '$e');
    }
  }

  /// 把列表层的**签名口**换成页内 fetch。
  ///
  /// 只换签名那一个：另外四支匿名就能通，换过去反而多一层「WebView 没就绪」的
  /// 失败面。换口的动作在 [BiliListApi] 那边是构造参数，所以这里重建一个实例，
  /// 不试图热改已经发出去的请求。
  Future<void> _attachInPage() async {
    final ctrl = _web;
    final api = _api;
    if (ctrl == null || api == null || !mounted) return;
    try {
      _listApi = BiliListApi(
        api: api,
        signed: (path, params) async {
          final url = await api.signedPageUrl(path, params);
          return BiliInPage.get(ctrl, url);
        },
        plain: (path, params) async {
          final url = api.plainPageUrl(path, params);
          return BiliInPage.get(ctrl, url);
        },
      );
    } catch (e) {
      AppLogger.log('BILI', '批量页页内取数口接线失败，继续用纯接口：$e');
    }
  }

  Future<void> _checkLogin() async {
    final ctrl = _web;
    if (ctrl == null) return;
    final s = await BiliInPage.loginState(ctrl);
    if (mounted) setState(() => _login = s);
  }

  // ── 跑批 ───────────────────────────────────────────────────

  /// 点「开始批量」：弹窗（一次）→ 逐目标跑。
  Future<void> _start() async {
    final store = context.read<BiliBatchStore>();
    final api = _api;
    final listApi = _listApi;
    if (api == null || listApi == null) return;
    if (_working) return;
    if (!store.hasTargets) {
      AppToast.show(context, t('先粘至少一条主页 / 合集 / 系列 / 收藏夹链接'),
          kind: AppToastKind.info);
      return;
    }
    final coordinator = Aria2Coordinator.instance;
    if (!coordinator.booted) {
      AppToast.show(
        context,
        t('下载引擎还没起来（aria2 未就绪），请稍后重试或查看日志'),
        kind: AppToastKind.error,
      );
      return;
    }

    var cfg = context.read<SettingsStore>().settings.bili;
    final r = await showBiliDownloadOptions(context, cfg);
    if (!mounted) return;
    if (r.action == BiliOptionsAction.cancel) return;
    cfg = r.config ?? cfg;
    if (r.action == BiliOptionsAction.confirmAndSync) {
      final picked = cfg;
      await context.read<SettingsStore>().setBili((b) => b.applyFrom(picked));
      if (!mounted) return;
    }

    setState(() => _working = true);
    store.start();
    final ledger = context.read<BiliLedger>();
    try {
      while (store.running) {
        final target = store.current;
        if (target == null) break;
        await _runTarget(target, api, listApi, cfg, ledger, store, coordinator);
        store.advance();
      }
    } finally {
      store.finish();
      if (mounted) setState(() => _working = false);
    }
    if (!mounted) return;
    AppToast.show(
      context,
      tf(
        '批量结束：目标 {n} 个，认出稿件 {m} 条，提交 {q} 条下载',
        {
          'n': store.total,
          'm': store.totalCollected,
          'q': store.totalQueued,
        },
      ),
      kind: store.failedCount > 0 ? AppToastKind.error : AppToastKind.success,
      duration: const Duration(seconds: 5),
      actionLabel: widget.onNavigate == null ? null : t('去下载管理'),
      // 与解析页同一条纪律：必须落在**本模块的**下载管理上。
      onAction: widget.onNavigate == null
          ? null
          : () => widget.onNavigate!('bili-downloads'),
    );
  }

  /// 一个目标：判身份 → 翻列表 → 逐条稿件展开分 P → 投队列。
  ///
  /// 抛出来的异常由调用侧那一格统一落成「这一行失败 + 一句原因」，
  /// 不在这里吞 —— 吞掉的话用户只看到一行没动过的目标，不知道为什么。
  Future<void> _runTarget(
    BiliBatchTarget target,
    BiliApi api,
    BiliListApi listApi,
    BiliConfig cfg,
    BiliLedger ledger,
    BiliBatchStore store,
    Aria2Coordinator coordinator,
  ) async {
    var ref = target.ref;
    if (ref.needsExpand) {
      store.mark(target, BiliBatchStatus.expanding);
      final expanded = await expandBiliShortLink(ref.shortLink!);
      if (expanded == null) {
        throw StateError(t('短链没能展开（没有重定向、页面里也找不到 BV 号）'));
      }
      ref = expanded;
      target.ref = ref;
      if (ref.isUnsupported) throw StateError(ref.unsupportedReason!);
    }

    store.mark(target, BiliBatchStatus.listing);
    final works = <String, String>{}; // bvid → 标题（列表给的，可能为空）
    final list = ref.list;
    if (list == null) {
      // 单条稿件那一行：不翻列表，直接把这条展开
      final view = await api.view(bvid: ref.bvid, aid: ref.aid?.toString());
      target.title = view.title;
      works[view.bvid] = view.title;
    } else {
      final judged = list.kind == BiliListKind.unknown
          ? await listApi.resolveTarget(list)
          : list;
      target.target = judged;
      final summary = await listApi.allArcsSummary(judged);
      target.archives = summary.items;
      target.skippedUnsupported = summary.skipped;
      target.title = summary.listTitle;
      var take = summary.items;
      final cap = store.maxWorks;
      if (cap > 0 && take.length > cap) {
        target.truncated = take.length - cap;
        take = take.sublist(0, cap);
      }
      for (final a in take) {
        if (a.bvid.isEmpty) continue;
        works[a.bvid] = a.title;
      }
    }
    target.collected = works.length;
    store.refresh();
    if (works.isEmpty) {
      throw StateError(t('这个列表里一条本期能下的稿件都没有'));
    }

    final tally = BiliRunTally();
    target.run = tally;
    store.mark(target, BiliBatchStatus.downloading);
    for (final bvid in works.keys) {
      if (!store.running) break;
      try {
        final view = await api.view(bvid: bvid);
        final all = biliPartsOfView(view);
        if (all.isEmpty) {
          tally.failed++;
          tally.addNote(tf('{bvid} 没有可下载的分 P', {'bvid': bvid}));
          continue;
        }
        // 「多 P 只取第 1P」是**默认**：一个 20P 的合集勾上全取就是几百条队列，
        // 而想要全部的人本来也可以在解析页里按稿件勾。
        final parts = store.allParts ? all : [all.first];
        tally.absorb(await biliDownloadParts(
          api: api,
          cfg: cfg,
          parts: parts,
          ledger: ledger,
          coordinator: coordinator,
          cancel: () => !store.running,
        ));
      } catch (e) {
        tally.failed++;
        tally.addNote('$e');
        AppLogger.log('BILI', '批量里这条稿件没跑通（$bvid）：$e');
      }
      store.refresh();
    }
    store.mark(target, BiliBatchStatus.done);
  }

  // ── 收藏夹下拉（D8 的后半）──────────────────────────────────

  /// 列出我自己建的收藏夹。**要登录态**：匿名实测 `code=0` 而 `data=null`，
  /// 所以拿不到时说的是「拿不到列表」，不是「你没有收藏夹」。
  Future<void> _loadFavFolders() async {
    final store = context.read<BiliBatchStore>();
    final listApi = _listApi;
    final login = _login;
    if (listApi == null || _foldersLoading) return;
    final mid = int.tryParse(login?.mid ?? '');
    if (login == null || !login.isLoggedIn || mid == null) {
      store.setFavFolders(
        const [],
        note: t('还没登录，拿不到自建收藏夹列表 —— 把收藏夹链接或那串 id 粘进来一样能下'),
      );
      return;
    }
    setState(() => _foldersLoading = true);
    try {
      final r = await listApi.createdFolders(upMid: mid);
      store.setFavFolders(r.items);
    } catch (e) {
      AppLogger.log('BILI', '自建收藏夹列表取失败：$e');
      store.setFavFolders(
        const [],
        note: t('列表没取回来（登录态过期或被风控）—— 贴收藏夹链接或 id 一样能下'),
      );
    } finally {
      if (mounted) setState(() => _foldersLoading = false);
    }
  }

  // ── 界面 ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final store = context.watch<BiliBatchStore>();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 3,
          child: _browser(c),
        ),
        Container(
          width: 1.2,
          margin: const EdgeInsets.symmetric(vertical: 10),
          color: c.line,
        ),
        SizedBox(
          width: 400,
          child: _panel(c, store),
        ),
      ],
    );
  }

  Widget _browser(AppColors c) {
    if (_wvError != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(_wvError!, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
      );
    }
    if (!_wvReady) {
      return Center(
        child: Text(
          _loading ? t('页面加载中…') : t('正在准备内嵌页面…'),
          style: TextStyle(fontSize: 12.5, color: c.textMuted),
        ),
      );
    }
    return Webview(_web!);
  }

  Widget _panel(AppColors c, BiliBatchStore store) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      children: [
        _hint(
          c,
          t('一行一个目标：UP 主主页、合集 / 系列链接、收藏夹链接或那串 id、'
              '单条稿件链接或 BV 号都认。'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _text,
          maxLines: 6,
          enabled: !store.running,
          style: TextStyle(fontSize: 12.5, color: c.textStrong),
          decoration: InputDecoration(
            hintText: t('把链接一行一条粘进来'),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: store.setRawText,
        ),
        const SizedBox(height: 6),
        _targetsSummary(c, store),
        const SizedBox(height: 12),
        _favFolderRow(c, store),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _labeledDropdown<int>(
                c,
                t('每个列表最多下几条'),
                store.maxWorks,
                [
                  for (final v in BiliBatchStore.kMaxWorksChoices)
                    DropdownMenuItem(
                      value: v,
                      child: Text(v == 0 ? t('不限') : '$v'),
                    ),
                ],
                store.setMaxWorks,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            t('多 P 稿件取全部 P'),
            style: TextStyle(fontSize: 13, color: c.textStrong),
          ),
          subtitle: Text(
            t('默认只取第 1P：一个 20P 的合集全取就是几百条队列。'),
            style: TextStyle(fontSize: 11.5, color: c.textMuted),
          ),
          value: store.allParts,
          activeThumbColor: c.accent,
          onChanged: store.running ? null : store.setAllParts,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton(
              onPressed: store.running || !store.hasTargets ? null : _start,
              child: Text(t('开始批量')),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: store.running ? () => store.stop() : null,
              child: Text(t('停止')),
            ),
          ],
        ),
        if (store.running || store.allSettled) ...[
          const SizedBox(height: 8),
          _progress(c, store),
        ],
        const SizedBox(height: 14),
        for (var i = 0; i < store.targets.length; i++)
          _targetRow(c, store.targets[i], i == store.currentIndex),
        if (store.rejected.isNotEmpty) ...[
          const SizedBox(height: 10),
          _hint(
            c,
            tf(
              '这几行认不出来，已经跳过：{lines}',
              {'lines': store.rejected.take(3).join(' / ')},
            ),
          ),
        ],
      ],
    );
  }

  Widget _targetsSummary(AppColors c, BiliBatchStore store) {
    final bits = <String>[
      tf('识别到 {n} 个目标', {'n': store.total}),
      if (store.rejected.isNotEmpty)
        tf('{n} 行认不出来', {'n': store.rejected.length}),
      if (store.truncated > 0) tf('{n} 行超出上限', {'n': store.truncated}),
    ];
    return Text(
      bits.join('，'),
      style: TextStyle(fontSize: 11.5, color: c.textMuted),
    );
  }

  Widget _favFolderRow(AppColors c, BiliBatchStore store) {
    final folders = store.favFolders;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: folders.isEmpty
                  ? _placeholder(c, store.favFoldersNote)
                  : _folderPicker(c, store, folders),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _foldersLoading ? null : _loadFavFolders,
              child: Text(_foldersLoading
                  ? t('取列表中…')
                  : t('列出我的自建收藏夹')),
            ),
          ],
        ),
        if (store.favFoldersNote.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            store.favFoldersNote,
            style: TextStyle(fontSize: 11.5, color: c.textMuted),
          ),
        ],
      ],
    );
  }

  Widget _placeholder(AppColors c, String note) => Text(
        note.isEmpty ? t('下拉里是「我建的」收藏夹；别人的收藏夹请贴链接') : note,
        style: TextStyle(fontSize: 11.5, color: c.textMuted),
      );

  Widget _folderPicker(
    AppColors c,
    BiliBatchStore store,
    List<BiliFavFolder> folders,
  ) {
    return DropdownButton<int>(
      isExpanded: true,
      value: null,
      hint: Text(
        t('选一个自建收藏夹加进目标'),
        style: TextStyle(fontSize: 12, color: c.textMuted),
      ),
      items: [
        for (final f in folders)
          DropdownMenuItem(
            value: f.mediaId,
            child: Text(
              '${f.title}（${f.mediaCount}）',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.textStrong),
            ),
          ),
      ],
      onChanged: (id) {
        if (id == null) return;
        final folder = folders.firstWhere((f) => f.mediaId == id);
        final added = store.addFavFolderTarget(folder);
        AppToast.show(
          context,
          added
              ? tf('已把「{name}」加进目标', {'name': folder.title})
              : tf('「{name}」已经在目标里了', {'name': folder.title}),
          kind: AppToastKind.info,
        );
      },
    );
  }

  Widget _progress(AppColors c, BiliBatchStore store) => Text(
        tf(
          '目标 {done}/{total}　认出 {m} 条　提交 {q} 条　跳过不支持 {u} 条',
          {
            'done': store.settledCount,
            'total': store.total,
            'm': store.totalCollected,
            'q': store.totalQueued,
            'u': store.totalUnsupported,
          },
        ),
        style: TextStyle(fontSize: 12, color: c.textStrong),
      );

  Widget _targetRow(AppColors c, BiliBatchTarget t, bool current) {
    final run = t.run;
    final bits = <String>[
      if (t.collected > 0) tf('稿件 {n} 条', {'n': t.collected}),
      if (run != null && run.queued > 0) tf('提交 {n}', {'n': run.queued}),
      if (run != null && run.skippedLedger > 0)
        tf('已下过 {n}', {'n': run.skippedLedger}),
      if (run != null && run.failed > 0) tf('失败 {n}', {'n': run.failed}),
      if (t.skippedUnsupported > 0)
        tf('不支持 {n}', {'n': t.skippedUnsupported}),
      if (t.truncated > 0) tf('截掉 {n}', {'n': t.truncated}),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: current ? c.surfaceSunken : Colors.transparent,
        border: Border.all(color: c.line, width: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _statusText(t.status),
                style: TextStyle(
                  fontSize: 11.5,
                  color: t.status == BiliBatchStatus.failed
                      ? c.danger
                      : c.textMuted,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.title.isEmpty ? t.input : t.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: c.textStrong),
                ),
              ),
            ],
          ),
          if (bits.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(bits.join('　·　'),
                style: TextStyle(fontSize: 11, color: c.textMuted)),
          ],
          if (t.error != null) ...[
            const SizedBox(height: 3),
            Text(t.error!, style: TextStyle(fontSize: 11, color: c.danger)),
          ],
        ],
      ),
    );
  }

  String _statusText(BiliBatchStatus s) => switch (s) {
        BiliBatchStatus.waiting => t('等待'),
        BiliBatchStatus.expanding => t('展开短链'),
        BiliBatchStatus.listing => t('取列表'),
        BiliBatchStatus.downloading => t('入队中'),
        BiliBatchStatus.done => t('完成'),
        BiliBatchStatus.failed => t('失败'),
      };

  Widget _hint(AppColors c, String text) => Text(
        text,
        style: TextStyle(fontSize: 11.5, color: c.textMuted, height: 1.5),
      );

  Widget _labeledDropdown<T>(
    AppColors c,
    String label,
    T value,
    List<DropdownMenuItem<T>> items,
    void Function(T) onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11.5, color: c.textMuted)),
        const SizedBox(height: 4),
        DropdownButton<T>(
          isExpanded: true,
          value: value,
          items: items,
          // 跑批中不许改档位：改到一半会让「这一批按哪份设置投」说不清。
          onChanged: context.read<BiliBatchStore>().running
              ? null
              : (v) {
                  if (v != null) onChanged(v);
                },
        ),
      ],
    );
  }
}
