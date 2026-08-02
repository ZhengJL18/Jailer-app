import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/tools/toolsets.dart';

void main() {
  group('resolveToolset', () {
    test('file toolset resolves to 4 file tools', () {
      final tools = resolveToolset('file');
      expect(tools, ['patch', 'read_file', 'search_files', 'write_file']);
    });

    test('safe toolset includes web/vision/image_gen', () {
      final tools = resolveToolset('safe');
      expect(tools, contains('web_search'));
      expect(tools, contains('vision_analyze'));
      expect(tools, contains('image_generate'));
      // no terminal
      expect(tools, isNot(contains('terminal')));
    });

    test('debugging toolset composes includes', () {
      final tools = resolveToolset('debugging');
      expect(tools, contains('terminal'));
      expect(tools, contains('process'));
      expect(tools, contains('read_file'));
      expect(tools, contains('web_search'));
    });

    test('all/* returns every toolset tool', () {
      final all = resolveToolset('all');
      final any = resolveToolset('*');
      expect(all, any);
      expect(all, isNotEmpty);
      expect(all, contains('read_file'));
    });

    test('hermes-cli resolves to core tools', () {
      final tools = resolveToolset('hermes-cli');
      expect(tools, containsAll(hermesCoreTools));
    });

    test('cycle detection returns empty', () {
      createCustomToolset('cycle_a', 'a', includes: ['cycle_b']);
      createCustomToolset('cycle_b', 'b', includes: ['cycle_a']);
      final tools = resolveToolset('cycle_a');
      // b 里的工具经 a 解析时 visited 拦截 cycle_a，返回 []
      // a 直接工具为空，includes b → b 解析 b 的 includes cycle_a → 已 visited → []
      expect(tools, isEmpty);
    });
  });

  group('getToolset / validate', () {
    test('getToolset returns def with registry merge', () {
      final def = getToolset('file');
      expect(def, isNotNull);
      expect(def!.tools, containsAll(['read_file', 'write_file']));
    });

    test('unknown toolset returns null', () {
      expect(getToolset('no_such_ts'), isNull);
    });

    test('validateToolset accepts known/all', () {
      expect(validateToolset('file'), isTrue);
      expect(validateToolset('all'), isTrue);
      expect(validateToolset('*'), isTrue);
      expect(validateToolset('no_such'), isFalse);
    });
  });

  group('bundleNonCoreTools', () {
    test('hermes-feishu removes only feishu extras', () {
      final toRemove = bundleNonCoreTools('hermes-feishu');
      expect(toRemove, isNot(contains('read_file'))); // core preserved
      expect(toRemove, contains('feishu_doc_read'));
      expect(toRemove, contains('feishu_drive_add_comment'));
    });

    test('hermes-cli (pure core) removes nothing', () {
      final toRemove = bundleNonCoreTools('hermes-cli');
      expect(toRemove, isEmpty);
    });
  });

  group('createCustomToolset', () {
    test('registers new toolset and resolves', () {
      createCustomToolset('custom_ts', 'Custom', tools: ['read_file']);
      expect(validateToolset('custom_ts'), isTrue);
      expect(resolveToolset('custom_ts'), ['read_file']);
      expect(getToolsetInfo('custom_ts')!['is_composite'], isFalse);
    });
  });
}
