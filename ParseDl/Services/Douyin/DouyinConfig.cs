using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using ParseDl.Services;

namespace ParseDl.Services.Douyin;

/// <summary>「启用模版」预设 —— 一键把文件夹模板 + 文件模板填成一套现成组合。</summary>
public sealed record DouyinTemplatePreset(string Id, string Label, string DirTemplate, string FileNameTemplate);

/// <summary>
/// 抖音下载配置 —— 逐条对齐 Flutter 版 lib/models/douyin_config.dart。
///
/// 落盘到 &lt;数据目录&gt;\douyin_settings.json（独立文件，不塞进 settings.json 的
/// ModuleSettings：抖音这一组选项有 20 多项，且要能单独演进）。每项改动立即写盘。
/// </summary>
public sealed class DouyinConfig
{
    // ── 下载 ────────────────────────────────────────────────
    public DouyinSource Source { get; set; } = DouyinSource.DefaultAddr;
    public DouyinQualityMode QualityMode { get; set; } = DouyinQualityMode.Auto;
    public DouyinImageFormat ImageFormat { get; set; } = DouyinImageFormat.Keep;
    public bool FilterLowQuality { get; set; }
    public bool FilterByteVc1 { get; set; }
    public bool IncludeLivePhoto { get; set; } = true;
    public bool IncludeBgm { get; set; }
    public bool SkipDownloaded { get; set; } = true;
    public bool GroupByAweme { get; set; } = true;
    public bool TimeRangeEnabled { get; set; }
    public int TimeStartSec { get; set; }
    public int TimeEndSec { get; set; } = 300;
    public int Concurrency { get; set; } = 4;
    public string CustomText { get; set; } = "";

    // ── 保存与命名 ──────────────────────────────────────────
    /// <summary>保存根目录。空 = 沿用全局默认目录（数据目录\downloads）。</summary>
    public string SaveDirBase { get; set; } = "";
    public bool EnableSaveFolder { get; set; } = true;
    public string DirTemplate { get; set; } = "%AUTHOR%";
    public string FileNameTemplate { get; set; } = DouyinTemplate.DefaultFileNameTemplate;

    // ── 抓取 / 滚动 ─────────────────────────────────────────
    public int BatchSize { get; set; } = 50;
    public int RequestIntervalMs { get; set; } = 800;
    public int ScrollStepPx { get; set; } = 600;
    public int ScrollIntervalMs { get; set; } = 700;
    /// <summary>自动下载「每个目标最多滚几轮」。</summary>
    public int MaxRounds { get; set; } = 15;
    /// <summary>连续多少轮页面高度没变就判定到底。</summary>
    public int StallLimit { get; set; } = 6;

    // ── 筛选（持久化，下次进页面还在）───────────────────────
    public string FilterKeyword { get; set; } = "";
    public DouyinDateRange FilterDateRange { get; set; } = DouyinDateRange.None;
    public int? FilterMinDurationSec { get; set; }
    public int? FilterMaxDurationSec { get; set; }
    public DouyinTagMode FilterTagMode { get; set; } = DouyinTagMode.Any;

    public DouyinConfig Clone() => (DouyinConfig)MemberwiseClone();

    /// <summary>与默认值不同 —— 设置页折叠时用来点「已修改」小圆点。</summary>
    public bool IsDefault
    {
        get
        {
            var d = new DouyinConfig();
            return Source == d.Source && QualityMode == d.QualityMode && ImageFormat == d.ImageFormat
                && FilterLowQuality == d.FilterLowQuality && FilterByteVc1 == d.FilterByteVc1
                && IncludeLivePhoto == d.IncludeLivePhoto && IncludeBgm == d.IncludeBgm
                && SkipDownloaded == d.SkipDownloaded && GroupByAweme == d.GroupByAweme
                && !TimeRangeEnabled && Concurrency == 4 && string.IsNullOrEmpty(CustomText)
                && string.IsNullOrEmpty(SaveDirBase) && EnableSaveFolder
                && DirTemplate == "%AUTHOR%" && FileNameTemplate == d.FileNameTemplate;
        }
    }
}

/// <summary>
/// 配置的读写（单例）—— 每项改动立即写盘，不用「保存」按钮。
/// 读坏文件时不阻塞启动：坏文件留成 .bad，用默认值继续。
/// </summary>
public static class DouyinSettings
{
    private static readonly object Gate = new();
    private static DouyinConfig? _current;

    public static string FilePath => Path.Combine(AppPaths.DataDir, "douyin_settings.json");

    public static DouyinConfig Current
    {
        get
        {
            lock (Gate)
            {
                if (_current is null) _current = Load();
                return _current;
            }
        }
    }

    /// <summary>改一项并写盘：<c>DouyinSettings.Mutate(c =&gt; c.IncludeBgm = true)</c>。</summary>
    public static void Mutate(Action<DouyinConfig> change)
    {
        lock (Gate)
        {
            var cfg = Current;
            change(cfg);
            Save(cfg);
        }
    }

    public static void Save()
    {
        lock (Gate) Save(Current);
    }

    private static DouyinConfig Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return new DouyinConfig();
            var json = File.ReadAllText(FilePath);
            var n = JsonNode.Parse(json) as JsonObject;
            if (n is null) return new DouyinConfig();

