using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ParseDl.Services;

/// <summary>
/// 应用设置 —— 落盘到 &lt;数据目录&gt;\settings.json。
/// 结构与 Flutter 版 lib/models/settings.dart 对应（只保留 WinUI 版用得到的字段）。
///
/// 设计要点：
/// 1. **单一实例**：所有页面读同一份，改一处全局生效；
/// 2. **原子写**：先写 .tmp 再替换，避免断电/崩溃留下半个 JSON；
/// 3. **容错读**：文件损坏时返回默认值并保留坏文件为 .bad，不阻塞启动。
/// </summary>
public sealed class AppSettings
{
    public static AppSettings Instance { get; } = new();

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    // ── 下载 ──────────────────────────────────────────
    public string SaveDirBase { get; set; } = "";
    public string FileNameTemplate { get; set; } = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%";
    public bool SameFileSkip { get; set; } = true;
    public int RequestIntervalMs { get; set; } = 800;
    public int BatchSize { get; set; } = 50;
    public int MaxConcurrent { get; set; } = 5;

    // ── 各模块独立设置（键 = 模块 id：x / douyin / bili）────
    public Dictionary<string, ModuleSettings> Modules { get; set; } = new();

    // ── 外观 ──────────────────────────────────────────
    public string MaterialKind { get; set; } = "Mica";
    public bool IsDark { get; set; } = true;

    // ── 代理 ──────────────────────────────────────────
    // 对齐 Flutter 版 lib/models/settings.dart 的 ProxySettings：
    // enable / url / useSystem 三项。默认值与那边逐字一致。
    public bool ProxyEnable { get; set; } = true;
    public string ProxyUrl { get; set; } = "http://127.0.0.1:7890";
    public bool ProxyUseSystem { get; set; } = true;

    // ── 界面 ──────────────────────────────────────────
    /// <summary>导航形态：dock（悬浮 Dock）/ sidebar（左侧常规栏）。对齐 NavLayout。</summary>
    public string NavLayout { get; set; } = "dock";

    // ── 主题色（强调色）──────────────────────────────
    // 2026-10-25 新增：预设 id（见 Services/AccentService.Presets）或 "custom"，
    // 以及自定义色的 #RRGGBB。只新增字段，不动既有字段语义。
    public string AccentPreset { get; set; } = "windows";

    /// <summary>自定义强调色 #RRGGBB。仅当 AccentPreset == "custom" 时有意义。</summary>
    public string AccentHex { get; set; } = "#0078D4";

    // ── 其它 ──────────────────────────────────────────
    public bool WriteLogs { get; set; } = true;

    /// <summary>启动时自动检查更新（对齐 AppOptions.autoCheckUpdate）。</summary>
    public bool AutoCheckUpdate { get; set; } = true;

    /// <summary>接受预发布版本（对齐 AppOptions.acceptPrerelease）。</summary>
    public bool AcceptPrerelease { get; set; }

    [JsonIgnore]
    public string FilePath => Path.Combine(AppPaths.DataDir, "settings.json");

    public ModuleSettings ForModule(string id)
    {
        if (!Modules.TryGetValue(id, out var m))
        {
            m = new ModuleSettings();
            Modules[id] = m;
        }
        return m;
    }

    /// <summary>从磁盘加载（不存在或损坏时用默认值）。</summary>
    public void Load()
    {
        try
        {
            var path = FilePath;
            if (!File.Exists(path)) return;
            var json = File.ReadAllText(path);
            var loaded = JsonSerializer.Deserialize<AppSettings>(json, JsonOpts);
            if (loaded is null) return;

            SaveDirBase = loaded.SaveDirBase;
            FileNameTemplate = loaded.FileNameTemplate;
            SameFileSkip = loaded.SameFileSkip;
            RequestIntervalMs = loaded.RequestIntervalMs;
            BatchSize = loaded.BatchSize;
            MaxConcurrent = loaded.MaxConcurrent;
            Modules = loaded.Modules ?? new();
            MaterialKind = loaded.MaterialKind;
            IsDark = loaded.IsDark;
            WriteLogs = loaded.WriteLogs;
            // 2026-10-24 新增的一批字段集中在这一处读，减少与并行分支的合并冲突
            LoadExtras(loaded);
        }
        catch (Exception ex)
        {
            // 坏文件留证据，不静默吞掉
            try
            {
                var bad = FilePath + ".bad";
                if (File.Exists(FilePath)) File.Copy(FilePath, bad, overwrite: true);
            }
            catch { }
            System.Diagnostics.Debug.WriteLine($"[Settings] 读取失败，使用默认值: {ex.Message}");
        }

        // 设置读完立刻把强调色应用到应用级资源（开机恢复上次选的主题色）。
        // 放在这里而不是 App.xaml.cs：App 是禁改区，而 Load() 正好在 OnLaunched 里、
        // UI 线程上、MainWindow 创建之前执行 —— 时机与位置都对。
        // Application.Current 尚未就绪时 Apply 会返回 false，不抛异常，不影响启动。
        try
        {
            AccentService.ApplyFromSettings();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[Settings] 应用主题色失败: {ex.Message}");
        }
    }

