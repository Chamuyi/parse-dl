/// B 站弹幕 protobuf（`dm/wbi/web/seg.so` 的响应体）的**手写最小 wire 解码器**。
///
/// 为什么不引 `protobuf` 依赖、也不放 `.proto` 文件：
///   1. B 站这份 descriptor 没有公开可校验的来源，`.proto` 只能靠逆向凑，
///      凑出来的 schema 一旦少写一个字段，用生成码解码会把整包丢掉；
///   2. 本期只需要 7 个字段，而 wire 格式本身只有四种 wire type，
///      手写百来行就够，且**未知 tag 按 wire type 跳过**这件事在生成码里是黑盒、
///      在这里是可测的（见 `test/bili_dm_proto_test.dart` 的负控制）。
///
/// **未知 tag 是硬要求，不是理论洁癖**：真夹具 `DanmakuElem` 里除 descriptor 已知的
/// 1~9/12/13 之外，实测还出现 15、20、21、25、26、27 六个字段（26 就是本条的 oid）。
/// 把任何一个当错误就是整包丢弹幕。
///
/// 字段号的物理含义是拿真字节反证过的，不是照抄注释：
/// 分段 1 覆盖视频 0~360s、分段 2 覆盖 360~720s，五条真弹幕里**只有 tag 2**
/// 的取值在分段 1 全落在 [0,360000) 毫秒、在分段 2 落在 [360000,720000) 毫秒 ——
/// 所以 tag 2 是「相对视频起点的毫秒偏移」，也就是 `stime`。
/// 同理 tag 4 恒为 25（与 [kBiliDefaultDanmakuFontSize] 同值，字号）、
/// tag 5 恒为 0xFFFFFF（白色，颜色）、tag 8 是十位数的秒级时间戳（发出时间）。
library;

import 'dart:convert';
import 'dart:typed_data';

// ── wire 层常量 ───────────────────────────────────────────────

/// protobuf 的 varint 最长 10 个字节（64 位 ÷ 7 位一组，向上取整）。
const int kBiliProtoMaxVarintBytes = 10;

// ── 字段号 ────────────────────────────────────────────────────

/// `DmSegMobileReply.elems`：重复的 `DanmakuElem`，本层唯一关心的顶层字段。
///
/// 顶层还实测出现 tag 4（段内最大时间，裸 varint 串）与 tag 5（展示配置，内含一段
/// JSON），本期不需要，按未知 tag 跳过。
const int kBiliDmFieldElems = 1;

const int kBiliDmFieldId = 1; // int64  弹幕 id
const int kBiliDmFieldStime = 2; // int32 相对视频起点的毫秒
const int kBiliDmFieldMode = 3; // int32 弹幕类型
const int kBiliDmFieldSize = 4; // int32 字号
const int kBiliDmFieldColor = 5; // uint32 0xRRGGBB
const int kBiliDmFieldUhash = 6; // string 发送者 mid 的 md5 前 8 位
const int kBiliDmFieldText = 7; // string 弹幕内容
const int kBiliDmFieldDate = 8; // int64  发出时间的秒级时间戳
const int kBiliDmFieldWeight = 9; // int32 权重（屏蔽用，本期不参与判定）

// ── 弹幕类型 ──────────────────────────────────────────────────

// 档位含义按 B 站旧 XML 接口 `p` 属性第一段的公开口径对齐：
// 1/2/3 = 滚动（2、3 是历史上的第二种滚动形态）、4 = 顶部、5 = 底部、
// 6 = 逆向滚动、`>= 7` = 特效/代码类。
// 注意有文档把 3 说成「底部」：本期把**未单独列举的档位一律画成滚动**，
// 判据是真夹具 6 条全是 mode 1，其余档位没有样本可证 —— 而认错档位的后果只是
// 「画在哪一行」，不会让弹幕消失，所以按最保守的那一档走。

/// 滚动弹幕（右进左出）。真夹具 6 条全是这一档。
const int kBiliDmModeScroll = 1;

/// 逆向滚动：与 [kBiliDmModeScroll] 共用同一套行槽位，只是方向反过来
/// （左进右出，见 `biliDanmakuToAss`）。
const int kBiliDmModeReverse = 6;

/// 顶部固定
const int kBiliDmModeTop = 4;

/// 底部固定
const int kBiliDmModeBottom = 5;

/// 特效/代码弹幕的起始档：`mode >= 7` 的 text 里装的是渲染指令而不是给人看的字，
/// 本期**不渲染**，但要如实计入统计（见 `BiliDanmakuStats.specialSkipped`）。
const int kBiliDmModeSpecialMin = 7;

