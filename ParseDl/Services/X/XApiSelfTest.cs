using System;
using System.Text;
using System.Text.Json;

namespace ParseDl.Services.X;

/// <summary>X 解析自测 —— 全部离线，不联网。</summary>
public static class XApiSelfTest
{
    /// <summary>
    /// 时间线响应样本。这是**真实结构的精简版**：只保留了路径上必须存在的节点，
    /// 用来验证「逐层下钻 + 找不到就跳过」这条逻辑，比 mock 假对象更接近线上。
    /// </summary>
    /// <summary>
    /// 时间线响应样本。真实结构的精简版，逐行缩进写以便核对括号配对 ——
    /// 上一版压成一行时括号数错了，导致样本本身不是合法 JSON，测试反而失败。
    /// </summary>
    private static readonly string TimelineSample = string.Join("\n", new[]
    {
        "{",
        "  \"data\": {",
        "    \"user\": {",
        "      \"result\": {",
        "        \"timeline_v2\": {",
        "          \"timeline\": {",
        "            \"instructions\": [{",
        "              \"entries\": [{",
        "                \"content\": {",
        "                  \"itemContent\": {",
        "                    \"tweet_results\": {",
        "                      \"result\": {",
        "                        \"rest_id\": \"1234567890\",",
        "                        \"legacy\": {",
        "                          \"full_text\": \"hello world\",",
        "                          \"created_at\": \"Sat Jan 20 21:15:36 +0000 2024\",",
        "                          \"extended_entities\": {",
        "                            \"media\": [{",
        "                              \"id_str\": \"m1\",",
        "                              \"type\": \"photo\",",
        "                              \"media_url_https\": \"https://pbs.twimg.com/media/M1.jpg\",",
        "                              \"original_info\": { \"width\": 1200, \"height\": 800 }",
        "                            }]",
        "                          }",
        "                        },",
        "                        \"core\": {",
        "                          \"user_results\": {",
        "                            \"result\": {",
        "                              \"legacy\": {",
        "                                \"id_str\": \"u1\",",
        "                                \"name\": \"Nick\",",
        "                                \"screen_name\": \"nick\"",
        "                              }",
        "                            }",
        "                          }",
        "                        }",
        "                      }",
        "                    }",
        "                  }",
        "                }",
        "              }]",
        "            }]",
        "          }",
        "        }",
        "      }",
        "    }",
        "  }",
        "}",
    });
    /// <summary>结构残缺的样本：用来验证「不抛异常、返回空」。负控制。</summary>
    private const string BrokenSample = "{\"data\":{\"user\":{}}}";

