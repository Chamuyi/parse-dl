using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;
using Windows.ApplicationModel.DataTransfer;

namespace ParseDl.Pages;

/// <summary>
/// X 下载设置页 —— 对齐 Flutter 版 lib/pages/settings_page.dart 的
/// `SettingsScope.xDownload` 分支（账号 → 接口缓存 → 下载），
/// 外加 lib/widgets/account_section.dart 的账号与登录。
///
/// ### 分区顺序（与 Flutter 版逐条对应）
/// 1. 账号 —— 登录状态、auth_token / ct0、智能导入、保存并验证、退出登录
/// 2. 下载 —— 保存目录、文件夹模板、文件名模板（全部占位符 + 实时预览）、
///    并发、请求间隔、跳过已下载
/// 3. 筛选 —— 媒体类型、时间范围
/// 4. 接口缓存 —— 排障说明（WinUI 版尚未实现 queryId 缓存，如实标注）
///
/// 所有改动**立即写盘**（AppSettings.Save），不依赖「保存」按钮 ——
/// 这是模块设置页既有约定，登录态也不例外。
/// </summary>
public sealed partial class XSettingsPage : Page
{
    private const string ModuleKey = "x";

    /// <summary>X 公开的 Bearer token（所有 X 客户端共用同一个，非密钥）。</summary>
    private const string Bearer =
        "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";

    /// <summary>
    /// X 文件名模板的默认值。
    ///
    /// **2026-10-28 同步自用户实际在用的 Flutter 版（D:\app\解析下载器\userdata\settings.json）**：
    /// 用户要求「统一测试」，把发行版里调好的那套模板搬过来，避免两版行为不一致。
    /// 与原值（%POST_TIME% %USER_SCREEN_NAME% %POST_ID%-%MEDIA_INDEX%%EXT%）的差别：
    ///   · 加上了 %USER_NAME%（昵称）—— 用户按昵称认人，光看 @handle 不好找；
    ///   · 用 %CONTENT%（推文内容）替代 %POST_ID%-%MEDIA_INDEX% —— 从文件名就能看出内容。
    /// </summary>
    private const string DefaultNameTpl =
        "%POST_TIME%%USER_NAME%%USER_SCREEN_NAME%%CONTENT%%EXT%";

    /// <summary>
    /// X 侧可用变量（与 Flutter 版 kXTemplateVars 逐条一致：13 个、顺序照抄
    /// kAllTemplateVars 过滤后的顺序，不含任何抖音 / B 站术语）。
    /// 带参数的变量把参数写进 ParamExample / ParamDesc —— 控件的「参数格式」行
    /// 与每行说明都从这两个字段生成，不在页面里再写一遍。
    /// </summary>
    private static readonly TemplateVarInfo[] XTemplateVars =
    {
        new("POST_ID", "推文 ID"),
        new("POST_TIME", "推文发布日期", "d=0", "仅日期（0 或 1）"),
        new("USER_ID", "用户 ID"),
        new("USER_NAME", "用户昵称"),
        new("USER_SCREEN_NAME", "用户名"),
        new("MEDIA_ID", "资源 ID"),
        new("MEDIA_WIDTH", "资源宽度"),
        new("MEDIA_HEIGHT", "资源高度"),
        new("MEDIA_INDEX", "资源索引"),
        new("CONTENT", "推文内容", "t=32", "截断长度"),
        new("MEDIA_TYPE", "媒体类型"),
        new("EXT", "扩展名"),
        new("TAGS", "推文标签"),
    };

    /// <summary>文件夹模板的「填入默认」值（对齐 Flutter 版 download_section 的 onUseDefault）。</summary>
    /// <summary>
    /// X 文件夹模板的默认值。2026-10-28 同步自用户实际在用的 Flutter 版：
    /// 原来是 %USER_SCREEN_NAME%（只有 @handle），加上 %USER_NAME%（昵称）更好认。
    /// </summary>
    private const string DefaultDirTpl = "%USER_NAME%%USER_SCREEN_NAME%";

    private ModuleSettings S => AppSettings.Instance.ForModule(ModuleKey);

    private TextBox _authTokenBox = null!;
    private TextBox _ct0Box = null!;
    private TextBlock _loginStatus = null!;
    private TextBlock _loginHint = null!;
    private Border _loginBadge = null!;
    private TextBlock _loginBadgeText = null!;
    private Button _verifyButton = null!;
    private Button _logoutButton = null!;
    private TemplateEditor _templateEditor = null!;
    private TemplateField _dirField = null!;
    private TemplateField _nameField = null!;
    private TextBox _saveDirBox = null!;
    private TextBlock _saveDirStatus = null!;
    private bool _applying;

