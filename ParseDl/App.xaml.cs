using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;

// To learn more about WinUI, the WinUI project structure,
// and more about our project templates, see: http://aka.ms/winui-project-info.

namespace ParseDl;

/// <summary>
/// Provides application-specific behavior to supplement the default Application class.
/// </summary>
public partial class App : Application
{
    private Window? _window;

    /// <summary>当前主窗口。文件选择器要用它的 HWND 做 InitializeWithWindow，
    /// 否则 FolderPicker 在 WinUI 3 里会直接抛 COMException（没有窗口句柄）。</summary>
    public static Window? MainWindow { get; private set; }
    
    /// <summary>
    /// Initializes the singleton application object.  This is the first line of authored code
    /// executed, and as such is the logical equivalent of main() or WinMain().
    /// </summary>
    public App()
    {
        InitializeComponent();
    }

    /// <summary>
    /// Invoked when the application is launched.
    /// </summary>
    /// <param name="args">Details about the launch request and process.</param>
    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        // 先加载设置：材质档位与明暗要在建窗时就用上，否则会先闪一下默认值再切。
        ParseDl.Services.AppSettings.Instance.Load();

        _window = new MainWindow();
        MainWindow = _window;
        _window.Activate();
    }
}