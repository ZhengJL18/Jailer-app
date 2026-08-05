/// DeepSeek 课堂笔记生成。
///
/// 把转写全文（可选带说话人标签）+ 课程热词喂给 DeepSeek，输出结构化
/// JSON 笔记：核心概述、要点、术语、考点、疑问。API key 与模型名存于
/// SharedPreferences（`lecture_deepseek_key` / `lecture_deepseek_model`）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// 返回是否已配置 DeepSeek API key。
Future<bool> hasDeepSeekKey() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getString('lecture_deepseek_key') ?? '').isNotEmpty;
}

/// 读取 DeepSeek 配置。未配置时 key 为空串。
Future<({String key, String model})> deepSeekConfig() async {
  final prefs = await SharedPreferences.getInstance();
  return (
    key: prefs.getString('lecture_deepseek_key') ?? '',
    model: prefs.getString('lecture_deepseek_model') ?? 'deepseek-chat',
  );
}

/// 保存 DeepSeek 配置。
Future<void> saveDeepSeekConfig({required String key, required String model}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('lecture_deepseek_key', key);
  if (model.isNotEmpty) {
    await prefs.setString('lecture_deepseek_model', model);
  }
}

/// 生成结构化笔记。onToken 每收到一段输出调用一次（流式体验）。
///
/// [transcriptText] 为完整转写文本，[hotwords] 为课程热词（用于术语纠偏
/// 提示），[title] 为课程/会话标题。
Future<LectureNote> generateNotes({
  required String transcriptText,
  required List<String> hotwords,
  required String title,
  void Function(String partial)? onToken,
}) async {
  final cfg = await deepSeekConfig();
  if (cfg.key.isEmpty) {
    throw StateError('请先在设置中配置 DeepSeek API Key');
  }

  final prompt = _buildPrompt(title, transcriptText, hotwords);
  final messages = [
    {'role': 'system', 'content': '你是专业的课堂笔记整理助手。'},
    {'role': 'user', 'content': prompt},
  ];

  final response = await http
      .post(
        Uri.parse('https://api.deepseek.com/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${cfg.key}',
        },
        body: jsonEncode({
          'model': cfg.model,
          'messages': messages,
          'temperature': 0.3,
          'stream': false,
          'response_format': {'type': 'json_object'},
        }),
      )
      .timeout(const Duration(minutes: 5));

  if (response.statusCode != 200) {
    throw StateError(
      'DeepSeek 请求失败（${response.statusCode}）：${response.body}',
    );
  }

  final data = jsonDecode(utf8.decode(response.bodyBytes))
      as Map<String, dynamic>;
  final content = ((data['choices'] as List).first['message'] as Map)['content']
      as String;
  onToken?.call(content);

  final cleaned = content
      .replaceAll('```json', '')
      .replaceAll('```', '')
      .trim();
  final jsonBody = jsonDecode(cleaned) as Map<String, dynamic>;
  return LectureNote.fromJson(jsonBody);
}

/// 一键生成笔记的返回：完整 Markdown 正文 + 待回填热词库的术语。
class NoteGeneration {
  const NoteGeneration({required this.markdown, required this.terms});

  final String markdown;
  final List<String> terms;
}

/// 一键生成 Markdown 课堂笔记正文，并提取术语用于科目热词自进化。
///
/// 输出可直接追加到笔记正文；[hotwords] 为科目热词（用于转写术语纠偏），
/// [title] 为笔记标题。
Future<NoteGeneration> generateNoteMarkdown({
  required String transcriptText,
  required List<String> hotwords,
  required String title,
}) async {
  final cfg = await deepSeekConfig();
  if (cfg.key.isEmpty) {
    throw StateError('请先在设置中配置 DeepSeek API Key');
  }

  final sb = StringBuffer();
  sb.writeln('请根据下面的课堂转写内容，整理成一篇完整的 Markdown 课堂笔记。');
  sb.writeln('笔记标题：$title');
  sb.writeln('注意：这是语音转写结果，可能含有同音错字。');
  if (hotwords.isNotEmpty) {
    sb.writeln(
      '遇到与以下术语读音相近的内容时，应优先判断并更正为本术语：'
      '${hotwords.join('、')}',
    );
  }
  sb.writeln('要求：');
  sb.writeln('- 用 Markdown 组织：一级标题为笔记标题，使用 ## 分节（核心内容、'
      '重点考点、术语解释等）。');
  sb.writeln('- 提炼老师强调的重点、考点，用列表呈现。');
  sb.writeln('- 涉及公式可用 LaTeX：行内 \$...\$、块级 \$\$...\$\$。');
  sb.writeln('- 口语化内容书面化，去除口头禅。');
  sb.writeln('- 不要遗漏关键知识点。');
  sb.writeln('请仅返回一个 JSON 对象，字段：');
  sb.writeln('{"markdown": "完整笔记正文（Markdown）", "terms": ["本课出现的专业术语，用于热词库，每个不少于2字"]}');
  sb.writeln('不要输出 JSON 以外的任何内容。');
  sb.writeln('\n以下是转写全文：\n');
  sb.write(transcript);

  final response = await http
      .post(
        Uri.parse('https://api.deepseek.com/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${cfg.key}',
        },
        body: jsonEncode({
          'model': cfg.model,
          'messages': [
            {'role': 'system', 'content': '你是专业的课堂笔记整理助手。'},
            {'role': 'user', 'content': sb.toString()},
          ],
          'temperature': 0.3,
          'stream': false,
          'response_format': {'type': 'json_object'},
        }),
      )
      .timeout(const Duration(minutes: 5));

  if (response.statusCode != 200) {
    throw StateError(
      'DeepSeek 请求失败（${response.statusCode}）：${response.body}',
    );
  }

  final data = jsonDecode(utf8.decode(response.bodyBytes))
      as Map<String, dynamic>;
  final content = ((data['choices'] as List).first['message'] as Map)['content']
      as String;
  final cleaned =
      content.replaceAll('```json', '').replaceAll('```', '').trim();
  final jsonBody = jsonDecode(cleaned) as Map<String, dynamic>;
  final markdown = jsonBody['markdown'] as String? ?? '';
  final terms = (jsonBody['terms'] as List? ?? const [])
      .map((e) => e.toString())
      .toList();
  return NoteGeneration(markdown: markdown, terms: terms);
}

/// 构造笔记生成 prompt。热词列表会明确要求 LLM 用它纠正转写中的术语错误
/// （弥补 Paraformer 无 ASR 级热词的短板）。
String _buildPrompt(String title, String transcript, List<String> hotwords) {
  final sb = StringBuffer();
  sb.writeln('请根据下面的课堂转写内容，整理成结构化笔记。课程标题：$title');
  sb.writeln('注意：这是语音转写结果，可能含有同音错字。');
  if (hotwords.isNotEmpty) {
    sb.writeln(
      '遇到与以下术语读音相近的内容时，应优先判断并更正为本术语：'
      '${hotwords.join('、')}',
    );
  }
  sb.writeln('请仅返回一个 JSON 对象，字段：');
  sb.writeln('{"summary": "课程核心内容概述（100字内）",');
  sb.writeln(' "keyPoints": ["要点1", "要点2", ...],');
  sb.writeln(' "terms": ["需掌握的名词/术语", ...],');
  sb.writeln(' "examHints": ["老师强调的考点/重点", ...],');
  sb.writeln(' "questions": ["转写中提及但未解答的疑问", ...]}');
  sb.writeln('不要输出 JSON 以外的任何内容。');
  sb.writeln('\n以下是转写全文：\n');
  sb.write(transcript);
  return sb.toString();
}
