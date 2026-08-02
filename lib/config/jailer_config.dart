/// Jailer 配置持久化 —— 复用 MIX `AiSettings` 的 SharedPreferences 模式。
///
/// 存储 vendor/model/key/baseUrl，经 [providers.dart] 的解析链解析成 LlmConfig。
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../llm/openai_llm.dart';
import 'providers.dart';

/// Jailer 配置。
class JailerConfig {
  final String vendorId;
  final String model;
  final String apiKey;
  final String baseUrl;

  const JailerConfig({
    required this.vendorId,
    required this.model,
    required this.apiKey,
    required this.baseUrl,
  });

  /// 是否完整可用。
  bool get isComplete =>
      vendorId.isNotEmpty && model.isNotEmpty && apiKey.isNotEmpty;

  /// 从 SharedPreferences 读取。
  static Future<JailerConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final vendorId = prefs.getString('jailer_vendor') ?? '';
    final model = prefs.getString('jailer_model') ?? '';
    final apiKey = prefs.getString('jailer_api_key') ?? '';
    final baseUrl = prefs.getString('jailer_base_url') ?? '';
    final config = JailerConfig(
      vendorId: vendorId,
      model: model,
      apiKey: apiKey,
      baseUrl: baseUrl,
    );
    return config.isComplete ? config : null;
  }

  /// 写入 SharedPreferences。
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('jailer_vendor', vendorId);
    await prefs.setString('jailer_model', model);
    await prefs.setString('jailer_api_key', apiKey);
    await prefs.setString('jailer_base_url', baseUrl);
  }

  /// 转换成 LlmConfig。
  LlmConfig toLlmConfig() {
    // 用 baseUrl（自定义优先），否则用 provider 预设。
    final pdef = resolveProviderFull(vendorId);
    final effectiveBaseUrl = baseUrl.isNotEmpty
        ? baseUrl
        : (pdef?.baseUrl ?? '');
    return LlmConfig(
      baseUrl: effectiveBaseUrl,
      apiKey: apiKey,
      model: model,
    );
  }
}

/// 把 keyResolver 钩子接到 App 配置读取。
Future<void> initConfig() async {
  final prefs = await SharedPreferences.getInstance();
  keyResolver = (envVar) {
    // env var 名 → 单一存储 key（App 只有一个 key 槽）。
    return prefs.getString('jailer_api_key');
  };
}

/// 常用模型预设（按 vendor）。
const Map<String, List<String>> vendorModels = {
  'deepseek': ['deepseek-chat', 'deepseek-reasoner'],
  'alibaba': ['qwen-plus', 'qwen-max', 'qwen-turbo'],
  'openai': ['gpt-4o', 'gpt-4o-mini', 'o3-mini'],
  'kimi-for-coding': ['moonshot-v1-8k', 'moonshot-v1-32k', 'moonshot-v1-128k'],
  'zai': ['glm-4-plus', 'glm-4-flash'],
  'google': ['gemini-2.0-flash', 'gemini-1.5-pro', 'gemini-1.5-flash'],
  'openrouter': ['openrouter/auto'],
  'anthropic': ['claude-sonnet-4-6', 'claude-opus-4-5'],
};

/// vendor 显示名（配置页下拉用）。
const Map<String, String> vendorLabels = {
  'deepseek': 'DeepSeek',
  'alibaba': '通义千问 (DashScope)',
  'openai': 'OpenAI',
  'kimi-for-coding': 'Kimi (Moonshot)',
  'zai': '智谱 GLM (Z.ai)',
  'google': 'Gemini (Google)',
  'openrouter': 'OpenRouter',
  'anthropic': 'Anthropic Claude',
};
