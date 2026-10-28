using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;

// To learn more about WinUI, the WinUI project structure,
// and more about our project templates, see: http://aka.ms/winui-project-info.

namespace ParseDl;

/// <summary>
/// Provides application-specific behavior to supplement the default Application class.
/// </summary>
public partial class App : Application
{
    private Window? _window;

    /// <summary>当前主窗口。文件选择器要用它的 HWND 做 InitializeWithWindow，
    /// 否则 FolderPicker 在 WinUI 3 里会直接抛 COMException（没有窗口句柄）。</summary>
    public static Window? MainWindow { get; private set; }
    
    /// <summary>
    /// Initializes the singleton application object.  This is the first line of authored code
    /// executed, and as such is the logical equivalent of main() or WinMain().
    /// </summary>
    public App()
    {
        InitializeComponent();
    }

    /// <summary>
    /// Invoked when the application is launched.
    /// </summary>
    /// <param name="args">Details about the launch request and process.</param>
    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        // 诊断探针：--probe <url> —— 打开链接、抄真实载荷、落盘、退出。
        if (ParseDl.Services.Douyin.DouyinProbe.Enabled)
        {
            var probeUrl = ParseDl.Services.Douyin.DouyinProbe.Url!;
            _ = ParseDl.Services.Douyin.DouyinProbe.RunAsync(probeUrl).ContinueWith(_ =>
            {
                try { Environment.Exit(0); } catch { }
            });
            return;
        }
        // 自测入口：带 --selftest 启动时只跑离线自测、把结果写文件后退出。
        // 这样能不经界面验证纯逻辑（文件名模板等），也不会弹窗干扰用户。
        // 双通道触发：命令行参数 + 环境变量。
        // 为什么两套：打包应用用 winapp run 启动时透传不了命令行参数（实测
        // UnauthorizedAccess_IODenied_NoPathName），环境变量是唯一可靠通道。
        var cmdArgs = Environment.GetCommandLineArgs();
        var envFlag = Environment.GetEnvironmentVariable("PARSE_DL_SELFTEST");
        if (Array.IndexOf(cmdArgs, "--selftest") >= 0 || envFlag == "1")
        {
            try
            {
                var report = ParseDl.Services.FileNameTemplateSelfTest.Run()
                    + Environment.NewLine + "===== 抖音名单解析自测 =====" + Environment.NewLine
                    + ParseDl.Services.Douyin.DouyinRoster.SelfTest()
                    + Environment.NewLine + "===== 抖音模块自测（含实况图）=====" + Environment.NewLine
                    + ParseDl.Services.Douyin.DouyinModuleSelfTest.Run()
                    + Environment.NewLine + "===== 动态照片合成自测 =====" + Environment.NewLine
                    + ParseDl.Services.Douyin.MotionPhoto.SelfTest()
                    + Environment.NewLine + "===== X 关注列表解析自测 =====" + Environment.NewLine
                    + ParseDl.Services.X.XFollowingApi.SelfTest()
                    + Environment.NewLine + "===== 开发版目录锁自测 =====" + Environment.NewLine
                    + DirLockSelfTest();
                var outPath = System.IO.Path.Combine(ParseDl.Services.AppPaths.DataDir, "selftest.txt");
                System.IO.File.WriteAllText(outPath, report);
            }
            catch (Exception ex)
            {
                try
                {
                    System.IO.File.WriteAllText(
                        System.IO.Path.Combine(ParseDl.Services.AppPaths.DataDir, "selftest.txt"),
                        "自测异常: " + ex);
                }
                catch { }
            }
            Environment.Exit(0);
            return;
        }

        // 先加载设置：材质档位与明暗要在建窗时就用上，否则会先闪一下默认值再切。
        ParseDl.Services.AppSettings.Instance.Load();

        // 按「日志保留天数」清理旧日志（0 = 不删）。
        try { ParseDl.Services.Aria2Engine.PurgeOldLogs(); } catch { }

        _window = new MainWindow();
        MainWindow = _window;
        _window.Activate();
    }

    /// <summary>
    /// 开发版目录锁自测（用户 2026-10-28：「开发版数据包括下载，要严格在测试目录，就 exe 目录里面」）。
    /// 核心判据：**无论配置里写什么外部路径，Debug 版解析出来的下载目录都必须在 exe 目录内**。
    /// </summary>
    private static string DirLockSelfTest()
    {
        var sb = new System.Text.StringBuilder();
        var install = ParseDl.Services.AppPaths.InstallDir;
        sb.AppendLine("安装目录: " + install);
        sb.AppendLine("LockToInstallDir = " + ParseDl.Services.AppPaths.LockToInstallDir
            + "（Debug 应为 True）");

        var cases = new[] { "D:\\下载目录", "D:\\somewhere", "", install + "\\downloads" };
        foreach (var c in cases)
        {
            var resolved = ParseDl.Services.AppPaths.ResolveDownloadDir(c, out var locked);
            var inside = ParseDl.Services.AppPaths.IsUnder(resolved, install);
            var label = c.Length == 0 ? "<空>" : c;
            sb.AppendLine("  配置=" + label + "  →  实际=" + resolved
                + "  在exe内=" + inside + (locked ? "  [已强制改写]" : ""));
#if DEBUG
            if (!inside) sb.AppendLine("    ✘ 违反：Debug 版必须锁在 exe 目录内");
#endif
        }
        return sb.ToString();
    }
}