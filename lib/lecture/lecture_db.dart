/// 课堂笔记本地库（SQLite）。
///
/// Windows 桌面用 sqflite_common_ffi；手机用默认 sqflite。存储会话、
/// 转写段、DeepSeek 笔记三类数据。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models.dart';

/// 课堂笔记数据库单例。
class LectureDb {
  LectureDb._();

  static final LectureDb instance = LectureDb._();

  Database? _db;

  /// 打开数据库（首次调用创建表）。Windows 走 ffi 工厂。
  Future<Database> _open() async {
    if (_db != null) return _db!;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final docs = await getApplicationDocumentsDirectory();
    final path = p.join(docs.path, 'lecture.db');
    _db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE lecture_sessions (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              audio_path TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              status TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE lecture_segments (
              session_id TEXT NOT NULL,
              speaker INTEGER NOT NULL,
              start_ms REAL NOT NULL,
              end_ms REAL NOT NULL,
              text TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE lecture_notes (
              session_id TEXT PRIMARY KEY,
              summary TEXT,
              key_points TEXT,
              terms TEXT,
              exam_hints TEXT,
              questions TEXT
            )
          ''');
        },
      ),
    );
    return _db!;
  }

  /// 保存一次完整会话（会话 + 段 + 可选笔记）。
  Future<void> saveSession({
    required LectureSession session,
    List<TranscriptSegment>? segments,
    LectureNote? note,
  }) async {
    final db = await _open();
    await db.insert('lecture_sessions', {
      'id': session.id,
      'title': session.title,
      'audio_path': session.audioPath,
      'created_at': session.createdAt.millisecondsSinceEpoch,
      'status': session.status.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (segments != null) {
      await db.delete('lecture_segments',
          where: 'session_id = ?', whereArgs: [session.id]);
      final batch = db.batch();
      for (final s in segments) {
        batch.insert('lecture_segments', {
          'session_id': session.id,
          'speaker': s.speaker,
          'start_ms': s.startMs,
          'end_ms': s.endMs,
          'text': s.text,
        });
      }
      await batch.commit(noResult: true);
    }
    if (note != null) {
      await db.insert('lecture_notes', {
        'session_id': session.id,
        'summary': note.summary,
        'key_points': jsonEncode(note.keyPoints),
        'terms': jsonEncode(note.terms),
        'exam_hints': jsonEncode(note.examHints),
        'questions': jsonEncode(note.questions),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// 更新会话状态。
  Future<void> updateSessionStatus(String id, LectureStatus status) async {
    final db = await _open();
    await db.update('lecture_sessions', {'status': status.name},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 按时间倒序列出全部会话。
  Future<List<LectureSession>> listSessions() async {
    final db = await _open();
    final rows = await db.query('lecture_sessions', orderBy: 'created_at DESC');
    return rows
        .map((r) => LectureSession(
              id: r['id'] as String,
              title: r['title'] as String,
              audioPath: r['audio_path'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(
                  r['created_at'] as int),
              status: LectureStatus.values.firstWhere(
                (s) => s.name == r['status'],
                orElse: () => LectureStatus.recorded,
              ),
            ))
        .toList();
  }

  /// 读取某会话的转写段。
  Future<List<TranscriptSegment>> segmentsFor(String sessionId) async {
    final db = await _open();
    final rows = await db.query('lecture_segments',
        where: 'session_id = ?',
        whereArgs: [sessionId],
        orderBy: 'start_ms ASC');
    return rows
        .map((r) => TranscriptSegment(
              speaker: r['speaker'] as int,
              startMs: (r['start_ms'] as num).toDouble(),
              endMs: (r['end_ms'] as num).toDouble(),
              text: r['text'] as String,
            ))
        .toList();
  }

  /// 读取某会话的笔记。
  Future<LectureNote?> noteFor(String sessionId) async {
    final db = await _open();
    final rows = await db.query('lecture_notes',
        where: 'session_id = ?', whereArgs: [sessionId]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    List<String> list(String key) =>
        (jsonDecode(r[key] as String? ?? '[]') as List)
            .map((e) => e.toString())
            .toList();
    return LectureNote(
      summary: r['summary'] as String? ?? '',
      keyPoints: list('key_points'),
      terms: list('terms'),
      examHints: list('exam_hints'),
      questions: list('questions'),
    );
  }

  /// 删除会话（含段与笔记）。
  Future<void> deleteSession(String sessionId) async {
    final db = await _open();
    await db.delete('lecture_segments',
        where: 'session_id = ?', whereArgs: [sessionId]);
    await db.delete('lecture_notes',
        where: 'session_id = ?', whereArgs: [sessionId]);
    await db.delete('lecture_sessions',
        where: 'id = ?', whereArgs: [sessionId]);
  }
}
