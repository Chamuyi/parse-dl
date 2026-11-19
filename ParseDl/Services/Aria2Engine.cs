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
    /// <summary>
    /// 引擎启动时**实际**传给 aria2c 的代理（空串＝没走代理）。
    ///
    /// aria2c 是独立进程，代理只在命令行里给一次、之后永不重读；
    /// 而代理软件常常晚于本程序启动，于是 aria2 带着「没有代理」一直跑到死。
    /// 留这份快照是为了让上层能发现代理已变更，主动重启引擎。
    /// </summary>
    private string _startedProxy = "";
    private int _port;
    // **超时不能设太短**（2026-10-28 修）：原来是 8 秒，批量入队时 aria2 要一个个
    // 建连接、写 .aria2 控制文件，几十上百个任务连着提很容易超过 8 秒，
    // 于是用户看到「入队异常：The request was canceled due to the configured
    // HttpClient.Timeout of 8 seconds elapsing」。
    //
    // 这里只管**与本机 aria2 的 RPC 通信**（127.0.0.1），不是下载本身，
    // 所以放宽到 60 秒没有副作用 —— 下载慢是 aria2 那边的事，与本超时无关。
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private bool _disposed;

    public bool IsRunning => _child is { HasExited: false };

    /// <summary>引擎启动时的代理快照（供外部比对是否已过时）。</summary>
    public string StartedProxy => _startedProxy;

    /// <summary>按当前设置**该**用的代理（空串＝不该走代理）。</summary>
    public static string CurrentProxy() => ResolveProxyForAria2() ?? "";

    /// <summary>
    /// 停掉子进程但保留端口/密钥，供上层「带新参数重启」。
    /// 与 Dispose 的区别：不释放 _http、不置 _disposed，所以还能再 StartAsync。
    /// </summary>
    public void StopForRestart()
    {
        try
        {
            if (_child is { HasExited: false })
            {
                _child.Kill(entireProcessTree: true);
                _child.WaitForExit(3000);
            }
        }
        catch { }
        try { _child?.Dispose(); } catch { }
        _child = null;
        _startedProxy = "";
    }

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

            // **必须允许覆盖**（2026-10-29 找到的真凶之二）：
            //
            // 之前是 `--allow-overwrite=false`，配合 `--continue=true` 会踩到这个坑：
            // 目标文件已存在、但 `.aria2` 控制文件不存在时，aria2 报
            // `errorCode=13: File ... exists, but a control file(*.aria2) does not exist.
            //  Download was canceled in order to prevent your file from being truncated to 0.`
            // 然后**直接失败**，一个字节都不下。
            //
            // 实测：153 个任务全部是这个错，界面看着就是「下载卡住」。
            //
            // 允许覆盖之后，已存在但没有控制文件的会**重新下载覆盖**；
            // 有 `.aria2` 控制文件的仍然正常续传（`--continue=true` 优先）。
            "--allow-overwrite=true",
            "--file-allocation=none",
            "--summary-interval=0",
            "--console-log-level=warn",
            // 并发上限与默认目录都从设置读（改设置后重启引擎生效）。
            // **2026-10-31 改回读设置**：用户明确要求并发 5 ——「按顺序下载」的语义
            // 改由「入队顺序 + aria2 的 FIFO waiting 队列」保证，并发只决定同时在跑几个。
            // 原来为了「绝对串行」写死成 1，用户改设置里的并发数完全不生效。
            //
            // 为什么并发可以调而顺序不乱：aria2 对 waiting 状态的任务是 **FIFO**
            // （按 addUri 的先后派人），所以并发 N 只是「同时在下 N 个」，
            // 先后次序仍由入队顺序决定。
            "--max-concurrent-downloads=" + Math.Clamp(AppSettings.Instance.MaxConcurrent, 1, 16),
            $"--dir={DefaultDir()}",

            // ── 重试与超时（2026-10-28 加）────────────────────────────
            // 用户报有 4 个任务报「SSL/TLS handshake failure」。这是**代理链路抖动**
            // 的典型表现（握手阶段被掐断），不是文件本身的问题 —— 重试基本都能过。
            // aria2 默认 max-tries=5 且没有连接/读取超时，走不稳定代理时不够用。
            "--max-tries=10",

            // ── 连接数限制（2026-10-28 实测定位）────────────────────
            // 用户一次入队 189 个任务后，代理端口 7897 上出现了 **198 个并发连接**，
            // 代理被压垮 → aria2 的 RPC 线程也跟着卡住（`aria2.tellActive` 要 25 秒
            // 且超时），于是暂停/重试/刷新全部像「按了没反应」。
            //
            // aria2 默认 `--max-connection-per-server=1` 是每个服务器 1 条，
            // 但 X 的图片全在 pbs.twimg.com **同一个域名**下 —— 默认值理论上够；
            // 真正的问题是 `--max-concurrent-downloads=5` 之外，
            // 每个下载还会额外建 DNS/TLS 辅助连接。这里显式收紧：
            // **不要在这里设 --referer！**（2026-10-29 回归修复）
            //
            // 上一版为了修 B 站 1080P 在这里加了 "--referer=https://www.bilibili.com/"，
            // 那是**全局参数**，对所有下载生效 —— 结果 X 的 video.twimg.com 带着
            // B 站 Referer 被 CDN 直接 403（实测 code=403 size=0）。
            // 表现为「X 的队列全红、列表一直闪」。
            //
            // 正确做法：Referer 按任务设置（见 DownloadStore.AddAsync 的 referer 参数），
            // B 站任务带 B 站 Referer，X/抖音任务不带。
            "--max-connection-per-server=1",
            "--split=1",
            "--min-split-size=1M",
            "--retry-wait=3",
            "--always-resume=true",
            "--max-resume-failure-tries=0",
            // 连接/读取超时给足（走代理时首字节较慢，太短会误杀）
            "--connect-timeout=20",
            "--timeout=30",
            // 证书校验：走代理时证书链细节常被中间设备破坏，这里不因它失败
            "--check-certificate=false",
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
        // 记下这次实际用的代理，供上层检测「代理变了需要重启」。
        _startedProxy = proxy ?? "";

        // **UA**：X 与抖音的图床/CDN 会对默认的 aria2 UA 返回 403，必须伪装成浏览器。
        args.Add("--user-agent=" + DownloadUserAgent);


        // **不能重定向 stdout/stderr 而不读取**（2026-10-29 找到的真凶）：
        //
        // 之前这里 RedirectStandardOutput/Error 都开着，但**代码从来没读过这两个流**。
        // 子进程的管道缓冲区（约 4KB）填满之后，aria2 会**阻塞在写日志那一步**——
        // 于是整个进程卡死：RPC 全部超时（实测 tellActive 30 秒不返回）、
        // 下载速度恒为 0、.aria2 控制文件永远是空的。
        //
        // 这正是用户反复说的「下载卡住了」。
        // 现在不重定向：CreateNoWindow 下子进程输出直接丢弃，
        // aria2 永远不会因为写日志而卡住。
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = false,
            RedirectStandardError = false,
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
    internal static string ResolveProxyForAria2()
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
        var dir = LogDir;
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
    /// <summary>
    /// 日志目录：<数据目录>\\logs。
    ///
    /// **必须与设置页显示的路径一致**（2026-10-30 修）：设置页写的是
    /// `DataDir\\logs`，但原来 Log() 实际写 `DataDir\\app.log` —— 于是设置页
    /// 点「打开日志目录」看到的是空文件夹，用户以为「没有日志」。
    /// 「按天数自动清理」也一直在扫一个空目录，等于从未生效。
    /// </summary>
    public static string LogDir => System.IO.Path.Combine(AppPaths.DataDir, "logs");

    /// <summary>
    /// 本次运行的日志文件 —— **每次启动新建一个，按启动时间命名**（2026-10-30 用户要求）。
    ///
    /// 用户原话：十点打开用了五分钟关掉，十点十分再打开，就重新建一个日志文件。
    /// 所以文件名取「进程启动那一刻」的时间戳，形如 2026-10-30_22-45-01.log，
    /// 一次运行一个文件，互不追加。好处是排查时能精确定位是哪一次运行。
    /// </summary>
    public static string LogFilePath => System.IO.Path.Combine(LogDir, _sessionStamp + ".log");

    /// <summary>本进程的启动时间戳 yyyy-MM-dd_HH-mm-ss，类加载时固定。</summary>
    private static readonly string _sessionStamp =
        System.Diagnostics.Process.GetCurrentProcess().StartTime.ToString("yyyy-MM-dd_HH-mm-ss");

    /// <summary>写一行诊断日志到本次运行的日志文件（设置里关了写日志就不写）。</summary>
    public static void Log(string message)
    {
        try
        {
            if (!AppSettings.Instance.WriteLogs) return;
            System.IO.Directory.CreateDirectory(LogDir);
            MigrateLegacyLogOnce();
            System.IO.File.AppendAllText(LogFilePath,
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {message}{Environment.NewLine}");
        }
        catch { }
    }

    private static bool _legacyLogMigrated;

    /// <summary>
    /// 把历史遗留的 `<数据目录>\\app.log` 搬进日志目录（只做一次）。
    /// 原来日志写在数据目录根部，改成 `logs\\` 之后旧文件会留在外面；
    /// 这里把它整个搬到 `logs\\legacy-app.log`，内容不丢、目录不再混杂。
    /// </summary>
    private static void MigrateLegacyLogOnce()
    {
        if (_legacyLogMigrated) return;
        _legacyLogMigrated = true;
        try
        {
            var legacy = System.IO.Path.Combine(AppPaths.DataDir, "app.log");
            if (!System.IO.File.Exists(legacy)) return;
            var dest = System.IO.Path.Combine(LogDir, "legacy-app.log");
            if (System.IO.File.Exists(dest))
            {
                System.IO.File.AppendAllText(dest, System.IO.File.ReadAllText(legacy));
                System.IO.File.Delete(legacy);
            }
            else
            {
                System.IO.File.Move(legacy, dest);
            }
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

    /// <summary>
    /// 把 URL 加入下载队列，返回 gid。
    ///
    /// <paramref name="referer"/> 是**按任务**设的，不是全局的 —— 这一点很关键：
    /// B 站 1080P 视频流的 CDN 校验 Referer，不带就 403/errorCode=1；
    /// 但 X 的 video.twimg.com **带 B 站 Referer 反而被 403**（实测）。
    /// 所以只能在任务级设置，不能进 aria2 的全局启动参数。
    /// </summary>
    public async Task<string?> AddUriAsync(
        string url, string? dir = null, string? outName = null, string? referer = null)
    {
        var opts = new Dictionary<string, object>();
        if (!string.IsNullOrWhiteSpace(dir)) opts["dir"] = dir!;
        if (!string.IsNullOrWhiteSpace(outName)) opts["out"] = outName!;
        if (!string.IsNullOrWhiteSpace(referer)) opts["referer"] = referer!;

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
    /// <summary>
    /// 拉全部任务状态。
    ///
    /// ### ⚠ 只用于「进页面时的一次性对账」，**不要放进轮询**（2026-10-28 实测）
    /// 任务多时（实测 372 条）这个调用会**卡十几秒甚至超时**：
    /// aria2 要把每条任务的 `files` 数组都序列化一遍，数据量随任务数线性膨胀。
    /// 之前 DownloadStore 每 0.8 秒调一次它，于是暂停、重试、刷新全部
    /// 像「按了没反应」——其实都在等这个 RPC 返回。
    ///
    /// 轮询请用 <see cref="TellActiveAsync"/>：只问正在下的那几条。
    /// 这也是原项目 Flutter 版的做法（`_pollActive` 只拉 `store.activeGids()`）。
    /// </summary>
    public async Task<List<AriaTask>> TellAllAsync()
    {
        // **去掉 `files`**（2026-10-28 实测）：aria2 的 RPC 是**单线程串行处理**的，
        // 拉 `files` 要把每条任务的文件列表都序列化一遍，几百条任务时单次 RPC
        // 就要几十秒 —— 这期间**所有其他 RPC（含 pause/unpause/remove）全部排队**，
        // 用户看到的就是「按了暂停没反应、重试没反应、界面卡死」。
        // 文件名入队时就已经知道（存在 DownloadItem.FileName），不必反复问引擎。
        var keys = new[] { "gid", "status", "completedLength", "totalLength", "downloadSpeed", "errorMessage" };
        var list = new List<AriaTask>();
        foreach (var method in new[] { "aria2.tellActive", "aria2.tellWaiting", "aria2.tellStopped" })
        {
            JsonElement? r;
            try
            {
                // tellActive **不接受 keys**（传了 400），tellWaiting/tellStopped 则可以。
                // 条数上限压到 100：只是对账用，不必一次拉完整个队列。
                r = method == "aria2.tellActive"
                    ? await CallAsync(method, Array.Empty<object>())
                    : await CallAsync(method, new object[] { 0, 100, keys });
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

    /// <summary>
    /// **轮询专用**：只拉「正在下载」的那几条（对应原项目 `_pollActive`）。
    ///
    /// 不碰 waiting / stopped —— 那些状态变化由入队、暂停、完成事件自己维护，
    /// 不需要每 0.8 秒重拉一遍。任务再多，这个调用的开销也只与**并发数**有关。
    /// </summary>
    public async Task<List<AriaTask>> TellActiveAsync()
    {
        // **不能传 keys 参数**（2026-10-28 实测铁证）：aria2 的 `aria2.tellActive`
        // 只接受「无参」或「token」形式，多传一个 keys 数组直接 **400 Bad Request**。
        // 之前一直传 keys，于是这个调用**每次都失败** →
        //   · 「下载中」状态永远不更新（界面卡在入队时的样子）
        //   · 暂停/重试看不到效果（它们依赖状态刷新后才显示变化）
        //   · 轮询每秒白跑三次
        // 不传 keys 时 aria2 会返回全部 12 个字段，本来也不需要挑。
        var list = new List<AriaTask>();
        try
        {
            var r = await CallAsync("aria2.tellActive", Array.Empty<object>());
            if (r is null || r.Value.ValueKind != JsonValueKind.Array) return list;
            foreach (var item in r.Value.EnumerateArray())
            {
                var t = ParseTask(item);
                if (t is not null) list.Add(t);
            }
        }
        catch { }
        return list;
    }

    public Task PauseAsync(string gid) => CallAsync("aria2.pause", new object[] { gid });

    /// <summary>
    /// **批量暂停**（逐条，但不再拖垮界面）。
    ///
    /// ### 为什么不是「一次 RPC 传多个 GID」
    /// 实测（2026-10-28）：`aria2.pause` **只接受一个 GID**，
    /// 一次传 120 个直接 **400 Bad Request**。所以只能逐条。
    ///
    /// 但逐条本身不是问题：单次 pause 只要 ~20ms，189 条约 4 秒。
    /// 之前「按了没反应」的真凶是**轮询在拉全量重字段**（tellWaiting + files，
    /// 单次几十秒），把 aria2 的**单线程 RPC 队列**堵死了，pause 排在后面永远轮不上。
    /// 轮询改轻量后，逐条 pause 就能正常走完。
    /// </summary>
    public async Task PauseManyAsync(IReadOnlyList<string> gids)
    {
        foreach (var g in gids)
        {
            try { await CallAsync("aria2.pause", new object[] { g }); } catch { }
        }
    }

    /// <summary>
    /// 把一条**等待中**的任务挪到队列最前（`aria2.changePosition`，how = POS_SET）。
    ///
    /// 用途：模块间公平调度。aria2 的 `--max-concurrent-downloads` 是**全局**的，
    /// 它按队列顺序取任务，于是「先入队的模块」会把并发槽全占住，后来的模块
    /// 一条都轮不上（2026-11-20 实测：X 积压 352 条在前，抖音 229 条排在
    /// 101~329 位，5 个槽全是 X，抖音自动流程空等 30 分钟）。
    ///
    /// 只对 waiting/paused 状态的任务有效；已 active 的会返回错误，调用方自己跳过。
    /// 返回 true 表示 RPC 成功（不代表任务立刻开始下 —— 槽满时它只是排到队首，
    /// 等有槽空出来第一个上）。
    /// </summary>
    public async Task<bool> ChangePositionAsync(string gid, int pos, string how = "POS_SET")
    {
        if (string.IsNullOrEmpty(gid)) return false;
        try
        {
            var r = await CallAsync("aria2.changePosition", new object[] { gid, pos, how });
            return r is not null;
        }
        catch { return false; }
    }

    /// <summary>
    /// 按队列顺序取**等待中**任务的 gid（供公平调度判断「谁还排着队」）。
    ///
    /// 只取 gid，不取 files（几百条时 files 会让单次 RPC 拖到几十秒）。
    /// num = 1000：只是调度参考，不必真的拉完整个队列。
    /// </summary>
    public async Task<List<string>> TellWaitingGidsAsync(int offset = 0, int num = 1000)
    {
        var list = new List<string>();
        try
        {
            var r = await CallAsync("aria2.tellWaiting",
                new object[] { offset, num, new[] { "gid", "status" } });
            if (r is null || r.Value.ValueKind != JsonValueKind.Array) return list;
            foreach (var item in r.Value.EnumerateArray())
            {
                if (item.TryGetProperty("gid", out var g))
                {
                    var gid = g.GetString();
                    if (!string.IsNullOrEmpty(gid)) list.Add(gid!);
                }
            }
        }
        catch { }
        return list;
    }

    /// <summary>批量继续（同样逐条，aria2.unpause 也只接受一个 GID）。</summary>
    public async Task UnpauseManyAsync(IReadOnlyList<string> gids)
    {
        foreach (var g in gids)
        {
            try { await CallAsync("aria2.unpause", new object[] { g }); } catch { }
        }
    }
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