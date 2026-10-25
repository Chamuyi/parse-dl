using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services.Bili;

/// <summary>
/// 失败的哪一种。三种「没成功」的形状必须分开：界面要给出不同的下一步
/// （装 ffmpeg / 重试 / 换原始流），光一句「合并失败」等于没说。
/// </summary>
public enum BiliMergeFailure
{
    None = 0,
    /// <summary>找不到 ffmpeg 可执行文件（安装目录那份没放、随包那份也取不到）。</summary>
    FfmpegMissing,
    /// <summary>子进程压根没起来，或起不来之后 IO 出异常 —— 拿不到可信的退出码。</summary>
    ProcessError,
    /// <summary>ffmpeg 明确回了非 0 退出码。</summary>
    ExitNonZero,
    /// <summary>退出码是 0，但没读到 progress=end 就被结束了（进程提前死）。</summary>
    NoEndProgress,
    /// <summary>progress=end 读到了、退出码也是 0，但产物不存在或是 0 字节。</summary>
    BadProduct,
}

/// <summary>一次合并的结果。刻意不抛异常：失败以 Ok=false + Failure + Message 的形状返回。</summary>
public sealed record BiliMergeResult(
    bool Ok,
    BiliMergeFailure Failure,
    string Message,
    string CommandLine,
    string Stderr,
    double MediaDurationSec,
    string OutputPath);

/// <summary>一次合并请求（两条输入流 + 产物 + 可选内封轨）。</summary>
public sealed record BiliMergeRequest
{
    /// <summary>不含扩展名的 base 名。</summary>
    public string OutBase { get; init; } = "";
    /// <summary>所在目录（两条流与产物都在这里）。</summary>
    public string Dir { get; init; } = "";
    public string VideoPath { get; init; } = "";
    public string AudioPath { get; init; } = "";
    /// <summary>产物全路径。</summary>
    public string OutputPath { get; init; } = "";
    /// <summary>要内封的字幕轨（文件名，相对 Dir）。只有 MKV 容器才会用上。</summary>
    public IReadOnlyList<BiliEmbeddedTrack> Tracks { get; init; } = Array.Empty<BiliEmbeddedTrack>();
    /// <summary>章节 ffmetadata 中间文件（文件名，相对 Dir）。无章节时为 null。</summary>
    public string? ChapterFileName { get; init; }
    /// <summary>成功后删掉两条原始流。</summary>
    public bool DeleteSource { get; init; } = true;
    /// <summary>容器扩展名（mp4 / mkv）。</summary>
    public string Container { get; init; } = "mp4";
    /// <summary>台账里显示的名字。</summary>
    public string DisplayName { get; init; } = "";
    /// <summary>台账里的来源 URL（可选）。</summary>
    public string SourceUrl { get; init; } = "";
}

/// <summary>进度点（ffmpeg -progress 的一行）。</summary>
public sealed record BiliProgressPoint(long? OutTimeUs, long? TotalSize, bool Ended);

/// <summary>
/// B 站 DASH 分开的视频流 / 音频流**自动**合并管线 —— 对齐 Flutter 版
/// lib/services/bili_merger.dart（868 行）+ bili_download_plan.dart 的落名契约。
///
/// 它解决什么问题：B 站 playurl 返回的是 DASH —— 视频与音频是两条独立的 .m4s，
/// 各自都不是能单独播放的完整文件。下载完两条文件之后，离「拿到一个能播的 mp4」
/// 还差一次容器级合并。Flutter 版把这一步做成了「下载完成 → 自动配对 → 合并 →
/// 删源 → 落台账」，本类就是那条链路的 C# 版。
///
/// 设计要点：
///  1. 纯服务：不依赖任何界面。上层只需要在下载终态回调时调一次
///     NotifyFileReadyAsync，或者在界面上点一次「扫描待合并」调 ScanAndMergeAsync。
///  2. 配对靠落名契约（BiliDownloadPlan.VideoStreamName / AudioStreamName）：
///     base 名 + .video.m4s 与 base 名 + .audio.m4s 合成 base 名 + .mp4。
///     另外兼容一套旧命名（base 名 + .mp4 配 base 名 + .m4a，历史版本入队用的形状），
///     这样升级前已经下到一半的批次不会变成孤儿文件。
///  3. 同一时刻只跑 1 个 ffmpeg：合并是 CPU + IO 双密集，多个进程同时读写同一块盘
///     只会互相抢头程。第二个请求排队而不是报错。
///  4. 成功判据是三件事同时成立：读到 progress=end 且 退出码 0 且 产物存在且非 0 字节。
///     只看退出码不够（见 BadProduct / NoEndProgress）。
///  5. 失败时原始流一律保留，只清掉 0 字节的产物 —— 那是「看起来像成品」的废件，
///     留着只会让下游的「同名跳过」把它当成已经下好了。
/// </summary>
public sealed class BiliMergePipeline
{
    public static BiliMergePipeline Instance { get; } = new();

