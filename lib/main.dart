import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent/agent.dart';
import 'agent/company.dart';
import 'agent/context_compressor.dart';
import 'agent/workflow.dart';
import 'config/jailer_config.dart';
import 'db/session_db.dart';
import 'llm/openai_llm.dart';
import 'screens/code_editor_screen.dart';
import 'screens/file_browser_screen.dart';
import 'screens/github_screen.dart';
import 'screens/settings_screen.dart';
import 'services/storage_permission.dart';
import 'services/update_service.dart';
import 'theme/theme_ext.dart';
import 'theme/theme_provider.dart';
import 'tools/clarify_tool.dart';
import 'tools/company_tool.dart';
import 'tools/context_retriever.dart';
import 'tools/cron_tools.dart';
import 'tools/delegate_tool.dart';
import 'tools/file_tools.dart';
import 'tools/git_tools.dart';
import 'tools/memory_manager.dart';
import 'tools/memory_tool.dart';
import 'tools/moa_tool.dart';
import 'tools/model_tools.dart';
import 'tools/session_search_tool.dart';
import 'tools/skills_tool.dart';
import 'tools/todo_tool.dart';
import 'tools/vision_tool.dart';
import 'tools/web_tools.dart';
import 'widgets/markdown_math.dart';

/// 全局主题控制器（设置页/切换入口共用）。
ThemeController themeController = ThemeController();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  themeController.load();
  runApp(const JailerApp());
}

/// 对话历史页「继续聊天」回调：切换 ChatScreen 到指定会话。
/// 由 ChatScreen 注册，HistoryScreen 调用。
Future<void> Function(String sessionId)? resumeSessionHandler;

class JailerApp extends StatelessWidget {
  const JailerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 监听主题 + 明暗，任一变化 → 整树 rebuild（ThemeExtension 全量替换）。
    return ValueListenableBuilder(
      valueListenable: themeController.themeNotifier,
      builder: (context, theme, child) {
        return ValueListenableBuilder(
          valueListenable: themeController.brightnessNotifier,
          builder: (context, brightness, child) {
            return MaterialApp(
              title: 'Hermes',
              theme: themeController.themeData,
              home: const ChatScreen(),
            );
          },
        );
      },
    );
  }
}

/// 单条对话消息。
class _ChatMessage {
  final String role; // user / assistant / tool
  final String? text;
  final String? toolName;
  final String? toolStatus;

  _ChatMessage.user(this.text)
      : role = 'user',
        toolName = null,
        toolStatus = null;
  _ChatMessage.assistant(this.text)
      : role = 'assistant',
        toolName = null,
        toolStatus = null;
  _ChatMessage.tool(this.toolName, this.toolStatus)
      : role = 'tool',
        text = null;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final List<_ChatMessage> _messages = [];
  // 工具名 → 当前 running 卡片的消息索引（done 时更新而非新增）。
  final Map<String, int> _toolRunningIdx = {};
  bool _running = false;
  bool _planMode = false; // Claude Code 式 plan 模式：先出计划，批准后执行。
  String? _pendingPlan; // 待批准的计划。
  String? _pendingTask; // 待执行的任务原文（批准计划后执行用）。
  String _workflowId = 'daily'; // 当前工作流（AgentWorkflow）。
  JailerAgent? _activeAgent;
  MemoryManager? _memory;
  SessionDB? _sessionDb;
  String? _currentSessionId;

  /// 停止当前生成（ESC / 停止按钮）。
  void _stop() {
    _activeAgent?.cancel();
  }

  @override
  void initState() {
    super.initState();
    initConfig();
    registerFileTools();
    registerWebTools();
    registerTodoTool();
    registerSessionSearchTool();
    registerGitTools();
    registerClarifyTool();
    clarifyHandler = _showClarifyDialog;
    registerDelegateTool();
    delegateHandler = _runSubAgent;
    registerMoaTool();
    moaHandler = _runDiscussion;
    registerCompanyTool();
    departmentHandler = _runDepartment;
    registerCronTools();
    cronFireHandler = _fireCronJob;
    startCronScheduler();
    registerVisionTool();
    // 对话历史页「继续聊天」→ 切换到指定会话并加载历史。
    resumeSessionHandler = _resumeSession;
    _initCwd();
    // 自动更新检查（fire-and-forget，失败静默不打扰）。
    _checkUpdate();
  }

