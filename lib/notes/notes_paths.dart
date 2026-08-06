// 笔记库根目录常量。根 = <documents>/notes，subject_library 移为子文件夹。
// main.dart _initCwd 与 StudyQuestionService 共用，避免硬编码散落。
library;

/// 笔记库根目录名（位于 documents 下）。
const String notesRootDirName = 'notes';

/// subject_library 在 notes 根下的相对名。
const String subjectLibraryDirName = 'subject_library';

/// 组装笔记库根路径。
String notesRootPath(String documentsDir) =>
    '$documentsDir/$notesRootDirName';

/// 组装 subject_library 路径。
String subjectLibraryPath(String documentsDir) =>
    '$documentsDir/$notesRootDirName/$subjectLibraryDirName';
