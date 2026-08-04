/// 部门管理页：配置公司模式的部门（角色/工具），自定义 + 保存。
library;

import 'package:flutter/material.dart';

import '../agent/company.dart';

class DepartmentScreen extends StatefulWidget {
  const DepartmentScreen({super.key});

  @override
  State<DepartmentScreen> createState() => _DepartmentScreenState();
}

class _DepartmentScreenState extends State<DepartmentScreen> {
  late List<AgentDepartment> _departments;
  bool _loading = true;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _departments = [...activeDepartments];
    _loading = false;
  }

  Future<void> _save() async {
    await saveCustomDepartments(_departments);
    if (!mounted) return;
    setState(() => _msg = '已保存（公司模式将使用这些部门）');
  }

  Future<void> _reset() async {
    await loadCustomDepartments();
    if (!mounted) return;
    setState(() {
      _departments = [...activeDepartments];
      _msg = '已恢复默认部门';
    });
  }

  Future<void> _addDepartment() async {
    final idCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final rolesCtrl = TextEditingController();
    final toolsCtrl = TextEditingController(text: 'file, web');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增部门'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: idCtrl, decoration: const InputDecoration(labelText: 'id（英文，如 data）')),
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '名称（如 数据部）')),
              TextField(controller: descCtrl, decoration: const InputDecoration(labelText: '描述')),
              TextField(controller: rolesCtrl, decoration: const InputDecoration(labelText: '角色（逗号分隔，如 分析师/清洗员）')),
              TextField(controller: toolsCtrl, decoration: const InputDecoration(labelText: '工具集（逗号分隔，如 file, web, git）')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('新增')),
        ],
      ),
    );
    if (ok != true) return;
    final id = idCtrl.text.trim();
    if (id.isEmpty) return;
    setState(() {
      _departments.add(AgentDepartment(
        id: id,
        name: nameCtrl.text.trim().isEmpty ? id : nameCtrl.text.trim(),
        description: descCtrl.text.trim(),
        roles: rolesCtrl.text
            .split(RegExp(r'[,，]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        toolsets: toolsCtrl.text
            .split(RegExp(r'[,，]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
      ));
    });
  }

  Future<void> _editDepartment(int index) async {
    final d = _departments[index];
    final nameCtrl = TextEditingController(text: d.name);
    final descCtrl = TextEditingController(text: d.description);
    final rolesCtrl = TextEditingController(text: d.roles.join(','));
    final toolsCtrl = TextEditingController(text: d.toolsets.join(','));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑部门 ${d.id}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '名称')),
              TextField(controller: descCtrl, decoration: const InputDecoration(labelText: '描述')),
              TextField(controller: rolesCtrl, decoration: const InputDecoration(labelText: '角色（逗号分隔）')),
              TextField(controller: toolsCtrl, decoration: const InputDecoration(labelText: '工具集（逗号分隔）')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _departments[index] = AgentDepartment(
        id: d.id,
        name: nameCtrl.text.trim().isEmpty ? d.id : nameCtrl.text.trim(),
        description: descCtrl.text.trim(),
        roles: rolesCtrl.text
            .split(RegExp(r'[,，]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        toolsets: toolsCtrl.text
            .split(RegExp(r'[,，]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('部门管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '恢复默认',
            onPressed: _reset,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新增部门',
            onPressed: _addDepartment,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_msg != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(_msg!, style: const TextStyle(fontSize: 12)),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _departments.length,
                    itemBuilder: (context, i) {
                      final d = _departments[i];
                      return ListTile(
                        leading: const Icon(Icons.apartment),
                        title: Text(d.name),
                        subtitle: Text(
                            '${d.roles.join('/')} · ${d.toolsets.join(',')}'),
                        onTap: () => _editDepartment(i),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save),
                    label: const Text('保存部门配置'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
