import 'package:flutter_test/flutter_test.dart';
import 'package:jailer/agent/context_compressor.dart';

/// 构造长对话。
List<Map<String, dynamic>> longConversation(int turns) {
  final messages = <Map<String, dynamic>>[
    {'role': 'system', 'content': 'You are a helpful agent.'},
  ];
  for (var i = 0; i < turns; i++) {
    messages.add({'role': 'user', 'content': 'Question number $i with some detail'});
    messages.add({'role': 'assistant', 'content': 'Answer number $i with useful info'});
  }
  return messages;
}

void main() {
  group('shouldCompress', () {
    test('低于阈值不压缩', () {
      final c = ContextCompressor(
        contextLength: 100000,
        summarizer: (m) async => 'summary',
      );
      expect(c.shouldCompress(1000), isFalse);
    });

    test('超过阈值压缩', () {
      final c = ContextCompressor(
        contextLength: 100000,
        summarizer: (m) async => 'summary',
      );
      expect(c.shouldCompress(80000), isTrue);
    });

    test('防抖动：最近两次省<10%跳过', () {
      final c = ContextCompressor(
        contextLength: 100000,
        summarizer: (m) async => 'summary',
      );
      // 制造两次低节省。
      c.simulateLowSavings();
      c.simulateLowSavings();
      expect(c.shouldCompress(80000), isFalse);
    });
  });

  group('compress', () {
    test('长对话压缩后更短且保留头尾', () async {
      // 小尾预算模拟"超长对话"：20 turn 对话超过 200 token 尾预算 → 压缩。
      final c = ContextCompressor(
        contextLength: 100000,
        tailTokenBudget: 200,
        summarizer: (m) async => '中间对话摘要',
      );
      final messages = longConversation(20);
      final result = await c.compress(messages);
      expect(result.length, lessThan(messages.length));
      // 头部 system 保留。
      expect(result.first['role'], 'system');
      // 尾部最新对话保留（tail）。
      expect(result.last['content'], contains('Answer number 19'));
      // 中间被摘要替换。
      expect(
        result.any((m) => m['content'] is String && (m['content'] as String).contains('中间对话摘要')),
        isTrue,
      );
    });

    test('消息太少不压缩', () async {
      final c = ContextCompressor(
        contextLength: 100000,
        summarizer: (m) async => 'summary',
      );
      final messages = longConversation(2);
      final result = await c.compress(messages);
      expect(result, messages);
    });

    test('摘要失败保持原样', () async {
      final c = ContextCompressor(
        contextLength: 100000,
        summarizer: (m) async => throw Exception('LLM down'),
      );
      final messages = longConversation(20);
      final result = await c.compress(messages);
      expect(result.length, messages.length);
    });
  });

  group('estimateTokens', () {
    test('粗略 4 chars/token', () {
      expect(estimateTokens('abcdefgh'), 2);
      expect(estimateTokens(''), 0);
    });
  });
}
