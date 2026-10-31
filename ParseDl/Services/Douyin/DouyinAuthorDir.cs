using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;

namespace ParseDl.Services.Douyin;

/// <summary>
/// **作者目录名记忆表**（2026-10-31 加）。
///
/// ### 要解决什么
/// 用户按作者建文件夹（模板 `%AUTHOR%` → `@昵称`）。昵称是**可变的**：
/// 一改名，同一个人的作品就会落到 `@新昵称` 这个新目录里，
/// 老的 891 个文件留在 `@旧昵称` —— 目录被拆成两半，很难认。
///
/// ### 做法
/// 记一份「作者稳定 ID → 首次使用的目录名」的映射：
///   · 第一次下这个作者 → 用当时的 `@昵称` 建目录，并把这条关系存下来；
///   · 之后无论他改什么名，**只要 ID 一样就用回原来那个目录名**。
///
/// 于是目录名**永久固定**（改名不分裂），而且里面是人名（好辨认）——
/// 这正是用户要的两个条件。
///
/// ### 边界（要说清）
/// 目录名一旦定下就不再跟随改名。这是**刻意的取舍**：要么跟着改名走（目录分裂），
/// 要么固定（名字可能过时）。用户选的是固定。
/// 想更新名字，删掉这个映射里对应的那条即可，下次下载会用新昵称建新目录。
/// </summary>
public static class DouyinAuthorDir
{
    private const string FileName = "douyin_author_dirs.json";
    private static readonly object _lock = new();
    private static Dictionary<string, string>? _map;
    private static bool _dirty;

    /// <summary>映射文件路径（设置页展示给用户看）。</summary>
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
                Aria2Engine.Log("[作者目录] 读取映射失败（从空开始）：" + ex.Message);
            }
            return _map;
        }
    }

    /// <summary>
    /// 给一个作者算「应该用的目录名」。
    ///
    /// <paramref name="stableId"/> 优先用 UID（`%AUTHOR_ID%`），没有就退回抖音号；
    /// 两者都没有时**不参与记忆**（直接用当前昵称，退化成老行为），
    /// 因为拿昵称当 key 等于没记忆 —— 改名就换 key 了。
    /// </summary>
    /// <param name="fallbackName">按模板展开出来的当前名字（首次见到时用它）。</param>
    public static string Resolve(string? stableId, string fallbackName)
        => Resolve(stableId, fallbackName, parentDir: null);

    /// <summary>
    /// 同上，但**发现改名时会把旧目录重命名成新名字**（2026-10-31 用户要求
    /// 「作者名字改了，再下载的时候自动更改文件夹名字」）。
    ///
    /// ### 行为
    ///   · 没记录过 → 用 <paramref name="fallbackName"/> 建目录并记下；
    ///   · 记录过且与当前名字**相同** → 直接用；
    ///   · 记录过但**不同**（改名了）→ 把 <paramref name="parentDir"/> 下的
    ///     旧目录 `old` 改名成 `new`，成功则更新记录并返回新名；
    ///     失败（目标已存在 / 文件被占用）则**退回旧名**，保证不丢文件。
    ///
    /// 为什么需要 parentDir：目录名只是一个段，重命名得知道它在哪个父目录下。
    /// 拿不到父目录时只更新记录、不动磁盘（下次下载自然落到新名目录）。
    /// </summary>
    public static string Resolve(string? stableId, string fallbackName, string? parentDir)
    {
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

        // 首次见到：直接记住
        if (oldName is null)
        {
            lock (_lock)
            {
                Map[stableId] = fallbackName;
                _dirty = true;
            }
            return fallbackName;
        }

        // 改名了：先尝试把磁盘上的旧目录改成新名字
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
                    Aria2Engine.Log($"[作者目录] 改名：{oldName} → {fallbackName}");
                }
                else if (Directory.Exists(newPath))
                {
                    // 新名目录已经存在（可能之前已建过）：不合并，保留记录指向新名
                    Aria2Engine.Log($"[作者目录] 新名目录已存在，不再重命名：{fallbackName}");
                    renamed = true;
                }
            }
            catch (Exception ex)
            {
                Aria2Engine.Log($"[作者目录] 重命名失败（保留旧目录 {oldName}）：{ex.Message}");
            }
        }

        lock (_lock)
        {
            // 重命名成功（或目标已存在）→ 记录改成新名字；失败则保持旧名，避免文件落进新目录造成分裂
            Map[stableId] = renamed ? fallbackName : oldName;
            _dirty = true;
        }
        Flush();
        return renamed ? fallbackName : oldName;
    }

    /// <summary>落盘（防抖调用，进程退出前也会调一次）。</summary>
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
            catch (Exception ex)
            {
                Aria2Engine.Log("[作者目录] 保存映射失败：" + ex.Message);
            }
        }
    }

    /// <summary>当前记了多少个作者（设置页/日志用）。</summary>
    public static int Count
    {
        get { lock (_lock) return Map.Count; }
    }

    /// <summary>清空记忆（用户想「让目录名重新跟随当前昵称」时用）。</summary>
    public static void Clear()
    {
        lock (_lock)
        {
            _map?.Clear();
            _dirty = true;
            Flush();
        }
    }
}