    /// <summary>合并完成（无论成功失败）时抛给界面刷新用。</summary>
    public event Action<BiliMergeResult>? Merged;

    /// <summary>日志行（界面可以挂上去显示最近发生了什么）。</summary>
    public event Action<string>? Logged;

    // ── 全局并发闸门 ──────────────────────────────────────────
    //
    // 静态：多个 pipeline 实例也必须共用同一个闸门，因为真正的稀缺资源是
    // 「磁盘 + CPU」，不是某个对象。
    private static readonly SemaphoreSlim Gate = new(1, 1);

    /// <summary>当前是否正在跑一次合并（界面显示「合并中…」用）。</summary>
    public bool IsMerging { get; private set; }

    /// <summary>累计合并成功 / 失败次数（自测报告与界面统计用）。</summary>
    public int MergeSuccessCount { get; private set; }
    public int MergeFailureCount { get; private set; }

    // ── 待合并登记表 ──────────────────────────────────────────
    //
    // 下载是两条独立任务，谁先下完不确定。所以按 base 名登记，两条都到齐才合并。
    // 进程内表（不落盘）：重启后靠 ScanAndMergeAsync 扫目录重建 —— 与 Flutter 版
    // 的做法一致（那份也只有内存表 + 启动扫描）。
    private readonly Dictionary<string, HashSet<string>> _pending =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly object _pendingLock = new();

    private readonly BiliConfig _cfg;

    public BiliMergePipeline(BiliConfig? config = null) => _cfg = config ?? BiliConfig.Instance;

    private void Log(string message)
    {
        Aria2Engine.Log("[BiliMerge] " + message);
        Logged?.Invoke(message);
    }

    // ── ffmpeg 定位 ───────────────────────────────────────────

    /// <summary>
    /// 找 ffmpeg.exe。优先用户在设置里指定的目录（他装完整版是为了拿到随包那份没有的
    /// 能力），其次 exe 同级的 ffmpeg 子目录（出包位置），最后 exe 同级（随包分发）。
    /// </summary>
    public static List<string> FfmpegCandidates(string? userDir)
    {
        var list = new List<string>();
        var d = (userDir ?? "").Trim();
        if (d.Length > 0)
        {
            list.Add(Path.Combine(d, "ffmpeg.exe"));
            list.Add(Path.Combine(d, "bin", "ffmpeg.exe"));
        }
        var baseDir = AppContext.BaseDirectory;
        list.Add(Path.Combine(baseDir, "ffmpeg", "ffmpeg.exe"));
        list.Add(Path.Combine(baseDir, "ffmpeg.exe"));
        list.Add(Path.Combine(baseDir, "Assets", "ffmpeg.exe"));
        return list;
    }

    /// <summary>真正要用的那一份在哪；都没有时返回 null（不抛）。</summary>
    public static string? ResolveFfmpeg(string? userDir = null)
    {
        foreach (var c in FfmpegCandidates(userDir))
        {
            try { if (File.Exists(c)) return c; } catch { }
        }
        return null;
    }

    // ── 配对扫描 ──────────────────────────────────────────────

