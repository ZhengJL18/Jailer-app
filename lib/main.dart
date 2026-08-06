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
import 'refine/edit_journal.dart';
import 'refine/prompt_notes_store.dart';
import 'refine/refine_pipeline.dart';
import 'refine/trajectory_store.dart';
import 'screens/code_editor_screen.dart';
import 'screens/file_browser_screen.dart';
import 'screens/github_screen.dart';
import 'screens/settings_screen.dart';
import 'services/multi_agent.dart';
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
  final String role; // user / assistant / tool / discussion / refine
  final String? text;
  final String? toolName;
  final String? toolStatus;
  // discussion 专用：进度/分工展示。
  final bool discussionRunning;
  final int? discussionRound;
  final int? discussionTotalRounds;
  final String? discussionPerspective;
  final List<(String, String)> discussionPerspectives; // 每视角最终发言。
  final String? discussionSummary;
  // refine 专用：自进化建议卡。
  final List<RefineProposal> refineProposals;
  final bool refineApplied;
  final bool refineIgnored;

  _ChatMessage.user(this.text)
      : role = 'user',
        toolName = null,
        toolStatus = null,
        discussionRunning = false,
        discussionRound = null,
        discussionTotalRounds = null,
        discussionPerspective = null,
        discussionPerspectives = const [],
        discussionSummary = null,
        refineProposals = const [],
        refineApplied = false,
        refineIgnored = false;
  _ChatMessage.assistant(this.text)
      : role = 'assistant',
        toolName = null,
        toolStatus = null,
        discussionRunning = false,
        discussionRound = null,
        discussionTotalRounds = null,
        discussionPerspective = null,
        discussionPerspectives = const [],
        discussionSummary = null,
        refineProposals = const [],
        refineApplied = false,
        refineIgnored = false;
  _ChatMessage.tool(this.toolName, this.toolStatus)
      : role = 'tool',
        text = null,
        discussionRunning = false,
        discussionRound = null,
        discussionTotalRounds = null,
        discussionPerspective = null,
        discussionPerspectives = const [],
        discussionSummary = null,
        refineProposals = const [],
        refineApplied = false,
        refineIgnored = false;
  _ChatMessage.discussion({
    required this.discussionRunning,
    this.discussionRound,
    this.discussionTotalRounds,
    this.discussionPerspective,
    this.discussionPerspectives = const [],
    this.discussionSummary,
  })  : role = 'discussion',
        text = null,
        toolName = null,
        toolStatus = null,
        refineProposals = const [],
        refineApplied = false,
        refineIgnored = false;
  _ChatMessage.refine({
    required this.refineProposals,
    this.refineApplied = false,
    this.refineIgnored = false,
  })  : role = 'refine',
        text = null,
        toolName = null,
        toolStatus = null,
        discussionRunning = false,
        discussionRound = null,
        discussionTotalRounds = null,
        discussionPerspective = null,
        discussionPerspectives = const [],
        discussionSummary = null;
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
  MultiAgentService? _multiAgent;
  int _discussionMsgIdx = -1; // 当前讨论消息索引（-1 表示无）。
  final Map<String, String> _lastPerspectiveOutputs = {}; // 视角 → 最终发言。
  MemoryManager? _memory;
  SessionDB? _sessionDb;
  String? _currentSessionId;
  // 自进化（Continual Harness）存储。
  TrajectoryStore? _trajectory;
  PromptNotesStore? _promptNotes;
  EditJournal? _editJournal;
  RefinePipeline? _refine;
  bool _refineSuggesting = false;

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
    delegateHandler = (task, toolsets, depth) async {
      final svc = await _ensureMultiAgent();
      if (svc == null) return '子任务未执行：AI 未配置';
      return svc.runSubAgent(
        task: task,
        toolsets: toolsets,
        depth: depth,
        onToolEvent: _onSubAgentToolEvent,
      );
    };
    registerMoaTool();
    moaHandler = (topic, rounds) async {
      final svc = await _ensureMultiAgent();
      if (svc == null) return '讨论未执行：AI 未配置';
      return svc.runDiscussion(
        topic: topic,
        rounds: rounds,
        onProgress: _onMoaProgress,
      );
    };
    registerCompanyTool();
    departmentHandler = (department, task, depth) async {
      final svc = await _ensureMultiAgent();
      if (svc == null) return '部门任务未执行：AI 未配置';
      return svc.runDepartment(
        department: department,
        task: task,
        depth: depth,
        onToolEvent: _onSubAgentToolEvent,
      );
    };
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
    ConversationResult? lastResult;
    var ranError = false;
    try {
      final result = await _activeAgent!.runConversation(task);
      lastResult = result;
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
      ranError = true;
      _addAssistant('出错了：$e');
    } finally {
      _activeAgent = null;
      setState(() => _running = false);
    }
    _recordTrajectoryAndRefine(task, lastResult, ranError);
  }

  /// 任务完成后：写轨迹 + fire-and-forget 触发自进化建议。
  void _recordTrajectoryAndRefine(
    String task,
    ConversationResult? result,
    bool ranError,
  ) {
    final traj = _trajectory;
    if (traj == null) return;
    // 提取调用过的工具名（从 assistant 消息的 tool_calls）。
    final toolNames = <String>[];
    if (result != null) {
      for (final m in result.messages) {
        final calls = m['tool_calls'];
        if (calls is List) {
          for (final c in calls) {
            if (c is Map<String, dynamic>) {
              final fn = c['function'];
              if (fn is Map && fn['name'] is String) {
                toolNames.add(fn['name'] as String);
              }
            }
          }
        }
      }
    }
    final outcome = ranError
        ? 'error'
        : (result?.completed ?? false)
            ? 'success'
            : (result?.error == 'cancelled' ? 'cancelled' : 'budget');
    traj.append(TrajectoryRecord(
      ts: DateTime.now(),
      sessionId: _currentSessionId ?? 'main',
      userPrompt: task,
      toolNames: toolNames.toSet().toList(),
      completed: result?.completed ?? false,
      outcome: outcome,
      finalExcerpt: result?.finalResponse != null &&
              (result!.finalResponse!.length > 200)
          ? result.finalResponse!.substring(0, 200)
          : result?.finalResponse,
    ));
    // fire-and-forget：不阻塞主流程，建议卡追加到消息流。
    unawaited(_suggestRefine());
  }

  /// 异步跑 refine 提议，非空则追加建议卡。
  Future<void> _suggestRefine() async {
    if (_refineSuggesting) return;
    _refineSuggesting = true;
    try {
      await _suggestRefineInner();
    } finally {
      _refineSuggesting = false;
    }
  }

  Future<void> _suggestRefineInner() async {
    var refine = _refine;
    if (refine == null) {
      final config = await JailerConfig.load();
      final traj = _trajectory;
      final notes = _promptNotes;
      final journal = _editJournal;
      if (config == null || traj == null || notes == null || journal == null) {
        return;
      }
      refine = RefinePipeline(
        llm: OpenAiLlmClient(config: config.toLlmConfig()),
        trajectory: traj,
        journal: journal,
        memory: memoryStore,
        promptNotes: notes,
        skills: skillDiscovery,
      );
      _refine = refine;
    }
    if (!mounted) return;
    final proposals = await refine.suggest();
    if (proposals.isEmpty || !mounted) return;
    setState(() {
      _messages.add(_ChatMessage.refine(refineProposals: proposals));
    });
  }

  /// 接受全部自进化建议。
  void _applyRefineProposals(_ChatMessage msg) {
    final refine = _refine;
    if (refine == null) return;
    for (final p in msg.refineProposals) {
      refine.apply(p);
    }
    final idx = _messages.indexOf(msg);
    if (idx >= 0) {
      setState(() {
        _messages[idx] = _ChatMessage.refine(
          refineProposals: msg.refineProposals,
          refineApplied: true,
        );
      });
    }
  }

  /// 忽略建议卡。
  void _ignoreRefineProposals(_ChatMessage msg) {
    final idx = _messages.indexOf(msg);
    if (idx >= 0) {
      setState(() {
        _messages[idx] = _ChatMessage.refine(
          refineProposals: msg.refineProposals,
          refineIgnored: true,
        );
      });
    }
  }

  /// 惰性创建多代理执行器（子代理/部门/讨论共用，复用连接）。
  Future<MultiAgentService?> _ensureMultiAgent() async {
    if (_multiAgent != null) return _multiAgent;
    final config = await JailerConfig.load();
    if (config == null) return null;
    final fast = await JailerConfig.loadFastConfig();
    _multiAgent = MultiAgentService(
      llm: OpenAiLlmClient(config: config.toLlmConfig()),
      fastLlm: fast != null ? OpenAiLlmClient(config: fast) : null,
      isCancelled: () => _activeAgent?.isCancelled ?? false,
    );
    return _multiAgent;
  }

  /// 子代理/部门角色的工具事件 → UI 工具卡（带「子代理·」前缀，层级可辨）。
  void _onSubAgentToolEvent(String name, String status) {
    if (!mounted) return;
    final displayName = '子代理·$name';
    setState(() {
      if (status == 'running') {
        _toolRunningIdx[displayName] = _messages.length;
        _messages.add(_ChatMessage.tool(displayName, status));
      } else {
        final idx = _toolRunningIdx.remove(displayName);
        if (idx != null && idx < _messages.length) {
          _messages[idx] = _ChatMessage.tool(displayName, status);
        } else {
          _messages.add(_ChatMessage.tool(displayName, status));
        }
      }
    });
  }

  /// MoA 讨论进度 → 更新讨论消息（对齐官方 moa-progress-event 语义）。
  void _onMoaProgress(MoaProgress p) {
    if (!mounted) return;
    setState(() {
      switch (p.stage) {
        case MoaStage.roundStart:
          _upsertDiscussion(_ChatMessage.discussion(
            discussionRunning: true,
            discussionRound: p.round,
            discussionTotalRounds: p.totalRounds,
          ));
        case MoaStage.perspectiveStart:
          _upsertDiscussion(_ChatMessage.discussion(
            discussionRunning: true,
            discussionRound: p.round,
            discussionTotalRounds: p.totalRounds,
            discussionPerspective: p.perspective,
          ));
        case MoaStage.perspectiveDone:
          if (p.perspective != null) {
            _lastPerspectiveOutputs[p.perspective!] = p.output ?? '';
          }
        case MoaStage.synthesizing:
          _upsertDiscussion(_ChatMessage.discussion(
            discussionRunning: true,
            discussionRound: p.round,
            discussionTotalRounds: p.totalRounds,
          ));
        case MoaStage.done:
          _upsertDiscussion(_ChatMessage.discussion(
            discussionRunning: false,
            discussionRound: p.round,
            discussionTotalRounds: p.totalRounds,
            discussionPerspectives: [
              for (final e in _lastPerspectiveOutputs.entries) (e.key, e.value),
            ],
            discussionSummary: p.output,
          ));
          _discussionMsgIdx = -1;
          _lastPerspectiveOutputs.clear();
      }
    });
  }

  /// 插入或更新当前讨论消息（流式累积，同 _toolRunningIdx 模式）。
  void _upsertDiscussion(_ChatMessage msg) {
    if (_discussionMsgIdx >= 0 && _discussionMsgIdx < _messages.length) {
      _messages[_discussionMsgIdx] = msg;
    } else {
      _discussionMsgIdx = _messages.length;
      _messages.add(msg);
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
    final svc = await _ensureMultiAgent();
    final result = svc != null
        ? await svc.runSubAgent(
            task: job.task,
            toolsets: const ['file', 'web', 'git', 'cron'],
            depth: 0,
          )
        : '（AI 未配置）';
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
    // 自进化 prompt notes：注入可自改的补充提示（基础 workflow 提示不可变）。
    final notesBlock = _promptNotes?.formatForSystemPrompt() ?? '';
    if (notesBlock.isNotEmpty) {
      prompt += notesBlock;
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
    // 自进化（Continual Harness）：轨迹 / prompt notes / 编辑台账。
    try {
      _trajectory = TrajectoryStore(filePath: '$dir/refine/trajectory.jsonl');
      _promptNotes = PromptNotesStore(filePath: '$dir/refine/prompt_notes.json');
      _editJournal = EditJournal(filePath: '$dir/refine/edit_journal.json');
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

  /// 自进化建议卡（Continual Harness /refine 的 UI）。
  Widget _buildRefineCard(_ChatMessage m) {
    if (m.refineIgnored) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('已忽略自进化建议',
            style: Theme.of(context).textTheme.bodySmall),
      );
    }
    if (m.refineApplied) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: context.appPalette.primary, width: 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('✅ 已应用 ${m.refineProposals.length} 条自进化建议',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.appPalette.primary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final p in m.refineProposals)
              Text('• ${p.displayLabel}: ${p.content}',
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
          ],
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
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
              Icon(Icons.auto_awesome, color: context.appPalette.primary, size: 16),
              const SizedBox(width: 6),
              Text('自进化建议（${m.refineProposals.length} 条）',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          for (final p in m.refineProposals) ...[
            Text('• [${p.displayLabel}] ${p.content}',
                style: Theme.of(context).textTheme.bodySmall),
            if ((p.trigger ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 1),
                child: Text('适用：${p.trigger}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline)),
              ),
            const SizedBox(height: 4),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => _applyRefineProposals(m),
                  style: FilledButton.styleFrom(
                      backgroundColor: context.appPalette.primary),
                  child: const Text('全部接受'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _ignoreRefineProposals(m),
                  child: const Text('忽略'),
                ),
              ),
            ],
          ),
        ],
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
      case 'refine':
        return _buildRefineCard(m);
      case 'discussion':
        if (m.discussionRunning) {
          final status = m.discussionPerspective != null
              ? '第 ${m.discussionRound}/${m.discussionTotalRounds} 轮 · '
                  '「${m.discussionPerspective}」思考中…'
              : '第 ${m.discussionRound}/${m.discussionTotalRounds} 轮进行中…';
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
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('🗣️ MoA 讨论 $status',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          );
        }
        // 完成：结构化分工块（Reference N — 视角 + 观点 + 综合结论）。
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.record_voice_over,
                      size: 16, color: context.appPalette.primary),
                  const SizedBox(width: 6),
                  Text('🗣️ MoA 讨论完成（${m.discussionTotalRounds} 轮）',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < m.discussionPerspectives.length; i++) ...[
                Text('Reference ${i + 1} — ${m.discussionPerspectives[i].$1}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.appPalette.primary,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(m.discussionPerspectives[i].$2,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
              ],
              const Divider(height: 12),
              Text('📌 综合结论',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(m.discussionSummary ?? '',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
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
