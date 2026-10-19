#include "system_backdrop_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <dwmapi.h>

#include <memory>
#include <string>

// NOTE: this file must stay pure ASCII. MSVC decodes sources with the system
// code page (936 here) and turns any non-ASCII byte into C4819, which /WX
// promotes to C2220 and which then cascades into bogus syntax errors.

namespace system_backdrop {

namespace {

constexpr char kChannelName[] = "parse_dl/system_backdrop";
constexpr char kMethodSetBackdrop[] = "setBackdrop";

// DWMWA_SYSTEMBACKDROP_TYPE. The value is a DWM_SYSTEMBACKDROP_TYPE:
//   0 = AUTO, 1 = NONE, 2 = MAINWINDOW (Mica), 3 = TRANSIENTWINDOW (Acrylic),
//   4 = TABBEDWINDOW (Mica Alt).
// Declared here because the SDK's dwmapi.h only defines the attribute from
// Windows 11 SDK 22621 onwards and this file must also build on older ones.
constexpr DWORD kDwmSystemBackdropType = 38;
// DWMWA_USE_IMMERSIVE_DARK_MODE; 20 is the value since Windows 11 22H2
// (older builds used 19, which current Windows ignores).
constexpr DWORD kDwmUseImmersiveDarkMode = 20;

constexpr int kBackdropNone = 1;
constexpr int kBackdropMica = 2;
constexpr int kBackdropAcrylic = 3;
constexpr int kBackdropMicaAlt = 4;

// Contract value -> DWM backdrop type. "acrylic-thin" has no DWM equivalent:
// DWM_SYSTEMBACKDROP_TYPE has a single acrylic tier, so both acrylic tiers map
// to the same value and look identical on screen. The WinAppSDK
// DesktopAcrylicController does expose DesktopAcrylicKind::Thin, but see the
// class comment for why that path cannot be used here.
bool BackdropTypeOf(const std::string& type, int* out) {
  if (type == "mica") {
    *out = kBackdropMica;
  } else if (type == "mica-alt") {
    *out = kBackdropMicaAlt;
  } else if (type == "acrylic" || type == "acrylic-thin") {
    *out = kBackdropAcrylic;
  } else if (type == "none") {
    *out = kBackdropNone;
  } else {
    return false;
  }
  return true;
}

// Window material through DWM system backdrops.
//
// ### Why not the Windows App SDK composition controllers
//
// MicaController / DesktopAcrylicController are the documented way to get
// Mica and to distinguish acrylic from thin acrylic, and this plugin used them
// first. On a Flutter runner window they crash the process instead:
// SetSystemBackdropConfiguration succeeds, and then the first window state
// change (move / z-order / minimize) dies with 0xC000027B -- STOWED_EXCEPTION,
// an uncaught WinRT async exception raised by coremessaging.dll.
//
// Measured with F:\samples\_verify\probe_crash_scope.ps1 (six actions, one
// fresh process each). Every combination below still crashed on all four
// window-state actions, so the fault is not about which thread owns the queue:
//   - DispatcherQueueController::CreateOnCurrentThread() on the platform thread
//   - DispatcherQueue::GetForCurrentThread() reuse (returns null there, so it
//     falls through to creating one -- the embedder owns no Microsoft.UI queue)
//   - CreateOnCurrentThread() on a dedicated thread with its own message loop
//   - the same, plus a CoreMessaging (Windows.System) queue on that thread
//   - a CoreMessaging queue on the platform thread itself
//   - target built from the child view HWND and from GetAncestor(GA_ROOT)
//   - WS_EX_NOREDIRECTIONBITMAP set on the top-level window
// Removing the plugin entirely, or attaching the controller without
// SetSystemBackdropConfiguration, keeps all six actions alive -- which is what
// pins the fault on the composition path and not on window handling.
//
// DWM system backdrops drive the same visual result from outside the process
// and survive all six actions. The cost is the missing thin-acrylic tier.
class BackdropController {
 public:
  explicit BackdropController(HWND hwnd) : hwnd_(hwnd) {}

  // true = applied; false = unsupported tier / DWM refused.
  bool Apply(const std::string& type, bool dark, bool active) {
    int backdrop = kBackdropNone;
    if (!BackdropTypeOf(type, &backdrop)) return false;

    // The backdrop belongs to the top-level window. The Flutter view HWND is a
    // child, and DWM ignores the attribute on it.
    const HWND top = ::GetAncestor(hwnd_, GA_ROOT);
    if (top == nullptr) return false;

    const BOOL dark_flag = dark ? TRUE : FALSE;
    ::DwmSetWindowAttribute(top, kDwmUseImmersiveDarkMode, &dark_flag,
                            sizeof(dark_flag));

    const HRESULT hr = ::DwmSetWindowAttribute(
        top, kDwmSystemBackdropType, &backdrop, sizeof(backdrop));
    if (FAILED(hr)) return false;

    // "none" means no system material at all: the window must also stop
    // letting the desktop through, otherwise the Flutter surface renders over
    // an undefined background. DwmExtendFrameIntoClientArea is what the
    // previous flutter_acrylic path did, and its removal is what makes the
    // tier switch visible.
    if (backdrop == kBackdropNone) {
      MARGINS margins{0, 0, 0, 0};
      ::DwmExtendFrameIntoClientArea(top, &margins);
    }

    // |active| is deliberately unused: DWM dims Mica on focus loss by itself,
    // and there is no API to override that per window. The Dart side still
    // sends it so the channel contract stays stable.
    (void)active;
    return true;
  }

 private:
  HWND hwnd_;
};

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

// Keeps the method channel alive for as long as the registrar lives.
class ChannelHolder : public flutter::Plugin {
 public:
  explicit ChannelHolder(
      std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel)
      : channel_(std::move(channel)) {}

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace

void SystemBackdropPlugin::RegisterWithEngine(flutter::FlutterEngine* engine) {
  // The runner has no PluginRegistrarWindows of its own; the registry only
  // vends the C-level registrar ref. Construct the wrapper from it.
  //
  // The wrapper MUST be heap-allocated and never destroyed: PluginRegistrar's
  // destructor calls ClearPlugins(), which destroys every plugin it owns --
  // including the MethodChannel. A stack-local registrar silently unregisters
  // the channel the moment this function returns, so setBackdrop is never
  // delivered (measured: plugin log file never created).
  FlutterDesktopPluginRegistrarRef ref =
      engine->GetRegistrarForPlugin("SystemBackdropPlugin");
  if (ref == nullptr) return;
  auto* registrar = new flutter::PluginRegistrarWindows(ref);
  RegisterWithRegistrar(registrar);
}

void SystemBackdropPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  auto window = registrar->GetView()->GetNativeWindow();
  auto controller = std::make_shared<BackdropController>(window);
  auto last_type = std::make_shared<std::string>("none");

  channel->SetMethodCallHandler(
      [controller, last_type](
          const flutter::MethodCall<flutter::EncodableValue>& call,
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

        // Same tier, only dark/focus changed. DWM needs no rebuild for that:
        // Apply() is idempotent and only writes two attributes, so re-applying
        // cannot make the material blink.
        const bool applied = controller->Apply(type, dark, active);
        *last_type = applied ? type : std::string("none");
        result->Success(flutter::EncodableValue(applied));
      });

  registrar->AddPlugin(std::make_unique<ChannelHolder>(std::move(channel)));
}

}  // namespace system_backdrop
