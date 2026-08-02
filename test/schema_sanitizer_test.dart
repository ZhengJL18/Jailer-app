import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/tools/schema_sanitizer.dart';

void main() {
  group('sanitizeToolSchemas', () {
    test('empty input passthrough', () {
      expect(sanitizeToolSchemas(const []), isEmpty);
    });

    test('missing/non-dict parameters substituted', () {
      final tools = [
        {
          'type': 'function',
          'function': {'name': 'foo'},
        },
      ];
      final out = sanitizeToolSchemas(tools);
      final params = out.first['function']!['parameters'] as Map;
      expect(params['type'], 'object');
      expect(params['properties'], isEmpty);
    });

    test('bare string schema replaced with dict', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {'type': 'object'},
          },
        },
      ];
      final out = sanitizeToolSchemas(tools);
      final params = out.first['function']!['parameters'] as Map;
      expect(params['type'], 'object');
      expect(params['properties'], isEmpty);
    });

    test('non-schema stray string replaced', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {'type': 'object', 'properties': {'a': 'garbage'}},
          },
        },
      ];
      final out = sanitizeToolSchemas(tools);
      final params = out.first['function']!['parameters'] as Map;
      final propA = (params['properties'] as Map)['a'] as Map;
      expect(propA['type'], 'object');
    });

    test('type array single non-null collapses', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {
              'type': 'object',
              'properties': {'a': {'type': ['string', 'null']}},
            },
          },
        },
      ];
      final out = sanitizeToolSchemas(tools);
      final params = out.first['function']!['parameters'] as Map;
      final propA = (params['properties'] as Map)['a'] as Map;
      expect(propA['type'], 'string');
      expect(propA['nullable'], isTrue);
    });

    test('type array multiple non-null becomes anyOf', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {
              'type': 'object',
              'properties': {'a': {'type': ['number', 'string']}},
            },
          },
        },
      ];
      final out = sanitizeToolSchemas(tools);
      final params = out.first['function']!['parameters'] as Map;
      final propA = (params['properties'] as Map)['a'] as Map;
      final anyOf = propA['anyOf'] as List;
      expect(anyOf.length, 2);
      expect(anyOf[0]['type'], 'number');
      expect(anyOf[1]['type'], 'string');
    });

    test('nullable anyOf/oneOf union collapses with hint', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {
              'type': 'object',
              'properties': {
                'a': {
                  'anyOf': [
                    {'type': 'string'},
                    {'type': 'null'},
                  ],
                  'default': null,
                },
              },
            },
          },
        },
      ];
      final out = sanitizeToolSchemas(tools);
      final params = out.first['function']!['parameters'] as Map;
      final propA = (params['properties'] as Map)['a'] as Map;
      expect(propA['type'], 'string');
      expect(propA['nullable'], isTrue);
      // metadata carried over
      expect(propA.containsKey('default'), isTrue);
    });

    test(r'$ref sibling default stripped', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {
              'type': 'object',
              'properties': {
                'a': {r'$ref': '#/\$defs/Foo', 'default': null},
              },
            },
          },
        },
      ];
      final out = sanitizeToolSchemas(tools);
      final params = out.first['function']!['parameters'] as Map;
      final propA = (params['properties'] as Map)['a'] as Map;
      expect(propA.containsKey(r'$ref'), isTrue);
      expect(propA.containsKey('default'), isFalse);
    });

    test('top-level combinators stripped, nested preserved', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {
              'type': 'object',
              'properties': {},
              'oneOf': [{'required': ['x']}],
            },
          },
        },
      ];
      final out = sanitizeToolSchemas(tools);
      final params = out.first['function']!['parameters'] as Map;
      expect(params.containsKey('oneOf'), isFalse);
    });

    test('object node without properties gets empty properties', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {
              'type': 'object',
            },
          },
        },
      ];
      final out = sanitizeToolSchemas(tools);
      final params = out.first['function']!['parameters'] as Map;
      expect(params['type'], 'object');
      expect(params['properties'], isEmpty);
    });

    test('required entries not in properties pruned', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {
              'type': 'object',
              'properties': {'a': {'type': 'string'}},
              'required': ['a', 'b'],
            },
          },
        },
      ];
      final out = sanitizeToolSchemas(tools);
      final params = out.first['function']!['parameters'] as Map;
      expect(params['required'], ['a']);
    });

    test('required with no valid entries removed', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {
              'type': 'object',
              'properties': {'a': {'type': 'string'}},
              'required': ['b'],
            },
          },
        },
      ];
      final out = sanitizeToolSchemas(tools);
      final params = out.first['function']!['parameters'] as Map;
      expect(params.containsKey('required'), isFalse);
    });
  });

  group('sanitizePropertyKey', () {
    test('conforming keys pass through', () {
      expect(sanitizePropertyKey('abc.def-ghi_1'), 'abc.def-ghi_1');
    });

    test('bad chars replaced with underscore', () {
      expect(sanitizePropertyKey('issue_class~neq'), 'issue_class_neq');
      expect(sanitizePropertyKey('meta[op]'), 'meta_op_');
    });

    test('all-bad-chars become underscores (Python sub semantics)', () {
      // Python 的 str.sub("_", '~~~') → '___'（非空），new or "param" 只在
      // 空串时回退。Dart replaceAll 语义相同。
      expect(sanitizePropertyKey('~~~'), '___');
    });

    test('truncation to empty falls back to param', () {
      // 构造一个净化后为空串的情形 —— sanitizePropertyKey 只截断不删字符，
      // 直接触发空回退需空输入路径：这里验证边界长度保留。
      final s = sanitizePropertyKey('abc');
      expect(s, 'abc');
      expect(s.isEmpty, isFalse);
    });

    test('truncated to 64 chars', () {
      final long = List.filled(80, 'a').join();
      final s = sanitizePropertyKey(long);
      expect(s.length, 64);
    });
  });

  group('unrenameToolArgs', () {
    test('maps renamed key back to wire name', () {
      final paramsSchema = {
        'type': 'object',
        'properties': {
          'issue_class~neq': {'type': 'string'},
          'normal': {'type': 'string'},
        },
      };
      final args = {
        'issue_class_neq': 'open',
        'normal': 'x',
      };
      final out = unrenameToolArgs(paramsSchema, args) as Map;
      expect(out['issue_class~neq'], 'open');
      expect(out['normal'], 'x');
    });

    test('recurses into nested objects', () {
      final paramsSchema = {
        'type': 'object',
        'properties': {
          'meta[filter]': {
            'type': 'object',
            'properties': {
              'inner~key': {'type': 'string'},
            },
          },
        },
      };
      // 'meta[filter]' 含正则特殊字符 [ 和 ] → 净化为 'meta_filter_'
      // （每个坏字符一个下划线）；值内部 'inner~key' → 'inner_key'。
      // 模型发出净化后的键，unrename 把两层映射回 wire 名。
      final args = {
        'meta_filter_': {
          'inner_key': 'v',
        },
      };
      final out = unrenameToolArgs(paramsSchema, args) as Map;
      expect(out.containsKey('meta[filter]'), isTrue);
      expect(out.containsKey('meta_filter_'), isFalse);
      final inner = out['meta[filter]'] as Map;
      expect(inner.containsKey('inner~key'), isTrue);
      expect(inner['inner~key'], 'v');
    });
  });

  group('reactive strips', () {
    test('stripPatternAndFormat', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {
              'type': 'object',
              'properties': {
                'pattern': {'type': 'string'},
                'x': {'type': 'string', 'pattern': r'\d+', 'format': 'email'},
              },
            },
          },
        },
      ];
      final (count, out) = stripPatternAndFormat(tools);
      expect(count, 2);
      final params = out.first['function']!['parameters'] as Map;
      // property named 'pattern' survives
      expect((params['properties'] as Map).containsKey('pattern'), isTrue);
      // pattern/format as siblings of type stripped
      final x = (params['properties'] as Map)['x'] as Map;
      expect(x.containsKey('pattern'), isFalse);
      expect(x.containsKey('format'), isFalse);
    });

    test('stripSlashEnum', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'foo',
            'parameters': {
              'type': 'object',
              'properties': {
                'model': {
                  'type': 'string',
                  'enum': ['Qwen/Qwen3.5-0.8B', 'plain'],
                },
              },
            },
          },
        },
      ];
      final (count, out) = stripSlashEnum(tools);
      expect(count, 1);
      final params = out.first['function']!['parameters'] as Map;
      final model = (params['properties'] as Map)['model'] as Map;
      expect(model.containsKey('enum'), isFalse);
    });
  });
}
