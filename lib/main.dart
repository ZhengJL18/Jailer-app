import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'agent/agent.dart';
import 'agent/context_compressor.dart';
import 'config/jailer_config.dart';
import 'db/session_db.dart';
import 'llm/openai_llm.dart';
import 'screens/github_screen.dart';
import 'screens/settings_screen.dart';
import 'services/storage_permission.dart';
import 'tools/clarify_tool.dart';
import 'tools/cron_tools.dart';
import 'tools/delegate_tool.dart';
import 'tools/file_tools.dart';
import 'tools/git_tools.dart';
import 'tools/memory_manager.dart';
import 'tools/memory_tool.dart';
import 'tools/model_tools.dart';
import 'tools/session_search_tool.dart';
import 'tools/skills_tool.dart';
import 'tools/todo_tool.dart';
import 'tools/vision_tool.dart';
import 'tools/web_tools.dart';
import 'widgets/markdown_math.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const JailerApp());
}

/// 对话历史页「继续聊天」回调：切换 ChatScreen 到指定会话。
/// 由 ChatScreen 注册，HistoryScreen 调用。
Future<void> Function(String sessionId)? resumeSessionHandler;

class JailerApp extends StatelessWidget {
  const JailerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hermes',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
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
  MemoryManager? _memory;
  SessionDB? _sessionDb;
  String? _currentSessionId;

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
    registerCronTools();
    cronFireHandler = _fireCronJob;
    startCronScheduler();
    registerVisionTool();
    // 对话历史页「继续聊天」→ 切换到指定会话并加载历史。
    resumeSessionHandler = _resumeSession;
    _initCwd();
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

  /// delegate 回调：子 agent 独立执行任务，返回结果摘要。
  Future<String> _runSubAgent(String task, List<String>? toolsets) async {
    final config = await JailerConfig.load();
    if (config == null) {
      return '子任务未执行：AI 未配置';
    }
    final llm = OpenAiLlmClient(config: config.toLlmConfig());
    final subAgent = JailerAgent(
      llm: llm,
      systemPrompt: '你是 Hermes 的子代理。独立完成给定任务并简洁汇报结果。'
          '用中文。',
      toolDefinitionsProvider: () => getToolDefinitions(
        enabledToolsets: toolsets ?? const ['file', 'web', 'git'],
        quietMode: true,
      ),
      maxIterations: 20,
    );
    try {
      final result = await subAgent.runConversation(task);
      return result.finalResponse ?? '(子代理无输出)';
    } catch (e) {
      return '子任务失败：$e';
    }
  }

  /// cron 触发回调：执行任务并把结果作为 assistant 消息加入对话。
  Future<void> _fireCronJob(CronJob job) async {
    if (!mounted) return;
    // 显示 cron 触发的提示。
    _addAssistant('⏰ [定时任务 ${job.id}] ${job.schedule}\n任务：${job.task}');
    final result = await _runSubAgent(job.task, const ['file', 'web', 'git']);
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

  /// 构建系统提示（含记忆 + skill 索引）。
  String _systemPrompt() {
    final externalAllowed = fileToolsAllowExternal;
    var prompt = '你是 Hermes，一个运行在 Android App 沙盒里的 agent。'
        '你可以调用工具操作文件（read_file / write_file / patch / '
        'search_files），管理记忆（memory），上网（web_search / '
        'web_extract），管理待办（todo），回顾会话（session_search），'
        '以及使用技能（skills_list / skill_view / skill_manage）。'
        '用中文回答。';
    if (externalAllowed) {
      prompt += '\n\n你已获准访问公共存储目录（/sdcard/Download、'
          '/sdcard/Documents 等）。用户可能请你读取、搜索或编辑这些目录里的'
          '文件（如课件、笔记、图片）。访问公共目录请用绝对路径，例如 '
          '`/sdcard/Download/文件名`。';
    }
    final skillBlock = buildSkillsSystemPrompt();
    if (skillBlock.isNotEmpty) {
      prompt = '$prompt\n\n$skillBlock';
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
    setState(() {
      _running = true;
      _toolRunningIdx.clear();
    });

    final llm = OpenAiLlmClient(config: config.toLlmConfig());
    // 上下文压缩：超阈值时用主 LLM 摘要中间段（手机内存刚需）。
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
    final agent = JailerAgent(
      llm: llm,
      memoryManager: _memory,
      sessionDb: _sessionDb,
      sessionId: _currentSessionId,
      contextCompressor: compressor,
      systemPrompt: _systemPrompt(),
      toolDefinitionsProvider: () => getToolDefinitions(
        enabledToolsets: const [
          'file',
          'web',
          'memory',
          'todo',
          'skills',
          'session_search',
          'git',
          'clarify',
          'delegate',
          'cron',
          'vision',
        ],
        quietMode: true,
      ),
      onDelta: (delta) {
        setState(() {
          // 若上一条是工具事件，则开新 assistant 消息；否则累积到最后一条。
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
            // 新增 running 卡片，记录索引。
            _toolRunningIdx[name] = _messages.length;
            _messages.add(_ChatMessage.tool(name, status));
          } else {
            // 找到对应 running 卡片更新为 done；找不到则新增。
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
      final result = await agent.runConversation(text);
      // 只在完成时用 finalResponse 覆盖流式内容；预算耗尽/失败（completed=false）
      // 时保留已流式的半截回答，不覆盖为用户看不到的错误文案。
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
        // 预算耗尽：保留流式内容，追加提示。
        _addAssistant(result.finalResponse!);
      }
    } catch (e) {
      _addAssistant('出错了：$e');
    } finally {
      setState(() => _running = false);
    }
  }

  void _addUser(String text) {
    setState(() => _messages.add(_ChatMessage.user(text)));
  }

  void _addAssistant(String text) {
    setState(() => _messages.add(_ChatMessage.assistant(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hermes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.code),
            tooltip: 'GitHub',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const GitHubScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text('Hermes —— 沙盒内的 agent。\n输入任务试试，'
                        '比如：在 notes 目录写一首关于安卓的俳句并读给我看'),
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
                    icon: const Icon(Icons.send),
                    onPressed: _running ? null : _send,
                  ),
                ],
              ),
            ),
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
      case 'tool':
        // 工具调用卡片。
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
