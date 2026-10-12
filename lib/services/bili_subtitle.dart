/// 字幕：取回、按语言筛、渲染成 srt / ass / txt。
///
/// 数据源是 `x/player/wbi/v2` 的 `data.subtitle.subtitles[]`，每条再 GET 一次
/// `subtitle_url`（那是个 JSON，`body[]` 里是 `content` + `start_time`/`end_time`，
/// 单位是**秒的浮点**）。匿名态实测拿不到字幕（见取证 Q4），所以这一族的真机
/// 那一格必须等登录档，本文件只有夹具级证据。
///
/// 两条从参照实现里抄来的坑，都是踩过才知道的：
///  * MKV 的 `Language` 元素要 ISO 639-2 三字母码，B 站回的却是 BCP-47
///    （`zh-cn` / `ai-es`）。不归一，播放器字幕菜单里就是一串非法码。
///  * AI 字幕只有 `lan` 带 `ai-` 前缀，`lan_doc` 与人工字幕**完全同名**。
///    轨道标题不标注，菜单里就会出现两条都叫「中文」的轨，用户无法选。
library;

import 'dart:convert';

import '../models/bili_config.dart';
import 'bili_dm_proto.dart' show biliAssColor;

/// B 站 AI 字幕的语言码前缀。
const String kBiliAiLangPrefix = 'ai-';

/// 字幕正文的默认字号（ass 的 Fontsize，1080p 坐标系）。
///
/// **这个数是抄 B站播放器自己的公式算出来的**，不是拍的。2026-10-12 从本机
/// WebView2 缓存里的播放器 JS 挖到：
/// ```js
/// calculateFontSize() { var t=1, …; r && (t = panel.width / 1139); … return t; }
/// group[Major].style.fontSize = (t ?? 28) * calculateFontSize() + "px";
/// ```
/// 即主字幕字号 = `28 × (播放器宽 / 1139)`。1080p 全屏（宽 1920）下
/// `28 × 1920 / 1139 ≈ 47.2`。取 48：实测该值渲染出的汉字字形高 36 px，
/// 与 CSS 47.2px 的中文字形高（≈ em × 0.76）一致。
///
/// 与 [kBiliDefaultDanmakuFontSize]（25，弹幕用）分开的理由见 [biliSubtitleFontSize]。
const int kBiliDefaultSubtitleFontSize = 48;

/// 字幕正文的默认底部边距。
///
/// 弹幕默认 10 对字幕太贴底 —— 播放器的进度条与悬浮控件会压在上面。
const int kBiliDefaultSubtitleMarginV = 48;

/// 字幕描边宽度。抄 B站播放器的 `majorStrokeWidth: 3`。
///
/// B站是在 CSS 里用 8 向 `text-shadow` 模拟描边的（`buildStrokeShadow`），
/// ass 这边直接用 `Outline` 一个数就够了，语义等价。
const int kBiliSubtitleOutline = 3;

/// 字幕描边色：B站 `strokeColor: "#000000"`。
const int kBiliSubtitleOutlineColor = 0x000000;

/// 字幕正文色：B站 `textColor: "#FFFFFF"`。
const int kBiliSubtitlePrimaryColor = 0xFFFFFF;

/// BCP-47 → ISO 639-2。表里没有的一律映射成空串（= 不写 Language 标签），
/// 因为把 `xx-YY` 原样塞进 MKV 比不写更糟：播放器会显示一个非法语言码。
const Map<String, String> kBiliIso639 = {
  'zh': 'chi', 'zh-cn': 'chi', 'zh-hans': 'chi', 'zh-hant': 'chi',
  'zh-hk': 'chi', 'zh-tw': 'chi',
  'en': 'eng', 'en-us': 'eng', 'en-gb': 'eng',
  'ja': 'jpn', 'jp': 'jpn', 'ko': 'kor', 'es': 'spa', 'ar': 'ara',
  'pt': 'por', 'fr': 'fre', 'de': 'ger', 'ru': 'rus', 'it': 'ita',
  'vi': 'vie', 'th': 'tha', 'id': 'ind', 'ms': 'may', 'hi': 'hin',
  'tr': 'tur', 'pl': 'pol', 'nl': 'dut', 'tl': 'tgl',
};

/// 归一到 ISO 639-2；认不出来回空串（调用方据此**不写** Language 标签）。
///
/// `ai-` 前缀要先剥掉再查表：那是 B 站自己加的标记，不是语言子标签，
/// 留着查表的结果就是 AI 那几条全都没有语言标签。
String biliIso639(String lan) {
  final normalized = lan.toLowerCase().replaceFirst(kBiliAiLangPrefix, '');
  return kBiliIso639[normalized] ??
      kBiliIso639[normalized.split('-').first] ??
      '';
}

