import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/db/session_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late SessionDB db;

  setUpAll(() {
    sqfliteFfiInit();
    sessionDbFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('jailer_sess_test_');
    db = SessionDB(dbPath: '${tmp.path}/state.db');
    await db.init();
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('createSession', () {
    test('创建会话', () async {
      await db.createSession('s1', source: 'test');
      final sess = await db.getSession('s1');
      expect(sess, isNotNull);
      expect(sess!['source'], 'test');
      expect(sess['message_count'], 0);
    });
  });

  group('appendMessage / getMessages', () {
    test('追加并读取消息', () async {
      await db.createSession('s1', source: 'test');
      final id = await db.appendMessage(
        's1',
        role: 'user',
        content: '你好',
      );
      expect(id, greaterThan(0));
      await db.appendMessage(
        's1',
        role: 'assistant',
        content: '回答',
      );
      final messages = await db.getMessages('s1');
      expect(messages.length, 2);
      expect(messages[0]['role'], 'user');
      expect(messages[0]['content'], '你好');
      expect(messages[1]['role'], 'assistant');
    });

    test('tool_calls JSON 解析', () async {
      await db.createSession('s1', source: 'test');
      await db.appendMessage(
        's1',
        role: 'assistant',
        content: null,
        toolCalls: '[{"id":"c1","function":{"name":"read_file"}}]',
      );
      final messages = await db.getMessages('s1');
      expect(messages.first['tool_calls'], isA<List>());
      expect((messages.first['tool_calls'] as List).first['id'], 'c1');
    });

    test('计数递增', () async {
      await db.createSession('s1', source: 'test');
      await db.appendMessage('s1', role: 'user', content: 'a');
      await db.appendMessage('s1', role: 'tool', toolName: 'read_file');
      final sess = await db.getSession('s1');
      expect(sess!['message_count'], 2);
      expect(sess['tool_call_count'], 1);
    });
  });

  group('endSession / reopenSession', () {
    test('结束和重开', () async {
      await db.createSession('s1', source: 'test');
      await db.endSession('s1');
      var sess = await db.getSession('s1');
      expect(sess!['ended_at'], isNotNull);
      await db.reopenSession('s1');
      sess = await db.getSession('s1');
      expect(sess!['ended_at'], isNull);
    });
  });

  group('searchMessages', () {
    test('FTS5 搜索命中', () async {
      await db.createSession('s1', source: 'test');
      await db.appendMessage('s1', role: 'user', content: 'Hello world flutter');
      await db.appendMessage('s1', role: 'assistant', content: 'Reply about dart');
      final results = await db.searchMessages('flutter');
      expect(results, isNotEmpty);
      expect(results.first['content'], contains('Hello world'));
    });

    test('中文 LIKE 兜底', () async {
      await db.createSession('s1', source: 'test');
      await db.appendMessage('s1', role: 'user', content: '今天天气很好');
      final results = await db.searchMessages('天气');
      expect(results, isNotEmpty);
      expect(results.first['content'], contains('今天天气很好'));
    });

    test('role 过滤', () async {
      await db.createSession('s1', source: 'test');
      await db.appendMessage('s1', role: 'user', content: 'question about sqlite');
      await db.appendMessage('s1', role: 'assistant', content: 'answer about sqlite');
      final userOnly = await db.searchMessages('sqlite', roleFilter: 'user');
      expect(userOnly.length, 1);
      expect(userOnly.first['role'], 'user');
    });
  });

  group('listSessions', () {
    test('按时间倒序', () async {
      await db.createSession('s1', source: 'test');
      await Future.delayed(const Duration(milliseconds: 10));
      await db.createSession('s2', source: 'test');
      final sessions = await db.listSessions();
      expect(sessions.first['id'], 's2');
      expect(sessions.length, 2);
    });
  });
}
