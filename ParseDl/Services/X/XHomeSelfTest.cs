using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;

namespace ParseDl.Services.X;

/// <summary>
/// X 主页自测 —— 全部离线，不联网。
///
/// 覆盖三块最容易错、又不需要网络的逻辑：
///   1. 输入归一化（用户名 / @ / 主页链接 / user_id / 认不出的串）
///   2. 分页停止条件（首次加载前 hasMore 必须为 true；三种停止条件各一例）
///   3. module 形态的时间线解析 + v1.1 降级解析（含结构残缺的负控制）
///   4. Cookie 里的 ct0 抽取
/// </summary>
public static class XHomeSelfTest
{
    /// <summary>真实结构的精简样本：媒体推文包在 TimelineTimelineModule 里。</summary>
    private static readonly string ModuleSample = string.Join("\n", new[]
    {
        "{",
        "  \"data\": {",
        "    \"user\": {",
        "      \"result\": {",
        "        \"timeline_v2\": {",
        "          \"timeline\": {",
        "            \"instructions\": [{",
        "              \"entries\": [",
        "                {",
        "                  \"content\": {",
        "                    \"entryType\": \"TimelineTimelineModule\",",
        "                    \"items\": [{",
        "                      \"item\": {",
        "                        \"itemContent\": {",
        "                          \"tweet_results\": {",
        "                            \"result\": {",
        "                              \"__typename\": \"TweetWithVisibilityResults\",",
        "                              \"tweet\": {",
        "                                \"rest_id\": \"111\",",
        "                                \"legacy\": {",
        "                                  \"full_text\": \"hello\",",
        "                                  \"created_at\": \"Sat Jan 20 21:15:36 +0000 2024\",",
        "                                  \"extended_entities\": { \"media\": [{",
        "                                    \"id_str\": \"m1\",",
        "                                    \"type\": \"photo\",",
        "                                    \"media_url_https\": \"https://pbs.twimg.com/media/M1.jpg\",",
        "                                    \"original_info\": { \"width\": 1200, \"height\": 800 }",
        "                                  }] }",
        "                                },",
        "                                \"core\": { \"user_results\": { \"result\": {",
        "                                  \"legacy\": { \"id_str\": \"u1\", \"name\": \"Nick\", \"screen_name\": \"nick\" }",
        "                                } } }",
        "                              }",
        "                            }",
        "                          }",
        "                        }",
        "                      }",
        "                    }],",
        "                    \"entryType2\": \"\"",
        "                  }",
        "                },",
        "                {",
        "                  \"content\": {",
        "                    \"entryType\": \"TimelineTimelineCursor\",",
        "                    \"cursorType\": \"Bottom\",",
        "                    \"value\": \"CURSOR_BOTTOM\"",
        "                  }",
        "                }",
        "              ]",
        "            }]",
        "          }",
        "        }",
        "      }",
        "    }",
        "  }",
        "}",
    });

    /// <summary>v1.1 降级路径样本：数组根 + entities.media + video_info.variants。</summary>
    private static readonly string V11Sample = string.Join("\n", new[]
    {
        "[{",
        "  \"id_str\": \"999\",",
        "  \"full_text\": \"v11 text\",",
        "  \"created_at\": \"Sat Jan 20 21:15:36 +0000 2024\",",
        "  \"user\": { \"id_str\": \"u9\", \"name\": \"Ann\", \"screen_name\": \"ann\" },",
        "  \"entities\": { \"media\": [",
        "    { \"id_str\": \"v1\", \"type\": \"video\",",
        "      \"media_url_https\": \"https://pbs.twimg.com/media/V1.jpg\",",
        "      \"video_info\": { \"variants\": [",
        "        { \"content_type\": \"video/mp4\", \"bitrate\": 256000, \"url\": \"https://video.twimg.com/low.mp4\" },",
        "        { \"content_type\": \"video/mp4\", \"bitrate\": 832000, \"url\": \"https://video.twimg.com/high.mp4\" },",
        "        { \"content_type\": \"application/x-mpegURL\", \"url\": \"https://video.twimg.com/x.m3u8\" }",
        "      ] },",
        "      \"sizes\": { \"large\": { \"w\": 1920, \"h\": 1080 } } }",
        "  ] }",
        "}]",
    });

