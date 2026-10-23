using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;

namespace ParseDl.Services;

/// <summary>一条下载记录（界面绑定的对象）。</summary>
public sealed class DownloadItem
{
    public string Gid { get; init; } = "";
    public string Url { get; init; } = "";
    public string FileName { get; set; } = "";
    public string Dir { get; set; } = "";
    public string Module { get; init; } = "X 媒体";
    public DateTime CreatedAt { get; init; } = DateTime.Now;

    public AriaStatus Status { get; set; } = AriaStatus.Waiting;
    public long CompletedBytes { get; set; }
    public long TotalBytes { get; set; }
    public long SpeedBytesPerSec { get; set; }
    public string Error { get; set; } = "";

    public double Progress => TotalBytes <= 0 ? 0 : (double)CompletedBytes / TotalBytes;
    public string ProgressText => TotalBytes <= 0
        ? "—"
        : $"{FormatSize(CompletedBytes)} / {FormatSize(TotalBytes)}（{Progress:P0}）";
    public string SpeedText => SpeedBytesPerSec <= 0 ? "" : FormatSize(SpeedBytesPerSec) + "/s";
    public string StatusText => Status switch
    {
        AriaStatus.Active => "下载中",
        AriaStatus.Waiting => "等待中",
        AriaStatus.Paused => "已暂停",
        AriaStatus.Error => "错误",
        AriaStatus.Complete => "已完成",
        _ => "已移除",
    };

    public static string FormatSize(long bytes)
    {
        if (bytes <= 0) return "0 B";
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double v = bytes;
        var i = 0;
        while (v >= 1024 && i < units.Length - 1) { v /= 1024; i++; }
        return $"{v:0.#} {units[i]}";
    }
}

/// <summary>
/// 下载队列 —— 界面与 aria2 之间的唯一中介。
/// 定时轮询 aria2 的 tellAll，把状态刷到 ObservableCollection 上。
/// </summary>
public sealed class DownloadStore
{
    public static DownloadStore Instance { get; } = new();

    private readonly Aria2Engine _engine = new();
    private readonly DispatcherQueue? _ui;
    private Timer? _pollTimer;
    private int _polling;

    public ObservableCollection<DownloadItem> Items { get; } = new();

    public bool EngineReady { get; private set; }
    public string EngineMessage { get; private set; } = "未启动";

    public DownloadStore()
    {
        _ui = DispatcherQueue.GetForCurrentThread();
    }

    /// <summary>启动引擎（幂等）。</summary>
    public async Task<bool> EnsureEngineAsync()
    {
        if (EngineReady && _engine.IsRunning) return true;
        var ok = await _engine.StartAsync();
        EngineReady = ok;
        EngineMessage = ok ? "aria2 正在运行" : "aria2 启动失败（缺少 aria2c.exe？）";
        if (ok) StartPolling();
        return ok;
    }

    /// <summary>加入一条下载。</summary>
    /// <param name="outName">另存文件名（含扩展名）。为空则让 aria2 按 URL 末段命名。</param>
    public async Task<(bool Ok, string Message)> AddAsync(
        string url, string module, string? dir = null, string? outName = null)
    {
        if (string.IsNullOrWhiteSpace(url)) return (false, "地址为空");
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            (uri.Scheme != "http" && uri.Scheme != "https"))
        {
            return (false, "只支持 http / https 直链");
        }

        if (!await EnsureEngineAsync())
            return (false, "下载引擎未就绪：" + EngineMessage);

        var gid = await _engine.AddUriAsync(url, dir ?? Aria2Engine.DefaultDir(), outName);
        if (string.IsNullOrEmpty(gid)) return (false, "aria2 拒绝该任务");

        var item = new DownloadItem { Gid = gid, Url = url, Module = module };
        if (!string.IsNullOrEmpty(outName)) item.FileName = outName;
        OnUi(() => Items.Insert(0, item));
        await RefreshOnceAsync();
        return (true, "已加入队列");
    }

    public async Task PauseAsync(DownloadItem item)
    {
        if (item.Status == AriaStatus.Paused) await _engine.UnpauseAsync(item.Gid);
        else await _engine.PauseAsync(item.Gid);
        await RefreshOnceAsync();
    }

    public async Task RemoveAsync(DownloadItem item)
    {
        try { await _engine.RemoveAsync(item.Gid); } catch { }
        OnUi(() => Items.Remove(item));
    }

    public async Task ClearCompletedAsync()
    {
        var done = Items.Where(i => i.Status is AriaStatus.Complete or AriaStatus.Error or AriaStatus.Removed).ToList();
        foreach (var d in done) await RemoveAsync(d);
        try { await _engine.PurgeAsync(); } catch { }
    }

    private void StartPolling()
    {
        if (_pollTimer is not null) return;
        _pollTimer = new Timer(async _ => await SafeRefreshAsync(), null, 800, 800);
    }

    private async Task SafeRefreshAsync()
    {
        if (Interlocked.Exchange(ref _polling, 1) == 1) return;
        try { await RefreshOnceAsync(); }
        catch { }
        finally { Interlocked.Exchange(ref _polling, 0); }
    }

    public async Task RefreshOnceAsync()
    {
        if (!_engine.IsRunning) return;
        List<AriaTask> tasks;
        try { tasks = await _engine.TellAllAsync(); }
        catch { return; }

        OnUi(() =>
        {
            foreach (var t in tasks)
            {
                var item = Items.FirstOrDefault(i => i.Gid == t.Gid);
                if (item is null) continue;
                item.Status = t.Status;
                item.CompletedBytes = t.CompletedBytes;
                item.TotalBytes = t.TotalBytes;
                item.SpeedBytesPerSec = t.SpeedBytesPerSec;
                item.Error = t.Error;
                if (!string.IsNullOrEmpty(t.FileName)) item.FileName = t.FileName;
                if (!string.IsNullOrEmpty(t.Dir)) item.Dir = t.Dir;
            }
            // 终态落台账：完成/失败/移除各记一笔，重启后仍能看到历史。
            foreach (var t in tasks)
            {
                if (t.Status is AriaStatus.Complete or AriaStatus.Error or AriaStatus.Removed)
                {
                    var it = Items.FirstOrDefault(i => i.Gid == t.Gid);
                    if (it is not null && it.Status != t.Status)
                    {
                        it.Status = t.Status;
                        DownloadLedger.Instance.Record(it);
                    }
                }
            }

            // 触发一次集合变更通知（DownloadItem 未实现 INotifyPropertyChanged，
            // 用 Replace 让列表项重绘 —— 比给每项加通知简单且够用）
            for (var i = 0; i < Items.Count; i++)
            {
                var cur = Items[i];
                Items[i] = cur;
            }
        });
    }

    private void OnUi(Action action)
    {
        if (_ui is null || _ui.HasThreadAccess) { action(); return; }
        _ui.TryEnqueue(() => action());
    }
}