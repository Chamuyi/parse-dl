using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace ParseDl.Services.Douyin;

/// <summary>
/// 网址归一化与页面分组 —— 对齐 Flutter 版 douyin_store.dart 的
/// normalizeDouyinUrl / douyinPageKey / douyinTargetLabel。
/// </summary>
public static class DouyinUrl
{
    public const string HomeUrl = "https://www.douyin.com/";
    public const string HomeKey = "home";

    /// <summary>
    /// 把用户输入补全成可导航的网址；认不出来返回 null。
    ///
    /// 三种贴法都认：完整链接；v.douyin.com/xxxx/ 短链（WebView 自己跟 302）；
    /// 一串纯数字作品 ID。另外会从**分享口令**里把链接抠出来。
    /// </summary>
    public static string? Normalize(string? raw)
    {
        var t = (raw ?? "").Trim();
        if (t.Length == 0) return null;

        if (Regex.IsMatch(t, "^[0-9]{15,25}$"))
            return "https://www.douyin.com/video/" + t;

        // 分享口令：把链接片段抠出来（中文标点当边界）
        var m = Regex.Match(t, @"https?://[^\s，,。、；;：:）)】\]}]+");
        if (m.Success) return m.Value;

        // 剩下的只接受「长得像域名」的：必须有点号 + 顶级域，且不能夹中文/空格
        if (!Regex.IsMatch(t, @"^[A-Za-z0-9.-]+\.[A-Za-z]{2,}(:\d+)?([/?#].*)?$"))
            return null;
        return "https://" + t;
    }

    private static readonly Dictionary<string, string> PageNames = new()
    {
        ["jingxuan"] = "精选",
        ["discover"] = "推荐",
        ["recommend"] = "推荐",
        ["following"] = "关注",
        ["friend"] = "朋友",
        ["search"] = "搜索",
        ["message"] = "消息",
        ["collection"] = "收藏",
        ["like"] = "喜欢",
        ["mine"] = "我的",
    };

    /// <summary>
    /// 把 WebView 的 URL 归一成「页面分组 key」—— 抖音是单页应用，URL 上挂着一堆
    /// 追踪参数，不归一的话每点一下视频就会多出一组。
    /// </summary>
    public static string PageKey(string? url)
    {
        var raw = (url ?? "").Trim();
        if (raw.Length == 0) return HomeKey;

        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri)) return HomeKey;
        var segs = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (segs.Count == 0) return HomeKey;

        if (segs.Count >= 2)
        {
            var head = segs[0];
            if (head is "video" or "note") return "video:" + segs[1];
            if (head == "user") return "user:" + segs[1];
        }
        return segs[0];
    }

    /// <summary>分组在界面上的短标签。</summary>
    public static string PageLabel(string key)
    {
        if (key == HomeKey) return "首页";
        if (key.StartsWith("video:", StringComparison.Ordinal)) return "作品 " + key[6..];
        if (key.StartsWith("user:", StringComparison.Ordinal)) return "作者 " + key[5..];
        return PageNames.TryGetValue(key, out var n) ? n : key;
    }

    /// <summary>
    /// 目标在列表里的短标签 —— sec_uid 有 50 多个字符，整条铺在列表里会把状态挤没。
    /// </summary>
    public static string TargetLabel(string url)
    {
        string Cut(string s, int n) => s.Length <= n ? s : s[..n] + "…";

        if (!Uri.TryCreate(url ?? "", UriKind.Absolute, out var uri)) return url ?? "";
        var host = uri.Host;
        var segs = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);

        if (segs.Length >= 2)
        {
            var kind = segs[0];
            var id = segs[1];
            return kind switch
            {
                "user" => "作者 · " + Cut(id, 12),
                "video" => "作品 · " + id,
                "note" => "图文 · " + id,
                "collection" => "合集 · " + Cut(id, 12),
                "share" => "分享 · " + Cut(id, 12),
                _ => kind + " · " + Cut(id, 12),
            };
        }
        if (segs.Length == 1) return host + "/" + segs[0];
        return host.Length == 0 ? url ?? "" : host;
    }
}
