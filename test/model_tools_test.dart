import 'package:flutter_test/flutter_test.dart';
import 'package:mix/tools/model_tools.dart';
import 'package:mix/tools/registry.dart';

void main() {
  setUp(() {
    // 测试用工具注册到 file toolset。schema 结构与 Hermes 一致：
    // {name, description, parameters: {type, properties, required}}。
    registry.register(
      name: 'read_file',
      toolset: 'file',
      schema: {
        'name': 'read_file',
        'description': 'Read a file',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'limit': {'type': 'integer'},
          },
          'required': ['path'],
        },
      },
      handler: (args, [kwargs]) => toolResult({'ok': true}),
    );
    registry.register(
      name: 'write_file',
      toolset: 'file',
      schema: {
        'name': 'write_file',
        'description': 'Write a file',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'content': {'type': 'string'},
          },
          'required': ['path', 'content'],
        },
      },
      handler: (args, [kwargs]) => toolResult({'ok': true}),
    );
  });

  group('getToolDefinitions', () {
    test('enabled file toolset returns only file tools', () {
      final defs = getToolDefinitions(
        enabledToolsets: ['file'],
        quietMode: true,
      );
      final names = defs.map((d) => (d['function'] as Map)['name']).toSet();
      expect(names, contains('read_file'));
      expect(names, contains('write_file'));
      expect(names, isNot(contains('web_search')));
      // schema 有 name 字段 + type function
      expect(defs.first['type'], 'function');
      expect((defs.first['function'] as Map).containsKey('name'), isTrue);
    });

    test('disabled toolset strips tools', () {
      final defs = getToolDefinitions(
        enabledToolsets: ['file', 'web'],
        disabledToolsets: ['file'],
        quietMode: true,
      );
      final names = defs.map((d) => (d['function'] as Map)['name']).toSet();
      expect(names, isNot(contains('read_file')));
    });

    test('default (no toolsets) includes file tools', () {
      final defs = getToolDefinitions(quietMode: true);
      final names = defs.map((d) => (d['function'] as Map)['name']).toSet();
      expect(names, contains('read_file'));
    });

    test('quiet_mode cache returns same result', () {
      final a = getToolDefinitions(enabledToolsets: ['file'], quietMode: true);
      final b = getToolDefinitions(enabledToolsets: ['file'], quietMode: true);
      expect(a, b);
    });
  });

  group('coerceToolArgs', () {
    test('coerces string number to int', () {
      final args = coerceToolArgs('read_file', {'path': 'x', 'limit': '42'});
      expect(args!['limit'], 42);
    });

    test('coerces string boolean', () {
      registry.register(
        name: 'bool_tool',
        toolset: 'file',
        schema: {
          'name': 'bool_tool',
          'parameters': {
            'type': 'object',
            'properties': {
              'flag': {'type': 'boolean'},
            },
          },
        },
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      final args = coerceToolArgs('bool_tool', {'flag': 'true'});
      expect(args!['flag'], true);
    });

    test('wraps bare scalar in list for array type', () {
      registry.register(
        name: 'list_tool',
        toolset: 'file',
        schema: {
          'name': 'list_tool',
          'parameters': {
            'type': 'object',
            'properties': {
              'urls': {'type': 'array', 'items': {'type': 'string'}},
            },
          },
        },
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      final args = coerceToolArgs('list_tool', {'urls': 'https://a.com'});
      expect(args!['urls'], ['https://a.com']);
    });

    test('parses JSON array string', () {
      registry.register(
        name: 'arr_tool',
        toolset: 'file',
        schema: {
          'name': 'arr_tool',
          'parameters': {
            'type': 'object',
            'properties': {
              'list': {'type': 'array', 'items': {'type': 'string'}},
            },
          },
        },
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      final args = coerceToolArgs('arr_tool', {'list': '["a","b"]'});
      expect(args!['list'], ['a', 'b']);
    });

    test('nullable null string becomes null', () {
      registry.register(
        name: 'null_tool',
        toolset: 'file',
        schema: {
          'name': 'null_tool',
          'parameters': {
            'type': 'object',
            'properties': {
              'x': {'type': ['string', 'null']},
            },
          },
        },
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      final args = coerceToolArgs('null_tool', {'x': 'null'});
      expect(args!['x'], isNull);
    });

    test('unknown tool leaves args unchanged', () {
      final args = coerceToolArgs('no_such_tool', {'a': '1'});
      expect(args!['a'], '1');
    });

    test('fails to coerce non-numeric string stays string', () {
      final args = coerceToolArgs('read_file', {'path': 'x', 'limit': 'abc'});
      expect(args!['limit'], 'abc');
    });

    test('coerces nested JSON in array items', () {
      registry.register(
        name: 'nested_tool',
        toolset: 'file',
        schema: {
          'name': 'nested_tool',
          'parameters': {
            'type': 'object',
            'properties': {
              'todos': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'id': {'type': 'integer'},
                    'content': {'type': 'string'},
                  },
                },
              },
            },
          },
        },
        handler: (args, [kwargs]) => toolResult({'ok': true}),
      );
      final args = coerceToolArgs('nested_tool', {
        'todos': ['{"id": "1", "content": "x"}'],
      });
      final list = args!['todos'] as List;
      // Python 语义：嵌套字符串只做 JSON→容器转换，不做字符串→number；
      // id 保持字符串 '1'。
      expect((list.first as Map)['id'], '1');
      expect((list.first as Map)['content'], 'x');
    });
  });

  group('handleFunctionCall', () {
    test('dispatches to registry handler', () async {
      final result = await handleFunctionCall(
        'read_file',
        {'path': 'x', 'limit': '42'},
      );
      expect(result, '{"ok":true}');
    });

    test('unknown tool returns error', () async {
      final result = await handleFunctionCall('no_such_tool', {});
      expect(result, contains('Unknown tool'));
    });
  });
}
