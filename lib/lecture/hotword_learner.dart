/// 热词自进化。
///
/// 闭环：科目专属热词库 → 转写时喂给 ASR 纠偏 → DeepSeek 笔记生成 → 笔记
/// 中的术语（terms）回填该科目热词库 → 下次转写更准。热词分科目，与笔记联动。
library;

import 'lecture_db.dart';
import 'models.dart';

/// 把笔记中的术语回填到科目热词库（去重），返回实际新增数。
///
/// 只提取长度 ≥2 的术语，避免单字噪声。这是自进化的核心入口：每次生成
/// 笔记后调用，科目热词库随之增长，转写准确率随之提升。
Future<int> harvestTermsFromNote({
  required String subjectId,
  required LectureNote note,
}) async {
  final db = LectureDb.instance;
  final words = note.terms
      .map((t) => t.trim())
      .where((t) => t.length >= 2)
      .toList();
  return db.addHotwords(subjectId, words);
}
