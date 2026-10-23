using System;
using System.Text;
using System.Text.Json;

namespace ParseDl.Services.Douyin;

/// <summary>抖音解析自测 —— 全部离线。</summary>
public static class DouyinSelfTest
{
    /// <summary>单个作品 JSON 样本（真实结构的精简版）。</summary>
    private const string AwemeSample = "{" +
        "\"aweme_id\":\"7300000000000000001\"," +
        "\"desc\":\"测试作品\"," +
        "\"create_time\":1705737336," +
        "\"author\":{\"uid\":\"u1\",\"nickname\":\"小明\",\"unique_id\":\"xiaoming\"}," +
        "\"video\":{\"play_addr\":{\"url_list\":[\"http://v1.douyin.com/a.mp4\",\"https://v2.douyin.com/a.mp4\"]}}," +
        "\"digg_count\":100,\"comment_count\":20,\"share_count\":5}";

    /// <summary>图集作品样本（3 张图）。</summary>
    private const string ImagesSample = "{" +
        "\"aweme_id\":\"7300000000000000002\"," +
        "\"desc\":\"图集\"," +
        "\"author\":{\"uid\":\"u2\",\"nickname\":\"小红\"}," +
        "\"images\":[{" +
        "\"url_list\":[\"https://p1.douyin.com/1.jpg\"]},{" +
        "\"url_list\":[\"https://p1.douyin.com/2.jpg\"]},{" +
        "\"url_list\":[\"https://p1.douyin.com/3.jpg\"]}]}";

    /// <summary>嵌在页面里的带 _ROUTER_DATA 的 HTML 样本。</summary>
    private const string HtmlSample = "<html><head>" +
        "<script id=\"_ROUTER_DATA\" type=\"application/json\">" +
        "{\"loaderData\":{\"video_(id)/page\":{\"aweme_detail\":" +
        "{\"aweme_id\":\"7300000000000000003\",\"desc\":\"页面里的作品\"," +
        "\"author\":{\"uid\":\"u3\",\"nickname\":\"小刚\"}," +
        "\"video\":{\"play_addr\":{\"url_list\":[\"https://v.douyin.com/b.mp4\"]}}}}}}" +
        "</script></head><body></body></html>";

    public static string Run()
    {
        var sb = new StringBuilder();
        var pass = 0; var fail = 0;

        void Check(string name, bool ok, string detail = "")
        {
            if (ok) { pass++; sb.AppendLine("  PASS  " + name); }
            else { fail++; sb.AppendLine("  FAIL  " + name + "  " + detail); }
        }

        // ① 视频作品
        try
        {
            using var doc = JsonDocument.Parse(AwemeSample);
            var a = DouyinParser.ParseAweme(doc.RootElement);
            Check("视频作品解析", a is not null);
            if (a is not null)
            {
                Check("作品 id", a.Id == "7300000000000000001", a.Id);
                Check("作品描述", a.Desc == "测试作品", a.Desc);
                Check("作者昵称", a.AuthorName == "小明", a.AuthorName ?? "null");
                Check("点赞数", a.DiggCount == 100, a.DiggCount.ToString());
                Check("媒体 1 条", a.Media.Count == 1, a.Media.Count.ToString());
                Check("媒体取最后一个 CDN 且转 https",
                    a.Media.Count == 1 && a.Media[0].Url == "https://v2.douyin.com/a.mp4",
                    a.Media.Count == 1 ? a.Media[0].Url : "");
                Check("创建时间已解析", a.CreatedAt is not null);
            }
        }
        catch (Exception ex) { Check("视频作品解析不抛异常", false, ex.Message); }

        // ② 图集作品
        try
        {
            using var doc = JsonDocument.Parse(ImagesSample);
            var a = DouyinParser.ParseAweme(doc.RootElement);
            Check("图集 3 条媒体", a is not null && a.Media.Count == 3,
                a is null ? "null" : a.Media.Count.ToString());
            Check("图集序号 1/2/3",
                a is not null && a.Media.Count == 3 &&
                a.Media[0].Index == 1 && a.Media[2].Index == 3);
            Check("图集类型是 image", a is not null && a.Media.Count > 0 && a.Media[0].Type == "image");
        }
        catch (Exception ex) { Check("图集解析不抛异常", false, ex.Message); }

        // ③ 从页面 HTML 抽内嵌 JSON
        var json = DouyinParser.ExtractEmbeddedJson(HtmlSample);
        Check("从 HTML 抽出 _ROUTER_DATA", !string.IsNullOrEmpty(json));
        if (!string.IsNullOrEmpty(json))
        {
            try
            {
                using var doc = JsonDocument.Parse(json);
                var list = DouyinParser.ParseAllAwemes(doc.RootElement);
                Check("页面 JSON 里批量抽出 1 个作品", list.Count == 1, "实际 " + list.Count);
                Check("抽出作品的 id 正确",
                    list.Count == 1 && list[0].Id == "7300000000000000003");
            }
            catch (Exception ex) { Check("页面 JSON 解析不抛异常", false, ex.Message); }
        }

        // ④ 负控制：没有数据容器的 HTML 必须返回 null
        Check("无数据容器返回 null",
            DouyinParser.ExtractEmbeddedJson("<html><body>nothing</body></html>") is null);
        Check("空 HTML 返回 null", DouyinParser.ExtractEmbeddedJson("") is null);

        // ⑤ 分享文本与 URL 提取
        var shareText = "7.92 复制打开抖音，看看【小明的作品】 https://v.douyin.com/iABCdef/ 复制此链接";
        var url = DouyinParser.ExtractShareUrl(shareText);
        Check("从分享文本抽 URL", url == "https://v.douyin.com/iABCdef/", url ?? "null");
        Check("从作品页 URL 抽 id",
            DouyinParser.ExtractAwemeIdFromUrl("https://www.douyin.com/video/7300000000000000001")
                == "7300000000000000001");
        Check("非作品 URL 返回 null",
            DouyinParser.ExtractAwemeIdFromUrl("https://www.douyin.com/user/abc") is null);

        sb.AppendLine();
        sb.AppendLine("抖音解析 合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}
