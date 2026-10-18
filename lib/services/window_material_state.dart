import 'package:flutter/foundation.dart';

/// 窗口材质是否**真的挂上了** —— DWM 画的 Mica / 亚克力能否透出来。
///
/// ### 为什么需要一个全局可监听的值
///
/// 材质由 DWM 画在**窗口后面**，Flutter 侧看不见它。而 Flutter 只要画了
/// 不透明像素，就会把 DWM 那层整个盖住 —— 四档材质在真机上因此是四张
/// 一模一样的图。所以窗口底必须透明。
///
/// 但透明有个前提：材质**真的在**。系统关掉「透明效果」、远程桌面、Win10
/// 等情况下 `DwmSetWindowAttribute` 会失败（`applyWindowMaterial` 返回
/// `ok: false`），此时窗口底若还是透明，桌面就直接从窗口里透出来，正文
/// 压在花花绿绿的壁纸上没法读。所以窗口底要按这个值二选一：
///
/// | 值 | 窗口底 |
/// |---|---|
/// | `true`  | `Colors.transparent`（DWM 材质原样透上来） |
/// | `false` | `WindowMaterial.fallbackTo()` 的**不透明**纯色兜底 |
///
/// 写入点有两处，都在 `lib/app.dart`：启动路径的 `build` 与设置页的
/// 材质回调，都读 `MaterialApplyResult.ok`。
///
/// ### 初值必须是 `true`
///
/// `applyWindowMaterial` 是异步的，首帧跑在它之前。初值给 `false` 的话，
/// 每次冷启动都会先闪一帧不透明的实色底、再切成透明 —— 那是一次肉眼可见
/// 的闪烁。给 `true` 则首帧就是透明：材质通常**确实**可用，猜错的代价只是
/// 材质不可用的机器上多闪一帧（那种机器上本来就没有材质可看）。
final ValueNotifier<bool> windowMaterialAvailable = ValueNotifier<bool>(true);
