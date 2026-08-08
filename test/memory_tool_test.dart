import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/tools/memory_manager.dart';
import 'package:mix/tools/memory_tool.dart';

void main() {
  late Directory tmp;
  late MemoryStore store;
  late MemoryManager manager;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jailer_mem_test_');
    store = MemoryStore(baseDir: tmp.path);
    manager = MemoryManager(store: store);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('MemoryStore add/replace/remove', () {
    test('add appends entry', () {
      final result = store.add('memory', '用户喜欢简洁的回答');
      expect(result['success'], true);
      expect(store.memoryEntries, ['用户喜欢简洁的回答']);
    });

    test('add rejects duplicate', () {
      store.add('memory', '事实A');
      final result = store.add('memory', '事实A');
      expect(result['success'], true);
      expect(store.memoryEntries.length, 1);
    });

    test('add rejects empty', () {
      final result = store.add('memory', '   ');
      expect(result['success'], false);
    });

    test('add enforces char limit', () {
      final tiny = MemoryStore(baseDir: tmp.path, memoryCharLimit: 10);
      final result = tiny.add('memory', '这是一个很长的超过限制的条目内容');
      expect(result['success'], false);
      expect(result['error'], contains('exceed'));
    });

    test('replace edits matching entry', () {
      store.add('memory', '旧事实');
      final result = store.replace('memory', '旧事实', '新事实');
      expect(result['success'], true);
      expect(store.memoryEntries, ['新事实']);
    });

    test('replace no match', () {
      store.add('memory', '存在');
      final result = store.replace('memory', '不存在', '新');
      expect(result['success'], false);
    });

    test('remove deletes matching entry', () {
      store.add('memory', '要删的');
      final result = store.remove('memory', '要删的');
      expect(result['success'], true);
      expect(store.memoryEntries, isEmpty);
    });

    test('user target separate from memory', () {
      store.add('user', '用户资料');
      expect(store.userEntries, ['用户资料']);
      expect(store.memoryEntries, isEmpty);
    });
  });

  group('applyBatch', () {
    test('atomic add + remove + replace in one call', () {
      store.add('memory', '旧条目');
      final result = store.applyBatch('memory', [
        {'action': 'remove', 'old_text': '旧条目'},
        {'action': 'add', 'content': '新条目1'},
        {'action': 'add', 'content': '新条目2'},
      ]);
      expect(result['success'], true);
      expect(store.memoryEntries, ['新条目1', '新条目2']);
    });

    test('batch overflow rejects all', () {
      final tiny = MemoryStore(baseDir: tmp.path, memoryCharLimit: 8);
      final result = tiny.applyBatch('memory', [
        {'action': 'add', 'content': '这是第一段内容'},
        {'action': 'add', 'content': '这是第二段也很长的内容'},
      ]);
      expect(result['success'], false);
      expect(tiny.memoryEntries, isEmpty);
    });
  });

  group('持久化', () {
    test('entries survive reload', () {
      store.add('memory', '持久化事实');
      final store2 = MemoryStore(baseDir: tmp.path);
      expect(store2.memoryEntries, ['持久化事实']);
    });
  });

  group('system prompt 注入', () {
    test('buildSystemPromptMemory 用 load 时快照（冻结语义）', () {
      // 先写记忆，再新建 store 模拟下个会话 —— 快照在 load 时冻结。
      store.add('memory', '记住这个');
      store.add('user', '用户喜欢中文');
      final store2 = MemoryStore(baseDir: tmp.path);
      final manager2 = MemoryManager(store: store2);
      final block = manager2.buildSystemPromptMemory();
      expect(block, contains('MEMORY (your personal notes)'));
      expect(block, contains('USER PROFILE'));
      expect(block, contains('记住这个'));
      expect(block, contains('用户喜欢中文'));
    });

    test('本会话 add 后快照不变（prefix cache 稳定）', () {
      final blockBefore = manager.buildSystemPromptMemory();
      store.add('memory', '本会话新写');
      final blockAfter = manager.buildSystemPromptMemory();
      expect(blockBefore, blockAfter, reason: '会话中写入不影响冻结快照');
    });

    test('prefetchAll 返回 load 时快照', () {
      store.add('memory', '记忆X');
      final store2 = MemoryStore(baseDir: tmp.path);
      final manager2 = MemoryManager(store: store2);
      expect(manager2.prefetchAll('任意查询'), contains('记忆X'));
    });
  });

  group('memoryTool 入口', () {
    test('单操作 add', () {
      final result = memoryTool(
        action: 'add',
        target: 'memory',
        content: '新记忆',
        store: store,
      );
      final map = jsonDecode(result) as Map;
      expect(map['success'], true);
    });

    test('批处理 operations', () {
      final result = memoryTool(
        operations: [
          {'action': 'add', 'content': '批量记忆'},
        ],
        store: store,
      );
      final map = jsonDecode(result) as Map;
      expect(map['success'], true);
      expect(store.memoryEntries, ['批量记忆']);
    });

    test('无效 action', () {
      final result = memoryTool(action: 'foo', store: store);
      expect(result, contains('Unknown action'));
    });
  });
}
