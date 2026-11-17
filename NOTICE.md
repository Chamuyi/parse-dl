# 第三方与出处说明 · Third-Party Notices

解析下载器（Parse Downloader）· Copyright (C) 2026 Cha Muyi
本程序是自由软件，遵循 **GPL-3.0-or-later**（全文见 [LICENSE](LICENSE)）。

## 随包分发的组件

| 组件 | 许可证 | 说明 |
|---|---|---|
| [aria2 1.37.0](https://github.com/aria2/aria2) —— `assets/aria2c.exe` | GPL-2.0-or-later | 作为**独立子进程**拉起，通过本地 JSON-RPC 通信；本程序不链接其任何代码，只分发其可执行文件 |
| [FFmpeg](https://ffmpeg.org/) —— `assets/ffmpeg.exe` | **GPL-3.0-or-later**（该构建启用了 `--enable-gpl`） | 作为**独立子进程**调用，用于音视频合并、字幕与章节封装；本程序不链接其任何库 |
| [Windows App SDK](https://github.com/microsoft/WindowsAppSDK) / WinUI 3 | MIT | 界面框架，通过 NuGet 引用 |
| [.NET 10](https://github.com/dotnet/runtime) | MIT | 运行时与基础类库 |
| [WebView2](https://learn.microsoft.com/microsoft-edge/webview2/) | 随系统分发 | 页面渲染与登录态载体，不随本程序打包 |
| NSIS | zlib/libpng | 仅构建期使用，不随产物分发其源码 |

> **关于 ffmpeg**：随包的 `ffmpeg.exe` 构建启用了 GPL 组件，按 GPL 分发。
> 本程序以独立进程方式调用它，不与其链接。对应源码可从
> [ffmpeg 官方仓库](https://github.com/FFmpeg/FFmpeg) 按所用版本获取。

## 出处

- **X 下载模块**：基于 [X-Spider](https://github.com/MiningCattiva/x-spider)（GPL-3.0）二次开发，
  属其衍生作品，因此整体按 GPL-3.0 分发。源码注释中出现的「原版」即指该项目。
- **抖音模块**：接口形状与页面行为按平台自身对外可见的表现整理，由本项目自行实现；
  设置项与下载源的组织方式参考了此类工具的常见做法。各项默认值经本项目实测校准，
  平台改版时以本项目自己的实测结果为准。
- **B 站模块**：接口形状与页面行为同样按平台对外可见表现整理，由本项目自行实现；
  参考了同类开源工具（如 Bili23-Downloader、downkyi）的公开行为，**未复制其代码**。

## 凭据与隐私

| 内容 | 位置 |
|---|---|
| 各平台登录态（WebView2 用户数据） | `<软件所在目录>\userdata\webview`；仅当安装目录不可写时才回退到系统给的应用数据目录（`%APPDATA%\com.parsedl\解析下载器`），界面上会如实提示 |
| X 的 cookie | `<软件所在目录>\userdata\prefs.json`（与 `settings.json` 同目录） |

**凭据只保存在本机、不加密**，本程序不把它们发往任何第三方服务器，也不会被提交进版本库
（`.gitignore` 兜了 `userdata/`、`.env`、`*.session`）。能读到你本机目录的人就能读到它们 ——
共用机器请用系统账户隔离，或不用时退出登录。

## 架构说明

本程序在 2026-11 从 Flutter 版整体重构为 **WinUI 3（.NET 10）** 版。
仓库根目录下的 `lib/`、`pubspec.yaml`、`shaders/` 是旧 Flutter 实现的存档，
**不参与当前构建**，因此上表的 Flutter SDK 已不再是随包分发的组件。

本程序按"现状"提供，不含任何担保（GPL-3.0 第 15 条）。使用者需自行遵守 X、抖音、B 站各平台的服务条款。
