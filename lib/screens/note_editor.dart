/// Markdown 笔记编辑器：源码编辑 / 渲染预览 切换。
///
/// 源码模式用等宽 TextField；预览模式复用 [HermesMarkdown]（支持 LaTeX
/// 行内 `$...$` 与块级 `$$...$$`）。内容变化通过 [onChanged] 上报，由
/// 父级做自动保存。
library;

import 'package:flutter/material.dart';

import '../widgets/markdown_math.dart';

class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.controller,
    required this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool autofocus;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  /// false = 源码编辑，true = 渲染预览。
  bool _preview = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.edit_outlined),
                    label: Text('编辑'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.visibility_outlined),
                    label: Text('预览'),
                  ),
                ],
                selected: {_preview},
                onSelectionChanged: (s) => setState(() => _preview = s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const Spacer(),
              Text(
                '${widget.controller.text.length} 字',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _preview
              ? _buildPreview()
              : _buildSource(),
        ),
      ],
    );
  }

  Widget _buildSource() {
    return TextField(
      controller: widget.controller,
      autofocus: widget.autofocus,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      style: const TextStyle(
        fontFamily: 'Consolas',
        fontSize: 14,
        height: 1.5,
      ),
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(16),
        hintText: '# 笔记标题\n\n在这里用 Markdown 写笔记…',
      ),
      onChanged: widget.onChanged,
    );
  }

  Widget _buildPreview() {
    final text = widget.controller.text;
    if (text.trim().isEmpty) {
      return const Center(child: Text('（空笔记）'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: HermesMarkdown(data: text),
    );
  }
}
