using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Controls;
using ParseDl.Services;

namespace ParseDl.Pages;

/// <summary>
/// 自动执行页 —— X「自动执行」与抖音「自动下载」共用。
///
/// 当前能力（如实）：
/// - 名单/目标**持久化**（落盘到 &lt;数据目录&gt;\autotask.json，重启不丢）
/// - 按行逐条处理，每条之间按设置里的「请求间隔」节流
/// - 每一行若是 http/https 直链，就真的交给 aria2 下载；否则记为「跳过」并写明原因
/// - 运行日志实时追加，可暂停 / 清空
///
/// 未实现：平台专用抓取（X 用户主页遍历、抖音滚动抓取）—— 需要登录态与站点 API，
/// 日志里会明确写「跳过：不是直链」，不假装成功。
/// </summary>
public sealed partial class AutoTaskPage : Page
{
    private bool _isDouyin;
    private string _key = "x";
    private TextBox? _listBox;
    private ToggleSwitch? _toggle;
    private TextBlock? _logText;
    private StackPanel? _logPanel;
    private CancellationTokenSource? _cts;
    private readonly List<string> _log = new();

    public AutoTaskPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _isDouyin = e.Parameter is string s && s == "douyin";
        _key = _isDouyin ? "douyin-auto" : "x-auto";
        Build();
    }

    private void Build()
    {
        Root.Children.Clear();

        var title = _isDouyin ? "自动下载" : "自动执行";
        var subtitle = _isDouyin ? "按目标批量下载（逐条节流）" : "按名单批量执行（逐条节流）";
        Root.Children.Add(UiKit.PageHeader(title, subtitle, "\uE945"));

        // 任务卡
        var panel = new StackPanel { Spacing = 12 };

        var headRow = new Grid();
        headRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        headRow.Children.Add(new TextBlock
        {
            Text = _isDouyin ? "抓取目标（每行一个直链）" : "用户名单 / 直链（每行一个）",
            FontSize = 14,
            VerticalAlignment = VerticalAlignment.Center,
        });
        _toggle = new ToggleSwitch { OffContent = "已停止", OnContent = "运行中", IsOn = false };
        Grid.SetColumn(_toggle, 1);
        headRow.Children.Add(_toggle);
        panel.Children.Add(headRow);

        _listBox = new TextBox
        {
            PlaceholderText = "每行一个 http(s) 直链；非直链会被记为跳过",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 120,
            Text = LoadList(),
        };
        _listBox.TextChanged += (_, _) => SaveList(_listBox.Text);
        panel.Children.Add(_listBox);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var startBtn = new Button
        {
            Content = "开始",
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
            MinWidth = 88,
        };
        startBtn.Click += async (_, _) => await StartRunAsync();
        actions.Children.Add(startBtn);

        var stopBtn = new Button { Content = "停止", MinWidth = 88 };
        stopBtn.Click += (_, _) => StopRun();
        actions.Children.Add(stopBtn);

        var clearBtn = new Button { Content = "清空日志", MinWidth = 88 };
        clearBtn.Click += (_, _) =>
        {
            _log.Clear();
            RenderLog();
        };
        actions.Children.Add(clearBtn);
        panel.Children.Add(actions);

        Root.Children.Add(UiKit.SectionCard("任务", panel));

        // 运行日志
        _logPanel = new StackPanel { Spacing = 4 };
        _logText = new TextBlock
        {
            Text = "还没有运行记录",
            FontSize = 13,
            Opacity = 0.6,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        _logPanel.Children.Add(_logText);
        Root.Children.Add(UiKit.SectionCard("运行日志", _logPanel, "实时追加"));
    }

    // ── 名单持久化 ────────────────────────────────────
    private string ListPath => Path.Combine(AppPaths.DataDir, "autotask.json");

    private string LoadList()
    {
        try
        {
            if (!File.Exists(ListPath)) return "";
            var map = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(ListPath));
            return map is not null && map.TryGetValue(_key, out var v) ? v : "";
        }
        catch { return ""; }
    }

    private void SaveList(string text)
    {
        try
        {
            Dictionary<string, string> map = new();
            if (File.Exists(ListPath))
            {
                var existing = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(ListPath));
                if (existing is not null) map = existing;
            }
            map[_key] = text;
            File.WriteAllText(ListPath, JsonSerializer.Serialize(map, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[AutoTask] 保存名单失败: {ex.Message}");
        }
    }

    // ── 执行 ──────────────────────────────────────────
    private async Task StartRunAsync()
    {
        if (_cts is not null) return;
        // 换行符必须三种都认：Windows 文本框内部用 \r，粘贴进来常是 \r\n，
        // 手输可能是 \n。只按 '\n' 切时，UIA 写入的多行文本会变成一整条
        // （实测：填 3 行只处理了 1 条）。
        var lines = (_listBox?.Text ?? "")
            .Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .ToList();

        if (lines.Count == 0)
        {
            AppendLog("名单为空，先粘贴每行一个目标。");
            return;
        }

        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        if (_toggle is not null) _toggle.IsOn = true;

        var module = _isDouyin ? "抖音" : "X 媒体";
        var interval = Math.Max(200, AppSettings.Instance.ForModule(_isDouyin ? "douyin" : "x").RequestIntervalMs);

        AppendLog($"开始：共 {lines.Count} 条，间隔 {interval} ms");

        var ok = 0;
        var skip = 0;
        try
        {
            for (var i = 0; i < lines.Count; i++)
            {
                if (token.IsCancellationRequested) break;
                var line = lines[i];

                if (line.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                    line.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                {
                    var (success, msg) = await DownloadStore.Instance.AddAsync(line, module);
                    if (success) { ok++; AppendLog($"[{i + 1}/{lines.Count}] 已入队：{Shorten(line)}"); }
                    else { skip++; AppendLog($"[{i + 1}/{lines.Count}] 失败：{msg}"); }
                }
                else
                {
                    skip++;
                    AppendLog($"[{i + 1}/{lines.Count}] 跳过：不是直链（{Shorten(line)}）");
                }

                if (i < lines.Count - 1) await Task.Delay(interval, token);
            }
        }
        catch (OperationCanceledException)
        {
            AppendLog("已停止。");
        }
        catch (Exception ex)
        {
            AppendLog($"异常：{ex.Message}");
        }
        finally
        {
            _cts?.Dispose();
            _cts = null;
            if (_toggle is not null) _toggle.IsOn = false;
            AppendLog($"结束：成功 {ok}，跳过/失败 {skip}");
        }
    }

    private void StopRun()
    {
        _cts?.Cancel();
        if (_toggle is not null) _toggle.IsOn = false;
    }

    private static string Shorten(string s) => s.Length <= 60 ? s : s[..57] + "…";

    private void AppendLog(string line)
    {
        _log.Add($"{DateTime.Now:HH:mm:ss}  {line}");
        if (_log.Count > 300) _log.RemoveRange(0, _log.Count - 300);
        RenderLog();
    }

    private void RenderLog()
    {
        if (_logText is null) return;
        _logText.Text = _log.Count == 0 ? "还没有运行记录" : string.Join("\n", _log);
    }
}