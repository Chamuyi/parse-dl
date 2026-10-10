/// 下载管理页的「空态提示」与「B 站已下载历史」两块视图。
///
/// **为什么要从 `download_management_page.dart` 里搬出来**：
///   1. B 站的文案得能**按文件**扫术语（照 `test/module_boundary_test.dart` 的口径：
///      模块独占文件的字符串字面量里不许出现别的平台的说法）。B 站历史若继续留在
///      页面里就没法界定「这几行字是谁的」—— 同一个文件里合法地写着
///      「已下载（抖音）」，整份扫必然误报，只扫行号区间又跟不上代码增删。
///   2. 空态提示原来是页面的私有类，跨不了库；搬成公开类之后历史分区才能复用
///      同一份视觉规格，而不是抄一遍像素。
///
/// **这里不放抖音的历史**：那份是作品粒度（`DouyinStore.ledger`），和本文件的
/// 分 P 粒度台账没有共用代码的余地（键、字段、可做的操作都不一样），留在页面里。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/bili_ledger.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';

/// B 站模块独有的那个历史 Tab 名（**分 P 粒度**的下载历史，
/// 数据就是「跳过已下载」用的那份台账）。
///
/// Tab 名与抖音那份同格式，但**不共用常量**：这个名字本身带着平台术语，
/// 共用一个常量就等于让两个模块说同一句话，术语扫描也就没得扫了。
const String kBiliHistoryTab = '已下载（B 站）';

/// Tab 内容列表为空时的提示：图标 + 标题 + 说明。
///
/// [title] 不给就用「「`<Tab 名>`」里还没有任务」——带括号的 Tab 名直接套模板
/// 会写成「下载中 里还没有任务」，那个空格是模板带的，读起来像漏字。
class DownloadEmptyHint extends StatelessWidget {
  final String name;

  /// 空态标题（默认「`<名字>` 里还没有任务」；带括号的 Tab 名这么套不通顺，可覆盖）
  final String? title;

  /// 空态说明 —— 必须显式给：三个模块的入口页名不同，写死默认值会串到别的模块
  final String hint;

  const DownloadEmptyHint({
    super.key,
    required this.name,
    required this.hint,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_download_outlined, size: 56, color: c.textFaint),
          const SizedBox(height: 14),
          Text(
            // Tab 名直接拼会写成「下载中 里还没有任务」——那个空格是模板带的，
            // 读起来像漏字。用「」把 Tab 名框住。
            // 走 `tf` 而不是插值整串：整串拼好再查表永远查不中（Tab 名每次不一样）。
            title ?? tf('「{name}」里还没有任务', {'name': name}),
            style: TextStyle(fontSize: 14, color: c.textMuted),
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: c.textFaint, height: 1.6),
          ),
        ],
      ),
    );
  }
}

/// B 站下载历史（**分 P 粒度**）。
///
/// 数据就是「跳过已下载」用的那份台账（`bili_downloaded.json`）。
/// 所以在这里删掉一条，下次批量下载就会重新下它 —— 这也是它放在「下载管理」
/// 而不是 B 站页里的原因：它管的是「下过什么」。
///
/// ## 为什么行里没有「打开文件夹」
/// 台账记的是**内容标识**（`bvid` + `cid`）与展示用的标题 / UP 主 / 时间，
/// **没有落盘路径**：文件名与目录是下载时按用户模板算出来的，模板随时会被改，
/// 事后拿标题去反推目录只会推出一个「看着像」的错地方，点了没反应或打开隔壁
/// 稿件的文件夹都比不显示更难查。抖音那份历史同理，也只有「移除」。
/// 真要做「打开文件夹」，得先让台账把当次用的目录一起记下来
/// （改 `bili_ledger.dart` 的记录字段与落盘格式，不在这一期）。
class BiliHistorySection extends StatelessWidget {
  const BiliHistorySection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    // 台账由 app 级 provider 提供。集成方如果把 ledger 挂到 BiliStore 上
    // （照 DouyinStore.ledger 的做法），这一行换成 `context.watch<BiliStore>().ledger`
    // 就行，下面的视图代码不用动。
    // 这里**故意不用可空查询**：没接线就抛 ProviderNotFoundException，
    // 比静默显示一个空列表好 —— 空列表等于告诉用户「你没下过东西」，
    // 而台账里可能正躺着几百条记录，这个谎代价太大。
    final ledger = context.watch<BiliLedger>();

