import 'dart:io';

import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:path_provider/path_provider.dart';

import 'agent/agent.dart';
import 'config/jailer_config.dart';
import 'db/session_db.dart';
import 'llm/openai_llm.dart';
import 'screens/settings_screen.dart';
import 'services/storage_permission.dart';
import 'tools/file_tools.dart';
import 'tools/memory_manager.dart';
import 'tools/memory_tool.dart';
import 'tools/model_tools.dart';
import 'tools/session_search_tool.dart';
import 'tools/skills_tool.dart';
import 'tools/todo_tool.dart';
import 'tools/web_tools.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const JailerApp());
}

class JailerApp extends StatelessWidget {
  const JailerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jailer',
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
    registerMemoryTool();
    registerWebTools();
    registerTodoTool();
    registerSessionSearchTool();
    _initCwd();
  }

  /// 构建系统提示（含记忆 + skill 索引）。
  String _systemPrompt() {
    var prompt = '你是 Jailer，一个运行在 Android App 沙盒里的 agent。'
        '你可以调用工具操作 App 自己的文件空间（read_file / write_file / '
        'patch / search_files），管理记忆（memory），上网（web_search / '
        'web_extract），管理待办（todo），回顾会话（session_search），'
        '以及使用技能（skills_list / skill_view / skill_manage）。'
        '用中文回答。';
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
    try {
      final dir = await getApplicationDocumentsDirectory();
      rememberFileToolsCwd(dir.path);
      await syncExternalAccessPermission();
      // 初始化记忆存储（MEMORY.md/USER.md 在 App documents/memories 下）。
      registerMemoryTool(baseDir: dir.path);
      _memory = MemoryManager(store: memoryStore!);
      // 初始化会话库（state.db 在 App documents 下）。
      _sessionDb = SessionDB(dbPath: '${dir.path}/state.db');
      await _sessionDb!.init();
      sessionDb = _sessionDb;
      _currentSessionId =
          's${DateTime.now().millisecondsSinceEpoch}';
      await _sessionDb!.createSession(_currentSessionId!, source: 'app');
      // 初始化 skill 系统（skills/ 在 App documents 下）。
      final skillsRoot = '${dir.path}/skills';
      Directory(skillsRoot).createSync(recursive: true);
      registerSkillTools(skillsRoot: skillsRoot);
    } catch (_) {
      configureFileTools(cwd: null);
    }
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
    final agent = JailerAgent(
      llm: llm,
      memoryManager: _memory,
      sessionDb: _sessionDb,
      sessionId: _currentSessionId,
      systemPrompt: _systemPrompt(),
      toolDefinitionsProvider: () => getToolDefinitions(
        enabledToolsets: const ['file', 'web', 'memory', 'todo', 'skills'],
        quietMode: true,
      ),
      onDelta: (delta) {
        // 流式打字：累积到当前 assistant 消息。
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
      if (result.finalResponse != null &&
          _messages.last.role == 'assistant' &&
          _messages.last.text != result.finalResponse) {
        setState(() {
          _messages[_messages.length - 1] =
              _ChatMessage.assistant(result.finalResponse);
        });
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
        title: const Text('Jailer'),
        actions: [
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
                    child: Text('Jailer —— 沙盒内的 agent。\n输入任务试试，'
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
            child: MarkdownWidget(
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
