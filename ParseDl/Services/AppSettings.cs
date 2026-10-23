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

    // ── 其它 ──────────────────────────────────────────
    public bool WriteLogs { get; set; } = true;

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
    public bool SkipDownloaded { get; set; } = true;
    public int BatchSize { get; set; } = 50;
    public int RequestIntervalMs { get; set; } = 800;
    public int ScrollStepPx { get; set; } = 600;
    public int ScrollIntervalMs { get; set; } = 1200;
    public string PreferredQuality { get; set; } = "最高";
    public bool DownloadDanmaku { get; set; }
    public bool AudioOnly { get; set; }
}