    /// <summary>结构残缺样本 —— 负控制：必须返回空而不是抛异常。</summary>
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

        // ① 输入归一化
        var a1 = XHomeInput.Parse("nasa");
        Check("纯用户名", a1 is { Kind: XHomeTargetKind.ScreenName, Value: "nasa" });
        var a2 = XHomeInput.Parse("@nasa");
        Check("@ 前缀", a2 is { Kind: XHomeTargetKind.ScreenName, Value: "nasa" });
        var a3 = XHomeInput.Parse("https://x.com/nasa");
        Check("x.com 主页链接", a3 is { Kind: XHomeTargetKind.ScreenName, Value: "nasa" });
        var a4 = XHomeInput.Parse("https://twitter.com/NASA_1/");
        Check("twitter.com 链接 + 结尾斜杠", a4 is { Kind: XHomeTargetKind.ScreenName, Value: "NASA_1" });
        var a5 = XHomeInput.Parse("44196397");
        Check("纯数字按 user_id", a5 is { Kind: XHomeTargetKind.UserId, Value: "44196397" });
        Check("保留段认不出", XHomeInput.Parse("https://x.com/home") is null);
        Check("空串认不出", XHomeInput.Parse("   ") is null);
        Check("带空格认不出", XHomeInput.Parse("na sa") is null);

        // ② 分页停止条件
        var first = new XTimelinePage { Posts = new List<XPost>(), NextCursor = null };
        Check("首次加载前 HasMore 必须为 true", new XHomeStore().HasMore);
        Check("服务端无游标 → 停", !XHomeStore.PageHasMore(null, first, 0));

        var same = new XTimelinePage { Posts = new List<XPost>(), NextCursor = "C1" };
        Check("游标原地打转 → 停", !XHomeStore.PageHasMore("C1", same, 0));

        var onePage = new XTimelinePage { Posts = new List<XPost> { new() { Id = "1" } }, NextCursor = "C2" };
        Check("有内容有游标 → 继续", XHomeStore.PageHasMore("C1", onePage, 0));

        var emptyPage = new XTimelinePage { Posts = new List<XPost>(), NextCursor = "C3" };
        Check("第一页空还可再试一页", XHomeStore.PageHasMore("C2", emptyPage, 0));
        Check("连续两页空 → 停", !XHomeStore.PageHasMore("C2", emptyPage, 1));

        // ③ 解析
        using (var doc = JsonDocument.Parse(ModuleSample))
        {
            var page = XApi.ParseTimeline(doc.RootElement);
            Check("module 形态解析出 1 条", page.Posts.Count == 1, "实际 " + page.Posts.Count);
            Check("底部游标已取到", page.NextCursor == "CURSOR_BOTTOM", page.NextCursor ?? "null");
            if (page.Posts.Count == 1)
            {
                var p = page.Posts[0];
                Check("转推包装层已剥掉（rest_id 取自内层）", p.Id == "111", p.Id);
                Check("正文", p.Text == "hello", p.Text);
                Check("作者", p.UserScreenName == "nick", p.UserScreenName ?? "null");
                Check("媒体 1 条", p.Media.Count == 1, "实际 " + p.Media.Count);
                Check("图片是原图", p.Media[0].Url.EndsWith("name=orig"), p.Media[0].Url);
                Check("缩略图取 small", p.Media[0].PreviewUrl.EndsWith("name=small"), p.Media[0].PreviewUrl);
            }
        }

        using (var bad = JsonDocument.Parse(BrokenSample))
        {
            var badPage = XApi.ParseTimeline(bad.RootElement);
            Check("结构残缺返回空且不抛", badPage.Posts.Count == 0);
        }

