#include "system_backdrop_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <dwmapi.h>

#include <memory>
#include <string>

// Windows App SDK composition controllers.
#include <winrt/base.h>
// Microsoft.UI.Composition.h must come BEFORE Microsoft.UI.Composition.Interop.h:
// the interop header references ICompositionGraphicsDevice, which is declared
// there. Including them the other way round gives a bare "syntax error:
// identifier ICompositionGraphicsDevice".
#include <winrt/Microsoft.UI.Composition.h>
#include <winrt/Windows.UI.Composition.h>
#include <winrt/Windows.UI.Composition.Desktop.h>
// ICompositorDesktopInterop / IDesktopWindowTarget (the ABI forms used to
// create a DesktopWindowTarget from a plain HWND) live in this SDK header,
// not in windows.ui.composition.desktop.h.
//
// No "winrt/" prefix: the include dir already IS .../Include/<ver>/winrt.
#include <windows.ui.composition.interop.h>
#include <winrt/Microsoft.UI.Composition.SystemBackdrops.h>
#include <winrt/Microsoft.UI.Dispatching.h>
//
// NOTE: do NOT include <Microsoft.UI.Composition.Interop.h>. It only declares
// the graphics-device / drawing-surface interop interfaces, which this plugin
// never uses, and it drags in a chain of ABI declarations that collides with
// the C++/WinRT projection headers above. The only interface needed here is
// Microsoft::UI::Composition::ICompositionSupportsSystemBackdrop, which comes
// with the SystemBackdrops projection.

// NOTE: do NOT include <DispatcherQueue.h>. It declares
// ABI::Windows::System::IDispatcherQueueController and drags in a specific
// metadata projection order that fights the WinAppSDK one. Since this plugin
// uses DispatcherQueue::GetForCurrentThread() + EnsureSystemDispatcherQueue()
// (both from the Microsoft.UI.Dispatching projection), the C header is not
// needed at all.

// Windows App Runtime bootstrap. Unpackaged apps must add the installed
// framework package to the process package graph, otherwise the WinAppSDK
// composition controllers fail with "class not registered".
#include <MddBootstrap.h>
#pragma comment(lib, "Microsoft.WindowsAppRuntime.Bootstrap.lib")

// NOTE: this file must stay pure ASCII. MSVC decodes sources with the system
// code page (936 here) and turns any non-ASCII byte into C4819, which /WX
// promotes to C2220 and which then cascades into bogus syntax errors.

