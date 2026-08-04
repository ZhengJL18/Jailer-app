/// 记忆管理页：查看/编辑 MEMORY.md（个人笔记）与 USER.md（用户资料）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  bool _loading = true;
  String _memoryContent = '';
  String _userContent = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Directory> _memoriesDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/memories');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _load() async {
    final dir = await _memoriesDir();
    final memFile = File('${dir.path}/MEMORY.md');
    final userFile = File('${dir.path}/USER.md');
    if (!mounted) return;
    setState(() {
      _memoryContent = memFile.existsSync()
          ? memFile.readAsStringSync()
          : '';
      _userContent = userFile.existsSync()
          ? userFile.readAsStringSync()
          : '';
      _loading = false;
    });
  }

  Future<void> _edit(String title, String content) async {
    final controller = TextEditingController(text: content);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑$title'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 12,
            decoration: const InputDecoration(
              hintText: '输入内容…',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    final dir = await _memoriesDir();
    final filename = title == '记忆' ? 'MEMORY.md' : 'USER.md';
    await File('${dir.path}/$filename').writeAsString(saved);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$title已保存')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('记忆管理')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.sticky_note_2_outlined,
                        color: Colors.teal),
                    title: const Text('记忆（MEMORY.md）'),
                    subtitle: Text(
                      _memoryContent.isEmpty
                          ? '空的，agent 会自己记录'
                          : '${_memoryContent.length} 字符',
                    ),
                    trailing: const Icon(Icons.edit),
                    onTap: () => _edit('记忆', _memoryContent),
                  ),
                ),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.person_outline, color: Colors.blue),
                    title: const Text('用户资料（USER.md）'),
                    subtitle: Text(
                      _userContent.isEmpty
                          ? '空的，描述你是谁、你的偏好'
                          : '${_userContent.length} 字符',
                    ),
                    trailing: const Icon(Icons.edit),
                    onTap: () => _edit('用户资料', _userContent),
                  ),
                ),
                const SizedBox(height: 12),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '这些是 agent 长期记住的内容。agent 也会自动写入；'
                    '你可以手动维护，让 agent 更了解你。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
    );
  }
}