  /// 启动时静默检查更新，有新版 → 弹窗提示。
  Future<void> _checkUpdate() async {
    final info = await UpdateService.checkForUpdate();
    if (!mounted || info == null) return;
    _showUpdateDialog(info);
  }

  /// 手动检查更新（二级菜单入口）：有新版弹窗，无新版/失败给提示。
  Future<void> _checkForUpdateManually() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在检查更新…')),
    );
    UpdateInfo? info;
    var failed = false;
    try {
      info = await UpdateService.checkForUpdateDetailed();
    } catch (_) {
      failed = true; // 网络/解析失败。
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (failed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('检查更新失败，请检查网络')),
      );
    } else if (info != null) {
      _showUpdateDialog(info);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已是最新版本')),
      );
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 v${info.version}'),
        content: SingleChildScrollView(
          child: Text(info.notes?.trim().isNotEmpty == true
              ? info.notes!
              : '有新版本可用，是否立即更新？'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _downloadAndInstall(info);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstall(UpdateInfo info) async {
    if (!mounted) return;
    // 下载进度提示。
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Row(
          children: const [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('正在下载更新…'),
          ],
        ),
      ),
    );
    final ok = await UpdateService.downloadAndInstall(info.downloadUrl);
    if (!mounted) return;
    Navigator.of(context).pop(); // 关下载提示
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载/安装失败，请稍后重试')),
      );
    }
  }

  /// 从对话历史切回某个会话继续聊：切换 sessionId + 加载历史到 UI。
  Future<void> _resumeSession(String sessionId) async {
    final sdb = _sessionDb;
    if (sdb == null) return;
    if (!mounted) return;
    setState(() {
      _messages.clear();
      _toolRunningIdx.clear();
      _currentSessionId = sessionId;
    });
    try {
      final stored = await sdb.getMessages(sessionId);
      for (final m in stored) {
        final role = m['role'] as String? ?? 'user';
        final content = m['content'] as String?;
        if (role == 'user' && content != null) {
          _messages.add(_ChatMessage.user(content));
        } else if (role == 'assistant' && content != null) {
          _messages.add(_ChatMessage.assistant(content));
        } else if (role == 'tool') {
          _messages.add(_ChatMessage.tool(
            m['tool_name'] as String? ?? '',
            'done',
          ));
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
  }

  /// 新建会话：生成新 sessionId，清空当前对话。
  Future<void> _newSession() async {
    final sdb = _sessionDb;
    if (sdb == null) return;
    if (!mounted) return;
    final newId = 's${DateTime.now().millisecondsSinceEpoch}';
    try {
      await sdb.createSession(newId, source: 'app');
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _messages.clear();
      _toolRunningIdx.clear();
      _currentSessionId = newId;
      _pendingPlan = null;
      _pendingTask = null;
    });
  }

  /// Plan 模式：只读探索任务，生成计划并展示（不执行写操作）。
  Future<void> _generatePlan(String task) async {
    final config = await JailerConfig.load();
    if (config == null) {
      _addAssistant('请先配置 AI');
      return;
    }
    setState(() {
      _running = true;
      _pendingPlan = null;
    });
    final llm = OpenAiLlmClient(config: config.toLlmConfig());
    final planAgent = JailerAgent(
      llm: llm,
      systemPrompt: '你是 Hermes，处于计划模式。你现在只做探索和规划，'
          '绝对不要修改/创建/删除任何文件，不要 git add/commit/push。'
          '可以用 read_file / search_files / git_status / git_diff 探索当前状态，'
          '然后输出一个清晰的执行计划：列出要做的步骤、每步做什么、'
          '涉及什么文件/命令。计划要具体、可执行。用中文。',
      toolDefinitionsProvider: () => _readOnlyTools(),
      maxIterations: 15,
    );
    try {
      final result = await planAgent.runConversation(task);
      final plan = result.finalResponse ?? '(无计划输出)';
      if (!mounted) return;
      setState(() {
        _pendingPlan = plan;
        _running = false;
      });
      _addAssistant('📋 **执行计划**\n\n$plan');
      _addPlanApprovalBar();
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      _addAssistant('生成计划失败：$e');
    }
  }

  /// 计划批准/拒绝操作条。
  void _addPlanApprovalBar() {
    if (!mounted) return;
    _pendingPlan = _pendingPlan; // 保留计划。
    setState(() {
      _messages.add(_ChatMessage.tool('plan_approval', 'running'));
    });
  }

  /// 批准计划：用完整工具执行。
  Future<void> _executePlan(String task) async {
    final plan = _pendingPlan;
    setState(() {
      _pendingPlan = null;
      _running = true;
      _toolRunningIdx.clear();
    });
    if (plan != null) {
      // 把计划加进对话，agent 执行时参考（跳过重复检索，计划已是上下文）。
      await _runTaskWithFullTools(
        '$task\n\n按以下计划执行：\n$plan',
        skipRetrieval: true,
      );
      return;
    }
    await _runTaskWithFullTools(task);
  }

  /// 用完整工具集执行任务（现有 _send 主体逻辑抽取）。
  Future<void> _runTaskWithFullTools(String task, {bool skipRetrieval = false}) async {
    final config = await JailerConfig.load();
    if (config == null) {
      _addAssistant('请先配置 AI');
      return;
    }
    final llm = OpenAiLlmClient(config: config.toLlmConfig());
    final compressor = ContextCompressor(
      contextLength: 100000,
      summarizer: (middle) async {
        final summaryTurn = await llm.chatStream(
          messages: [
            {
              'role': 'system',
              'content': 'Summarize the conversation below, preserving key '
                  'facts, decisions, and context. Be concise.',
            },
            {'role': 'user', 'content': jsonEncode(middle)},
          ],
        );
        return summaryTurn.content ?? '';
      },
    );
    // 工程检索：从历史消息召回与当前任务相关的片段，注入上下文（防污染）。
    // plan 执行时跳过（计划本身已是上下文，避免基于长拼接文本搜到无关内容）。
    final retrieved =
        skipRetrieval ? <ContextHit>[] : await _retrieveRelevantContext(task);
    _activeAgent = JailerAgent(
      llm: llm,
      memoryManager: _memory,
      sessionDb: _sessionDb,
      sessionId: _currentSessionId,
      contextCompressor: compressor,
      systemPrompt: _buildWorkflowPrompt(
        contextBlock: formatContextBlock(retrieved),
      ),
      toolDefinitionsProvider: () => getToolDefinitions(
        enabledToolsets: _currentWorkflow.toolsets,
        quietMode: true,
      ),
      onDelta: (delta) {
        setState(() {
          if (_messages.isEmpty ||
              _messages.last.role == 'user' ||
              _messages.last.role == 'tool') {
            _messages.add(_ChatMessage.assistant(delta));
          } else if (_messages.last.role == 'assistant') {
            final last = _messages.last;
            _messages[_messages.length - 1] = _ChatMessage.assistant(
                (last.text ?? '') + delta);
          }
        });
      },
      onToolEvent: (name, status) {
        setState(() {
          if (status == 'running') {
            _toolRunningIdx[name] = _messages.length;
            _messages.add(_ChatMessage.tool(name, status));
          } else {
            final idx = _toolRunningIdx.remove(name);
            if (idx != null && idx < _messages.length) {
              _messages[idx] = _ChatMessage.tool(name, status);
            } else {
              _messages.add(_ChatMessage.tool(name, status));
            }
          }
        });
      },
    );
    try {
      final result = await _activeAgent!.runConversation(task);
      if (result.completed &&
          result.finalResponse != null &&
          _messages.isNotEmpty &&
          _messages.last.role == 'assistant' &&
          _messages.last.text != result.finalResponse) {
        setState(() {
          _messages[_messages.length - 1] =
              _ChatMessage.assistant(result.finalResponse);
        });
      } else if (!result.completed && result.finalResponse != null) {
        _addAssistant(result.finalResponse!);
      }
    } catch (e) {
      _addAssistant('出错了：$e');
    } finally {
      _activeAgent = null;
      setState(() => _running = false);
    }
  }

  /// delegate 回调：子 agent 独立执行任务，返回结果摘要。
  /// [depth] 当前层数（0=主代理，1=一级子代理…）；最大 [maxAgentDepth]。
  Future<String> _runSubAgent(
    String task,
    List<String>? toolsets,
    int depth,
  ) async {
    final config = await JailerConfig.load();
    if (config == null) {
      return '子任务未执行：AI 未配置';
    }
    // 分级委派：子任务优先用快模型（未配置则 fallback 主模型）。
    final fastConfig = await JailerConfig.loadFastConfig();
    final llm = OpenAiLlmClient(
      config: fastConfig ?? config.toLlmConfig(),
    );
    // 子代理可继续委派（下探），深度由 currentAgentDepth 维护（串行安全）。
    // 过滤 company（子代理不派部门，防部门递归）。
    final effectiveToolsets =
        (toolsets ?? const ['file', 'web', 'git'])
            .where((t) => t != 'company')
            .toList();
    final subAgent = JailerAgent(
      llm: llm,
      systemPrompt: '你是 Hermes 的第 $depth 层子代理。独立完成给定任务并'
          '简洁汇报结果。任务太复杂时，可继续 delegate_task 派给更下层的'
          '子代理。用中文。',
      toolDefinitionsProvider: () => getToolDefinitions(
        enabledToolsets: effectiveToolsets,
        quietMode: true,
      ),
      maxIterations: 20,
    );
    // 子代理运行期间：currentAgentDepth = depth + 1（本层子代理）。
    // 它的 delegate 工具读 currentAgentDepth 作深度，超限则被 _handleDelegate 拦。
    final prevDepth = currentAgentDepth;
    currentAgentDepth = depth + 1;
    try {
      final result = await subAgent.runConversation(task);
      return result.finalResponse ?? '(子代理无输出)';
    } catch (e) {
      return '子任务失败：$e';
    } finally {
      currentAgentDepth = prevDepth;
    }
  }

  /// 部门执行器（公司模式）：部门内角色先讨论再分工执行，汇总给 CEO。
  ///
  /// [department] 部门 id；[task] 任务；[depth] 当前层数。
  /// 流程：1) 角色间一轮讨论（互看意见）2) 各角色分工执行 3) 经理汇总。
  Future<String> _runDepartment(String department, String task, int depth) async {
    final dep = findActiveDepartment(department);
    if (dep == null) {
      return '未知部门：$department';
    }
    final config = await JailerConfig.load();
    if (config == null) {
      return '部门任务未执行：AI 未配置';
    }
    final llm = OpenAiLlmClient(config: config.toLlmConfig());

    // 第 1 步：角色间讨论一轮（各自给专业意见，互看后补充/反驳）。
    String discussionBlock = '';
    if (dep.roles.length > 1) {
      final opinions = await Future.wait(
        dep.roles.map((role) async {
          try {
            final turn = await llm.chatStream(messages: [
              {
                'role': 'system',
                'content': '你是「${dep.name}」的$role。围绕部门任务给出你的'
                    '专业意见，重点是你视角下的关键点。用中文。',
              },
              {'role': 'user', 'content': '部门任务：$task'},
            ]);
            return '「$role」：${turn.content ?? '(无意见)'}';
          } catch (e) {
            return '「$role」：（讨论失败 $e）';
          }
        }),
      );
      discussionBlock = opinions.join('\n');
    }

    // 第 2 步：各角色带着讨论结果分工执行（角色子代理可用工具，可下探）。
    // 角色子代理并行跑：各自设 currentAgentDepth = depth（下探时 depth+1）。
    final prevDepth = currentAgentDepth;
    final roleOutputs = await Future.wait(
      dep.roles.map((role) async {
        final roleAgent = JailerAgent(
          llm: llm,
          systemPrompt: '你是「${dep.name}」的$role。参考团队讨论，完成你的'
              '分工工作。可调用工具。用中文。',
          toolDefinitionsProvider: () => getToolDefinitions(
            // 角色不再派部门（防部门递归），但可 delegate 子任务/讨论。
            enabledToolsets: dep.toolsets
                .where((t) => t != 'company')
                .toList(),
            quietMode: true,
          ),
          maxIterations: 20,
        );
        currentAgentDepth = depth + 1;
        try {
          final result = await roleAgent.runConversation(
            '$task\n\n团队讨论：\n$discussionBlock',
          );
          return '「$role」：${result.finalResponse ?? '(无输出)'}';
        } catch (e) {
          return '「$role」：执行失败 $e';
        }
      }),
    );
    currentAgentDepth = prevDepth;

    // 第 3 步：主模型（部门经理）汇总各角色输出给 CEO。
    try {
      final summaryTurn = await llm.chatStream(messages: [
        {
          'role': 'system',
          'content': '你是「${dep.name}」的经理。综合下面部门成员的输出，'
              '给 CEO 一个简洁的最终结果：提炼关键结论，合并重复，标出分歧。'
              '用中文。',
        },
        {
          'role': 'user',
          'content': '部门任务：$task\n\n成员输出：\n${roleOutputs.join('\n')}',
        },
      ]);
      final summary = summaryTurn.content ?? '';
      return summary.isNotEmpty ? summary : roleOutputs.join('\n');
    } catch (e) {
      return roleOutputs.join('\n');
    }
  }

  /// 多子代理真对话（Kimi 式）：各视角子代理逐轮并行讨论，主模型综合。
  ///
  /// [topic] 讨论主题；[rounds] 轮数（默认2，上限4）。
  /// 每轮所有子代理并行发言（看到上轮彼此内容），N 轮后主模型综合。
  Future<String> _runDiscussion(String topic, int rounds) async {
    final config = await JailerConfig.load();
    if (config == null) {
      return '讨论未执行：AI 未配置';
    }
    final llm = OpenAiLlmClient(config: config.toLlmConfig());

    // 各子代理视角人设。
    const perspectives = [
      ('架构', '你是一位资深架构师，关注系统结构、模块划分、可扩展性和维护性。'),
      ('性能', '你是一位性能优化专家，关注效率、资源占用、瓶颈和权衡。'),
      ('严谨', '你是一位批判性审查者，关注边界情况、错误处理、风险和遗漏。'),
    ];

    // 共享讨论记录（每轮追加所有人的发言）。
    final transcript = <String>[];
    final roundsClamped = rounds.clamp(1, 4);

    for (var r = 1; r <= roundsClamped; r++) {
      // 每轮并行：所有子代理看到上轮记录，各自回应。
      final roundOutputs = await Future.wait(
        perspectives.map((p) async {
          final system = '你是讨论参与者「${p.$1}」。${p.$2}\n'
              '围绕主题给出你的专业见解。讨论规则：观点要具体、可反驳、'
              '能补充或修正他人的意见。用中文。';
          final messages = <Map<String, dynamic>>[
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': '主题：$topic\n\n讨论记录：\n'
                '${transcript.isEmpty ? '(这是第一轮，请给出你的初始见解)' : transcript.join('\n')}'},
          ];
          try {
            final turn = await llm.chatStream(messages: messages);
            return (p.$1, turn.content ?? '(无发言)');
          } catch (e) {
            return (p.$1, '(发言失败：$e)');
          }
        }),
      );

      // 把本轮发言追加到共享记录。
      for (final (name, text) in roundOutputs) {
        transcript.add('「$name」：$text');
      }
    }

    // 主模型综合所有讨论给最终结论。
    try {
      final finalTurn = await llm.chatStream(messages: [
        {
          'role': 'system',
          'content': '你是一位讨论主持人。综合下面所有专家的讨论，给出一个'
              '清晰的最终结论：总结共识、点明分歧、给出你的判断。用中文。',
        },
        {
          'role': 'user',
          'content': '主题：$topic\n\n完整讨论记录：\n${transcript.join('\n')}',
        },
      ]);
      final summary = finalTurn.content ?? '';
      return summary.isNotEmpty
          ? summary
          : '讨论完成，但综合失败。\n\n${transcript.join('\n')}';
    } catch (e) {
      return '讨论完成，但综合失败：$e\n\n${transcript.join('\n')}';
    }
  }

  /// 从历史消息检索与任务相关的上下文片段（FTS5 词法，工程检索一期）。
  Future<List<ContextHit>> _retrieveRelevantContext(String task) async {
    final sdb = _sessionDb;
    if (sdb == null) return [];
    try {
      return await retrieveRelevantContext(
        db: sdb,
        query: task,
        sessionId: _currentSessionId, // 限定当前会话，避免引用别的会话旧信息。
        limit: 5,
      );
    } catch (_) {
      return [];
    }
  }

  /// cron 触发回调：执行任务并把结果作为 assistant 消息加入对话。
  Future<void> _fireCronJob(CronJob job) async {
    if (!mounted) return;
    // 显示 cron 触发的提示。
    _addAssistant('⏰ [定时任务 ${job.id}] ${job.schedule}\n任务：${job.task}');
    // 附带 cron 工具集：任务文本里若写了「做完删除本任务」，子代理才真正有权删。
    final result =
        await _runSubAgent(job.task, const ['file', 'web', 'git', 'cron'], 0);
    if (!mounted) return;
    _addAssistant('[定时任务完成]\n$result');
  }

  /// clarify 回调：弹对话框收集用户答案。
  Future<String> _showClarifyDialog(
    String question,
    List<String> choices,
    bool multiSelect,
  ) async {
    final controller = TextEditingController();
    final selected = <String>{};
    final answer = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Hermes 想确认一下'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(question),
              ),
              if (choices.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final c in choices)
                  CheckboxListTile(
                    title: Text(c),
                    value: selected.contains(c),
                    dense: true,
                    onChanged: (v) => setDialogState(() {
                      if (multiSelect) {
                        if (v == true) {
                          selected.add(c);
                        } else {
                          selected.remove(c);
                        }
                      } else {
                        selected
                          ..clear()
                          ..add(c);
                      }
                    }),
                  ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: '或直接输入回答',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('跳过'),
            ),
            FilledButton(
              onPressed: () {
                final typed = controller.text.trim();
                if (typed.isNotEmpty) {
                  Navigator.pop(ctx, typed);
                } else if (selected.isNotEmpty) {
                  Navigator.pop(ctx, selected.join('、'));
                } else {
                  Navigator.pop(ctx, '');
                }
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    return answer ?? '';
  }

  /// 只读工具集（plan 模式用）：过滤掉写操作，防 plan 阶段误改文件。
  List<Map<String, dynamic>> _readOnlyTools() {
    const readOnly = {
      'read_file', 'search_files', 'git_status', 'git_diff', 'git_log',
      'git_branch', 'git_version',
    };
    final all = getToolDefinitions(
      enabledToolsets: const ['file', 'git'],
      quietMode: true,
    );
    return [
      for (final t in all)
        if (readOnly.contains((t['function'] as Map)['name'])) t,
    ];
  }

  /// 当前工作流（按 _workflowId，未知则回退通用）。
  AgentWorkflow get _currentWorkflow =>
      findWorkflow(_workflowId) ?? builtinWorkflows.last;

  /// 按工作流构建系统提示（人设 + 委派/计划策略 + 工程检索 + 技能 + 外部权限）。
  String _buildWorkflowPrompt({String contextBlock = ''}) {
    var prompt = _currentWorkflow.buildSystemPrompt(
      contextBlock: contextBlock,
      skillBlock: buildSkillsSystemPrompt(),
    );
    // 公司模式：追加部门列表，让 CEO 知道有哪些团队可用。
    if (_currentWorkflow.id == 'company') {
      prompt += '${departmentsSummary()}\n\n根据任务性质选择部门并分派。';
    }
    if (fileToolsAllowExternal) {
      prompt += '\n\n你已获准访问公共存储目录（/sdcard/Download、'
          '/sdcard/Documents 等）。用户可能请你读取、搜索或编辑这些目录里的'
          '文件（如课件、笔记、图片）。访问公共目录请用绝对路径，例如 '
          '`/sdcard/Download/文件名`。';
    }
    return prompt;
  }

  /// 把文件工具的 cwd 配置到 App documents 目录（隔离墙边界）。
  /// 不配置的话 Android 上 Directory.current 是 `/`，search_files 会递归
  /// 遍历整个文件系统导致卡死。
  /// 同时按「所有文件访问」权限决定是否允许访问公共目录。
  Future<void> _initCwd() async {
    // 各子系统独立初始化：任一失败不拖垮其他。
    final String dir;
    try {
      dir = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      configureFileTools(cwd: null);
      return;
    }
    rememberFileToolsCwd(dir);
    try {
      // 按「所有文件访问」权限设置 file_tools：cwd = documents + 外部访问开关。
      await syncExternalAccessPermission(fallbackCwd: dir);
    } catch (_) {}
    // 记忆存储。
    try {
      registerMemoryTool(baseDir: dir);
      _memory = MemoryManager(store: memoryStore!);
    } catch (_) {}
    // 自定义部门（公司模式）。
    try {
      await loadCustomDepartments();
    } catch (_) {}
    // 会话库。
    try {
      _sessionDb = SessionDB(dbPath: '$dir/state.db');
      await _sessionDb!.init();
      sessionDb = _sessionDb;
      // 固定会话 id：跨重启恢复同一会话历史（不累积孤儿会话）。
      _currentSessionId = 'main';
      await _sessionDb!.createSession(_currentSessionId!, source: 'app');
    } catch (_) {}
    // skill 系统。
    try {
      final skillsRoot = '$dir/skills';
      Directory(skillsRoot).createSync(recursive: true);
      registerSkillTools(skillsRoot: skillsRoot);
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _running) return;
    _controller.clear();

    final config = await JailerConfig.load();
    if (config == null) {
      _addUser(text);
      _addAssistant('请先在设置中配置 AI（厂商 + 模型 + API Key）。');
      return;
    }

    _addUser(text);

    // Plan 模式：UI 开关开启，或当前工作流要求先计划（planGate）。
    final needPlan = _planMode || _currentWorkflow.planGate;
    if (needPlan) {
      _pendingTask = text;
      await _generatePlan(text);
      return;
    }

    // 非 plan 模式：直接执行（完整工具集）。
    await _runTaskWithFullTools(text);
  }

  void _addUser(String text) {
    setState(() => _messages.add(_ChatMessage.user(text)));
  }

  void _addAssistant(String text) {
    setState(() => _messages.add(_ChatMessage.assistant(text)));
  }

  @override
  Widget build(BuildContext context) {
    // ESC = 停止当前生成。
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _stop,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      appBar: AppBar(
        title: const Text('Hermes'),
        actions: [
          // 工作流选择器。
          PopupMenuButton<String>(
            tooltip: '工作流：${_currentWorkflow.name}',
            onSelected: (id) => setState(() => _workflowId = id),
            itemBuilder: (_) => [
              for (final w in builtinWorkflows)
                PopupMenuItem(
                  value: w.id,
                  child: Row(
                    children: [
                      Icon(
                        w.id == 'coding'
                            ? Icons.code
                            : w.id == 'research'
                                ? Icons.search
                                : w.id == 'company'
                                    ? Icons.apartment
                                    : Icons.home,
                        size: 18,
                        color: _workflowId == w.id
                            ? context.appPalette.primary
                            : context.appPalette.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(w.name),
                                if (_workflowId == w.id) ...[
                                  SizedBox(width: 6),
                                  Icon(Icons.check,
                                      size: 14, color: context.appPalette.primary),
                                ],
                              ],
                            ),
                            Text(
                              w.description,
                              style: TextStyle(
                                  fontSize: 11, color: context.appPalette.textSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.tune, size: 20,
                  color: _currentWorkflow.id == 'coding'
                      ? context.appPalette.primary
                      : context.appPalette.textSecondary),
            ),
          ),
          // 更多菜单：计划/GitHub/设置（收纳二级入口）。
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) {
              switch (v) {
                case 'new_session':
                  _newSession();
                case 'plan':
                  setState(() => _planMode = !_planMode);
                case 'github':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const GitHubScreen()),
                  );
                case 'settings':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => SettingsScreen()),
                  );
                case 'check_update':
                  _checkForUpdateManually();
                case 'files':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FileBrowserScreen()),
                  );
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'new_session',
                child: Row(
                  children: [
                    Icon(Icons.add_comment, size: 18, color: context.appPalette.textSecondary),
                    SizedBox(width: 8),
                    Text('新建会话'),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'plan',
                child: Row(
                  children: [
                    Icon(_planMode ? Icons.check_circle : Icons.rule,
                        size: 18,
                        color: _planMode ? context.appPalette.primary : context.appPalette.textSecondary),
                    const SizedBox(width: 8),
                    Text(_planMode ? '计划模式（开）' : '计划模式（关）'),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'github',
                child: Row(
                  children: [
                    Icon(Icons.code, size: 18, color: context.appPalette.textSecondary),
                    SizedBox(width: 8),
                    Text('GitHub'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings, size: 18, color: context.appPalette.textSecondary),
                    SizedBox(width: 8),
                    Text('设置'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'check_update',
                child: Row(
                  children: [
                    Icon(Icons.system_update_alt, size: 18, color: context.appPalette.textSecondary),
                    SizedBox(width: 8),
                    Text('检查更新'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'files',
                child: Row(
                  children: [
                    Icon(Icons.code, size: 18, color: context.appPalette.textSecondary),
                    SizedBox(width: 8),
                    Text('代码'),
                  ],
                ),
              ),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.more_vert),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        'Hermes —— 沙盒内的 agent。\n输入任务试试，'
                        '比如：在 notes 目录写一首关于安卓的俳句并读给我看',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.appPalette.textSecondary),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final m = _messages[i];
                      return _buildMessage(m);
                    },
                  ),
          ),
          if (_running)
            const LinearProgressIndicator(minHeight: 2),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: '输入任务…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: _running
                        ? const Icon(Icons.stop)
                        : const Icon(Icons.send),
                    onPressed: _running ? _stop : _send,
                    tooltip: _running ? '停止生成' : '发送',
                  ),
                ],
              ),
            ),
          ),
        ],
        ),
        ),
      ),
    );
  }

  Widget _buildMessage(_ChatMessage m) {
    switch (m.role) {
      case 'user':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(m.text ?? ''),
          ),
        );
      case 'assistant':
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            child: HermesMarkdown(
              data: m.text ?? '',
              selectable: true,
            ),
          ),
        );
      case 'tool':
        // 计划审批卡：批准/拒绝按钮。
        if (m.toolName == 'plan_approval') {
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border.all(color: context.appPalette.primary, width: 1.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.rule, color: context.appPalette.primary, size: 16),
                    SizedBox(width: 6),
                    Text('计划已生成，是否执行？',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          _executePlan(_pendingTask ?? '继续');
                        },
                        style: FilledButton.styleFrom(backgroundColor: context.appPalette.primary),
                        child: const Text('批准并执行'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _pendingPlan = null;
                            _messages.removeLast();
                          });
                        },
                        child: const Text('拒绝'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }
        // 普通工具调用卡片。
        final running = m.toolStatus == 'running';
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (running)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.check_circle,
                    size: 14, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                '🔧 ${m.toolName} ${running ? '运行中…' : '完成'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
