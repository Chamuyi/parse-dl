using System;
using System.IO;

namespace ParseDl.Services;

/// <summary>
/// 数据目录 —— 设置、台账、aria2 会话、默认下载目录都落在这里。
///
/// **2026-10-25 修（真机实测发现）**：原实现无条件取
/// <c>AppContext.BaseDirectory\userdata</c>。用 winapp 打包运行时它是
/// <c>...\win-x64\AppX\userdata</c> —— 属于包安装目录，AppContainer 无写权限。
/// 实测后果：settings.json 从来没落过盘（目录能建出来，文件写不进去），
/// 于是「切浅色 → 重启 → 又是深色」，用户报的「浅色模式下三键不可辨」
/// 连复现都做不到。
///
/// 现在的规则：**按顺序探测，取第一个真正可写的**。
/// 1. 包容器 LocalFolder（打包运行的唯一稳定可写位置，路径形如
///    <c>%LOCALAPPDATA%\Packages\&lt;pkg&gt;\LocalState</c>）；
/// 2. exe 同级 userdata\（未打包运行时数据跟着软件走，不写 C 盘）；
/// 3. LocalApplicationData\ParseDl 兜底。
///
/// 探测必须**真的写一个文件**再删 —— 只调 Directory.CreateDirectory 不够：
/// AppContainer 下有些目录能被枚举/创建却写不进文件。
/// </summary>
public static class AppPaths
{
    private const string DataDirName = "userdata";
    private const string ProbeName = ".write_probe";

    private static string? _cached;

    public static string DataDir
    {
        get
        {
            if (_cached is not null) return _cached;
            foreach (var candidate in Candidates())
            {
                if (string.IsNullOrEmpty(candidate)) continue;
                if (TryWritable(candidate))
                {
                    _cached = candidate;
                    return _cached;
                }
            }
            // 全都不行也得给个路径，让上层报错时能说清落在哪
            _cached = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ParseDl");
            return _cached;
        }
    }

    private static string?[] Candidates()
    {
        var list = new string?[3];

        // 1) 包容器 LocalFolder。
        //    类型是 Windows.Storage.ApplicationData（Windows SDK 自带，不是
        //    WinAppSDK 的 Microsoft.Windows.Storage.ApplicationData —— 后者在
        //    2.3.9 上没有 Current 属性，实测 CS0117）。用反射取一次并缓存，
        //    避免把整个 Windows.Storage 变成硬依赖、也避免每次启动重复反射。
        try
        {
            var t2 = typeof(Windows.Storage.ApplicationData);
            var cur = t2.GetProperty("Current")?.GetValue(null);
            var folder = cur?.GetType().GetProperty("LocalFolder")?.GetValue(cur);
            list[0] = folder?.GetType().GetProperty("Path")?.GetValue(folder) as string;
        }
        catch
        {
            list[0] = null;
        }

        // 2) exe 同级 userdata
        try { list[1] = Path.Combine(AppContext.BaseDirectory, DataDirName); }
        catch { list[1] = null; }

        // 3) 兜底
        try
        {
            list[2] = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ParseDl");
        }
        catch { list[2] = null; }

        return list;
    }

    /// <summary>真的写一个探针文件再删掉，验证目录可写。</summary>
    private static bool TryWritable(string dir)
    {
        try
        {
            Directory.CreateDirectory(dir);
            var probe = Path.Combine(dir, ProbeName);
            File.WriteAllText(probe, "probe");
            File.Delete(probe);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public static string SettingsFile => Path.Combine(DataDir, "settings.json");

    /// <summary>下载产物默认目录（未在设置里指定时用）。</summary>
    public static string DefaultDownloadDir => Path.Combine(DataDir, "downloads");
}