namespace system_backdrop {

namespace {

// Diagnostics go to the debugger output only (DebugView / VS Output window).
// No files are written: the previous %TEMP% log was for bring-up only.
void Diag(const std::string& msg) { ::OutputDebugStringA(msg.c_str()); }

constexpr char kChannelName[] = "parse_dl/system_backdrop";
constexpr char kMethodSetBackdrop[] = "setBackdrop";

// Major.Minor of the Windows App SDK the project is pinned to (1.7).
// Passed to MddBootstrapInitialize2 so the runtime picks a compatible
// framework package.
constexpr UINT32 kWasdkMajorMinor = 0x00010007;

using namespace winrt::Microsoft::UI::Composition::SystemBackdrops;

// One controller per window. The controller MUST outlive the call that created
// it: destroying MicaController tears the material down with it.
//
// Why this and not DWM's DWMWA_SYSTEMBACKDROP_TYPE: the DWM enum has a single
// acrylic tier, so "acrylic" and "acrylic-thin" would render identically, and
// it exposes neither Kind nor Theme. The WinAppSDK controllers give all four
// tiers (MicaKind::Base / BaseAlt, DesktopAcrylicKind::Base / Thin) plus
// SystemBackdropConfiguration for Theme and IsInputActive.
//
// HISTORY (2026-10-20): an earlier version used the same controllers but
// crashed on every window state change (move / z-order / minimize) with
// 0xC000027B in coremessaging.dll. Two things were wrong; both are fixed here:
//
//   1) It called DispatcherQueueController::CreateOnCurrentThread(). That
//      FORCES a brand new dispatcher queue onto a thread that already has one
//      (the Flutter runner main thread owns a Win32 message loop) and the two
//      pumps fight. The correct call is GetForCurrentThread() followed by
//      IDispatcherQueue3::EnsureSystemDispatcherQueue(), which attaches to the
//      existing system queue instead of creating a competing one.
//
//   2) The window was created WITHOUT WS_EX_NOREDIRECTIONBITMAP. Without it
//      DWM keeps a redirection surface for the window and the WinAppSDK
//      compositor fights DWM over the same pixels. WinUI 3 windows always
//      carry this ex-style, which is why the reference app never had this
//      problem. The flag is now set in windows/runner/win32_window.cpp at
//      CreateWindowEx time.
// Companion material window.
//
// ARCHITECTURE (2026-10-21): the WinAppSDK backdrop controllers need a window
// WITHOUT WS_EX_NOREDIRECTIONBITMAP and they own the whole DComp tree of that
// window -- any GDI/GL content the app draws there is never composited. That
// made "official material" and "Flutter UI" mutually exclusive in one window.
//
// Solution: give the material its OWN window (this one), placed directly
// BELOW the Flutter window, and make the Flutter window per-pixel transparent
// (DwmExtendFrameIntoClientArea in win32_window.cpp). DWM then composites
// Flutter's pixels over this window's material, so both are visible at once.
// Proven first with the standalone dualwin experiment.
constexpr wchar_t kMaterialWindowClass[] = L"PARSE_DL_MATERIAL_WINDOW";
constexpr UINT_PTR kSyncTimerId = 1;

class BackdropController;
BackdropController* g_controller_for_timer = nullptr;

LRESULT CALLBACK MaterialWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                 LPARAM lparam);

class BackdropController {
 public:
  explicit BackdropController(HWND hwnd) : hwnd_(hwnd) {
    g_controller_for_timer = this;
  }

  ~BackdropController() { Remove(); }

  HWND hwnd() const { return hwnd_; }

  // true = material attached; false = unsupported on this system / failed.
  bool Apply(const std::string& type, bool dark, bool active) {
    if (type == "none") {
      Remove();
      return true;
    }

    // The controllers live in the Windows App Runtime framework package.
    // An unpackaged process must join that package before touching them, or
    // every controller call fails with "class not registered".
    //
    // Failure here is NOT an error: a machine without the runtime is a
    // legitimate environment. Returning false makes the Dart side fall back
    // to an opaque background (see lib/widgets/background_layer.dart).
    Diag(std::string("Apply type=") + type);
    SyncMaterialWindow();
    if (!EnsureBootstrap()) {
      Diag("  bootstrap FAILED");
      return false;
    }
    Diag("  bootstrap ok");
    if (!EnsureTarget()) {
      Diag("  target FAILED");
      return false;
    }
    Diag("  target ok");

    // Drop the old controller first: two attached controllers fight over the
    // same surface and the result looks dirty.
    Remove();

    const SystemBackdropTheme theme =
        dark ? SystemBackdropTheme::Dark : SystemBackdropTheme::Light;

    if (type == "mica" || type == "mica-alt") {
      if (!MicaController::IsSupported()) {
        Diag("  MicaController::IsSupported() == false");
        return false;
      }
      Diag("  MicaController supported");
      auto controller = MicaController();
      controller.Kind(type == "mica-alt" ? MicaKind::BaseAlt : MicaKind::Base);
      mica_ = controller;
    } else if (type == "acrylic" || type == "acrylic-thin") {
      if (!DesktopAcrylicController::IsSupported()) return false;
      auto controller = DesktopAcrylicController();
      controller.Kind(type == "acrylic-thin" ? DesktopAcrylicKind::Thin
                                             : DesktopAcrylicKind::Base);
      acrylic_ = controller;
    } else {
      return false;
    }

    auto config = SystemBackdropConfiguration();
    config.IsInputActive(active);
    config.Theme(theme);
    configuration_ = config;

    try {
      // DIAG (2026-10-21): PARSE_DL_NOCONFIG=1 skips the configuration call
      // so "material attached" and "material configured & compositing" can be
      // told apart as crash triggers.
      bool skip_config = false;
      {
        wchar_t flag[8] = {};
        if (::GetEnvironmentVariableW(L"PARSE_DL_NOCONFIG", flag, 8) > 0 &&
            flag[0] == L'1') {
          skip_config = true;
        }
      }
      if (mica_) {
        mica_.AddSystemBackdropTarget(target_);
        if (skip_config) {
          Diag("  configuration SKIPPED (env)");
        } else {
          mica_.SetSystemBackdropConfiguration(configuration_);
        }
      } else if (acrylic_) {
        acrylic_.AddSystemBackdropTarget(target_);
        if (skip_config) {
          Diag("  configuration SKIPPED (env)");
        } else {
          acrylic_.SetSystemBackdropConfiguration(configuration_);
        }
      }
    } catch (const winrt::hresult_error& ex) {
      Diag("  AddSystemBackdropTarget threw hr=0x" +
           std::to_string(static_cast<unsigned long>(ex.code())));
      Remove();
      return false;
    } catch (...) {
      Diag("  AddSystemBackdropTarget threw unknown");
      Remove();
      return false;
    }
    Diag("  material attached");
    // Re-assert Z order: the material window must sit directly BELOW the
    // Flutter window, so Flutter's transparent pixels reveal it.
    SyncMaterialWindow();
    return true;
  }

