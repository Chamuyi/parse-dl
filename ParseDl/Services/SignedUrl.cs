using System;
using System.Globalization;
using System.Text.RegularExpressions;

namespace ParseDl.Services;

/// <summary>
/// 带时效签名的下载直链（抖音 CDN、B 站等）的过期判定。
///
/// ### 为什么需要（2026-10-31 用户报「上千个错误任务，重试后仍旧无法下载」）
///
/// 抖音的视频/图片直链长这样：
///   https://v26-web.douyinvod.com/**6ae50d65**/video/tos/cn/tos-cn-ve-15c000-ce/xxx/?a=6383...
/// 路径里那段 8 位十六进制（这里 6ae50d65）是 **Unix 秒级过期时间戳**：
///   0x6ae50d65 = 1793417061 = 2026-10-31 05:24:21
/// 到点之后 CDN 一律回 **403**，且无论怎么重试都没用 —— 链接本身已经死了，
/// 必须回页面重新抓一次拿新签名。
///
/// 实测：用户队列 5029 条全部是这种链接，签名在 05:34 过期，
/// 11:58 重启恢复时全部 403，界面上就是「上千个错误任务，点重试也没用」。
///
/// 判定策略（**保守**：只在明确过期时返回 true，判不准一律当有效）：
///   1. 能解析出签名时间戳，且已过期 → true；
///   2. 解析不出 → false（交给 aria2 去试，不能因为猜不准就把任务吞掉）。
/// </summary>
public static class SignedUrl
{
    /// <summary>抖音 CDN 域名（douyinvod / douyinpic / 等）。</summary>
    private static readonly Regex DouyinCdn = new(
        @"^https?://[^/]*(?:douyinvod|douyinpic|douyinstatic|douyincdn)\.com/",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// <summary>
    /// 抖音直链的签名时间戳段。
    ///
    /// 真实形态（2026-10-31 从用户队列取样确认）：
    ///   https://v26-web.douyinvod.com/**66c9b4062cadc768bc5f1ab5901af196**/**6ae50d65**/video/tos/...
    ///   └─ 域名 ─┘                    └─ 32 位 hex（资源哈希）┘ └ 8 位 hex = 过期时间戳
    /// 所以是「域名后第一段 32 位 hex，再紧跟 8 位 hex」——
    /// 只匹配 8 位（漏掉前面那 32 位）会一条都匹配不上。
    /// </summary>
    private static readonly Regex DouyinSig = new(
        @"^https?://[^/]+/[0-9a-fA-F]{32}/([0-9a-fA-F]{8})/",
        RegexOptions.Compiled);

    /// <summary>时钟容差：签名到点前 60 秒就当过期，避免「刚好在边界上」白试一次。</summary>
    private const int SkewSeconds = 60;

    /// <summary>这个 URL 是不是已知类型的「带时效签名直链」。</summary>
    public static bool IsSigned(string? url)
        => !string.IsNullOrEmpty(url) && DouyinCdn.IsMatch(url);

    /// <summary>签名何时过期（UTC）。解析不出来返回 null。</summary>
    public static DateTimeOffset? ExpiryOf(string? url)
    {
        if (string.IsNullOrEmpty(url)) return null;
        var m = DouyinSig.Match(url);
        if (!m.Success) return null;
        if (!long.TryParse(m.Groups[1].Value, NumberStyles.HexNumber,
                CultureInfo.InvariantCulture, out var sec)) return null;
        // 合理区间校验：2020-01-01 ~ 2100-01-01。落在外面说明这段 hex 不是时间戳
        // （可能是别的路径参数），判不准就当没有过期信息。
        if (sec < 1_577_836_800L || sec > 4_102_444_800L) return null;
        return DateTimeOffset.FromUnixTimeSeconds(sec);
    }

    /// <summary>是否**确定**已过期。判不准返回 false（保守，不吞任务）。</summary>
    public static bool IsExpired(string? url)
    {
        var exp = ExpiryOf(url);
        if (exp is null) return false;
        return DateTimeOffset.UtcNow > exp.Value.AddSeconds(-SkewSeconds);
    }

    /// <summary>给人看的过期描述，用于日志与提示。解析不出返回空串。</summary>
    public static string Describe(string? url)
    {
        var exp = ExpiryOf(url);
        if (exp is null) return "";
        var local = exp.Value.ToLocalTime();
        var tail = IsExpired(url) ? "已过期" : "有效";
        return local.ToString("MM-dd HH:mm:ss") + " " + tail;
    }
}