// ── 缺省值 ────────────────────────────────────────────────────

/// descriptor 里缺字段时的兜底值，全部取真夹具里的恒等取值。
///
/// 缺省不是「随便填一个」：一条弹幕缺 `mode` 按 1（滚动）是唯一合理 guesses，
/// B 站自己的播放器也是这么画的；缺 `color` 用白色最不容易看不见。
const int kBiliDmDefaultMode = kBiliDmModeScroll;
const int kBiliDmDefaultSize = 25;
const int kBiliDmDefaultColor = 0xFFFFFF;

/// 解码失败。
///
/// 文本刻意写清「第几字节」「哪个 tag」「要几个字节」——真机上一旦出现
/// 某个分段解不开，这几处是唯一能把归因从「网络」拉回到「字节」的信息。
class BiliDmProtoException implements Exception {
  const BiliDmProtoException(this.message);
  final String message;
  @override
  String toString() => 'BiliDmProtoException: $message';
}

/// 一条弹幕。
///
/// 只有本期渲染要用到的字段：`id` / `stime` / `mode` / `size` / `color` / `text` /
/// `date`。权重、attr、midhash 都留在字节流里没带出来 —— 需要时再加字段，
/// 不要把它们塞进 `Map` 里让下游各自解释。
class BiliDanmaku {
  const BiliDanmaku({
    this.id = 0,
    this.stime = 0,
    this.mode = kBiliDmDefaultMode,
    this.size = kBiliDmDefaultSize,
    this.color = kBiliDmDefaultColor,
    this.text = '',
    this.date = 0,
    this.pool = 0,
  });

  /// 弹幕 id（雪花号，19 位，必须按 int64 存，别转 double 会掉精度）。
  final int id;

  /// 相对**视频起点**的毫秒偏移。分段边界不影响它（分段 2 的值直接就是 60 万级）。
  final int stime;

  /// 弹幕类型，见上面 `kBiliDmMode*`。
  final int mode;

  /// 字号（px，B 站侧的 25 是「正常」档）。
  final int size;

  /// 颜色，0xRRGGBB。
  final int color;

  /// 内容
  final String text;

  /// 发出时间的秒级 Unix 时间戳
  final int date;

  /// 弹幕池。
  ///
  /// **注意：`DanmakuElem` 里没有 pool 这个字段**（只有旧的 XML 接口回过 pool），
  /// 所以从 protobuf 解出来的一律是 0。这一项留着是为了让「屏蔽池」这条过滤规则
  /// 在两种来源下同一套代码，且能被测试驱动到（测试里手工构造 pool != 0 的条目）。
  /// 不要把它当成「接口说这条不属于屏蔽区」的证据。
  final int pool;

  /// 秒（含小数），xml 的 `p` 属性第一段要用。
  double get stimeSeconds => stime / 1000.0;

  /// 特效/代码类：本期不渲染
  bool get isSpecial => mode >= kBiliDmModeSpecialMin;

  bool get isTop => mode == kBiliDmModeTop;

  bool get isBottom => mode == kBiliDmModeBottom;

  bool get isScroll =>
      !isSpecial && !isTop && !isBottom;

  @override
  String toString() =>
      'BiliDanmaku(id: $id, stime: $stime, mode: $mode, size: $size, '
      'color: 0x${color.toRadixString(16)}, text: $text, date: $date)';
}

// ── wire 读取 ─────────────────────────────────────────────────

/// 一条已读出的 wire 字段（未解释语义）。
///
/// 公开它不是为了好看：**未知 tag 必须「看得见」才谈得上证明解码器跳过了它**，
/// 而不是解出一个对象后无从判断。测试就是拿这个类型断言
/// 「tag 31 被当成 31、没有冒充 stime」。
class BiliProtoField {
  const BiliProtoField({
    required this.number,
    required this.wireType,
    this.varintValue = 0,
    this.bytesValue = const [],
    this.fixedValue = 0,
  });

  /// 字段号
  final int number;

  /// 0=varint 1=fixed64 2=length-delimited 5=fixed32
  final int wireType;

  /// wireType==0 时的值
  final int varintValue;

  /// wireType==2 时的原始字节（**已拷贝**，不随原缓冲变化）
  final List<int> bytesValue;

  /// wireType==1 / 5 时的无符号整数值
  final int fixedValue;

