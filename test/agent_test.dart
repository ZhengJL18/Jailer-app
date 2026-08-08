/// 最小闭环验收测试：agent 自主完成"写文件→读文件→最终回答"。
///
/// 用脚本化 MockClient 模拟 LLM 的流式响应序列：
/// turn1 → 调用 write_file（写 notes/hello.txt）
/// turn2 → 调用 read_file（读回来）
/// turn3 → 最终回答
/// 全程经过 agent 主循环 + registry.dispatch + file_tools。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mix/agent/agent.dart';
import 'package:mix/agent/iteration_budget.dart';
import 'package:mix/llm/openai_llm.dart';
import 'package:mix/tools/file_tools.dart';
import 'package:path/path.dart' as p;

String sse(Map<String, dynamic> chunk) => 'data: ${jsonEncode(chunk)}';

/// 脚本化 LLM：按顺序返回预定义 SSE 流。
class ScriptedLlmClient extends http.BaseClient {
  final List<List<String>> responses;
  int _callCount = 0;

  ScriptedLlmClient(this.responses);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_callCount >= responses.length) {
      throw StateError('unexpected extra LLM call #$_callCount');
    }
    final body = responses[_callCount].join('\n');
    _callCount++;
    final stream = Stream.value(utf8.encode(body));
    return http.StreamedResponse(stream, 200,
        headers: {'content-type': 'text/event-stream'});
  }

  int get callCount => _callCount;
}