    /// <summary>
    /// 读 2026-10-24 新增的那批字段（代理 / 导航形态 / 更新检查）。
    ///
    /// 单独一个方法而不是散在 <see cref="Load"/> 里：并行开发时多个分支都会往
    /// Load 里加读取行，集中在一处能显著降低合并冲突的概率。
    /// </summary>
    private void LoadExtras(AppSettings loaded)
    {
        ProxyEnable = loaded.ProxyEnable;
        ProxyUrl = loaded.ProxyUrl;
        ProxyUseSystem = loaded.ProxyUseSystem;
        NavLayout = loaded.NavLayout;
        AutoCheckUpdate = loaded.AutoCheckUpdate;
        AcceptPrerelease = loaded.AcceptPrerelease;
        AccentPreset = string.IsNullOrWhiteSpace(loaded.AccentPreset) ? "windows" : loaded.AccentPreset;
        AccentHex = string.IsNullOrWhiteSpace(loaded.AccentHex) ? "#0078D4" : loaded.AccentHex;
    }

    /// <summary>原子写盘。</summary>
    public void Save()
    {
        try
        {
            var path = FilePath;
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            var tmp = path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, JsonOpts));
            // File.Move(overwrite) 在 NTFS 上是原子的
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[Settings] 保存失败: {ex.Message}");
        }
    }
}

/// <summary>单个模块（X / 抖音 / B 站）的独立设置。</summary>
public sealed class ModuleSettings
{
    public string SaveDir { get; set; } = "";
    public string FileNameTemplate { get; set; } = "%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%";

    /// <summary>文件夹模板（X 侧「命名模板」的上一层目录）。留空表示平铺在保存目录下。</summary>
    public string DirTemplate { get; set; } = "";

    public bool SkipDownloaded { get; set; } = true;
    public int BatchSize { get; set; } = 50;
    public int RequestIntervalMs { get; set; } = 800;
    public int ScrollStepPx { get; set; } = 600;
    public int ScrollIntervalMs { get; set; } = 1200;
    public string PreferredQuality { get; set; } = "最高";
    /// <summary>登录态 Cookie（B 站 SESSDATA 等）。空表示未登录 —— 未登录时 B 站只给 480P。</summary>
    public string Cookie { get; set; } = "";
    public bool DownloadDanmaku { get; set; }
    public bool AudioOnly { get; set; }

    // ── X 下载模块专用（对齐 Flutter 版 DownloadFilter + 账号分区）──────

    /// <summary>媒体类型筛选：空串表示不限，否则逗号分隔的 video / image / gif。</summary>
    public string MediaTypeFilter { get; set; } = "";

    /// <summary>是否启用时间范围筛选。</summary>
    public bool TimeRangeEnabled { get; set; }

    /// <summary>时间范围下界（yyyy-MM-dd），空表示不限。</summary>
    public string DateFrom { get; set; } = "";

    /// <summary>时间范围上界（yyyy-MM-dd），空表示不限。</summary>
    public string DateTo { get; set; } = "";

    /// <summary>X 身份令牌（auth_token cookie）。</summary>
    public string AuthToken { get; set; } = "";

    /// <summary>X CSRF token（ct0 cookie，必须是 32 位十六进制）。</summary>
    public string Ct0 { get; set; } = "";

    /// <summary>最后一次联网验证通过的账号 @ 名。空表示未验证/未登录。</summary>
    public string LastVerifiedUser { get; set; } = "";

    /// <summary>除 auth_token / ct0 之外的其它 cookie 字段（原样保留，避免 X 判为未认证）。</summary>
    public string ExtraCookies { get; set; } = "";

    /// <summary>是否已配置凭据（两个字段都非空）。</summary>
    [JsonIgnore]
    public bool HasCredentials => !string.IsNullOrWhiteSpace(AuthToken) && !string.IsNullOrWhiteSpace(Ct0);

    /// <summary>拼回 X 需要的整段 cookie（原版就是发整段）。</summary>
    [JsonIgnore]
    public string MergedCookie
    {
        get
        {
            var parts = new List<string> { $"auth_token={AuthToken}", $"ct0={Ct0}" };
            if (!string.IsNullOrWhiteSpace(ExtraCookies)) parts.Add(ExtraCookies.Trim().TrimEnd(';'));
            return string.Join("; ", parts);
        }
    }
}