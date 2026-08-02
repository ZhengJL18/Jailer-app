import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jailer/llm/openai_llm.dart';

/// 构造一个返回合成 SSE 流的 MockClient。
http.Client mockSseClient(List<String> lines) {
  return MockClient((request) async {
    final body = lines.join('\n');
    return http.Response(
      body,
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
}

/// 把 JSON chunk 编码为 SSE data 行。
String sse(Map<String, dynamic> chunk) => 'data: ${jsonEncode(chunk)}';

void main() {
  group('content streaming', () {
    test('aggregates text deltas', () async {
      final client = mockSseClient([
        'data: {"choices":[{"delta":{"content":"Hel"}, "finish_reason":null}]}',
        'data: {"choices":[{"delta":{"content":"lo"}, "finish_reason":null}]}',
        'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
        'data: [DONE]',
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: client,
      );
      final deltas = <String>[];
      final result = await llm.chatStream(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
        onDelta: deltas.add,
      );
      expect(result.content, 'Hello');
      // onDelta 收到的是增量（Hermes stream_delta_callback 语义）。
      expect(deltas, ['Hel', 'lo']);
      expect(result.hasToolCalls, isFalse);
      expect(result.finishReason, 'stop');
    });
  });

  group('tool_calls aggregation', () {
    test('aggregates by index with name assignment + args concat', () async {
      // 用 jsonEncode 构造干净 SSE 字节，避免字符串转义地狱。
      final client = mockSseClient([
        sse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'function': {'name': 'write_file', 'arguments': '{"path":"a.txt",'},
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        }),
        sse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': '"content":"hi"}'},
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        }),
        sse({
          'choices': [
            {
              'delta': <String, dynamic>{},
              'finish_reason': 'tool_calls',
            },
          ],
        }),
        'data: [DONE]',
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: client,
      );
      final result = await llm.chatStream(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
      );
      expect(result.hasToolCalls, isTrue);
      expect(result.toolCalls.length, 1);
      final tc = result.toolCalls.first;
      expect(tc.id, 'call_1');
      expect(tc.name, 'write_file');
      expect(tc.arguments, '{"path":"a.txt","content":"hi"}');
      expect(result.finishReason, 'tool_calls');
    });

    test('parallel tool calls aggregate by distinct index', () async {
      final client = mockSseClient([
        sse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'c1',
                    'function': {'name': 'read_file', 'arguments': '{"path":"a"}'},
                  },
                  {
                    'index': 1,
                    'id': 'c2',
                    'function': {'name': 'write_file', 'arguments': '{"path":"b"}'},
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        }),
        sse({
          'choices': [
            {
              'delta': <String, dynamic>{},
              'finish_reason': 'tool_calls',
            },
          ],
        }),
        'data: [DONE]',
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: client,
      );
      final result = await llm.chatStream(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
      );
      expect(result.toolCalls.length, 2);
      expect(result.toolCalls[0].name, 'read_file');
      expect(result.toolCalls[1].name, 'write_file');
      // 按 index 排序。
      expect(result.toolCalls[0].id, 'c1');
      expect(result.toolCalls[1].id, 'c2');
    });

    test('name repeated in every chunk uses assignment (no concat)', () async {
      final client = mockSseClient([
        sse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'c1',
                    'function': {'name': 'read_file', 'arguments': ''},
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        }),
        sse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'name': 'read_file', 'arguments': '{"path":"x"}'},
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        }),
        sse({
          'choices': [
            {
              'delta': <String, dynamic>{},
              'finish_reason': 'tool_calls',
            },
          ],
        }),
        'data: [DONE]',
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: client,
      );
      final result = await llm.chatStream(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
      );
      expect(result.toolCalls.first.name, 'read_file', reason: 'name 应赋值而非拼接');
    });

    test('Ollama reuses index 0 with new id → new slot', () async {
      final client = mockSseClient([
        sse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_A',
                    'function': {'name': 'read_file', 'arguments': '{"path":"a"}'},
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        }),
        sse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_B',
                    'function': {'name': 'write_file', 'arguments': '{"path":"b"}'},
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        }),
        sse({
          'choices': [
            {
              'delta': <String, dynamic>{},
              'finish_reason': 'tool_calls',
            },
          ],
        }),
        'data: [DONE]',
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: client,
      );
      final result = await llm.chatStream(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
      );
      expect(result.toolCalls.length, 2);
      expect(result.toolCalls[0].name, 'read_file');
      expect(result.toolCalls[1].name, 'write_file');
    });

    test('toAssistantMessage round-trips', () async {
      final client = mockSseClient([
        sse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'c1',
                    'function': {'name': 'read_file', 'arguments': '{}'},
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        }),
        sse({
          'choices': [
            {
              'delta': <String, dynamic>{},
              'finish_reason': 'tool_calls',
            },
          ],
        }),
        'data: [DONE]',
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: client,
      );
      final result = await llm.chatStream(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
      );
      final msg = result.toAssistantMessage();
      expect(msg['role'], 'assistant');
      final calls = msg['tool_calls'] as List;
      expect((calls.first as Map)['id'], 'c1');
      expect((calls.first as Map)['function']['name'], 'read_file');
    });
  });

  group('non-streaming chat', () {
    test('parses tool_calls from JSON body', () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['stream'], isNull);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': null,
                  'tool_calls': [
                    {
                      'id': 'c1',
                      'type': 'function',
                      'function': {'name': 'read_file', 'arguments': '{"path":"x"}'},
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          }),
          200,
        );
      });
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: client,
      );
      final result = await llm.chat(messages: [
        {'role': 'user', 'content': 'hi'},
      ]);
      expect(result.toolCalls.length, 1);
      expect(result.toolCalls.first.name, 'read_file');
    });

    test('non-200 throws LlmException', () async {
      final client = MockClient((request) async {
        return http.Response('error', 401);
      });
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: client,
      );
      expect(
        () => llm.chat(messages: [
          {'role': 'user', 'content': 'hi'},
        ]),
        throwsA(isA<LlmException>()),
      );
    });
  });

  group('usage chunk', () {
    test('captures usage when present', () async {
      final client = mockSseClient([
        'data: {"choices":[{"delta":{"content":"a"},"finish_reason":null}]}',
        'data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}',
        'data: [DONE]',
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: client,
      );
      final result = await llm.chatStream(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
      );
      expect(result.usageJson, contains('prompt_tokens'));
    });
  });
}
