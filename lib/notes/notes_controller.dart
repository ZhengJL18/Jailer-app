// 笔记库状态：全局单例 ChangeNotifier（仿 themeController 模式，hermes 无 provider）。
// 管理当前目录、文件列表、排序、多选、回收站/归档视图、搜索。
// ensureInitialized() 必须先调用（确定 notes 根目录）再访问任何状态。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'notes_frontmatter.dart';
import 'notes_library.dart';
import 'notes_paths.dart';
import 'notes_search.dart';
import 'notes_trash.dart';
import 'notes_unique.dart';

/// 笔记库视图模式。
enum NotesView { library, trash, archive }

/// 排序方式。
enum NotesSort { name, modified }

class NotesController extends ChangeNotifier {
  String _rootPath = '';
  String _currentDir = '';
  List<FileSystemEntity> _items = [];
  NotesView _view = NotesView.library;
  NotesSort _sort = NotesSort.name;
  bool _searching = false;
  List<String> _searchResults = [];
  // 多选状态。
  final Set<String> _selected = {};
  bool get selecting => _selected.isNotEmpty;

  String get rootPath => _rootPath;
  String get currentDir => _currentDir;
  List<FileSystemEntity> get items => List.unmodifiable(_items);
  NotesView get view => _view;
  NotesSort get sort => _sort;
  List<String> get searchResults => _searchResults;
  bool get searching => _searching;
  Set<String> get selected => _selected;

  bool _initialized = false;

  /// 初始化：确定 notes 根目录并进入。
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    final documents = (await getApplicationDocumentsDirectory()).path;
    _rootPath = notesRootPath(documents);
    await Directory(_rootPath).create(recursive: true);
    _currentDir = _rootPath;
    _initialized = true;
    await refresh();
  }

  /// 进入目录 / 返回上级。返回 false = 已在根目录。
  Future<bool> cd(String dir) async {
    _selected.clear();
    _currentDir = dir;
    await refresh();
    return true;
  }

  Future<bool> goUp() async {
    final parent = p.dirname(_currentDir);
    if (parent == _currentDir || parent == _rootPath || !parent.startsWith(_rootPath)) {
      _currentDir = _rootPath;
    } else {
      _currentDir = parent;
    }
    _selected.clear();
    await refresh();
    return _currentDir == _rootPath;
  }

  /// 刷新当前目录列表。
  Future<void> refresh() async {
    if (!_initialized) return;
    final entities = await listFolderContents(_currentDir);
    var items = entities.toList();
    if (_sort == NotesSort.modified) {
      items.sort((a, b) {
        final at = _modified(a);
        final bt = _modified(b);
        return bt.compareTo(at);
      });
    } else {
      // name 排序：目录在前，文件在后，各自按名。
      items.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
      });
    }
    _items = items;
    notifyListeners();
  }

  DateTime _modified(FileSystemEntity e) {
    try {
      return FileSystemEntity.typeSync(e.path) == FileSystemEntityType.file
          ? File(e.path).lastModifiedSync()
          : FileSystemEntity.typeSync(e.path) == FileSystemEntityType.directory
              ? File(e.path).lastModifiedSync()
              : DateTime.fromMillisecondsSinceEpoch(0);
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  void switchView(NotesView v) {
    _view = v;
    _selected.clear();
    _searchResults = [];
    if (v == NotesView.library && _currentDir != _rootPath) {
      // 从回收站/归档切回库视图时，回到库根目录。
      _currentDir = _rootPath;
    }
    notifyListeners();
    _reloadView();
  }

  void setSort(NotesSort s) {
    _sort = s;
    refresh();
  }

  Future<void> _reloadView() async {
    if (_view == NotesView.library) {
      await refresh();
    } else {
      final containerDir = _view == NotesView.trash ? '.trash' : '.archive';
      final dir = p.join(_rootPath, containerDir);
      _currentDir = dir;
      final entities = await listFolderContents(dir, recursive: true, showHidden: true);
      _items = entities;
      notifyListeners();
    }
  }

  /// 创建笔记文件（防重名）。
  Future<String?> createNote(String name) async {
    final safeName = name.trim().isEmpty ? '未命名' : name.trim();
    final base = p.join(_currentDir, safeName);
    final path = await resolveUniqueFileName('$base.md');
    final f = File(path);
    await f.create(recursive: true);
    await f.writeAsString('');
    await refresh();
    return path;
  }

  /// 创建文件夹（防重名）。
  Future<String?> createFolder(String name) async {
    final safeName = name.trim().isEmpty ? '新文件夹' : name.trim();
    var dirPath = p.join(_currentDir, safeName);
    if (await nameExists(safeName, parentPath: _currentDir)) {
      dirPath = await resolveUniqueFileName(dirPath);
    }
    await Directory(dirPath).create(recursive: true);
    await refresh();
    return dirPath;
  }

  /// 重命名。返回是否成功。
  Future<bool> rename(String oldPath, String newName) async {
    final isFile = await FileSystemEntity.isFile(oldPath);
    final item = isFile ? File(oldPath) : Directory(oldPath);
    if (!await item.exists()) return false;
    final parentDir = p.dirname(oldPath);
    final newPath = p.join(parentDir, newName);
    if (await nameExists(newName, parentPath: parentDir)) return false;
    await item.rename(newPath);
    await refresh();
    return true;
  }

  /// 删除（进回收站）。
  Future<void> delete(String path) async {
    await trashItem(_rootPath, path);
    _selected.remove(path);
    await refresh();
  }

  /// 彻底删除 / 归档。
  Future<void> archive(String path) async {
    await archiveItem(_rootPath, path);
    _selected.remove(path);
    await _reloadView();
  }

  Future<void> restore(String path) async {
    if (_view == NotesView.trash) {
      await restoreDeletedItem(_rootPath, path);
    } else {
      await unarchiveItem(_rootPath, path);
    }
    _selected.remove(path);
    await _reloadView();
  }

  Future<void> purge(String path) async {
    await permanentlyDeleteItem(path);
    _selected.remove(path);
    await _reloadView();
  }

  void toggleSelect(String path) {
    if (_selected.contains(path)) {
      _selected.remove(path);
    } else {
      _selected.add(path);
    }
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  /// 搜索（在 notes 根内，递归）。非空查询进入搜索模式。
  Future<void> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      _searching = false;
      _searchResults = [];
      notifyListeners();
      await refresh();
      return;
    }
    _searching = true;
    final results = await searchNotes(_rootPath, q);
    _searchResults = results;
    notifyListeners();
  }

  /// 读取笔记正文（去掉 frontmatter 返回 body + raw）。
  Future<ParsedNote> readNote(String path) async {
    final content = await File(path).readAsString();
    return parseFrontmatter(content);
  }
}

/// 全局单例（在 main.dart _initCwd 或 NotesLibraryScreen 里 ensureInitialized）。
NotesController notesController = NotesController();
