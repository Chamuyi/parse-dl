; 解析下载器 安装器 NSIS 脚本
;
; 设计目标：安装与卸载都不留意外 —— 不覆盖运行时文件、不误删父目录。
;   1. 欢迎页（NSIS MUI2 默认中文）
;   2. 许可证页（GPL-3.0，GBK 编码）
;   3. 安装目录选择（默认 %LOCALAPPDATA%\解析下载器）
;   4. 安装页（杀进程 + 解压 + 进度条）
;   5. 完成页（启动 + 桌面快捷方式）
;
; 关键约束：
;   - 文件必须以 UTF-8 BOM 开头 + UTF-8 编码
;   - MUI 默认中文文案（来自 NSIS 自带的 SimpChinese.nsh）已经够好，
;     **不**自定义 MUI_*_TEXT（避免 LangString 内的换行/转义问题）
;   - 必须杀 aria2c.exe（避免覆盖安装时 "Error opening file for writing"）

Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "x64.nsh"

; ── 元数据 ───────────────────────────────────────────────
!define APP_NAME      "解析下载器"
!define APP_DISPLAY    "解析下载器"
!define APP_PUBLISHER  "茶沐依"
; 版本号由 build_installer.py 通过 makensis /DVERSION= 传入（唯一来源）；
; 直接双击编译 .nsi 时用下面的兜底值。规则：从 1.0 起每迭代 +0.1。
!ifndef VERSION
  !define VERSION       "1.3"
!endif
!define APP_VERSION    "${VERSION}"
; NSIS 的 VIProductVersion 要求 4 段数字（X.X.X.X），故补零
!define APP_VERSION_4  "${VERSION}.0.0"
!define APP_EXE        "ParseDownloader.exe"

; 兜底安装目录：只在机器上连 D:/E:/F: 都没有时才会用到。
; .onInit 里会优先挑非系统盘 —— 因为 数据（设置/日志/台账/抖音登录态）
; 就存在安装目录下的 userdata\，装到 C 盘 = 数据也在 C 盘。
!define INSTALL_DIR_DEFAULT "$LOCALAPPDATA\解析下载器"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"

; ── 现代 UI 配置 ───────────────────────────────────────────
!define MUI_ABORTWARNING
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_BITMAP "${__FILE__}\..\header.bmp"
!define MUI_WELCOMEFINISHPAGE_BITMAP "${__FILE__}\..\sidebar.bmp"
; 刻意**不设** MUI_LANGDLL_LANGUAGES_DEFAULT：设了就会强制那一种语言。
; 不设时 NSIS 按系统 locale 预选（中文系统→简中，其余→英语），
; 语言数大于 1 时仍会弹一次选择框，用户可以手动改。
; 安装/卸载向导图标，以及**安装包 exe 自身**的图标（NSIS 会拿 MUI_ICON
; 作为输出文件的图标资源）。与 app 内 logo 同源，见 build_installer.py。
!define MUI_ICON      "${__FILE__}\..\app_icon.ico"
!define MUI_UNICON    "${__FILE__}\..\app_icon.ico"

; ── 注入版本信息 ─────────────────────────────────────────
VIProductVersion  "${APP_VERSION_4}"
VIAddVersionKey   "ProductName"      "${APP_DISPLAY}"
VIAddVersionKey   "CompanyName"      "${APP_PUBLISHER}"
VIAddVersionKey   "FileDescription"  "${APP_DISPLAY} 安装程序"
; GPL 的署名义务由随附的 LICENSE.txt / LICENSE.en.txt 履行，
; 不必塞进 exe 属性；这里只写自己的版权与许可证。
VIAddVersionKey   "LegalCopyright"   "Copyright (C) 2026 ${APP_PUBLISHER} - GPL-3.0"
VIAddVersionKey   "FileVersion"      "${APP_VERSION_4}"
VIAddVersionKey   "ProductVersion"   "${APP_VERSION_4}"

Name "${APP_DISPLAY} ${APP_VERSION}"
BrandingText "${APP_DISPLAY} ${APP_VERSION}"
OutFile "解析下载器_${APP_VERSION}_x64-setup.exe"
InstallDir "${INSTALL_DIR_DEFAULT}"
; InstallDirRegKey 必须放在 !insertmacro MUI_PAGE_* 之前才生效
; 当第二次运行时，NSIS 会自动读这个注册表项作为 InstallDir
InstallDirRegKey HKCU "Software\${APP_DISPLAY}" "InstallDir"
; 安装/卸载过程**只给进度条**，不显示任何逐行文件明细。
;
; 三个档位的区别：`show` 默认展开；`hide` 默认收起但**仍可以点「显示详情」
; 展开看到解压了哪些文件**；`nevershow` 才是连展开入口都不给。
; 出问题时临时改回 show 排查。
ShowInstDetails nevershow
ShowUninstDetails nevershow

