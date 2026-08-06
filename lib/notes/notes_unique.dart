// 防重名命名：`name.md` 已存在时递增为 `name(1).md`（从 printnotes
// storage_system.resolveUniqueFileName 移植，纯函数无耦合）。
library;

import 'dart:io';
import 'package:path/path.dart' as p;

/// 文件/文件夹是否已存在。
Future<bool> nameExists(String name, {required String parentPath}) async {
  final fullPath = p.join(parentPath, name);
  final fileExists = await File('$fullPath.md').exists();
  final folderExists = await Directory(fullPath).exists();
  return fileExists || folderExists;
}

/// 若 [filePath] 已存在，返回递增唯一路径（`name(1).md`）。
Future<String> resolveUniqueFileName(String filePath) async {
  String baseName = p.basenameWithoutExtension(filePath);
  final parentDir = p.dirname(filePath);
  final fileExt = p.extension(filePath);

  final regex = RegExp(r'^(.*)\((\d+)\)$');
  int copyNumber = 1;

  final match = regex.firstMatch(baseName);
  if (match != null) {
    baseName = match.group(1)!.trim();
    copyNumber = int.parse(match.group(2)!) + 1;
  }

  String newName = '$baseName($copyNumber)';
  String newPath = p.join(parentDir, '$newName$fileExt');

  while (await nameExists(newName, parentPath: parentDir)) {
    copyNumber++;
    newName = '$baseName($copyNumber)';
    newPath = p.join(parentDir, '$newName$fileExt');
  }

  return newPath;
}