/// 是不是 AI 生成的那条。
bool biliIsAiSubtitle(String lan) =>
    lan.toLowerCase().startsWith(kBiliAiLangPrefix);

/// 一条已选中的字幕。
class BiliSubtitleEntry {
  const BiliSubtitleEntry({
    required this.lan,
    required this.lanDoc,
    required this.lines,
  });

  final String lan;
  final String lanDoc;

  /// 毫秒 + 文本，已按时间排好。
  final List<(int startMs, int endMs, String text)> lines;

  bool get isAi => biliIsAiSubtitle(lan);

  /// 播放器菜单里显示的名字。AI 那几条必须标出来，理由见文件头。
  String get trackTitle => isAi ? '$lanDoc（AI）' : lanDoc;
}

/// 从 `playerInfo` 的响应里挑出要下的语言。
///
/// [langs] 空 = 不筛选。比对时大小写与 `ai-` 前缀都不敏感
/// （用户勾的是 `zh-CN`，接口给的是 `zh-CN` 或 `ai-zh`，都得能对上）。
List<String> biliSubtitleLangKeys(List<String> wanted) =>
    [for (final w in wanted) w.toLowerCase().replaceFirst(kBiliAiLangPrefix, '')];

bool biliSubtitleWanted(String lan, List<String> wanted, {bool manualOnly = false}) {
  if (manualOnly && biliIsAiSubtitle(lan)) return false;
  if (wanted.isEmpty) return true;
  final key = lan.toLowerCase().replaceFirst(kBiliAiLangPrefix, '');
  return biliSubtitleLangKeys(wanted).contains(key);
}