    public XSettingsPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Build();
    }

    // ── 页面构建 ────────────────────────────────────────────

    private void Build()
    {
        Root.Children.Clear();
        Root.Children.Add(UiKit.PageHeader("X 下载设置", "账号 · 下载 · 接口缓存", "\uE9E9"));

        Root.Children.Add(BuildAccountCard());
        Root.Children.Add(BuildDownloadCard());
        Root.Children.Add(BuildFilterCard());
        Root.Children.Add(BuildCacheCard());

        RefreshLoginVisual();
    }

    // ── ① 账号 ──────────────────────────────────────────────

    private UIElement BuildAccountCard()
    {
        var panel = new StackPanel { Spacing = 12 };

        // 登录状态行：左侧标题 + 副题，右侧一枚胶囊徽章（对齐 account_section 的 _StatusRow）
        var statusGrid = new Grid();
        statusGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        statusGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var statusTexts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        statusTexts.Children.Add(new TextBlock { Text = "登录状态", FontSize = 14 });
        _loginHint = new TextBlock { Text = "尚未登录", FontSize = 12, Opacity = 0.6, TextWrapping = TextWrapping.Wrap };
        statusTexts.Children.Add(_loginHint);
        statusGrid.Children.Add(statusTexts);

        _loginBadgeText = new TextBlock { Text = "未登录", FontSize = 12 };
        _loginBadge = new Border
        {
            Background = SettingRows.SubtleFill,
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(10, 4, 10, 4),
            VerticalAlignment = VerticalAlignment.Center,
            Child = _loginBadgeText,
        };
        Grid.SetColumn(_loginBadge, 1);
        statusGrid.Children.Add(_loginBadge);
        panel.Children.Add(statusGrid);

        _loginStatus = new TextBlock { Text = "", FontSize = 12, TextWrapping = TextWrapping.Wrap, Opacity = 0.8 };
        panel.Children.Add(_loginStatus);

        // auth_token / ct0 两个必填框
        _authTokenBox = new TextBox
        {
            Text = S.AuthToken,
            PlaceholderText = "auth_token —— 从 DevTools 复制 Value，长度不限",
            FontFamily = new FontFamily("Consolas"),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_authTokenBox, "auth_token");
        _authTokenBox.TextChanged += (_, _) => OnCookieChanged();
        panel.Children.Add(SettingRows.Row("auth_token", "身份令牌。DevTools → Application → Cookies → x.com → auth_token 的 Value。", _authTokenBox));

        _ct0Box = new TextBox
        {
            Text = S.Ct0,
            PlaceholderText = "ct0 —— 从 DevTools 复制 Value，长度不限",
            FontFamily = new FontFamily("Consolas"),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_ct0Box, "ct0");
        _ct0Box.TextChanged += (_, _) => OnCookieChanged();
        panel.Children.Add(SettingRows.Row("ct0", "CSRF token。长度不固定（实测有 160 位的），从 DevTools 原样复制完整值即可。", _ct0Box));

        // 操作行
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var openButton = new Button { Content = "在浏览器登录" };
        openButton.Click += async (_, _) => await OpenLoginPageAsync();
        actions.Children.Add(openButton);

        var importButton = new Button { Content = "智能导入完整 cookie" };
        importButton.Click += async (_, _) => await ImportFromClipboardAsync();
        actions.Children.Add(importButton);

        _verifyButton = new Button { Content = "保存并验证", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        _verifyButton.Click += async (_, _) => await VerifyAsync();
        actions.Children.Add(_verifyButton);

        _logoutButton = new Button { Content = "退出登录" };
        _logoutButton.Click += (_, _) => Logout();
        actions.Children.Add(_logoutButton);
        panel.Children.Add(actions);

        // 合并后的完整 cookie 一览（对齐 account_section.dart 的 FieldRow 那一行）：
        // 只读展示 + 复制，方便用户核对「到底存进去了什么」。
        var cookieRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var cookieBox = new TextBox
        {
            IsReadOnly = true,
            MinWidth = 360,
            FontFamily = new FontFamily("Consolas"),
            Text = MaskCookie(),
        };
        AutomationProperties.SetName(cookieBox, "merged-cookie");
        cookieRow.Children.Add(cookieBox);
        var copyBtn = new Button { Content = "复制" };
        copyBtn.Click += (_, _) =>
        {
            try
            {
                var dp = new DataPackage();
                dp.SetText(S.MergedCookie);
                Clipboard.SetContent(dp);
                _loginStatus.Text = "已复制完整 cookie";
            }
            catch (Exception ex)
            {
                _loginStatus.Text = "复制失败：" + ex.Message;
            }
        };
        cookieRow.Children.Add(copyBtn);
        panel.Children.Add(SettingRows.Row("完整 cookie", "除 auth_token / ct0 外的其它字段会原样保留 —— 原版 X-Spider 发的就是整段 cookie。", cookieRow));

        // 获取方式说明
        var help = new Border
        {
            Background = SettingRows.SubtleFill,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12, 10, 12, 10),
            Child = new TextBlock
            {
                Text = "获取方式：点「在浏览器登录」登录 x.com → 按 F12 → Application → Cookies → x.com → " +
                       "找到 auth_token 与 ct0 两行，双击 Value 列复制值，分别填到上面两个框。\n" +
                       "省事做法：把整段 cookie（或直接从 DevTools 复制的多行内容）粘进任一框，会自动拆分出这两个值。",
                FontSize = 11.5,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
                LineHeight = 18,
            },
        };
        panel.Children.Add(help);

        return SettingRows.Card("账号", "登录状态、cookie 输入与验证", panel);
    }

    /// <summary>两个框任一改动 → 立即落盘（保留其它 cookie 字段）。</summary>
    private void OnCookieChanged()
    {
        if (_applying) return;
        var raw = _authTokenBox.Text.Trim() + "\n" + _ct0Box.Text.Trim();

        // 整段 cookie 被粘进某一个框 → 尝试自动拆分
        var parsed = ParseCookie(raw);
        if (parsed is not null)
        {
            var at = _authTokenBox.Text.Trim();
            var ct0 = _ct0Box.Text.Trim();
            if ((parsed.Value.At != at || parsed.Value.Ct0 != ct0) &&
                (at.Contains((char)61) || at.Contains((char)59) || ct0.Contains((char)61) || ct0.Contains((char)59)))
            {
                _applying = true;
                _authTokenBox.Text = parsed.Value.At;
                _ct0Box.Text = parsed.Value.Ct0;
                _applying = false;
                RememberExtras(raw);
                _loginStatus.Text = "已自动拆分 auth_token 与 ct0";
            }
        }

        S.AuthToken = _authTokenBox.Text.Trim();
        S.Ct0 = _ct0Box.Text.Trim();
        AppSettings.Instance.Save();
        RefreshLoginVisual();
    }

    /// <summary>
    /// 从各种粘贴格式里解析 (auth_token, ct0)。
    /// 规则与 Flutter 版 account_section.dart 的 _parseCookie 一致：
    /// 分号/换行/Tab 都当分隔符，容忍 `cookie: ` 前缀、引号与 DevTools 表格形态。
    /// </summary>
    private static (string At, string Ct0)? ParseCookie(string raw)
    {
        var text = (raw ?? "").Trim();
        if (text.Length == 0) return null;

        string? at = null, ct0 = null;
        foreach (var part in Regex.Split(text, "[;\\r\\n\\t]+"))
        {
            var s = part.Trim();
            if (s.Length == 0) continue;
            var i = s.IndexOf((char)61);
            if (i <= 0) continue;
            var k = s[..i].Trim().ToLowerInvariant();
            var colon = k.LastIndexOf((char)58);
            if (colon >= 0) k = k[(colon + 1)..].Trim();
            var v = s[(i + 1)..].Trim().Replace("\"", "");
            if (k == "auth_token" && v.Length > 0 && at is null) at = v;
            if (k == "ct0" && v.Length > 0 && ct0 is null) ct0 = v;
        }

        // DevTools 表格形态：标签与值之间是 Tab / 空格 / 冒号，**没有等号**。
        // 这一支必须单独处理 —— 实测「从 DevTools 整段复制的表格」全是这个形状，
        // 只靠上面的 k=v 分支会一个都取不到（2026-10-24 自测：10 例里这一例 FAIL）。
        at ??= ValueAfterLabel(text, "auth_token");
        ct0 ??= ValueAfterLabel(text, "ct0");

        // **不要用「抠 32 位十六进制」兜底**（2026-10-28 修正，与 Flutter 版同步）。
        // 原来的写法用 [0-9a-f]{32} 从整段文本里抓一段，在 ct0 实际长度不是 32 时
        // 会把用户的真实值**静默截断成前 32 位**，导致登录必然失败且看不出原因。
        // ct0 长度并不固定（实测见过 160 位）。现在只靠上面的「k=v」与「标签后取值」
        // 两条路，取不到就返回 null，让用户看到明确提示而不是拿到一个被截断的值。

        if (at is null || ct0 is null || at == ct0) return null;
        return (at, ct0);
    }

    /// <summary>
    /// 取标签之后第一个「像值」的片段（Tab / 空格 / 等号 / 冒号分隔都容忍）。
    /// 对应 Flutter 版 account_section.dart 的 `_valueAfterLabel`。
    ///
    /// 用字符常量拼分隔符而不是写转义：本项目反复踩过「TS/C# 双层转义把 \t 写坏」的坑，
    /// 用 (char)9 / (char)58 这类常量在两边都不会被改写。
    /// </summary>
    private static string? ValueAfterLabel(string text, string label)
    {
        var idx = text.ToLowerInvariant().IndexOf(label, StringComparison.Ordinal);
        if (idx < 0) return null;
        var rest = text[(idx + label.Length)..];
        rest = rest.TrimStart(new[] { (char)32, (char)9, (char)61, (char)58 });
        var m = Regex.Match(rest, "^([^;,\t ]+)");
        if (!m.Success) return null;
        var v = m.Groups[1].Value.Trim().Trim((char)34);
        if (v.Length == 0) return null;
        var lower = v.ToLowerInvariant();
        if (lower == "ct0" || lower == "auth_token") return null;
        return v;
    }

    /// <summary>记住 auth_token / ct0 之外的其它 cookie 字段（原版发整段 cookie）。</summary>
    private void RememberExtras(string raw)
    {
        var keep = new List<string>();
        foreach (var part in Regex.Split(raw, "[;\\r\\n\\t]+"))
        {
            var s = part.Trim();
            var i = s.IndexOf((char)61);
            if (i <= 0) continue;
            var k = s[..i].Trim().ToLowerInvariant();
            var colon = k.LastIndexOf((char)58);
            if (colon >= 0) k = k[(colon + 1)..].Trim();
            if (k.Length == 0 || k == "auth_token" || k == "ct0") continue;
            if (!Regex.IsMatch(k, "^[a-z0-9_.\\-]+$")) continue;
            keep.Add(s);
        }
        if (keep.Count == 0) return;
        var merged = string.Join("; ", keep.Distinct());
        S.ExtraCookies = merged;
        AppSettings.Instance.Save();
    }

    private async Task ImportFromClipboardAsync()
    {
        try
        {
            var data = Clipboard.GetContent();
            if (!data.Contains(StandardDataFormats.Text))
            {
                _loginStatus.Text = "剪贴板为空";
                return;
            }
            // **不要**用 .GetAwaiter().GetResult() 同步等：剪贴板是 WinRT 异步 API，
            // 在 UI 线程上同步阻塞有死锁风险（实测过同类调用偶发卡住）。
            var text = await data.GetTextAsync();
            var parsed = ParseCookie(text);
            if (parsed is null)
            {
                _loginStatus.Text = "剪贴板里没有同时找到 auth_token 与 ct0";
                return;
            }
            _applying = true;
            _authTokenBox.Text = parsed.Value.At;
            _ct0Box.Text = parsed.Value.Ct0;
            _applying = false;
            RememberExtras(text);
            S.AuthToken = parsed.Value.At;
            S.Ct0 = parsed.Value.Ct0;
            AppSettings.Instance.Save();
            RefreshLoginVisual();
            _loginStatus.Text = "已从剪贴板导入 auth_token 与 ct0，点击「保存并验证」确认登录";
        }
        catch (Exception ex)
        {
            _loginStatus.Text = "剪贴板访问失败：" + ex.Message;
        }
    }

    private static async Task OpenLoginPageAsync()
    {
        try
        {
            await Windows.System.Launcher.LaunchUriAsync(new Uri("https://x.com/login"));
        }
        catch
        {
            // 没有默认浏览器等情况：静默 —— 用户可自行打开，页面上的说明已给出路径
        }
    }

    /// <summary>
    /// 保存并验证：先落盘，再打 X 的 REST v1.1 `account/verify_credentials.json`。
    ///
    /// 为什么用 v1.1 而不是 GraphQL：v1.1 的 queryId 不会轮换（实测返回 401 而非 404，
    /// 说明端点稳定存在），而 GraphQL 的 doc_id 每 2~4 周换一次。
    /// 验证失败**不删凭据** —— 网络不通与凭据失效要分开，否则一次断网就把用户的登录态抹了。
    /// </summary>
    private async Task VerifyAsync()
    {
        var at = _authTokenBox.Text.Trim();
        var ct0 = _ct0Box.Text.Trim();

        if (at.Length == 0 || ct0.Length == 0)
        {
            _loginStatus.Text = "❌ auth_token 和 ct0 都要填";
            return;
        }
        // **不要硬性校验长度**（2026-10-28 修正，与 Flutter 版同步）。
        // 原来这里强制 ct0 必须「恰好 32 位十六进制」、auth_token ≥20 位 —— 都是没验证过的假设。
        // 实测 ct0 长度并不固定（见过 160 位），这条校验会把正常值判死，登录必然失败。
        // 现在只保留两条最低限度检查：
        //   ① 长度 ≥8（防止明显没粘全）；
        //   ② 不含分隔符（空格/分号/换行/引号/等号）—— 那说明用户误粘了整段 cookie。
        if (ct0.Length < 8 || HasCookieSeparators(ct0))
        {
            _loginStatus.Text = ct0.Length < 8
                ? $"❌ ct0 太短（当前 {ct0.Length} 位），可能没粘全"
                : "❌ ct0 里含有空格/分号/引号等分隔符 —— 请只粘 Value 那一串";
            return;
        }
        if (at.Length < 8 || HasCookieSeparators(at))
        {
            _loginStatus.Text = at.Length < 8
                ? $"❌ auth_token 太短（当前 {at.Length} 位），可能没粘全"
                : "❌ auth_token 里含有空格/分号/引号等分隔符 —— 请只粘 Value 那一串";
            return;
        }

        S.AuthToken = at;
        S.Ct0 = ct0;
        AppSettings.Instance.Save();

        _verifyButton.IsEnabled = false;
        _loginStatus.Text = "正在验证…";
        try
        {
            var screenName = await FetchScreenNameAsync(at, ct0);
            if (screenName is null)
            {
                _loginStatus.Text = "⚠ 已保存，但没能确认登录状态（请检查网络或代理）";
            }
            else
            {
                S.LastVerifiedUser = screenName;
                AppSettings.Instance.Save();
                _loginStatus.Text = $"✅ 已登录 @{screenName}";
            }
        }
        catch (Exception ex)
        {
            _loginStatus.Text = "❌ 验证失败：" + ex.Message;
        }
        finally
        {
            _verifyButton.IsEnabled = true;
            RefreshLoginVisual();
        }
    }

    /// <summary>
    /// 验证登录态并取回 @screen_name。
    ///
    /// ### 为什么不用 verify_credentials（2026-10-28 实测结论）
    /// 原来走的是 REST v1.1 `account/verify_credentials.json`。实测（用真实登录 cookie）：
    ///   · api.x.com / api.twitter.com / x.com 三个域下的 v1.1 该端点**全部返回 404**
    ///     `{"errors":[{"message":"Sorry, that page does not exist","code":34}]}`；
    ///   · 同一份 cookie 走 GraphQL `Viewer` 却返回 **200** 且能拿到 screen_name。
    /// 说明 **X 已下线 v1.1 用户端点**，不是用户的 cookie 或代理有问题。
    ///
    /// ### 现在的做法
    /// 调 GraphQL `Viewer`（无参查询，返回当前登录账号信息）。
    /// queryId 从 x.com 首页的 JS bundle 里解析（X 每 2~4 周轮换一次，硬编码必然过期）；
    /// 解析失败时退回内置兜底值。
    /// </summary>
    private static async Task<string?> FetchScreenNameAsync(string authToken, string ct0)
    {
        var handler = new HttpClientHandler { UseCookies = false };
        var cfg = AppSettings.Instance;
        if (cfg.ProxyEnable && !cfg.ProxyUseSystem && !string.IsNullOrWhiteSpace(cfg.ProxyUrl))
        {
            handler.Proxy = new System.Net.WebProxy(cfg.ProxyUrl.Trim());
            handler.UseProxy = true;
        }

        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(25) };

        var queryId = await ResolveViewerQueryIdAsync(http, ct0);
        var url = "https://x.com/i/api/graphql/" + queryId + "/Viewer?variables="
                  + Uri.EscapeDataString("{}");

        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Bearer);
        req.Headers.TryAddWithoutValidation("Cookie", $"auth_token={authToken}; ct0={ct0}");
        req.Headers.TryAddWithoutValidation("x-csrf-token", ct0);
        req.Headers.TryAddWithoutValidation("x-twitter-active-user", "yes");
        req.Headers.TryAddWithoutValidation("x-twitter-auth-type", "OAuth2Session");
        req.Headers.TryAddWithoutValidation("User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36");

        using var res = await http.SendAsync(req);
        var body = await res.Content.ReadAsStringAsync();
        if (!res.IsSuccessStatusCode)
            throw new InvalidOperationException(DescribeFailure((int)res.StatusCode, body));

        var m = Regex.Match(body, "\"screen_name\"\\s*:\\s*\"([^\"]+)\"");
        return m.Success ? m.Groups[1].Value : null;
    }

    /// <summary>
    /// 把失败原因说清楚 —— 不再一律报「cookie 可能已失效」。
    /// 用户 2026-10-28 反馈：网络/端点问题被包装成 cookie 失效，误导排查方向。
    /// </summary>
    private static string DescribeFailure(int code, string body)
    {
        if (code == 401 || code == 403)
            return $"HTTP {code}：cookie 无效或已过期，请重新从 DevTools 复制 auth_token 与 ct0";
        if (code == 404)
            return $"HTTP 404：接口不存在（X 可能改版了）。这不是 cookie 问题，请把这条反馈给开发者";
        if (code == 429)
            return "HTTP 429：请求太频繁，被 X 限流，等几分钟再试";
        var hint = body.Length > 0 && body.Length < 200 ? "　" + body : "";
        return $"HTTP {code}{hint}";
    }

    /// <summary>
    /// 解析 GraphQL `Viewer` 的 queryId：抓 x.com 首页 → 找 JS bundle → 正则提取。
    /// 失败时退回 <see cref="ViewerQueryIdFallback"/>（可能已过期，但总比没有强）。
    /// </summary>
    private static async Task<string> ResolveViewerQueryIdAsync(HttpClient http, string ct0)
    {
        try
        {
            using var homeReq = new HttpRequestMessage(HttpMethod.Get, "https://x.com/");
            homeReq.Headers.TryAddWithoutValidation("Cookie", $"ct0={ct0}");
            homeReq.Headers.TryAddWithoutValidation("User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36");
            using var homeRes = await http.SendAsync(homeReq);
            var html = await homeRes.Content.ReadAsStringAsync();

            var bundles = Regex.Matches(html,
                    "https://abs\\.twimg\\.com/(?:responsive-web/client-web|x-web)[^\"'\\s\\\\]+\\.js")
                .Select(x => x.Value).Distinct().Take(25);

            foreach (var b in bundles)
            {
                try
                {
                    using var br = new HttpRequestMessage(HttpMethod.Get, b);
                    using var bres = await http.SendAsync(br);
                    if (!bres.IsSuccessStatusCode) continue;
                    var js = await bres.Content.ReadAsStringAsync();

                    var m = Regex.Match(js, "queryId:\"([A-Za-z0-9_-]{15,})\",operationName:\"Viewer\"");
                    if (!m.Success)
                        m = Regex.Match(js, "operationName:\"Viewer\".{0,200}?queryId:\"([A-Za-z0-9_-]{15,})\"");
                    if (m.Success) return m.Groups[1].Value;
                }
                catch { }
            }
        }
        catch { }

        return ViewerQueryIdFallback;
    }

    /// <summary>Viewer 的 queryId 兜底值（2026-10-28 从 bundle 实测取得，过期后由上面的解析覆盖）。</summary>
    private const string ViewerQueryIdFallback = "TpQxQtWMTMnIAMPlMGMqNw";
    private void Logout()
    {
        S.AuthToken = "";
        S.Ct0 = "";
        S.ExtraCookies = "";
        S.LastVerifiedUser = "";
        AppSettings.Instance.Save();
        _applying = true;
        _authTokenBox.Text = "";
        _ct0Box.Text = "";
        _applying = false;
        _loginStatus.Text = "已退出登录";
        RefreshLoginVisual();
    }

    /// <summary>掩码展示当前 cookie（不把令牌明文铺在界面上）。</summary>
    private string MaskCookie() =>
        S.HasCredentials ? "auth_token=" + new string((char)8226, 12) + "; ct0=" + new string((char)8226, 12) : "（未设置）";

    /// <summary>刷新登录状态行与按钮可用性。</summary>
    private void RefreshLoginVisual()
    {
        var has = S.HasCredentials;
        var verified = S.LastVerifiedUser;

        _loginBadgeText.Text = verified.Length > 0 ? "已登录" : (has ? "未验证" : "未登录");
        _loginBadge.Background = verified.Length > 0 ? SettingRows.AccentFill : SettingRows.SubtleFill;
        _loginHint.Text = verified.Length > 0
            ? $"已登录 @{verified}"
            : (has ? "已保存凭据，尚未联网验证" : "尚未登录（抓取媒体需要登录）");
        _logoutButton.IsEnabled = has;
    }

    // ── ② 下载 ──────────────────────────────────────────────

    private UIElement BuildDownloadCard()
    {
        var panel = new StackPanel { Spacing = 14 };

        // 保存目录
        var dirRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _saveDirBox = new TextBox
        {
            Text = string.IsNullOrEmpty(S.SaveDir) ? AppSettings.Instance.SaveDirBase : S.SaveDir,
            IsReadOnly = true,
            MinWidth = 320,
            PlaceholderText = "未选择（用全局默认目录）",
        };
        dirRow.Children.Add(_saveDirBox);
        var pickBtn = new Button { Content = "选择文件夹" };
        pickBtn.Click += async (_, _) => await PickDirAsync();
        dirRow.Children.Add(pickBtn);
        var clearBtn = new Button { Content = "清除" };
        clearBtn.Click += (_, _) =>
        {
            S.SaveDir = "";
            AppSettings.Instance.Save();
            // 清除后显示**实际会生效的那个目录**（全局值），不是一句空 ——
            // 空的输入框会被读成「没有下载目录」（Flutter 版 2026-10-15 就踩过这条）。
            var global = AppSettings.Instance.SaveDirBase;
            _saveDirBox.Text = global;
            _saveDirStatus.Text = global.Length == 0
                ? "已清除，改用数据目录\\downloads"
                : "已清除本模块设置，改回全局保存目录";
        };
        dirRow.Children.Add(clearBtn);
        panel.Children.Add(SettingRows.Row("保存目录", "留空则使用全局默认目录（数据目录\\downloads）", dirRow));

        _saveDirStatus = new TextBlock { Text = "", FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
        panel.Children.Add(_saveDirStatus);

        panel.Children.Add(SettingRows.Divider());

        // ── 命名模板：一张共用的模板编辑控件（Controls/TemplateEditor.cs）──
        //
        // 对齐 Flutter 版 lib/widgets/download_section.dart 的两个 TemplateRow：
        // 文件夹模板与文件名模板**各自**带「填入默认」与「输出示例」，而「可用变量」
        // 面板只有一份，点「插入」插到**当前正在编辑的那个框**（旧实现写死文件名框，
        // 用户 2026-10-25 投诉的正是这一点）。
        panel.Children.Add(new TextBlock
        {
            Text = "命名模板",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 4, 0, 0),
        });

        _templateEditor = new TemplateEditor(XTemplateVars, VarHintForDirTemplate);
        _dirField = _templateEditor.AddField(new TemplateFieldOptions
        {
            Label = "文件夹模板",
            Hint = DefaultDirTpl,
            DefaultTemplate = DefaultDirTpl,
            EmptyHint = "留空则直接存到保存目录下",
            Preview = RenderDirTemplate,
        }, S.DirTemplate);

        _nameField = _templateEditor.AddField(new TemplateFieldOptions
        {
            Label = "文件名模板",
            Hint = DefaultNameTpl,
            DefaultTemplate = DefaultNameTpl,
            EmptyHint = "留空则使用「媒体ID_时间戳.扩展名」",
            Preview = RenderNameTemplate,
        }, string.IsNullOrEmpty(S.FileNameTemplate) ? DefaultNameTpl : S.FileNameTemplate);

        _templateEditor.FieldChanged += (_, e) => OnTemplateChanged(e.Field, e.Value);
        panel.Children.Add(_templateEditor);

        panel.Children.Add(new TextBlock
        {
            Text = "模板改动会自动保存。",
            FontSize = 11.5,
            Opacity = 0.55,
            TextWrapping = TextWrapping.Wrap,
        });

        panel.Children.Add(SettingRows.Divider());

        // 并发 / 请求间隔 / 跳过已下载
        panel.Children.Add(SettingRows.Number("并发上限",
            "aria2 同时下载的任务数（1-16）。三个模块共用同一个下载引擎，这里是全局值。",
            AppSettings.Instance.MaxConcurrent, 1, 16,
            v => { AppSettings.Instance.MaxConcurrent = (int)v; AppSettings.Instance.Save(); }));

        panel.Children.Add(SettingRows.Number("请求间隔（毫秒）",
            "每次抓取之间的间隔。太小容易触发 X 的限流。",
            S.RequestIntervalMs, 200, 10000,
            v => { S.RequestIntervalMs = (int)v; AppSettings.Instance.Save(); }));

        panel.Children.Add(SettingRows.Switch("跳过已下载",
            "同一条推文重复下载时自动跳过已经存在的文件。",
            S.SkipDownloaded,
            v => { S.SkipDownloaded = v; AppSettings.Instance.Save(); }));

        return SettingRows.Card("下载", "保存路径、文件夹 / 文件名模板、同名文件处理", panel);
    }

    /// <summary>文件夹模板变量面板底部的补充提示（对齐 Flutter 版 download_section 的 varHint）。</summary>
    private const string VarHintForDirTemplate =
        "提示：文件夹模板建议只用「用户 / 推文」级变量；%MEDIA_INDEX%、%EXT%、%MEDIA_ID% 等逐文件变量会让每条媒体各建一个文件夹。";

    /// <summary>
    /// 两个模板框任一改动 → 立即落盘（字段标签判别，不靠下标，免得以后加字段错位）。
    /// </summary>
    private void OnTemplateChanged(TemplateField field, string value)
    {
        if (ReferenceEquals(field, _dirField)) S.DirTemplate = value;
        else if (ReferenceEquals(field, _nameField)) S.FileNameTemplate = value;
        AppSettings.Instance.Save();
    }

    /// <summary>
    /// 预览用的示例上下文（同 Flutter 版 xExampleMedia 的那组数）。
    /// 复用 FileNameTemplate 引擎（与真正下载时同一份实现），预览与产出不可能漂移。
    /// </summary>
    private static TemplateContext ExampleContext() => new()
    {
        PostId = "1145141919810",
        PostTime = new DateTime(2024, 1, 20, 21, 15, 36),
        UserId = "1145141919",
        UserName = "这是用户昵称",
        UserScreenName = "userscreenname",
        MediaId = "1234567890123456789",
        MediaWidth = 1323,
        MediaHeight = 1136,
        MediaType = "image",
        Extension = ".jpg",
        MediaIndex = 1,
        MediaCount = 4,
        Content = "这里是推文内容,这里是推文内容，这里是推文内容，这里是推文内容，"
                + "这里是推文内容，这里是推文内容。",
    };

    private static string RenderDirTemplate(string template)
        => FileNameTemplate.Resolve(template, ExampleContext()).Trim();

    private static string RenderNameTemplate(string template)
        => FileNameTemplate.Resolve(template, ExampleContext()).Trim();

    private async Task PickDirAsync()
    {
        try
        {
            var folder = await FolderPickerService.PickAsync();
            if (folder is null) return;
            var (ok, msg) = FolderPickerService.VerifyWritable(folder.Path);
            if (!ok)
            {
                _saveDirStatus.Text = "❌ 该目录不可写：" + msg;
                return;
            }
            S.SaveDir = folder.Path;
            AppSettings.Instance.Save();
            _saveDirBox.Text = folder.Path;
            _saveDirStatus.Text = "✅ 已保存，立即生效";
        }
        catch (Exception ex)
        {
            _saveDirStatus.Text = "❌ 选择失败：" + ex.GetType().Name + " " + ex.Message;
        }
    }

    // ── ③ 筛选 ──────────────────────────────────────────────

    private UIElement BuildFilterCard()
    {
        var panel = new StackPanel { Spacing = 12 };

        // 媒体类型
        var types = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var current = (S.MediaTypeFilter ?? "").Split((char)44, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim().ToLowerInvariant()).ToHashSet();

        foreach (var (id, label) in new[] { ("video", "视频"), ("image", "图片"), ("gif", "GIF") })
        {
            var cb = new CheckBox { Content = label, IsChecked = current.Contains(id), Tag = id, MinWidth = 0 };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(cb, label);
            cb.Checked += (_, _) => ToggleMediaType(id, true);
            cb.Unchecked += (_, _) => ToggleMediaType(id, false);
            types.Children.Add(cb);
        }
        panel.Children.Add(SettingRows.Row("媒体类型", "不勾选任何一项表示不限类型。", types));

        panel.Children.Add(SettingRows.Divider());

        // 时间范围
        var rangePanel = new StackPanel { Spacing = 8 };

        var enableRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = SettingRows.InlineGap };
        enableRow.Children.Add(new TextBlock { Text = "启用时间范围", FontSize = 14, VerticalAlignment = VerticalAlignment.Center });
        var rangeToggle = new ToggleSwitch { IsOn = S.TimeRangeEnabled, OnContent = "", OffContent = "", MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(rangeToggle, "启用时间范围");
        enableRow.Children.Add(rangeToggle);
        rangePanel.Children.Add(enableRow);
        rangePanel.Children.Add(SettingRows.Description("只下载发布时间落在区间内的推文。到达下界后停止继续翻页。"));

        // StackPanel 没有 IsEnabled（那是 Control 的成员），所以逐个控件设。
        var dates = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };

        var fromPicker = new CalendarDatePicker
        {
            PlaceholderText = "起始日期",
            DateFormat = "{year.full}-{month.integer(2)}-{day.integer(2)}",
            MinWidth = 180,
        };
        if (DateTime.TryParse(S.DateFrom, out var df)) fromPicker.Date = df;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(fromPicker, "起始日期");
        fromPicker.DateChanged += (_, e) =>
        {
            S.DateFrom = e.NewDate?.ToString("yyyy-MM-dd") ?? "";
            AppSettings.Instance.Save();
        };
        dates.Children.Add(fromPicker);

        dates.Children.Add(new TextBlock { Text = "至", VerticalAlignment = VerticalAlignment.Center, Opacity = 0.7 });

        var toPicker = new CalendarDatePicker
        {
            PlaceholderText = "结束日期",
            DateFormat = "{year.full}-{month.integer(2)}-{day.integer(2)}",
            MinWidth = 180,
        };
        if (DateTime.TryParse(S.DateTo, out var dt)) toPicker.Date = dt;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toPicker, "结束日期");
        toPicker.DateChanged += (_, e) =>
        {
            S.DateTo = e.NewDate?.ToString("yyyy-MM-dd") ?? "";
            AppSettings.Instance.Save();
        };
        dates.Children.Add(toPicker);

        fromPicker.IsEnabled = S.TimeRangeEnabled;
        toPicker.IsEnabled = S.TimeRangeEnabled;

        rangeToggle.Toggled += (_, _) =>
        {
            S.TimeRangeEnabled = rangeToggle.IsOn;
            AppSettings.Instance.Save();
            fromPicker.IsEnabled = rangeToggle.IsOn;
            toPicker.IsEnabled = rangeToggle.IsOn;
        };

        rangePanel.Children.Add(dates);
        panel.Children.Add(rangePanel);

        return SettingRows.Card("筛选", "媒体类型与时间范围", panel);
    }

    private void ToggleMediaType(string id, bool on)
    {
        var set = (S.MediaTypeFilter ?? "").Split((char)44, StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim().ToLowerInvariant()).ToHashSet();
        if (on) set.Add(id); else set.Remove(id);
        // 固定顺序输出，避免每次点击都改字符串形状（便于人读 JSON）
        S.MediaTypeFilter = string.Join(",", new[] { "video", "image", "gif" }.Where(set.Contains));
        AppSettings.Instance.Save();
    }

    // ── ④ 接口缓存 ──────────────────────────────────────────

    private UIElement BuildCacheCard()
    {
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(SettingRows.Description(
            "X 的 GraphQL 接口标识（queryId）每 2~4 周轮换一次，过期后表现为「搜不到用户」或「加载不出媒体」。" +
            "WinUI 版目前尚未实现 queryId 缓存 —— 抓取链路本身还在等 WebView2 内嵌落地，" +
            "所以这里只作说明，没有可点的清理按钮（不摆一个点了没反应的按钮）。"));
        return SettingRows.Card("接口缓存", "X 接口标识缓存（排障）", panel);
    }

    /// <summary>
    /// 值里是不是混进了 cookie 分隔符 —— 用来判断「用户是不是把整段 cookie 粘进来了」。
    /// 比「必须 32 位十六进制」这种长度/格式假设可靠得多：
    /// X 的 auth_token / ct0 长度都不固定，但**值本身一定不含分隔符**。
    /// </summary>
    private static bool HasCookieSeparators(string v)
        => v.IndexOf(' ') >= 0 || v.IndexOf(';') >= 0 || v.IndexOf('=') >= 0
           || v.IndexOf('"') >= 0 || v.IndexOf('\n') >= 0 || v.IndexOf('\r') >= 0
           || v.IndexOf('\t') >= 0;
}
