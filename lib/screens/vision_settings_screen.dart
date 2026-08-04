/// 视觉模型配置页：配置 vision_analyze 的图像分析模型（独立于主对话模型）。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/theme_ext.dart';

class VisionSettingsScreen extends StatefulWidget {
  const VisionSettingsScreen({super.key});

  @override
  State<VisionSettingsScreen> createState() => _VisionSettingsScreenState();
}

class _VisionSettingsScreenState extends State<VisionSettingsScreen> {
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
      _keyController.text = prefs.getString('vision_api_key') ?? '';
      _urlController.text = prefs.getString('vision_base_url') ?? '';
      _modelController.text = prefs.getString('vision_model') ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      setState(() => _msg = '请输入视觉模型 API key');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vision_api_key', key);
    await prefs.setString('vision_base_url', _urlController.text.trim());
    await prefs.setString('vision_model', _modelController.text.trim());
    if (!mounted) return;
    setState(() => _msg = '已保存');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('视觉模型')),
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
                        Text(
                          '配置 vision_analyze 用的多模态模型。'
                          '支持 OpenAI 兼容的视觉接口（如 Qwen-VL、Gemini、GPT-4V）。',
                          style: TextStyle(fontSize: 13, color: context.appPalette.textSecondary),
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
                            labelText: '模型名',
                            hintText: '如 qwen-vl-max / gemini-2.0-flash',
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
