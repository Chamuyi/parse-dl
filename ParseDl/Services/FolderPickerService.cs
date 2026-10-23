using System;
using System.Threading.Tasks;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace ParseDl.Services;

/// <summary>
/// 文件夹选择器 —— 解决 MSIX 打包应用写不了任意磁盘目录的问题。
///
/// 为什么需要它：打包应用（即使声明了 runFullTrust）在部分环境下对
/// 用户任意路径的写入会被拦；而通过 <see cref="FolderPicker"/> 选中的目录，
/// 系统会授予应用对该 <see cref="StorageFolder"/> 的访问权。
///
/// WinUI 3 的关键点：**必须先 InitializeWithWindow 传 HWND**，
/// 否则 PickSingleFolderAsync 会抛 COMException（0x80070578 无效窗口句柄）。
/// </summary>
public static class FolderPickerService
{
    /// <summary>弹出文件夹选择器。用户取消返回 null。</summary>
    public static async Task<StorageFolder?> PickAsync(string? startPath = null)
    {
        var picker = new FolderPicker
        {
            SuggestedStartLocation = PickerLocationId.Downloads,
            CommitButtonText = "选择此文件夹",
        };
        // FolderPicker 必须至少有一个 FileTypeFilter，否则抛异常
        picker.FileTypeFilter.Add("*");

        var hwnd = WindowNative.GetWindowHandle(App.MainWindow);
        InitializeWithWindow.Initialize(picker, hwnd);

        return await picker.PickSingleFolderAsync();
    }

    /// <summary>
    /// 校验目录是否**真能写**。只建目录不够 —— 权限问题常在写入时才暴露。
    /// 返回 (可用, 说明)。
    /// </summary>
    public static (bool Ok, string Message) VerifyWritable(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return (false, "路径为空");
        try
        {
            System.IO.Directory.CreateDirectory(path);
            var probe = System.IO.Path.Combine(path, ".parse_dl_write_probe");
            System.IO.File.WriteAllText(probe, "ok");
            System.IO.File.Delete(probe);
            return (true, "可写");
        }
        catch (Exception ex)
        {
            return (false, $"{ex.GetType().Name}: {ex.Message}");
        }
    }
}