    return ListenableBuilder(
      listenable: ledger,
      builder: (context, _) {
        final records = ledger.records;
        if (records.isEmpty) {
          return DownloadEmptyHint(
            name: kBiliHistoryTab,
            title: t('还没有下载记录'),
            hint: t('在 B 站解析下载页勾选分P并下完之后就会记在这里。\n'
                '记录按「分P」计，把文件移走或删掉也仍然算下过。'),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
              child: Row(
                children: [
                  Icon(Icons.history_rounded, size: 15, color: c.accent),
                  const SizedBox(width: 7),
                  Text(
                    tf('共 {n} 个分P', {'n': records.length}),
                    style: TextStyle(fontSize: 12.5, color: c.textMuted),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _confirmClear(context, ledger),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 15),
                    label: Text(t('清空')),
                    style: TextButton.styleFrom(
                      foregroundColor: c.danger,
                      textStyle: const TextStyle(fontSize: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                itemCount: records.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _historyRow(c, ledger, records[i]),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _historyRow(AppColors c, BiliLedger ledger, BiliDownloadRecord r) {
    final bvid = _of(r.keyGroup['bvid']);
    final cid = _of(r.keyGroup['cid']);
    // 台账一条记录只有一个标题位（`BiliPartMeta.title`），所以这里显示的就是
    // 「这一条叫什么」：入库方按分 P 记账，写进来的通常是分P标题，
    // 写作品标题也照样是这一行 —— 想两个都显示得先给记录加字段。
    // 都没写就退回 BV 号，再没有就是 hash：一行连标识都没有的历史没法读。
    final title = _of(r.title).isNotEmpty
        ? r.title!
        : (bvid.isNotEmpty ? bvid : r.hashId);
    final up = _of(r.author).isNotEmpty ? r.author! : t('UP 主未知');
    // 分 P 的定位只能靠 `cid`：台账的键组里存的就是它（P 号没入库，
    // 而按 hash 记账的设计也不认 P 号这种会变的东西）。
    final part = bvid.isEmpty
        ? r.label
        : (cid.isEmpty ? bvid : tf('{bv} · 分P {cid}', {'bv': bvid, 'cid': cid}));

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: c.surfaceCardHover,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line),
      ),
      child: Row(
        children: [
          Icon(Icons.play_circle_outline_rounded, size: 16, color: c.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: c.textStrong),
                ),
                const SizedBox(height: 3),
                Text(
                  '$up · ${_formatTime(r.time)} · $part',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: c.textFaint),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            // 删这条要用**键组**而不是 id：台账一律按 hash 记账，
            // 而 hash 是键组算出来的（抖音那边才是直接拿 awemeId 删）。
            onPressed: () => ledger.drop([r.keyGroup]),
            tooltip: t('从历史中移除（下次会重新下载）'),
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            color: c.textMuted,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, BiliLedger ledger) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('清空下载历史？')),
        content: Text(t('清空之后，下次批量下载就不会再跳过这些分P了。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t('清空')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 清完必须说有没有真的写回磁盘：台账没清干净的话，下次批量下载会继续
    // 静默跳过那批分 P，而用户以为自己已经清过了（抖音那边踩过同一个坑）。
    final cleared = await ledger.clear();
    if (!context.mounted) return;
    AppToast.show(
      context,
      cleared
          ? t('已清除 B 站下载记录')
          : t('清除失败：记录文件写入出错，记录还在'),
      kind: cleared ? AppToastKind.success : AppToastKind.error,
    );
  }

  /// 键组里的值可能是 `int` 也可能是 `String`（`_asText` 两种都收），
  /// 显示一律按文本取，取不到当空串。
  static String _of(Object? v) => v?.toString().trim() ?? '';

  /// 时间格式与抖音那份历史一致，但**两份各留一份实现**：历史分区之间的边界
  /// 比省下这 6 行重要（共用一个工具函数的话，术语扫描就得连抖音的文件一起扫）。
  static String _formatTime(DateTime? at) {
    if (at == null) return t('时间未知');
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }
}
