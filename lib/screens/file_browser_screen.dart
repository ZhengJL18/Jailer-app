/// 文件浏览器 —— 浏览 agent 工作目录（App documents），点文件打开代码编辑器。
///
/// 目录在前、文件在后，均按名排序。点目录深入（系统返回即向上），点文件
/// 进 CodeEditorScreen。无 root 时默认 App documents 目录（agent 的隔离墙）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'code_editor_screen.dart';
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

class FileBrowserScreen extends StatefulWidget {
  final String? root;

  const FileBrowserScreen({super.key, this.root});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  String? _currentDir;
  bool _loading = true;
  String? _error;
  List<FileSystemEntity> _entries = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final dir = widget.root ?? (await getApplicationDocumentsDirectory()).path;
      _open(dir);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法定位目录：$e';
      });
    }
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
          child: Text(_error!, textAlign: TextAlign.center),
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
            child: Text(
              dir,
              style: TextStyle(
                fontSize: 12,
                color: context.appPalette.textSecondary,
              ),
              overflow: TextOverflow.ellipsis,
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
    );
  }
}
