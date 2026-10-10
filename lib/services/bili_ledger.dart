/// B 站「已下载」台账 —— 与 `douyin_ledger.dart` 同构：读过那边再读这边，
/// 需要换脑子的只有「键是什么」这一节。
///
/// ## 为什么 B 站的键是「一组」而不是「一个」
/// 抖音的粒度是作品（`aweme_id`，一个字符串就够）。B 站一个稿件（`bvid`）下有
/// 多个分 P，每个分 P 有自己的 `cid`，所以去重键必须是**一组字段**，
/// 于是先由键组算出稳定 hash（[biliHashId]），台账一律按 hash 记账与查询。
///
/// ## 键组 = `['bili', bvid, cid]`，**不含画质 / 编码**
/// 「跳过已下载」的语义是「这个内容我拿过了」，不是「我拿过这个 1080P AVC 流」。
/// 把 `quality` / `codec` 放进了键组的话，同一分 P 会被记成一串互不相干的条目：
/// 用户换个画质重下，程序认为那是新内容，「已下载 N 个」的数字也跟着涨到看不懂，
/// 而台账文件里挤满同一个分 P 的 8 个键。**画质变了还想再下一遍**的用户，
/// 该做的是关掉「跳过已下载」开关（那是页面上的显式意图），而不是让程序替他记。
///
/// 将来若要支持音频-only 或别的附属内容，再往键组里加一段 `kind`。现在**不加**：
/// 提前放一个猜出来的段（哪怕是空串），等真值确定时所有老 hash 都会变样、
/// 历史记录当场作废，代价比省下的多。
///
/// ## 三条规矩（与抖音台账一致，别改）
///   1. **pending / done 两段式**：入队只写 pending，下载成功才转 done。
///      半途失败/被取消的记录不算已下载 —— 否则用户丢了一次下载却再也拿不回来。
///   2. **绝不按磁盘上文件还在不在来清理记录**（红线）。用户会主动把下载好的文件
///      移走或删掉，但依然希望程序认为「这个下过了、别再下」。
///      所以这里不许出现「拿下载目录里的媒体路径做 exists 校验、不在了就删记录」
///      的代码 —— 本文件里仅有的几处 exists 判的都是台账文件自己与它的换名临时文件。
///   3. **历史误记不自愈**：旧记录错了就让它错，不做批量重算/修正。
///      （`_trim()` 按条数上限丢最旧的是另一回事 —— 那是防止文件无限变大，
///      抖音台账也是这么做的，且注释里写明了为什么上限取这个数。）
///
/// ## 落盘格式 v1
/// ```json
/// {"version":1,
///  "items":{"<hash_id>":{"k":{"bvid":"BV1xx411c7mD","cid":"123456"},
///                        "t":1699999999999,"text":"标题","user":"UP 主",
///                        "s":"pending","f":["<任务id>"]}}}
/// ```
/// `s` 缺省即 `done`。`k` 只给人看（下载历史要说得清哪一条是啥、能不能删），
/// 去重与查询一律只认 hash —— 手改 `k` 不会改变这条记录的归属，
/// 这正是不做自愈的底气所在。
///
/// **这个文件里只允许内容标识与展示元信息**：cookie / SESSDATA / buvid / token
/// 不许写进来，本模块的日志行里也不许出现。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import 'app_paths.dart';

/// 一条记录的状态。
///
/// 为什么要分两态：「提交进 aria2 队列就算已下载」是错的 —— 一次都没下成功的
/// 分 P（直链过期、网络断、ffmpeg 合并发错、用户取消）会永久占着「已下载」，
/// 用户开着「跳过已下载」就再也不会重试，而文件又不在手里。
/// 现在只有真的下完了才算 [done]。
enum BiliLedgerState {
  /// 已入队，这条分 P 的任务还没全部成功。
  pending,

  /// 全部任务都成功了 —— 这才是「已下载」，会出现在下载历史里。
  done,
}

/// 台账侧看到的工作状态（由调用方从 `DownloadStatus` 映射过来，
/// 台账不认识 `DownloadStore`，这样它能被单独测试）。
enum BiliTaskState { complete, failed, running, unknown }

