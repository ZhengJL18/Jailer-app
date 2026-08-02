import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/tools/registry.dart';

void main() {
  group('ToolRegistry.register/getEntry', () {
    test('register 存入条目并填充默认 description', () {
      registry.register(
        name: 'test_echo',
        toolset: 'file',
        schema: {
          'type': 'object',
          'properties': {'text': {'type': 'string'}},
        },
        handler: (args, [kwargs]) => toolResult({'echo': args['text']}),
      );
      final entry = registry.getEntry('test_echo');
      expect(entry, isNotNull);
      expect(entry!.toolset, 'file');
      expect(entry.description, isEmpty);
    });

    test('description 为空时回退 schema.description', () {
      registry.register(
        name: 'test_desc',
        toolset: 'file',
        schema: {
          'type': 'object',
          'description': '从 schema 取描述',
          'properties': {},
        },
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      expect(registry.getEntry('test_desc')!.description, '从 schema 取描述');
    });
  });

  group('register shadow 保护', () {
    test('跨 toolset 注册不传 override 时静默拒绝', () {
      registry.register(
        name: 'test_shadow',
        toolset: 'file',
        schema: {
          'type': 'object',
          'properties': {},
        },
        handler: (args, [kwargs]) => toolResult({'ok': 'file'}),
      );
      // 同 toolset 覆盖允许
      registry.register(
        name: 'test_shadow',
        toolset: 'file',
        schema: {
          'type': 'object',
          'properties': {},
        },
        handler: (args, [kwargs]) => toolResult({'ok': 'file2'}),
      );
      expect(registry.getEntry('test_shadow'), isNotNull);

      // 跨 toolset 且无 override → 拒绝，保留原条目
      registry.register(
        name: 'test_shadow',
        toolset: 'web',
        schema: {
          'type': 'object',
          'properties': {},
        },
        handler: (args, [kwargs]) => toolResult({'ok': 'web'}),
      );
      expect(registry.getEntry('test_shadow')!.toolset, 'file');

      // override=true 才允许跨 toolset 替换
      registry.register(
        name: 'test_shadow',
        toolset: 'web',
        schema: {
          'type': 'object',
          'properties': {},
        },
        handler: (args, [kwargs]) => toolResult({'ok': 'web2'}),
        override: true,
      );
      expect(registry.getEntry('test_shadow')!.toolset, 'web');
    });
  });

  group('getDefinitions', () {
    test('check_fn 过滤：失败的工具不暴露', () {
      registry.register(
        name: 'test_unavail',
        toolset: 'terminal',
        schema: {
          'type': 'object',
          'properties': {},
        },
        checkFn: () => false,
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      registry.register(
        name: 'test_avail',
        toolset: 'terminal',
        schema: {
          'type': 'object',
          'properties': {},
        },
        checkFn: () => true,
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      final defs = registry.getDefinitions({'test_unavail', 'test_avail'});
      expect(defs.length, 1);
      expect((defs.first['function'] as Map)['name'], 'test_avail');
    });

    test('check_fn TTL 缓存：同函数一次调用多次复用', () {
      var calls = 0;
      bool Function() probe() {
        return () {
          calls++;
          return true;
        };
      }

      registry.register(
        name: 'test_cache',
        toolset: 'file',
        schema: {
          'type': 'object',
          'properties': {},
        },
        checkFn: probe(),
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      registry.getDefinitions({'test_cache'});
      registry.getDefinitions({'test_cache'});
      expect(calls, 1, reason: 'TTL 缓存应避免重复探测');
    });

    test('dynamic_schema_overrides 在 getDefinitions 时合并', () {
      registry.register(
        name: 'test_dyn',
        toolset: 'file',
        schema: {
          'type': 'object',
          'properties': {},
        },
        dynamicSchemaOverrides: () => {'description': '动态描述'},
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      final defs = registry.getDefinitions({'test_dyn'});
      final fn = defs.first['function'] as Map;
      expect(fn['description'], '动态描述');
    });
  });

  group('dispatch', () {
    test('同步 handler 返回 toolResult JSON', () async {
      registry.register(
        name: 'test_dispatch',
        toolset: 'file',
        schema: {
          'type': 'object',
          'properties': {},
        },
        handler: (args, [kwargs]) => toolResult({'echo': args['v']}),
      );
      final result = await registry.dispatch('test_dispatch', {'v': 42});
      expect(result, '{"echo":42}');
    });

    test('异步 handler 被 await', () async {
      registry.register(
        name: 'test_async_handler',
        toolset: 'file',
        schema: {
          'type': 'object',
          'properties': {},
        },
        isAsync: true,
        handler: (args, [kwargs]) async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return toolResult({'async': true});
        },
      );
      final result = await registry.dispatch('test_async_handler', {});
      expect(result, '{"async":true}');
    });

    test('未知工具返回 error JSON', () async {
      final result = await registry.dispatch('no_such_tool', {});
      expect(result, '{"error":"Unknown tool: no_such_tool"}');
    });

    test('handler 抛异常 → 返回 sanitized error JSON', () async {
      registry.register(
        name: 'test_boom',
        toolset: 'file',
        schema: {
          'type': 'object',
          'properties': {},
        },
        handler: (args, [kwargs]) {
          throw StateError('boom');
        },
      );
      final result = await registry.dispatch('test_boom', {});
      // 注意：Dart 异常 toString 带类型前缀（StateError → 'Bad state: boom'），
      // 与 Python str(e)（'boom'）不同 —— 语言差异，消息结构保持一致。
      expect(
        result as String,
        contains('Tool execution failed:'),
      );
      expect((jsonDecode(result) as Map)['error'], contains('boom'));
    });

    test('handler 返回非法类型 → tool_result_contract error', () async {
      registry.register(
        name: 'test_bad_type',
        toolset: 'file',
        schema: {
          'type': 'object',
          'properties': {},
        },
        handler: (args, [kwargs]) => 123,
      );
      final result = await registry.dispatch('test_bad_type', {});
      final map = jsonDecode(result as String) as Map;
      expect(map['error_type'], 'tool_result_contract');
      expect(map['result_type'], 'int');
    });
  });

  group('toolset 查询', () {
    test('getToolToToolsetMap / isToolsetAvailable / checkToolAvailability', () {
      final map = registry.getToolToToolsetMap();
      expect(map['test_echo'], 'file');

      expect(registry.isToolsetAvailable('file'), isTrue);
      expect(registry.isToolsetAvailable('no_such_ts'), isFalse);

      final (available, _) = registry.checkToolAvailability();
      expect(available, contains('file'));

      final reqs = registry.checkToolsetRequirements();
      expect(reqs['file'], isTrue);
    });

    test('requires_env 聚合进 getToolsetRequirements', () {
      registry.register(
        name: 'test_env',
        toolset: 'web',
        schema: {
          'type': 'object',
          'properties': {},
        },
        requiresEnv: ['API_KEY'],
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      final reqs = registry.getToolsetRequirements();
      expect(reqs['web']!['env_vars'], ['API_KEY']);
      expect(reqs['web']!['tools'], contains('test_env'));
    });
  });

  group('toolError/toolResult', () {
    test('toolError 构造 error JSON', () {
      expect(toolError('file not found'), '{"error":"file not found"}');
      expect(
        toolError('bad input', extra: {'success': false}),
        '{"error":"bad input","success":false}',
      );
    });

    test('toolResult 接受 dict 或 kwargs', () {
      expect(toolResult({'success': true, 'count': 42}),
          '{"success":true,"count":42}');
      expect(toolResult(null, {'key': 'value'}), '{"key":"value"}');
    });
  });

  group('deregister', () {
    test('deregister 移除工具并清理 toolset 检查', () {
      registry.register(
        name: 'test_dereg',
        toolset: 'memory',
        schema: {
          'type': 'object',
          'properties': {},
        },
        checkFn: () => true,
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      expect(registry.getEntry('test_dereg'), isNotNull);
      registry.deregister('test_dereg');
      expect(registry.getEntry('test_dereg'), isNull);
      expect(registry.getToolToToolsetMap().containsKey('test_dereg'), isFalse);
    });
  });

  group('generation', () {
    test('每次变更代数递增', () {
      final before = registry.generation;
      registry.register(
        name: 'test_gen',
        toolset: 'file',
        schema: {
          'type': 'object',
          'properties': {},
        },
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      expect(registry.generation, greaterThan(before));
    });
  });
}
