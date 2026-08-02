/// 对话历史管理页：浏览/查看/删除会话。
///
/// 复用 SessionDB（listSessions / getMessages）+ session_search 工具。
library;

import 'package:flutter/material.dart';

import '../tools/session_search_tool.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sdb = sessionDb;
    if (sdb == null) {
      setState(() => _loading = false);
      return;
    }
    final sessions = await sdb.listSessions(limit: 100);
    setState(() {
      _sessions = sessions;
      _loading = false;
    });
  }

  Future<void> _viewSession(String sessionId) async {
    final sdb = sessionDb;
    if (sdb == null) return;
    final result = await sessionSearchTool(sessionId: sessionId, db: sdb);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SessionViewScreen(sessionId: sessionId, dump: result),
      ),
    );
  }

  Future<void> _deleteSession(String sessionId) async {
    final sdb = sessionDb;
    if (sdb == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除会话 $sessionId 吗？此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await sdb.deleteSession(sessionId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('对话历史')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? const Center(child: Text('暂无历史会话'))
              : ListView.builder(
                  itemCount: _sessions.length,
                  itemBuilder: (context, i) {
                    final s = _sessions[i];
                    final id = s['id'] as String? ?? '';
                    final title = s['title'] as String? ?? '会话 $id';
                    final count = s['message_count'] as int? ?? 0;
                    final model = s['model'] as String? ?? '';
                    return ListTile(
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: Text(title),
                      subtitle: Text('$count 条消息${model.isNotEmpty ? ' · $model' : ''}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteSession(id),
                      ),
                      onTap: () => _viewSession(id),
                    );
                  },
                ),
    );
  }
}

/// 单个会话详情查看。
class _SessionViewScreen extends StatelessWidget {
  final String sessionId;
  final String dump;

  const _SessionViewScreen({required this.sessionId, required this.dump});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('会话 $sessionId')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: SelectableText(
            dump,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}
