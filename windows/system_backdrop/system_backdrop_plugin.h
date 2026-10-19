#ifndef SYSTEM_BACKDROP_PLUGIN_H_
#define SYSTEM_BACKDROP_PLUGIN_H_

#include <flutter/flutter_engine.h>
#include <flutter/plugin_registrar_windows.h>

namespace system_backdrop {

// Backdrop material via Windows App SDK composition controllers
// (MicaController / DesktopAcrylicController).
//
// Why this exists instead of flutter_acrylic: that path only writes
// DwmSetWindowAttribute(SYSTEMBACKDROP_TYPE). The DWM enum has no "thin
// acrylic" value and exposes neither Kind nor IsInputActive / Theme. This
// plugin owns the real controller objects, so all four tiers are distinct.
//
// NOTE: this file must stay pure ASCII. MSVC decodes sources with the system
// code page (936 here) and turns any non-ASCII byte into C4819, which /WX
// promotes to an error (C2220) that cascades into bogus syntax errors.
class SystemBackdropPlugin {
 public:
  // Registers the method channel on |engine|'s default plugin registrar.
  //
  // Takes the engine rather than a PluginRegistrarWindows* because this
  // plugin is registered by hand from the runner: PluginRegistry only hands
  // out the C-level FlutterDesktopPluginRegistrarRef, and the wrapper type
  // is constructed here from it.
  static void RegisterWithEngine(flutter::FlutterEngine* engine);

  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
};

}  // namespace system_backdrop

#endif  // SYSTEM_BACKDROP_PLUGIN_H_
