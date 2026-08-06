// 笔记库搜索：文件名匹配 + 全文匹配 + #tag 匹配（从 printnotes storage_system
// searchItems / searchMultiFileContents / getAllTags 移植，去 provider 耦合）。
library;

import 'dart:io';
import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;

import 'notes_library.dart';

/// 全文搜索工作负载（compute isolate 传递）。
class SearchPayload {
  final String query;
  final List<String> filePaths;

  SearchPayload({required this.query, required this.filePaths});
}

/// 在笔记文件内容中匹配查询（纯函数，供 compute 隔离执行）。
List<String> searchMultiFileContents(SearchPayload payload) {
  final query = payload.query.toLowerCase();
  final results = <String>[];

  for (final path in payload.filePaths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final content = file.readAsStringSync().replaceAll('\n', ' ').toLowerCase();

    if (content.contains(query)) {
      results.add(path);
      continue;
    }

    // `tags:xxx` 查询 → 匹配 #tag。
    if (query.contains('tags:')) {
      final tags = RegExp(r'#\w+').allMatches(content).toList();
      final cleanQuery = query.replaceFirst('tags:', '').trim();
      if (tags.isNotEmpty) {
        if (cleanQuery.isEmpty) {
          results.add(path);
        } else if (tags.any((e) =>
            content.substring(e.start, e.end).contains(cleanQuery))) {
          results.add(path);
        }
      }
    }
  }
  return results;
}

/// 在 [rootPath] 下搜索：先按文件名匹配，再按内容匹配（compute 隔离）。
Future<List<String>> searchNotes(String rootPath, String query) async {
  final allItems = await listFolderContents(rootPath, recursive: true);
  final noteFiles = allItems
      .whereType<File>()
      .where((f) => isNoteFile(f.path))
      .toList();

  final q = query.toLowerCase();
  final byName = noteFiles
      .where((f) => p.basename(f.path).toLowerCase().contains(q))
      .map((f) => f.path)
      .toList();

  // 内容搜索走 compute isolate，避免卡 UI。
  final byContent = await compute(
    searchMultiFileContents,
    SearchPayload(query: query, filePaths: noteFiles.map((f) => f.path).toList()),
  );

  // 合并去重。
  final pathSet = byName.toSet();
  for (final path in byContent) {
    pathSet.add(path);
  }
  final results = pathSet.toList()..sort();
  return results;
}

/// 收集 [rootPath] 下所有笔记的 #tag → 文件路径 映射。
Future<Map<String, List<String>>> getAllTags(String rootPath) async {
  final allItems = await listFolderContents(rootPath, recursive: true);
  final noteFiles = allItems
      .whereType<File>()
      .where((f) => isNoteFile(f.path))
      .toList();

  final tagMap = <String, List<String>>{};
  for (final file in noteFiles) {
    if (!file.existsSync()) continue;
    final contents = await file.readAsString();
    final matches = RegExp(r'(?<!\S)(#[\w-]+)(?!\S)').allMatches(contents);
    for (final match in matches) {
      final tag = contents.substring(match.start, match.end);
      tagMap.putIfAbsent(tag, () => []);
      if (!tagMap[tag]!.contains(file.path)) {
        tagMap[tag]!.add(file.path);
      }
    }
  }
  return tagMap;
}
