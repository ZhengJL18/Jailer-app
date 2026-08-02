import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/tools/file_tools.dart';
import 'package:jailer/tools/file_safety.dart';
import 'package:jailer/tools/registry.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jailer_ft_test_');
    configureFileTools(cwd: tmp.path);
    registerFileTools();
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('registration', () {
    test('4 file tools registered in file toolset', () {
      expect(registry.getEntry('read_file'), isNotNull);
      expect(registry.getEntry('write_file'), isNotNull);
      expect(registry.getEntry('patch'), isNotNull);
      expect(registry.getEntry('search_files'), isNotNull);
      expect(registry.getToolsetForTool('read_file'), 'file');
    });

    test('schema has name + parameters', () {
      final schema = registry.getSchema('read_file');
      expect(schema!['name'], 'read_file');
      final params = schema['parameters'] as Map;
      expect(params['type'], 'object');
      expect(params['required'], ['path']);
    });
  });

  group('readFileTool', () {
    test('reads with line numbers', () {
      File(p.join(tmp.path, 'a.txt')).writeAsStringSync('x\ny\nz');
      final result = readFileTool(path: 'a.txt');
      final map = jsonDecode(result) as Map;
      expect(map['content'], '1|x\n2|y\n3|z');
      expect(map['total_lines'], 3);
    });

    test('binary extension blocked', () {
      File(p.join(tmp.path, 'img.png')).writeAsStringSync('notreallybinary');
      final result = readFileTool(path: 'img.png');
      expect(result, contains('Cannot read binary file'));
    });

    test('missing file suggests similar', () {
      File(p.join(tmp.path, 'config.yaml')).writeAsStringSync('a');
      final result = readFileTool(path: 'config.yml');
      final map = jsonDecode(result) as Map;
      expect(map['error'], contains('File not found'));
      expect(map['similar_files'], isNotEmpty);
    });

    test('pagination respects offset/limit', () {
      File(p.join(tmp.path, 'n.txt')).writeAsStringSync('1\n2\n3\n4\n5');
      final result = readFileTool(path: 'n.txt', offset: 2, limit: 2);
      final map = jsonDecode(result) as Map;
      expect(map['content'], '2|2\n3|3');
      expect(map['truncated'], true);
    });
  });

  group('writeFileTool', () {
    test('writes and reports absolute path', () {
      final result = writeFileTool(path: 'b.txt', content: 'hello');
      final map = jsonDecode(result) as Map;
      expect(map.containsKey('error'), isFalse);
      expect(map['resolved_path'], endsWith('b.txt'));
      expect(File(p.join(tmp.path, 'b.txt')).readAsStringSync(), 'hello');
    });

    test('blocks sensitive path', () {
      final origHome = hermesHomePathProvider;
      hermesHomePathProvider = () => tmp.path;
      try {
        final result = writeFileTool(path: 'state.db', content: 'x');
        expect(result, contains('denied'));
      } finally {
        hermesHomePathProvider = origHome;
      }
    });

    test('refuses corrupt json via fail-closed gate', () {
      final result = writeFileTool(path: 'bad.json', content: '{oops');
      expect(result, contains('Refusing to write'));
    });

    test('missing content arg', () {
      final result = writeFileTool(path: 'x.txt', content: '');
      // content 参数是 required String，测试直接传空串合法。
      expect(jsonDecode(result)['error'], isNull);
    });
  });

  group('patchTool', () {
    test('replace mode edits file', () {
      File(p.join(tmp.path, 'c.py')).writeAsStringSync('def foo():\n    pass\n');
      final result = patchTool(
        mode: 'replace',
        path: 'c.py',
        oldString: 'def foo():',
        newString: 'def bar():',
      );
      final map = jsonDecode(result) as Map;
      expect(map['success'], true);
      expect(File(p.join(tmp.path, 'c.py')).readAsStringSync(),
          'def bar():\n    pass\n');
      expect(map['diff'], contains('a/c.py'));
    });

    test('v4a patch mode applies', () {
      File(p.join(tmp.path, 'g.py')).writeAsStringSync('x\n');
      final result = patchTool(
        mode: 'patch',
        patch: '*** Begin Patch\n'
            '*** Update File: g.py\n'
            '-x\n'
            '+y\n'
            '*** End Patch\n',
      );
      final map = jsonDecode(result) as Map;
      expect(map['success'], true);
      expect(File(p.join(tmp.path, 'g.py')).readAsStringSync(), 'y\n');
    });

    test('v4a traversal blocked', () {
      final result = patchTool(
        mode: 'patch',
        patch: '*** Begin Patch\n'
            '*** Update File: ../escape.py\n'
            '-x\n'
            '+y\n'
            '*** End Patch\n',
      );
      expect(result, contains('traversal'));
    });

    test('replace missing params', () {
      final result = patchTool(mode: 'replace', path: 'c.py');
      expect(result, contains("mode='replace' requires"));
    });
  });

  group('searchFileTool', () {
    test('content search finds matches', () {
      File(p.join(tmp.path, 's1.txt')).writeAsStringSync('apple\nbanana\n');
      final result = searchFileTool(pattern: 'banana');
      final map = jsonDecode(result) as Map;
      expect(map['total_count'], 1);
      expect(map['matches'].length, 1);
      expect(map['matches'][0]['line'], 2);
    });

    test('files search by glob', () {
      File(p.join(tmp.path, 'a.dart')).writeAsStringSync('x');
      File(p.join(tmp.path, 'b.py')).writeAsStringSync('y');
      final result = searchFileTool(pattern: '*.dart', target: 'files');
      final map = jsonDecode(result) as Map;
      expect(map['files'].length, 1);
      expect(map['files'][0], endsWith('a.dart'));
    });
  });

  group('dispatch via registry', () {
    test('handleFunctionCall dispatches read_file', () async {
      File(p.join(tmp.path, 'd.txt')).writeAsStringSync('hello');
      final result = await registry.dispatch('read_file', {'path': 'd.txt'});
      final map = jsonDecode(result as String) as Map;
      expect(map['content'], '1|hello');
    });

    test('handleFunctionCall dispatches write_file', () async {
      final result = await registry.dispatch(
        'write_file',
        {'path': 'w.txt', 'content': 'data'},
      );
      expect(jsonDecode(result as String)['error'], isNull);
      expect(File(p.join(tmp.path, 'w.txt')).readAsStringSync(), 'data');
    });
  });
}
