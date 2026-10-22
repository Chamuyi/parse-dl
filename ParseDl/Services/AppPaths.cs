using System;
using System.IO;

namespace ParseDl.Services;

/// <summary>
/// 数据目录：exe 同级的 userdata\（数据跟着软件走，不写 C 盘）。
/// 与 Flutter 版 lib/services/app_paths.dart 规则一致。
/// </summary>
public static class AppPaths
{
    private const string DataDirName = "userdata";

    public static string DataDir
    {
        get
        {
            var baseDir = AppContext.BaseDirectory;
            var dir = Path.Combine(baseDir, DataDirName);
            try
            {
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                return dir;
            }
            catch
            {
                // 安装到 Program Files 时同级目录不可写 —— 退到 LocalAppData。
                var fallback = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "ParseDl");
                Directory.CreateDirectory(fallback);
                return fallback;
            }
        }
    }

    public static string SettingsFile => Path.Combine(DataDir, "settings.json");
}
