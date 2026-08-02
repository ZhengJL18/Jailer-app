/// skill 管理页：查看/创建/删除技能。
///
/// 复用 SkillDiscovery + skills_tool.dart 的工具函数。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../skills/skill_discovery.dart';
import '../tools/skills_tool.dart';

class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  List<SkillMeta> _skills = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final discovery = skillDiscovery;
    if (discovery == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _skills = discovery.findAllSkills();
      _loading = false;
    });
  }

  Future<void> _createSkill() async {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final contentController = TextEditingController();
    final categoryController = TextEditingController(text: 'general');
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('创建技能'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameController, decoration: const InputDecoration(labelText: '名称（小写连字符）')),
                TextField(controller: descController, decoration: const InputDecoration(labelText: '描述（≤60 字符）')),
                TextField(controller: categoryController, decoration: const InputDecoration(labelText: '分类')),
                TextField(
                  controller: contentController,
                  maxLines: 8,
                  decoration: const InputDecoration(labelText: 'SKILL.md 内容（含 --- frontmatter ---）'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
        ],
      ),
    );
    if (created != true) return;
    final content = contentController.text.trim();
    if (content.isEmpty) {
      // 用户没填全文，用 name/desc 拼一个。
      contentController.text =
          '---\nname: ${nameController.text.trim()}\ndescription: ${descController.text.trim()}\n---\n\n# ${nameController.text.trim()}\n';
    }
    final result = skillManageTool(
      action: 'create',
      name: nameController.text.trim(),
      content: content.isEmpty
          ? '---\nname: ${nameController.text.trim()}\ndescription: ${descController.text.trim()}\n---\n'
          : content,
      category: categoryController.text.trim(),
    );
    _showResult(result);
    await _load();
  }

  Future<void> _viewSkill(SkillMeta skill) async {
    final result = skillViewTool(name: skill.name);
    final map = jsonDecode(result) as Map;
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SkillViewScreen(
          name: skill.name,
          content: map['content'] as String? ?? '',
        ),
      ),
    );
  }

  Future<void> _deleteSkill(SkillMeta skill) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除技能'),
        content: Text('确定删除技能 ${skill.name} 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = skillManageTool(action: 'delete', name: skill.name);
    _showResult(result);
    await _load();
  }

  void _showResult(String result) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.length > 100 ? result.substring(0, 100) : result)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('技能管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '创建技能',
            onPressed: _createSkill,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _skills.isEmpty
              ? const Center(child: Text('暂无技能，点右上角 + 创建'))
              : ListView.builder(
                  itemCount: _skills.length,
                  itemBuilder: (context, i) {
                    final s = _skills[i];
                    return ListTile(
                      leading: const Icon(Icons.menu_book),
                      title: Text(s.name),
                      subtitle: Text('${s.category} · ${s.description}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteSkill(s),
                      ),
                      onTap: () => _viewSkill(s),
                    );
                  },
                ),
    );
  }
}

/// 单个 skill 详情查看。
class _SkillViewScreen extends StatelessWidget {
  final String name;
  final String content;

  const _SkillViewScreen({required this.name, required this.content});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: SelectableText(
            content,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
    );
  }
}
