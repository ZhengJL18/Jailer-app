/// 课堂笔记模块的数据模型。
library;

import 'package:flutter/foundation.dart';

/// 一段带说话人标签和时间戳的转写文本。
@immutable
class TranscriptSegment {
  const TranscriptSegment({
    required this.speaker,
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  /// 说话人编号，从 0 开始；-1 表示未分人。
  final int speaker;
  final double startMs;
  final double endMs;
  final String text;

  TranscriptSegment copyWith({String? text}) {
    return TranscriptSegment(
      speaker: speaker,
      startMs: startMs,
      endMs: endMs,
      text: text ?? this.text,
    );
  }
}

/// 会话处理状态。
enum LectureStatus {
  recorded, // 已录音，未转写
  transcribing, // 转写中
  transcribingModels, // 正在下载模型
  done, // 转写 + 总结完成
  failed, // 失败
}

/// 一次课堂录音会话。
class LectureSession {
  const LectureSession({
    required this.id,
    required this.title,
    required this.audioPath,
    required this.createdAt,
    required this.status,
  });

  final String id;
  final String title;
  final String audioPath;
  final DateTime createdAt;
  final LectureStatus status;

  LectureSession copyWith({LectureStatus? status, String? title}) {
    return LectureSession(
      id: id,
      title: title ?? this.title,
      audioPath: audioPath,
      createdAt: createdAt,
      status: status ?? this.status,
    );
  }
}

/// DeepSeek 生成的结构化课堂笔记。
class LectureNote {
  const LectureNote({
    required this.summary,
    required this.keyPoints,
    required this.terms,
    required this.examHints,
    required this.questions,
  });

  /// 课程核心内容概述。
  final String summary;

  /// 要点列表。
  final List<String> keyPoints;

  /// 需要掌握的名词/术语。
  final List<String> terms;

  /// 考点/老师强调的重点。
  final List<String> examHints;

  /// 遗留疑问（若有）。
  final List<String> questions;

  factory LectureNote.fromJson(Map<String, dynamic> json) {
    List<String> list(String key) =>
        (json[key] as List? ?? const []).map((e) => e.toString()).toList();
    return LectureNote(
      summary: json['summary'] as String? ?? '',
      keyPoints: list('keyPoints'),
      terms: list('terms'),
      examHints: list('examHints'),
      questions: list('questions'),
    );
  }

  String toMarkdown() {
    String section(String title, List<String> items) {
      if (items.isEmpty) return '';
      return '## $title\n' + items.map((e) => '- $e').join('\n') + '\n\n';
    }

    final sb = StringBuffer();
    sb.writeln('# 课堂笔记\n');
    if (summary.isNotEmpty) sb.writeln('$summary\n');
    sb.write(section('要点', keyPoints));
    sb.write(section('术语', terms));
    sb.write(section('考点', examHints));
    sb.write(section('疑问', questions));
    return sb.toString();
  }
}