  // Update configuration only (focus / dark change) without rebuilding the
  // controller, so the material does not blink.
  bool UpdateConfiguration(bool dark, bool active) {
    if (!configuration_) return false;
    // Window moved/resized since the last call: keep the material window glued
    // to it, otherwise the material shows at a stale rect.
    SyncMaterialWindow();
    // The root visual must cover the current client area: a mismatch here is
    // visible as the material stopping short of the window edge.
    UpdateRootVisualSize();
    configuration_.IsInputActive(active);
    configuration_.Theme(dark ? SystemBackdropTheme::Dark
                              : SystemBackdropTheme::Light);
    return true;
  }

  void Remove() {
    try {
      if (mica_) {
        mica_.RemoveAllSystemBackdropTargets();
        mica_ = nullptr;
      }
    } catch (...) {
      mica_ = nullptr;
    }
    try {
      if (acrylic_) {
        acrylic_.RemoveAllSystemBackdropTargets();
        acrylic_ = nullptr;
      }
    } catch (...) {
      acrylic_ = nullptr;
    }
    configuration_ = nullptr;
  }

 private:
  // Adds the Windows App Runtime framework package to this process package
  // graph. Idempotent: the second and later calls return immediately.
  bool EnsureBootstrap() {
    if (bootstrapped_) return true;
    try {
      const PACKAGE_VERSION min_version{};
      const HRESULT hr = ::MddBootstrapInitialize2(
          kWasdkMajorMinor, L"", min_version,
          MddBootstrapInitializeOptions_OnNoMatch_ShowUI);
      bootstrapped_ = SUCCEEDED(hr);
      ::OutputDebugStringA(bootstrapped_ ? "[backdrop] bootstrap OK\n"
                                         : "[backdrop] bootstrap FAILED\n");
      return bootstrapped_;
    } catch (...) {
      return false;
    }
  }

