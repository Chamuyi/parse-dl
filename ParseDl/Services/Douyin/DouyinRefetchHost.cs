using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace ParseDl.Services.Douyin;

/// <summary>
/// **隐藏 WebView2 取址**（2026-11-01 加）—— 过期直链按作品 ID 现取新地址。
///
/// ### 为什么不自己拼接口请求
/// 抖音 web 的 detail 接口要 a_bogus 签名（实测裸调返回 403 / 46 字节）。
/// 自己算签名等于跟平台对抗，平台一改就全挂。
///
/// ### 做法：搭页面自己的车
/// 用一个**隐藏的 WebView2** 导航到 https://www.douyin.com/video/<id>：
///   · 页面自己带全套登录态与签名去请求 detail；
///   · 已注册的拦截器（DouyinInterceptor.Script）把响应抄一份；
///   · 我们从抄下来的载荷里挑出该作品的新直链。
/// 签名怎么变都不用跟着改，和抓取走的是同一条已验证链路。
///
/// ### 为什么必须是独立实例
/// 不能借用「抖音解析页」那个 WebView：用户可能正在上面滚动抓取，
/// 导航走会把他的页面顶掉、进度全丢。这里挂在主窗口里一个 1x1、
/// 近乎全透明、不接受点击的容器中，肉眼不可见、也不抢焦点。
/// 与其它 WebView2 共用默认 user data folder，所以**登录态是同一个**。
/// </summary>
public static class DouyinRefetchHost
{
    private static WebView2? _web;
    private static Task<bool>? _init;
    private static readonly SemaphoreSlim _gate = new(1, 1);

    /// <summary>等待中的目标作品 id（空 = 没人等）。</summary>
    private static string _target = "";
    private static TaskCompletionSource<bool>? _waiter;
    private static readonly List<DouyinItem> _hits = new();

    /// <summary>等待上限：单条作品页 20 秒还没回数据就放弃。</summary>
    private static readonly TimeSpan WaitTimeout = TimeSpan.FromSeconds(20);

    /// <summary>把隐藏 WebView 挂进宿主容器（主窗口启动时调一次）。</summary>
    public static void Attach(Grid host)
    {
        try
        {
            var web = new WebView2
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                VerticalAlignment = VerticalAlignment.Stretch,
            };
            host.Children.Add(web);
            _web = web;
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[取址] 隐藏浏览器挂载失败：" + ex.Message);
        }
    }

    /// <summary>懒初始化：等控件加载 → EnsureCoreWebView2 → 注册拦截器。</summary>
    private static Task<bool> EnsureAsync()
    {
        if (_init is not null) return _init;
        _init = InitAsync();
        return _init;
    }

    private static async Task<bool> InitAsync()
    {
        var web = _web;
        if (web is null) return false;
        try
        {
            // 控件还没进视觉树时 EnsureCoreWebView2Async 会抛，先等 Loaded
            if (web.XamlRoot is null)
            {
                var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                RoutedEventHandler? h = null;
                h = (_, _) => { web.Loaded -= h; tcs.TrySetResult(true); };
                web.Loaded += h;
                var loaded = await Task.WhenAny(tcs.Task, Task.Delay(10000));
                if (loaded != tcs.Task) return false;
            }

            await web.EnsureCoreWebView2Async();
            var core = web.CoreWebView2;
            if (core is null) return false;

            core.Settings.UserAgent =
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
            core.Settings.IsStatusBarEnabled = false;
            core.WebMessageReceived += OnWebMessage;
            await core.AddScriptToExecuteOnDocumentCreatedAsync(DouyinInterceptor.Script);
            return true;
        }
        catch (Exception ex)
        {
            Aria2Engine.Log("[取址] 隐藏浏览器初始化失败：" + ex.Message);
            return false;
        }
    }
    /// <summary>拦截器回传载荷 → 命中目标作品时收下并唤醒等待者。</summary>
    private static void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            var target = _target;
            if (string.IsNullOrEmpty(target)) return;

            string payload;
            try { payload = e.WebMessageAsJson; } catch { return; }
            if (string.IsNullOrEmpty(payload)) return;

            var parsed = DouyinPayloadParser.Parse(payload);
            if (parsed.Media.Count == 0) return;

            var hit = parsed.Media.Where(m =>
                string.Equals(m.PostId, target, StringComparison.Ordinal)
                || string.Equals(m.Id, target, StringComparison.Ordinal)
                || m.Id.StartsWith(target + "_", StringComparison.Ordinal)).ToList();
            if (hit.Count == 0) return;

            lock (_hits)
            {
                _hits.Clear();
                _hits.AddRange(hit);
            }
            _waiter?.TrySetResult(true);
        }
        catch { }
    }

    /// <summary>
    /// 打开作品页、等拦截器回传、挑出第 mediaIndex 条媒体的新地址。
    /// 失败时返回原因（调用方要把它连同作者/作品 ID 一起报给用户）。
    /// </summary>
    public static async Task<DouyinAddressResolver.Resolved> RefetchAsync(string awemeId, int mediaIndex)
    {
        if (string.IsNullOrWhiteSpace(awemeId))
            return new DouyinAddressResolver.Resolved(false, "", "没有作品 ID，无法重新取地址");

        if (!await EnsureAsync())
            return new DouyinAddressResolver.Resolved(false, "", "取址用的内嵌浏览器未就绪");

        await _gate.WaitAsync();
        try
        {
            var core = _web?.CoreWebView2;
            if (core is null)
                return new DouyinAddressResolver.Resolved(false, "", "取址用的内嵌浏览器未就绪");

            lock (_hits) _hits.Clear();
            _target = awemeId;
            _waiter = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

            var url = DouyinAddressResolver.PageUrlFor(awemeId);
            try { core.Navigate(url); }
            catch (Exception ex)
            {
                return new DouyinAddressResolver.Resolved(false, "", "打开作品页失败：" + ex.Message);
            }

            var waiter = _waiter;
            var finished = await Task.WhenAny(waiter.Task, Task.Delay(WaitTimeout));
            if (finished != waiter.Task || !waiter.Task.IsCompleted || !waiter.Task.Result)
                return new DouyinAddressResolver.Resolved(false, "",
                    "打开作品页 " + (int)WaitTimeout.TotalSeconds + " 秒内没拿到数据（可能未登录、作品已删/私密，或网络不通）");

            List<DouyinItem> hits;
            lock (_hits) hits = _hits.ToList();
            if (hits.Count == 0)
                return new DouyinAddressResolver.Resolved(false, "", "页面没有回传该作品的数据");

            // mediaIndex 从 1 开始（与 %MEDIA_INDEX% 一致）；0 表示未记录，取第一条
            var wanted = mediaIndex <= 0 ? 1 : mediaIndex;
            var pick = hits.FirstOrDefault(h => h.MediaIndex == wanted)
                       ?? hits.FirstOrDefault(h => h.Type == DouyinMediaType.Video)
                       ?? hits[0];

            var fresh = pick.Url;
            if (string.IsNullOrEmpty(fresh))
                return new DouyinAddressResolver.Resolved(false, "", "取到的新地址为空");
            if (SignedUrl.IsExpired(fresh))
                return new DouyinAddressResolver.Resolved(false, "", "取到的新地址本身也过期了（签名时间异常）");

            return new DouyinAddressResolver.Resolved(true, fresh, "已按作品 ID 现取新地址");
        }
        finally
        {
            _target = "";
            _waiter = null;
            _gate.Release();
        }
    }
}