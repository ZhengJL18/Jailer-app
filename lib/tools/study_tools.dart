/// study_list / study_question 工具：学习模式出题入口。
///
/// 薄工具层，真实逻辑由 [studyQuestionHandler] / [studyListHandler] 委托给
/// 注入方（ChatScreen/bridge，拥有 LLM client + StudyEngine + 画像读取）。
library;

import 'registry.dart';

/// 出题执行器（多阶段管线）：给定科目/知识点，返回题目 JSON。
/// [kpId] 知识点 id；[targetDifficulty] 目标难度档（easy/medium/hard，可选）。
Future<String> Function(
  int kpId, {
  String? targetDifficulty,
})? studyQuestionHandler;

/// 知识点列表执行器：返回可用科目/知识点（带掌握度）。
Future<String> Function()? studyListHandler;

/// study_list 工具 handler。
Future<String> _handleStudyList(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  final handler = studyListHandler;
  if (handler == null) {
    return toolError('study_list: 学习引擎未初始化');
  }
  try {
    return await handler();
  } catch (e) {
    return toolError('study_list failed: $e');
  }
}

/// study_question 工具 handler。
Future<String> _handleStudyQuestion(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  final handler = studyQuestionHandler;
  if (handler == null) {
    return toolError('study_question: 学习引擎未初始化');
  }
  final kpId = args['kp_id'];
  if (kpId is! int && kpId is! String) {
    return toolError('study_question: 缺少有效的 kp_id');
  }
  final targetDifficulty = args['target_difficulty'] as String?;
  try {
    return await handler(
      kpId is String ? int.tryParse(kpId) ?? 0 : kpId,
      targetDifficulty: targetDifficulty,
    );
  } catch (e) {
    return toolError('study_question failed: $e');
  }
}

const Map<String, dynamic> _studyListSchema = {
  'name': 'study_list',
  'description':
      'List available knowledge points with their mastery (recent accuracy). '
      'Use at the start of a study session to pick what to practice and to '
      'announce the round ("这轮 N 题，主练 X，上次正确率 Y%").',
  'parameters': {
    'type': 'object',
    'properties': {},
    'required': [],
  },
};

const Map<String, dynamic> _studyQuestionSchema = {
  'name': 'study_question',
  'description':
      'Generate a practice question for the given knowledge point using a '
      'multi-stage refined pipeline (draft → complexity rounds → independent '
      'critique → refine → final check). Returns a JSON question with 4 '
      'options, the correct answer, and an explanation. Targeting is based on '
      'the student profile (0_profile.md).',
  'parameters': {
    'type': 'object',
    'properties': {
      'kp_id': {
        'type': 'integer',
        'description': 'Knowledge point id from study_list',
      },
      'target_difficulty': {
        'type': 'string',
        'enum': ['easy', 'medium', 'hard'],
        'description': 'Optional target difficulty; defaults to auto from mastery',
      },
    },
    'required': ['kp_id'],
  },
};

/// 注册学习工具。
void registerStudyTools() {
  registry.register(
    name: 'study_list',
    toolset: 'study',
    schema: _studyListSchema,
    handler: _handleStudyList,
    isAsync: true,
    emoji: '📚',
  );
  registry.register(
    name: 'study_question',
    toolset: 'study',
    schema: _studyQuestionSchema,
    handler: _handleStudyQuestion,
    isAsync: true,
    emoji: '📝',
    // 题目 JSON 有界。
    maxResultSizeChars: 6000,
  );
}