  // The only way a plain Win32 window obtains an
  // ICompositionSupportsSystemBackdrop target:
  //   system Windows.UI.Composition.Compositor
  //     -> ICompositorDesktopInterop::CreateDesktopWindowTarget(hwnd)
  //     -> QI to Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop
  //
  // The last step works because the interface has the same IID in both
  // metadata files (397DAFE4-B6C2-5BB9-951D-F5707DE8B7BC): the WinAppSDK
  // backdrop controllers accept that ABI interface regardless of which
  // projection it came from.
  // Creates (once) the companion material window and keeps it exactly behind
  // the Flutter window: same rect, same Z order minus one, never activated.
  HWND EnsureMaterialWindow() {
    if (material_hwnd_) {
      SyncMaterialWindow();
      return material_hwnd_;
    }
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = MaterialWndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.lpszClassName = kMaterialWindowClass;
    ::RegisterClassExW(&wc);

    // WS_EX_NOREDIRECTIONBITMAP: required by CreateDesktopWindowTarget, and it
    // is what makes this window a pure material carrier with no GDI surface.
    material_hwnd_ = ::CreateWindowExW(
        WS_EX_NOREDIRECTIONBITMAP | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
        kMaterialWindowClass, L"", WS_POPUP, 0, 0, 100, 100, nullptr, nullptr,
        ::GetModuleHandleW(nullptr), nullptr);
    if (!material_hwnd_) {
      Diag("  EnsureMaterialWindow FAILED");
      return nullptr;
    }
    ::ShowWindow(material_hwnd_, SW_SHOWNOACTIVATE);
    SyncMaterialWindow();
    // The runner does not forward WM_MOVE/WM_SIZE to plugins, so the material
    // window follows by polling. 60 ms is below the perceptible lag for a drag
    // and the rect guard makes the common case a no-op.
    ::SetTimer(material_hwnd_, kSyncTimerId, 60, nullptr);
    Diag("  material window created");
    return material_hwnd_;
  }

  // Copy the owner window's rect and put the material window directly below it
  // in Z order. Called on Apply/UpdateConfiguration and from the sync timer.
 public:
  void SyncMaterialWindow() {
    if (!material_hwnd_ || !::IsWindow(material_hwnd_)) return;
    RECT rc = {};
    if (!::GetWindowRect(hwnd_, &rc)) return;
    // Cheap idempotence guard: SetWindowPos on every message would make the
    // material flicker while the user drags the window.
    if (rc.left == last_rect_.left && rc.top == last_rect_.top &&
        rc.right == last_rect_.right && rc.bottom == last_rect_.bottom &&
        ::IsWindowVisible(material_hwnd_)) {
      return;
    }
    last_rect_ = rc;
    ::SetWindowPos(material_hwnd_, hwnd_, rc.left, rc.top,
                   rc.right - rc.left, rc.bottom - rc.top,
                   SWP_NOACTIVATE | SWP_NOREDRAW);
    UpdateRootVisualSize();
  }

