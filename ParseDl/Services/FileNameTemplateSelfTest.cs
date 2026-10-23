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

        sb.AppendLine();
        sb.AppendLine("合计: 通过 " + pass + ", 失败 " + fail);
        return sb.ToString();
    }
}