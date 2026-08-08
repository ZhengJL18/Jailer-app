/// 移植自 `ref/hermes-agent/tests/tools/test_fuzzy_match.py`（像素级复刻验证）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/tools/fuzzy_match.dart';

void main() {
  group('TestExactMatch', () {
    test('single replacement', () {
      final (new_, count, _, err) =
          fuzzyFindAndReplace('hello world', 'hello', 'hi');
      expect(err, isNull);
      expect(count, 1);
      expect(new_, 'hi world');
    });

    test('whitespace-only old_string rejected', () {
      final content = 'alpha\n   \nbeta\n';
      final (new_, count, _, err) =
          fuzzyFindAndReplace(content, '   ', 'XXX');
      expect(count, 0);
      expect(err, isNotNull);
      expect(err, contains('whitespace'));
      expect(new_, content);
    });

    test('empty old_string rejected', () {
      final (_, count, _, err) = fuzzyFindAndReplace('abc', '', 'x');
      expect(count, 0);
      expect(err, isNotNull);
    });

    test('multiline exact', () {
      final (new_, count, _, err) =
          fuzzyFindAndReplace('line1\nline2\nline3', 'line1\nline2', 'replaced');
      expect(err, isNull);
      expect(count, 1);
      expect(new_, 'replaced\nline3');
    });
  });

  group('TestWhitespaceDifference', () {
    test('extra spaces match', () {
      final (new_, count, _, err) = fuzzyFindAndReplace(
          'def  foo(  x,  y  ):', 'def foo( x, y ):', 'def bar(x, y):');
      expect(count, 1);
      expect(new_, contains('bar'));
    });

    test('boundary space preserved after match', () {
      final (new_, count, strategy, err) =
          fuzzyFindAndReplace('foo   bar baz', 'foo bar', 'XY');
      expect(err, isNull);
      expect(count, 1);
      expect(strategy, 'whitespace_normalized');
      expect(new_, 'XY baz', reason: 'Boundary space deleted: $new_');
    });

    test('boundary space preserved in code edit', () {
      final (new_, count, strategy, err) = fuzzyFindAndReplace(
          'result = compute(a,  b) + tail', 'compute(a, b)', 'compute(a, b, c)');
      expect(err, isNull);
      expect(count, 1);
      expect(strategy, 'whitespace_normalized');
      expect(new_, 'result = compute(a, b, c) + tail',
          reason: 'Boundary space deleted: $new_');
    });

    test('trailing ws still consumed when match ends with space', () {
      final (new_, count, _, err) =
          fuzzyFindAndReplace('a = foo   + bar', 'foo +', 'XY');
      expect(err, isNull);
      expect(count, 1);
      expect(new_, contains('XY'));
      expect(new_, contains('bar'));
    });
  });

  group('TestIndentDifference', () {
    test('different indentation', () {
      final (new_, count, _, err) = fuzzyFindAndReplace(
          '    def foo():\n        pass', 'def foo():\n    pass',
          'def bar():\n    return 1');
      expect(count, 1);
      expect(new_, contains('bar'));
    });
  });

  group('TestIndentationPreservation', () {
    test('unindented input reindented to match file', () {
      final content = 'class Calculator:\n'
          '    def add(self, a, b):\n'
          '        result = a + b\n'
          '        return result\n';
      final old = 'result = a + b\nreturn result';
      final newStr = 'result = a + b\nresult *= 2\nreturn result';
      final (out, count, strategy, err) =
          fuzzyFindAndReplace(content, old, newStr);
      expect(err, isNull);
      expect(count, 1);
      expect(strategy, isNot('exact'));
      for (final marker in ['result = a + b', 'result *= 2', 'return result']) {
        final line = out.split('\n').firstWhere((l) => l.contains(marker));
        final indent = line.length - line.trimLeft().length;
        expect(indent, 8, reason: "Expected 8-space indent for '$marker', got $indent: '$line'");
      }
    });

    test('blank lines left alone', () {
      final content = '    a = 1\n    b = 2\n';
      final old = 'a = 1\nb = 2';
      final newStr = 'a = 1\n\nb = 99';
      final (out, count, _, err) = fuzzyFindAndReplace(content, old, newStr);
      expect(err, isNull);
      expect(count, 1);
      final lines = out.split('\n');
      expect(lines[0], '    a = 1');
      expect(lines[1], '');
      expect(lines[2], '    b = 99');
    });
  });

  group('TestReplaceAll', () {
    test('multiple matches without flag errors', () {
      final (_, count, _, err) = fuzzyFindAndReplace(
          'aaa bbb aaa', 'aaa', 'ccc', replaceAll: false);
      expect(count, 0);
      expect(err, contains('Found 2 matches'));
    });

    test('multiple matches with flag', () {
      final (new_, count, _, err) = fuzzyFindAndReplace(
          'aaa bbb aaa', 'aaa', 'ccc', replaceAll: true);
      expect(err, isNull);
      expect(count, 2);
      expect(new_, 'ccc bbb ccc');
    });

    test('self-overlapping pattern non-overlapping matches', () {
      final (new_, count, _, err) =
          fuzzyFindAndReplace('aaaa', 'aa', 'b', replaceAll: true);
      expect(err, isNull);
      expect(count, 2);
      expect(new_, 'bb');

      final (new2, count2, _, _) =
          fuzzyFindAndReplace('aaa', 'a', 'b', replaceAll: true);
      expect(count2, 3);
      expect(new2, 'bbb');

      final (new3, count3, _, _) = fuzzyFindAndReplace(
          'prefix aaaa suffix', 'aa', 'b', replaceAll: true);
      expect(count3, 2);
      expect(new3, 'prefix bb suffix');

      final (_, count4, _, err4) =
          fuzzyFindAndReplace('aaaa', 'aa', 'b', replaceAll: false);
      expect(count4, 0);
      expect(err4, contains('2 matches'));
    });
  });

  group('TestUnicodeNormalized', () {
    test('em dash matched', () {
      final content = 'return value\u2014fallback';
      final (new_, count, strategy, err) = fuzzyFindAndReplace(
          content, 'return value--fallback', 'return value or fallback');
      expect(count, 1, reason: 'Expected match via unicode_normalized, got err=$err');
      expect(strategy, 'unicode_normalized');
      expect(new_, contains('return value or fallback'));
    });

    test('ellipsis preserved', () {
      final content = 'Wait for it\u2026and done';
      final (new_, count, strategy, err) = fuzzyFindAndReplace(
          content, 'Wait for it...and done', 'Wait for it...then done');
      expect(count, 1, reason: 'Expected match, got err=$err');
      expect(new_, 'Wait for it\u2026then done', reason: 'Got $new_');
    });

    test('mixed unicode multiline', () {
      final content = 'Line 1 \u2014 with dash\nLine 2 \u201cquoted\u201d text\nLine 3 plain';
      final old = 'Line 1 -- with dash\nLine 2 "quoted" text\nLine 3 plain';
      final newStr = 'Line 1 -- with dash\nLine 2 "quoted" text\nLine 3 changed';
      final (new_, count, strategy, err) =
          fuzzyFindAndReplace(content, old, newStr);
      expect(count, 1, reason: 'Expected match, got err=$err');
      final expected =
          'Line 1 \u2014 with dash\nLine 2 \u201cquoted\u201d text\nLine 3 changed';
      expect(new_, expected, reason: 'Got $new_');
    });

    test('no unicode no change', () {
      final (new_, count, _, err) = fuzzyFindAndReplace(
          'plain text here', 'plain text here', 'plain text there');
      expect(count, 1);
      expect(new_, 'plain text there');
    });
  });

  group('TestUnicodeSpaceAndMinusNormalized', () {
    test('unicode minus matched and preserved', () {
      final content = 'offset = value \u2212 1\nprint(offset)\n';
      final (new_, count, strategy, err) = fuzzyFindAndReplace(
          content, 'offset = value - 1', 'offset = delta - 1');
      expect(count, 1, reason: 'Expected match, got err=$err');
      expect(strategy, 'unicode_normalized');
      expect(new_, contains('delta \u2212 1'), reason: 'Got $new_');
    });

    test('ideographic space cjk line', () {
      final content = '標題\u3000第一章\nbody text\n';
      final (new_, count, strategy, err) = fuzzyFindAndReplace(
          content, '標題 第一章', '標題 第二章');
      expect(count, 1, reason: 'Expected match, got err=$err');
      expect(strategy, 'unicode_normalized');
      expect(new_, contains('標題\u3000第二章'), reason: 'Got $new_');
    });
  });

  group('TestBlockAnchorThreshold', () {
    test('high similarity matches', () {
      final content = 'def foo():\n    x = 1\n    y = 2\n    return x + y\n';
      final pattern = 'def foo():\n    x = 1\n    y = 9\n    return x + y';
      final (_, count, _, _) = fuzzyFindAndReplace(
          content, pattern, 'def foo():\n    return 0\n');
      expect(count, 1);
    });

    test('completely different middle does not match', () {
      final content = 'class Foo:\n'
          "    completely = 'unrelated'\n"
          "    content = 'here'\n"
          "    nothing = 'in common'\n"
          '    pass\n';
      final pattern = 'class Foo:\n'
          '    x = 1\n'
          '    y = 2\n'
          '    z = 3\n'
          '    pass';
      final (_, count, strategy, _) =
          fuzzyFindAndReplace(content, pattern, 'replaced');
      expect(count, 0,
          reason:
              'Block with unrelated middle should not match under threshold=0.50, but matched via strategy=$strategy');
    });
  });

  group('TestStrategyNameSurfaced', () {
    test('exact strategy name', () {
      final (_, count, strategy, _) =
          fuzzyFindAndReplace('hello', 'hello', 'world');
      expect(strategy, 'exact');
      expect(count, 1);
    });

    test('failed match returns null strategy', () {
      final (_, count, strategy, _) =
          fuzzyFindAndReplace('hello', 'xyz', 'world');
      expect(count, 0);
      expect(strategy, isNull);
    });
  });

  group('TestEscapeDriftGuard', () {
    test('drift blocked apostrophe', () {
      final content = 'line\n    x = 1\nline';
      final oldString = "line\n  x = \\'a\\'\nline";
      final newString = "line\n  x = \\'b\\'\nline";
      final (new_, count, _, err) =
          fuzzyFindAndReplace(content, oldString, newString);
      expect(count, 0);
      expect(err, isNotNull);
      expect(err, contains('Escape-drift'));
      expect(err!.toLowerCase(), contains('backslash'));
      expect(new_, content);
    });

    test('drift blocked double quote', () {
      final content = 'line\n    x = 1\nline';
      final oldString = 'line\n  x = \\"a\\"\nline';
      final newString = 'line\n  x = \\"b\\"\nline';
      final (_, count, _, err) =
          fuzzyFindAndReplace(content, oldString, newString);
      expect(count, 0);
      expect(err, isNotNull);
      expect(err, contains('Escape-drift'));
    });

    test('drift allowed when file genuinely has backslash escapes', () {
      final content = "line\n  x = \\'a\\'\nline";
      final oldString = "line\n  x = \\'a\\'\nline";
      final newString = "line\n  x = \\'b\\'\nline";
      final (new_, count, _, err) =
          fuzzyFindAndReplace(content, oldString, newString);
      expect(err, isNull);
      expect(count, 1);
      expect(new_, contains("\\'b\\'"));
    });

    test('drift allowed on exact match', () {
      final content = "hello \\'world\\'";
      final (new_, count, strategy, err) = fuzzyFindAndReplace(
          content, "hello \\'world\\'", "hello \\'there\\'");
      expect(err, isNull);
      expect(count, 1);
      expect(strategy, 'exact');
    });

    test('no drift check when new_string lacks suspect chars', () {
      final content = 'def foo():\n    pass';
      final oldString = 'def foo():\n  pass';
      final newString = 'def bar():\n  return 1';
      final (_, count, _, err) =
          fuzzyFindAndReplace(content, oldString, newString);
      expect(err, isNull);
      expect(count, 1);
    });
  });

  group('TestFindClosestLines', () {
    test('finds similar line', () {
      final result =
          findClosestLines('def baz():', 'def foo():\n    pass\ndef bar():\n    return 1\n');
      expect(result, contains('def foo'));
    });

    test('includes line numbers', () {
      final result = findClosestLines('def foo():', 'line1\nline2\ndef foo():\n    pass\n');
      expect(result, contains('|'));
    });
  });

  group('TestFormatNoMatchHint', () {
    test('fires on could not find with match', () {
      final result = formatNoMatchHint(
          'Could not find a match for old_string in the file', 0, 'def baz():',
          'def foo():\n    pass\ndef bar():\n    pass\n');
      expect(result, contains('Did you mean'));
      expect(result, contains('foo'));
    });

    test('silent on escape drift error', () {
      final result = formatNoMatchHint(
          "Escape-drift detected: ...", 0, "x = \\'1\\'", 'x = 1\n');
      expect(result, '');
    });

    test('silent when no similar content', () {
      final result = formatNoMatchHint(
          'Could not find a match for old_string in the file', 0,
          'totally_unique_xyzzy_qux', 'abc\nxyz\n');
      expect(result, '');
    });
  });

  group('TestEscapeNormalizedNewString', () {
    test('tab in new_string unescaped under escape_normalized', () {
      final content = 'def hello():\n\tprint("before")\n';
      final oldString = 'def hello():\n\\tprint("before")\n';
      final newString = 'def hello():\n\\tprint("after")\n';
      final (new_, count, strategy, err) =
          fuzzyFindAndReplace(content, oldString, newString);
      expect(err, isNull, reason: 'Unexpected error: $err');
      expect(count, 1);
      expect(strategy, 'escape_normalized');
      expect(new_, contains('\tprint("after")'));
      expect(new_, isNot(contains('\\t')));
    });

    test('tab in new_string unescaped under exact', () {
      final content = 'def hello():\n\tprint("before")\n';
      final oldString = '\tprint("before")';
      final newString = '\\tprint("after")';
      final (new_, count, strategy, err) =
          fuzzyFindAndReplace(content, oldString, newString);
      expect(err, isNull, reason: 'Unexpected error: $err');
      expect(count, 1);
      expect(strategy, 'exact');
      expect(new_, contains('\tprint("after")'));
      expect(new_, isNot(contains('\\t')));
    });

    test('carriage return in new_string unescaped', () {
      final content = 'line1\r\nline2\r\n';
      final oldString = 'line1\\r\\nline2\\r\\n';
      final newString = 'replaced\\r\\n';
      final (new_, count, strategy, err) =
          fuzzyFindAndReplace(content, oldString, newString);
      expect(err, isNull, reason: 'Unexpected error: $err');
      expect(count, 1);
      expect(strategy, 'escape_normalized');
      expect(new_, contains('replaced\r'));
    });

    test('newline in new_string NOT unescaped', () {
      final content = 'line1\nline2\n';
      final oldString = 'line1\nline2';
      final newString = 'alpha\\nbeta';
      final (new_, count, _, err) =
          fuzzyFindAndReplace(content, oldString, newString);
      expect(err, isNull, reason: 'Unexpected error: $err');
      expect(count, 1);
      expect(new_, contains('alpha\\nbeta'));
      expect(new_, isNot(contains('alpha\nbeta')));
    });

    test('mixed tab and newline only tab unescaped', () {
      final content = 'def foo():\n\tpass\n';
      final oldString = 'def foo():\n\tpass\n';
      final newString = 'def bar():\\n\\treturn 1\\n';
      final (new_, count, _, err) =
          fuzzyFindAndReplace(content, oldString, newString);
      expect(err, isNull, reason: 'Unexpected error: $err');
      expect(count, 1);
      expect(new_, contains('\treturn 1'));
      expect(new_, isNot(contains('\\t')));
      expect(new_, contains('\\n'));
    });

    test('exact match preserves literal backslash t in string literal', () {
      final content = 'sep = "\\t"\n';
      final oldString = 'sep = "\\t"\n';
      final newString = 'sep = "\\tab"\n';
      final (new_, count, strategy, err) =
          fuzzyFindAndReplace(content, oldString, newString);
      expect(err, isNull, reason: 'Unexpected error: $err');
      expect(count, 1);
      expect(strategy, 'exact');
      expect(new_, contains('sep = "\\tab"'));
      expect(new_, isNot(contains('\t')));
    });

    test('no escape sequences passthrough', () {
      final content = 'def foo():\n    return 1\n';
      final oldString = 'def foo():\n    return 1\n';
      final newString = 'def foo():\n    return 2\n';
      final (new_, count, _, err) =
          fuzzyFindAndReplace(content, oldString, newString);
      expect(err, isNull);
      expect(count, 1);
      expect(new_, contains('return 2'));
    });
  });

  group('TestContextAwareCorrectness', () {
    test('half garbage block does not match', () {
      final content = 'config_value = 100\nthreshold = 200\n';
      final old = 'config_value = 999\ntotally_unrelated_line_here';
      final newStr = 'config_value = 42\ntotally_unrelated_line_here';
      final (result, count, strategy, err) =
          fuzzyFindAndReplace(content, old, newStr);
      expect(count, 0, reason: 'should not match, got strategy=$strategy');
      expect(err, isNotNull);
      expect(result, contains('threshold = 200'));
    });

    test('replace_all refuses similarity strategy', () {
      final content = 'aX\nbY\naX\nbY\naX\nbY\n';
      final (result, count, strategy, err) = fuzzyFindAndReplace(
          content, 'aX\nbZ', 'QQ\nRR', replaceAll: true);
      expect(count, 0, reason: 'should refuse, got strategy=$strategy');
      expect(err, isNotNull);
      expect(result, content);
    });

    test('all lines matching still replaces', () {
      final content = 'alpha one\nbeta two\ngamma three\n';
      final old = 'alpha one\nbeta 2\ngamma three';
      final newStr = 'alpha one\nbeta TWO\ngamma three';
      final (result, count, _, err) =
          fuzzyFindAndReplace(content, old, newStr);
      expect(count, 1, reason: 'err=$err');
      expect(result, contains('beta TWO'));
    });
  });
}