  bool EnsureTarget() {
    if (target_) return true;
    try {
      // The material lives in its own window (see the class comment above).
      HWND target_hwnd = EnsureMaterialWindow();
      if (!target_hwnd) return false;
      // The Flutter runner thread is a plain Win32 thread: it has a message
      // loop but no DispatcherQueue, so GetForCurrentThread() returns null
      // (measured 2026-10-21: this was the reason every Apply() returned
      // false). WinAppSDK controllers require a DispatcherQueue on the thread
      // that owns them, so create one here.
      //
      // CreateOnCurrentThread() installs the queue on THIS thread without
      // spawning a second pump: the queue posts work to a hidden window and
      // the Flutter runner loop already dispatches those messages. The
      // controller is stored so the queue outlives this call.
      // C++/WinRT requires an apartment before any WinRT type is activated.
      // The Flutter runner thread never initialised COM, and the WinAppSDK
      // composition controllers are documented to be created on a
      // single-threaded apartment (WinUI 3 apps get one from the framework).
      // Measured 2026-10-21: without this the material attaches and then dies
      // with a stowed exception (0xC000027B, coremessaging.dll) a few seconds
      // after the first state change.
      if (!apartment_initialized_) {
        apartment_initialized_ = true;
        try {
          winrt::init_apartment(winrt::apartment_type::single_threaded);
          Diag("  init_apartment: STA ok");
        } catch (const winrt::hresult_error& ex) {
          Diag(std::string("  init_apartment failed hr=0x") +
               std::to_string(static_cast<unsigned long>(ex.code())));
        } catch (...) {
          Diag("  init_apartment failed unknown");
        }
      }

      if (!queue_controller_) {
        queue_controller_ = winrt::Microsoft::UI::Dispatching::
            DispatcherQueueController::CreateOnCurrentThread();
        Diag("  EnsureTarget: created DispatcherQueueController");
      }
      auto queue = winrt::Microsoft::UI::Dispatching::DispatcherQueue::
          GetForCurrentThread();
      if (!queue) {
        Diag("  EnsureTarget: no DispatcherQueue on this thread");
        return false;
      }
      Diag("  EnsureTarget: queue ok");
      // A queue created with CreateOnCurrentThread() is a plain queue; the
      // WinAppSDK components may require the "system" queue (the one shared
      // with CoreMessaging). Upgrading is best-effort: failure is logged only.
      try {
        queue.as<winrt::Microsoft::UI::Dispatching::IDispatcherQueue3>()
            .EnsureSystemDispatcherQueue();
        Diag("  EnsureSystemDispatcherQueue ok");
      } catch (const winrt::hresult_error& ex) {
        Diag(std::string("  EnsureSystemDispatcherQueue failed hr=0x") +
             std::to_string(static_cast<unsigned long>(ex.code())));
      }

      compositor_ = winrt::Windows::UI::Composition::Compositor();
      auto interop = compositor_.as<ABI::Windows::UI::Composition::Desktop::
                                        ICompositorDesktopInterop>();

      winrt::Windows::UI::Composition::Desktop::IDesktopWindowTarget
          desktop_target{nullptr};
      const HRESULT hr = interop->CreateDesktopWindowTarget(
          target_hwnd, /*isTopmost=*/FALSE,
          reinterpret_cast<
              ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(
              winrt::put_abi(desktop_target)));
      if (FAILED(hr) || desktop_target == nullptr) {
        Diag("  EnsureTarget: CreateDesktopWindowTarget hr=0x" +
             std::to_string(static_cast<unsigned long>(hr)));
        return false;
      }
      Diag("  EnsureTarget: CreateDesktopWindowTarget ok");

      // A DesktopWindowTarget with NO content makes the backdrop controllers
      // crash a few seconds after SetSystemBackdropConfiguration
      // (microsoft-ui-xaml#8416 "backdrop APIs still require the window to
      // have some content"). Measured 2026-10-21 on a minimal Win32 repro:
      // without a root visual -> 0xC000027B in coremessaging.dll after ~5s;
      // with an empty root visual -> survives indefinitely. The material is
      // drawn behind this visual, and the visual itself paints nothing.
      root_visual_ = compositor_.CreateSpriteVisual();
      UpdateRootVisualSize();
      desktop_target.as<winrt::Windows::UI::Composition::Desktop::
                            DesktopWindowTarget>()
          .Root(root_visual_);
      Diag("  EnsureTarget: root visual set");

      target_ = desktop_target
                    .as<winrt::Microsoft::UI::Composition::
                            ICompositionSupportsSystemBackdrop>();
      return target_ != nullptr;
    } catch (...) {
      target_ = nullptr;
      return false;
    }
  }

  // Empty visual that gives the DesktopWindowTarget a content layer; the
  // backdrop material draws behind it. Size tracks the window client area.
  void UpdateRootVisualSize() {
    if (!root_visual_) return;
    RECT rc = {};
    if (!::GetClientRect(material_hwnd_ ? material_hwnd_ : hwnd_, &rc)) return;
    root_visual_.Size({static_cast<float>(rc.right - rc.left),
                       static_cast<float>(rc.bottom - rc.top)});
  }

