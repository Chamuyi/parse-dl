; 解析下载器 WinUI 版 安装器 NSIS 脚本（2026-10-31 新建）
;
; 与 Flutter 版 installer/解析下载器.nsi 的区别：
;   1. 产物是 WinUI3 的 解析下载器.exe（Flutter 版是 ParseDownloader.exe）；
;   2. 源目录 build/winui_publish_sc（dotnet publish，自包含 WinAppSDK）；
;   3. **注册表键名独立**（Uninstall\解析下载器 (WinUI)）—— 与 Flutter 版并存时
;      两个卸载项都在，不会互相顶掉；
;   4. 安装时若发现旧版 Flutter 的台账，自动复制一份过来（只复制，不动源）。

Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "x64.nsh"

!define APP_NAME      "解析下载器"
!define APP_DISPLAY   "解析下载器"
!define APP_KEY       "解析下载器 (WinUI)"
!define APP_PUBLISHER "茶沐依"
!ifndef VERSION
  !define VERSION     "1.6"
!endif
!define APP_VERSION   "${VERSION}"
!define APP_VERSION_4 "${VERSION}.0.0"
!define APP_EXE       "解析下载器.exe"
!define INSTALL_DIR_DEFAULT "D:\解析下载器"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_KEY}"

!define MUI_ABORTWARNING
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_BITMAP "${__FILE__}\..\header.bmp"
!define MUI_WELCOMEFINISHPAGE_BITMAP "${__FILE__}\..\sidebar.bmp"
!define MUI_ICON   "${__FILE__}\..\app_icon.ico"
!define MUI_UNICON "${__FILE__}\..\app_icon.ico"

VIProductVersion  "${APP_VERSION_4}"
VIAddVersionKey "ProductName"     "${APP_DISPLAY}"
VIAddVersionKey "CompanyName"     "${APP_PUBLISHER}"
VIAddVersionKey "FileDescription" "${APP_DISPLAY} 安装程序"
VIAddVersionKey "LegalCopyright"  "Copyright (C) 2026 ${APP_PUBLISHER} - GPL-3.0"
VIAddVersionKey "FileVersion"     "${APP_VERSION_4}"
VIAddVersionKey "ProductVersion"  "${APP_VERSION_4}"

Name "${APP_DISPLAY} ${APP_VERSION}"
BrandingText "${APP_DISPLAY} ${APP_VERSION}"
OutFile "解析下载器_${APP_VERSION}_x64-setup.exe"
InstallDir "${INSTALL_DIR_DEFAULT}"
InstallDirRegKey HKCU "Software\${APP_KEY}" "InstallDir"
ShowInstDetails nevershow
ShowUninstDetails nevershow

!macro KillRunningApps
  Push $0
  Push $1
  nsExec::ExecToLog 'taskkill /F /T /IM "${APP_EXE}"'
  nsExec::ExecToLog 'taskkill /F /T /IM "aria2c.exe"'
  Pop $1
  Pop $0
!macroend

!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "$(STR_FINISH_RUN)"
!define MUI_FINISHPAGE_SHOWREADME ""
!define MUI_FINISHPAGE_SHOWREADME_TEXT "$(STR_CREATE_SHORTCUT)"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION CreateDesktopShortcutFromFinish
!define MUI_FINISHPAGE_NOREBOOTSUPPORT

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "$(LICENSE_FILE)"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_WELCOME
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

LicenseLangString LICENSE_FILE ${LANG_ENGLISH}   "${__FILE__}\..\LICENSE.en.txt"
LicenseLangString LICENSE_FILE ${LANG_SIMPCHINESE} "${__FILE__}\..\LICENSE.txt"

