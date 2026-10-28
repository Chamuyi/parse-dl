using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services;

/// <summary>aria2 任务状态。</summary>
public enum AriaStatus
{
    Waiting,
    Active,
    Paused,
    Error,
    Complete,
    Removed,
}

/// <summary>aria2 任务（只取界面用得到的字段）。</summary>
public sealed record AriaTask(
    string Gid,
    AriaStatus Status,
    long CompletedBytes,
    long TotalBytes,
    string FileName,
    string Dir,
    string Error,
    long SpeedBytesPerSec)
{
    public double Progress => TotalBytes <= 0 ? 0 : (double)CompletedBytes / TotalBytes;
}

/// <summary>
/// aria2 下载引擎 —— 与 Flutter 版 lib/services/aria2.dart 同一套做法：
/// 拉起打包的 aria2c.exe（--enable-rpc + 随机密钥），走 JSON-RPC 控制。
///
/// 为什么不用自己写 HTTP 下载：aria2 支持多线程分片、断点续传、磁力/BT，
/// 这些自己写要几千行还不稳。Flutter 版已验证这套参数可用，直接照搬。
///
/// 关键设计（照搬 Flutter 版踩过的坑）：
/// 1. **父进程一消失 aria2c 自己退出** —— 用 Job Object 绑定，避免孤儿进程；
/// 2. **会话文件不存在时不能传 --input-file** —— aria2c 会直接 exit(1)（实测）；
/// 3. **随机 rpc-secret** —— 本机其他程序不能随便控制我们的下载器。
/// </summary>
public sealed class Aria2Engine : IDisposable
{
    private Process? _child;
    private string _secret = "";
    private int _port;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(8) };
    private bool _disposed;

    public bool IsRunning => _child is { HasExited: false };

    /// <summary>启动 aria2c。返回是否成功。</summary>
    public async Task<bool> StartAsync()
    {
        if (IsRunning) return true;

        var exe = ResolveAria2Exe();
        if (exe is null) return false;

        _secret = Guid.NewGuid().ToString("N");
        // 端口从 16800 起试，最多试 20 个 —— 与 Flutter 版同区间。
        for (var attempt = 0; attempt < 20; attempt++)
        {
            _port = 16800 + attempt;
            if (!IsPortFree(_port)) continue;
            try
            {
                if (await TryStartOnceAsync(exe, _port)) return true;
            }
            catch
            {
                // 换下一个端口
            }
        }
        return false;
    }

    private async Task<bool> TryStartOnceAsync(string exe, int port)
    {
        var args = new List<string>
        {
            "--enable-rpc",
            $"--rpc-listen-port={port}",
            $"--rpc-secret={_secret}",
            "--rpc-listen-all=false",
            "--rpc-allow-origin-all=false",
            "--continue=true",
            "--auto-file-renaming=false",
            "--allow-overwrite=false",
            "--file-allocation=none",
            "--summary-interval=0",
            "--console-log-level=warn",
            // 并发上限与默认目录都从设置读（改设置后重启引擎生效）
            $"--max-concurrent-downloads={Math.Clamp(AppSettings.Instance.MaxConcurrent, 1, 16)}",
            $"--dir={DefaultDir()}",
        };

        // **代理**（2026-10-28 修）：aria2c 是独立进程，**不会继承 .NET/系统的代理设置**。
        // 之前一个代理参数都没传，而 X 的图片在 pbs.twimg.com、抖音在 CDN 上，
        // 国内直连不通 → 任务永远停在「等待中」（超时前不报错，界面看起来就是卡死）。
        // 所以这里显式把代理传给 aria2c，取值口径与应用内 HTTP 一致：
        //   · ProxyEnable 关 → 不传；
        //   · 用系统代理 → 直接读 IE 设置里的 ProxyServer；
        //   · 自定义 → 用 ProxyUrl。
        var proxy = ResolveProxyForAria2();
        if (!string.IsNullOrEmpty(proxy))
        {
            // http/https 都走同一个代理（all-proxy 覆盖全部协议）
            args.Add("--all-proxy=" + proxy);
            // 代理是本机时别走 loopback 例外，否则等于没走代理
            args.Add("--no-proxy=");
        }

        // **UA**：X 与抖音的图床/CDN 会对默认的 aria2 UA 返回 403，必须伪装成浏览器。
        args.Add("--user-agent=" + DownloadUserAgent);


        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(exe)!,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        _child = Process.Start(psi);
        if (_child is null) return false;

        // 父进程消失时自动结束 aria2c（Windows Job Object）
        try { ChildProcessGuard.Bind(_child); } catch { }

        // 等 RPC 就绪
        for (var i = 0; i < 40; i++)
        {
            await Task.Delay(150);
            if (_child.HasExited) return false;
            if (await PingAsync()) return true;
        }
        try { _child.Kill(entireProcessTree: true); } catch { }
        return false;
    }

    /// <summary>最近一次目录解析的失败原因（界面与日志用）。</summary>
    public static string LastDirError { get; private set; } = "";

    /// <summary>默认下载目录：设置里有就用设置，否则用 数据目录\downloads。</summary>
    public static string DefaultDir()
    {
        LastDirError = "";
        var configured = AppSettings.Instance.SaveDirBase;

        // 开发版（Debug）：严格锁在 exe\downloads（用户 2026-10-28 要求）。
        // 配置里哪怕写着外部盘，也一律忽略，避免测试产物写到别的盘去。
        var resolved = AppPaths.ResolveDownloadDir(configured, out var locked);
        if (locked)
        {
            LastDirError = $"开发版已忽略外部目录「{configured}」，强制使用 {resolved}";
            Log(LastDirError);
        }
        if (AppPaths.LockToInstallDir)
        {
            System.IO.Directory.CreateDirectory(resolved);
            return resolved;
        }

        if (!string.IsNullOrWhiteSpace(configured))
        {
            try
            {
                System.IO.Directory.CreateDirectory(configured);
                // 只建目录不够 —— 还要真写一次，否则权限问题会在 aria2 下载时
                // 才暴露（实测 AppContainer 下 CreateDirectory 可能"成功"但写入失败）。
                var probe = System.IO.Path.Combine(configured, ".write_probe");
                System.IO.File.WriteAllText(probe, "ok");
                System.IO.File.Delete(probe);
                return configured;
            }
            catch (Exception ex)
            {
                // **不静默吞**：把原因记下来，设置页与日志都能看到。
                LastDirError = $"自定义目录不可用（{configured}）：{ex.GetType().Name} {ex.Message}";
                Log(LastDirError);
            }
        }
        // 兜底走 AppPaths.DefaultDownloadDir（= 安装目录\downloads）。
        // 以前这里写的是 DataDir\downloads，两处口径不一致，用户看到「数据目录」
        // 和实际下载落点对不上。
        var dir = AppPaths.DefaultDownloadDir;
        try { System.IO.Directory.CreateDirectory(dir); } catch { }
        return dir;
    }

    /// <summary>下载用的浏览器 UA（X/抖音的图床会拒绝 aria2 默认 UA）。</summary>
    private const string DownloadUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";

    /// <summary>
    /// 给 aria2c 用的代理地址。
    ///
    /// aria2c 是**独立进程**，不会自动继承系统的 .NET 代理配置 —— 必须显式传。
    /// 取值顺序与应用内 HttpClient 保持一致：
    ///   1. ProxyEnable 关 → 返回空（直连）；
    ///   2. ProxyUseSystem → 读注册表里 IE/系统代理的 ProxyServer；
    ///   3. 否则用设置里的 ProxyUrl。
    /// 系统代理是分协议写法（如 <c>http=127.0.0.1:7897;https=127.0.0.1:7897</c>）时，
    /// 取 http 那一项即可（aria2 的 all-proxy 对两种协议都用它）。
    /// </summary>
    private static string ResolveProxyForAria2()
    {
        try
        {
            var cfg = AppSettings.Instance;
            if (!cfg.ProxyEnable) return "";

            string raw;
            if (cfg.ProxyUseSystem)
            {
                using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
                if (key?.GetValue("ProxyEnable") is not int on || on == 0) return "";
                raw = key.GetValue("ProxyServer") as string ?? "";
            }
            else
            {
                raw = cfg.ProxyUrl ?? "";
            }

            raw = raw.Trim();
            if (raw.Length == 0) return "";

            // 分协议写法：取 http= 那一项
            if (raw.Contains((char)61))
            {
                foreach (var part in raw.Split((char)59))
                {
                    var kv = part.Split((char)61, 2);
                    if (kv.Length == 2 && kv[0].Trim().Equals("http", StringComparison.OrdinalIgnoreCase))
                    { raw = kv[1].Trim(); break; }
                }
            }

            if (raw.Length == 0) return "";
            // 没写协议就补 http://（aria2 要求带 scheme）
            if (!raw.Contains("://")) raw = "http://" + raw;
            return raw;
        }
        catch { return ""; }
    }


    /// <summary>
    /// 按保留天数清理日志文件（用户 2026-10-26 要求「日志增加自动删除」）。
    /// 保留天数 0 = 不删除。返回删掉的文件数，供设置页显示。
    /// </summary>
    public static int PurgeOldLogs()
    {
        var days = AppSettings.Instance.LogRetentionDays;
        if (days <= 0) return 0;
        var dir = System.IO.Path.Combine(AppPaths.DataDir, "logs");
        if (!System.IO.Directory.Exists(dir)) return 0;

        var cutoff = DateTime.Now.AddDays(-days);
        var removed = 0;
        try
        {
            foreach (var f in System.IO.Directory.EnumerateFiles(dir))
            {
                try
                {
                    if (System.IO.File.GetLastWriteTime(f) < cutoff)
                    {
                        System.IO.File.Delete(f);
                        removed++;
                    }
                }
                catch { }
            }
        }
        catch { }
        if (removed > 0) Log("[日志清理] 删除 " + removed + " 个超过 " + days + " 天的日志文件");
        return removed;
    }
    /// <summary>写一行诊断日志到 数据目录\app.log（设置里关了写日志就不写）。</summary>
    public static void Log(string message)
    {
        try
        {
            if (!AppSettings.Instance.WriteLogs) return;
            var path = System.IO.Path.Combine(AppPaths.DataDir, "app.log");
            System.IO.File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {message}{Environment.NewLine}");
        }
        catch { }
    }

    private static bool IsPortFree(int port)
    {
        try
        {
            var l = new System.Net.Sockets.TcpListener(IPAddress.Loopback, port);
            l.Start();
            l.Stop();
            return true;
        }
        catch { return false; }
    }

    /// <summary>找 aria2c.exe：优先 exe 同级，其次 assets 目录。</summary>
    private static string? ResolveAria2Exe()
    {
        var baseDir = AppContext.BaseDirectory;
        foreach (var candidate in new[]
                 {
                     Path.Combine(baseDir, "aria2c.exe"),
                     Path.Combine(baseDir, "Assets", "aria2c.exe"),
                     Path.Combine(baseDir, "assets", "aria2c.exe"),
                 })
        {
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>把 URL 加入下载队列，返回 gid。</summary>
    public async Task<string?> AddUriAsync(string url, string? dir = null, string? outName = null)
    {
        var opts = new Dictionary<string, object>();
        if (!string.IsNullOrWhiteSpace(dir)) opts["dir"] = dir!;
        if (!string.IsNullOrWhiteSpace(outName)) opts["out"] = outName!;

        var result = await CallAsync("aria2.addUri", new object[] { new[] { url }, opts });
        return result?.ValueKind == JsonValueKind.String ? result.Value.GetString() : null;
    }

    /// <summary>查任务状态。</summary>
    public async Task<AriaTask?> TellStatusAsync(string gid)
    {
        var r = await CallAsync("aria2.tellStatus", new object[]
        {
            gid,
            new[] { "gid", "status", "completedLength", "totalLength", "files", "dir", "errorMessage", "downloadSpeed" },
        });
        if (r is null || r.Value.ValueKind != JsonValueKind.Object) return null;
        return ParseTask(r.Value);
    }

    /// <summary>列出全部任务（活动 + 等待 + 已停止）。</summary>
    public async Task<List<AriaTask>> TellAllAsync()
    {
        var keys = new[] { "gid", "status", "completedLength", "totalLength", "files", "dir", "errorMessage", "downloadSpeed" };
        var list = new List<AriaTask>();
        foreach (var method in new[] { "aria2.tellActive", "aria2.tellWaiting", "aria2.tellStopped" })
        {
            JsonElement? r;
            try
            {
                r = method == "aria2.tellActive"
                    ? await CallAsync(method, new object[] { keys })
                    : await CallAsync(method, new object[] { 0, 1000, keys });
            }
            catch { continue; }

            if (r is null || r.Value.ValueKind != JsonValueKind.Array) continue;
            foreach (var item in r.Value.EnumerateArray())
            {
                var t = ParseTask(item);
                if (t is not null) list.Add(t);
            }
        }
        return list;
    }

    public Task PauseAsync(string gid) => CallAsync("aria2.pause", new object[] { gid });
    public Task UnpauseAsync(string gid) => CallAsync("aria2.unpause", new object[] { gid });
    public Task RemoveAsync(string gid) => CallAsync("aria2.remove", new object[] { gid });
    public Task PurgeAsync() => CallAsync("aria2.purgeDownloadResult", Array.Empty<object>());

    private static AriaTask? ParseTask(JsonElement e)
    {
        try
        {
            var gid = e.TryGetProperty("gid", out var g) ? g.GetString() ?? "" : "";
            var statusStr = e.TryGetProperty("status", out var s) ? s.GetString() ?? "" : "";
            var completed = e.TryGetProperty("completedLength", out var c) && long.TryParse(c.GetString(), out var cv) ? cv : 0;
            var total = e.TryGetProperty("totalLength", out var t) && long.TryParse(t.GetString(), out var tv) ? tv : 0;
            var dir = e.TryGetProperty("dir", out var d) ? d.GetString() ?? "" : "";
            var err = e.TryGetProperty("errorMessage", out var em) ? em.GetString() ?? "" : "";
            var speed = e.TryGetProperty("downloadSpeed", out var sp) && long.TryParse(sp.GetString(), out var sv) ? sv : 0;

            var name = "";
            if (e.TryGetProperty("files", out var files) && files.ValueKind == JsonValueKind.Array)
            {
                foreach (var f in files.EnumerateArray())
                {
                    if (f.TryGetProperty("path", out var p))
                    {
                        name = Path.GetFileName(p.GetString() ?? "");
                        break;
                    }
                }
            }

            var status = statusStr switch
            {
                "active" => AriaStatus.Active,
                "waiting" => AriaStatus.Waiting,
                "paused" => AriaStatus.Paused,
                "error" => AriaStatus.Error,
                "complete" => AriaStatus.Complete,
                "removed" => AriaStatus.Removed,
                _ => AriaStatus.Waiting,
            };

            return new AriaTask(gid, status, completed, total, name, dir, err, speed);
        }
        catch { return null; }
    }

    private async Task<bool> PingAsync()
    {
        try
        {
            var r = await CallAsync("aria2.getVersion", Array.Empty<object>());
            return r is not null;
        }
        catch { return false; }
    }

    /// <summary>发一次 JSON-RPC 调用（HTTP POST，比 WebSocket 简单且够用）。</summary>
    private async Task<JsonElement?> CallAsync(string method, object[] parameters)
    {
        var payload = new
        {
            jsonrpc = "2.0",
            id = Guid.NewGuid().ToString("N"),
            method,
            @params = PrependSecret(parameters),
        };
        var json = JsonSerializer.Serialize(payload);
        using var content = new StringContent(json, Encoding.UTF8, "application/json");
        using var resp = await _http.PostAsync($"http://127.0.0.1:{_port}/jsonrpc", content);
        var text = await resp.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(text);
        if (doc.RootElement.TryGetProperty("error", out _)) return null;
        if (!doc.RootElement.TryGetProperty("result", out var result)) return null;
        return result.Clone();
    }

    private object[] PrependSecret(object[] parameters)
    {
        var list = new List<object> { $"token:{_secret}" };
        list.AddRange(parameters);
        return list.ToArray();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try
        {
            if (_child is { HasExited: false })
            {
                _child.Kill(entireProcessTree: true);
                _child.WaitForExit(2000);
            }
        }
        catch { }
        try { _child?.Dispose(); } catch { }
        _http.Dispose();
    }
}

/// <summary>
/// 用 Windows Job Object 把子进程绑到当前进程 —— 本进程被杀时子进程一起死。
/// Flutter 版注释里说的「父进程一消失 aria2c 自己退出」就是靠这个。
/// </summary>
internal static class ChildProcessGuard
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr a, string? name);

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint len);

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    private static IntPtr _job = IntPtr.Zero;

    public static void Bind(Process p)
    {
        if (_job == IntPtr.Zero)
        {
            _job = CreateJobObject(IntPtr.Zero, null);
            if (_job == IntPtr.Zero) return;
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            var len = System.Runtime.InteropServices.Marshal.SizeOf(info);
            var ptr = System.Runtime.InteropServices.Marshal.AllocHGlobal(len);
            try
            {
                System.Runtime.InteropServices.Marshal.StructureToPtr(info, ptr, false);
                SetInformationJobObject(_job, JobObjectExtendedLimitInformation, ptr, (uint)len);
            }
            finally
            {
                System.Runtime.InteropServices.Marshal.FreeHGlobal(ptr);
            }
        }
        AssignProcessToJobObject(_job, p.Handle);
    }

}