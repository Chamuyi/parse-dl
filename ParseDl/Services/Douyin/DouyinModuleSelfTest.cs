using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace ParseDl.Services.Douyin;

/// <summary>
/// 抖音模块自测 —— 全部离线纯逻辑，覆盖本次移植的服务层：
/// 载荷解析 / 变体评分与选源 / 筛选 / 作品分组 / 模板展开 / 目标解析 /
/// 滚动状态机 / 台账读写 / URL 归一化。
///
/// 每条判据都带**负控制**（空载荷、未知变量、缺字段变体、无发布时间的条目…），
/// 避免「全绿」其实是因为判据本身失效。
/// </summary>
public static class DouyinModuleSelfTest
{
    private const string VideoPost = "{" +
        "\"id\":\"7300000000000000001\",\"kind\":\"video\",\"desc\":\"测试视频作品\"," +
        "\"createTime\":1705737336,\"durationMs\":45000," +
        "\"authorUid\":\"u1\",\"authorName\":\"小明\",\"authorId\":\"xiaoming\"," +
        "\"cover\":\"https://p1.douyin.com/cover.jpg\",\"tags\":[\"测试标签\"]," +
        "\"musicUrls\":[\"https://sf.douyin.com/bgm1.mp3\"]," +
        "\"videos\":[" +
        "{\"urls\":[\"https://v.douyin.com/low.mp4\"],\"kind\":\"bit_rate\",\"w\":720,\"h\":1280,\"fps\":30,\"br\":1200000,\"format\":\"mp4\",\"gear\":\"low_720p\"}," +
        "{\"urls\":[\"https://v.douyin.com/high.mp4\"],\"kind\":\"bit_rate\",\"w\":1080,\"h\":1920,\"fps\":30,\"br\":2400000,\"format\":\"mp4\",\"gear\":\"normal_1080p\"}," +
        "{\"urls\":[\"https://v.douyin.com/bvc1.mp4\"],\"kind\":\"bit_rate\",\"w\":1080,\"h\":1920,\"fps\":30,\"br\":3000000,\"format\":\"mp4\",\"gear\":\"bytevc1_1080p\",\"bytevc1\":true}," +
        "{\"urls\":[\"https://v.douyin.com/nofps.mp4\"],\"kind\":\"bit_rate\",\"w\":1080,\"h\":1920,\"fps\":0,\"br\":2600000,\"format\":\"mp4\",\"gear\":\"nofps\"}," +
        "{\"urls\":[\"https://v.douyin.com/def.mp4\"],\"kind\":\"default\",\"w\":1080,\"h\":1920,\"fps\":0,\"br\":0}," +
        "{\"urls\":[\"https://v.douyin.com/h264.mp4\"],\"kind\":\"h264\",\"w\":1080,\"h\":1920}" +
        "]," +
        "\"images\":[],\"digg\":100,\"comment\":20,\"collect\":5,\"share\":3,\"episode\":0}";

    private const string ImagePost = "{" +
        "\"id\":\"7300000000000000002\",\"kind\":\"images\",\"desc\":\"图集作品\"," +
        "\"createTime\":1705737336,\"authorUid\":\"u2\",\"authorName\":\"小红\",\"authorId\":\"xiaohong\"," +
        "\"images\":[" +
        "{\"urls\":[\"https://p1.douyin.com/1.webp\",\"https://p2.douyin.com/1.jpg\"],\"live\":[]}," +
        "{\"urls\":[\"https://p1.douyin.com/2.webp\"],\"live\":[{\"urls\":[\"https://v.douyin.com/live2.mp4\"],\"kind\":\"default\",\"w\":1080,\"h\":1920}]}" +
        "]," +
        "\"videos\":[],\"tags\":[\"图集\"],\"digg\":7," +
        "\"musicUrls\":[\"https://sf.douyin.com/bgm2.mp3\"]}";