    public static string Run()
    {
        var sb = new StringBuilder();
        var pass = 0; var fail = 0;

        void Check(string name, bool ok, string detail = "")
        {
            if (ok) { pass++; sb.AppendLine("  PASS  " + name); }
            else { fail++; sb.AppendLine("  FAIL  " + name + "  " + detail); }
        }

        Check("图片 URL 换 orig",
            XApi.NormalizeImageUrl("https://pbs.twimg.com/media/ABC.jpg?name=small")
                == "https://pbs.twimg.com/media/ABC.jpg?name=orig");
        Check("无 name 参数时补上",
            XApi.NormalizeImageUrl("https://pbs.twimg.com/media/ABC.jpg")
                == "https://pbs.twimg.com/media/ABC.jpg?name=orig");
        Check("非 twimg 域名不动",
            XApi.NormalizeImageUrl("https://example.com/a.jpg") == "https://example.com/a.jpg");

        // **限流的错误映射必须认得出来**（2026-11-03 加）。
        //
        // 用户实测界面上一片「失败：网络错误：被 X 限流（429），稍后再试」。
        // 成因是 GetJsonAsync 重试耗尽后把 429 包进了「网络错误：…」，
        // 状态码被丢掉，上游既认不出限流、也无法据此排队重试。
        // 下面钉死三条：429 带状态码、MapError 给可操作提示、非 429 不被误判。
        var rl = new XHomeException("被 X 限流", 429);
        Check("429 带状态码（供重排判定）", rl.StatusCode == 429);
        Check("429 的界面提示可操作",
            XHomeApi.MapError(rl).Contains("429") || XHomeApi.MapError(rl).Contains("频繁"),
            XHomeApi.MapError(rl));
        Check("401 不会被误判成限流",
            new XHomeException("登录已失效", 401).StatusCode != 429);

        // **断言必须与时区无关**（2026-11-01 改）。
        //
        // 原来这两条钉的是「Hour == 21 / == 13」——那是**返回 UTC 时**才成立的期望值。
        // 现在 ParseTwitterTime 按 Flutter 版口径统一转本地时区（toLocal），
        // 在本机（UTC+8）21:15 UTC 会变成次日 05:15，旧断言必然红。
        // 硬钉某个小时等于把测试绑死在本机时区上 —— 换台机器又会红。
        // 改成校验「换算后的 UTC 时刻」，与时区无关。
        var t = XApi.ParseTwitterTime("Sat Jan 20 21:15:36 +0000 2024");
        Check("Twitter 时间解析（UTC 时刻正确）",
            t is not null
            && t.Value.ToUniversalTime() == new DateTime(2024, 1, 20, 21, 15, 36, DateTimeKind.Utc),
            t?.ToUniversalTime().ToString("o") ?? "null");
        Check("时区偏移 +0800 换算成 UTC 13:15",
            XApi.ParseTwitterTime("Sat Jan 20 21:15:36 +0800 2024")?.ToUniversalTime()
                == new DateTime(2024, 1, 20, 13, 15, 36, DateTimeKind.Utc));
        Check("解析结果统一为本地时区",
            t is not null && t.Value.Kind == DateTimeKind.Local,
            t is null ? "null" : t.Value.Kind.ToString());
        Check("垃圾时间返回 null", XApi.ParseTwitterTime("not a date") is null);
        Check("空时间返回 null", XApi.ParseTwitterTime("") is null);

        try
        {
            using var doc = JsonDocument.Parse(TimelineSample);
            var page = XApi.ParseTimeline(doc.RootElement);
            Check("时间线解析出 1 条", page.Posts.Count == 1, "实际 " + page.Posts.Count);
            if (page.Posts.Count == 1)
            {
                var p = page.Posts[0];
                Check("推文 id", p.Id == "1234567890", p.Id);
                Check("推文正文", p.Text == "hello world", p.Text);
                Check("作者昵称", p.UserName == "Nick", p.UserName ?? "null");
                Check("媒体 1 条", p.Media.Count == 1, "实际 " + p.Media.Count);
                Check("媒体 URL 已归一化",
                    p.Media.Count == 1 && p.Media[0].Url.EndsWith("name=orig"),
                    p.Media.Count == 1 ? p.Media[0].Url : "");
                Check("媒体尺寸", p.Media.Count == 1 && p.Media[0].Width == 1200);
                Check("时间已解析", p.CreatedAt?.Year == 2024);

                // **时间必须是本地时区**（2026-11-01 修「X 跳过已下载失效」）。
                // Flutter 版 parseTwitterCreatedAt 返回 toLocal() 之后的时间，
                // C# 原来返回 UTC → 同一作品两边文件名差 8 小时 → 按完整路径判「没下过」
                // → 整批重复下载。实测用户队列 1390 条里 1125 条加 8h 才命中磁盘文件。
                var ct = p.CreatedAt!.Value;
                Check("时间已转本地时区（Kind=Local）",
                    ct.Kind == DateTimeKind.Local, ct.Kind.ToString());
                Check("时间换算与 UTC 一致",
                    ct.ToUniversalTime() == DateTime.Parse(
                        "2024-01-20T21:15:36Z", null,
                        System.Globalization.DateTimeStyles.AdjustToUniversal),
                    ct.ToUniversalTime().ToString("o"));
            }
        }
        catch (Exception ex)
        {
            Check("时间线样本解析不抛异常", false, ex.Message);
        }

        // 负控制：结构残缺时必须返回空而不是抛异常
        try
        {
            using var bad = JsonDocument.Parse(BrokenSample);
            var badPage = XApi.ParseTimeline(bad.RootElement);
            Check("结构残缺样本返回空且不抛异常", badPage.Posts.Count == 0);
        }
        catch (Exception ex)
        {
            Check("结构残缺样本返回空且不抛异常", false, ex.Message);
        }

        sb.AppendLine();
        sb.AppendLine("X API 合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}