// 笔记库主界面：浏览 notes/ 目录树 + 搜索 + 多选 + 回收站/归档切换。
// 布局从 printnotes home/ 移植，去 provider 耦合，配色走 hermes appPalette。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../notes/notes_controller.dart';
import '../notes/notes_library.dart';
import '../theme/theme_ext.dart';
import 'note_editor_screen.dart';

class NotesLibraryScreen extends StatefulWidget {
  const NotesLibraryScreen({super.key});

  @override
  State<NotesLibraryScreen> createState() => _NotesLibraryScreenState();
}

class _NotesLibraryScreenState extends State<NotesLibraryScreen> {
  bool _ready = false;
  String? _error;
  bool _showSearchBar = false;
  final _searchCtrl = TextEditingController();

  NotesController get _ctrl => notesController;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onCtrl);
    _init();
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onCtrl);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await _ctrl.ensureInitialized();
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '初始化笔记库失败：$e');
    }
  }

  void _onCtrl() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      appBar: AppBar(
        title: Text(_ctrl.view == NotesView.library
            ? (_ctrl.currentDir == _ctrl.rootPath
                ? '笔记库'
                : p.basename(_ctrl.currentDir))
            : (_ctrl.view == NotesView.trash ? '回收站' : '归档')),
        actions: [
          if (_ctrl.view == NotesView.library) ...[
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: '搜索',
              onPressed: _showSearch,
            ),
            PopupMenuButton<NotesSort>(
              icon: const Icon(Icons.sort),
              tooltip: '排序',
              onSelected: (s) => _ctrl.setSort(s),
              itemBuilder: (_) => const [
                PopupMenuItem(value: NotesSort.name, child: Text('按名称')),
                PopupMenuItem(value: NotesSort.modified, child: Text('按修改时间')),
              ],
            ),
          ],
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) {
              switch (v) {
                case 'trash':
                  _ctrl.switchView(NotesView.trash);
                case 'archive':
                  _ctrl.switchView(NotesView.archive);
                case 'library':
                  _ctrl.switchView(NotesView.library);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'library',
                child: Row(children: [
                  Icon(Icons.folder_open, size: 18, color: palette.textSecondary),
                  const SizedBox(width: 8),
                  const Text('笔记库'),
                ]),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'trash',
                child: Row(children: [
                  Icon(Icons.delete_outline, size: 18, color: palette.textSecondary),
                  const SizedBox(width: 8),
                  const Text('回收站'),
                ]),
              ),
              PopupMenuItem(
                value: 'archive',
                child: Row(children: [
                  Icon(Icons.archive_outlined, size: 18, color: palette.textSecondary),
                  const SizedBox(width: 8),
                  const Text('归档'),
                ]),
              ),
            ],
          ),
        ],
        bottom: _showSearchBar
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _searchCtrl,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: '搜索文件名 / 内容 / #tag',
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: '关闭搜索',
                        onPressed: () {
                          _searchCtrl.clear();
                          _ctrl.search('');
                          setState(() => _showSearchBar = false);
                        },
                      ),
                    ),
                    onChanged: (q) {
                      setState(() {});
                      _ctrl.search(q);
                    },
                  ),
                ),
              )
            : null,
      ),
      body: !_ready
          ? (_error != null
              ? Center(child: Text(_error!))
              : const Center(child: CircularProgressIndicator()))
          : _buildBody(context),
      floatingActionButton: _ctrl.view == NotesView.library &&
              !_ctrl.searching
          ? FloatingActionButton.extended(
              onPressed: _showCreateMenu,
              icon: const Icon(Icons.add),
              label: const Text('新建'),
            )
          : null,
    );
  }

  Widget _buildBody(BuildContext context) {
    final palette = context.appPalette;

    if (_ctrl.searching) {
      final results = _ctrl.searchResults;
      if (results.isEmpty) {
        return const Center(child: Text('无匹配结果'));
      }
      return ListView.builder(
        itemCount: results.length,
        itemBuilder: (ctx, i) {
          final path = results[i];
          final name = p.basename(path);
          final relative = path.replaceFirst('${_ctrl.rootPath}/', '');
          return ListTile(
            leading: Icon(isNoteFile(path) ? Icons.description_outlined : Icons.image_outlined,
                color: palette.primary),
            title: Text(name),
            subtitle: Text(relative),
            onTap: () => _openEntry(path),
          );
        },
      );
    }

    if (_ctrl.view != NotesView.library) {
      // 回收站 / 归档：只列文件，可还原/彻底删除。
      final items = _ctrl.items;
      if (items.isEmpty) {
        return Center(
          child: Text(_ctrl.view == NotesView.trash ? '回收站是空的' : '没有归档内容',
              style: TextStyle(color: palette.textSecondary)),
        );
      }
      return ListView.builder(
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final item = items[i];
          if (item is! File) return const SizedBox.shrink();
          return ListTile(
            leading: Icon(Icons.restore_from_trash, color: palette.primary),
            title: Text(p.basename(item.path)),
            subtitle: Text(item.path.replaceFirst(_ctrl.rootPath, '')),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.restore),
                  tooltip: '还原',
                  onPressed: () => _ctrl.restore(item.path),
                ),
                IconButton(
                  icon: Icon(Icons.delete_forever, color: palette.danger),
                  tooltip: '彻底删除',
                  onPressed: () => _confirmPurge(item.path),
                ),
              ],
            ),
          );
        },
      );
    }

    // 正常库浏览。
    if (_ctrl.currentDir != _ctrl.rootPath) {
      return Column(
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_upward),
            title: const Text('返回上级'),
            onTap: () => _ctrl.goUp(),
          ),
          const Divider(height: 1),
          Expanded(child: _buildItemsList(context)),
        ],
      );
    }
    return _buildItemsList(context);
  }

  Widget _buildItemsList(BuildContext context) {
    final palette = context.appPalette;
    final items = _ctrl.items;
    if (items.isEmpty) {
      return Center(
        child: Text('空目录 · 点右下角新建', style: TextStyle(color: palette.textSecondary)),
      );
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final item = items[i];
        final isDir = item is Directory;
        final isSelected = _ctrl.selected.contains(item.path);
        final type = isDir ? null : fileTypeOf(item.path);
        final IconData icon;
        if (isDir) {
          icon = Icons.folder;
        } else {
          icon = switch (type) {
            CFileType.note => Icons.description_outlined,
            CFileType.image => Icons.image_outlined,
            CFileType.pdf => Icons.picture_as_pdf_outlined,
            _ => Icons.insert_drive_file_outlined,
          };
        }
        return ListTile(
          leading: Icon(icon,
              color: isDir ? palette.accent : palette.primary),
          title: Text(p.basename(item.path)),
          subtitle: isDir ? null : Text(_fileMeta(item)),
          selected: isSelected,
          trailing: isDir ? const Icon(Icons.chevron_right) : null,
          onTap: () => _openEntry(item.path),
          onLongPress: () => _ctrl.toggleSelect(item.path),
        );
      },
    );
  }

  String _fileMeta(FileSystemEntity e) {
    if (e is! File) return '';
    try {
      final size = e.lengthSync();
      final sizeText = size < 1024
          ? '$size B'
          : size < 1024 * 1024
              ? '${(size / 1024).toStringAsFixed(1)} KB'
              : '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
      return sizeText;
    } catch (_) {
      return '';
    }
  }

  void _openEntry(String path) {
    if (_ctrl.selected.isNotEmpty) {
      _ctrl.toggleSelect(path);
      return;
    }
    final isDir = FileSystemEntity.isDirectorySync(path);
    if (isDir) {
      _ctrl.cd(path);
      return;
    }
    if (isNoteFile(path)) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => NoteEditorScreen(filePath: path)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${p.basename(path)} 非笔记文件，暂不支持打开')),
      );
    }
  }

  void _showSearch() {
    setState(() => _showSearchBar = !_showSearchBar);
    if (_showSearchBar) {
      _searchCtrl.clear();
      _ctrl.search('');
    }
  }

  void _showCreateMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: const Text('新建笔记'),
              onTap: () async {
                Navigator.of(ctx).pop();
                final name = await _promptName('新建笔记', '笔记名（自动加 .md）');
                if (name == null) return;
                final path = await _ctrl.createNote(name);
                if (path != null && mounted) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => NoteEditorScreen(filePath: path)),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('新建文件夹'),
              onTap: () async {
                Navigator.of(ctx).pop();
                final name = await _promptName('新建文件夹', '文件夹名');
                if (name == null) return;
                await _ctrl.createFolder(name);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _promptName(String title, String label) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _confirmPurge(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('彻底删除'),
        content: const Text('此操作不可恢复，确定删除？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _ctrl.purge(path);
    }
  }
}