        using (var doc = JsonDocument.Parse(V11Sample))
        {
            var page = XApi.ParseTimelineV11(doc.RootElement);
            Check("v1.1 解析出 1 条", page.Posts.Count == 1, "实际 " + page.Posts.Count);
            if (page.Posts.Count == 1)
            {
                var m = page.Posts[0].Media[0];
                Check("取最高码率 mp4", m.Url.EndsWith("high.mp4"), m.Url);
                Check("v1.1 尺寸取自 sizes.large", m.Width == 1920, m.Width?.ToString() ?? "null");
                Check("v1.1 也带缩略图", m.PreviewUrl.EndsWith("name=small"), m.PreviewUrl);
            }
        }
        Check("v1.1 收到非数组根时不抛",
            XApi.ParseTimelineV11(JsonDocument.Parse("{}").RootElement).Posts.Count == 0);

        // ④ Cookie
        Check("抽出 ct0",
            XHomeApi.ExtractCsrf("auth_token=abc; ct0=deadbeef; twid=u%3D1") == "deadbeef");
        Check("没有 ct0 返回 null", XHomeApi.ExtractCsrf("auth_token=abc") is null);
        Check("空 cookie 返回 null", XHomeApi.ExtractCsrf("") is null);
        var api = new XHomeApi("auth_token=abc");
        Check("缺 ct0 不算已登录", !api.HasLogin);

        // ⑤ 用户解析（GraphQL / v1.1 两种根）
        using (var doc = JsonDocument.Parse(
            "{\"data\":{\"user\":{\"result\":{\"rest_id\":\"42\",\"legacy\":" +
            "{\"name\":\"Nick\",\"screen_name\":\"nick\",\"profile_image_url_https\":" +
            "\"https://pbs.twimg.com/a_normal.jpg\",\"followers_count\":7}}}}}"))
        {
            var u = XHomeApi.ParseUserGraphql(doc.RootElement);
            Check("GraphQL 用户解析", u is { Id: "42", Name: "Nick", ScreenName: "nick" });
            Check("头像换成 400x400", u?.Avatar?.Contains("_400x400.jpg") == true, u?.Avatar ?? "null");
            Check("粉丝数", u?.FollowersCount == 7);
        }
        using (var doc = JsonDocument.Parse(
            "{\"id_str\":\"42\",\"name\":\"Nick\",\"screen_name\":\"nick\",\"media_count\":123}"))
        {
            var u = XHomeApi.ParseUserV11(doc.RootElement);
            Check("v1.1 用户解析", u is { Id: "42", MediaCount: 123 });
        }
        using (var doc = JsonDocument.Parse("{}"))
        {
            Check("空对象用户解析返回 null", XHomeApi.ParseUserV11(doc.RootElement) is null);
        }

        // ⑥ 状态机：去重、选择、下载范围
        var store = new XHomeStore();
        var p1 = new XPost { Id = "a", Media = new[] { new XMedia { Id = "m1" } } };
        var p2 = new XPost { Id = "b", Media = new[] { new XMedia { Id = "m2" } } };
        var p3 = new XPost { Id = "c", Media = Array.Empty<XMedia>() };   // 纯文字，应被丢弃
        store.SetUser(new XHomeUser { Id = "42", ScreenName = "nick" });
        store.Append(new XTimelinePage
        {
            Posts = new[] { p1, p2, p3 },
            NextCursor = "N1",
        }, null);
        Check("纯文字推文不入列表", store.Posts.Count == 2, "实际 " + store.Posts.Count);
        Check("累计媒体数", store.TotalMedia == 2, "实际 " + store.TotalMedia);

        store.Append(new XTimelinePage
        {
            Posts = new[] { p1, p2 },
            NextCursor = null,
        }, "N1");
        Check("重复推文已去重", store.Posts.Count == 2, "实际 " + store.Posts.Count);
        Check("无游标后不再翻页", !store.HasMore);

        Check("默认下载全部", store.PostsForDownload().Count == 2);
        store.Toggle("a");
        Check("勾选 1 条", store.SelectedCount == 1);
        Check("只下勾中的", store.PostsForDownload().Count == 1);
        store.SelectAll();
        Check("全选后只下勾中的（= 全部）", store.PostsForDownload().Count == 2);
        store.ClearSelection();
        Check("清空后回到全部", store.PostsForDownload().Count == 2);

        sb.AppendLine();
        sb.AppendLine("X 主页合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}
