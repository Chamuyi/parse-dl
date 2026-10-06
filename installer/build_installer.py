"""
构建 解析下载器 的 NSIS 安装包。

流程：
  1. 如果 build/windows/x64/runner/Release 不存在，自动跑
     flutter build windows --release --no-tree-shake-icons
     （图标树摇坑：动态/间接使用的图标会被静态分析器剪掉，导致所有图标空白）
  2. 把构建产物（ParseDownloader.exe + 各种 dll + data/）整理到 build/staging
  3. 调用 makensis 编译 installer/解析下载器.nsi
  4. 产出 build/dist/解析下载器_<ver>_x64-setup.exe
     （归档目录用环境变量 INSTALLER_OUT_DIR 覆盖）

用法：
  python installer/build_installer.py

依赖外部工具的位置用环境变量指定，不设则按默认查找：
  FLUTTER_BAT=...      flutter.bat 全路径（默认取 PATH 上的 flutter.bat）
  NSIS_DIR=...         NSIS 安装目录（默认搜 Program Files 常见位置）
  INSTALLER_OUT_DIR=... 安装包归档目录（默认 build/dist）
"""
import os
import shutil
import subprocess
import sys
import time

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(PROJECT, "build", "windows", "x64", "runner", "Release")
STAGING = os.path.join(PROJECT, "build", "staging")
NSI = os.path.join(PROJECT, "installer", "解析下载器.nsi")
LICENSE = os.path.join(PROJECT, "installer", "LICENSE.txt")
# flutter.bat 的位置：环境变量 FLUTTER_BAT 优先，否则用 PATH 上的 flutter.bat
FLUTTER = os.environ.get("FLUTTER_BAT") or shutil.which("flutter.bat") or "flutter.bat"

# 运行时数据目录：只要有人在 build 产物里直接跑过一次 exe，这里就会长出
# WebView2 的抖音登录态缓存（实测 132 MB）、settings.json、aria2c.exe、
# aria2.session 与下载任务表 —— 台账 douyin_downloaded.json 也落在同一目录。
# 它属于「这台机器的用户数据」，绝不能进安装包：轻则包从 16 MB 涨到 98 MB，
# 重则把登录 cookie 送到别人机器上，或让对方一装上就「跳过」他没下过的作品。
EXCLUDE_DIRS = {"userdata"}

# NSIS 安装路径：环境变量 NSIS_DIR 优先，否则按常见位置搜
NSIS_DIR_CANDIDATES = [
    r"C:/Program Files (x86)/NSIS",
    r"C:/Program Files/NSIS",
    r"D:/Program Files (x86)/NSIS",
]
NSIS_DIR = os.environ.get("NSIS_DIR") or next(
    (d for d in NSIS_DIR_CANDIDATES if os.path.exists(d)), None
)

# 安装包输出的归档目录：环境变量 INSTALLER_OUT_DIR 优先，默认仓库内的 build/dist
OUT_DIR = os.environ.get("INSTALLER_OUT_DIR") or os.path.join(PROJECT, "build", "dist")

# 版本号规则：公开基线起从 1.0 重新开始，每迭代一次 +0.1。
# 这里是**唯一改动点** —— .nsi 通过 makensis 的 /DVERSION 读取，不再各自硬编码。
VERSION = "1.3"
OUT_NAME = f"解析下载器_{VERSION}_x64-setup.exe"
OUT = os.path.join(OUT_DIR, OUT_NAME)


def find_makensis() -> str:
    if NSIS_DIR is None:
        print("ERROR: 找不到 NSIS 安装目录")
        print("      尝试安装：winget install NSIS.NSIS")
        sys.exit(1)
    candidate = os.path.join(NSIS_DIR, "makensis.exe")
    if not os.path.exists(candidate):
        print(f"ERROR: makensis.exe 不存在：{candidate}")
        sys.exit(1)
    return candidate


