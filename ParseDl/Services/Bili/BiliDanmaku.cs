using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.Bili;

/// <summary>一条弹幕。</summary>
public sealed record BiliDanmaku(double TimeSec, int Mode, int FontSize, long Color, string Text);

/// <summary>
/// B 站弹幕下载 —— 从 Flutter 版 bili_danmaku.dart（854 行）移植核心部分。
///
/// 接口：/x/v2/dm/wbi/web/seg.so?type=1&oid={cid}&segment_index={n}
/// 返回的是 protobuf，不是 JSON。项目里不引 protobuf 运行时（为了少一个依赖），
/// 所以这里手写一个最小的 protobuf 解码器 —— 只解 DanmakuElem 里用得到的字段。
///
/// segment_index 从 1 开始（B 站不是 0 基），这是踩过的坑。
/// </summary>
public static class BiliDanmakuService
{
    /// <summary>
    /// 取一段弹幕（protobuf 原始字节）。段不存在时返回空数组，不报错。
    /// **走 wbi 签名**：未签名的 seg.so 会被风控（表现为 code=-403 或 HTML 页）。
    /// </summary>
    public static async Task<byte[]> FetchSegmentAsync(
        BiliApi api, long cid, int segmentIndex, CancellationToken ct = default)
    {
        return await api.GetSignedBytesAsync("/x/v2/dm/wbi/web/seg.so", new Dictionary<string, string?>
        {
            ["type"] = "1",
            ["oid"] = cid.ToString(),
            ["segment_index"] = segmentIndex.ToString(),
        }, ct);
    }

    /// <summary>拉全部弹幕。段数未知时一直拉到返回空为止（上限防死循环）。</summary>
    public static async Task<List<BiliDanmaku>> FetchAllAsync(
        BiliApi api, long cid, int maxSegments = 100, CancellationToken ct = default)
    {
        var all = new List<BiliDanmaku>();
        for (var seg = 1; seg <= maxSegments; seg++)
        {
            if (ct.IsCancellationRequested) break;
            byte[] bytes;
            try { bytes = await FetchSegmentAsync(api, cid, seg, ct); }
            catch { break; }
            if (bytes.Length == 0) break;
            all.AddRange(ParseSegment(bytes));
        }
        return all;
    }

    /// <summary>解析一段 protobuf（DmSegMobileReply 里 repeated DanmakuElem elems = 1）。</summary>
    public static List<BiliDanmaku> ParseSegment(byte[] data)
    {
        var list = new List<BiliDanmaku>();
        var i = 0;
        while (i < data.Length)
        {
            var (field, wire, newPos) = ReadTag(data, i);
            if (newPos < 0) break;
            i = newPos;

            if (field == 1 && wire == 2)
            {
                var (len, pos2) = ReadVarint(data, i);
                if (pos2 < 0 || pos2 + (int)len > data.Length) break;
                var elem = ParseElem(data, pos2, (int)len);
                if (elem is not null) list.Add(elem);
                i = pos2 + (int)len;
            }
            else
            {
                i = SkipField(data, i, wire);
                if (i < 0) break;
            }
        }
        return list;
    }

    /// <summary>解析单个 DanmakuElem，字段号按 B 站 protobuf 定义。</summary>
    private static BiliDanmaku? ParseElem(byte[] data, int start, int len)
    {
        var end = start + len;
        var i = start;
        double progressMs = 0;
        var mode = 1;
        var fontSize = 25;
        long color = 0xFFFFFF;
        var text = "";

        while (i < end)
        {
            var (field, wire, newPos) = ReadTag(data, i);
            if (newPos < 0) break;
            i = newPos;

            if (field == 2 && wire == 0)
            {
                var (v, p2) = ReadVarint(data, i);
                if (p2 < 0) return null;
                progressMs = v; i = p2;
            }
            else if (field == 3 && wire == 0)
            {
                var (v, p2) = ReadVarint(data, i);
                if (p2 < 0) return null;
                mode = (int)v; i = p2;
            }
            else if (field == 4 && wire == 0)
            {
                var (v, p2) = ReadVarint(data, i);
                if (p2 < 0) return null;
                fontSize = (int)v; i = p2;
            }
            else if (field == 5 && wire == 0)
            {
                var (v, p2) = ReadVarint(data, i);
                if (p2 < 0) return null;
                color = (long)v; i = p2;
            }
            else if (field == 7 && wire == 2)
            {
                var (sl, p2) = ReadVarint(data, i);
                if (p2 < 0 || p2 + (int)sl > end) return null;
                text = Encoding.UTF8.GetString(data, p2, (int)sl);
                i = p2 + (int)sl;
            }
            else
            {
                i = SkipField(data, i, wire);
            }
            if (i < 0) break;
        }

        if (text.Length == 0) return null;
        return new BiliDanmaku(progressMs / 1000.0, mode, fontSize, color, text);
    }

    private static (int Field, int Wire, int NextPos) ReadTag(byte[] d, int i)
    {
        var (tag, pos) = ReadVarint(d, i);
        if (pos < 0) return (0, 0, -1);
        return ((int)(tag >> 3), (int)(tag & 7), pos);
    }

    private static (ulong Value, int NextPos) ReadVarint(byte[] d, int i)
    {
        ulong result = 0;
        var shift = 0;
        while (i < d.Length)
        {
            var b = d[i++];
            result |= (ulong)(b & 0x7F) << shift;
            if ((b & 0x80) == 0) return (result, i);
            shift += 7;
            if (shift >= 64) return (0, -1);
        }
        return (0, -1);
    }