LangString STR_FINISH_RUN      ${LANG_ENGLISH}     "Launch the app now"
LangString STR_FINISH_RUN      ${LANG_SIMPCHINESE} "立即启动 ${APP_DISPLAY}"
LangString STR_CREATE_SHORTCUT ${LANG_ENGLISH}     "Create a desktop shortcut"
LangString STR_CREATE_SHORTCUT ${LANG_SIMPCHINESE} "创建桌面快捷方式"
LangString STR_KEEP_DATA       ${LANG_ENGLISH}     "User data has been kept in:$\r$\n$INSTDIR\userdata"
LangString STR_KEEP_DATA       ${LANG_SIMPCHINESE} "设置、下载台账与登录态已保留在：$\r$\n$INSTDIR\userdata$\r$\n$\r$\n如需彻底清除，请手动删除该目录。"
LangString STR_NO_DIR          ${LANG_ENGLISH}     "The installation folder is missing. The uninstaller will not remove anything."
LangString STR_NO_DIR          ${LANG_SIMPCHINESE} "安装目录不存在或已被修改：$\r$\n$\r$\n$INSTDIR$\r$\n$\r$\n为避免误删，卸载程序不会删除任何文件。请手动清理。"
LangString STR_UNINST_DONE     ${LANG_ENGLISH}     "${APP_DISPLAY} has been removed from your computer."
LangString STR_UNINST_DONE     ${LANG_SIMPCHINESE} "${APP_DISPLAY} 已从您的电脑移除。"
LangString STR_NEEDS_X64       ${LANG_ENGLISH}     "${APP_DISPLAY} requires 64-bit Windows."
LangString STR_NEEDS_X64       ${LANG_SIMPCHINESE} "${APP_DISPLAY} 仅支持 64 位 Windows。"
LangString STR_FOUND_OLD       ${LANG_ENGLISH}     "A previous install was detected. Its download ledger will be copied into the new install (the old folder is untouched)."
LangString STR_FOUND_OLD       ${LANG_SIMPCHINESE} "检测到旧版安装目录。安装完成后会把它的下载台账复制到新目录（旧目录原样保留，不做改动）。"

Function CreateDesktopShortcutFromFinish
  CreateShortcut "$DESKTOP\${APP_DISPLAY}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
FunctionEnd

Section "-${APP_DISPLAY} 必装项" SEC_REQUIRED
  SectionIn RO
  !insertmacro KillRunningApps
  Sleep 800
  SetOutPath "$INSTDIR"
  File /r "${__FILE__}\..\..\build\winui_staging\*.*"

  WriteUninstaller "$INSTDIR\uninst.exe"

  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName"     "${APP_DISPLAY}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion"  "${APP_VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher"       "${APP_PUBLISHER}"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" "$INSTDIR\uninst.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\${APP_EXE},0"
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  WriteRegStr HKCU "Software\${APP_KEY}" "InstallDir" "$INSTDIR"

  CreateDirectory "$SMPROGRAMS\${APP_DISPLAY}"
  CreateShortcut "$SMPROGRAMS\${APP_DISPLAY}\${APP_DISPLAY}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
  CreateShortcut "$SMPROGRAMS\${APP_DISPLAY}\卸载 ${APP_DISPLAY}.lnk" "$INSTDIR\uninst.exe" "" "$INSTDIR\uninst.exe" 0

  ; ── 旧版台账导入（只复制，不改源）──────────────────────────
  ; 旧 Flutter 版台账格式 {"version":3,"items":{id:{}}}，WinUI 版解码兼容。
  IfFileExists "$INSTDIR\userdata\douyin_downloaded.json" skip_import 0
  IfFileExists "D:\app\${APP_DISPLAY}\userdata\douyin_downloaded.json" 0 skip_import
    CreateDirectory "$INSTDIR\userdata"
    CopyFiles /SILENT "D:\app\${APP_DISPLAY}\userdata\douyin_downloaded.json" "$INSTDIR\userdata\"
    DetailPrint "已导入旧版抖音台账"
  skip_import:
SectionEnd

Function un.DeleteAllFiles
  !include "${__FILE__}\..\..\build\_uninst_files_winui.nsh"
FunctionEnd

Section "Uninstall"
  Push $0
  nsExec::ExecToLog 'taskkill /F /T /IM "${APP_EXE}"'
  nsExec::ExecToLog 'taskkill /F /T /IM "aria2c.exe"'
  Pop $0
  Sleep 500

  IfFileExists "$INSTDIR\uninst.exe" 0 not_our_install
    Call un.DeleteAllFiles
    Delete "$INSTDIR\${APP_EXE}"
    Delete "$INSTDIR\uninst.exe"
    RMDir "$INSTDIR\Assets"
    RMDir "$INSTDIR\Microsoft.UI.Xaml"
    ; userdata 刻意保留
    ${If} ${FileExists} "$INSTDIR\userdata\*.*"
      DetailPrint "用户数据已保留：$INSTDIR\userdata"
      MessageBox MB_ICONINFORMATION|MB_OK "$(STR_KEEP_DATA)" /SD IDOK
    ${EndIf}
    RMDir "$INSTDIR"
    Goto done_uninst
  not_our_install:
    MessageBox MB_ICONSTOP "$(STR_NO_DIR)" IDOK
  done_uninst:

  Delete "$DESKTOP\${APP_DISPLAY}.lnk"
  RMDir /r "$SMPROGRAMS\${APP_DISPLAY}"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\${APP_KEY}"
  MessageBox MB_ICONINFORMATION "$(STR_UNINST_DONE)" IDOK
SectionEnd

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "$(STR_NEEDS_X64)" IDOK
    Abort
  ${EndIf}
FunctionEnd
