// 笔记库回收站/归档：`.trash` / `.archive` 隐藏目录语义（从 printnotes
// storage_system trashItem / archiveItem 移植，去 App.localStorage 耦合，根目录参数化）。
library;

import 'dart:io';
import 'package:path/path.dart' as p;

Future<void> _copyTo(FileSystemEntity source, String destPath) async {
  await Directory(p.dirname(destPath)).create(recursive: true);
  if (source is Directory) {
    await _copyDirectory(source, Directory(destPath));
  } else {
    await (source as File).copy(destPath);
  }
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: false)) {
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(p.join(destination.path, p.basename(entity.path))));
    } else if (entity is File) {
      await entity.copy(p.join(destination.path, p.basename(entity.path)));
    }
  }
}

FileSystemEntity _entityFor(String path) {
  return FileSystemEntity.typeSync(path) == FileSystemEntityType.directory
      ? Directory(path)
      : File(path);
}

/// 归档：`{root}/.archive/{相对路径}`（保留目录结构），移出原文件。
Future<void> archiveItem(String rootPath, String itemPath) async {
  final archiveDir = p.join(rootPath, '.archive');
  final relativePath = p.relative(itemPath, from: rootPath);
  final archivePath = p.join(archiveDir, relativePath);

  final source = _entityFor(itemPath);
  await _copyTo(source, archivePath);
  await source.delete(recursive: true);
}

/// 从归档还原。
Future<void> unarchiveItem(String rootPath, String archivedItemPath) async {
  final archiveDir = p.join(rootPath, '.archive');
  final relativePath = p.relative(archivedItemPath, from: archiveDir);
  final destinationPath = p.join(rootPath, relativePath);

  final source = _entityFor(archivedItemPath);
  await _copyTo(source, destinationPath);
  await source.delete(recursive: true);
}

/// 移入回收站：`{root}/.trash/{相对路径}`。
Future<void> trashItem(String rootPath, String itemPath) async {
  final trashDir = p.join(rootPath, '.trash');
  final relativePath = p.relative(itemPath, from: rootPath);
  final deletedPath = p.join(trashDir, relativePath);

  final source = _entityFor(itemPath);
  await _copyTo(source, deletedPath);
  await source.delete(recursive: true);
}

/// 从回收站还原。
Future<void> restoreDeletedItem(String rootPath, String deletedItemPath) async {
  final trashDir = p.join(rootPath, '.trash');
  final relativePath = p.relative(deletedItemPath, from: trashDir);
  final destinationPath = p.join(rootPath, relativePath);

  final source = _entityFor(deletedItemPath);
  await _copyTo(source, destinationPath);
  await source.delete(recursive: true);
}

/// 彻底删除（不可恢复）。
Future<void> permanentlyDeleteItem(String itemPath) async {
  final item = _entityFor(itemPath);
  if (await item.exists()) {
    await item.delete(recursive: true);
  }
}