    private static int SkipField(byte[] d, int i, int wire)
    {
        if (wire == 0) { var (_, p) = ReadVarint(d, i); return p; }
        if (wire == 1) return i + 8 <= d.Length ? i + 8 : -1;
        if (wire == 2)
        {
            var (len, p) = ReadVarint(d, i);
            if (p < 0) return -1;
            var np = p + (int)len;
            return np <= d.Length ? np : -1;
        }
        if (wire == 5) return i + 4 <= d.Length ? i + 4 : -1;
        return -1;
    }

    /// <summary>导出成 B 站标准 XML（播放器与弹幕工具都认）。</summary>
    public static string ToXml(IReadOnlyList<BiliDanmaku> list, long cid)
    {
        var sb = new StringBuilder();
        sb.AppendLine("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        sb.AppendLine("<i>");
        sb.AppendLine("  <chatserver>chat.bilibili.com</chatserver>");
        sb.AppendLine("  <chatid>" + cid + "</chatid>");
        sb.AppendLine("  <mission>0</mission>");
        sb.AppendLine("  <maxlimit>99999</maxlimit>");
        sb.AppendLine("  <state>0</state>");
        sb.AppendLine("  <real_name>0</real_name>");
        sb.AppendLine("  <source>k-v</source>");
        foreach (var d in list)
        {
            var p = (int)Math.Round(d.TimeSec * 1000);
            sb.AppendLine("  <d p=\"" + d.TimeSec.ToString("0.000") + "," + d.Mode + ","
                + d.FontSize + "," + d.Color + "," + p + ",0,0,0\">" + Escape(d.Text) + "</d>");
        }
        sb.AppendLine("</i>");
        return sb.ToString();
    }

    private static string Escape(string s)
        => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    /// <summary>
    /// **protobuf 解码器自测**（2026-10-29 补）。
    ///
    /// 这个解码器之前没有任何自测 —— 而它是手写的（为了不引 protobuf 运行时），
    /// 字段号、varint、wire type 全靠人肉对照 B 站定义，错一个就静默解出空列表。
    /// 这里手工拼一段**结构合法的 DmSegMobileReply 字节**，验证解出来的字段值。
    /// </summary>
    public static string ProtoSelfTest()
    {
        var sb = new StringBuilder();
        var pass = 0; var fail = 0;
        void Check(string name, bool ok, string detail = "")
        {
            if (ok) { pass++; sb.AppendLine("  PASS  " + name); }
            else { fail++; sb.AppendLine("  FAIL  " + name + "  " + detail); }
        }

        // ── 造一个 DanmakuElem ──────────────────────────────
        // 字段号按 B 站 DanmakuElem 的真实定义（和 ParseElem 里的判断必须一致）：
        //   2=progressMs(varint)  3=mode(varint)  4=fontSize(varint)
        //   5=color(varint)       7=content(string)   ← content 是 7，不是 8
        static void Varint(List<byte> buf, ulong v)
        {
            while (v >= 0x80) { buf.Add((byte)((v & 0x7F) | 0x80)); v >>= 7; }
            buf.Add((byte)v);
        }
        static void Tag(List<byte> buf, int field, int wire) => Varint(buf, (ulong)((field << 3) | wire));

        var elem = new List<byte>();
        Tag(elem, 2, 0); Varint(elem, 12345);           // progressMs = 12345
        Tag(elem, 3, 0); Varint(elem, 1);               // mode = 1（滚动）
        Tag(elem, 4, 0); Varint(elem, 25);              // fontSize = 25
        Tag(elem, 5, 0); Varint(elem, 16777215);        // color = 0xFFFFFF（field 5）
        var text = Encoding.UTF8.GetBytes("测试弹幕");
        Tag(elem, 7, 2); Varint(elem, (ulong)text.Length);   // content（field 7）
        elem.AddRange(text);

        // ── 包成 DmSegMobileReply：repeated DanmakuElem elems = 1 ──
        var msg = new List<byte>();
        Tag(msg, 1, 2); Varint(msg, (ulong)elem.Count);
        msg.AddRange(elem);

        var list = ParseSegment(msg.ToArray());
        Check("解出 1 条弹幕", list.Count == 1, "实际 " + list.Count);
        if (list.Count == 1)
        {
            var d = list[0];
            Check("TimeSec 正确（12345ms → 12.345s）", Math.Abs(d.TimeSec - 12.345) < 0.01, d.TimeSec.ToString());
            Check("mode 正确", d.Mode == 1, d.Mode.ToString());
            Check("fontSize 正确", d.FontSize == 25, d.FontSize.ToString());
            Check("color 正确", d.Color == 16777215, d.Color.ToString());
            Check("content 正确（UTF-8 中文）", d.Text == "测试弹幕", d.Text);
        }

        // ── 负控制：空数据不能崩，也不能瞎返回 ──
        Check("空数组返回空列表", ParseSegment(Array.Empty<byte>()).Count == 0);
        Check("截断数据不崩", ParseSegment(new byte[] { 0x0A, 0x7F }).Count == 0);
        Check("垃圾数据不崩", ParseSegment(new byte[] { 0xFF, 0xFF, 0xFF }).Count == 0);

        // ── 多条目 ──
        var two = new List<byte>();
        Tag(two, 1, 2); Varint(two, (ulong)elem.Count); two.AddRange(elem);
        Tag(two, 1, 2); Varint(two, (ulong)elem.Count); two.AddRange(elem);
        Check("两条能都解出来", ParseSegment(two.ToArray()).Count == 2);

        sb.AppendLine("  合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}
