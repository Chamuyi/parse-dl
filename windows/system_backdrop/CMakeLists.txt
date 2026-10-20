# 窗口材质插件：用 Windows App SDK 的合成控制器做 Mica / 亚克力四档。
#
# 走的是 MicaController / DesktopAcrylicController —— 与参照物（图吧工具箱，
# WinUI 3）完全同一套 API，因此四档都能区分（MicaKind::Base / BaseAlt、
# DesktopAcrylicKind::Base / Thin），且能通过 SystemBackdropConfiguration
# 控制 Theme 与 IsInputActive。
#
# 2026-10-20 修复的两处（此前这条路上窗口一移动就 0xC000027B 崩）：
#   1) 队列：改用 GetForCurrentThread() + IDispatcherQueue3::
#      EnsureSystemDispatcherQueue()，不再 CreateOnCurrentThread() 强建新队列
#      （那会和 Flutter runner 自己的消息泵打架）。
#   2) 窗口：windows/runner/win32_window.cpp 在 CreateWindowEx 时带上
#      WS_EX_NOREDIRECTIONBITMAP（WinUI 3 窗口天生带它）。
# 细节见 system_backdrop_plugin.cpp 的类注释。

cmake_minimum_required(VERSION 3.14)
project(system_backdrop LANGUAGES CXX)

# STATIC, not SHARED: this is an in-process plugin linked straight into the
# runner exe (same shape as Flutter's own Windows plugins). A SHARED library
# would need a .lib import library that MSVC does not generate for a DLL with
# no exported symbols.
add_library(${PROJECT_NAME} STATIC
  "system_backdrop_plugin.cpp"
  "system_backdrop_plugin.h"
)

apply_standard_settings(${PROJECT_NAME})

target_compile_definitions(${PROJECT_NAME} PRIVATE "NOMINMAX")

# C++/WinRT 投影由 windows/gen_winrt_projection.ps1 生成到
# windows/winrt_projection/（构建产物，不入库）。
set(WINRT_PROJ_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../winrt_projection")
if(NOT EXISTS "${WINRT_PROJ_DIR}/winrt/impl/Microsoft.UI.Composition.SystemBackdrops.0.h")
  message(FATAL_ERROR
    "C++/WinRT projection missing. Run windows/gen_winrt_projection.ps1 first "
    "(it needs cppwinrt.exe from the Windows SDK and the WindowsAppSDK NuGet "
    "package). Looked in: ${WINRT_PROJ_DIR}")
endif()

# ICompositorDesktopInterop / IDesktopWindowTarget 只存在于 Windows SDK 自带的
# winrt/windows.ui.composition.desktop.h 里（WindowsAppSDK 的投影不含它），
# 所以 SDK 的 cppwinrt 头目录也要加进来。
if(NOT DEFINED WINSDK_CPPWINRT_BASE)
  message(FATAL_ERROR "WINSDK_CPPWINRT_BASE must be defined by the parent CMakeLists")
endif()
if(NOT DEFINED WINSDK_WINRT_INTEROP)
  message(FATAL_ERROR "WINSDK_WINRT_INTEROP must be defined by the parent CMakeLists")
endif()

target_include_directories(${PROJECT_NAME} PRIVATE
  "${WINRT_PROJ_DIR}"
  "${WINRT_PROJ_DIR}/winrt"
  "${WINSDK_CPPWINRT_BASE}"
  "${WINSDK_WINRT_INTEROP}"
)

# Windows App SDK: headers + import lib + runtime DLL.
# The NuGet package version is pinned by windows/CMakeLists.txt.
if(NOT DEFINED WASDK_ROOT)
  message(FATAL_ERROR "WASDK_ROOT must be defined by the parent CMakeLists")
endif()

target_include_directories(${PROJECT_NAME} PRIVATE
  "${WASDK_ROOT}/include"
  "${WASDK_ROOT}/include/winrt"
)

# Full path, not target_link_directories: this is a STATIC library, and link
# directories are not transitive -- the runner that links it would otherwise
# fail with LNK1104 "cannot open Microsoft.WindowsAppRuntime.Bootstrap.lib".
set(WASDK_BOOTSTRAP_LIB "${WASDK_ROOT}/lib/win10-x64/Microsoft.WindowsAppRuntime.Bootstrap.lib")
if(NOT EXISTS "${WASDK_BOOTSTRAP_LIB}")
  message(FATAL_ERROR "Windows App Runtime bootstrap lib not found at ${WASDK_BOOTSTRAP_LIB}")
endif()

target_link_libraries(${PROJECT_NAME} PUBLIC
  flutter
  flutter_wrapper_plugin
  # MddBootstrapInitialize2 (Windows App Runtime bootstrap)
  "${WASDK_BOOTSTRAP_LIB}"
  # C++/WinRT 基础库
  windowsapp.lib
  # DwmSetWindowAttribute / DwmExtendFrameIntoClientArea
  dwmapi.lib
)

target_include_directories(${PROJECT_NAME} PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
