/// Edit Journal — 自进化编辑台账 + 回滚。
///
/// 每条已应用的自进化编辑记录一个**可逆操作**描述，undo 时按它反向恢复。
/// 持久化 JSON，App documents 目录。对照 Prime Agent /refine 的快照回滚：
/// 不存全量快照，存反向操作（更轻，单条编辑可独立回滚）。
library;

import 'dart:convert';
import 'dart:io';

/// 可逆操作类型。
enum JournalOpType {
  memoryAdd, // 反向：memory.remove(原文)
  memoryReplace, // 反向：memory.replace(新文→原文)
  skillCreate, // 反向：删 skill
  skillPatch, // 反向：patch 回去
  promptNoteAdd, // 反向：删 note
}

/// 一条编辑台账记录。
class JournalEntry {
  final String id;
  final JournalOpType op;
  final DateTime appliedAt;
  final String type; // 展示用：memory / skill / prompt_note
  final String target; // memory target / skill name / note id
  final Map<String, dynamic> opArgs; // 执行时的参数（回滚要用）。
  final Map<String, dynamic> reverseOp; // 反向操作参数。

  JournalEntry({
    required this.id,
    required this.op,
    required this.appliedAt,
    required this.type,
    required this.target,
    required this.opArgs,
    required this.reverseOp,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'op': op.name,
        'applied_at': appliedAt.toIso8601String(),
        'type': type,
        'target': target,
        'op_args': opArgs,
        'reverse_op': reverseOp,
      };

  factory JournalEntry.fromJson(Map<String, dynamic> j) => JournalEntry(
        id: j['id'] as String? ?? '',
        op: JournalOpType.values.asNameMap()[j['op']] ?? JournalOpType.memoryAdd,
        appliedAt: DateTime.tryParse(j['applied_at'] as String? ?? '') ??
            DateTime.now(),
        type: j['type'] as String? ?? '',
        target: j['target'] as String? ?? '',
        opArgs: (j['op_args'] as Map?)?.cast<String, dynamic>() ?? const {},
        reverseOp: (j['reverse_op'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// 编辑台账（JSON 文件）。
class EditJournal {
  final String filePath;
  List<JournalEntry> _entries = [];
  bool _loaded = false;

  EditJournal({required this.filePath});

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(filePath);
      if (!f.existsSync()) {
        _entries = [];
        return;
      }
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is List) {
        _entries = [
          for (final e in raw)
            if (e is Map<String, dynamic>) JournalEntry.fromJson(e),
        ];
      }
    } catch (_) {
      _entries = [];
    }
  }

  void _save() {
    try {
      File(filePath).parent.createSync(recursive: true);
      File(filePath).writeAsStringSync(
        jsonEncode([for (final e in _entries) e.toJson()]),
        flush: true,
      );
    } catch (_) {}
  }

  void add(JournalEntry entry) {
    _ensureLoaded();
    _entries.add(entry);
    _save();
  }

  List<JournalEntry> list() {
    _ensureLoaded();
    return List.unmodifiable(_entries);
  }

  JournalEntry? findById(String id) {
    _ensureLoaded();
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  bool remove(String id) {
    _ensureLoaded();
    final before = _entries.length;
    _entries.removeWhere((e) => e.id == id);
    if (_entries.length != before) {
      _save();
      return true;
    }
    return false;
  }
}
