/// 代码查看/编辑器 —— 纯 Dart（re_editor + re_highlight），无 WebView。
///
/// 读本地文件 → 按扩展名选 re_highlight 语法高亮 → re_editor 编辑。
/// 默认只读（看代码），点「编辑」可改，点「保存」写回磁盘。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

/// 扩展名 → re_highlight 语言模式（null = 不高亮，纯文本）。
Mode? _modeForPath(String path) {
  switch (p.extension(path).toLowerCase()) {
    case '.dart':
      return langDart;
    case '.py':
      return langPython;
    case '.js':
    case '.mjs':
    case '.cjs':
      return langJavascript;
    case '.ts':
      return langTypescript;
    case '.html':
    case '.htm':
    case '.xml':
    case '.svg':
      return langXml;
    case '.css':
      return langCss;
    case '.scss':
      return langScss;
    case '.json':
      return langJson;
    case '.yaml':
    case '.yml':
      return langYaml;
    case '.md':
    case '.markdown':
      return langMarkdown;
    case '.java':
      return langJava;
    case '.go':
      return langGo;
    case '.rs':
      return langRust;
    case '.c':
    case '.h':
      return langC;
    case '.cpp':
    case '.cc':
    case '.hpp':
      return langCpp;
    case '.sh':
    case '.bash':
    case '.zsh':
      return langBash;
    case '.sql':
      return langSql;
    case '.ini':
    case '.cfg':
    case '.conf':
      return langIni;
    case '.kt':
    case '.kts':
      return langKotlin;
    case '.lua':
      return langLua;
    case '.php':
      return langPhp;
    case '.rb':
      return langRuby;
    case '.swift':
      return langSwift;
    case '.txt':
    case '.log':
      return langPlaintext;
    default:
      return null;
  }
}

/// 语言 key（CodeHighlightTheme 单语言直高亮用；扩展名去点，保证 map 内唯一）。
String? _langKeyForPath(String path) {
  final ext = p.extension(path).toLowerCase();
  if (ext.isEmpty) {
    return null;
  }
  return ext.replaceFirst('.', '');
}

class CodeEditorScreen extends StatefulWidget {
  final String filePath;

  const CodeEditorScreen({super.key, required this.filePath});

  @override
  State<CodeEditorScreen> createState() => _CodeEditorScreenState();
}

class _CodeEditorScreenState extends State<CodeEditorScreen> {
  CodeLineEditingController? _controller;
  bool _readOnly = true;
  bool _loading = true;
  String? _error;
  String? _originalText;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final f = File(widget.filePath);
      if (!f.existsSync()) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = '文件不存在：${widget.filePath}';
        });
        return;
      }
      final text = await f.readAsString();
      if (!mounted) return;
      setState(() {
        _controller = CodeLineEditingController.fromText(text);
        _originalText = text;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取失败：$e';
      });
    }
  }

  bool get _dirty =>
      _controller != null && _originalText != null && _controller!.text != _originalText;

  Future<void> _save() async {
    final controller = _controller;
    if (controller == null || !mounted) return;
    try {
      await File(widget.filePath).writeAsString(controller.text);
      if (!mounted) return;
      setState(() {
        _originalText = controller.text;
        _readOnly = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${p.basename(widget.filePath)}${_dirty ? ' ●' : ''}',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (controller != null && !_loading && _error == null)
            _readOnly
                ? TextButton.icon(
                    onPressed: () => setState(() => _readOnly = false),
                    icon: const Icon(Icons.edit, size: 18),
                    label: const Text('编辑'),
                  )
                : TextButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save, size: 18),
                    label: const Text('保存'),
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
    final controller = _controller!;
    final brightness = Theme.of(context).brightness;
    final key = _langKeyForPath(widget.filePath);
    final mode = _modeForPath(widget.filePath);
    return CodeEditor(
      controller: controller,
      readOnly: _readOnly,
      padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
      style: CodeEditorStyle(
        fontSize: 13,
        backgroundColor: Colors.transparent,
        codeTheme: (key != null && mode != null)
            ? CodeHighlightTheme(
                languages: {key: CodeHighlightThemeMode(mode: mode)},
                theme: brightness == Brightness.dark
                    ? atomOneDarkTheme
                    : atomOneLightTheme,
              )
            : null,
      ),
      indicatorBuilder:
          (context, editingController, chunkController, notifier) {
        return Row(
          children: [
            DefaultCodeLineNumber(
              controller: editingController,
              notifier: notifier,
            ),
            DefaultCodeChunkIndicator(
              width: 20,
              controller: chunkController,
              notifier: notifier,
            ),
          ],
        );
      },
      chunkAnalyzer: DefaultCodeChunkAnalyzer(),
    );
  }
}
