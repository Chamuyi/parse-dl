using System;
using System.Runtime.InteropServices;

namespace ParseDl.Services;

/// <summary>
/// 非打包（unpackaged）应用的**任务栏身份**。
///
/// ### 为什么必须有这个（2026-10-26 实测）
/// 工程从 MSIX 打包改成非打包后，任务栏按钮变成了一个**空白方块**，
/// 鼠标悬停的名字却是对的（「解析下载器」）。查证过程：
/// - `Assets/AppIcon.ico` 本身没问题：7 档尺寸齐全（16/24/32/48/64/128/256，全 32bpp）；
/// - exe 里也**真的内嵌了**这 7 档图标（在 exe 二进制里能搜到 7 个 PNG 签名 + ICO 目录头）；
/// - `AppWindow.SetIcon("Assets/AppIcon.ico")` 也在调。
/// 所以图标文件与嵌入都没问题 —— 问题在于**窗口没有 AppUserModelID**：
/// 非打包应用如果不显式设置，Shell 无法把「这个窗口」和「那个 exe 的图标」关联起来，
/// 于是任务栏退回占位图标（一个带叉的方块）。
///
/// 修法：进程启动时调 `SetCurrentProcessExplicitAppUserModelID`。
/// 必须在任何窗口创建**之前**调用，所以在 `Main` 的最开头（见 Program.cs）。
/// </summary>
public static class TaskbarIdentity
{
    /// <summary>
    /// 应用唯一标识。格式建议 "公司.产品.版本" 这种三段式，不必与包名一致，
    /// 但要**全局唯一且稳定** —— 改了它，用户固定在任务栏的图标会失效。
    /// </summary>
    public const string AppUserModelId = "ParseDl.ParseDownloader.1";

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(
        [MarshalAs(UnmanagedType.LPWStr)] string appId);

    /// <summary>设置进程的 AppUserModelID。失败不抛异常（不影响启动）。</summary>
    public static void Apply()
    {
        try { SetCurrentProcessExplicitAppUserModelID(AppUserModelId); }
        catch { /* 老系统上可能没有这个 API，忽略 */ }
    }
}
