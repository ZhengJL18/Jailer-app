/// 对应 `ref/hermes-agent/agent/conversation_loop.py` 的 run_conversation 核心
/// （像素级复刻，最小闭环子集）。
///
/// 完整 run_conversation 是 4500+ 行（压缩门控、截断重试、中断、记忆 review、
/// MoA、fallback 链等）。本文件复刻**主循环骨架**（这是最小闭环的核心数据流）：
///
/// 1. **Prologue**：组装 messages（system + conversation_history + user）
/// 2. **主循环**（while api_call_count < max_iterations 且 budget 有余量）：
///    - 组包：api_messages + getToolDefinitions()（OpenAI 格式工具 schema）
///    - LLM 调用：chatStream（含 tool_calls 聚合）
///    - 响应含 tool_calls → 逐工具经 model_tools.handleFunctionCall 执行，
///      结果回填为 role=tool 消息 → 继续循环
///    - 响应无 tool_calls → 确定 final_response → 结束
/// 3. **收尾**：返回 {final_response, messages, api_calls, completed}
///
/// 外围（压缩/截断重试/中断/持久化）留接口，App 首版不实现。
library;

import 'dart:convert';

import '../llm/openai_llm.dart';
import '../tools/model_tools.dart';
import 'iteration_budget.dart';

/// agent 主循环的结果。
class ConversationResult {
  final String? finalResponse;
  final List<Map<String, dynamic>> messages;
  final int apiCalls;
  final bool completed;
  final String? error;

  const ConversationResult({
    this.finalResponse,
    required this.messages,
    required this.apiCalls,
    required this.completed,
    this.error,
  });
}

/// Agent 主循环。
class JailerAgent {
  /// LLM 客户端。
  final OpenAiLlmClient llm;

  /// 系统提示词（三层 system_prompt 的简化：stable 身份提示）。
  final String systemPrompt;

  /// 工具 schema 提供者（默认取 Hermes getToolDefinitions）。
  final List<Map<String, dynamic>> Function()? toolDefinitionsProvider;

  /// 最大迭代次数（Hermes 默认 500）。
  final int maxIterations;

  /// 迭代预算。
  final IterationBudget iterationBudget;

  /// 流式文本回调（UI 打字）。
  final void Function(String delta)? onDelta;

  /// 工具调用事件回调（UI 显示工具执行）。
  final void Function(String name, String status)? onToolEvent;

  JailerAgent({
    required this.llm,
    required this.systemPrompt,
    this.toolDefinitionsProvider,
    this.maxIterations = 500,
    this.onDelta,
    this.onToolEvent,
  }) : iterationBudget = IterationBudget(maxIterations);

  /// 运行一次完整对话（带工具调用直到完成）。
  ///
  /// [conversationHistory] 之前对话消息（可选）。
  Future<ConversationResult> runConversation(
    String userMessage, {
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    // ── Prologue：组装 messages ──
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      ...?conversationHistory,
      {'role': 'user', 'content': userMessage},
    ];

    var apiCallCount = 0;
    String? finalResponse;
    var failed = false;

    while (apiCallCount < maxIterations && iterationBudget.remaining > 0) {
      apiCallCount++;

      // 消耗迭代预算。
      if (!iterationBudget.consume()) {
        break;
      }

      // ── 组包：api_messages + tools ──
      final tools = toolDefinitionsProvider != null
          ? toolDefinitionsProvider!()
          : getToolDefinitions(quietMode: true);

      // ── LLM 调用 ──
      final LlmTurnResult turn;
      try {
        turn = await llm.chatStream(
          messages: messages,
          tools: tools,
          onDelta: onDelta,
        );
      } on LlmException catch (e) {
        failed = true;
        return ConversationResult(
          finalResponse: 'API call failed: $e',
          messages: messages,
          apiCalls: apiCallCount,
          completed: false,
          error: e.toString(),
        );
      }

      // 把 assistant turn 追加进消息历史。
      messages.add(turn.toAssistantMessage());

      // ── 有 tool_calls → 执行并回填 ──
      if (turn.hasToolCalls) {
        for (final tc in turn.toolCalls) {
          Map<String, dynamic> args;
          try {
            final decoded = tc.arguments.isEmpty
                ? <String, dynamic>{}
                : jsonDecode(tc.arguments);
            args = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
          } catch (_) {
            args = <String, dynamic>{};
          }

          onToolEvent?.call(tc.name, 'running');
          final result = await handleFunctionCall(tc.name, args);
          onToolEvent?.call(tc.name, 'done');

          messages.add({
            'role': 'tool',
            'tool_call_id': tc.id,
            'name': tc.name, // OpenAI 兼容端要求 tool 消息带 name。
            'content': result,
          });
        }
        continue; // 有工具调用 → 继续循环（模型看到工具结果再决定）
      }

      // ── 无 tool_calls → final_response ──
      finalResponse = turn.content ?? '';
      break;
    }

    // 预算耗尽但未完成。
    if (finalResponse == null && !failed) {
      return ConversationResult(
        finalResponse: 'Iteration budget exhausted (${iterationBudget.used}/'
            '${iterationBudget.maxTotal} iterations used)',
        messages: messages,
        apiCalls: apiCallCount,
        completed: false,
      );
    }

    return ConversationResult(
      finalResponse: finalResponse,
      messages: messages,
      apiCalls: apiCallCount,
      completed: finalResponse != null,
    );
  }
}