/// 键组：字段名 → 值。见 [biliPartKey]。
typedef BiliKeyGroup = Map<String, Object?>;

/// 一条记录可选带上标题/UP 主，用于「下载历史」展示。
typedef BiliPartMeta = ({String? title, String? author});

/// 键组里的命名空间段。抖音的键（`aweme_id`）自带平台特征，
/// B 站的 `bvid`/`cid` 是纯字符串/数字，加一段命名空间免得与别的模块撞键，
/// 也给将来的非视频内容留位置。
const String kBiliNamespace = 'bili';

/// 键组 → 稳定签名串（**[biliHashId] 的内部实现，导出是为了能单独测**）。
///
/// 为什么不能直接 `jsonEncode(键组)` 去算 hash：Dart 的 Map 按**插入顺序**迭代，
/// `{'bvid':b,'cid':c}` 与 `{'cid':c,'bvid':b}` 会编出两种字符串，同一个分 P
/// 于是有两个 hash，去重当场失效。解析端与入库端本来就容易各写各的字面量，
/// 所以这里把两件事钉死：**字段名按字典序排，值一律转成字符串**。
String biliKeySignature(BiliKeyGroup keyGroup) {
  final names = keyGroup.keys.map((k) => k.toString()).toList()..sort();
  final buf = StringBuffer('{');
  for (var i = 0; i < names.length; i++) {
    if (i > 0) buf.write(',');
    final v = _asText(keyGroup[names[i]]);
    buf..write(jsonEncode(names[i]))..write(':')..write(jsonEncode(v));
  }
  return (buf..write('}')).toString();
}

/// 键组 → `hash_id`（md5 of [biliKeySignature] 的 UTF-8 字节）。
///
/// 只做**标识**，不当密码用，所以 md5 足够（参照实现 Bili23-Downloader 也是 md5）。
String biliHashId(BiliKeyGroup keyGroup) =>
    crypto.md5.convert(utf8.encode(biliKeySignature(keyGroup))).toString();

/// 普通稿件的一个分 P 的键组（本模块唯一的键组构造口）。
///
/// 值先归一化（trim、数字按字符串存），这样 `cid` 来自 JSON 的 `int`
/// 还是来自 URL 查询串的 `'12345'` 都算出同一个 hash。
BiliKeyGroup biliPartKey({required String? bvid, required String? cid}) => {
      'ns': kBiliNamespace,
      'bvid': _asText(bvid),
      'cid': _asText(cid),
    };

/// 键组能不能拿去记账：**每一段都必须有值**。
///
/// 少一段（`bvid` 空 = 解析没给 BV 号）时这条记录与「另一个 bvid」的键组
/// 会退化成一类，宁可丢掉这条也别污染去重（抖音那边同理：空 id 直接跳过）。
bool biliKeyGroupUsable(BiliKeyGroup keyGroup) {
  if (keyGroup.isEmpty) return false;
  for (final v in keyGroup.values) {
    if (_asText(v).isEmpty) return false;
  }
  return true;
}

/// 值 → 参与 hash 的字符串。
String _asText(Object? v) {
  if (v == null) return '';
  if (v is int) return v.toString();
  if (v is double) {
    // 同一个 cid 一会儿是 12345.0 一会儿是 12345，不能算出两个 hash。
    return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  }
  final s = v is String ? v : v.toString();
  return s.trim();
}

/// 日志行只留**第一行**并且截断。
///
/// 为什么要留神这个：`FormatException.toString()` 会把出错位置附近的**文件内容**
/// 一起带出来（实测尾巴上就是坏文件那几行）。台账里不该有凭据，但把一大段
/// 垃圾抄进日志会淹掉真正有用的行；而「第一行」本身（
/// `Unexpected character (at character 2)`）已经够定位了。
String _oneLine(String text) {
  final line = text.split('\n').first.trim();
  return line.length <= 160 ? line : '${line.substring(0, 160)}…';
}

/// 一条下载记录（分 P 粒度）
@immutable
class BiliDownloadRecord {
  const BiliDownloadRecord({
    required this.hashId,
    required this.keyGroup,
    this.at,
    this.title,
    this.author,
    this.state = BiliLedgerState.done,
    this.taskIds = const [],
  });