def ensure_utf8_bom(path: str) -> None:
    """确保 .nsi 带 UTF-8 BOM。

    NSIS 3 只接受 ANSI 或**带 BOM 的 UTF-8**：脚本里只要出现一个非 ASCII 字符
    （本项目的注释和产品名全是中文），无 BOM 的 UTF-8 就会直接
    `Error in script ... Bad text encoding` 中止。
    编辑器/自动改写工具经常顺手把 BOM 抹掉，所以在打包前兜一道。
    """
    with open(path, "rb") as f:
        data = f.read()
    if data.startswith(b"\xef\xbb\xbf"):
        return
    with open(path, "wb") as f:
        f.write(b"\xef\xbb\xbf" + data)
    print(f"[0/4] 给 {os.path.basename(path)} 补上 UTF-8 BOM（NSIS 要求，原本缺失）")


def rmtree_retry(path: str, attempts: int = 5) -> None:
    """删 staging 目录，失败重试。

    Windows 上杀软 / 搜索索引器会瞬时持有刚写出的 exe（实测踩到
    `PermissionError: [WinError 32] ... staging\\...\\aria2c.exe`），
    而这类占用通常一秒内就释放，重试即可，没必要让人重新打包。
    """
    for i in range(1, attempts + 1):
        try:
            shutil.rmtree(path)
            return
        except PermissionError:
            if i == attempts:
                raise
            print(f"      删除 {path} 被占用，{i}/{attempts - 1} 次重试中…")
            time.sleep(1.5)


def ensure_flutter_build():
    """如果 Release 产物不存在，自动跑 flutter build windows --release --no-tree-shake-icons

    重要：直接 subprocess 跑 flutter.bat 会报「找不到 pwsh」。
    flutter.bat 内部是 PowerShell 脚本，必须经 cmd/PowerShell 启动。
    """
    if os.path.exists(BUILD) and os.path.exists(os.path.join(BUILD, "ParseDownloader.exe")):
        return
    print("构建产物不存在，开始 flutter build windows --release --no-tree-shake-icons")

    # 方法：cmd /c flutter.bat（cmd 会把 .bat 当批处理，自动用 PowerShell 解释器）
    cmd_path = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "cmd.exe")
    if not os.path.exists(cmd_path):
        print(f"ERROR: 找不到 cmd.exe：{cmd_path}")
        sys.exit(1)

    flutter_bat = FLUTTER
    if not os.path.exists(flutter_bat):
        print(f"ERROR: 找不到 flutter.bat：{flutter_bat}")
        print("      用环境变量指定：set FLUTTER_BAT=<路径>\\flutter.bat")
        sys.exit(1)

    # cmd /c 会把 bat 通过 PowerShell 解释器跑，避免 pwsh 找不到的问题
    result = subprocess.run(
        [cmd_path, "/c", flutter_bat, "build", "windows", "--release", "--no-tree-shake-icons"],
        capture_output=True,
    )
    out = (result.stdout or b"").decode("utf-8", errors="replace")
    err = (result.stderr or b"").decode("utf-8", errors="replace")
    print("STDOUT (last 2000 chars):")
    print(out[-2000:])
    print()
    print("STDERR (last 1000 chars):")
    print(err[-1000:])
    if result.returncode != 0 or not os.path.exists(os.path.join(BUILD, "ParseDownloader.exe")):
        print(f"ERROR: flutter build 失败 (returncode={result.returncode})")
        sys.exit(1)


