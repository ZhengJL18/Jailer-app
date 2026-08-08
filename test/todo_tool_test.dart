import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/tools/todo_tool.dart';

void main() {
  late TodoStore store;

  setUp(() {
    store = TodoStore();
  });

  group('TodoStore write/read', () {
    test('替换模式整个覆盖', () {
      store.write([
        {'id': '1', 'content': '任务A', 'status': 'pending'},
        {'id': '2', 'content': '任务B', 'status': 'in_progress'},
      ]);
      expect(store.read().length, 2);
      // 再写一次替换。
      store.write([
        {'id': '3', 'content': '新任务', 'status': 'pending'},
      ]);
      expect(store.read().length, 1);
      expect(store.read().first['id'], '3');
    });

    test('合并模式按 id 更新', () {
      store.write([
        {'id': '1', 'content': '任务A', 'status': 'pending'},
      ]);
      store.write([
        {'id': '1', 'content': '任务A 更新', 'status': 'completed'},
        {'id': '2', 'content': '新任务', 'status': 'pending'},
      ], merge: true);
      final items = store.read();
      expect(items.length, 2);
      expect(items[0]['status'], 'completed');
      expect(items[0]['content'], '任务A 更新');
      expect(items[1]['id'], '2');
    });

    test('非法状态回退 pending', () {
      store.write([
        {'id': '1', 'content': 'x', 'status': 'weird'},
      ]);
      expect(store.read().first['status'], 'pending');
    });

    test('条数上限', () {
      final items = [
        for (var i = 0; i < 300; i++)
          {'id': '$i', 'content': '任务$i', 'status': 'pending'},
      ];
      store.write(items);
      expect(store.read().length, maxTodoItems);
    });
  });

  group('formatForInjection', () {
    test('只注入 active 项', () {
      store.write([
        {'id': '1', 'content': '进行中', 'status': 'in_progress'},
        {'id': '2', 'content': '已完成', 'status': 'completed'},
        {'id': '3', 'content': '待办', 'status': 'pending'},
      ]);
      final block = store.formatForInjection();
      expect(block, contains('进行中'));
      expect(block, contains('待办'));
      expect(block, isNot(contains('已完成')));
    });

    test('空列表返回 null', () {
      expect(store.formatForInjection(), isNull);
    });
  });

  group('todoTool 入口', () {
    test('读模式返回当前列表 + 统计', () {
      store.write([
        {'id': '1', 'content': 'a', 'status': 'pending'},
        {'id': '2', 'content': 'b', 'status': 'completed'},
      ]);
      final result = todoTool(store: store);
      final map = jsonDecode(result) as Map;
      expect((map['summary'] as Map)['total'], 2);
      expect((map['summary'] as Map)['pending'], 1);
      expect((map['summary'] as Map)['completed'], 1);
    });

    test('写模式', () {
      final result = todoTool(
        todos: [
          {'id': '1', 'content': '新任务', 'status': 'pending'},
        ],
        store: store,
      );
      final map = jsonDecode(result) as Map;
      expect((map['summary'] as Map)['total'], 1);
    });

    test('JSON 字符串 todos 解析', () {
      final result = todoTool(
        todos: ['[{"id":"1","content":"x","status":"pending"}]'],
        store: store,
      );
      final map = jsonDecode(result) as Map;
      expect((map['summary'] as Map)['total'], 1);
    });

    test('未初始化 store 报错', () {
      final result = todoTool(store: null);
      expect(result, contains('not initialized'));
    });
  });
}
