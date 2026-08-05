/// 文件浏览器 —— 浏览 agent 工作目录 + 公共目录（授权后），支持新建文件。
///
/// 目录在前、文件在后，均按名排序。点目录深入，点文件进 CodeEditorScreen。
/// AppBar：
/// - 目录图标：切换根目录（App 数据目录 / Download / Documents / 存储根）
/// - 新建图标：在当前目录创建文件并打开编辑器
/// 公共目录需要「所有文件访问」权限（MANAGE_EXTERNAL_STORAGE），未授权时点
/// 公共目录入口会引导去授权。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'code_editor_screen.dart';
import '../services/storage_permission.dart';
import '../theme/theme_ext.dart';

/// 二进制扩展名集合：不尝试用文本编辑器打开。
const Set<String> _binaryExts = {
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp',
  '.mp4', '.mov', '.avi', '.mkv', '.mp3', '.m4a', '.wav', '.ogg',
  '.apk', '.aab', '.zip', '.gz', '.tar', '.rar', '.7z', '.jar',
  '.db', '.sqlite', '.so', '.dll', '.exe', '.pdf',
};

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// 公共存储根（Android 实际路径 / 符号链接均可）。
String _storageRoot() {
  if (Directory('/storage/emulated/0').existsSync()) {
    return '/storage/emulated/0';
  }
  if (Directory('/sdcard').existsSync()) {
    return '/sdcard';
  }
  return '/storage/emulated/0'; // fallback，读失败时按不存在处理。
}

/// 路径是否位于公共存储（App 数据目录之外）。
bool _isPublicPath(String path) {
  return path.startsWith('/storage/emulated/0') || path.startsWith('/sdcard');
}

class FileBrowserScreen extends StatefulWidget {
  final String? root;

