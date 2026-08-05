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
        version: 2,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE lecture_sessions (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              audio_path TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              status TEXT NOT NULL,
              subject_id TEXT,
              duration_sec INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE lecture_subjects (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE lecture_hotwords (
              subject_id TEXT NOT NULL,
              word TEXT NOT NULL,
              PRIMARY KEY (subject_id, word)
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
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 2) {
            await db.execute(
                'ALTER TABLE lecture_sessions ADD COLUMN subject_id TEXT');
            await db.execute(
                'ALTER TABLE lecture_sessions ADD COLUMN duration_sec INTEGER NOT NULL DEFAULT 0');
            await db.execute('''
              CREATE TABLE lecture_subjects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                created_at INTEGER NOT NULL
              )
            ''');
            await db.execute('''
              CREATE TABLE lecture_hotwords (
                subject_id TEXT NOT NULL,
                word TEXT NOT NULL,
                PRIMARY KEY (subject_id, word)
              )
            ''');
          }
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
      'subject_id': session.subjectId,
      'duration_sec': session.durationSec,
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
    return rows.map(_sessionFromRow).toList();
  }

  LectureSession _sessionFromRow(Map<String, dynamic> r) {
    return LectureSession(
      id: r['id'] as String,
      title: r['title'] as String,
      audioPath: r['audio_path'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      status: LectureStatus.values.firstWhere(
        (s) => s.name == r['status'],
        orElse: () => LectureStatus.recorded,
      ),
      subjectId: r['subject_id'] as String?,
      durationSec: (r['duration_sec'] as int? ?? 0),
    );
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

  // ── 科目 ──────────────────────────────────────────────

  /// 列出全部科目（含各自热词库）。
  Future<List<LectureSubject>> listSubjects() async {
    final db = await _open();
    final rows = await db.query('lecture_subjects', orderBy: 'created_at ASC');
    final out = <LectureSubject>[];
    for (final r in rows) {
      final sid = r['id'] as String;
      final hot = await db.query('lecture_hotwords',
          where: 'subject_id = ?', whereArgs: [sid]);
      out.add(LectureSubject(
        id: sid,
        name: r['name'] as String,
        hotwords: hot.map((h) => h['word'] as String).toList(),
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      ));
    }
    return out;
  }

  /// 新建科目（name 去重，已存在则返回现有）。
  Future<LectureSubject> createSubject(String name) async {
    final db = await _open();
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('科目名不能为空');
    final existing = await db.query('lecture_subjects',
        where: 'name = ?', whereArgs: [trimmed]);
    if (existing.isNotEmpty) {
      return (await listSubjects()).firstWhere((s) => s.id == existing.first['id']);
    }
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    await db.insert('lecture_subjects', {
      'id': id,
      'name': trimmed,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    return LectureSubject(
        id: id, name: trimmed, hotwords: const [], createdAt: DateTime.now());
  }

  /// 重命名科目。
  Future<void> renameSubject(String id, String newName) async {
    final db = await _open();
    await db.update('lecture_subjects', {'name': newName.trim()},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 删除科目（热词一并删除，会话保留但不属于任何科目）。
  Future<void> deleteSubject(String id) async {
    final db = await _open();
    await db.delete('lecture_hotwords',
        where: 'subject_id = ?', whereArgs: [id]);
    await db.delete('lecture_subjects', where: 'id = ?', whereArgs: [id]);
  }

  // ── 热词 ──────────────────────────────────────────────

  /// 往科目热词库添加热词（去重）。
  Future<void> addHotword(String subjectId, String word) async {
    final db = await _open();
    final w = word.trim();
    if (w.isEmpty) return;
    await db.insert('lecture_hotwords', {
      'subject_id': subjectId,
      'word': w,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// 批量添加热词（去重，返回实际新增数）。
  Future<int> addHotwords(String subjectId, List<String> words) async {
    var added = 0;
    for (final w in words) {
      if (w.trim().isEmpty) continue;
      final res = await _addHotwordReturn(subjectId, w);
      if (res) added++;
    }
    return added;
  }

  Future<bool> _addHotwordReturn(String subjectId, String word) async {
    final db = await _open();
    final w = word.trim();
    if (w.isEmpty) return false;
    final before = await db.query('lecture_hotwords',
        where: 'subject_id = ? AND word = ?', whereArgs: [subjectId, w]);
    if (before.isNotEmpty) return false;
    await db.insert('lecture_hotwords', {
      'subject_id': subjectId,
      'word': w,
    });
    return true;
  }

  /// 移除科目热词。
  Future<void> removeHotword(String subjectId, String word) async {
    final db = await _open();
    await db.delete('lecture_hotwords',
        where: 'subject_id = ? AND word = ?', whereArgs: [subjectId, word]);
  }

  // ── 录音管理 ──────────────────────────────────────────

  /// 列出全部录音（含转写状态），按时间倒序。
  Future<List<RecordingInfo>> listRecordings() async {
    final db = await _open();
    final sessions =
        await db.query('lecture_sessions', orderBy: 'created_at DESC');
    final notes = await db.query('lecture_notes');
    final noteIds = notes.map((n) => n['session_id'] as String).toSet();
    return sessions
        .map((r) {
          final s = _sessionFromRow(r);
          return RecordingInfo(
            sessionId: s.id,
            title: s.title,
            audioPath: s.audioPath,
            createdAt: s.createdAt,
            durationSec: s.durationSec,
            hasTranscript: noteIds.contains(s.id) ||
                s.status == LectureStatus.done,
          );
        })
        .toList();
  }

  /// 重命名会话标题。
  Future<void> renameSession(String sessionId, String newTitle) async {
    final db = await _open();
    await db.update('lecture_sessions', {'title': newTitle.trim()},
        where: 'id = ?', whereArgs: [sessionId]);
  }

  /// 把会话归入某科目。
  Future<void> setSessionSubject(String sessionId, String? subjectId) async {
    final db = await _open();
    await db.update('lecture_sessions', {'subject_id': subjectId},
        where: 'id = ?', whereArgs: [sessionId]);
  }

  /// 更新某会话笔记（编辑后保存）。
  Future<void> updateNote(String sessionId, LectureNote note) async {
    final db = await _open();
    await db.insert('lecture_notes', {
      'session_id': sessionId,
      'summary': note.summary,
      'key_points': jsonEncode(note.keyPoints),
      'terms': jsonEncode(note.terms),
      'exam_hints': jsonEncode(note.examHints),
      'questions': jsonEncode(note.questions),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
