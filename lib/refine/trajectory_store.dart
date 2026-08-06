/// Trajectory Store — Continual Harness 的证据源。
///
/// append-only JSONL，每任务一行轨迹快照（用户输入、调用的工具、结果走向）。
/// refine 管线读最近 N 条来提议改进。超过上限滚动截断（保尾部最新）。
library;

import 'dart:convert';
import 'dart:io';

/// 单条轨迹记录。
class TrajectoryRecord {
  final DateTime ts;
  final String sessionId;
  final String userPrompt;
  final List<String> toolNames;
  final bool completed;
  final String outcome; // 'success' / 'error' / 'cancelled' / 'budget'
  final String? finalExcerpt; // finalResponse 前 200 字。

  TrajectoryRecord({
    required this.ts,
    required this.sessionId,
    required this.userPrompt,
    required this.toolNames,
    required this.completed,
    required this.outcome,
    this.finalExcerpt,
  });

  Map<String, dynamic> toJson() => {
        'ts': ts.toIso8601String(),
        'session_id': sessionId,
        'user_prompt': userPrompt,
        'tool_names': toolNames,
        'completed': completed,
        'outcome': outcome,
        if (finalExcerpt != null) 'final_excerpt': finalExcerpt,
      };

  factory TrajectoryRecord.fromJson(Map<String, dynamic> j) =>
      TrajectoryRecord(
        ts: DateTime.tryParse(j['ts'] as String? ?? '') ?? DateTime.now(),
        sessionId: j['session_id'] as String? ?? '',
        userPrompt: j['user_prompt'] as String? ?? '',
        toolNames: [
          for (final t in (j['tool_names'] as List? ?? const []))
            if (t is String) t,
        ],
        completed: j['completed'] as bool? ?? false,
        outcome: j['outcome'] as String? ?? 'unknown',
        finalExcerpt: j['final_excerpt'] as String?,
      );
}

/// 轨迹持久化（JSONL，App documents 目录）。
class TrajectoryStore {
  final String filePath;
  final int maxRecords;

  TrajectoryStore({required this.filePath, this.maxRecords = 200});

  void append(TrajectoryRecord record) {
    try {
      final f = File(filePath);
      Directory(File(filePath).parent.path).createSync(recursive: true);
      final line = jsonEncode(record.toJson());
      if (!f.existsSync()) {
        f.writeAsStringSync('$line\n', flush: true);
      } else {
        final raf = f.openSync(mode: FileMode.append);
        raf.writeStringSync('$line\n');
        raf.closeSync();
      }
      _truncateIfNeeded();
    } catch (_) {}
  }

  void _truncateIfNeeded() {
    try {
      final f = File(filePath);
      if (!f.existsSync()) return;
      final lines = f
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (lines.length <= maxRecords) return;
      f.writeAsStringSync(
        lines.sublist(lines.length - maxRecords).join('\n') + '\n',
        flush: true,
      );
    } catch (_) {}
  }

  /// 最近 N 条轨迹（refine 证据源）。
  List<TrajectoryRecord> recent(int n) {
    try {
      final f = File(filePath);
      if (!f.existsSync()) return [];
      final lines = f.readAsLinesSync().where((l) => l.trim().isNotEmpty);
      final all = <TrajectoryRecord>[];
      for (final line in lines) {
        try {
          final j = jsonDecode(line);
          if (j is Map<String, dynamic>) all.add(TrajectoryRecord.fromJson(j));
        } catch (_) {}
      }
      return all.length > n ? all.sublist(all.length - n) : all;
    } catch (_) {
      return [];
    }
  }

  /// 渲染轨迹为文本（喂 refine 的 LLM）。
  String renderRecent(int n) {
    final records = recent(n);
    if (records.isEmpty) return '(暂无任务轨迹)';
    final buf = StringBuffer();
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      buf.writeln('--- 任务 ${i + 1} ---');
      buf.writeln('用户输入: ${r.userPrompt}');
      if (r.toolNames.isNotEmpty) {
        buf.writeln('调用工具: ${r.toolNames.join(', ')}');
      }
      buf.writeln('结果: ${r.outcome}'
          '${r.completed ? ' (完成)' : ' (未完成)'}');
      if (r.finalExcerpt != null && r.finalExcerpt!.isNotEmpty) {
        buf.writeln('回复摘录: ${r.finalExcerpt}');
      }
      buf.writeln();
    }
    return buf.toString();
  }
}
