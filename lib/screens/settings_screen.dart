/// 设置页：provider/vendor 下拉 + 模型 + API key + 自定义 baseUrl。
///
/// UI 是新设计（Hermes 无移动端配置页），但 vendor/模型映射来自
/// [providers.dart] 复刻的解析链。
library;

import 'package:flutter/material.dart';

import '../config/jailer_config.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  String _vendor = '';
  String _model = '';
  String _apiKey = '';
  String _baseUrl = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await JailerConfig.load();
    setState(() {
      if (config != null) {
        _vendor = config.vendorId;
        _model = config.model;
        _apiKey = config.apiKey;
        _baseUrl = config.baseUrl;
      } else {
        _vendor = 'deepseek';
        _model = 'deepseek-chat';
      }
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final config = JailerConfig(
      vendorId: _vendor,
      model: _model,
      apiKey: _apiKey.trim(),
      baseUrl: _baseUrl.trim(),
    );
    await config.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存配置')),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final models = vendorModels[_vendor] ?? const <String>[];
    final labels = vendorLabels;

    return Scaffold(
      appBar: AppBar(title: const Text('Jailer 设置')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // vendor 下拉。
            DropdownButtonFormField<String>(
              initialValue: _vendor,
              decoration: const InputDecoration(
                labelText: 'AI 厂商',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final entry in labels.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _vendor = v;
                  // 切换厂商时自动选默认模型。
                  final m = vendorModels[v];
                  if (m != null && m.isNotEmpty) {
                    _model = m.first;
                  }
                });
              },
            ),
            const SizedBox(height: 12),
            // 模型（可编辑文本 + 预设提示）。
            Autocomplete<String>(
              initialValue: TextEditingValue(text: _model),
              optionsBuilder: (text) {
                if (text.text.isEmpty) return const Iterable<String>.empty();
                return models.where(
                    (m) => m.toLowerCase().contains(text.text.toLowerCase()));
              },
              onSelected: (v) => setState(() => _model = v),
              fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                return TextFormField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: const InputDecoration(
                    labelText: '模型',
                    border: OutlineInputBorder(),
                    helperText: '可用模型：',
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '请输入模型' : null,
                );
              },
            ),
            if (models.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: [
                  for (final m in models)
                    ChoiceChip(
                      label: Text(m),
                      selected: _model == m,
                      onSelected: (_) => setState(() => _model = m),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            // API key。
            TextFormField(
              initialValue: _apiKey,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入 API Key' : null,
              onChanged: (v) => _apiKey = v,
            ),
            const SizedBox(height: 12),
            // 自定义 baseUrl（可选）。
            TextFormField(
              initialValue: _baseUrl,
              decoration: const InputDecoration(
                labelText: '自定义 Base URL（可选）',
                border: OutlineInputBorder(),
                hintText: '留空用厂商默认',
              ),
              onChanged: (v) => _baseUrl = v,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
            const SizedBox(height: 8),
            Text(
              '所有配置仅存本机（SharedPreferences）。'
              '厂商/模型映射来自 Hermes providers 解析链复刻。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
