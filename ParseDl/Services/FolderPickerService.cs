using System;
using System.Threading.Tasks;
using Microsoft.Windows.Storage.Pickers;

namespace ParseDl.Services;

/// <summary>
/// 文件夹选择器。
///
/// ### 2026-10-31 改用 WinAppSDK 2.x 新版 Pickers API（用户报「抖音设置里点选择文件夹报错」）
///
/// 旧实现用的是 UWP 那套 `Windows.Storage.Pickers.FolderPicker` +
/// `InitializeWithWindow.Initialize(picker, hwnd)`。它在**非打包（unpackaged）**
/// 应用里不可靠 —— 本工程就是 `WindowsPackageType=None`，实测点「选择文件夹」
/// 直接抛 COMException，而 Message 还是空串，日志里只能看到一行
/// `System.Runtime.InteropServices.COMException:`（crash.log 2026-10-31 03:45 抓到）。
///
/// WinAppSDK 1.8+/2.x 提供的新 API 走的是**现代 IFileDialog + WindowId**，
/// 专为桌面（非打包）应用设计，不再需要 InitializeWithWindow，也不再依赖包身份：
///   `var picker = new Microsoft.Windows.Storage.Pickers.FolderPicker(windowId);`
///   `var result = await picker.PickSingleFolderAsync();`
///   `result?.Path` —— 直接给文件系统路径字符串，不需要 StorageFolder。
///
/// 返回 **string?** 而不是 StorageFolder：非打包应用本来就有完整文件系统权限，
/// 不需要 StorageFolder 那层授权令牌，只要一个路径就够。
/// </summary>
public static class FolderPickerService
{
    /// <summary>弹出文件夹选择器，返回选中的绝对路径；用户取消返回 null。</summary>
    public static async Task<string?> PickAsync(string? startPath = null)
    {
        var win = App.MainWindow
                  ?? throw new InvalidOperationException("主窗口尚未创建，无法弹出文件夹选择器");

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(win);
        var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);

        var picker = new FolderPicker(windowId)
        {
            CommitButtonText = "选择此文件夹",
            SuggestedStartLocation = PickerLocationId.Downloads,
        };

        var result = await picker.PickSingleFolderAsync();
        return result?.Path;
    }

    /// <summary>
    /// 弹出**文件**选择器，返回选中的绝对路径；用户取消返回 null。
    ///
    /// ### 2026-10-31 加（用户报「点导入名单没有反应」）
    ///
    /// 和文件夹选择器同一个病根：`Windows.Storage.Pickers.FileOpenPicker` +
    /// `InitializeWithWindow` 在**非打包**应用里必抛 COMException。更糟的是
    /// 两处调用点都把异常 `catch` 掉了（`catch { }` / 只写日志），
    /// 用户看到的就是**点了完全没反应**，连报错框都没有。
    ///
    /// 新版 API 用法与文件夹选择器对称：
    ///   `new FileOpenPicker(windowId)` + `PickSingleFileAsync()` → `result?.Path`
    /// 扩展名过滤用 `FileTypeFilter.Add(".md")`（**必须带点**，新版 API 不接受 "*"）。
    /// </summary>
    /// <param name="extensions">扩展名列表，如 `.md` / `.txt`；为空则不过滤。</param>
    public static async Task<string?> PickFileAsync(params string[] extensions)
    {
        var win = App.MainWindow
                  ?? throw new InvalidOperationException("主窗口尚未创建，无法弹出文件选择器");

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(win);
        var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);

        var picker = new FileOpenPicker(windowId)
        {
            CommitButtonText = "选择",
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };

        if (extensions is { Length: > 0 })
        {
            foreach (var e in extensions)
            {
                var ext = e.StartsWith((char)46) ? e : "." + e;
                picker.FileTypeFilter.Add(ext);
            }
        }
        else
        {
            // 不过滤时也必须至少给一个，否则对话框里什么都看不见
            picker.FileTypeFilter.Add("*");
        }

        var result = await picker.PickSingleFileAsync();
        return result?.Path;
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