  /// 三种数值型 wire type 归到一个出口。
  ///
  /// **这里不做「是不是本条字段的合法类型」的判断** —— 那是语义层的事
  /// （见 `_intOf`：length-delimited 的 tag 2 绝不能当整数读成 stime）。
  int get intValue => switch (wireType) {
    0 => varintValue,
    1 => fixedValue,
    5 => fixedValue,
    _ => 0,
  };
}

/// 读出一个 message 的所有字段，**未知 tag 按其 wire type 原样跳过**。
///
/// 只做「分组」不做「解释」：语义由调用方按字段号挑。
/// 截断、varint 越界、length 超出缓冲都抛 [BiliDmProtoException]，不返回半截结果 ——
/// 半截结果在真机上表现为「弹幕少了几条」，比报错难查得多。
List<BiliProtoField> biliProtoReadFields(List<int> data) {
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  final reader = _BiliProtoReader(bytes);
  final out = <BiliProtoField>[];
  while (!reader.atEnd) {
    final start = reader.position;
    final key = reader.readVarint('字段 key');
    final number = key >> 3;
    final wireType = key & 0x7;
    if (number == 0) {
      throw BiliDmProtoException(
        '第 $start 字节读出的字段号为 0（wireType=$wireType），protobuf 不允许 0 号字段',
      );
    }
    switch (wireType) {
      case 0:
        out.add(
          BiliProtoField(
            number: number,
            wireType: 0,
            varintValue: reader.readVarint('tag $number 的值'),
          ),
        );
      case 1:
        out.add(
          BiliProtoField(
            number: number,
            wireType: 1,
            fixedValue: reader.readFixed(8, 'tag $number 的 fixed64'),
          ),
        );
      case 2:
        final length = reader.readVarint('tag $number 的长度');
        out.add(
          BiliProtoField(
            number: number,
            wireType: 2,
            bytesValue: reader.readBytes(length, 'tag $number 的 $length 字节负载'),
          ),
        );
      case 5:
        out.add(
          BiliProtoField(
            number: number,
            wireType: 5,
            fixedValue: reader.readFixed(4, 'tag $number 的 fixed32'),
          ),
        );
      default:
        throw BiliDmProtoException(
          '第 $start 字节的 wireType=$wireType 不属于 varint/fixed64/'
          'length-delimited/fixed32 四种之一（tag $number），无法跳过',
        );
    }
  }
  return out;
}

class _BiliProtoReader {
  _BiliProtoReader(this.bytes);

  final Uint8List bytes;
  int position = 0;

  bool get atEnd => position >= bytes.length;

  int readVarint(String what) {
    var result = 0;
    var shift = 0;
    var used = 0;
    while (true) {
      if (position >= bytes.length) {
        throw BiliDmProtoException('$what 的 varint 在第 $position 字节处截断');
      }
      final byte = bytes[position++];
      used++;
      if (used > kBiliProtoMaxVarintBytes) {
        throw BiliDmProtoException(
          '$what 的 varint 超过 $kBiliProtoMaxVarintBytes 个字节（第 $position 字节）',
        );
      }
      // 第 10 个字节的最高位必须只贡献 1 位，否则就是超出 64 位
      if (used == kBiliProtoMaxVarintBytes && (byte & 0x7F) > 1) {
        throw BiliDmProtoException('$what 的 varint 超出 64 位范围');
      }
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
    }
  }

  int readFixed(int count, String what) {
    if (position + count > bytes.length) {
      throw BiliDmProtoException(
        '$what 需要 $count 个字节，但第 $position 字节起只剩 '
        '${bytes.length - position} 个',
      );
    }
    var value = 0;
    for (var i = 0; i < count; i++) {
      value |= bytes[position + i] << (8 * i); // 小端
    }
    position += count;
    return value;
  }

  Uint8List readBytes(int length, String what) {
    if (length < 0) {
      throw BiliDmProtoException('$what 的长度是负数（$length）');
    }
    if (position + length > bytes.length) {
      throw BiliDmProtoException(
        '$what 声明 $length 个字节，但第 $position 字节起只剩 '
        '${bytes.length - position} 个',
      );
    }
    // sublist 是拷贝：解出来的 text 不随原缓冲被复用而变
    final slice = bytes.sublist(position, position + length);
    position += length;
    return slice;
  }
}

// ── 语义层 ────────────────────────────────────────────────────