def main():
    ensure_utf8_bom(NSI)
    ensure_flutter_build()
    makensis = find_makensis()
    print(f"NSIS: {makensis}")

    # 1. 清理 staging
    if os.path.exists(STAGING):
        rmtree_retry(STAGING)
    os.makedirs(STAGING, exist_ok=True)
    print(f"[1/4] staging -> {STAGING}")

    # 2. 拷贝构建产物（跳过运行时数据目录，见 EXCLUDE_DIRS）
    count = 0
    for root, dirs, names in os.walk(BUILD):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for n in names:
            s = os.path.join(root, n)
            rel = os.path.relpath(s, BUILD)
            d = os.path.join(STAGING, rel)
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.copy2(s, d)
            count += 1
    print(f"[2/4] 拷贝了 {count} 个文件")

    # 2.5 生成 _uninst_files.nsh（NSIS include 文件，逐行 Delete 指令）
    #     NSIS 的 FileRead 不是按行读（一次读整个剩余），所以循环遍历会只跑一次。
    #     最稳的方案：Python 预生成一段 NSIS 脚本，每行一个 Delete，NSIS 直接 !include。
    #
    #     **落在 build/ 而不是 build/staging/**：staging 整目录会被 `File /r` 装进
    #     用户目录。清单只在编译期被 !include 用掉，装过去没有任何用处，只会让
    #     安装目录里多出两个谁也用不着的内部文件。
    uninst_nsh = os.path.join(PROJECT, "build", "_uninst_files.nsh")
    uninst_txt = os.path.join(PROJECT, "build", "_uninst_files.txt")
    file_list = []
    for root, _, names in os.walk(STAGING):
        for n in names:
            rel = os.path.relpath(os.path.join(root, n), STAGING)
            file_list.append(rel.replace("\\", "/"))
    file_list.sort()

    # NSIS include 文件（用正斜杠）
    with open(uninst_nsh, "w", encoding="utf-8") as f:
        f.write("; Auto-generated by build_installer.py — 卸载时按此清单逐个 Delete\n")
        f.write("; 不要手编这个文件\n\n")
        for rel in file_list:
            # NSIS 里 $INSTDIR 已经是 $INSTDIR，不要把 _uninst_files.nsh 自身也删
            f.write(f'  Delete "$INSTDIR\\{rel}"\n')

    # 给人看的纯文本清单（GBK，给 NSIS License 控件用 ANSI 解码）
    with open(uninst_txt, "w", encoding="gbk", errors="replace") as f:
        f.write("; 解析下载器 卸载文件清单\n")
        f.write("; 卸载时按此清单逐个删除，每行一个相对路径\n")
        for rel in file_list:
            f.write(rel + "\n")
    print(f"[2.5/4] 生成 _uninst_files.nsh + .txt ({len(file_list)} 项)")

    # 3. 写 LICENSE.txt（NSIS MUI_PAGE_LICENSE 需要）
    #    NSIS 3 的 License 控件按 ANSI/GBK 读取 .txt（与系统代码页一致），
    #    用 UTF-8 写会显示乱码。直接以 GBK 写入。
    if not os.path.exists(LICENSE):
        license_text = (
            "解析下载器 基于开源项目 X-Spider "
            "(https://github.com/MiningCattiva/x-spider)\n"
            "二次开发，遵循 GPL-3.0 协议。\n\n"
            "Copyright (C) 2026 茶沐依\n\n"
            "本软件为自由软件；您可以根据自由软件基金会发布的 GPL-3.0 协议的条款\n"
            "重新分发和/或修改它。\n\n"
            "分发此软件旨在希望它有用，但没有任何担保；甚至没有对适销性或\n"
            "特定用途适用性的暗示担保。详见 GPL-3.0 协议。\n"
        )
        # NSIS 用系统 ANSI/GBK 解码 .txt：必须用 GBK 编码
        with open(LICENSE, "w", encoding="gbk", errors="replace") as f:
            f.write(license_text)
        print(f"[3/4] 写 LICENSE.txt (GBK)")

    # 4. 调用 makensis（输出是 GBK）
    print(f"[4/4] makensis {NSI}")
    result = subprocess.run(
        [makensis, f"/DVERSION={VERSION}", NSI],
        capture_output=True,
    )
    out = (result.stdout or b"").decode("gbk", errors="replace")
    err = (result.stderr or b"").decode("gbk", errors="replace")
    print(out)
    if result.returncode != 0:
        print(f"makensis ERROR: {err}")
        sys.exit(1)

    # makensis 默认在脚本目录输出 解析下载器_<ver>_x64-setup.exe
    produced = os.path.join(PROJECT, "installer", OUT_NAME)
    if not os.path.exists(produced):
        print(f"ERROR: 期望产物不存在 {produced}")
        sys.exit(1)

    # 复制到 OUT_DIR（如果还没在）
    os.makedirs(OUT_DIR, exist_ok=True)
    if os.path.normpath(produced) != os.path.normpath(OUT):
        if os.path.exists(OUT):
            os.remove(OUT)
        shutil.copy2(produced, OUT)

    print()
    print(f"DONE: {OUT}")
    print(f"      {os.path.getsize(OUT)} bytes")


if __name__ == "__main__":
    main()