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

    /// <summary>
    /// **模块间公平调度**（2026-11-20 加，默认开）。
    ///
    /// 背景：aria2 的 `--max-concurrent-downloads` 是**全局**的，队列按入队顺序取任务。
    /// 于是「先入队的模块」会把并发槽全占满，后来的模块一条都轮不上 ——
    /// 实测 X 积压 352 条排在前面，抖音 229 条排 101~329 位，5 个槽全是 X，
    /// 抖音自动流程空等 30 分钟。
    ///
    /// 打开后：某个模块有等待中的任务、却一条都没在下时，把它的队首任务
    /// `changePosition` 提到队首，保证每个模块至少占到一个并发槽。
    /// 关掉则完全回到旧行为（纯 FIFO）。
    /// </summary>
    public bool ModuleFairShare { get; set; } = true;

    // ── 各模块独立设置（键 = 模块 id：x / douyin / bili）────
    public Dictionary<string, ModuleSettings> Modules { get; set; } = new();

    // ── 外观 ──────────────────────────────────────────
    public string MaterialKind { get; set; } = "Mica";

    /// <summary>
    /// 明暗偏好（2026-10-30 加「跟随系统」）：
    ///   "System" —— 跟随 Windows 的「应用模式」，系统切深色/浅色时界面跟着变；
    ///   "Dark" / "Light" —— 手动锁定。
    ///
    /// 老配置里没有这个字段，加载时按 <see cref="IsDark"/> 回填（见 Load）。
    /// </summary>
    public string ThemeMode { get; set; } = "System";

    /// <summary>
    /// 实际生效的明暗（**只读派生值**，不要直接改它）。
    /// ThemeMode == "System" 时取系统的应用主题，否则取 ThemeMode。
    /// 写入请用 <see cref="SetThemeMode"/>，它会同时更新 ThemeMode 与 IsDark。
    /// </summary>
    public bool IsDark { get; set; } = true;

    /// <summary>系统当前是否深色（读注册表 AppsUseLightTheme）。读不到时按深色处理。</summary>
    public static bool SystemIsDark()
    {
        try
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var v = k?.GetValue("AppsUseLightTheme");
            if (v is int i) return i == 0;
        }
        catch { }
        return true;
    }

    /// <summary>按 ThemeMode 解析出实际明暗。</summary>
    public bool ResolveIsDark()
        => ThemeMode switch
        {
            "Dark" => true,
            "Light" => false,
            _ => SystemIsDark(),
        };

    /// <summary>设置明暗偏好并同步 IsDark（三者之一：System / Dark / Light）。</summary>
    public void SetThemeMode(string mode)
    {
        ThemeMode = mode is "Dark" or "Light" ? mode : "System";
        IsDark = ResolveIsDark();
    }

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

    /// <summary>
    /// 日志保留天数（2026-10-26 用户要求「日志增加自动删除，可以选择时间删除或者不删除」）。
    /// 0 = 不自动删除；大于 0 = 启动时清掉超过这么多天的日志文件。
    /// </summary>
    public int LogRetentionDays { get; set; } = 0;

    /// <summary>启动时自动检查更新（对齐 AppOptions.autoCheckUpdate）。</summary>
    public bool AutoCheckUpdate { get; set; } = true;

    /// <summary>接受预发布版本（对齐 AppOptions.acceptPrerelease）。</summary>
    public bool AcceptPrerelease { get; set; }

    [JsonIgnore]
    public string FilePath => Path.Combine(AppPaths.DataDir, "settings.json");

    /// <summary>
    /// 自动执行页专用的设置槽（2026-10-29 用户要求「和主页分开」）。
    ///
    /// 之前自动执行页和 X 主页都用 <c>ForModule("x")</c> —— **同一份对象**，
    /// 在自动执行页把「媒体类型」改成只看视频，主页那边也跟着变，反之亦然。
    /// 用户要的是两页各自独立：主页那页配的是「手动加载后下载」的规则，
    /// 自动执行配的是「按名单批量跑」的规则，本来就该分开。
    ///
    /// 做法：在 <see cref="Modules"/> 里另开一个键 <c>x_auto</c>，
    /// 复用同一个 <see cref="ModuleSettings"/> 类型，但对象互不相干。
    /// **登录态（AuthToken / Ct0）仍然共用 x 那一份** —— 账号只有一个，
    /// 分开会导致「主页登录了、自动执行说没登录」。
    /// </summary>
    public ModuleSettings ForAutoTask()
    {
        if (!Modules.TryGetValue(AutoTaskModuleKey, out var m))
        {
            m = new ModuleSettings();
            Modules[AutoTaskModuleKey] = m;
        }

        // **登录态必须每次从 x 槽同步过来**（2026-10-29 修回归）。
        //
        // 上一版只在这里新建空槽就算完 —— 结果自动执行一跑就报
        // 「失败：未登录，无法创建下载任务」，而 X 下载设置页明明显示「已登录」。
        // 原因：`XHomeApi.HasLogin => AuthToken.Length > 0 && Ct0.Length > 0`，
        // 而新建的 x_auto 槽这两个字段都是空 —— 「共用登录态」只写在注释里，代码没做。
        //
        // 现在每次取用前都把凭据同步一份：账号只有一个（登录入口只在 X 下载设置页），
        // 不存在「两个槽各登各的」这种需求。
        var auth = ForModule("x");
        m.AuthToken = auth.AuthToken;
        m.Ct0 = auth.Ct0;
        m.Cookie = auth.Cookie;
        m.ExtraCookies = auth.ExtraCookies;
        m.LastVerifiedUser = auth.LastVerifiedUser;
        return m;
    }

    /// <summary>自动执行页独立设置槽的键名。</summary>
    public const string AutoTaskModuleKey = "x_auto";

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
            // 【2026-11-20】ModuleFairShare 是新字段，老配置里没有 → 取反序列化后的默认值（true）。
            ModuleFairShare = loaded.ModuleFairShare;
            Modules = loaded.Modules ?? new();
            MaterialKind = loaded.MaterialKind;
            // 【2026-10-30】ThemeMode 是新字段：老配置文件里没有，反序列化后是默认值
            // "System"。若用户以前手动设过深色/浅色（配置里 IsDark 与之不符），
            // 以老字段为准回填，避免升级后「莫名其妙变成跟随系统」。
            ThemeMode = string.IsNullOrWhiteSpace(loaded.ThemeMode) ? "System" : loaded.ThemeMode;
            // 老配置（没有 ThemeMode 键）无法区分「新装的默认」与「手动设过」——
            // 用一个显式标记判断：有 IsDark 但没有 ThemeMode 就当成手动锁定。
            if (!json.Contains("\"ThemeMode\"", StringComparison.Ordinal))
                ThemeMode = loaded.IsDark ? "Dark" : "Light";
            IsDark = ResolveIsDark();
            WriteLogs = loaded.WriteLogs;
            LogRetentionDays = loaded.LogRetentionDays;
            // 2026-10-24 新增的一批字段集中在这一处读，减少与并行分支的合并冲突
            LoadExtras(loaded);

            // ── 2026-10-26 路径迁移 ─────────────────────────────────────
            // 用户要求「所有数据保存在安装目录下，下载路径默认也在安装路径下」，工程已从
            // MSIX 打包改成非打包，数据目录从包容器 LocalState 换到 exe 同级 userdata。
            // 老版本写下的绝对路径会指向旧位置，这里统一改写，免得设置页显示旧路径。
            SaveDirBase = MigrateLegacyPath(SaveDirBase);
            if (Modules is not null)
            {
                foreach (var m in Modules.Values) m.SaveDir = MigrateLegacyPath(m.SaveDir);
            }
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
    /// <summary>
    /// 把旧版本留下的绝对路径改写到新位置（2026-10-26 改非打包发布时新增）。
    ///
    /// 只处理两种旧形态，其余原样返回（用户自己选的别的盘不动）：
    /// 1. 旧包容器路径 %LOCALAPPDATA%\Packages\<pkg>\LocalState\... → 安装目录\...
    /// 2. 旧兜底路径 %LOCALAPPDATA%\ParseDl\... → 安装目录\...
    /// </summary>
    private static string MigrateLegacyPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return path ?? "";
        try
        {
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var packages = Path.Combine(localAppData, "Packages");
            var fallback = Path.Combine(localAppData, "ParseDl");

            string? tail = null;
            if (path.StartsWith(packages, StringComparison.OrdinalIgnoreCase))
            {
                var i = path.IndexOf("LocalState", StringComparison.OrdinalIgnoreCase);
                if (i >= 0) tail = path.Substring(i + "LocalState".Length).TrimStart('\\', '/');
            }
            else if (path.StartsWith(fallback, StringComparison.OrdinalIgnoreCase))
            {
                tail = path.Substring(fallback.Length).TrimStart('\\', '/');
            }
            if (tail is null) return path;

            var install = AppPaths.InstallDir;
            if (tail.StartsWith("downloads", StringComparison.OrdinalIgnoreCase))
                return Path.Combine(install, "downloads");
            return Path.Combine(install, "userdata", tail);
        }
        catch
        {
            return path;
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

    /// <summary>
    /// 下载源（对齐 Flutter 版 DownloadSource）：medias = 媒体列表接口（快，更早的推文可能拿不到）；
    /// tweets = 帖子时间线（能翻到更早，较慢）。主页与自动执行页共用这一份。
    /// </summary>
    public string Source { get; set; } = "medias";

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

    /// <summary>
    /// 交给抓取链路用的整段 cookie：账号分区填了 auth_token + ct0 就用它拼出来的，
    /// 否则退回通用 Cookie 字段（老设置文件里只有这一处）。
    /// 登录入口只在 X 下载设置页，其它页面一律读这里，不自己维护一份 cookie。
    /// </summary>
    [JsonIgnore]
    public string EffectiveCookie =>
        HasCredentials ? MergedCookie : (Cookie ?? "");

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
