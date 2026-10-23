using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace ParseDl.Services;

/// <summary>合并结果。</summary>
public sealed record MergeResult(bool Ok, string Message, string OutputPath);

/// <summary>
/// 音视频合并 —— 用随包的 ffmpeg.exe 把分离的视频流与音频流合成一个 mp4。
///
/// 为什么必须做：B 站的 dash 格式把视频与音频分成两个文件（为了自适应码率），
/// 单独下一个只有画面没声音。Flutter 版的 bili_merger.dart（868 行）就是干这个的。
///
/// 实现要点：
/// 1. **必须 -c copy**（流复制），不能重编码 —— 重编码慢几十倍且会掉画质；
/// 2. 音频用 aac_adtstoasc 位流过滤器，否则 m4a 封进 mp4 会报错；
/// 3. 合并成功后原文件按设置决定是否保留（默认删，省空间）。
/// </summary>
public static class MediaMerger
{
    /// <summary>找 ffmpeg.exe：优先 exe 同级（随包分发的位置）。</summary>
    public static string? ResolveFfmpeg()
    {
        var baseDir = AppContext.BaseDirectory;
        foreach (var candidate in new[]
                 {
                     Path.Combine(baseDir, "ffmpeg.exe"),
                     Path.Combine(baseDir, "Assets", "ffmpeg.exe"),
                     Path.Combine(baseDir, "assets", "ffmpeg.exe"),
                 })
        {
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>探测 ffmpeg 能不能跑（跑一句 -version）。</summary>
    public static async Task<(bool Ok, string Version)> ProbeAsync()
    {
        var exe = ResolveFfmpeg();
        if (exe is null) return (false, "未找到 ffmpeg.exe");
        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            psi.ArgumentList.Add("-version");
            using var p = Process.Start(psi);
            if (p is null) return (false, "无法启动 ffmpeg");
            var outp = await p.StandardOutput.ReadToEndAsync();
            p.WaitForExit(5000);
            var firstLine = outp.Split((char)10).FirstOrDefault() ?? "";
            return (true, firstLine.Trim());
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    /// <summary>
    /// 合并一个视频与一个音频。
    /// 输出到 [outputPath]；成功后按 [deleteSource] 决定要不要删源文件。
    /// </summary>
    public static async Task<MergeResult> MergeAsync(
        string videoPath, string audioPath, string outputPath,
        bool deleteSource = true, CancellationToken ct = default)
    {
        var exe = ResolveFfmpeg();
        if (exe is null) return new MergeResult(false, "未找到 ffmpeg.exe（应随包分发到程序目录）", "");
        if (!File.Exists(videoPath)) return new MergeResult(false, "视频文件不存在：" + videoPath, "");
        if (!File.Exists(audioPath)) return new MergeResult(false, "音频文件不存在：" + audioPath, "");

        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            // -y 覆盖已有输出；-c copy 流复制（不重编码）
            psi.ArgumentList.Add("-y");
            psi.ArgumentList.Add("-i"); psi.ArgumentList.Add(videoPath);
            psi.ArgumentList.Add("-i"); psi.ArgumentList.Add(audioPath);
            psi.ArgumentList.Add("-c:v"); psi.ArgumentList.Add("copy");
            psi.ArgumentList.Add("-c:a"); psi.ArgumentList.Add("copy");
            // 音频从 m4a 封进 mp4 必须过 aac_adtstoasc，否则报 "Malformed AAC bitstream"
            psi.ArgumentList.Add("-bsf:a"); psi.ArgumentList.Add("aac_adtstoasc");
            psi.ArgumentList.Add(outputPath);

            using var proc = Process.Start(psi);
            if (proc is null) return new MergeResult(false, "无法启动 ffmpeg", "");

            var stderrTask = proc.StandardError.ReadToEndAsync();
            var stdoutTask = proc.StandardOutput.ReadToEndAsync();

            // 等它跑完；合并通常几秒，给 5 分钟上限防卡死
            var finished = await Task.Run(() => proc.WaitForExit(300_000), ct);
            var stderr = await stderrTask;
            await stdoutTask;

            if (!finished)
            {
                try { proc.Kill(entireProcessTree: true); } catch { }
                return new MergeResult(false, "合并超时（超过 5 分钟）", "");
            }

            if (proc.ExitCode != 0)
            {
                // 把 ffmpeg 的最后几行错误带出去，用户能看到具体原因
                var tail = string.Join("\n", stderr.Split((char)10).TakeLast(4));
                Aria2Engine.Log("[Merge] ffmpeg 退出码 " + proc.ExitCode + "：" + tail);
                return new MergeResult(false, "ffmpeg 失败（退出码 " + proc.ExitCode + "）：" + tail.Trim(), "");
            }

            if (!File.Exists(outputPath))
                return new MergeResult(false, "ffmpeg 声称成功但没有输出文件", "");

            if (deleteSource)
            {
                try { File.Delete(videoPath); } catch { }
                try { File.Delete(audioPath); } catch { }
            }

            Aria2Engine.Log("[Merge] 合并完成：" + outputPath);
            return new MergeResult(true, "合并完成", outputPath);
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[Merge] 合并异常：" + ex.Message);
            return new MergeResult(false, ex.Message, "");
        }
    }

    /// <summary>
    /// 扫一个目录，把「同名但一个是视频一个是音频」的配对找出来。
    /// 用于下载完成后自动合并，也可给界面做批量合并入口。
    /// </summary>
    public static List<(string Video, string Audio, string Output)> FindPairs(string dir)
    {
        var pairs = new List<(string, string, string)>();
        if (!Directory.Exists(dir)) return pairs;

        string[] videoExt = { ".mp4", ".mkv", ".flv" };
        string[] audioExt = { ".m4a", ".aac", ".mp3" };

        var files = Directory.GetFiles(dir);
        foreach (var v in files.Where(f => videoExt.Contains(Path.GetExtension(f).ToLowerInvariant())))
        {
            var stem = Path.GetFileNameWithoutExtension(v);
            foreach (var a in files.Where(f => audioExt.Contains(Path.GetExtension(f).ToLowerInvariant())))
            {
                if (Path.GetFileNameWithoutExtension(a) != stem) continue;
                // 输出加 _merged 后缀，避免覆盖正在用的视频文件
                pairs.Add((v, a, Path.Combine(dir, stem + "_merged.mp4")));
            }
        }
        return pairs;
    }
}
