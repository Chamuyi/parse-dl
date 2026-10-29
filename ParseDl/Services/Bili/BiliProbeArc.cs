using System;
using System.Threading.Tasks;

namespace ParseDl.Services.Bili;

public static class BiliProbeArc
{
    /// <summary>页面内 fetch 的探针结果槽（由 BiliPage 调用时填充）。</summary>
    public static string? InPageResult;

    public static async Task<string> RunAsync()
    {
        var sb = new System.Text.StringBuilder();

        // ① 签名 + dm_img（网页版同款参数）
        var cfg = BiliConfig.Instance;
        var api = new BiliApi(cfg.EffectiveCookie);
        var pars = new System.Collections.Generic.Dictionary<string, string?>
        {
            ["mid"] = "946974", ["ps"] = "10", ["pn"] = "1", ["order"] = "pubdate",
            ["platform"] = "web", ["web_location"] = "1550101",
            ["dm_img_list"] = "[]",
            ["dm_img_str"] = "V2ViR0wgMS4wIChPcGVuR0wgRVMgMi4wIENocm9taXVtKQ",
            ["dm_cover_img_str"] = "QU5HTEUgKE5WSURJQSwgTlZJRElBIEdlRm9yY2UgR1RYIDE2NTAgKDB4MDAwMDAxOTkpIERpcmVjdDNEMTEgdnNfXzVfMF9wczVfMCwgRDNEQ09NUCB2c181XzBfcHM1XzApLCBvciBzaW1pbGFy",
        };
        try
        {
            var d = await api.GetSignedDataAsync("/x/space/wbi/arc/search", pars, default);
            sb.AppendLine("① 签名+dm_img: OK  vlist=" + (d.TryGetProperty("list", out var l) && l.TryGetProperty("vlist", out var v) && v.ValueKind == System.Text.Json.JsonValueKind.Array ? v.GetArrayLength() : -1));
        }
        catch (Exception ex) { sb.AppendLine("① 签名+dm_img: 失败 " + ex.Message); }

        // ② 纯未签名 + 真 cookie（不带 buvid3 之外的东西）
        try
        {
            var d2 = await api.GetDataPublicAsync("/x/space/wbi/arc/search?mid=946974&ps=10&pn=1&order=pubdate", default);
            sb.AppendLine("② 未签名+真cookie: OK  vlist=" + (d2.TryGetProperty("list", out var l2) && l2.TryGetProperty("vlist", out var v2) && v2.ValueKind == System.Text.Json.JsonValueKind.Array ? v2.GetArrayLength() : -1));
        }
        catch (Exception ex) { sb.AppendLine("② 未签名+真cookie: 失败 " + ex.Message); }

        // ③ 页面内 fetch 的结果（若界面已填）
        sb.AppendLine("③ 页面内 fetch: " + (InPageResult ?? "(未执行)"));

        return sb.ToString();
    }
}
