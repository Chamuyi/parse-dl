using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace ParseDl.Services.Bili;

/// <summary>wbi 签名算不出来时的异常（只有「算不出来」这一类；网络与业务错误由 BiliApi 抛）。</summary>
public sealed class BiliWbiException : Exception
{
    public BiliWbiException(string message) : base(message) { }
}

/// <summary>
/// WBI 签名 —— B 站 web 接口的请求签名，**纯计算层，不发请求**。
/// 从 Flutter 版 lib/services/bili_wbi.dart 移植。
///
/// 算法（照 B 站前端那份 JS）：
///   1. nav 返回两个图片地址，去掉扩展名的文件名就是 img_key / sub_key；
///   2. 两串拼成 64 位，按 MixinKeyEncTab 逐位重排，截前 32 位得 mixinKey；
///   3. 参数补 wts（秒级时间戳）后按 key 字典序排，值里剔除 ! ' ( ) *，
///      urlencode，md5(query + mixinKey) 就是 w_rid。
///
/// **为什么单独一层**：签名是「给一组参数、得一个签名」的纯函数，能拿已知向量离线钉死；
/// 取密钥、缓存、重试是另一件事。任何一处排序或转义写错，表现都是 -403「风控」
/// 这种与网络毫无关系的错误 —— 只有把算法关在自测里才防得住。
/// </summary>
public static class BiliWbi
{
    /// <summary>固定重排表（64 项）。服务端只换密钥不换表，所以这张表不是配置项。</summary>
    public static readonly int[] MixinKeyEncTab =
    {
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
    };

    /// <summary>表里最大下标是 63，所以两个 key 拼起来至少要 64 个字符才够取。</summary>
    public const int KeySourceLength = 64;

    /// <summary>mixinKey 定长 32 位。</summary>
    public const int MixinKeyLength = 32;

    /// <summary>签名前要剔除的字符码点：! ' ( ) *。这五个在 JS 与 C# 的转义规则里不一致。</summary>
    private static readonly HashSet<int> StrippedChars = new() { 0x21, 0x27, 0x28, 0x29, 0x2A };

    /// <summary>拼出 mixinKey。key 不够长时抛可读中文而不是让下标越界。</summary>
    public static string MixinKey(string imgKey, string subKey)
    {
        var source = imgKey + subKey;
        if (source.Length < KeySourceLength)
        {
            throw new BiliWbiException(
                "wbi 签名密钥不足：img_key + sub_key 只有 " + source.Length + " 个字符，" +
                "需要 " + KeySourceLength + " 个（通常是 nav 接口没返回 wbi_img）");
        }
        var sb = new StringBuilder(MixinKeyEncTab.Length);
        foreach (var index in MixinKeyEncTab) sb.Append(source[index]);
        return sb.ToString().Substring(0, MixinKeyLength);
    }

    /// <summary>拼 query。**排序与编码方式都参与签名**，所以签名与发请求共用这一个函数。</summary>
    public static string Query(IReadOnlyDictionary<string, string?> p)
    {
        var keys = p.Where(kv => kv.Value is not null)
                    .Select(kv => kv.Key)
                    .OrderBy(k => k, StringComparer.Ordinal);
        var sb = new StringBuilder();
        foreach (var k in keys)
        {
            if (sb.Length > 0) sb.Append('&');
            sb.Append(Encode(k)).Append('=').Append(Encode(p[k]!));
        }
        return sb.ToString();
    }

    /// <summary>
    /// 给参数签名，返回**新**字典（含 w_rid 与 wts，值一律是剔除特殊字符之后的字符串）。
    ///
    /// 为什么结果里放过滤后的值：签名算的是「过滤 + 编码之后的 query」，
    /// 请求发出去的也必须是同一串字节，服务端才会重算出同一个 w_rid。
    /// </summary>
    /// <param name="wts">可注入 —— 已知向量自测要的正是「同样的输入 → 同样的签名」。</param>
    public static Dictionary<string, string?> Sign(
        IReadOnlyDictionary<string, string?> parameters, string mixinKey, long? wts = null)
    {
        var signed = new Dictionary<string, string?>(StringComparer.Ordinal);
        foreach (var kv in parameters)
        {
            if (kv.Value is null) continue;
            signed[kv.Key] = Strip(kv.Value);
        }
        signed["wts"] = (wts ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds()).ToString();
        var query = Query(signed);
        var digest = MD5.HashData(Encoding.UTF8.GetBytes(query + mixinKey));
        signed["w_rid"] = Convert.ToHexString(digest).ToLowerInvariant();
        return signed;
    }