/// 解 `DmSegMobileReply`，得到本段的弹幕列表（**不排序、不过滤**，照接口顺序）。
///
/// 顶层非 tag 1 的字段（实测有 4、5）全部忽略。
List<BiliDanmaku> biliDecodeDmSegReply(List<int> bytes) {
  if (bytes.isEmpty) return const [];
  final out = <BiliDanmaku>[];
  for (final field in biliProtoReadFields(bytes)) {
    if (field.number != kBiliDmFieldElems) continue;
    if (field.wireType != 2) {
      // tag 1 在 descriptor 里是嵌入消息，出现别的 wire type 就是接口换代，
      // 这时候**不能**把它当弹幕凑数，直接忽略并让上层看到条数对不上。
      continue;
    }
    out.add(_biliDecodeDanmakuElem(field.bytesValue));
  }
  return out;
}

BiliDanmaku _biliDecodeDanmakuElem(List<int> bytes) {
  var id = 0;
  var stime = 0;
  var mode = kBiliDmDefaultMode;
  var size = kBiliDmDefaultSize;
  var color = kBiliDmDefaultColor;
  var date = 0;
  var text = '';
  for (final field in biliProtoReadFields(bytes)) {
    switch (field.number) {
      case kBiliDmFieldId:
        id = _intOf(field, kBiliDmFieldId);
      case kBiliDmFieldStime:
        stime = _intOf(field, kBiliDmFieldStime);
      case kBiliDmFieldMode:
        mode = _intOf(field, kBiliDmFieldMode);
      case kBiliDmFieldSize:
        size = _intOf(field, kBiliDmFieldSize);
      case kBiliDmFieldColor:
        color = _intOf(field, kBiliDmFieldColor);
      case kBiliDmFieldText:
        text = _stringOf(field, kBiliDmFieldText);
      case kBiliDmFieldDate:
        date = _intOf(field, kBiliDmFieldDate);
      default:
      // 未知 tag（真字节里的 15/20/21/25/26/27 与 uhash/weight/dmid 都走这里）：
      // 跳过。 biliProtoReadFields 已经按 wire type 把它们整段消费掉了，
      // 所以后续字段不会串位 —— 这一条正是本期测试要证明的东西。
    }
  }
  return BiliDanmaku(
    id: id,
    stime: stime,
    mode: mode,
    size: size,
    color: color,
    text: text,
    date: date,
  );
}

/// 数值字段：只认能给出整数的那几种 wire type。
///
/// 刻意不用 `field.intValue` 兜底 length-delimited：packed 重复字段在 protobuf 里
/// 就是 wt=2 的整数串，若在这里当整数读会读出一个巨大的错值（表现是某条弹幕
/// 跑到几十小时后），而忽略它只是退回缺省值。
int _intOf(BiliProtoField field, int number) {
  if (field.wireType == 0 || field.wireType == 1 || field.wireType == 5) {
    return field.intValue;
  }
  return switch (number) {
    kBiliDmFieldMode => kBiliDmDefaultMode,
    kBiliDmFieldSize => kBiliDmDefaultSize,
    kBiliDmFieldColor => kBiliDmDefaultColor,
    _ => 0,
  };
}

String _stringOf(BiliProtoField field, int number) {
  if (field.wireType != 2) return '';
  // latin1 会在 >0xFF 的字节上抛；utf8.decode 的 allowedExceptions 也不能吞掉
  // 半截多字节序列。这里用 try 退成「按 latin1 保底读出来」而不是丢掉整条弹幕：
  // B 站偶发的脏文本（截断的表情符号）不该让一条弹幕消失。
  try {
    return utf8.decode(field.bytesValue);
  } on FormatException {
    return latin1.decode(field.bytesValue);
  }
}

/// 0xRRGGBB → ass 颜色串 `&HAABBGGRR`。
///
/// 两个坑都在这个函数里：**ass 的十六进制是 BGR 反的**，而 **alpha 在最前且
/// 00 是不透明、FF 是全透明**（与通常的「255 = 不透明」正好相反）。
/// [opacity] 是 0~100 的百分比（与配置的口径一致），100 → `&H00`。
String biliAssColor(int rgb, {int opacity = 100}) {
  final clamped = opacity.clamp(0, 100);
  // 0% 不透明 → alpha 255；100% 不透明 → alpha 0
  final alpha = (255 * (100 - clamped) / 100).round();
  final r = (rgb >> 16) & 0xFF;
  final g = (rgb >> 8) & 0xFF;
  final b = rgb & 0xFF;
  return '&H${_hex2(alpha)}${_hex2(b)}${_hex2(g)}${_hex2(r)}';
}

String _hex2(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
