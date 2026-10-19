# 窗口材质插件：用 DWM 的 SYSTEMBACKDROP_TYPE 做 Mica / 亚克力四档。
#
# 曾经用 Windows App SDK 的 MicaController / DesktopAcrylicController（能区分
# 「细亚克力」），但那条路在 Flutter runner 窗口上必崩：合成材质挂上之后，
# 第一次窗口状态变化（移动 / 改 Z 序 / 最小化）就以 0xC000027B
# （STOWED_EXCEPTION，coremessaging.dll）结束进程。换线程、换队列、换 HWND、
# 加 WS_EX_NOREDIRECTIONBITMAP 全部实测无效，细节见
# system_backdrop_plugin.cpp 的类注释。
#
# 因此这里不再需要 C++/WinRT 投影与 Windows App SDK 的元数据/导入库，
# 只依赖系统自带的 dwmapi.lib。代价是「细亚克力」落回普通亚克力
# （DWM 的 SYSTEMBACKDROP_TYPE 只有一档亚克力）。

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

target_link_libraries(${PROJECT_NAME} PUBLIC
  flutter
  flutter_wrapper_plugin
  # DwmSetWindowAttribute / DwmExtendFrameIntoClientArea
  dwmapi.lib
)

target_include_directories(${PROJECT_NAME} PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