  /// [biliHashId] 的结果，台账内部的唯一主键。
  final String hashId;

  /// 这条记录的键组（`bvid` / `cid` / …）。**只用于展示与排查**，
  /// 判重不看它（见文件头的「`k` 只给人看」）。
  final BiliKeyGroup keyGroup;

  /// 下载时间（epoch millis）。
  final int? at;

  /// 稿件标题（多 P 时的父标题）。
  final String? title;

  /// UP 主。
  final String? author;

  final BiliLedgerState state;

  /// 这条分 P 提交过的任务 id（`DownloadStore` 的 localId）。
  /// 只用于推进 [pending] → [done]，成功后不再需要。
  final List<String> taskIds;

  bool get isDone => state == BiliLedgerState.done;

  DateTime? get time =>
      at == null ? null : DateTime.fromMillisecondsSinceEpoch(at!);

  bool get hasTime => at != null;

  /// 历史列表里给人看的一行：`BV1xx411c7mD · P3`——取不到就退回 hash。
  String get label {
    final b = _asText(keyGroup['bvid']);
    final c = _asText(keyGroup['cid']);
    if (b.isEmpty && c.isEmpty) return hashId;
    return c.isEmpty ? b : '$b · cid $c';
  }

  @override
  String toString() => 'BiliDownloadRecord($label, at: $at, $state)';
}

class BiliLedger extends ChangeNotifier {
  /// [maxRecords] 可注入，便于测试上限行为
  BiliLedger({this.maxRecords = kMaxRecords});

  /// 台账文件名（在数据目录下，与 `douyin_downloaded.json`、`settings.json` 同处，
  /// 但**是另一个文件**：两个模块的台账各自演进，不共用格式）
  static const String fileName = 'bili_downloaded.json';

  /// 当前落盘格式版本。
  ///
  /// 从 1 起：这是 B 站侧第一版落盘格式，键是 hash 而不是明文 id，
  /// 所以没有向下兼容的旧数据要认（抖音那边的 3 是它自己的历史，互不相干）。
  static const int kFormatVersion = 1;

  /// 记录条数上限：超出时丢**最旧**的。
  ///
  /// 与抖音取同一个数（那边的理由：重度用户 5215 条台账，5000 会在迁移后被
  /// `_trim()` 悄悄删掉一批）。B 站这边按分 P 记，一个 50 P 的合集就是 50 条，
  /// 条数只会比抖音更多；20000 条约 500 KB，落盘是 JSON 文件，没有
  /// 浏览器 localStorage 那种 5 MB 约束。
  static const int kMaxRecords = 20000;

  final int maxRecords;

  final Map<String, BiliDownloadRecord> _records =
      <String, BiliDownloadRecord>{};
  File? _file;
  bool _loaded = false;

  /// 写盘链条的尾巴（见 [_save]）。
  Future<void> _tail = Future<void>.value();

  /// 台账里的全部条目数（含还在下载的）。
  ///
  /// 「跳过已下载」拦不拦是按这个集合判的 —— 正在下的也算，否则会重复提交。
  int get count => _records.length;

  /// **已下完**的分 P 数 —— 界面上「已下载 N 个」用它，别用 [count]。
  int get doneCount => _records.values.where((r) => r.isDone).length;

  bool get loaded => _loaded;

  /// 这条键组在不在台账里（**pending 与 done 都算**）。
  ///
  /// 与抖音的 `contains` 同语义：还在下的也算「已处理过」，否则用户手快再点一次
  /// 就会重复提交同一个分 P。只想看「真的下完了」的调用方用 [isDone] / [doneCount]。
  bool contains(BiliKeyGroup keyGroup) => _records.containsKey(hashOf(keyGroup));

  /// 这条键组是不是已经下完了。
  bool isDone(BiliKeyGroup keyGroup) =>
      _records[hashOf(keyGroup)]?.isDone ?? false;

  /// 键组当前在台账里的状态；没有这条记录时返回 null。
  BiliLedgerState? stateOf(BiliKeyGroup keyGroup) =>
      _records[hashOf(keyGroup)]?.state;

