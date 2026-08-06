// 笔记库文件模型：文件类型分类 + 目录树枚举（从 printnotes file_extensions /
// storage_system.listFolderContents 移植，去掉 provider 耦合）。
library;

import 'dart:io';
import 'package:path/path.dart' as p;

/// 文件类型分类。
enum CFileType { note, image, pdf, sketch, unknown }

/// 笔记扩展名（.md/.markdown/.txt/.me 算笔记）。
const List<String> allowedNoteExtensions = ['.md', '.markdown', '.txt', '.me'];
const List<String> allowedImageExtensions = ['.jpg', '.jpeg', '.png', '.bmp', '.gif'];
const List<String> allowedPdfExtensions = ['.pdf'];
const List<String> allowedSketchExtensions = ['.bson'];

/// 按扩展名分类文件。
CFileType fileTypeOf(String path) {
  final ext = p.extension(path);
  if (allowedNoteExtensions.contains(ext)) return CFileType.note;
  if (allowedImageExtensions.contains(ext)) return CFileType.image;
  if (allowedPdfExtensions.contains(ext)) return CFileType.pdf;
  if (allowedSketchExtensions.contains(ext)) return CFileType.sketch;
  return CFileType.unknown;
}

/// 是否为笔记文件。
bool isNoteFile(String path) => fileTypeOf(path) == CFileType.note;

/// 枚举目录内容（可选递归、可选含隐藏文件）。隐藏 = 路径段以 `.` 开头。
Future<List<FileSystemEntity>> listFolderContents(
  String folderPath, {
  bool recursive = false,
  bool showHidden = false,
}) async {
  final folder = Directory(folderPath);
  if (!await folder.exists()) return const [];
  final contents = await folder.list(recursive: recursive).toList();
  if (showHidden) return contents;
  final base = folder.uri.toFilePath();
  return contents.where((item) {
    final relative = item.path.replaceFirst(base, '');
    final segments = p.split(relative);
    return !segments.any((s) => s.startsWith('.'));
  }).toList();
}
