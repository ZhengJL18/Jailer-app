// frontmatter 解析：用 hermes 已有的 yaml 依赖实现（替代 printnotes 的
// cosmic_frontmatter 包）。解析 `---` 包裹的 YAML 头，返回 {frontmatter, body}。
library;

import 'package:yaml/yaml.dart';

/// frontmatter 解析结果。
class ParsedNote {
  final Map<String, dynamic> frontmatter;
  final String body;
  /// 原始文本（无 frontmatter 时 = body）。
  final String raw;

  ParsedNote({
    required this.frontmatter,
    required this.body,
    required this.raw,
  });
}

/// 解析 markdown 内容的 frontmatter。无 frontmatter 时返回空映射 + 原文。
ParsedNote parseFrontmatter(String content) {
  if (!content.startsWith('---')) {
    return ParsedNote(frontmatter: {}, body: content, raw: content);
  }

  final lines = content.split('\n');
  // 找到第二个 --- 行。
  var endIndex = -1;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trim() == '---') {
      endIndex = i;
      break;
    }
  }
  if (endIndex == -1) {
    return ParsedNote(frontmatter: {}, body: content, raw: content);
  }

  final yamlBlock = lines.sublist(1, endIndex).join('\n');
  final body = lines.sublist(endIndex + 1).join('\n');

  Map<String, dynamic> frontmatter = {};
  try {
    final yamlData = loadYaml(yamlBlock);
    if (yamlData is Map) {
      frontmatter = {
        for (final e in yamlData.entries) '${e.key}': _toDart(e.value),
      };
    }
  } catch (_) {
    // YAML 解析失败时降级为空 frontmatter，正文仍返回。
    frontmatter = {};
  }

  return ParsedNote(
    frontmatter: frontmatter,
    body: body.trim().isEmpty ? '' : body,
    raw: content,
  );
}

/// 从 parsed frontmatter 取 tag 值。
String? getTag(ParsedNote note, String tag) {
  final value = note.frontmatter[tag];
  if (value == null) return null;
  return value.toString();
}

dynamic _toDart(dynamic v) {
  if (v is YamlMap) {
    return {for (final e in v.entries) '${e.key}': _toDart(e.value)};
  }
  if (v is YamlList) {
    return v.map(_toDart).toList();
  }
  return v;
}