    public static string Run()
    {
        var sb = new StringBuilder();
        var pass = 0;
        var fail = 0;

        void Check(string name, bool ok, string detail = "")
        {
            if (ok) { pass++; sb.AppendLine("  PASS  " + name); }
            else { fail++; sb.AppendLine("  FAIL  " + name + "  " + detail); }
        }

        var payload = "{\"__pd\":\"douyin\",\"items\":[" + VideoPost + "," + ImagePost + "]}";

        // ── ① 载荷解析 ───────────────────────────────────────
        var parsed = DouyinPayloadParser.Parse(payload);
        Check("载荷解析出 2 条作品", parsed.AwemeCount == 2, "实际 " + parsed.AwemeCount);
        // 视频 1 条 + 图集 2 张图 + 1 条实况配对视频 = 4
        Check("媒体展开为 4 条", parsed.Media.Count == 4, "实际 " + parsed.Media.Count);

        var video = parsed.Media.FirstOrDefault(m => m.Id == "7300000000000000001");
        Check("视频媒体存在", video is not null);
        Check("视频带封面", video?.PreviewUrl == "https://p1.douyin.com/cover.jpg", video?.PreviewUrl ?? "");
        Check("视频带 6 个变体（含 BGM）", video?.Variants.Count == 7, (video?.Variants.Count ?? 0).ToString());
        Check("视频时长 45000ms", video?.DurationMs == 45000, (video?.DurationMs ?? 0).ToString());
        Check("视频点赞数", video?.LikeCount == 100);
        Check("创建时间转本地", video?.CreatedAt is not null);

        var live = parsed.Media.FirstOrDefault(m => m.Id == "7300000000000000002_2v");
        Check("实况图产出配对视频", live is not null);
        Check("配对视频与静态图共用序号 2", live?.MediaIndex == 2, (live?.MediaIndex ?? -1).ToString());
        Check("配对视频类型是视频", live?.Type == DouyinMediaType.Video);

        var images = parsed.Media.Where(m => m.Type == DouyinMediaType.Image).ToList();
        Check("图集展开 2 张图", images.Count == 2, images.Count.ToString());
        Check("图集序号 1/2", images.Count == 2 && images[0].MediaIndex == 1 && images[1].MediaIndex == 2);

        // 负控制：空载荷 / 坏 JSON / 无 id 对象都必须返回空
        Check("空载荷返回空（负控制）", DouyinPayloadParser.Parse("").Media.Count == 0);
        Check("坏 JSON 返回空（负控制）", DouyinPayloadParser.Parse("{ this is not json").Media.Count == 0);
        Check("无 id 对象被丢弃（负控制）",
            DouyinPayloadParser.Parse("[{\"kind\":\"video\"}]").Media.Count == 0);
        Check("纯数组形态也认", DouyinPayloadParser.Parse("[" + VideoPost + "]").Media.Count == 1);

        // ── ② 变体评分与选源 ─────────────────────────────────
        var auto = DouyinSourceResolver.Weights(DouyinQualityMode.Auto);
        Check("auto 档权重是 0.4/0.2/0.4（不是 0.7 系）",
            Math.Abs(auto.Res - 0.4) < 1e-9 && Math.Abs(auto.Fps - 0.2) < 1e-9 && Math.Abs(auto.Bit - 0.4) < 1e-9);
        var res = DouyinSourceResolver.Weights(DouyinQualityMode.Resolution);
        Check("分辨率档主项权重 0.7", Math.Abs(res.Res - 0.7) < 1e-9);

        var noFps = new DouyinVariant { Width = 1080, Height = 1920, Fps = 0, Bitrate = 2600000 };
        Check("缺帧率的变体得 0 分（对 auto 也生效）",
            DouyinSourceResolver.VariantScore(noFps, DouyinQualityMode.Auto) == 0);

        var ranked = DouyinSourceResolver.RankVideoVariants(video!.Variants, DouyinQualityMode.Auto);
        Check("评分候选只保留 mp4 且可用（不要求有码率，与参照实现一致）", ranked.Count == 4, ranked.Count.ToString());
        // 缺帧率的那条得 0 分被排到最后 —— 这是「四项任一为 0 直接判 0」的既定口径
        Check("auto 档第一名是 1080p/2.4Mbps 那条，缺帧率的排最后",
            ranked[0].Bitrate == 2400000 && ranked[^1].Bitrate == 2600000,
            ranked.Count > 0 ? ranked[0].Bitrate + "/" + ranked[^1].Bitrate : "");

        var rankedNoBvc1 = DouyinSourceResolver.RankVideoVariants(video.Variants,
            DouyinQualityMode.Auto, filterByteVc1: true);
        Check("排除 ByteVC1 后 ByteVC1 变体消失",
            rankedNoBvc1.All(v => !v.ByteVc1) && rankedNoBvc1.Count == 3, rankedNoBvc1.Count.ToString());

        var rankedNoLow = DouyinSourceResolver.RankVideoVariants(video.Variants,
            DouyinQualityMode.Auto, filterLowQuality: true);
        Check("过滤低画质后 low 档消失",
            rankedNoLow.All(v => !v.Gear.Contains("low")) && rankedNoLow.Count == 3, rankedNoLow.Count.ToString());

        // default 源：不评分，取 default 字段
        var cfgDefault = new DouyinConfig();
        var rDefault = DouyinSourceResolver.Resolve(video, cfgDefault);
        Check("默认源取 play_addr", rDefault.Url == "https://v.douyin.com/def.mp4", rDefault.Url);

        // h264 源
        var cfg264 = new DouyinConfig { Source = DouyinSource.H264 };
        var r264 = DouyinSourceResolver.Resolve(video, cfg264);
        Check("H.264 源取 play_addr_h264", r264.Url == "https://v.douyin.com/h264.mp4", r264.Url);

        // 质量优先：第一名应是 2.4Mbps 那条
        var cfgQ = new DouyinConfig { Source = DouyinSource.QualityFirst };
        var rQ = DouyinSourceResolver.Resolve(video, cfgQ);
        Check("兼容性+质量优先取 2.4Mbps 那条", rQ.Url == "https://v.douyin.com/high.mp4", rQ.Url);
        Check("选中的变体被记下来（供 %BITRATE%/%FPS% 用）", rQ.Chosen is not null && rQ.Chosen.Bitrate == 2400000);

        // 指定字段缺失时退回已有候选（不产出空任务）
        var onlyDefault = new DouyinItem
        {
            Id = "x1", PostId = "x1", Source = "douyin", Type = DouyinMediaType.Video,
            Url = "https://v.douyin.com/only.mp4",
            Variants = new List<DouyinVariant>
            {
                new() { Urls = new List<string> { "https://v.douyin.com/only.mp4" }, Kind = DouyinVariantKind.BitRate },
            },
        };
        var rFallback = DouyinSourceResolver.Resolve(onlyDefault, cfg264);
        Check("H.264 字段缺失时退回已有候选（负控制）",
            rFallback.Url == "https://v.douyin.com/only.mp4", rFallback.Url);

        // 仅音频：取 BGM
        var cfgAudio = new DouyinConfig { Source = DouyinSource.AudioOnly };
        var rAudio = DouyinSourceResolver.Resolve(video, cfgAudio);
        Check("仅音频取 BGM 地址", rAudio.Url == "https://sf.douyin.com/bgm1.mp3", rAudio.Url);
        Check("仅音频把媒体类型换成 audio", rAudio.Type == DouyinMediaType.Audio);

        // 图片格式偏好：jpg 优先把 webp 排到后面
        var imageItem = images[0];
        var rKeep = DouyinSourceResolver.Resolve(imageItem, new DouyinConfig());
        Check("默认（webp）保持下发顺序", rKeep.Url == "https://p1.douyin.com/1.webp", rKeep.Url);
        var rJpg = DouyinSourceResolver.Resolve(imageItem, new DouyinConfig { ImageFormat = DouyinImageFormat.JpgFirst });
        Check("其它格式优先把 jpg 排到前面", rJpg.Url == "https://p2.douyin.com/1.jpg", rJpg.Url);
        Check("重排后备用地址仍保留原 webp", rJpg.AltUrls.Contains("https://p1.douyin.com/1.webp"));

        // ── ③ 筛选 ───────────────────────────────────────────
        var all = parsed.Media;
        var fKeyword = new DouyinFilter { Keyword = "小明" };
        Check("关键词匹配作者名", fKeyword.Matches(video!));
        Check("关键词不匹配无关条目（负控制）", !fKeyword.Matches(imageItem));

        var fDate = new DouyinFilter
        {
            DateStart = new DateTime(2024, 1, 20),
            DateEnd = new DateTime(2024, 1, 20),
        };
        Check("日期区间命中（create_time 2024-01-20 本地）", fDate.Matches(video!));

        var fNoDate = new DouyinFilter { DateStart = new DateTime(2030, 1, 1) };
        Check("超出日期区间被排除（负控制）", !fNoDate.Matches(video!));

        var fQuick = new DouyinFilter { QuickRange = DouyinDateRange.Last7 };
        Check("最近 7 天不含 2024 年的老作品（负控制）", !fQuick.Matches(video!));

        var fNoTime = new DouyinFilter { DateStart = new DateTime(2000, 1, 1) };
        var noTimeItem = new DouyinItem { Id = "nt", PostId = "nt", CreatedAt = null };
        Check("没有发布时间的条目在启用日期筛选时被排除", !fNoTime.Matches(noTimeItem));

        var fTagAny = new DouyinFilter { Tags = new HashSet<string> { "测试标签", "不存在" } };
        Check("标签「任一」命中", fTagAny.Matches(video!));
        var fTagAll = new DouyinFilter
        {
            Tags = new HashSet<string> { "测试标签", "不存在" },
            TagMode = DouyinTagMode.All,
        };
        Check("标签「全部」不命中（负控制）", !fTagAll.Matches(video!));

        var fDur = new DouyinFilter { MinDurationSec = 10, MaxDurationSec = 60 };
        Check("时长区间命中 45s", fDur.Matches(video!));
        var fDurShort = new DouyinFilter { MaxDurationSec = 10 };
        Check("时长区间外被排除（负控制）", !fDurShort.Matches(video!));
        Check("图片没有时长，启用时长筛选时被排除", !fDur.Matches(imageItem));

        var filtered = DouyinFilter.Apply(all, new DouyinFilter { Keyword = "" });
        Check("空筛选返回全部 4 条", filtered.Count == 4, filtered.Count.ToString());
        var grouped = DouyinFilter.Apply(all, new DouyinFilter());
        Check("按作品聚合后同作品连续",
            grouped.Select(m => m.PostId).Aggregate(true, (acc, id) => acc && true)
            && grouped[0].PostId == "7300000000000000001"
            && grouped[^1].PostId == "7300000000000000002");

        var facets = DouyinFilter.Facets(all);
        Check("作者候选含小明与小红的抖音号",
            facets.Authors.Contains("xiaoming") && facets.Authors.Contains("xiaohong"));

        // ── ④ 作品分组 ───────────────────────────────────────
        var groups = DouyinAwemeGroup.GroupByAweme(all);
        Check("折成 2 个作品", groups.Count == 2, groups.Count.ToString());
        var g2 = groups.FirstOrDefault(g => g.AwemeId == "7300000000000000002");
        Check("图集作品类型标签含实况", g2 is not null && g2.TypeLabel.Contains("实况"), g2?.TypeLabel ?? "");
        Check("主视频识别正确（图集没有主视频）", g2 is not null && !g2.HasMainVideo);
        var g1 = groups[0];
        Check("视频作品类型标签是「视频」", g1.TypeLabel == "视频", g1.TypeLabel);

        // ── ⑤ 模板展开 ───────────────────────────────────────
        var tplCtx = parsed.Media.First(m => m.Id == "7300000000000000001");
        var name = DouyinTemplate.Expand(DouyinTemplate.DefaultFileNameTemplate, tplCtx);
        Check("默认模板展开含作者前缀与日期",
            name.StartsWith("@小明_20240120_"), name);
        Check("默认模板主视频不带图集序号", !name.Contains("_0"), name);
        Check("默认模板带扩展名占位结果", name.EndsWith(".mp4") || name.Contains("%EXT%"), name);

        var imgItem = images[0];
        var imgName = DouyinTemplate.Expand(DouyinTemplate.DefaultFileNameTemplate, imgItem);
        Check("图集条目带 _0 序号", imgName.Contains("_0"), imgName);

        var longDesc = new DouyinItem
        {
            Id = "d1", PostId = "d1",
            Text = new string('字', 40),
            CreatedAt = new DateTime(2026, 8, 24),
            UserName = "作者甲",
        };
        var longName = DouyinTemplate.Expand("%DESCRIPTION%", longDesc);
        Check("描述默认截断 25 字并补 ...", longName.Length == 25 + 3 && longName.EndsWith("..."), longName);
        var longName60 = DouyinTemplate.Expand("%DESCRIPTION,t=60%", longDesc);
        Check("t 参数可放宽到 60 字", longName60.Length == 40, longName60.Length.ToString());
        var longNameT999 = DouyinTemplate.Expand("%DESCRIPTION,t=999%", longDesc);
        Check("t 参数上限夹到 120", longNameT999.Length == 40);

        var emptyDesc = new DouyinItem { Id = "e1", PostId = "e1", Text = "" };
        Check("空描述用作品 id 兜底",
            DouyinTemplate.Expand("%DESCRIPTION%", emptyDesc) == "e1");

        Check("作者缺失时兜底 unknown_author",
            DouyinTemplate.Expand("%AUTHOR%", emptyDesc) == "@unknown_author");
        Check("创建时间 d=1 只输出日期",
            DouyinTemplate.Expand("%CREATE_TIME,d=1%", longDesc) == "20260824");
        Check("创建时间无参数输出到秒",
            DouyinTemplate.Expand("%CREATE_TIME%", longDesc) == "20260824000000");
        Check("时间缺失时 %CREATE_TIME% 出空串",
            DouyinTemplate.Expand("[%CREATE_TIME%]", emptyDesc) == "[]");

        Check("可选段在值为空时整段消失",
            DouyinTemplate.Expand("a<-%FPS%->b", imageItem) == "ab",
            DouyinTemplate.Expand("a<-%FPS%->b", imageItem));
        Check("可选段在值非空时保留段内内容（外壳 < > 不保留）",
            DouyinTemplate.Expand("a<-%DURATION%->b", longDesc) == "a-0s-b",
            DouyinTemplate.Expand("a<-%DURATION%->b", longDesc));

        Check("未知变量原样保留（负控制）",
            DouyinTemplate.Expand("%NO_SUCH_VAR%", longDesc) == "%NO_SUCH_VAR%");

        Check("时长格式化 0s/45s/1m30s/1h2m3s",
            DouyinTemplate.FormatDurationSeconds(0) == "0s"
            && DouyinTemplate.FormatDurationSeconds(45) == "45s"
            && DouyinTemplate.FormatDurationSeconds(90) == "1m30s"
            && DouyinTemplate.FormatDurationSeconds(120) == "2m"
            && DouyinTemplate.FormatDurationSeconds(3723) == "1h2m3s");
        Check("统计数格式化 0 / 9999999+",
            DouyinTemplate.FormatStatCount(0) == "0"
            && DouyinTemplate.FormatStatCount(12) == "12"
            && DouyinTemplate.FormatStatCount(10000000) == "9999999+");
        Check("文件大小格式化（0 → 空串）",
            DouyinTemplate.FormatFileSize(0) == ""
            && DouyinTemplate.FormatFileSize(500000) == "0.5MB");

        Check("预设识别：默认值命中 author",
            DouyinTemplate.PresetIdOf("%AUTHOR%", DouyinTemplate.DefaultFileNameTemplate) == "author");
        Check("预设识别：改过就是 custom",
            DouyinTemplate.PresetIdOf("%AUTHOR%", "%DESCRIPTION%") == DouyinTemplate.CustomPresetId);

        var dirSegs = DouyinTemplate.ParseDirSegments("%AUTHOR%/../x//y");
        Check("文件夹模板拆段并丢弃 ..",
            dirSegs.Count == 3 && !dirSegs.Contains(".."), string.Join("|", dirSegs));

        var (targetDir, targetName) = DouyinTemplate.BuildTarget(tplCtx, new DouyinConfig { SaveDirBase = "C:\\tmp\\dy" });
        Check("目标目录按作者建子目录", targetDir.EndsWith("dy\\@小明"), targetDir);
        Check("目标文件名非空且无非法字符", targetName.Length > 0 && !targetName.Contains(":") && !targetName.Contains("\\"), targetName);

        // ── ⑥ 目标解析 ───────────────────────────────────────
        var targets = DouyinAutoStore.ParseTargets(
            "https://www.douyin.com/user/MS4wLjABAAAAa\n" +
            "  \n" +
            "https://www.douyin.com/video/7412345678901234567\n" +
            "7412345678901234568\n" +
            "7.32 复制打开抖音，看看【某人的作品】 https://v.douyin.com/iABCdef/ 复制此链接\n" +
            "https://www.douyin.com/video/7412345678901234567\n" +
            "这不是一个链接，只是说明文字\n");
        Check("认出 4 个目标", targets.Tasks.Count == 4, targets.Tasks.Count.ToString());
        Check("重复地址只保留一次", targets.Tasks.Count(t => t.Url.Contains("7412345678901234567")) == 1);
        Check("纯数字 ID 补成作品链接",
            targets.Tasks.Any(t => t.Url == "https://www.douyin.com/video/7412345678901234568"));
        Check("分享口令里抠出短链",
            targets.Tasks.Any(t => t.Url == "https://v.douyin.com/iABCdef/"));
        Check("认不出来的行被回显（负控制）",
            targets.Rejected.Count == 1 && targets.Rejected[0].StartsWith("这不是"), string.Join("|", targets.Rejected));
        Check("空文本没有目标", DouyinAutoStore.ParseTargets("").Tasks.Count == 0);
        var truncated = DouyinAutoStore.ParseTargets(
            "7412345678901234561\n7412345678901234562\n7412345678901234563\n7412345678901234564",
            maxTargets: 3);
        Check("上限截断：4 个目标只留 3 个并记 1 个被丢",
            truncated.Tasks.Count == 3 && truncated.Truncated == 1,
            truncated.Tasks.Count + "/" + truncated.Truncated);

        var labelTask = new DouyinAutoTask("x", "https://www.douyin.com/user/MS4wLjABAAAAabcdefghijklmn");
        Check("目标标签带类型前缀并截断",
            labelTask.Label.StartsWith("作者 · ") && labelTask.Label.Length <= 20, labelTask.Label);

        Check("URL 归一化：纯 ID", DouyinUrl.Normalize("7412345678901234567") == "https://www.douyin.com/video/7412345678901234567");
        Check("URL 归一化：裸域名补 https", DouyinUrl.Normalize("v.douyin.com/iABC/") == "https://v.douyin.com/iABC/");
        Check("URL 归一化：说明文字返回 null（负控制）", DouyinUrl.Normalize("看看这个作品") is null);
        Check("页面分组 key：作品", DouyinUrl.PageKey("https://www.douyin.com/video/123456789012345678?from=x") == "video:123456789012345678");
        Check("页面分组 key：空 → home", DouyinUrl.PageKey("https://www.douyin.com/") == "home");
        Check("页面分组 key：作者", DouyinUrl.PageKey("https://www.douyin.com/user/abc/") == "user:abc");

        // ── ⑦ 滚动状态机 ─────────────────────────────────────
        var sc = new DouyinAutoScroller(maxRounds: 5, stallLimit: 3);
        sc.Start();
        Check("第一轮之后继续", sc.OnRoundResult(1000));
        Check("高度增长不算停滞", sc.Stalls == 0);
        sc.OnRoundResult(1000);
        sc.OnRoundResult(1000);
        sc.OnRoundResult(1000);
        Check("连续 3 轮没长高 → 判到底并停止",
            !sc.Running && sc.StopReason == DouyinAutoScrollStop.NoGrowth, sc.StopReason?.ToString() ?? "null");

        var sc2 = new DouyinAutoScroller(maxRounds: 2, stallLimit: 10);
        sc2.Start();
        sc2.OnRoundResult(100);
        Check("到轮次上限 → 停止原因是「已达本次滚动上限」",
            !sc2.OnRoundResult(200) && sc2.StopReason == DouyinAutoScrollStop.ReachedMaxRounds);
        Check("1px 以内的抖动不算长高",
            new Func<bool>(() =>
            {
                var s = new DouyinAutoScroller(maxRounds: 5, stallLimit: 2);
                s.Start();
                s.OnRoundResult(100);
                s.OnRoundResult(100.5);
                return s.Stalls == 1;
            })());
        Check("停止原因中文标签齐全",
            DouyinAutoScroller.LabelOf(DouyinAutoScrollStop.NoGrowth).Contains("到底")
            && DouyinAutoScroller.LabelOf(DouyinAutoScrollStop.ReachedMaxRounds).Contains("上限"));

        // ── ⑧ 台账 ──────────────────────────────────────────
        var ledgerPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
            "pd_douyin_selftest_" + Guid.NewGuid().ToString("N") + ".json");
        var ledgerDir = System.IO.Path.GetDirectoryName(ledgerPath)!;
        Check("临时台账目录可用", System.IO.Directory.Exists(ledgerDir));

