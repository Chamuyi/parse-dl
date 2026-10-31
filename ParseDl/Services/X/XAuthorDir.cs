using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace ParseDl.Services.X;

/// <summary>
/// **X 作者目录名记忆表**（2026-10-31 加，与抖音的 DouyinAuthorDir 同一思路）。
///
/// X 的目录默认模板是 `%USER_NAME%%USER_SCREEN_NAME%`（昵称 + @handle），
/// 两者都可能变：改名 → 目录换一个 → 同一个人的作品被拆成两个文件夹。
///
/// 做法与抖音一致：记「稳定 ID（userId）→ 首次用过的目录名」，
/// 命中就用回老名字；**发现改名时把磁盘上的旧目录就地重命名**（Directory.Move，
/// 同盘同父目录 = 瞬时改名，不复制数据）。
///
/// 为什么单独一份文件而不是复用 DouyinAuthorDir：
/// 两个平台的 ID 空间不同（X 的 userId 是纯数字串，抖音是另一套），
/// 混在一张表里会互相污染；而且用户可能只清其中一个。
/// </summary>
public static class XAuthorDir
{
    private const string FileName = "x_author_dirs.json";
    private static readonly object _lock = new();
    private static Dictionary<string, string>? _map;
    private static bool _dirty;

    /// <summary>映射文件路径（设置页展示用）。</summary>
    public static string FilePath => Path.Combine(AppPaths.DataDir, FileName);

    private static Dictionary<string, string> Map
    {
        get
        {
            if (_map is not null) return _map;
            _map = new Dictionary<string, string>(StringComparer.Ordinal);
            try
            {
                if (File.Exists(FilePath))
                {
                    var loaded = JsonSerializer.Deserialize<Dictionary<string, string>>(
                        File.ReadAllText(FilePath));
                    if (loaded is not null)
                        _map = new Dictionary<string, string>(loaded, StringComparer.Ordinal);
                }
            }
            catch (Exception ex)
            {
                Aria2Engine.Log("[X 作者目录] 读取映射失败（从空开始）：" + ex.Message);
            }
            return _map;
        }
    }

    /// <summary>
    /// 给一个作者算「应该用的目录名」。逻辑与 <see cref="Douyin.DouyinAuthorDir.Resolve"/>
    /// 完全对称：首次记住 → 相同直接用 → 不同则就地重命名 → 失败退回旧名。
    /// </summary>
    /// <param name="stableId">X 的 userId（%USER_ID%），不变的那个。</param>
    /// <param name="fallbackName">按模板展开出的当前目录名。</param>
    /// <param name="parentDir">该目录的父目录；为空则只更新记录、不动磁盘。</param>
    public static string Resolve(string? stableId, string fallbackName, string? parentDir)
    {
        // 与抖音同一套净化：X 显示名同样可能以点/空格结尾，Windows 会悄悄改写目录名，
        // 之后 aria2 按原串拼路径就报 errorCode=16（2026-10-31 统一收口）。
        fallbackName = FileNameTemplate.SanitizeDirSegment(fallbackName ?? "");
        if (string.IsNullOrWhiteSpace(stableId)) return fallbackName;

        string? oldName = null;
        lock (_lock)
        {
            var map = Map;
            if (map.TryGetValue(stableId, out var remembered) &&
                !string.IsNullOrWhiteSpace(remembered))
            {
                if (string.Equals(remembered, fallbackName, StringComparison.Ordinal))
                    return remembered;
                oldName = remembered;
            }
        }

        if (oldName is null)
        {
            lock (_lock) { Map[stableId] = fallbackName; _dirty = true; }
            return fallbackName;
        }

        var renamed = false;
        if (!string.IsNullOrWhiteSpace(parentDir))
        {
            try
            {
                var oldPath = Path.Combine(parentDir, oldName);
                var newPath = Path.Combine(parentDir, fallbackName);
                if (Directory.Exists(oldPath) && !Directory.Exists(newPath))
                {
                    Directory.Move(oldPath, newPath);
                    renamed = true;
                    Aria2Engine.Log($"[X 作者目录] 改名：{oldName} → {fallbackName}");
                }
                else if (Directory.Exists(newPath))
                {
                    Aria2Engine.Log($"[X 作者目录] 新名目录已存在，不再重命名：{fallbackName}");
                    renamed = true;
                }
            }
            catch (Exception ex)
            {
                Aria2Engine.Log($"[X 作者目录] 重命名失败（保留旧目录 {oldName}）：{ex.Message}");
            }
        }

        lock (_lock) { Map[stableId] = renamed ? fallbackName : oldName; _dirty = true; }
        Flush();
        return renamed ? fallbackName : oldName;
    }

    public static void Flush()
    {
        lock (_lock)
        {
            if (!_dirty || _map is null) return;
            try
            {
                var json = JsonSerializer.Serialize(_map,
                    new JsonSerializerOptions { WriteIndented = true });
                var tmp = FilePath + ".tmp";
                File.WriteAllText(tmp, json);
                File.Move(tmp, FilePath, overwrite: true);
                _dirty = false;
            }
            catch (Exception ex) { Aria2Engine.Log("[X 作者目录] 保存映射失败：" + ex.Message); }
        }
    }

    public static int Count { get { lock (_lock) return Map.Count; } }

    public static void Clear()
    {
        lock (_lock) { _map?.Clear(); _dirty = true; Flush(); }
    }
}
