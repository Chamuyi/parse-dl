using System.Text;

namespace ParseDl.Services;

/// <summary>
/// 全部离线自测的总入口 —— 关于页「运行自测」按钮调它。
/// 只放**不联网**的纯逻辑测试：网络相关的验证要单独做，否则一次失败分不清是
/// 代码错还是网断了。
/// </summary>
public static class SelfTestSuite
{
    public static string RunAll()
    {
        var sb = new StringBuilder();
        sb.AppendLine("===== 文件名模板 =====");
        sb.AppendLine(FileNameTemplateSelfTest.Run());
        sb.AppendLine("===== B 站链接解析 =====");
        sb.AppendLine(Bili.BiliLinkSelfTest.Run());
        sb.AppendLine("===== X 时间与媒体解析 =====");
        sb.AppendLine(X.XApiSelfTest.Run());
        sb.AppendLine("===== 抖音解析 =====");
        sb.AppendLine(Douyin.DouyinSelfTest.Run());
        return sb.ToString();
    }
}