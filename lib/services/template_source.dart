import '../models/douyin_config.dart';
import '../models/settings.dart';

/// 一次下载要用的两个模板（文件夹 / 文件名）。
typedef TemplatePair = ({String dirTemplate, String fileNameTemplate});

/// 按**下载来源**挑出这次要用的模板。
///
/// - X 下载（`douyin == null`）：用全局「下载设置」里的两个模板。
/// - 抖音解析下载（传了 `douyin`）：用它自己那一份 —— 于是两个模块的
///   命名规则彻底分开，改一边不会影响另一边。
///
/// **「启用保存文件夹」的语义**（用户明确过的）：
///   开 → 按 `dirTemplate` 建子目录再存；
///   关 → **忽略文件夹模板**，文件全部平铺在保存根目录里。
/// 所以关闭时这里直接返回空文件夹模板 —— 下游 `dirTemplate.trim().isEmpty`
/// 会走「不建子目录」的分支，不需要在别处再判断一次。
///
/// 抽成纯函数是为了能单测：真正的入队路径（`Aria2Coordinator.enqueueMedia`）
/// 依赖 aria2 进程与平台通道，测起来代价太大。
TemplatePair pickTemplates({
  required DownloadSettings download,
  DouyinConfig? douyin,
}) {
  if (douyin == null) {
    return (
      dirTemplate: download.dirTemplate,
      fileNameTemplate: download.fileNameTemplate,
    );
  }
  return (
    dirTemplate: douyin.enableSaveFolder ? douyin.dirTemplate : '',
    fileNameTemplate: douyin.fileNameTemplate,
  );
}

/// 这次下载落到哪个**保存根目录**（文件夹模板是往它下面拼子目录）。
///
/// 优先级：
///  1. 抖音自己填的 [DouyinConfig.saveDirBase]（才有这个字段）；
///  2. 留空 → 沿用 X 下载那条根目录（先看本次会话里选中的 [sessionSaveDir]，
///     再看持久化的 [xSaveDirBase]）。**这一层是刻意保留的兼容**：这个字段引入之前
///     抖音根本没有保存路径，一直在用 X 的设置，若"留空=用默认目录"，
///     老用户更新完会发现下载位置莫名其妙变了。
///  3. 都没有 → [fallback]（系统下载目录下的「解析下载器」）。
///
/// 抽成纯函数同 [pickTemplates] 的理由：真正的入队路径依赖 aria2 进程，测不动。
String resolveSaveBase({
  DouyinConfig? douyin,
  required String sessionSaveDir,
  required String xSaveDirBase,
  required String fallback,
}) {
  final own = douyin?.saveDirBase.trim() ?? '';
  if (own.isNotEmpty) return own;
  if (sessionSaveDir.isNotEmpty) return sessionSaveDir;
  final x = xSaveDirBase.trim();
  if (x.isNotEmpty) return x;
  return fallback;
}
