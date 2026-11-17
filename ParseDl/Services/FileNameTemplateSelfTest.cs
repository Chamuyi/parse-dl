using System;
using System.Text;

namespace ParseDl.Services;

/// <summary>文件名模板自测 —— 不经界面直接验证规则，也用作回归基线。</summary>
public static class FileNameTemplateSelfTest
{
    public static string Run()
    {
        var sb = new StringBuilder();
        var pass = 0; var fail = 0;

        void Check(string name, string actual, string expected)
        {
            if (actual == expected) { pass++; sb.AppendLine("  PASS  " + name); }
            else
            {
                fail++;
                sb.AppendLine("  FAIL  " + name);
                sb.AppendLine("        期望: [" + expected + "]");
                sb.AppendLine("        实际: [" + actual + "]");
            }
        }

        var ctx = new TemplateContext
        {
            PostId = "1145141919810",
            PostTime = new DateTime(2024, 1, 20, 21, 15, 36),
            UserScreenName = "userscreenname",
            MediaId = "m1",
            Extension = "jpg",
            MediaIndex = 1,
            Content = "这是一段很长的正文内容用来测试截断",
        };

        Check("普通替换",
            FileNameTemplate.Resolve("%POST_ID%-%MEDIA_INDEX%%EXT%", ctx),
            "1145141919810-1.jpg");
        Check("时间格式",
            FileNameTemplate.Resolve("%POST_TIME%", ctx),
            "2024-01-20 21-15-36");
        Check("时间仅日期 POST_TIME,d=1",
            FileNameTemplate.Resolve("%POST_TIME,d=1%", ctx),
            "2024-01-20");
        Check("非法字符清洗",
            FileNameTemplate.UnicodeFilenamify("a<b>c:d\"e/f\\g|h?i*j"),
            "a!b!c!d!e!f!g!h!i!j");
        Check("保留名补叹号", FileNameTemplate.UnicodeFilenamify("CON"), "CON!");
        Check("内容截断 CONTENT,t=4",
            FileNameTemplate.Resolve("%CONTENT,t=4%", ctx),
            "这是一段");
        Check("可选段有空值则整段丢弃",
            FileNameTemplate.Resolve("a<-%USER_ID%->b", ctx),
            "ab");
        // 尖括号是可选段标记本身，展开时会被去掉 —— 只剩中间的字面字符与变量值。
        // 这条期望值第一版写成了 "a<-1145141919810->b"，是**测试写错**，
        // 对照 Flutter 版 test/template_optional_segment_test.dart:27
        // （'a<%USER_NAME%>b' → 'a这是用户昵称b'）后确认实现无误。
        Check("可选段有值则保留（尖括号被去掉）",
            FileNameTemplate.Resolve("a<-%POST_ID%->b", ctx),
            "a-1145141919810-b");
        Check("可选段只扫模板不扫注入结果",
            FileNameTemplate.Resolve("%USER_NAME%<%POST_ID%>",
                new TemplateContext { PostId = "42", UserName = "a<b>c" }, perVar: x => x),
            "a<b>c42");
        Check("不成对的尖括号原样保留",
            FileNameTemplate.Resolve("a<b", ctx, perVar: x => x),
            "a<b");
        Check("未知变量原样保留",
            FileNameTemplate.Resolve("%NOT_A_VAR%", ctx),
            "%NOT_A_VAR%");
        Check("emoji 不被切半",
            FileNameTemplate.UnicodeSubstring("\U0001F642\U0001F643\U0001F600", 0, 2),
            "\U0001F642\U0001F643");
        Check("抖音清洗保留中文与字母数字",
            FileNameTemplate.DouyinFilenamify("测试 标题!! 2024"),
            "测试_标题_2024");
        Check("抖音清洗纯日文不归零", FileNameTemplate.DouyinFilenamify("テスト"), "テスト");
        Check("抖音清洗空串用兜底", FileNameTemplate.DouyinFilenamify("!!!", "fallback"), "fallback");
        Check("目录段丢弃 ..",
            string.Join("|", FileNameTemplate.ParseDirSegments("a/../b/c")),
            "a|b|c");

        // ── 目录段 Windows 净化（2026-10-31 修大批 Download aborted）────
        // 抖音昵称可以以点结尾：Windows 建目录时悄悄吃掉尾点，
        // aria2 仍按原串拼路径 → errorCode=16 / The system cannot find the path specified。
        Check("目录段去掉尾部点",
            FileNameTemplate.SanitizeDirSegment("@示例作者.."),
            "@示例作者");
        Check("目录段去掉尾部空格",
            FileNameTemplate.SanitizeDirSegment("@abc  "),
            "@abc");
        Check("目录段非法字符换下划线",
            FileNameTemplate.SanitizeDirSegment("a:b*c?d"),
            "a_b_c_d");
        Check("目录段保留名补下划线",
            FileNameTemplate.SanitizeDirSegment("CON"),
            "CON_");
        Check("模板拆段同时净化尾点",
            string.Join("|", FileNameTemplate.ParseDirSegments("@示例作者../sub")),
            "@示例作者|sub");
        Check("整条路径逐段净化（盘符保留）",
            FileNameTemplate.CleanDirPath(@"D:\下载\测试\@示例作者.."),
            @"D:\下载\测试\@示例作者");

        // ── %TAGS%（2026-10-31 补，X 侧变量）──────────────────────
        var tagCtx = new TemplateContext
        {
            Tags = new[] { "女高", "自拍" },
            Content = "正文",
        };
        Check("TAGS 逗号连接（不含 #）",
            FileNameTemplate.Resolve("%TAGS%", tagCtx),
            "女高,自拍");
        Check("TAGS 为空时出空串",
            FileNameTemplate.Resolve("[%TAGS%]", new TemplateContext()),
            "[]");

        // ── X 扩展名判定必须与 Flutter 版一致（2026-10-31 修）──────
        // Flutter 的 %EXT% 先看下载链接真实后缀，再退回媒体类型。
        Check("X 图片 .png 链接 → .png（不是一律 jpg）",
            X.XNaming.ExtensionFor(new X.XMedia
            {
                Type = "image",
                Url = "https://pbs.twimg.com/media/ABC123.png?name=orig",
            }),
            "png");
        Check("X 图片无后缀链接 → jpg",
            X.XNaming.ExtensionFor(new X.XMedia
            {
                Type = "image",
                Url = "https://pbs.twimg.com/media/ABC123?format=jpg&name=orig",
            }),
            "jpg");
        Check("X 视频 → mp4",
            X.XNaming.ExtensionFor(new X.XMedia
            {
                Type = "video",
                Url = "https://video.twimg.com/amplify_video/1/vid/avc1/720x1280/x.mp4?tag=16",
            }),
            "mp4");

        // ── 带时效签名直链的过期判定（2026-10-31 加，用户报「上千错误任务重试无效」）──
        // 真实取样：https://v26-web.douyinvod.com/<32hex>/<8hex>/video/tos/...
        // 其中 8 位 hex 是过期时间戳。0x6ae50d65 = 2026-10-31 05:24（已过期）。
        var expiredUrl = "https://v26-web.douyinvod.com/66c9b4062cadc768bc5f1ab5901af196/"
                       + "6ae50d65/video/tos/cn/x/?a=6383";
        Check("过期直链判定为已过期", SignedUrl.IsExpired(expiredUrl).ToString(), "True");
        Check("过期直链能解出签名时间",
            SignedUrl.Describe(expiredUrl).EndsWith("已过期") ? "已过期" : SignedUrl.Describe(expiredUrl),
            "已过期");
        // 未过期：取一个远期时间戳（0x7fffffff = 2038-01-19）
        var aliveUrl = "https://v26-web.douyinvod.com/66c9b4062cadc768bc5f1ab5901af196/"
                     + "7fffffff/video/tos/cn/x/?a=6383";
        Check("未过期直链不误判", SignedUrl.IsExpired(aliveUrl).ToString(), "False");
        Check("非 CDN 链接不误判", SignedUrl.IsExpired("https://example.com/a.jpg").ToString(), "False");
        Check("空链接不误判", SignedUrl.IsExpired("").ToString(), "False");
        // 32 位那段很像时间戳但位置不对，必须看第 2 段
        Check("只看第二段（不看资源哈希）",
            SignedUrl.ExpiryOf(expiredUrl)?.ToUnixTimeSeconds().ToString(), "1793396069");

        sb.AppendLine();
        sb.AppendLine("合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}