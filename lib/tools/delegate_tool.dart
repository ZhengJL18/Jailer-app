/// delegate_task 工具：agent 派子任务给子 agent 并行处理。
///
/// 子 agent 用独立 LLM 调用 + 工具执行，返回结果给主 agent。
/// 通过全局 [delegateHandler] 由 ChatScreen 提供（复用 JailerAgent）。
library;

import 'registry.dart';

/// ChatScreen 注册的子 agent 执行回调：给定任务，返回子 agent 的结果。
Future<String> Function(String task, List<String>? toolsets)? delegateHandler;

/// delegate_task 工具 handler。
Future<String> _handleDelegate(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final handler = delegateHandler;
  if (handler == null) {
    return toolError('delegate_task: 子 agent 执行器未注册');
  }
  final task = args['task'] as String? ?? '';
  if (task.isEmpty) {
    return toolError('delegate_task: missing task');
  }
  final toolsets = (args['toolsets'] as List?)?.whereType<String>().toList();
  try {
    return await handler(task, toolsets);
  } catch (e) {
    return toolError('delegate_task failed: $e');
  }
}

const Map<String, dynamic> _delegateSchema = {
  'name': 'delegate_task',
  'description':
      'Delegate a sub-task to a sub-agent that runs independently with its own '
      'LLM turns and tool access, then returns a summary. Use for tasks that '
      'can run in parallel with your main work, or that benefit from a fresh '
      'context (research, refactoring a separate file, drafting code). '
      'The sub-agent result is returned as text.',
  'parameters': {
    'type': 'object',
    'properties': {
      'task': {
        'type': 'string',
        'description': 'A self-contained task description for the sub-agent',
      },
      'toolsets': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Optional toolsets the sub-agent may use (file, web, git)',
      },
    },
    'required': ['task'],
  },
};

/// 注册 delegate_task 工具。
void registerDelegateTool() {
  registry.register(
    name: 'delegate_task',
    toolset: 'delegate',
    schema: _delegateSchema,
    handler: _handleDelegate,
    isAsync: true,
    emoji: '🤖',
  );
}
