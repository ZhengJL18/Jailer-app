import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/config/providers.dart';

void main() {
  setUp(() {
    // 恢复默认 key 解析器。
    keyResolver = (_) => null;
  });

  group('normalizeProvider / aliases', () {
    test('normalize aliases to canonical', () {
      expect(normalizeProvider('openai'), 'openrouter');
      expect(normalizeProvider('glm'), 'zai');
      expect(normalizeProvider('zhipu'), 'zai');
      expect(normalizeProvider('moonshot'), 'kimi-for-coding');
      expect(normalizeProvider('dashscope'), 'alibaba');
      expect(normalizeProvider('claude'), 'anthropic');
      expect(normalizeProvider('DeepSeek'), 'deepseek'); // 大小写归一化
    });

    test('unknown name passes through', () {
      expect(normalizeProvider('custom-thing'), 'custom-thing');
    });
  });

  group('getProvider / resolveProviderFull', () {
    test('resolves built-in deepseek', () {
      final pdef = resolveProviderFull('deepseek');
      expect(pdef, isNotNull);
      expect(pdef!.id, 'deepseek');
      expect(pdef.transport, Transport.openaiChat);
      expect(pdef.baseUrl, contains('deepseek.com'));
      expect(pdef.apiKeyEnvVars, ['DEEPSEEK_API_KEY']);
    });

    test('alias moonshot resolves to kimi-for-coding', () {
      final pdef = resolveProviderFull('moonshot');
      expect(pdef!.id, 'kimi-for-coding');
      expect(pdef.baseUrl, contains('moonshot.cn'));
    });

    test('anthropic has anthropic_messages transport', () {
      final pdef = resolveProviderFull('anthropic');
      expect(pdef!.transport, Transport.anthropicMessages);
    });

    test('user config provider wins over builtin', () {
      final pdef = resolveProviderFull('deepseek', userProviders: {
        'deepseek': {
          'name': 'My DeepSeek',
          'api': 'https://my-proxy.example.com/v1/chat/completions',
          'key_env': 'MY_KEY',
        },
      });
      expect(pdef!.id, 'deepseek');
      expect(pdef.name, 'My DeepSeek');
      expect(pdef.baseUrl, 'https://my-proxy.example.com/v1/chat/completions');
      expect(pdef.apiKeyEnvVars, ['MY_KEY']);
      expect(pdef.source, 'user-config');
    });

    test('unknown provider returns null', () {
      expect(resolveProviderFull('no-such-provider'), isNull);
    });
  });

  group('determineApiMode', () {
    test('openai_chat transport → chat_completions', () {
      expect(determineApiMode('deepseek'), 'chat_completions');
    });

    test('anthropic → anthropic_messages', () {
      expect(determineApiMode('anthropic'), 'anthropic_messages');
    });

    test('bedrock direct check', () {
      expect(determineApiMode('bedrock'), 'bedrock_converse');
    });

    test('default chat_completions', () {
      expect(determineApiMode('unknown'), 'chat_completions');
    });
  });

  group('keyResolver', () {
    test('providerApiKey uses keyResolver hook', () {
      keyResolver = (env) {
        if (env == 'DEEPSEEK_API_KEY') {
          return 'sk-test';
        }
        return null;
      };
      final pdef = resolveProviderFull('deepseek')!;
      expect(providerApiKey(pdef), 'sk-test');
    });

    test('null when no key resolved', () {
      final pdef = resolveProviderFull('deepseek')!;
      expect(providerApiKey(pdef), isNull);
    });
  });
}