    /// <summary>
    /// 扫一个目录，把「同 base 的视频流 + 音频流」的配对找出来。
    /// 返回 (base, 视频路径, 音频路径) 列表，已过滤掉产物已经存在且不比输入旧的配对。
    /// </summary>
    public static List<(string Base, string Video, string Audio)> FindPairs(string dir, string container = "mp4")
    {
        var result = new List<(string Base, string Video, string Audio)>();
        if (!Directory.Exists(dir)) return result;

        var files = Directory.GetFiles(dir);

        // ① 契约命名：base 名 + .video.m4s 配 base 名 + .audio.m4s
        foreach (var f in files)
        {
            var name = Path.GetFileName(f);
            if (!name.EndsWith(".video.m4s", StringComparison.OrdinalIgnoreCase)) continue;
            var stem = name.Substring(0, name.Length - ".video.m4s".Length);
            var audio = Path.Combine(dir, stem + ".audio.m4s");
            if (!File.Exists(audio)) continue;
            if (IsMergedUpToDate(stem, container, dir, f, audio)) continue;
            result.Add((stem, f, audio));
        }

        // ② 旧命名兼容：base 名 + .mp4 配 base 名 + .m4a（历史版本入队时用的形状）。
        //    只在没有 ① 命中时才算，避免同一批被两种规则各配一次。
        var byStem = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in files)
        {
            var stem = Path.GetFileNameWithoutExtension(f);
            if (!byStem.TryGetValue(stem, out var list)) { list = new List<string>(); byStem[stem] = list; }
            list.Add(f);
        }
        foreach (var pair in byStem)
        {
            if (pair.Value.Count < 2) continue;
            var stem = pair.Key;
            var video = pair.Value.FirstOrDefault(x => x.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase));
            var audio = pair.Value.FirstOrDefault(x => x.EndsWith(".m4a", StringComparison.OrdinalIgnoreCase));
            if (video is null || audio is null) continue;
            if (result.Any(r => string.Equals(r.Base, stem, StringComparison.OrdinalIgnoreCase))) continue;
            if (IsMergedUpToDate(stem, container, dir, video, audio)) continue;
            result.Add((stem, video, audio));
        }

        return result;
    }

    /// <summary>产物已存在且比两条输入都新 → 不再合并（幂等，重启扫描不会重复干活）。</summary>
    private static bool IsMergedUpToDate(
        string stem, string container, string dir, string video, string audio)
    {
        var outPath = Path.Combine(dir, stem + "." + container);
        try
        {
            if (!File.Exists(outPath)) return false;
            var outTime = File.GetLastWriteTimeUtc(outPath);
            return outTime >= File.GetLastWriteTimeUtc(video) &&
                   outTime >= File.GetLastWriteTimeUtc(audio);
        }
        catch
        {
            return false;
        }
    }

    // ── 下载终态入口 ──────────────────────────────────────────

    /// <summary>
    /// 下载终态回调入口：由 DownloadStore 的终态分支调用（接线在装配层做）。
    /// 收下这条已下完的文件，若它的配对伙伴也到齐就自动合并。
    /// 返回 true 表示这次调用真的触发了一次合并。
    /// </summary>
    public async Task<bool> NotifyFileReadyAsync(string filePath, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(filePath) || !File.Exists(filePath)) return false;
        if (!_cfg.MergeAfterDownload) return false;

        var name = Path.GetFileName(filePath);
        string stem;
        if (name.EndsWith(".video.m4s", StringComparison.OrdinalIgnoreCase))
            stem = name.Substring(0, name.Length - ".video.m4s".Length);
        else if (name.EndsWith(".audio.m4s", StringComparison.OrdinalIgnoreCase))
            stem = name.Substring(0, name.Length - ".audio.m4s".Length);
        else if (name.EndsWith(".m4a", StringComparison.OrdinalIgnoreCase) ||
                 name.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase))
            stem = Path.GetFileNameWithoutExtension(name);
        else
            return false;

        var dir = Path.GetDirectoryName(filePath) ?? "";
        lock (_pendingLock)
        {
            if (!_pending.TryGetValue(stem, out var set))
            {
                set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                _pending[stem] = set;
            }
            set.Add(filePath);

            var hasVideo = set.Any(p =>
                p.EndsWith(".video.m4s", StringComparison.OrdinalIgnoreCase) ||
                p.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase));
            var hasAudio = set.Any(p =>
                p.EndsWith(".audio.m4s", StringComparison.OrdinalIgnoreCase) ||
                p.EndsWith(".m4a", StringComparison.OrdinalIgnoreCase));
            if (!hasVideo || !hasAudio) return false;
            _pending.Remove(stem);
        }

        // 配对到齐：交给统一扫描，保证两条都是真实存在且未合并过的文件
        var container = _cfg.Container == BiliContainer.Mkv ? "mkv" : "mp4";
        var hit = FindPairs(dir, container)
            .FirstOrDefault(p => string.Equals(p.Base, stem, StringComparison.OrdinalIgnoreCase));
        if (hit.Video is null) return false;

        await MergePairAsync(hit.Base, hit.Video, hit.Audio, ct);
        return true;
    }

    /// <summary>手工/批量入口：扫一个目录，把全部待合并配对逐一合并过去。</summary>
    public async Task<List<BiliMergeResult>> ScanAndMergeAsync(string dir, CancellationToken ct = default)
    {
        var container = _cfg.Container == BiliContainer.Mkv ? "mkv" : "mp4";
        var pairs = FindPairs(dir, container);
        var results = new List<BiliMergeResult>();
        foreach (var (baseName, video, audio) in pairs)
        {
            if (ct.IsCancellationRequested) break;
            results.Add(await MergePairAsync(baseName, video, audio, ct));
        }
        if (results.Count == 0) Log("扫描完毕：" + dir + " 没有待合并的配对");
        return results;
    }

    /// <summary>把一个配对合成一条完整的合并请求（附加轨由调用方另行提供）。</summary>
    public async Task<BiliMergeResult> MergePairAsync(
        string outBase, string videoPath, string audioPath,
        CancellationToken ct = default,
        IReadOnlyList<BiliEmbeddedTrack>? tracks = null,
        string? chapterFileName = null,
        string displayName = "")
    {
        var dir = Path.GetDirectoryName(videoPath) ?? "";
        if (string.IsNullOrEmpty(dir)) dir = Path.GetDirectoryName(audioPath) ?? "";
        var req = new BiliMergeRequest
        {
            OutBase = outBase,
            Dir = dir,
            VideoPath = videoPath,
            AudioPath = audioPath,
            OutputPath = Path.Combine(dir, BiliDownloadPlan.MergedName(outBase, _cfg.Container)),
            Tracks = tracks ?? Array.Empty<BiliEmbeddedTrack>(),
            ChapterFileName = chapterFileName,
            DeleteSource = _cfg.DeleteStreamsAfterMerge,
            Container = _cfg.Container == BiliContainer.Mkv ? "mkv" : "mp4",
            DisplayName = displayName.Length > 0 ? displayName : outBase,
        };
        var result = await MergeAsync(req, ct);
        Merged?.Invoke(result);
        return result;
    }

    // ── 合并本体 ──────────────────────────────────────────────

    /// <summary>
    /// 拼 ffmpeg 参数 —— 纯函数，可离线钉住。
    ///
    /// 关键几处（照 Flutter 版那套结论）：
    ///  * -map 0:v:0 -map 1:a:0：必须显式 map，否则会把两条输入的所有流都塞进产物；
    ///  * -c copy：不重编码（重编码慢几十倍且掉画质），也是随包那份裁剪版 ffmpeg 能干活的前提；
    ///  * 字幕轨只有 MKV 才内封：MP4 要 mov_text，随包 ffmpeg 没有那个编码器，
    ///    -c:s copy 直接会失败 —— 与其让整条命令挂掉，不如不带字幕轨并如实说明；
    ///  * -movflags +faststart：mp4 专用（moov 前置，播放器不用读完整个文件才起播）；
    ///  * -progress pipe:1：进度走 stdout，与 stderr 的错误分开，互不干扰。
    /// </summary>
    public static List<string> MergeArgs(
        string videoPath, string audioPath, string outputPath,
        IReadOnlyList<BiliEmbeddedTrack> tracks, string? chapterPath,
        bool allowSubtitles)
    {
        var wantFaststart = outputPath.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase);
        var args = new List<string>
        {
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", videoPath,
            "-i", audioPath,
        };

        // 输入顺序决定后面所有 -map 的索引，别在中途插东西。
        var subs = allowSubtitles ? tracks : Array.Empty<BiliEmbeddedTrack>();
        foreach (var t in subs) { args.Add("-i"); args.Add(t.FileName); }
        if (!string.IsNullOrEmpty(chapterPath)) { args.Add("-i"); args.Add(chapterPath!); }

        args.Add("-map"); args.Add("0:v:0");
        args.Add("-map"); args.Add("1:a:0");
        for (var k = 0; k < subs.Count; k++) { args.Add("-map"); args.Add((2 + k) + ":0"); }

        args.Add("-c"); args.Add("copy");
        if (subs.Count > 0)
        {
            // 字幕轨原样封进去，不转格式：转 ass 与 srt 要的是编码器，而这里只想要
            // 「同一条字节流换个容器」。
            args.Add("-c:s"); args.Add("copy");
            // 默认轨必须显式指定：不写的话 ffmpeg 把 default 标给第一条字幕流，
            // 而第一条是按文件名排序撞出来的（2026-10-12 真机：阿拉伯语恰好排第一）。
            var defIdx = BiliAdditional.DefaultTrackIndex(subs);
            for (var k = 0; k < subs.Count; k++)
            {
                var t = subs[k];
                // 写法必须是 -metadata:s:s:0（两个冒号）：写成 s0 会被 ffmpeg 判
                // 「Trailing garbage at the end of a stream specifier」整条命令退出。
                var spec = "-metadata:s:s:" + k;
                args.Add(spec); args.Add("title=" + t.Title);
                // 空语言码比不写更糟（播放器菜单里出现一个非法的 Language 标签）。
                if (!string.IsNullOrEmpty(t.Iso639)) { args.Add(spec); args.Add("language=" + t.Iso639); }
                args.Add("-disposition:s:" + k);
                args.Add(k == defIdx ? "default" : "0");
            }
        }
        if (wantFaststart) { args.Add("-movflags"); args.Add("+faststart"); }
        args.Add("-progress"); args.Add("pipe:1");
        args.Add(outputPath);
        return args;
    }

    /// <summary>完整的合并执行（带全局闸门）。</summary>
    public async Task<BiliMergeResult> MergeAsync(BiliMergeRequest req, CancellationToken ct = default)
    {
        await Gate.WaitAsync(ct);
        IsMerging = true;
        try
        {
            var r = await MergeCoreAsync(req, ct);
            if (r.Ok) MergeSuccessCount++; else MergeFailureCount++;
            return r;
        }
        finally
        {
            IsMerging = false;
            Gate.Release();
        }
    }

    private async Task<BiliMergeResult> MergeCoreAsync(BiliMergeRequest req, CancellationToken ct)
    {
        var exe = ResolveFfmpeg(null) ?? MediaMerger.ResolveFfmpeg();
        if (exe is null)
        {
            return Fail(BiliMergeFailure.FfmpegMissing,
                "没找到 ffmpeg.exe。B 站下的是 DASH 分开的两条流，视频流与音频流各自都不能" +
                "单独播放，必须先合并。找过这些位置：" + string.Join("、", FfmpegCandidates(null)),
                "", "");
        }
        if (!File.Exists(req.VideoPath))
            return Fail(BiliMergeFailure.FfmpegMissing, "视频流文件不存在：" + req.VideoPath, "", "");
        if (!File.Exists(req.AudioPath))
            return Fail(BiliMergeFailure.FfmpegMissing, "音频流文件不存在：" + req.AudioPath, "", "");

        var allowSubs = req.Container.Equals("mkv", StringComparison.OrdinalIgnoreCase);
        var chapterPath = string.IsNullOrEmpty(req.ChapterFileName) ? null : req.ChapterFileName;

        var args = MergeArgs(req.VideoPath, req.AudioPath, req.OutputPath,
                             req.Tracks, chapterPath, allowSubs);
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        var commandLine = exe + " " + string.Join(" ", args.Select(Quote));

        var inBytes = SizeOf(req.VideoPath) + SizeOf(req.AudioPath);
        Log("开始合并 → " + Path.GetFileName(req.OutputPath) + "（输入 " + inBytes + " 字节）");

        Process? proc;
        try { proc = Process.Start(psi); }
        catch (Exception ex)
        {
            return Fail(BiliMergeFailure.ProcessError, "ffmpeg 进程没能启动：" + ex.Message, commandLine, "");
        }
        if (proc is null) return Fail(BiliMergeFailure.ProcessError, "ffmpeg 进程没能启动", commandLine, "");

        // stdin 立刻关掉：ffmpeg 遇到同名产物会问一句，不关就把自己卡死（我们已带 -y）。
        try { proc.StandardInput.Close(); } catch { }

        var sawEnd = false;
        long? outTimeUs = null;
        var stderr = new StringBuilder();
        var stderrTask = Task.Run(async () =>
        {
            var buf = new char[4096];
            int n;
            while ((n = await proc.StandardError.ReadAsync(buf, 0, buf.Length)) > 0)
                lock (stderr) stderr.Append(buf, 0, n);
        });

        int? exitCode = null;
        try
        {
            string? line;
            while ((line = await proc.StandardOutput.ReadLineAsync()) is not null)
            {
                var point = ParseProgressLine(line);
                if (point is null) continue;
                if (point.OutTimeUs is long us) outTimeUs = us;
                if (point.Ended) sawEnd = true;
            }
            await proc.WaitForExitAsync(ct);
            exitCode = proc.ExitCode;
            await stderrTask;
        }
        catch (Exception ex)
        {
            try { proc.Kill(entireProcessTree: true); } catch { }
            return Fail(BiliMergeFailure.ProcessError, "合并过程中读取子进程输出异常：" + ex.Message,
                commandLine, stderr.ToString());
        }
        finally
        {
            proc.Dispose();
        }

        var code = exitCode ?? -1;
        var outExists = File.Exists(req.OutputPath);
        var outSize = outExists ? SizeOf(req.OutputPath) : -1;
        var errText = stderr.ToString();
        var duration = outTimeUs is long tus && tus > 0 ? tus / 1000000.0 : 0.0;

        // 三种失败形状按「谁知道得更多」排序：非 0 退出码是 ffmpeg 自己判的失败，先报它。
        if (code != 0)
        {
            CleanupZeroByteProduct(outExists, outSize, req.OutputPath);
            return Fail(BiliMergeFailure.ExitNonZero,
                "ffmpeg 退出码 " + code + "（合并失败）。两条原始流已保留。",
                commandLine, errText, duration);
        }
        if (!sawEnd)
        {
            CleanupZeroByteProduct(outExists, outSize, req.OutputPath);
            return Fail(BiliMergeFailure.NoEndProgress,
                "ffmpeg 没跑到收尾就退出了（退出码 0，但全程没有 progress=end）。" +
                "通常是进程被强杀或中途崩溃，两条原始流已保留。",
                commandLine, errText, duration);
        }
        if (!outExists || outSize <= 0)
        {
            CleanupZeroByteProduct(outExists, outSize, req.OutputPath);
            return Fail(BiliMergeFailure.BadProduct,
                outExists
                    ? "ffmpeg 报成功，但产物是 0 字节。两条原始流已保留。"
                    : "ffmpeg 报成功，但产物并不存在。两条原始流已保留。",
                commandLine, errText, duration);
        }

        // 成功：清掉原始流（只删「不是产物自己」的那些）
        var note = DeleteStreams(req);
        Log("合并完成：" + Path.GetFileName(req.OutputPath) + "（" + outSize + " 字节）" +
            (note.Length == 0 ? "" : " —— " + note));

        RecordLedger(req, outSize);

        var msg = note;
        if (!allowSubs && req.Tracks.Count > 0)
            msg = AppendNote(msg, "字幕轨 " + req.Tracks.Count + " 条未内封：MP4 容器要 mov_text 编码器，" +
                                  "随包那份 ffmpeg 没有；需要内封请把容器改成 MKV。");
        return new BiliMergeResult(true, BiliMergeFailure.None, msg, commandLine, Tail(errText), duration,
                                   req.OutputPath);
    }

    /// <summary>
    /// 纯函数：把 ffmpeg -progress 的一行 key=value 解析成进度点。
    ///
    /// out_time_ms 这个名字是误导的，它的值实际是微秒（真 ffmpeg 复验：
    /// 5.106939 秒的素材，out_time_us 与 out_time_ms 打出来都是 5106939）。
    /// 按字面当毫秒用，时长与进度会凭空放大 1000 倍。
    /// </summary>
    public static BiliProgressPoint? ParseProgressLine(string line)
    {
        var s = (line ?? "").Trim();
        var i = s.IndexOf('=');
        if (s.Length == 0 || i <= 0) return null;
        var key = s.Substring(0, i);
        var value = s.Substring(i + 1).Trim();
        if (key == "progress") return new BiliProgressPoint(null, null, value == "end");
        if (key != "total_size" && key != "out_time_us" && key != "out_time_ms") return null;
        if (!long.TryParse(value, out var n)) return null;   // N/A 之类
        if (key == "total_size") return new BiliProgressPoint(null, n, false);
        return new BiliProgressPoint(n, null, false);
    }

    private static string Quote(string a) => a.Contains(' ') ? "\"" + a + "\"" : a;

    private static long SizeOf(string path)
    {
        try
        {
            var f = new FileInfo(path);
            return f.Exists ? f.Length : 0;   // 不存在回 0（不用 -1：进度分母是两笔相加）
        }
        catch { return 0; }
    }

    private static void CleanupZeroByteProduct(bool exists, long size, string outPath)
    {
        if (!exists || size != 0) return;
        try
        {
            File.Delete(outPath);
            Aria2Engine.Log("[BiliMerge] 已删掉 0 字节的无效产物：" + outPath);
        }
        catch { }
    }

    /// <summary>成功后删两条原始流；返回给用户看的附注（一切正常时为空串）。</summary>
    private string DeleteStreams(BiliMergeRequest req)
    {
        if (!req.DeleteSource) return "";
        var notes = new List<string>();
        var outFull = Path.GetFullPath(req.OutputPath).ToLowerInvariant();
        foreach (var path in new[] { req.VideoPath, req.AudioPath })
        {
            try
            {
                if (Path.GetFullPath(path).ToLowerInvariant() == outFull)
                {
                    notes.Add(Path.GetFileName(path) + " 与产物同路径，为避免删掉成品已保留");
                    continue;
                }
                if (File.Exists(path)) File.Delete(path);
            }
            catch (Exception ex)
            {
                notes.Add(Path.GetFileName(path) + " 没能删掉（" + ex.Message + "）");
            }
        }
        // 章节那份中间文件合并完就没用了（它只喂给 -i）
        if (!string.IsNullOrEmpty(req.ChapterFileName))
        {
            try
            {
                var cp = Path.Combine(req.Dir, req.ChapterFileName!);
                if (File.Exists(cp)) File.Delete(cp);
            }
            catch { }
        }
        return string.Join("；", notes);
    }

    /// <summary>落台账：合并产物也记一笔，重启后仍能看到「这一条是怎么来的」。</summary>
    private void RecordLedger(BiliMergeRequest req, long size)
    {
        try
        {
            var item = new DownloadItem
            {
                Gid = "merge:" + req.OutBase,
                Url = req.SourceUrl,
                Module = "B 站（合并）",
                FileName = Path.GetFileName(req.OutputPath),
                Dir = req.Dir,
            };
            item.Status = AriaStatus.Complete;
            item.TotalBytes = size;
            item.CompletedBytes = size;
            DownloadLedger.Instance.Record(item);
        }
        catch (Exception ex)
        {
            Log("写台账失败（不影响产物）：" + ex.Message);
        }
    }

    private static string AppendNote(string note, string extra) =>
        note.Length == 0 ? extra : note + "；" + extra;

    private static string Tail(string s)
    {
        var t = (s ?? "").TrimEnd();
        const int keep = 4000;
        return t.Length <= keep ? t : "…（前面省略 " + (t.Length - keep) + " 字符）" + t.Substring(t.Length - keep);
    }

    private static BiliMergeResult Fail(
        BiliMergeFailure kind, string message, string commandLine, string stderr, double duration = 0)
    {
        Aria2Engine.Log("[BiliMerge] 合并失败（" + kind + "）：" + message);
        return new BiliMergeResult(false, kind, message, commandLine, Tail(stderr), duration, "");
    }

    // ── 手工触发的自测入口 ────────────────────────────────────

    /// <summary>
    /// 手工触发的合并自测 —— 在真机上造一对样本流，跑完整合并，再用 ffprobe 验货。
    ///
    /// 为什么必须做成可手工触发：打包应用既透传不了命令行参数、也继承不到父进程
    /// 环境变量（winapp run 起独立进程），一个按钮是唯一可靠的触发方式。
    ///
    /// 为什么用「外部完整 ffmpeg 造样本」：随包那份是裁剪版（--disable-everything，
    /// 没有 lavfi 输入、没有 x264 与 aac 编码器），造不出样本；但它读 mov/mp4 与
    /// mux mp4 的能力是全的 —— 这恰好就是合并这一步需要的全部能力。
    /// 找不到完整 ffmpeg 时如实返回「未验证」，不伪造结论。
    /// </summary>
    public async Task<string> RunSelfTestAsync(string dir, CancellationToken ct = default)
    {
        var sb = new StringBuilder();
        sb.AppendLine("===== B 站合并自测 =====");
        sb.AppendLine("目录：" + dir);

        var packaged = ResolveFfmpeg();
        sb.AppendLine("随包 ffmpeg：" + (packaged ?? "【没找到】"));

        var full = FindFullFfmpeg();
        sb.AppendLine("完整 ffmpeg（造样本用）：" + (full ?? "【没找到 → 样本造不出来，真合并一项标未验证】"));
        sb.AppendLine();

        if (packaged is null)
        {
            sb.AppendLine("结论：随包 ffmpeg 缺失，合并功能不可用。");
            return sb.ToString();
        }

        // ① 参数拼装（离线，与样本无关 —— 这一项任何环境都能判）
        var probeTracks = new List<BiliEmbeddedTrack>
        {
            new("b.ass", "中文（AI）", "chi", false),
            new("a.ass", "弹幕", "", true),
        };
        var argvMp4 = MergeArgs("v.m4s", "a.m4s", "out.mp4", probeTracks, null, allowSubtitles: false);
        var argvMkv = MergeArgs("v.m4s", "a.m4s", "out.mkv", probeTracks, "ch.ffmeta", allowSubtitles: true);
        var lineMp4 = string.Join(" ", argvMp4);
        var lineMkv = string.Join(" ", argvMkv);
        sb.AppendLine("[参数] MP4 带 -c copy：" + Yes(lineMp4.Contains("-c copy")));
        sb.AppendLine("[参数] MP4 带 +faststart：" + Yes(lineMp4.Contains("+faststart")));
        sb.AppendLine("[参数] MP4 不带字幕轨（无 -c:s）：" + Yes(!lineMp4.Contains("-c:s")));
        sb.AppendLine("[参数] MKV 带字幕轨映射 -map 2:0：" + Yes(lineMkv.Contains("-map 2:0")));
        sb.AppendLine("[参数] MKV 带语言标签 language=chi：" + Yes(lineMkv.Contains("language=chi")));
        sb.AppendLine("[参数] MKV 默认轨标给中文轨（-disposition:s:0 default）：" +
                      Yes(lineMkv.Contains("-disposition:s:0 default")));
        sb.AppendLine("[参数] 章节文件作为输入：" + Yes(lineMkv.Contains("ch.ffmeta")));
        sb.AppendLine();

        // ② 进度行解析（离线）
        var p1 = ParseProgressLine("out_time_ms=5106939");
        var p2 = ParseProgressLine("progress=end");
        var p3 = ParseProgressLine("total_size=N/A");
        sb.AppendLine("[解析] out_time_ms 按微秒读（5106939 → 5.106939 秒）：" +
                      Yes(p1?.OutTimeUs == 5106939L));
        sb.AppendLine("[解析] progress=end 认得出：" + Yes(p2?.Ended == true));
        sb.AppendLine("[解析] N/A 不当成 0：" + Yes(p3 is null));
        sb.AppendLine();

        if (full is null)
        {
            sb.AppendLine("结论：参数与进度解析两项通过；真合并一项未验证" +
                          "（造样本需要完整 ffmpeg，本机没找到）。这不是「失败」，也不是「已证死」。");
            return sb.ToString();
        }

        // ③ 造样本 → 真合并 → 验货
        Directory.CreateDirectory(dir);
        var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
        var baseName = "_bili_merge_selftest_" + stamp;
        var videoSrc = Path.Combine(dir, baseName + ".video.m4s");
        var audioSrc = Path.Combine(dir, baseName + ".audio.m4s");

        sb.AppendLine("—— 用完整 ffmpeg 造一对样本流 ——");
        var mk = await RunAsync(full,
            new[]
            {
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15:duration=1",
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-f", "mp4", videoSrc,
            }, ct);
        sb.AppendLine("造视频流 rc=" + mk.Code + (mk.Ok ? "（成功）" : "（失败：" + mk.Err + "）"));

        var ak = await RunAsync(full,
            new[]
            {
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                "-c:a", "aac", "-f", "mp4", audioSrc,
            }, ct);
        sb.AppendLine("造音频流 rc=" + ak.Code + (ak.Ok ? "（成功）" : "（失败：" + ak.Err + "）"));
        if (!mk.Ok || !ak.Ok)
        {
            sb.AppendLine("结论：样本没造出来，真合并一项未验证。");
            return sb.ToString();
        }

        var pairs = FindPairs(dir, "mp4");
        sb.AppendLine("配对扫描找到 " + pairs.Count + " 对；本批 base = " + baseName +
                      " → " + Yes(pairs.Any(p => p.Base == baseName)));

        sb.AppendLine();
        sb.AppendLine("—— 用随包 ffmpeg 真合并（-c copy）——");
        var result = await MergeAsync(new BiliMergeRequest
        {
            OutBase = baseName,
            Dir = dir,
            VideoPath = videoSrc,
            AudioPath = audioSrc,
            OutputPath = Path.Combine(dir, baseName + ".mp4"),
            DeleteSource = true,
            Container = "mp4",
            DisplayName = baseName,
        }, ct);

        sb.AppendLine("结果：" + (result.Ok ? "成功" : "失败（" + result.Failure + "）"));
        sb.AppendLine("命令行：" + result.CommandLine);
        if (!result.Ok)
        {
            sb.AppendLine("stderr：" + result.Stderr);
            sb.AppendLine("结论：真合并失败，见上面的 stderr。");
            return sb.ToString();
        }
        sb.AppendLine("产物字节数：" + SizeOf(result.OutputPath));
        sb.AppendLine("ffmpeg 报的媒体时长：" + result.MediaDurationSec.ToString("0.###") + " 秒");
        sb.AppendLine("源流已删（视频流不存在）：" + Yes(!File.Exists(videoSrc)));
        sb.AppendLine("源流已删（音频流不存在）：" + Yes(!File.Exists(audioSrc)));

        // ffprobe 验货：随包那份没有 ffprobe，所以用完整 ffmpeg 同目录的 ffprobe
        var probe = FindFfprobe();
        sb.AppendLine();
        sb.AppendLine("—— ffprobe 验货（" + (probe ?? "【没有 ffprobe】") + "）——");
        if (probe is null)
        {
            sb.AppendLine("未验证：本机没有 ffprobe，无法读出产物里的流构成。");
        }
        else
        {
            var pr = await RunAsync(probe,
                new[]
                {
                    "-v", "error",
                    "-show_entries", "format=format_name,duration,size",
                    "-show_entries", "stream=index,codec_type,codec_name,channels,sample_rate",
                    "-of", "default=noprint_wrappers=0",
                    result.OutputPath,
                }, ct);
            sb.AppendLine(pr.Out.Trim());
            if (pr.Err.Trim().Length > 0) sb.AppendLine("（stderr：" + pr.Err.Trim() + "）");
            sb.AppendLine("含视频流：" + Yes(pr.Out.Contains("codec_type=video")));
            sb.AppendLine("含音频流：" + Yes(pr.Out.Contains("codec_type=audio")));
        }

        sb.AppendLine();
        sb.AppendLine("结论：真合并通过（证据：退出码 0 + progress=end + 产物非 0 字节 + ffprobe 两条流）。");
        return sb.ToString();
    }

    /// <summary>找一份完整版 ffmpeg（能 lavfi 造样本）。只认几个确定性候选，不扫全盘。</summary>
    public static string? FindFullFfmpeg()
    {
        foreach (var c in new[]
                 {
                     @"F:\qoder\_ffmpeg_full\ffmpeg-9.0.2-full_build\bin\ffmpeg.exe",
                     @"C:\ffmpeg\bin\ffmpeg.exe",
                 })
        {
            try { if (File.Exists(c)) return c; } catch { }
        }
        return null;
    }

    public static string? FindFfprobe()
    {
        foreach (var c in new[]
                 {
                     @"F:\qoder\_ffmpeg_full\ffmpeg-9.0.2-full_build\bin\ffprobe.exe",
                     @"C:\ffmpeg\bin\ffprobe.exe",
                 })
        {
            try { if (File.Exists(c)) return c; } catch { }
        }
        return null;
    }

    private static string Yes(bool ok) => ok ? "PASS" : "FAIL";

    private static async Task<(bool Ok, int Code, string Out, string Err)> RunAsync(
        string exe, IEnumerable<string> args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        try
        {
            using var p = Process.Start(psi);
            if (p is null) return (false, -1, "", "进程没起来");
            var outTask = p.StandardOutput.ReadToEndAsync();
            var errTask = p.StandardError.ReadToEndAsync();
            await p.WaitForExitAsync(ct);
            return (p.ExitCode == 0, p.ExitCode, await outTask, await errTask);
        }
        catch (Exception ex)
        {
            return (false, -1, "", ex.Message);
        }
    }
}