/// 构造一个 tool_calls turn 的 SSE 行。
List<String> toolCallTurn(String id, String name, String argsJson) => [
      sse({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': id,
                  'function': {'name': name, 'arguments': argsJson},
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
    ];

List<String> textTurn(String text) => [
      sse({
        'choices': [
          {
            'delta': {'content': text},
            'finish_reason': null,
          },
        ],
      }),
      sse({
        'choices': [
          {
            'delta': <String, dynamic>{},
            'finish_reason': 'stop',
          },
        ],
      }),
      'data: [DONE]',
    ];

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jailer_agent_test_');
    configureFileTools(cwd: tmp.path);
    registerFileTools();
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('最小闭环', () {
    test('写文件→读文件→最终回答', () async {
      final script = ScriptedLlmClient([
        toolCallTurn('call_write', 'write_file',
            '{"path":"notes/hello.txt","content":"haiku about android"}'),
        toolCallTurn('call_read', 'read_file', '{"path":"notes/hello.txt"}'),
        textTurn('Here is the file: haiku about android'),
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: script,
      );

      final toolEvents = <String>[];
      final agent = MIXAgent(
        llm: llm,
        systemPrompt: 'You are MIX, an Android agent.',
        onToolEvent: (name, status) => toolEvents.add('$name:$status'),
      );

      final result = await agent.runConversation(
        'Write a haiku to notes/hello.txt and read it back.',
      );

      expect(result.completed, isTrue);
      expect(result.finalResponse, 'Here is the file: haiku about android');
      expect(result.apiCalls, 3);
      expect(script.callCount, 3);

      // 工具真的执行了：文件被写入。
      expect(
        File(p.join(tmp.path, 'notes/hello.txt')).readAsStringSync(),
        'haiku about android',
      );

      // 工具事件顺序：write 执行 → read 执行。
      expect(toolEvents, [
        'write_file:running',
        'write_file:done',
        'read_file:running',
        'read_file:done',
      ]);

      // 消息历史结构：system + user + assistant(tool_calls) + tool + assistant(tool_calls) + tool + assistant(text)。
      final roles = result.messages.map((m) => m['role']).toList();
      expect(roles, [
        'system',
        'user',
        'assistant',
        'tool',
        'assistant',
        'tool',
        'assistant',
      ]);
    });

    test('直接最终回答（无工具调用）', () async {
      final script = ScriptedLlmClient([
        textTurn('Just an answer, no tools.'),
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: script,
      );
      final agent = MIXAgent(
        llm: llm,
        systemPrompt: 'You are MIX.',
      );
      final result = await agent.runConversation('Hello');
      expect(result.completed, isTrue);
      expect(result.finalResponse, 'Just an answer, no tools.');
      expect(result.apiCalls, 1);
    });

    test('迭代预算耗尽', () async {
      // 永远返回工具调用 → 预算（设小）耗尽。
      final script = ScriptedLlmClient([
        toolCallTurn('call_loop', 'read_file', '{"path":"x"}'),
        toolCallTurn('call_loop', 'read_file', '{"path":"x"}'),
        toolCallTurn('call_loop', 'read_file', '{"path":"x"}'),
        toolCallTurn('call_loop', 'read_file', '{"path":"x"}'),
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: script,
      );
      final agent = MIXAgent(
        llm: llm,
        systemPrompt: 'You are MIX.',
        maxIterations: 3,
      );
      final result = await agent.runConversation('Loop forever');
      expect(result.completed, isFalse);
      expect(result.finalResponse, contains('Iteration budget exhausted'));
      expect(result.apiCalls, 3);
    });

    test('工具参数 JSON 解析失败 → 空参数仍执行', () async {
      final script = ScriptedLlmClient([
        toolCallTurn('call_bad', 'write_file', 'not valid json'),
        textTurn('ok done'),
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: script,
      );
      final agent = MIXAgent(
        llm: llm,
        systemPrompt: 'You are MIX.',
      );
      // 坏参数 → write_file 缺 path → 返回错误 JSON，agent 继续。
      final result = await agent.runConversation('write something');
      expect(result.completed, isTrue);
      expect(result.finalResponse, 'ok done');
    });

    test('防死循环：同一工具+同参数连续失败 9 次 → 自动中断', () async {
      // 3 次失败 → 警告1；再 3 次 → 警告2；再 3 次 → 中断（阈值=3，警告上限=2）。
      final failCall =
          toolCallTurn('call_loop', 'read_file', '{"path":"/no/such/file"}');
      final script = ScriptedLlmClient([
        failCall, failCall, failCall, // 警告 1
        failCall, failCall, failCall, // 警告 2
        failCall, failCall, failCall, // 中断
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: script,
      );
      final agent = MIXAgent(
        llm: llm,
        systemPrompt: 'You are MIX.',
      );
      final result = await agent.runConversation('Loop on a broken tool');
      expect(result.completed, isFalse);
      expect(result.finalResponse, contains('已自动中止'));
      expect(result.error, contains('tool_loop_detected'));
      expect(script.callCount, 9); // 第 9 次执行后中断，未触发第 10 次调用。
    });

    test('防死循环：失败中穿插成功 → 计数器复位，不误杀', () async {
      // fail, fail, success, fail×3 → 只注入一次警告，不中断。
      final failCall =
          toolCallTurn('call_loop', 'read_file', '{"path":"/no/such/file"}');
      final okCall =
          toolCallTurn('call_ok', 'write_file', '{"path":"ok.txt","content":"x"}');
      final script = ScriptedLlmClient([
        failCall, failCall,
        okCall,
        failCall, failCall, failCall,
        textTurn('done'),
      ]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: script,
      );
      final agent = MIXAgent(
        llm: llm,
        systemPrompt: 'You are MIX.',
      );
      final result = await agent.runConversation('Mix of failures and success');
      expect(result.completed, isTrue);
      expect(result.finalResponse, 'done');
      expect(result.error, isNull);
    });
  });

  group('sanitizeToolPairing（残缺 tool 配对清洗）', () {
    late MIXAgent agent;

    setUp(() {
      final script = ScriptedLlmClient([]);
      final llm = OpenAiLlmClient(
        config: const LlmConfig(
          baseUrl: 'https://example.com/v1/chat/completions',
          apiKey: 'test',
          model: 'test-model',
        ),
        client: script,
      );
      agent = MIXAgent(llm: llm, systemPrompt: 'You are MIX.');
    });

    Map<String, dynamic> assistantWithToolCalls(List<Map<String, dynamic>> calls,
        {String? content}) {
      return {
        'role': 'assistant',
        if (content != null) 'content': content,
        'tool_calls': calls,
      };
    }

    test('assistant 声明 tool_calls 但无对应结果 → 残缺声明被清除（无文本整条丢弃）',
        () {
      var messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
        assistantWithToolCalls([
          {'id': 'call_1', 'type': 'function', 'function': {'name': 'a'}},
        ]),
      ];
      messages = agent.sanitizeToolPairing(messages);
      // 残缺的 assistant(tool_calls) 无文本 → 整条丢弃，只剩 user。
      expect(
        messages.map((m) => m['role']).toList(),
        ['user'],
      );
    });

    test('assistant 声明 tool_calls 无结果但有文本 → 降级为纯文本 assistant', () {
      var messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
        assistantWithToolCalls(
          [
            {'id': 'call_1', 'type': 'function', 'function': {'name': 'a'}},
          ],
          content: 'I will call a tool',
        ),
      ];
      messages = agent.sanitizeToolPairing(messages);
      final roles = messages.map((m) => m['role']).toList();
      expect(roles, ['user', 'assistant']);
      final kept = messages.last;
      expect(kept['content'], 'I will call a tool');
      expect(kept.containsKey('tool_calls'), isFalse); // 残缺声明已剔除。
    });

    test('孤儿 tool 消息（无前置 assistant 声明）→ 丢弃', () {
      var messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
        {'role': 'tool', 'tool_call_id': 'call_orphan', 'content': 'result'},
      ];
      messages = agent.sanitizeToolPairing(messages);
      expect(
        messages.map((m) => m['role']).toList(),
        ['user'],
      );
    });

    test('完整配对（assistant→tool）原样保留', () {
      var messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
        assistantWithToolCalls([
          {'id': 'call_ok', 'type': 'function', 'function': {'name': 'a'}},
        ]),
        {'role': 'tool', 'tool_call_id': 'call_ok', 'content': 'result'},
      ];
      messages = agent.sanitizeToolPairing(messages);
      expect(
        messages.map((m) => m['role']).toList(),
        ['user', 'assistant', 'tool'],
      );
      // 声明保留，tool 结果保留。
      expect((messages[1]['tool_calls'] as List).length, 1);
      expect(messages[2]['tool_call_id'], 'call_ok');
    });

    test('多 tool_call 部分有结果 → 只保留有结果的声明', () {
      var messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
        assistantWithToolCalls([
          {'id': 'call_a', 'type': 'function', 'function': {'name': 'a'}},
          {'id': 'call_b', 'type': 'function', 'function': {'name': 'b'}},
        ]),
        {'role': 'tool', 'tool_call_id': 'call_a', 'content': 'result-a'},
      ];
      messages = agent.sanitizeToolPairing(messages);
      final roles = messages.map((m) => m['role']).toList();
      expect(roles, ['user', 'assistant', 'tool']);
      // call_b 无结果 → 从声明中剔除，只留 call_a。
      final calls = (messages[1]['tool_calls'] as List)
          .map((c) => (c as Map)['id'])
          .toList();
      expect(calls, ['call_a']);
    });

    test('并行 tool 结果间插入 user 警告（楔子）→ 修成合法序列', () {
      // 旧逻辑只查 id"存在"：call_b 在声明里、也在某个 tool 消息里 → 全保留，
      // 但 user 警告楔在 tool(call_a) 与 tool(call_b) 之间，严格后端会 400
      // "Messages with role 'tool' must be a response to a preceding message
      // with 'tool_calls'"。严格清洗必须把被 user 打断的剩余声明（call_b）
      // 从 assistant 剔除、并丢弃错位的 tool(call_b)。
      var messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
        assistantWithToolCalls([
          {'id': 'call_a', 'type': 'function', 'function': {'name': 'a'}},
          {'id': 'call_b', 'type': 'function', 'function': {'name': 'b'}},
        ]),
        {'role': 'tool', 'tool_call_id': 'call_a', 'content': 'result-a'},
        {'role': 'user', 'content': '⚠️ 工具 a 已连续失败 3 次'},
        {'role': 'tool', 'tool_call_id': 'call_b', 'content': 'result-b'},
      ];
      messages = agent.sanitizeToolPairing(messages);
      final roles = messages.map((m) => m['role']).toList();
      expect(roles, ['user', 'assistant', 'tool', 'user']);
      final calls = (messages[1]['tool_calls'] as List)
          .map((c) => (c as Map)['id'])
          .toList();
      expect(calls, ['call_a']);
      expect(messages[2]['tool_call_id'], 'call_a');
    });

    test('tool 结果先于声明出现（错位）→ 不靠"id 存在"放行', () {
      var messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
        {'role': 'tool', 'tool_call_id': 'call_x', 'content': 'result'},
        assistantWithToolCalls([
          {'id': 'call_x', 'type': 'function', 'function': {'name': 'a'}},
        ]),
      ];
      messages = agent.sanitizeToolPairing(messages);
      // 错位：tool 在前、声明在后 → 两者都不可用，无文本的声明整条丢弃。
      expect(
        messages.map((m) => m['role']).toList(),
        ['user'],
      );
    });
  });

  group('IterationBudget', () {
    test('consume/refund/remaining', () {
      final budget = IterationBudget(3);
      expect(budget.remaining, 3);
      expect(budget.consume(), isTrue);
      expect(budget.consume(), isTrue);
      expect(budget.used, 2);
      expect(budget.remaining, 1);
      budget.refund();
      expect(budget.used, 1);
      expect(budget.remaining, 2);
      expect(budget.consume(), isTrue);
      expect(budget.consume(), isTrue);
      expect(budget.consume(), isFalse); // 用尽。
      expect(budget.remaining, 0);
    });
  });
}
