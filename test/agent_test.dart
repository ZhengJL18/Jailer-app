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
import 'package:jailer/agent/agent.dart';
import 'package:jailer/agent/iteration_budget.dart';
import 'package:jailer/llm/openai_llm.dart';
import 'package:jailer/tools/file_tools.dart';
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
      final agent = JailerAgent(
        llm: llm,
        systemPrompt: 'You are Jailer, an Android agent.',
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
      final agent = JailerAgent(
        llm: llm,
        systemPrompt: 'You are Jailer.',
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
      final agent = JailerAgent(
        llm: llm,
        systemPrompt: 'You are Jailer.',
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
      final agent = JailerAgent(
        llm: llm,
        systemPrompt: 'You are Jailer.',
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
      final agent = JailerAgent(
        llm: llm,
        systemPrompt: 'You are Jailer.',
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
      final agent = JailerAgent(
        llm: llm,
        systemPrompt: 'You are Jailer.',
      );
      final result = await agent.runConversation('Mix of failures and success');
      expect(result.completed, isTrue);
      expect(result.finalResponse, 'done');
      expect(result.error, isNull);
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