        var decode = typeof(DouyinLedger).GetMethod("Decode",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);
        Check("台账 Decode 可反射取到（下面的读写用例依赖它）", decode is not null);

        var v3 = "{\"version\":3,\"items\":{\"a1\":{\"t\":1700000000000,\"text\":\"标题\",\"user\":\"作者\"},\"a2\":{\"s\":\"pending\",\"f\":[\"gid1\"]}}}";
        var decoded = (Dictionary<string, DouyinDownloadRecord>)decode!.Invoke(null, new object[] { v3 })!;
        Check("v3 读入 2 条", decoded.Count == 2, decoded.Count.ToString());
        Check("缺省状态按已下载", decoded["a1"].IsDone);
        Check("pending 记录被认出", !decoded["a2"].IsDone);
        Check("pending 记录带任务 id", decoded["a2"].TaskIds.Contains("gid1"));

        var v2 = "{\"version\":2,\"items\":{\"b1\":{\"t\":1700000000000,\"text\":\"x\"}}}";
        Check("v2 记录也认（当已下载）",
            ((Dictionary<string, DouyinDownloadRecord>)decode.Invoke(null, new object[] { v2 })!)["b1"].IsDone);
        var v1 = "{\"c1\":true}";
        Check("v1 记录也认",
            ((Dictionary<string, DouyinDownloadRecord>)decode.Invoke(null, new object[] { v1 })!).ContainsKey("c1"));
        Check("坏数据整份丢弃（负控制）",
            ((Dictionary<string, DouyinDownloadRecord>)decode.Invoke(null, new object[] { "not json" })!).Count == 0);