  const FileBrowserScreen({super.key, this.root});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  String? _currentDir;
  String? _documentsPath;
  bool _externalGranted = false;
  bool _loading = true;
  String? _error;
  List<FileSystemEntity> _entries = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _refreshExternalPermission();
    try {
      final docs = (await getApplicationDocumentsDirectory()).path;
      _documentsPath = docs;
      _open(widget.root ?? docs);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法定位目录：$e';
      });
    }
  }

  /// 重新检测「所有文件访问」权限（进入/授权后刷新）。
  Future<void> _refreshExternalPermission() async {
    var granted = false;
    try {
      granted = await isExternalStorageGranted();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _externalGranted = granted);
  }

  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = Directory(path);
      final entries = d.listSync().toList()
        ..sort((a, b) {
          final ad = a is Directory ? 0 : 1;
          final bd = b is Directory ? 0 : 1;
          if (ad != bd) return ad - bd;
          return a.path.toLowerCase().compareTo(b.path.toLowerCase());
        });
      if (!mounted) return;
      setState(() {
        _currentDir = path;
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法读取：$e';
      });
    }
  }

  void _openEntry(FileSystemEntity e) {
    if (e is Directory) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => FileBrowserScreen(root: e.path)),
      );
    } else if (e is File) {
      final ext = p.extension(e.path).toLowerCase();
      if (_binaryExts.contains(ext)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${p.basename(e.path)} 是二进制文件，无法用编辑器打开')),
        );
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CodeEditorScreen(filePath: e.path)),
      );
    }
  }

  /// 未授权时点公共目录 → 引导授权。
  Future<void> _promptGrant() async {
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要「所有文件访问」权限'),
        content: const Text(
          '访问公共目录（Download / Documents / 存储根）需要授予「所有文件访问」权限。'
          '授权后即可浏览和编辑公共目录里的文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('去授权'),
          ),
        ],
      ),
    );
    if (go == true) {
      await openManageExternalStorageSettings();
      // 从设置回来刷新权限。
      await _refreshExternalPermission();
    }
  }

  /// 切换根目录菜单。
  void _showRootMenu() {
    final docs = _documentsPath;
    final external = _externalGranted;
    final root = _storageRoot();
    final entries = <(String, String)>[
      if (docs != null) ('App 数据目录', docs),
      ('Download', '$root/Download'),
      ('Documents', '$root/Documents'),
      ('存储根目录', root),
    ];
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('切换位置', style: TextStyle(fontWeight: FontWeight.bold)),
              dense: true,
            ),
            for (final (label, path) in entries)
              ListTile(
                leading: Icon(
                  _isPublicPath(path) ? Icons.folder : Icons.apps,
                  color: context.appPalette.textSecondary,
                ),
                title: Text(label),
                trailing: _isPublicPath(path) && !external
                    ? const Icon(Icons.lock_outline,
                        size: 16, color: Colors.orange)
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  if (_isPublicPath(path) && !external) {
                    _promptGrant();
                  } else {
                    _open(path);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 新建文件：输入文件名（可含子路径）→ 当前目录创建 → 打开编辑器。
  Future<void> _newFile() async {
    final dir = _currentDir;
    if (dir == null || !mounted) return;
    if (_isPublicPath(dir) && !_externalGranted) {
      _promptGrant();
      return;
    }
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('新建文件'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '文件名，如 test.py（可带子路径）',
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty || !mounted) return;
    final target = p.join(dir, name);
    try {
      final f = File(target);
      if (f.existsSync()) {
        // 已存在 → 直接打开。
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => CodeEditorScreen(filePath: target)),
        );
        return;
      }
      f.createSync(recursive: true);
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CodeEditorScreen(filePath: target)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建失败：$e')),
      );
    }
  }

  /// 删除条目（长按菜单）。文件直接删，目录递归删（需确认）。
  /// 公共目录删除同样受「所有文件访问」权限约束，未授权弹引导。
  Future<void> _deleteEntry(FileSystemEntity e) async {
    if (!mounted) return;
    if (_isPublicPath(e.path) && !_externalGranted) {
      _promptGrant();
      return;
    }
    final isDir = e is Directory;
    final name = p.basename(e.path);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除${isDir ? '目录' : '文件'}？'),
        content: Text(
          '${isDir ? '目录' : '文件'} "$name"${isDir ? ' 及其全部内容' : ''}将被永久删除，无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      if (isDir) {
        await (e as Directory).delete(recursive: true);
      } else {
        await (e as File).delete();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除 $name')),
      );
      final dir = _currentDir;
      if (dir != null) _open(dir); // 刷新列表。
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$err')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dir = _currentDir;
    final baseName = p.basename(dir ?? '文件');
    return Scaffold(
      appBar: AppBar(
        title: Text(
          baseName.isEmpty ? '文件' : baseName,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: '切换位置',
            onPressed: _showRootMenu,
          ),
          IconButton(
            icon: const Icon(Icons.note_add),
            tooltip: '新建文件',
            onPressed: dir == null ? null : _newFile,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: dir == null ? null : () => _open(dir),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  final docs = _documentsPath;
                  if (docs != null) _open(docs);
                },
                child: const Text('回到 App 数据目录'),
              ),
            ],
          ),
        ),
      );
    }
    final dir = _currentDir;
    if (dir != null) {
      return Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: context.appPalette.surfaceVariant,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    dir,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.appPalette.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_isPublicPath(dir) && !_externalGranted)
                  InkWell(
                    onTap: _promptGrant,
                    child: Row(
                      children: [
                        const Icon(Icons.lock_outline,
                            size: 14, color: Colors.orange),
                        const SizedBox(width: 4),
                        Text(
                          '去授权',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _entries.isEmpty
                ? Center(
                    child: Text(
                      '空目录',
                      style: TextStyle(color: context.appPalette.textSecondary),
                    ),
                  )
                : ListView.builder(
                    itemCount: _entries.length,
                    itemBuilder: (context, i) {
                      final e = _entries[i];
                      return _buildTile(e);
                    },
                  ),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildTile(FileSystemEntity e) {
    final isDir = e is Directory;
    final name = p.basename(e.path);
    final IconData icon;
    final Color iconColor;
    if (isDir) {
      icon = Icons.folder;
      iconColor = Colors.amber;
    } else {
      icon = Icons.insert_drive_file;
      iconColor = context.appPalette.textSecondary;
    }
    String? subtitle;
    if (!isDir) {
      try {
        subtitle = _formatSize((e as File).lengthSync());
      } catch (_) {
        subtitle = null;
      }
    }
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(name, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: isDir
          ? Icon(Icons.chevron_right,
              size: 18, color: context.appPalette.textSecondary)
          : null,
      onTap: () => _openEntry(e),
      onLongPress: () => _showEntryMenu(e),
    );
  }

  /// 长按菜单：删除（操作不可逆，默认藏长按里避免误触）。
  void _showEntryMenu(FileSystemEntity e) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除'),
              subtitle: Text(
                e is Directory ? '删除整个目录及其内容' : '永久删除该文件',
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _deleteEntry(e);
              },
            ),
          ],
        ),
      ),
    );
  }
}
