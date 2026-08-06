// 笔记编辑器：编辑/预览切换 + 3 秒自动保存 + 外部修改检测。
// 从 printnotes note_editor 移植核心（编辑/预览 + 自动保存），去 provider/工具栏耦合，
// 渲染用全局新引擎 HermesMarkdown。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../notes/notes_controller.dart';
import '../theme/theme_ext.dart';
import '../widgets/markdown_math.dart';

class NoteEditorScreen extends StatefulWidget {
  final String filePath;

  const NoteEditorScreen({super.key, required this.filePath});

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final TextEditingController _controller;
  bool _editing = false;
  bool _loading = true;
  bool _error = false;
  bool _hasUnsaved = false;
  Timer? _autoSaveTimer;
  Timer? _fileCheckTimer;
  DateTime? _lastModified;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _fileCheckTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final f = File(widget.filePath);
      if (await f.exists()) {
        _controller.text = await f.readAsString();
        try {
          _lastModified = await f.lastModified();
        } catch (_) {}
      } else {
        await f.create(recursive: true);
      }
      if (!mounted) return;
      setState(() => _loading = false);
      _startFileCheck();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  void _startFileCheck() {
    // 每 2s 检查外部修改（agent 可能改了文件），仅在非编辑态提示。
    _fileCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || _editing) return;
      final f = File(widget.filePath);
      if (!await f.exists()) return;
      DateTime? m;
      try {
        m = await f.lastModified();
      } catch (_) {}
      if (m != null && _lastModified != null && m.isAfter(_lastModified!)) {
        _lastModified = m;
        final content = await f.readAsString();
        if (content != _controller.text && mounted) {
          setState(() {
            _controller.text = content;
            _controller.selection =
                TextSelection.collapsed(offset: _controller.text.length);
          });
        }
      }
    });
  }

  void _onChanged(String _) {
    setState(() => _hasUnsaved = true);
    _setupAutoSave();
  }

  void _setupAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 3), _save);
  }

  Future<void> _save() async {
    _autoSaveTimer?.cancel();
    if (!_hasUnsaved) return;
    try {
      final f = File(widget.filePath);
      await f.writeAsString(_controller.text);
      try {
        _lastModified = await f.lastModified();
      } catch (_) {}
      if (!mounted) return;
      setState(() => _hasUnsaved = false);
    } catch (_) {}
  }

  void _toggleMode() {
    if (_editing) {
      // 从编辑切到预览：立即保存。
      _save();
    }
    setState(() => _editing = !_editing);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          p.basename(widget.filePath),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_hasUnsaved)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Text('未保存',
                    style: TextStyle(color: palette.textSecondary, fontSize: 12)),
              ),
            ),
          IconButton(
            icon: Icon(_editing ? Icons.visibility : Icons.edit_outlined),
            tooltip: _editing ? '预览' : '编辑',
            onPressed: _loading ? null : _toggleMode,
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: '保存',
            onPressed: _loading ? null : _save,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? const Center(child: Text('读取文件失败'))
              : _editing
                  ? _buildEditor(context)
                  : _buildPreview(context),
    );
  }

  Widget _buildEditor(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: _controller,
        onChanged: _onChanged,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(fontSize: 16, height: 1.5),
        decoration: const InputDecoration(
          border: InputBorder.none,
          hintText: '用 Markdown 写笔记…（支持 LaTeX、#tag、[[wiki]]、代码块）',
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final text = _controller.text;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: HermesMarkdown(
        data: text,
        imageRoot: notesController.rootPath.isEmpty
            ? null
            : notesController.rootPath,
      ),
    );
  }
}
