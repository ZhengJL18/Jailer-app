/// 快速模型配置页：配置 delegate 子任务用的快/便宜模型（分级委派）。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FastModelScreen extends StatefulWidget {
  const FastModelScreen({super.key});

  @override
  State<FastModelScreen> createState() => _FastModelScreenState();
}

class _FastModelScreenState extends State<FastModelScreen> {
  final _keyController = TextEditingController();
  final _urlController = TextEditingController();
  final _modelController = TextEditingController();
  bool _loading = true;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _urlController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _keyController.text = prefs.getString('fast_api_key') ?? '';
      _urlController.text = prefs.getString('fast_base_url') ?? '';
      _modelController.text = prefs.getString('fast_model') ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      setState(() => _msg = '请输入快速模型 API key');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fast_api_key', key);
    await prefs.setString('fast_base_url', _urlController.text.trim());
    await prefs.setString('fast_model', _modelController.text.trim());
    if (!mounted) return;
    setState(() => _msg = '已保存（未配置时子任务用主模型）');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('快速模型')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'delegate_task 派发的子任务用这个快速模型处理'
                          '（主模型负责理解/规划/决策）。'
                          '用快/便宜的模型（如 deepseek-chat）可光速解决小任务。'
                          '留空则子任务用主模型。',
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _keyController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'API key',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _modelController,
                          decoration: const InputDecoration(
                            labelText: '快速模型名',
                            hintText: '如 deepseek-chat / gpt-4o-mini',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _urlController,
                          decoration: const InputDecoration(
                            labelText: 'API base URL（可选）',
                            hintText: 'https://.../v1',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (_msg != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(_msg!,
                                style: const TextStyle(fontSize: 12)),
                          ),
                        FilledButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.save),
                          label: const Text('保存'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