  /// 键组 → hash_id（与 [biliHashId] 同一个算法，暴露出来是给调用方
  /// 批量传 meta / 任务 id 时当字典键用 —— Map 按 identity 哈希，
  /// 内容相同的两个键组是两个不同的字典键，所以侧表只能按 hash 索引）。
  String hashOf(BiliKeyGroup keyGroup) => biliHashId(keyGroup);

  /// 已下完的记录，按下载时间**从新到旧**；没有时间的排在最后。
  ///
  /// 还在下的（[BiliLedgerState.pending]）不在这里 —— 「已下载（B 站）」
  /// 这个列表给用户看的是「哪些内容我已经拿到手了」。
  List<BiliDownloadRecord> get records {
    final list = _records.values.where((r) => r.isDone).toList()
      ..sort((a, b) {
        final x = a.at;
        final y = b.at;
        if (x == null && y == null) return a.hashId.compareTo(b.hashId);
        if (x == null) return 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });
    return List.unmodifiable(list);
  }

  /// 拿到台账文件句柄（必要时建目录）。
  ///
  /// 单独抽出来是为了**没先 `load()` 也能落盘**：否则「标记了却没保存」
  /// 会静默发生，用户看到的就是「下载历史又空了」。
  Future<File> _ensureFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await _configDir();
    if (!await dir.exists()) await dir.create(recursive: true);
    return _file = File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  /// 读入台账。
  ///
  /// **任何情况下都不往外抛**：这是启动路径上的一环，台账读坏了不能把整个
  /// 应用带崩。文件不存在 = 空台账；JSON 非法/形状不对 = 写一行日志 + 空台账，
  /// 坏文件原样留着（不删不改 —— 见文件头的「历史误记不自愈」，也保住它可能是
  /// 被别的程序临时锁住而不是真坏了这一种情况）。
  Future<void> load() async {
    try {
      final f = await _ensureFile();
      if (await f.exists()) {
        final raw = await f.readAsString();
        _records
          ..clear()
          ..addAll(_decode(raw));
      }
    } catch (e) {
      debugPrint('[BiliLedger] 读取失败：$e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// 解析台账。坏数据整份丢弃（与抖音同做法：一条脏记录不该毁掉整个台账，
  /// 而整份形状不对时内存里也不该留下半套状态）。
  Map<String, BiliDownloadRecord> _decode(String raw) {
    final out = <String, BiliDownloadRecord>{};
    Object? broken;
    try {
      final v = jsonDecode(raw);
      if (v is! Map) {
        broken = '顶层不是对象';
      } else {
        final ver = v['version'];
        final items = v['items'];
        if (ver != kFormatVersion || items is! Map) {
          // 版本号本身照实写：将来出 v2 时，这行日志就是「谁还在读旧程序写的文件」的证据。
          broken = '形状不对（version=$ver，本模块认 $kFormatVersion；'
              'items=${items is Map ? "对象" : "缺失/类型不对"}）';
        } else {
          items.forEach((k, value) {
            if (k is! String || k.isEmpty) return;
            if (value is! Map) return;
            final keyGroup = _keyGroup(value['k']);
            final t = value['t'];
            final f = value['f'];
            out[k] = BiliDownloadRecord(
              hashId: k,
              keyGroup: keyGroup,
              at: t is num ? t.toInt() : null,
              title: _str(value['text']),
              author: _str(value['user']),
              // done 是缺省态，写的时候不落字段，读的时候也一样
              state: value['s'] == BiliLedgerState.pending.name
                  ? BiliLedgerState.pending
                  : BiliLedgerState.done,
              taskIds: f is List ? [for (final x in f) if (x is String) x] : const [],
            );
          });
        }
      }
    } catch (e) {
      broken = e;
    }
    if (broken != null) {
      out.clear();
      // 只写 fileName，不写整条路径（启动时 `AppLogger` 已经记过数据目录）。
      final why = _oneLine('$broken');
      AppLogger.log('BILI-LEDGER', '$fileName 读不进去，已按空台账启动：$why');
      debugPrint('[BiliLedger] 台账损坏，已按空台账启动：$why');
    }
    return out;
  }

  /// 落盘里的 `k` → 键组。只收字符串键值，别的类型一律丢掉。
  static BiliKeyGroup _keyGroup(Object? raw) {
    if (raw is! Map) return {};
    return <String, Object?>{
      for (final e in raw.entries)
        if (e.key is String && e.value != null) e.key as String: e.value.toString(),
    };
  }

  static String? _str(Object? v) {
    if (v is! String) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  /// 时间戳保证**严格递增**：同一毫秒内连续标记多条时，
  /// 「从新到旧」的顺序与 `_trim()` 丢的都是同一批才有定论
  /// （Windows 时钟精度可能只有几毫秒）。
  int _nextStamp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var maxAt = 0;
    for (final r in _records.values) {
      final t = r.at;
      if (t != null && t > maxAt) maxAt = t;
    }
    return now > maxAt ? now : maxAt + 1;
  }

  /// 记为 pending（已入队、还没下完）。
  ///
  /// 这是下载链路上该由 UI 调的入口之一：入队成功 ≠ 拿到文件，所以这里只写
  /// [BiliLedgerState.pending]，之后由 [markDone]（成功回调）或 [advance]
  /// （按任务实际结局）转成已下载或撤销。
  ///
  /// [taskIds] 按 hash_id 索引（理由见 [hashOf]）：**给了任务 id 的记录**
  /// 才推得动 [advance]；没给的话这条 pending 只是用来挡住重复入队，
  /// 等调用方自己 [markDone]。
  Future<void> markPending(
    Iterable<BiliKeyGroup> keyGroups, {
    Map<String, BiliPartMeta>? meta,
    Map<String, List<String>>? taskIds,
  }) async {
    int? stamp;
    int takeStamp() => stamp ??= _nextStamp();
    var changed = false;

    for (final group in keyGroups) {
      final hash = _usableRecord(group);
      if (hash == null) continue;
      final ids = taskIds?[hash] ?? const <String>[];
      final old = _records[hash];
      final m = meta?[hash];

      if (old == null) {
        _records[hash] = BiliDownloadRecord(
          hashId: hash,
          keyGroup: group,
          at: takeStamp(),
          title: m?.title,
          author: m?.author,
          state: BiliLedgerState.pending,
          taskIds: ids,
        );
        changed = true;
      } else if (!old.isDone && !_sameTaskIds(old.taskIds, ids)) {
        // 同一分 P 再次提交（失败后重试）—— **换成**新任务 id，不并集：
        // 旧的失败任务留在里面会让 [advance] 把刚下好的分 P 又撤销。
        _records[hash] = BiliDownloadRecord(
          hashId: hash,
          keyGroup: group,
          at: old.at,
          title: old.title ?? m?.title,
          author: old.author ?? m?.author,
          state: BiliLedgerState.pending,
          taskIds: ids,
        );
        changed = true;
      }
    }

    if (changed) await _commit();
  }

  /// 记为 done（已下载）。
  ///
  /// 下载成功回调里用这个；已经算已下载的不覆盖时间 —— 历史时间应当是
  /// 第一次拿到它的时间。pending 记录转 done 时把任务 id 丢掉：
  /// 留着的话下一次 [advance] 会拿旧任务的结局（可能已经是 error）把这条
  /// 已下载撤销。
  Future<void> markDone(
    Iterable<BiliKeyGroup> keyGroups, {
    Map<String, BiliPartMeta>? meta,
  }) async {
    int? stamp;
    int takeStamp() => stamp ??= _nextStamp();
    var changed = false;

    for (final group in keyGroups) {
      final hash = _usableRecord(group);
      if (hash == null) continue;
      final old = _records[hash];
      if (old != null && old.isDone) continue;
      final m = meta?[hash];
      _records[hash] = BiliDownloadRecord(
        hashId: hash,
        keyGroup: group,
        at: old?.at ?? takeStamp(),
        title: old?.title ?? m?.title,
        author: old?.author ?? m?.author,
      );
      changed = true;
    }

    if (changed) await _commit();
  }

  /// 把一个新任务 id 续到这条分 P 的「在下」记录上（失败重试会换任务 id）。
  ///
  /// [hashId] 是 [hashOf] 的结果。没有对应 pending 记录时**什么都不做**：
  /// 这条 API 由 aria2 的提交回调驱动，而没有被台账认领的分 P
  /// 不该凭空冒出一条 pending。
  Future<void> attachTask(String hashId, String taskId) async {
    final r = _records[hashId];
    if (r == null || r.isDone) return;
    if (r.taskIds.contains(taskId)) return;
    _records[hashId] = BiliDownloadRecord(
      hashId: r.hashId,
      keyGroup: r.keyGroup,
      at: r.at,
      title: r.title,
      author: r.author,
      state: BiliLedgerState.pending,
      taskIds: [...r.taskIds, taskId],
    );
    await _commit();
  }

  /// 按任务的实际结局推进台账。返回是否发生了变化。
  ///
  /// 为什么需要它：记账点从「入队时」挪到了「下完时」，而「下完」这件事发生在
  /// aria2 事件里 —— 事件会丢（进程在完成前退出、上次会话的任务被
  /// `--input-file` 读回来时已经是完成态）。所以这里不看事件顺序：
  /// 任何时候拿任务表对一遍就能纠正，启动时也调一次（抖音那边的
  /// `bindLedgerToDownloads` 就是这么接的）。
  ///
  /// [statusOf] 由调用方按任务 id 查状态。判据与抖音逐条对应：
  ///   * 任一任务 [BiliTaskState.failed] → 撤掉这条记录，下次刷到同一分 P 能重试；
  ///   * 其余**查得到的**任务全部 [BiliTaskState.complete] → 转 done；
  ///   * [BiliTaskState.running] 还挂着 → 保持在下；
  ///   * 全部 [BiliTaskState.unknown]（任务被重试换掉、或用户从下载管理里删了）
  ///     → 保持原状，**不猜**。
  ///
  /// 「忽略 unknown 再判」而不是要求全部 complete：失败重试会把旧任务从任务表里
  /// 删掉换一个新 id，旧 id 从此查不到；把它当阻碍这条分 P 就永远转不成已下载。
  Future<bool> advance(BiliTaskState Function(String taskId) statusOf) async {
    var changed = false;
    for (final hash in _records.keys.toList()) {
      final r = _records[hash];
      if (r == null || r.isDone || r.taskIds.isEmpty) continue;
      final known = [
        for (final tid in r.taskIds) statusOf(tid),
      ].where((s) => s != BiliTaskState.unknown).toList(growable: false);
      if (known.isEmpty) continue;

      if (known.any((s) => s == BiliTaskState.failed)) {
        // 撤记录 = 允许下次重试。**只看任务表，不看磁盘**（红线）。
        _records.remove(hash);
        changed = true;
        continue;
      }
      if (known.every((s) => s == BiliTaskState.complete)) {
        _records[hash] = BiliDownloadRecord(
          hashId: r.hashId,
          keyGroup: r.keyGroup,
          at: _nextStamp(),
          title: r.title,
          author: r.author,
        );
        changed = true;
      }
    }
    if (!changed) return false;
    await _commit();
    return true;
  }

  /// 删掉记录（下载历史里的「移除」、以及「这一批我不算了」）。
  Future<void> drop(Iterable<BiliKeyGroup> keyGroups) async {
    var changed = false;
    for (final group in keyGroups) {
      final hash = _usableRecord(group);
      if (hash == null) continue;
      if (_records.remove(hash) != null) changed = true;
    }
    if (changed) await _commit();
  }

  /// 「清除下载记录」。**返回是否真的落盘**。
  ///
  /// 写盘失败时台账其实还在，用户下次批量下载会继续静默跳过那批分 P，
  /// 而他以为自己已经清干净了 —— 比不提示更难查（抖音踩过，返回值是为它留的）。
  Future<bool> clear() async {
    if (_records.isEmpty) return true;
    _records.clear();
    notifyListeners();
    return _save();
  }

  /// 状态变了 → 通知界面 → 落盘。`_records` 的改动是同步的，
  /// 只有落盘要等（见 [_save] 的串行化）。
  Future<void> _commit() async {
    _trim();
    notifyListeners();
    await _save();
  }

  /// 超出上限时丢最旧的（没有时间的当作最旧）
  void _trim() {
    if (_records.length <= maxRecords) return;
    final sorted = _records.values.toList()
      ..sort((a, b) {
        final x = a.at;
        final y = b.at;
        if (x == null && y == null) return a.hashId.compareTo(b.hashId);
        if (x == null) return -1;
        if (y == null) return 1;
        return x.compareTo(y); // 最旧在前
      });
    final drop = sorted.length - maxRecords;
    for (var i = 0; i < drop; i++) {
      _records.remove(sorted[i].hashId);
    }
  }

  /// 键组 → hash_id；不可用的键组返回 null（跳过，不写脏记录）。
  String? _usableRecord(BiliKeyGroup keyGroup) =>
      biliKeyGroupUsable(keyGroup) ? biliHashId(keyGroup) : null;

  /// 同进程内的写盘**串行**。
  ///
  /// 为什么必须有：改 `_records` 是同步的，但落盘要 await —— 两个并发调用
  /// （一次批量入队 + 一次 aria2 完成回调）各自开一个 `writeAsString`，
  /// 后一个在 Windows 上会被直接拒绝访问（实测 errno=5），于是少一次更新而
  /// 谁都不报错。全部写排到一条链上，后一个等前一个写完。
  Future<bool> _save() {
    final pending = _tail.then((_) => _write());
    // `_write` 自己吞掉所有异常并返回 false，所以链条不会被一次失败卡死；
    // 这里再兜一层，防的是以后有人在 `_write` 里加了会往外抛的代码，
    // 那样 `_tail` 会永久停在错误状态，之后每次写盘都直接跳过。
    _tail = pending.then<void>((_) {}, onError: (_) {});
    return pending;
  }

  Future<bool> _write() async {
    File? tmp;
    try {
      final f = await _ensureFile();
      final tmpFile = File('${f.path}.tmp');
      tmp = tmpFile;
      // 先写临时文件、flush 落盘，再改名盖上：改名在同一目录里是原子的，
      // 所以读到的要么是旧台账、要么是新台账，**不会有半截 JSON**。
      // 直接 `f.writeAsString` 的话，崩在 truncate 之后就是空台账（丢历史）。
      await tmpFile.writeAsString(jsonEncode(_payload()), flush: true);
      await tmpFile.rename(f.path);
      return true;
    } catch (e) {
      debugPrint('[BiliLedger] 写入失败：${_oneLine('$e')}');
      AppLogger.log('BILI-LEDGER', '$fileName 写入失败：${_oneLine('$e')}');
      // 改名被拒绝（目标被杀软/资源管理器占着）时退回原地覆盖：
      // 丢掉一次原子性，也比丢掉这次更新好 —— 台账少一条就意味着重复下载。
      try {
        final f = await _ensureFile();
        await f.writeAsString(jsonEncode(_payload()), flush: true);
        return true;
      } catch (e2) {
        debugPrint('[BiliLedger] 退回原地写也失败：$e2');
        return false;
      }
    } finally {
      // 退路写过之后 tmp 可能还在（改名失败）；顺手清掉，别留垃圾。
      try {
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 内存状态 → 落盘载荷。
  Map<String, Object?> _payload() => <String, Object?>{
        'version': kFormatVersion,
        'items': <String, Object?>{
          for (final e in _records.values)
            e.hashId: <String, Object?>{
              // done 是缺省态，不写字段，省得每条都多一行
              if (!e.isDone) 's': e.state.name,
              if (e.at != null) 't': e.at,
              if (e.title != null) 'text': e.title,
              if (e.author != null) 'user': e.author,
              if (e.taskIds.isNotEmpty) 'f': e.taskIds,
              'k': <String, Object?>{
                for (final seg in e.keyGroup.entries) seg.key: _asText(seg.value),
              },
            },
        },
      };

  /// 数据目录由 [AppPaths] 统一决定（跟着软件走）—— 与抖音台账同一个目录。
  Future<Directory> _configDir() async => AppPaths.configDir;
}

/// 两组任务 id 是否等价（顺序无关）—— 用来判断「再次提交」要不要更新记录。
bool _sameTaskIds(List<String> a, List<String> b) =>
    a.length == b.length && a.toSet().containsAll(b);
