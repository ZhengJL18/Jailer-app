/// Prompt Notes Store — Continual Harness 的 "supplemental prompts" 维度。
///
/// 对照 Prime Agent 的 Continual Harness：agent 可以小步、带证据地改进
/// 自己的状态，但**基础 workflow 提示不可变**。本 store 存放可自改的
/// 提示片段（prompt notes），注入到 system prompt 尾部；refine 管线建议、
/// 用户批准后写入。删除/修改有台账可回滚。
library;

import 'dart:convert';
import 'dart:io';

/// 单条 prompt note。
class PromptNote {
  final String id;
  String content;
  String trigger; // 何时生效（描述触发条件）。
  final DateTime createdAt;

  PromptNote({
    required this.id,
    required this.content,
    required this.trigger,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'trigger': trigger,
        'created_at': createdAt.toIso8601String(),
      };

  factory PromptNote.fromJson(Map<String, dynamic> j) => PromptNote(
        id: j['id'] as String? ?? '',
        content: j['content'] as String? ?? '',
        trigger: j['trigger'] as String? ?? '',
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// Prompt notes 持久化（JSON 文件，App documents 目录）。
class PromptNotesStore {
  final String filePath;
  List<PromptNote> _notes = [];
  bool _loaded = false;

  PromptNotesStore({required this.filePath});

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(filePath);
      if (!f.existsSync()) {
        _notes = [];
        return;
      }
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is List) {
        _notes = [
          for (final e in raw)
            if (e is Map<String, dynamic>) PromptNote.fromJson(e),
        ];
      }
    } catch (_) {
      _notes = [];
    }
  }

  void _save() {
    try {
      File(filePath).parent.createSync(recursive: true);
      File(filePath).writeAsStringSync(
        jsonEncode([for (final n in _notes) n.toJson()]),
        flush: true,
      );
    } catch (_) {}
  }

  List<PromptNote> list() {
    _ensureLoaded();
    return List.unmodifiable(_notes);
  }

  PromptNote? findById(String id) {
    _ensureLoaded();
    for (final n in _notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  PromptNote add(String content, String trigger) {
    _ensureLoaded();
    final note = PromptNote(
      id: 'pn_${DateTime.now().millisecondsSinceEpoch}',
      content: content.trim(),
      trigger: trigger.trim(),
      createdAt: DateTime.now(),
    );
    if (note.content.isEmpty) {
      throw ArgumentError('Prompt note content cannot be empty.');
    }
    _notes.add(note);
    _save();
    return note;
  }

  bool remove(String id) {
    _ensureLoaded();
    final before = _notes.length;
    _notes.removeWhere((n) => n.id == id);
    if (_notes.length != before) {
      _save();
      return true;
    }
    return false;
  }

  /// 渲染成 system prompt 注入块（放 skill 块之后）。
  String formatForSystemPrompt() {
    _ensureLoaded();
    if (_notes.isEmpty) return '';
    return '\n\n## 补充提示（来自自进化，仅作参考）\n' +
        _notes
            .map((n) => '- ${n.content}'
                '${n.trigger.isNotEmpty ? ' （适用：${n.trigger}）' : ''}')
            .join('\n');
  }
}