            string S(string key, string def) => n[key]?.GetValue<string>() ?? def;
            bool B(string key, bool def) => n[key]?.GetValue<bool>() ?? def;
            int I(string key, int def)
            {
                var node = n[key];
                if (node is null) return def;
                try { return node.GetValue<int>(); } catch { return def; }
            }
            int? In(string key)
            {
                var node = n[key];
                if (node is null) return null;
                try { return node.GetValue<int>(); } catch { return null; }
            }

            return new DouyinConfig
            {
                Source = DouyinEnumText.SourceFromId(S("source", "default")),
                QualityMode = DouyinEnumText.QualityModeFromId(S("qualityMode", "auto")),
                ImageFormat = DouyinEnumText.ImageFormatFromId(S("imageFormat", "webp")),
                FilterLowQuality = B("filterLowQuality", false),
                FilterByteVc1 = B("filterByteVc1", false),
                IncludeLivePhoto = B("includeLivePhoto", true),
                IncludeBgm = B("includeBgm", false),
                SkipDownloaded = B("skipDownloaded", true),
                GroupByAweme = B("groupByAweme", true),
                TimeRangeEnabled = B("timeRangeEnabled", false),
                TimeStartSec = I("timeStartSec", 0),
                TimeEndSec = I("timeEndSec", 300),
                Concurrency = I("concurrency", 4),
                CustomText = S("customText", ""),
                SaveDirBase = S("saveDirBase", ""),
                EnableSaveFolder = B("enableSaveFolder", true),
                DirTemplate = S("dirTemplate", "%AUTHOR%"),
                // 旧默认模板（3.6 之前）升级成当前这套 —— 只认「存的值恰好等于旧默认串」
                FileNameTemplate = Migrate(S("fileNameTemplate", DouyinTemplate.DefaultFileNameTemplate)),
                BatchSize = I("batchSize", 50),
                RequestIntervalMs = I("requestIntervalMs", 800),
                ScrollStepPx = I("scrollStepPx", 600),
                ScrollIntervalMs = I("scrollIntervalMs", 700),
                MaxRounds = I("maxRounds", 15),
                StallLimit = I("stallLimit", 6),
                FilterKeyword = S("filterKeyword", ""),
                FilterDateRange = DouyinEnumText.DateRangeFromId(S("filterDateRange", "")),
                FilterMinDurationSec = In("filterMinDurationSec"),
                FilterMaxDurationSec = In("filterMaxDurationSec"),
                FilterTagMode = S("filterTagMode", "any") == "all" ? DouyinTagMode.All : DouyinTagMode.Any,
            };
        }
        catch (Exception ex)
        {
            try { if (File.Exists(FilePath)) File.Copy(FilePath, FilePath + ".bad", overwrite: true); } catch { }
            Aria2Engine.Log("[抖音设置] 读取失败，用默认值：" + ex.Message);
            return new DouyinConfig();
        }
    }

    private static string Migrate(string stored)
        => string.IsNullOrEmpty(stored) || stored == DouyinTemplate.LegacyFileNameTemplate
            ? DouyinTemplate.DefaultFileNameTemplate
            : stored;

    private static void Save(DouyinConfig c)
    {
        try
        {
            var dir = Path.GetDirectoryName(FilePath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            var n = new JsonObject
            {
                ["source"] = c.Source.Id(),
                ["qualityMode"] = c.QualityMode.Id(),
                ["imageFormat"] = c.ImageFormat.Id(),
                ["filterLowQuality"] = c.FilterLowQuality,
                ["filterByteVc1"] = c.FilterByteVc1,
                ["includeLivePhoto"] = c.IncludeLivePhoto,
                ["includeBgm"] = c.IncludeBgm,
                ["skipDownloaded"] = c.SkipDownloaded,
                ["groupByAweme"] = c.GroupByAweme,
                ["timeRangeEnabled"] = c.TimeRangeEnabled,
                ["timeStartSec"] = c.TimeStartSec,
                ["timeEndSec"] = c.TimeEndSec,
                ["concurrency"] = c.Concurrency,
                ["customText"] = c.CustomText,
                ["saveDirBase"] = c.SaveDirBase,
                ["enableSaveFolder"] = c.EnableSaveFolder,
                ["dirTemplate"] = c.DirTemplate,
                ["fileNameTemplate"] = c.FileNameTemplate,
                ["batchSize"] = c.BatchSize,
                ["requestIntervalMs"] = c.RequestIntervalMs,
                ["scrollStepPx"] = c.ScrollStepPx,
                ["scrollIntervalMs"] = c.ScrollIntervalMs,
                ["maxRounds"] = c.MaxRounds,
                ["stallLimit"] = c.StallLimit,
                ["filterKeyword"] = c.FilterKeyword,
                ["filterDateRange"] = c.FilterDateRange.Id(),
                ["filterTagMode"] = c.FilterTagMode == DouyinTagMode.All ? "all" : "any",
            };
            if (c.FilterMinDurationSec is int a) n["filterMinDurationSec"] = a;
            if (c.FilterMaxDurationSec is int b) n["filterMaxDurationSec"] = b;

            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, n.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[抖音设置] 保存失败：" + ex.Message);
        }
    }
}