        // ── ⑨ 组装（跳过已下载 / 时长 / BGM）──────────────────
        var cfgSkip = new DouyinConfig { SkipDownloaded = true };
        var assembled = DouyinStore.Assemble(all, cfgSkip, m => m.PostId == "7300000000000000001");
        Check("跳过已下载：视频那条被剔除",
            assembled.Items.All(m => m.PostId != "7300000000000000001"));
        // 4 条媒体里只有 PostId 为 ...001 的那 1 条（主视频）属于被跳过的作品
        Check("跳过已下载计数正确", assembled.SkippedDownloaded == 1, assembled.SkippedDownloaded.ToString());

        var cfgDur = new DouyinConfig { TimeRangeEnabled = true, TimeStartSec = 10, TimeEndSec = 20 };
        var assembledDur = DouyinStore.Assemble(all, cfgDur, _ => false);
        // 主视频 45s 超上限 + 实况图配对视频时长为 0（没有独立时长）→ 共 2 条
        Check("时长筛选剔掉 45s 主视频与无时长的配对视频",
            assembledDur.SkippedDuration == 2, assembledDur.SkippedDuration.ToString());
        Check("时长筛选不影响图片", assembledDur.Items.Any(m => m.Type == DouyinMediaType.Image));

        var cfgBgm = new DouyinConfig { IncludeBgm = true };
        var assembledBgm = DouyinStore.Assemble(all, cfgBgm, _ => false);
        Check("附带 BGM 时产出音频条目",
            assembledBgm.Items.Any(m => m.Type == DouyinMediaType.Audio), assembledBgm.Items.Count.ToString());
        var bgms = assembledBgm.Items.Where(m => m.Type == DouyinMediaType.Audio).ToList();
        Check("同一作品只附一条 BGM", bgms.Count == bgms.Select(m => m.PostId).Distinct().Count());
        Check("BGM 序号排在图片之后（不与图片抢 %MEDIA_INDEX%）",
            bgms.All(m => m.MediaIndex > 900));

        var cfgLiveOff = new DouyinConfig { IncludeLivePhoto = false };
        var assembledLive = DouyinStore.Assemble(all, cfgLiveOff, _ => false);
        Check("关掉实况图配对视频后配对条目不进批次",
            assembledLive.Items.All(m => !m.Id.EndsWith("v", StringComparison.Ordinal)));

        var cfgCustom = new DouyinConfig { CustomText = "我的标记" };
        var assembledCustom = DouyinStore.Assemble(all, cfgCustom, _ => false);
        Check("自定义文本写进媒体（%CUSTOM_TEXT% 才有值）",
            assembledCustom.Items.All(m => m.CustomText == "我的标记"));

        sb.AppendLine();
        sb.AppendLine("抖音模块 合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}
