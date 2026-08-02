import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/tools/file_operations.dart';
import 'package:jailer/tools/file_safety.dart';
import 'package:jailer/tools/patch_parser.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late LocalFileOperations ops;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jailer_fo_test_');
    ops = LocalFileOperations(cwd: tmp.path);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('writeFile', () {
    test('creates parent dirs and writes content', () {
      final result = ops.writeFile('a/b/c.txt', 'hello');
      expect(result.error, isNull);
      expect(result.dirsCreated, isTrue);
      expect(File(p.join(tmp.path, 'a/b/c.txt')).readAsStringSync(), 'hello');
      expect(result.bytesWritten, 'hello'.length);
    });

    test('blocks sensitive path (hermes state.db)', () {
      // 黑名单锚定 HERMES_HOME（Python 语义）。把钩子指到 tmp，验证 writeFile
      // 拒绝应用自有状态文件。
      final origHome = hermesHomePathProvider;
      hermesHomePathProvider = () => tmp.path;
      try {
        final result = ops.writeFile('state.db', 'x');
        expect(result.error, isNotNull);
        expect(result.error, contains('denied'));
        expect(File(p.join(tmp.path, 'state.db')).existsSync(), isFalse);
      } finally {
        hermesHomePathProvider = origHome;
      }
    });

    test('JSON write gate refuses corrupt json', () {
      final result = ops.writeFile('config.json', '{broken json');
      expect(result.error, isNotNull);
      expect(result.error, contains('Refusing to write'));
      expect(File(p.join(tmp.path, 'config.json')).existsSync(), isFalse);
    });

    test('valid JSON write passes gate', () {
      final result = ops.writeFile('config.json', '{"a": 1}');
      expect(result.error, isNull);
      expect(File(p.join(tmp.path, 'config.json')).readAsStringSync(), '{"a": 1}');
    });
  });

  group('readFile', () {
    test('pagination adds line numbers', () {
      File(p.join(tmp.path, 'f.txt')).writeAsStringSync('a\nb\nc\nd');
      final r = ops.readFile('f.txt', offset: 1, limit: 2);
      expect(r.error, isNull);
      expect(r.content, '1|a\n2|b');
      expect(r.totalLines, 4);
      expect(r.truncated, isTrue);
      expect(r.hint, contains('offset=3'));
    });

    test('readFileRaw returns full content', () {
      File(p.join(tmp.path, 'f.txt')).writeAsStringSync('x\ny');
      final r = ops.readFileRaw('f.txt');
      expect(r.error, isNull);
      expect(r.content, 'x\ny');
    });

    test('missing file suggests similar', () {
      File(p.join(tmp.path, 'config.yaml')).writeAsStringSync('a');
      final r = ops.readFile('config.yml');
      expect(r.error, contains('File not found'));
      expect(r.similarFiles, isNotEmpty);
    });
  });

  group('patchReplace', () {
    test('exact replace with diff', () {
      File(p.join(tmp.path, 'x.py')).writeAsStringSync('def foo():\n    pass\n');
      final r = ops.patchReplace('x.py', 'def foo():', 'def bar():');
      expect(r.error, isNull);
      expect(r.success, isTrue);
      expect(r.filesModified, ['x.py']);
      expect(File(p.join(tmp.path, 'x.py')).readAsStringSync(),
          'def bar():\n    pass\n');
      expect(r.diff, contains('a/x.py'));
    });

    test('fuzzy indentation reindents to file', () {
      File(p.join(tmp.path, 'c.py')).writeAsStringSync(
          'class C:\n    def f(self):\n        x = 1\n');
      final r = ops.patchReplace(
          'c.py', 'x = 1', 'x = 99');
      expect(r.error, isNull);
      final content = File(p.join(tmp.path, 'c.py')).readAsStringSync();
      expect(content, contains('        x = 99'));
    });

    test('no-match returns error with hint', () {
      File(p.join(tmp.path, 'x.txt')).writeAsStringSync('hello world\n');
      final r = ops.patchReplace('x.txt', 'nothing here', 'replacement');
      expect(r.success, isFalse);
      expect(r.error, isNotNull);
    });
  });

  group('patchV4a', () {
    test('parse and apply update', () {
      File(p.join(tmp.path, 'g.py')).writeAsStringSync(
          'def foo():\n    pass\n');
      final patch = '*** Begin Patch\n'
          '*** Update File: g.py\n'
          '@@ def foo @@\n'
          ' def foo():\n'
          '-    pass\n'
          '+    return 1\n'
          '*** End Patch\n';
      final r = ops.patchV4a(patch);
      expect(r.error, isNull);
      expect(r.success, isTrue);
      expect(File(p.join(tmp.path, 'g.py')).readAsStringSync(),
          'def foo():\n    return 1\n');
    });

    test('add file operation', () {
      final patch = '*** Begin Patch\n'
          '*** Add File: new.txt\n'
          '+line one\n'
          '+line two\n'
          '*** End Patch\n';
      final r = ops.patchV4a(patch);
      expect(r.error, isNull);
      expect(r.success, isTrue);
      expect(r.filesCreated, ['new.txt']);
      expect(File(p.join(tmp.path, 'new.txt')).readAsStringSync(),
          'line one\nline two');
    });

    test('delete file operation', () {
      File(p.join(tmp.path, 'del.txt')).writeAsStringSync('bye\n');
      final patch = '*** Begin Patch\n'
          '*** Delete File: del.txt\n'
          '*** End Patch\n';
      final r = ops.patchV4a(patch);
      expect(r.error, isNull);
      expect(r.filesDeleted, ['del.txt']);
      expect(File(p.join(tmp.path, 'del.txt')).existsSync(), isFalse);
    });

    test('validation failure leaves files untouched', () {
      File(p.join(tmp.path, 'g.py')).writeAsStringSync('abc\n');
      final patch = '*** Begin Patch\n'
          '*** Update File: g.py\n'
          '-no such line\n'
          '*** End Patch\n';
      final r = ops.patchV4a(patch);
      expect(r.success, isFalse);
      expect(r.error, contains('validation failed'));
      expect(File(p.join(tmp.path, 'g.py')).readAsStringSync(), 'abc\n');
    });
  });

  group('delete/move', () {
    test('deleteFile removes file', () {
      File(p.join(tmp.path, 'd.txt')).writeAsStringSync('x');
      final r = ops.deleteFile('d.txt');
      expect(r.error, isNull);
      expect(File(p.join(tmp.path, 'd.txt')).existsSync(), isFalse);
    });

    test('moveFile renames', () {
      File(p.join(tmp.path, 'm.txt')).writeAsStringSync('x');
      final r = ops.moveFile('m.txt', 'm2.txt');
      expect(r.error, isNull);
      expect(File(p.join(tmp.path, 'm.txt')).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'm2.txt')).readAsStringSync(), 'x');
    });
  });

  group('search', () {
    test('content search finds matches', () {
      File(p.join(tmp.path, 's1.txt')).writeAsStringSync('apple\nbanana\n');
      File(p.join(tmp.path, 's2.txt')).writeAsStringSync('cherry\n');
      final r = ops.search('banana');
      expect(r.error, isNull);
      expect(r.totalCount, 1);
      expect(r.matches.single.path, endsWith('s1.txt'));
      expect(r.matches.single.lineNumber, 2);
    });

    test('files search by glob', () {
      File(p.join(tmp.path, 'a.dart')).writeAsStringSync('x');
      File(p.join(tmp.path, 'b.py')).writeAsStringSync('y');
      final r = ops.search('*.dart', target: 'files');
      expect(r.files.single, endsWith('a.dart'));
    });
  });

  group('search 沙盒保护', () {
    test('cwd 未配置时拒绝搜索（防遍历 / 卡死）', () {
      final noCwdOps = LocalFileOperations(); // cwd = null
      final r = noCwdOps.search('anything');
      expect(r.error, contains('cwd'));
      expect(r.totalCount, 0);
    });

    test('越界绝对路径被拒绝', () {
      // 用临时目录外的一个路径（如系统临时目录的上级）测试。
      final outside = p.join(tmp.path, '..', 'outside_dir');
      final r = ops.search('anything', path: outside);
      expect(r.error, contains('超出沙盒范围'));
      expect(r.totalCount, 0);
    });

    test('cwd 内搜索正常', () {
      File(p.join(tmp.path, 'in.txt')).writeAsStringSync('hello sandbox');
      final r = ops.search('sandbox');
      expect(r.error, isNull);
      expect(r.totalCount, 1);
    });
  });

  group('parseV4aPatch', () {
    test('CRLF-tolerant line splitting', () {
      final patch = '*** Begin Patch\r\n'
          '*** Update File: g.py\r\n'
          '-x\r\n'
          '+y\r\n'
          '*** End Patch\r\n';
      final (ops2, err) = parseV4aPatch(patch);
      expect(err, isNull);
      expect(ops2.single.operation, OperationType.update);
      expect(ops2.single.hunks.single.lines.first.prefix, '-');
      expect(ops2.single.hunks.single.lines.first.content, 'x');
    });
  });
}