; ── 安装前杀进程 ──────────────────────────────────────────
; 避免覆盖运行时文件
!macro KillRunningApps
  Push $0
  Push $1
  nsExec::ExecToLog 'taskkill /F /T /IM "${APP_EXE}"'
  nsExec::ExecToLog 'taskkill /F /T /IM "X-Spider.exe"'
  nsExec::ExecToLog 'taskkill /F /T /IM "aria2c.exe"'
  Pop $1
  Pop $0
!macroend

; ── 完成页自定义（**必须在 MUI_PAGE_FINISH 之前 define**）──────
; MUI 的 finish page 宏在 `!insertmacro` 那一刻就会读取这些 define；
; 若放在 MUI_PAGE_FINISH 之后再 define，选项不会出现在界面上，
; 且 SHOWREADME_FUNCTION 会被 makensis 判定为「未引用」而丢弃
; （就是之前那条 warning 6010 的真正原因）。
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"   ; 必须是完整路径，否则 finish 页找不到文件
!define MUI_FINISHPAGE_RUN_TEXT "$(STR_FINISH_RUN)"
!define MUI_FINISHPAGE_SHOWREADME ""               ; 空值 = 不启用「显示自述文件」默认逻辑
!define MUI_FINISHPAGE_SHOWREADME_TEXT "$(STR_CREATE_SHORTCUT)"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION CreateDesktopShortcutFromFinish
!define MUI_FINISHPAGE_NOREBOOTSUPPORT             ; 不显示「重启计算机」（本应用无需重启）
; 刻意**不用** MUI_FINISHPAGE_NOAUTOCLOSE：它的作用是让安装页停在原地等用户
; 点「下一步」，为的是看那份逐行详情。详情已经 nevershow 了，停在这里
; 只会让人以为卡住，不如自动进完成页。

; ── 页面顺序（文案随语言切换，见上面的 STR_* LangString）────
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "$(LICENSE_FILE)"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

; ── 卸载页 ──────────────────────────────────────────────
!insertmacro MUI_UNPAGE_WELCOME
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

; ── 国际化：必须在所有 MUI_PAGE / MUI_UNPAGE 宏之后插入 ────
;
; **第一个 MUI_LANGUAGE 是兜底语言**（系统 locale 认不出来时用），
; 按 NSIS 惯例放 English；中文系统上 LANGDLL 会自动预选 SimpChinese。
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

; ── 界面文案（中／英双语）──────────────────────────────────
;
; **必须放在 MUI_LANGUAGE 之后**：`${LANG_ENGLISH}` 这些常量正是由
; `!insertmacro MUI_LANGUAGE` 从 `Contrib\Language files\*.nsh` 引入的。
; 放在它前面会静默退化成语言 id 1033，中文文案被丢掉、英文被写两遍
; （makensis 报 warning 7025 + 6030，不会报 error）。
;
; 产品名 ${APP_DISPLAY} **不翻译**：它是快捷方式、开始菜单目录与注册表项的
; 稳定标识，翻了会让覆盖安装找不着旧安装。英文文案里改用 "the app" 指代。
LicenseLangString LICENSE_FILE ${LANG_ENGLISH}     "${__FILE__}\..\LICENSE.en.txt"
LicenseLangString LICENSE_FILE ${LANG_SIMPCHINESE} "${__FILE__}\..\LICENSE.txt"

LangString STR_FINISH_RUN      ${LANG_ENGLISH}     "Launch the app now"
LangString STR_FINISH_RUN      ${LANG_SIMPCHINESE} "立即启动 ${APP_DISPLAY}"
LangString STR_CREATE_SHORTCUT ${LANG_ENGLISH}     "Create a desktop shortcut"
LangString STR_CREATE_SHORTCUT ${LANG_SIMPCHINESE} "创建桌面快捷方式"
LangString STR_KEEP_DATA       ${LANG_ENGLISH}     "User data has been kept in:$\r$\n$INSTDIR\userdata$\r$\n$\r$\nTo remove it completely, delete that folder manually."
LangString STR_KEEP_DATA       ${LANG_SIMPCHINESE} "设置、下载台账与登录态已保留在：$\r$\n$INSTDIR\userdata$\r$\n$\r$\n如需彻底清除，请手动删除该目录。"
LangString STR_NO_DIR          ${LANG_ENGLISH}     "The installation folder is missing or has been changed:$\r$\n$\r$\n$INSTDIR$\r$\n$\r$\nTo avoid deleting the wrong files, the uninstaller will not remove anything. Please clean up manually."
LangString STR_NO_DIR          ${LANG_SIMPCHINESE} "安装目录不存在或已被修改：$\r$\n$\r$\n$INSTDIR$\r$\n$\r$\n为避免误删，卸载程序不会删除任何文件。请手动清理。"
LangString STR_UNINST_DONE     ${LANG_ENGLISH}     "${APP_DISPLAY} has been removed from your computer."
LangString STR_UNINST_DONE     ${LANG_SIMPCHINESE} "${APP_DISPLAY} 已从您的电脑移除。"
LangString STR_NEEDS_X64       ${LANG_ENGLISH}     "${APP_DISPLAY} requires 64-bit Windows."
LangString STR_NEEDS_X64       ${LANG_SIMPCHINESE} "${APP_DISPLAY} 仅支持 64 位 Windows。"

