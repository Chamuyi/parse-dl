using System;
using System.IO;

namespace ParseDl.Services;

/// <summary>
/// 数据目录 —— 设置、台账、aria2 会话、默认下载目录都落在这里。
///
/// ### 2026-10-26 用户要求：**所有数据保存在安装目录下，下载路径默认也在安装路径下**
///
/// 为此工程已改成**非打包（unpackaged）发布**（ParseDl.csproj 里
/// WindowsPackageType=None）。原因：MSIX 打包版跑在 AppContainer 沙箱里，对安装目录
/// **没有任何写权限** —— 实测 Directory.CreateDirectory 能建出目录、但文件写不进去，
/// 于是 settings.json 从来没落过盘（表现为「切浅色 → 重启 → 又是深色」）。
/// 要「数据跟着软件目录走」，只能放弃包身份。
///
/// 现在的规则：
/// 1. **exe 同级 userdata\** —— 默认，数据跟着软件走，拷走整个文件夹就带走全部数据；
/// 2. 如果安装目录不可写（例如装进 Program Files 且没有管理员权限），
///    退到 LocalApplicationData\ParseDl，并在日志里明确说明退到了哪。
///
/// 探测必须**真的写一个文件**再删 —— 只调 Directory.CreateDirectory 不够：
/// 有些目录能被枚举/创建却写不进文件（AppContainer 下就是这样）。
/// </summary>
public static class AppPaths
{
    private const string DataDirName = "userdata";
    private const string ProbeName = ".write_probe";

    private static string? _cached;

    /// <summary>安装目录（exe 所在目录）。</summary>
    public static string InstallDir => AppContext.BaseDirectory;

    public static string DataDir
    {
        get
        {
            if (_cached is not null) return _cached;

            // 1) 首选：安装目录下的 userdata\（用户要求：数据跟着软件走）
            var local = Path.Combine(InstallDir, DataDirName);
            if (TryWritable(local))
            {
                _cached = local;
                return _cached;
            }

            // 2) 安装目录不可写（如装在 Program Files 且无权限）→ 兜底到 LocalAppData。
            //    这一条是**例外路径**，正常分发（绿色版/便携版）不会走到。
            var fallback = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ParseDl");
            Directory.CreateDirectory(fallback);
            _cached = fallback;
            return _cached;
        }
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

    /// <summary>
    /// 下载产物默认目录 —— 用户要求「下载路径默认也要在安装路径下」，
    /// 所以是 <c>安装目录\downloads</c>，而不是数据目录下的子目录
    /// （数据目录本身也在安装目录里，两者并列，方便用户直接去 downloads 拿文件）。
    /// </summary>
    public static string DefaultDownloadDir => Path.Combine(InstallDir, "downloads");
}
