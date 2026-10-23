using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ParseDl.Services;

namespace ParseDl.Pages;

/// <summary>
/// 全局设置 —— 窗口材质四档 + 明暗。材质切换走 MaterialService（官方控制器）。
/// </summary>
public sealed partial class SettingsPage : Page
{
    private MainWindow? _host;
    private bool _suppressThemeEvent;

    private static readonly (MaterialKind Kind, string Label, string Hint)[] Materials =
    {
        (MaterialKind.Mica, "Mica", "云母 —— 长驻窗口的基础层"),
        (MaterialKind.MicaAlt, "Mica Alt", "云母 · 分层 —— 带标签页的窗口"),
        (MaterialKind.Acrylic, "Acrylic", "亚克力 —— 半透明磨砂"),
        (MaterialKind.AcrylicThin, "Acrylic Thin", "亚克力 · 细 —— 更透亮"),
    };

    public SettingsPage()
    {
        InitializeComponent();
        BuildMaterialOptions();
        Loaded += (_, _) => SyncFromHost();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _host = e.Parameter as MainWindow;
        SyncFromHost();
    }

    private void BuildMaterialOptions()
    {
        foreach (var (kind, label, hint) in Materials)
        {
            var rb = new RadioButton
            {
                GroupName = "material",
                Tag = kind,
                Margin = new Thickness(0, 0, 0, 4),
                // 屏幕阅读器与自动化测试都要靠这个识别档位；不设的话
                // UIA 的 Name 是空的（实测四个 RadioButton 全是 Name=[]）。
                Content = label,
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(rb, label);
            rb.Checked += OnMaterialChecked;
            MaterialPanel.Children.Add(rb);
        }
    }

    private void SyncFromHost()
    {
        if (_host is null) return;

        _suppressThemeEvent = true;
        DarkRadio.IsChecked = _host.IsDarkTheme;
        LightRadio.IsChecked = !_host.IsDarkTheme;
        _suppressThemeEvent = false;

        foreach (var child in MaterialPanel.Children)
        {
            if (child is RadioButton rb && rb.Tag is MaterialKind k)
            {
                rb.IsChecked = k == _host.CurrentMaterial;
            }
        }

        DataDirText.Text = AppPaths.DataDir;

        var cfg = AppSettings.Instance;
        SaveDirBox.Text = cfg.SaveDirBase;
        MaxConcurrentBox.Value = cfg.MaxConcurrent;
        WriteLogsToggle.IsOn = cfg.WriteLogs;
    }

    /// <summary>
    /// 选文件夹 —— **必须走 FolderPicker**：打包应用直接写任意路径会被拦，
    /// 而选择器选中的目录系统会授予访问权。选完立刻验证可写，不通就报错不保存。
    /// </summary>
    private async void OnPickFolderClick(object sender, RoutedEventArgs e)
    {
        try
        {
            PickDirButton.IsEnabled = false;
            var folder = await FolderPickerService.PickAsync();
            if (folder is null) return;

            var path = folder.Path;
            var (ok, msg) = FolderPickerService.VerifyWritable(path);
            if (!ok)
            {
                SaveDirStatus.Text = $"❌ 该目录不可写：{msg}";
                SaveDirStatus.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.OrangeRed);
                return;
            }

            AppSettings.Instance.SaveDirBase = path;
            AppSettings.Instance.Save();
            SaveDirBox.Text = path;
            SaveDirStatus.Text = "✅ 已保存，立即生效";
            SaveDirStatus.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.LightGreen);
        }
        catch (Exception ex)
        {
            SaveDirStatus.Text = $"❌ 选择失败：{ex.GetType().Name} {ex.Message}";
            SaveDirStatus.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.OrangeRed);
        }
        finally
        {
            PickDirButton.IsEnabled = true;
        }
    }

    private void OnClearFolderClick(object sender, RoutedEventArgs e)
    {
        AppSettings.Instance.SaveDirBase = "";
        AppSettings.Instance.Save();
        SaveDirBox.Text = "";
        SaveDirStatus.Text = "已清除，改用默认目录（数据目录\\downloads）";
        SaveDirStatus.Foreground = null;
    }

    private void OnMaxConcurrentChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (double.IsNaN(args.NewValue)) return;
        AppSettings.Instance.MaxConcurrent = (int)args.NewValue;
        AppSettings.Instance.Save();
    }

    private void OnWriteLogsToggled(object sender, RoutedEventArgs e)
    {
        AppSettings.Instance.WriteLogs = WriteLogsToggle.IsOn;
        AppSettings.Instance.Save();
    }

    private void OnMaterialChecked(object sender, RoutedEventArgs e)
    {
        if (_host is null || sender is not RadioButton rb) return;
        if (rb.Tag is not MaterialKind kind) return;

        var ok = _host.ApplyMaterial(kind, _host.IsDarkTheme);
        MaterialStatus.Text = ok ? $"已应用：{kind}" : $"系统不支持该材质（{kind}）";
    }

    private void OnThemeChecked(object sender, RoutedEventArgs e)
    {
        if (_suppressThemeEvent || _host is null) return;
        var isDark = DarkRadio.IsChecked == true;
        // 改 RootGrid.RequestedTheme 而不是直接调材质：MainWindow 订阅了
        // ActualThemeChanged，会带着真实主题重新 Apply，界面与材质才一致。
        _host.ApplyTheme(isDark);
        MaterialStatus.Text = isDark ? "已切换为深色" : "已切换为浅色";
    }
}