// printnotes 的 App 类适配：原 printnotes main.dart 里的 `App.localStorage`
// （SharedPreferences 全局静态）。printnotes 的 utils/configs/*.dart 依赖它，
// 这里提供等价物，避免引入 printnotes 完整 main.dart。
library;

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/configs/data_path.dart';

class App {
  App._();

  static late SharedPreferences localStorage;

  /// 初始化 localStorage + 默认笔记库目录（hermes documents/notes 根）。
  static Future<void> init() async {
    localStorage = await SharedPreferences.getInstance();
    // 无用户自定义目录时，默认指向 hermes 的 notes 根（与 subject_library 同根，
    // agent 可读写）。已有用户选择则不覆盖。
    if (await DataPath.selectedDirectory == null) {
      final docs = (await getApplicationDocumentsDirectory()).path;
      await DataPath.setSelectedDirectory('$docs/notes');
    }
  }
}