; 完成页触发：创建桌面快捷方式
Function CreateDesktopShortcutFromFinish
  CreateShortcut "$DESKTOP\${APP_DISPLAY}.lnk" \
                 "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
FunctionEnd

; ── 安装 Section ──────────────────────────────────────────
Section "-${APP_DISPLAY} 必装项" SEC_REQUIRED
  SectionIn RO

  ; 杀进程
  !insertmacro KillRunningApps
  Sleep 800

  SetOutPath "$INSTDIR"

  ; 拷贝所有构建产物（由 build_installer.py 准备好的 staging 目录）
  File /r "${__FILE__}\..\..\build\staging\*.*"

  ; 安全卸载：build_installer.py 预生成一份文件清单，卸载时按清单逐个删，
  ; 最后 RMDir（不带 /r）只删**空目录** —— 绝不会误删 $INSTDIR 的父目录或
  ; 用户放进去的其它文件。
  ;
  ; 清单落在 **staging 之外**（build\ 下），只在编译期被 !include 用掉。
  ; 以前它写在 staging 里，于是被上面那条 `File /r` 一起装进用户目录，
  ; 装完目录里就多出 `_uninst_files.nsh` / `_uninst_files.txt` 两个
  ; 谁也用不着的内部文件（2026-09-21 用户截图指出）。

  ; 写入卸载 exe
  WriteUninstaller "$INSTDIR\uninst.exe"

  ; 注册表：卸载项
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName"     "${APP_DISPLAY}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion"  "${APP_VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher"       "${APP_PUBLISHER}"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" "$INSTDIR\uninst.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\${APP_EXE},0"
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1

  ; 开始菜单快捷方式
  CreateDirectory "$SMPROGRAMS\${APP_DISPLAY}"
  CreateShortcut "$SMPROGRAMS\${APP_DISPLAY}\${APP_DISPLAY}.lnk" \
                 "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
  CreateShortcut "$SMPROGRAMS\${APP_DISPLAY}\卸载 ${APP_DISPLAY}.lnk" \
                 "$INSTDIR\uninst.exe" "" "$INSTDIR\uninst.exe" 0
SectionEnd

; ── 卸载 Section ─────────────────────────────────────────
; ── 卸载时按清单删除所有文件 ──
; !include 必须包在 Function 里（Delete 等指令需在 Section/Function 内）
Function un.DeleteAllFiles
  !include "${__FILE__}\..\..\build\_uninst_files.nsh"
FunctionEnd

Section "Uninstall"
  ; 杀进程
  Push $0
  nsExec::ExecToLog 'taskkill /F /T /IM "${APP_EXE}"'
  nsExec::ExecToLog 'taskkill /F /T /IM "aria2c.exe"'
  Pop $0
  Sleep 500

  ; ── 安全删除：按文件清单逐个删，绝不用 RMDir /r "$INSTDIR" ──
  ; 原因：如果用户把安装路径改成了父目录，RMDir /r 会**递归删除整个父目录**。
  ; 方案：build_installer.py 预生成 _uninst_files.nsh，每行一个 Delete "$INSTDIR\..."。
  ; 卸载时 !include 即可（零循环风险——之前用 FileRead 循环实际只跑一次就跳出）。

  ; 安全检查：确认 $INSTDIR 真的包含我们的卸载程序
  IfFileExists "$INSTDIR\uninst.exe" 0 not_our_install
    Call un.DeleteAllFiles

    ; 删掉清单文件本身 + 几个核心文件 + 已知子目录
    Delete "$INSTDIR\_uninst_files.nsh"
    Delete "$INSTDIR\_uninst_files.txt"
    Delete "$INSTDIR\${APP_EXE}"
    Delete "$INSTDIR\uninst.exe"
    ; 已知子目录（NSIS 的 RMDir 不带 /r 只删空目录，安全）
    RMDir "$INSTDIR\data\flutter_assets\shaders"
    RMDir "$INSTDIR\data\flutter_assets\packages\cupertino_icons"
    RMDir "$INSTDIR\data\flutter_assets\packages"
    RMDir "$INSTDIR\data\flutter_assets\fonts"
    RMDir "$INSTDIR\data\flutter_assets\assets"
    RMDir "$INSTDIR\data\flutter_assets"
    RMDir "$INSTDIR\data"

    ; ── 用户数据**刻意保留** ────────────────────────────────
    ; 卸载软件 != 想清空用户的东西；而且抖音登录态丢了要重新扫码登录。
    ; userdata\ 不在删除清单里，所以 RMDir（不带 /r）删不掉它 —— 这是故意的。
    ${If} ${FileExists} "$INSTDIR\userdata\*.*"
      DetailPrint "用户数据已保留：$INSTDIR\userdata"
      MessageBox MB_ICONINFORMATION|MB_OK \
        "$(STR_KEEP_DATA)" \
        /SD IDOK
    ${EndIf}

    ; 最后尝试删 $INSTDIR 自身（只有空时才成功；有 userdata 时会保留下来）
    RMDir "$INSTDIR"
    Goto done_uninst

  not_our_install:
    ; $INSTDIR 不像我们的安装目录，弹出警告，**完全不删**
    MessageBox MB_ICONSTOP "$(STR_NO_DIR)" IDOK
  done_uninst:

  ; 删除快捷方式
  Delete "$DESKTOP\${APP_DISPLAY}.lnk"
  RMDir /r "$SMPROGRAMS\${APP_DISPLAY}"

  ; 删除注册表
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\${APP_DISPLAY}"

  MessageBox MB_ICONINFORMATION "$(STR_UNINST_DONE)" IDOK
SectionEnd

; ── 初始化检查：禁止 32 位 ───────────────────────────────
Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "$(STR_NEEDS_X64)" IDOK
    Abort
  ${EndIf}

  ; 兜底：从注册表读上次安装路径
  ;   NSIS 的 InstallDirRegKey 在某些场景下不生效（特别是 MUI_PAGE_DIRECTORY 多次重定义时），
  ;   这里手动读更稳。兼容三种注册表项：
  ;   1. HKCU\Software\解析下载器\InstallDir                       （我们写的新键）
  ;   2. HKCU\...\Uninstall\解析下载器\InstallLocation             （卸载项里也写了路径）
  ;   3. HKCU\...\Uninstall\解析下载器\UninstallString              （从 uninst.exe 路径反推）
  Push $0
  Push $1

  ; 优先读新键（我们 Section 里写的）
  ReadRegStr $0 HKCU "Software\${APP_DISPLAY}" "InstallDir"
  ${If} $0 != ""
    StrCpy $INSTDIR $0
    Goto done_read_reg
  ${EndIf}

  ; 退回卸载项的 InstallLocation
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "InstallLocation"
  ${If} $0 != ""
    StrCpy $INSTDIR $0
    Goto done_read_reg
  ${EndIf}

  ; 最后退回 UninstallString 反推（路径形如 "$INSTDIR\uninst.exe"）
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "UninstallString"
  ${If} $0 != ""
    ; 去掉末尾 "\uninst.exe"（11 字符：\ + u n i n s t . e x e）
    StrCpy $0 "$0" -11
    StrCpy $INSTDIR $0
  ${EndIf}

  done_read_reg:
  Pop $1
  Pop $0

  ; ── 数据不落 C 盘 ────────────────────────────────────────
  ; 数据（设置 / 日志 / 下载台账 / 抖音登录态）存在
  ; `$INSTDIR\userdata`，所以「装到 C 盘」=「数据也在 C 盘」。
  ; 首次安装优先挑一个非系统盘；老用户原本装在 C 盘的也一并挪出来。
  ; 已经有自定义安装路径（例如 D:\Tools\解析下载器）的老用户不受影响。
  ${If} $INSTDIR == ""
  ${OrIf} $INSTDIR == "${INSTALL_DIR_DEFAULT}"
  ${OrIf} $INSTDIR == "$PROGRAMFILES64\${APP_DISPLAY}"
  ${OrIf} $INSTDIR == "$PROGRAMFILES\${APP_DISPLAY}"
    ${If} ${FileExists} "D:\*.*"
      StrCpy $INSTDIR "D:\${APP_DISPLAY}"
    ${ElseIf} ${FileExists} "E:\*.*"
      StrCpy $INSTDIR "E:\${APP_DISPLAY}"
    ${ElseIf} ${FileExists} "F:\*.*"
      StrCpy $INSTDIR "F:\${APP_DISPLAY}"
    ${EndIf}
  ${EndIf}
FunctionEnd