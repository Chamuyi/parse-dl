using System;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace ParseDl;

/// <summary>
/// 应用入口 —— **自己写 Main 而不是用 XAML 自动生成的**，原因见下。
///
/// 非打包（unpackaged）应用必须在**创建任何窗口之前**设置进程的 AppUserModelID，
/// 否则任务栏无法把这个窗口和 exe 的图标关联，会显示一个带叉的占位方块
/// （2026-10-26 用户报「图标不对」就是这个）。自动生成的 Main 里没有插入点，
/// 所以关掉自动生成（csproj 里 DISABLE_XAML_GENERATED_MAIN），在这里手动做全套初始化。
///
/// 顺序不能变：
/// 1. AppUserModelID —— 越早越好，先于任何窗口；
/// 2. WinRT apartment 初始化（COM apartment）；
/// 3. WinAppSDK bootstrapper 自初始化（非打包应用必需，否则 XAML 控件起不来）；
/// 4. DispatcherQueue 控制器；
/// 5. 启动 Application。
/// </summary>
public static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        // 1) 任务栏身份：必须最先设置
        Services.TaskbarIdentity.Apply();

        // 2) WinRT 初始化 + COM apartment
        global::WinRT.ComWrappersSupport.InitializeComWrappers();

        // 3) WinAppSDK bootstrapper —— **不要在这里手动调**。
        //    csproj 里 WindowsAppSdkBootstrapInitialize=true 已经让构建注入
        //    「模块初始化器」，它在 Main 之前就完成 bootstrap。再手调一次会抛
        //    COMException 0x80040014（2026-10-26 实测踩过）。
        // 4) UI 线程的 DispatcherQueue
        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            System.Threading.SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
    }
}