  HWND hwnd_;                  // the Flutter window (owner / reference rect)
  HWND material_hwnd_ = nullptr;  // companion window carrying the material
  RECT last_rect_ = {0, 0, 0, 0};  // last synced rect (idempotence guard)
  winrt::Windows::UI::Composition::SpriteVisual root_visual_{nullptr};
  bool bootstrapped_ = false;
  winrt::Microsoft::UI::Composition::SystemBackdrops::MicaController mica_{
      nullptr};
  winrt::Microsoft::UI::Composition::SystemBackdrops::DesktopAcrylicController
      acrylic_{nullptr};
  winrt::Microsoft::UI::Composition::SystemBackdrops::
      SystemBackdropConfiguration configuration_{nullptr};
  winrt::Windows::UI::Composition::Compositor compositor_{nullptr};
  winrt::Microsoft::UI::Dispatching::DispatcherQueueController
      queue_controller_{nullptr};
  bool apartment_initialized_ = false;
  winrt::Microsoft::UI::Composition::ICompositionSupportsSystemBackdrop target_{
      nullptr};
};

LRESULT CALLBACK MaterialWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                 LPARAM lparam) {
  if (message == WM_TIMER && wparam == kSyncTimerId) {
    if (g_controller_for_timer) g_controller_for_timer->SyncMaterialWindow();
    return 0;
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

std::string ReadString(const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return std::string();
  const auto* value = std::get_if<std::string>(&it->second);
  return value == nullptr ? std::string() : *value;
}

bool ReadBool(const flutter::EncodableMap& args, const char* key,
              bool fallback) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return fallback;
  const auto* value = std::get_if<bool>(&it->second);
  return value == nullptr ? fallback : *value;
}

// Lives for the whole process; one entry per top-level window.
std::unique_ptr<BackdropController> g_controller;

}  // namespace

void SystemBackdropPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [registrar](const flutter::MethodCall<flutter::EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                      result) {
        if (call.method_name() != kMethodSetBackdrop) {
          result->NotImplemented();
          return;
        }

        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Success(flutter::EncodableValue(false));
          return;
        }

        const std::string type = ReadString(*args, "type");
        const bool dark = ReadBool(*args, "dark", false);
        const bool active = ReadBool(*args, "active", true);

        HWND hwnd = registrar->GetView()->GetNativeWindow();
        if (hwnd == nullptr) {
          result->Success(flutter::EncodableValue(false));
          return;
        }

        // The backdrop belongs to the top-level window. The Flutter view HWND
        // is a child, and the controllers ignore it.
        const HWND top = ::GetAncestor(hwnd, GA_ROOT);
        if (top == nullptr) {
          result->Success(flutter::EncodableValue(false));
          return;
        }

        if (!g_controller || g_controller->hwnd() != top) {
          g_controller = std::make_unique<BackdropController>(top);
        }

        bool ok = false;
        if (type == "update-only") {
          ok = g_controller->UpdateConfiguration(dark, active);
        } else {
          ok = g_controller->Apply(type, dark, active);
        }
        result->Success(flutter::EncodableValue(ok));
      });
}

void SystemBackdropPlugin::RegisterWithEngine(flutter::FlutterEngine* engine) {
  // FlutterEngine implements PluginRegistry, so it hands out the C-level
  // registrar ref. PluginRegistrarManager wraps that ref into the C++
  // PluginRegistrarWindows the channel API needs. Calling this with a
  // different template type for the same ref is undefined behaviour, and
  // FlutterWindowsEngine already registered this one -- so reuse it.
  auto registrar_ref = engine->GetRegistrarForPlugin("system_backdrop");
  if (registrar_ref == nullptr) return;
  auto registrar = flutter::PluginRegistrarManager::GetInstance()
                       ->GetRegistrar<flutter::PluginRegistrarWindows>(
                           registrar_ref);
  RegisterWithRegistrar(registrar);
}

}  // namespace system_backdrop