    /// <summary>
    /// 从 nav 的 img_url / sub_url 取出 key（文件名去扩展名）。
    /// 地址形如 https://i0.hdslb.com/bfs/face/xxx.jpg，也见过带 query 的形态，
    /// 所以先剥 # 与 ? 再取后缀 —— 顺序反了会把鉴权参数当文件名。
    /// </summary>
    public static string KeyFromUrl(string url)
    {
        if (string.IsNullOrEmpty(url)) return "";
        var path = url.Split('#')[0].Split('?')[0];
        var slash = path.LastIndexOf('/');
        var name = slash < 0 ? path : path.Substring(slash + 1);
        var dot = name.LastIndexOf('.');
        return dot <= 0 ? name : name.Substring(0, dot);
    }

    private static string Strip(string value)
    {
        var sb = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            if (StrippedChars.Contains(ch)) continue;
            sb.Append(ch);
        }
        return sb.ToString();
    }

    /// <summary>
    /// 与 Python urlencode（quote_plus）逐字符等价：空格转 +、~ 不转义、其余按 UTF-8 大写十六进制。
    /// 换成 Uri.EscapeDataString 原样会把空格转成 %20，签名立刻对不上 ——
    /// 这是最容易踩且最难从错误信息倒查出来的一条。
    /// </summary>
    private static string Encode(string s) => Uri.EscapeDataString(s).Replace("%20", "+");
}

/// <summary>wbi 签名自测 —— 纯离线，不联网。用已知向量钉住算法。</summary>
public static class BiliWbiSelfTest
{
    public static string Run()
    {
        var sb = new StringBuilder();
        var pass = 0; var fail = 0;
        void Check(string name, bool ok, string detail = "")
        {
            if (ok) { pass++; sb.AppendLine("  PASS  " + name); }
            else { fail++; sb.AppendLine("  FAIL  " + name + (detail.Length > 0 ? "  " + detail : "")); }
        }

        // ① 重排表本身：64 项、恰好覆盖 0..63 各一次
        Check("重排表 64 项", BiliWbi.MixinKeyEncTab.Length == 64);
        Check("重排表是 0..63 的排列",
            BiliWbi.MixinKeyEncTab.OrderBy(x => x).SequenceEqual(Enumerable.Range(0, 64)));

        // ② key 提取
        Check("从图片地址取 key",
            BiliWbi.KeyFromUrl("https://i0.hdslb.com/bfs/face/abcdef0123.jpg") == "abcdef0123",
            BiliWbi.KeyFromUrl("https://i0.hdslb.com/bfs/face/abcdef0123.jpg"));
        Check("带 query 的图片地址取 key",
            BiliWbi.KeyFromUrl("https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png?x=1") == "7cd084941338484aae1ad9425b84077c");

        // ③ mixinKey：短 key 必须抛可读中文而不是下标越界
        var shortKeyThrew = false;
        try { BiliWbi.MixinKey("abc", "def"); }
        catch (BiliWbiException) { shortKeyThrew = true; }
        Check("短 key 抛 BiliWbiException", shortKeyThrew);

        var imgKey = "7cd084941338484aae1ad9425b84077c";
        var subKey = "4932caff0ff746eab6f01bf08b70ac45";
        var mixin = BiliWbi.MixinKey(imgKey, subKey);
        Check("mixinKey 定长 32", mixin.Length == 32, mixin);
        Check("mixinKey 与已知向量一致",
            mixin == "ea1db124af3c7062474693fa704f4ff8", mixin);

        // ④ 签名：同输入同签名（wts 可注入）
        var p = new Dictionary<string, string?>
        {
            ["foo"] = "114",
            ["bar"] = "514",
            ["zab"] = "1919810",
        };
        var s1 = BiliWbi.Sign(p, mixin, wts: 1702204169);
        var s2 = BiliWbi.Sign(p, mixin, wts: 1702204169);
        Check("同输入同签名", s1["w_rid"] == s2["w_rid"]);
        Check("已知向量 w_rid", s1["w_rid"] == "8f6f2b5b3d485fe1886cec6a0be8c5d4", s1["w_rid"] ?? "");
        Check("wts 写进结果", s1["wts"] == "1702204169");

        // ⑤ 剔除 ! ' ( ) *
        var p2 = new Dictionary<string, string?> { ["a"] = "x!y'z(w)v*u" };
        var s3 = BiliWbi.Sign(p2, mixin, wts: 1);
        Check("剔除五个特殊字符", s3["a"] == "xyzwvu", s3["a"] ?? "");

        // ⑥ query 排序（字典序）且空格转 +
        var q = BiliWbi.Query(new Dictionary<string, string?> { ["b"] = "2", ["a"] = "1 2" });
        Check("query 排序 + 空格转 +", q == "a=1+2&b=2", q);

        // ⑦ null 值跳过
        var s4 = BiliWbi.Sign(new Dictionary<string, string?> { ["a"] = "1", ["b"] = null }, mixin, wts: 1);
        Check("null 值不进签名", !s4.ContainsKey("b"));

        sb.AppendLine();
        sb.AppendLine("BiliWbi 合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}