/// 解析 `subtitle_url` 那份 JSON。字段缺失/形状不对时返回空列表而不是抛 ——
/// 一条字幕取不到不该让整批下载失败，缺什么由调用方记进 `missing`。
///
/// **字段名是 `from` / `to`，不是 `start_time` / `end_time`。**
/// 2026-10-11 登录档验收现场实测三条稿件（`probe_subtitle_fields.py`），
/// 每条的键都是 `['content','from','location','music','sid','to']` ——
/// 原来按 `start_time` 读，于是每一条都在 `s == null` 那行被 continue 掉，
/// 解析出 0 条，界面上表现为「字幕：ai-zh 是空的」。
/// 同一个协议在 `bili_chapter.dart` 里读的就是 `from`/`to`（那一支是对的），
/// 只有这里写错了 —— 而单测的夹具照抄了错的那份，所以 1426 条全绿也抓不到。
/// 回归测试 `test/bili_subtitle_body_shape_test.dart` 用的是真形状。
List<(int, int, String)> biliParseSubtitleBody(Object? decoded) {
  if (decoded is! Map) return const [];
  final body = decoded['body'];
  if (body is! List) return const [];
  final out = <(int, int, String)>[];
  for (final e in body) {
    if (e is! Map) continue;
    final content = e['content'];
    if (content is! String || content.trim().isEmpty) continue;
    // `from` / `to` 是**秒**的浮点，四舍五入到毫秒。
    // 兼容旧的 `start_time` / `end_time`：只有 ai-zh 这一种字幕被实测过
    // （人工字幕该账号一条都没有），留一个别名兜住没验过的形状。
    final s = ((e['from'] ?? e['start_time']) as num?)?.toDouble();
    final t = ((e['to'] ?? e['end_time']) as num?)?.toDouble();
    if (s == null) continue;
    final endMs = t == null ? s * 1000 + 2000 : t * 1000;
    out.add((
      (s * 1000).round(),
      (endMs > s * 1000 ? endMs : s * 1000 + 1000).round(),
      content,
    ));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

String biliSubtitleToSrt(List<(int, int, String)> lines) {
  final sb = StringBuffer();
  var i = 1;
  for (final (s, e, text) in lines) {
    sb
      ..write(i++)
      ..write('\n')
      ..write('${_srtTime(s)} --> ${_srtTime(e)}')
      ..write('\n')
      ..write(text)
      ..write('\n\n');
  }
  return sb.toString();
}

String biliSubtitleToTxt(List<(int, int, String)> lines) =>
    lines.map((e) => e.$3).join('\n');

/// ass 字幕。样式取配置里那几项，语言名进 Meta。
///
/// **主色必须用 [biliAssColor] 生成，不要手拼字符串。** 2026-10-12 真机撞上：
/// 这里曾写成 `'&H$alpha FFFFFF'` —— `$alpha` 与 `FFFFFF` 之间多了一个**空格**，
/// 而 ass 颜色是 `&HAABBGGRR` 八位十六进制，libass 在空格处截断，只读到 `&H00`
/// 补零成 `&H00000000`（不透明**黑**）。后果是内封字幕在播放器里是纯黑字，
/// 深色画面上直接看不见；`ScaledAndBorder` 那类拼写错误同理。
/// 实测判据：白底渲染同一帧，带空格时字形像素 79% 是近黑（1080/1367），
/// 去掉空格后只剩细描边（349/1227）。回归测试 `test/bili_subtitle_style_test.dart`。
String biliSubtitleToAss(
  BiliSubtitleEntry entry,
  BiliConfig cfg,
) {
  final primary = biliAssColor(kBiliSubtitlePrimaryColor, opacity: cfg.danmakuOpacity);
  final outline = biliAssColor(kBiliSubtitleOutlineColor);
  final sb = StringBuffer()
    ..writeln('[Script Info]')
    ..writeln('ScriptType: v4.00+')
    ..writeln('PlayResX: 1920')
    ..writeln('PlayResY: 1080')
    ..writeln('WrapStyle: 0')
    ..writeln('ScaledBorderAndShadow: yes')
    ..writeln('')
    ..writeln('[V4+ Styles]')
    ..writeln(
      'Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, '
      'BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, '
      'Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, '
      'MarginL, MarginR, MarginV, Encoding',
    )
    ..writeln(
      'Style: Default,${cfg.danmakuFontFace},${biliSubtitleFontSize(cfg)},'
      '$primary,$outline,&H00000000,0,0,0,0,100,100,0,0,1,'
      '$kBiliSubtitleOutline,0,2,20,20,${biliSubtitleMarginV(cfg)},134',
    )
    ..writeln('')
    ..writeln('[Events]')
    ..writeln('Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text')
    ..writeln('; ${entry.lan} / ${entry.lanDoc}');
  for (final (s, e, text) in entry.lines) {
    sb.writeln(
      'Dialogue: 0,${_assTime(s)},${_assTime(e)},Default,,0,0,0,,'
      '${biliEscapeSubtitleAssText(text)}',
    );
  }
  return sb.toString();
}

/// 字幕正文字号（ass 的 Fontsize，1080p 坐标系）。
///
/// **不直接复用 `cfg.danmakuFontSize`。** 那个默认值是 25，是给**弹幕**用的
/// —— 弹幕一行要挤很多条，字号天然偏小。字幕是「一行一句」的正文，25 太小：
/// 2026-10-12 实测 25 的字形高只有 19 px（占 1080p 屏高 1.76%），而 B 站播放器
/// 自己的字幕与 Netflix 规范都在 42 上下（字形高 31 px / 2.87%），常见压制组
/// 正文在 48（36 px / 3.33%）。
///
/// 取值规则：用户调过弹幕字号（≠ 默认 25）就尊重他的选择；仍是默认值时给
/// 字幕一个更大的默认，避免"没调过设置的人看到一片小字"。
int biliSubtitleFontSize(BiliConfig cfg) {
  final v = cfg.danmakuFontSize;
  return v == kBiliDefaultDanmakuFontSize ? kBiliDefaultSubtitleFontSize : v;
}

/// 字幕底部边距。与弹幕同源，但弹幕默认 10 对字幕太贴底（会被播放器进度条压住）。
int biliSubtitleMarginV(BiliConfig cfg) {
  final v = cfg.danmakuMarginV;
  return v == kBiliDefaultDanmakuMarginV ? kBiliDefaultSubtitleMarginV : v;
}

/// ass 文本转义：反斜杠与花括号会改语义，换行要变成 `\N`。
String biliEscapeSubtitleAssText(String text) => text
    .replaceAll('\\', '\\\\')
    .replaceAll('{', '(')
    .replaceAll('}', ')')
    .replaceAll('\r\n', '\\N')
    .replaceAll('\n', '\\N');

String _srtTime(int ms) {
  final h = ms ~/ 3600000;
  final m = (ms % 3600000) ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  final frac = ms % 1000;
  return '${_two(h)}:${_two(m)}:${_two(s)},${frac.toString().padLeft(3, '0')}';
}

String _assTime(int ms) {
  final h = ms ~/ 3600000;
  final m = (ms % 3600000) ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  final cs = (ms % 1000) ~/ 10;
  return '$h:${_two(m)}:${_two(s)}.${cs.toString().padLeft(2, '0')}';
}

String _two(int v) => v.toString().padLeft(2, '0');

/// 只把 JSON 文本化（给 json 档用；字幕这一族本期不出 json 档，留着是给
/// 「原样存一份」的场景，不重复实现一遍）。
String biliSubtitleJsonDump(List<BiliSubtitleEntry> entries) =>
    jsonEncode([
      for (final e in entries)
        {
          'lan': e.lan,
          'lan_doc': e.lanDoc,
          'ai': e.isAi,
          'body': [
            for (final (s, t, text) in e.lines)
              {'start': s, 'end': t, 'content': text},
          ],
        },
    ]);
