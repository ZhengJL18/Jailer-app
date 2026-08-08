// printnotes 的 App 类适配：原 printnotes main.dart 里的 `App.localStorage`
// （SharedPreferences 全局静态）。printnotes 的 utils/configs/*.dart 依赖它，
// 这里提供等价物，避免引入 printnotes 完整 main.dart。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'utils/configs/data_path.dart';

class App {
  App._();

  static late SharedPreferences localStorage;

  /// 初始化 localStorage + 确保笔记库根目录存在（documents/notes）。
  /// 笔记根固定由 DataPath 提供，与 agent 的 notes_* 工具共用。
  static Future<void> init() async {
    localStorage = await SharedPreferences.getInstance();
    await DataPath.selectedDirectory;
  }
}
