/// 「所有文件访问」权限处理（Android 11+ MANAGE_EXTERNAL_STORAGE）。
///
/// 检测是否已授予、打开系统设置页跳转、并把结果同步到
/// [fileToolsAllowExternal]（configureFileTools 的 allowExternal 开关）。
library;

import 'package:permission_handler/permission_handler.dart';

import '../tools/file_tools.dart';

/// 是否已授予「所有文件访问」。
Future<bool> isExternalStorageGranted() async {
  final status = await Permission.manageExternalStorage.status;
  return status.isGranted;
}

/// 打开系统「所有文件访问」设置页。
Future<void> openManageExternalStorageSettings() async {
  await openAppSettings();
}

/// 根据权限状态刷新 file_tools 的外部访问开关。
/// 应在 App 启动（_initCwd 之后）和设置页授予后调用。
Future<void> syncExternalAccessPermission() async {
  final granted = await isExternalStorageGranted();
  // 保持 cwd（documents 目录）不变，仅切换外部访问开关。
  configureFileTools(
    cwd: _currentCwd,
    allowExternal: granted,
  );
}

// 记住当前 cwd（避免重复调用时丢配置）。
String? _currentCwd;
void rememberFileToolsCwd(String? cwd) {
  _currentCwd = cwd;
}
